#!/bin/bash
# ════════════════════════════════════════════════════════════════════════════
# Claude Code — Status Line with real-time usage tracking
#
# Dependencies: bash, jq, curl
# License: MIT
#
# Default: 🌿 main★ │ Snt 4.6 │ 🟢 Ctx ▓▓▓░░░ 42% │ ⏳ 🟡 ▓▓░░░░ 35% ↻ 2h30m │ $0.12 ⏱ 1h4m
# ════════════════════════════════════════════════════════════════════════════

# ── Configuration (override via environment variables) ────────────────────────
TIMEZONE="${TIMEZONE:-}"                            # e.g. "America/New_York", empty = system default
REFRESH_INTERVAL="${REFRESH_INTERVAL:-300}"           # seconds between API calls (0 = every render, risks rate limiting)
SHOW_WEEKLY="${SHOW_WEEKLY:-0}"                      # set to 1 to show weekly + per-model quotas
SHOW_MODEL_WEEKLY="${SHOW_MODEL_WEEKLY:-1}"          # 0 = hide the per-model weekly quota and never call the API for it
SHOW_DIR="${SHOW_DIR:-0}"                            # 1 = lead with the project directory name
SHOW_CONTEXT_TOKENS="${SHOW_CONTEXT_TOKENS:-0}"      # 1 = context as "194k/1000k" instead of a percentage
STATUSLINE_STYLE="${STATUSLINE_STYLE:-emoji}"        # emoji | plain (ANSI colors, no emoji)
USAGE_FILE="${USAGE_FILE:-$HOME/.claude/usage-exact.json}"
DEFAULT_CREDENTIALS_FILE="$HOME/.claude/.credentials.json"
CREDENTIALS_FILE="${CREDENTIALS_FILE:-$DEFAULT_CREDENTIALS_FILE}"
SETTINGS_FILE="${SETTINGS_FILE:-$HOME/.claude/settings.json}"

# ── Helpers ───────────────────────────────────────────────────────────────────
tz_date() {
    local tz="$1"; shift
    if [ -n "$tz" ]; then TZ="$tz" date "$@"; else date "$@"; fi
}

format_remaining() {
    local secs="$1"
    [ "$secs" -le 0 ] 2>/dev/null && return
    local h=$(( secs / 3600 )) m=$(( (secs % 3600) / 60 ))
    if [ $h -gt 0 ]; then echo "${h}h${m}m"
    elif [ $m -gt 0 ]; then echo "${m}m"
    else echo "<1m"
    fi
}

# Cross-platform ISO 8601 → epoch (GNU date -d || BSD date -j)
iso_to_epoch() {
    local iso="$1"
    date -d "$iso" +%s 2>/dev/null && return
    # macOS/BSD fallback: strip the offset/Z and fractional seconds, then parse the
    # core as UTC (-u). The API always sends +00:00, so the stripped wall-clock IS
    # UTC; without -u, date -j would read it as local time and skew the countdown.
    local core="${iso%[+-][0-9][0-9]:*}"  # strip +HH:MM / -HH:MM suffix
    core="${core%Z}"                       # strip trailing Z
    core="${core%%.*}"                     # strip .fractional
    date -juf "%Y-%m-%dT%H:%M:%S" "$core" +%s 2>/dev/null
}

file_mtime() {
    if stat --version &>/dev/null; then
        stat -c %Y "$1" 2>/dev/null || echo 0
    else
        stat -f %m "$1" 2>/dev/null || echo 0
    fi
}

cache_age_sec() {
    [ ! -f "$USAGE_FILE" ] && echo 999999 && return
    local age=$(( $(date +%s) - $(file_mtime "$USAGE_FILE") ))
    [ "$age" -lt 0 ] && age=0
    echo "$age"
}

# Coerce to a bare non-negative integer. Drops the decimal part then strips any
# non-digit. Critical: percentages/resets flow into $(( )), where a value like
# "x[$(cmd)]" would execute cmd via arithmetic array-subscript evaluation.
num() {
    local v="${1%%.*}"
    v="${v//[^0-9]/}"
    echo "$(( 10#${v:-0} ))"   # 10# forces base 10 — a leading zero would be read as octal
}

is_plain() { [ "$STATUSLINE_STYLE" = "plain" ]; }

# ANSI palette of the plain style
C_RESET=$'\033[0m' C_DIM=$'\033[2m' C_DIR=$'\033[1;93m' C_TIMER=$'\033[35m'
C_GREEN=$'\033[38;5;194m' C_ORANGE=$'\033[38;5;208m' C_RED=$'\033[31m'

# make_bar <percent> → sets BAR_COLOR and BAR_STR.
# emoji style: 6 blocks of ▓ and a colored dot; plain style: 10 blocks of █ and an
# ANSI color. Both steps (17 = ceil(100/6), and 10) fill the bar exactly at 100%.
make_bar() {
    local pct; pct="$(num "$1")"
    [ "$pct" -gt 100 ] && pct=100
    local blocks=6 step=17 fill="▓"
    is_plain && blocks=10 step=10 fill="█"
    local filled=$(( (pct + step - 1) / step )); [ "$filled" -gt "$blocks" ] && filled=$blocks
    local empty=$(( blocks - filled ))
    BAR_STR=""
    local i
    for ((i=0; i<filled; i++)); do BAR_STR+="$fill"; done
    for ((i=0; i<empty;  i++)); do BAR_STR+="░"; done
    if is_plain; then
        if   [ "$pct" -lt 50 ]; then BAR_COLOR="$C_GREEN"
        elif [ "$pct" -lt 80 ]; then BAR_COLOR="$C_ORANGE"
        else                         BAR_COLOR="$C_RED"
        fi
    else
        if   [ "$pct" -lt 50 ]; then BAR_COLOR="🟢"
        elif [ "$pct" -lt 80 ]; then BAR_COLOR="🟡"
        else                         BAR_COLOR="🔴"
        fi
    fi
}

# render_quota <emoji> <percent> <reset_epoch> → "emoji color bar pct% [↻ remain]".
# A reset moment already in the past means the window rolled over → usage back to 0%.
# Needs NOW set by the caller.
render_quota() {
    local emoji="$1" reset="$3" remain="" pct
    pct="$(num "$2")"
    if [ -n "$reset" ] && [ "$reset" -gt "$NOW" ] 2>/dev/null; then
        remain=$(format_remaining $(( reset - NOW )))
    elif [ -n "$reset" ] && [ "$reset" -le "$NOW" ] 2>/dev/null; then
        pct=0
    fi
    make_bar "$pct"
    local out="${emoji} ${BAR_COLOR} ${BAR_STR} ${pct}%"
    [ -n "$remain" ] && out="${out} ↻ ${remain}"
    echo "$out"
}

# render_quota_plain <label> <percent> <reset_epoch> → "label [bar] pct%" in ANSI color.
# Same rollover rule as render_quota. No countdown: the plain style renders the
# 5-hour reset as a segment of its own.
render_quota_plain() {
    local label="$1" reset="$3" pct
    pct="$(num "$2")"
    if [ -n "$reset" ] && [ "$reset" -le "$NOW" ] 2>/dev/null; then pct=0; fi
    make_bar "$pct"
    echo "${BAR_COLOR}${label} [${BAR_STR}] ${pct}%${C_RESET}"
}

# ── Read JSON input from stdin ────────────────────────────────────────────────
JSON=$(cat)

# ── Parse all stdin fields in a single jq call ───────────────────────────────
# Joined on US (0x1f), not "|": a "|" in a branch path or model name would shift
# every field. US is non-whitespace so read preserves empty fields (absent
# rate_limits). rate_limits.* is native since Claude Code 2.1.x (Pro/Max) —
# preferred over the API call when present.
# jq -j, not -r: the Windows jq.exe ends lines with \r\n, and read would keep the
# \r on the last field.
IFS=$'\x1f' read -r J_MODEL_DISPLAY J_MODEL_RAW J_CTX_PCT J_CTX_SIZE J_COST J_DURATION J_CWD \
    J_RL_5H_PCT J_RL_5H_RESET J_RL_7D_PCT J_RL_7D_RESET J_EFFORT J_CTX_TOKENS \
    < <(echo "$JSON" | jq -j '[
        (if .model | type == "object" then .model.display_name // "" else "" end),
        (if .model | type == "string" then .model else "" end),
        (.context_window.used_percentage // 0 | tostring | split(".")[0]),
        (.context_window.context_window_size // 0),
        (.cost.total_cost_usd // ""),
        (.cost.total_duration_ms // ""),
        (.workspace.current_dir // ""),
        (.rate_limits.five_hour.used_percentage // ""),
        (.rate_limits.five_hour.resets_at // ""),
        (.rate_limits.seven_day.used_percentage // ""),
        (.rate_limits.seven_day.resets_at // ""),
        ((.effort | objects | .level | strings) // ""),
        (.context_window.total_input_tokens // 0)
    ] | join("\u001f")' 2>/dev/null)

# ── Model ─────────────────────────────────────────────────────────────────────
MODEL="$J_MODEL_DISPLAY"
MODEL=$(echo "$MODEL" | sed 's/Default (\(.*\))/\1/' | sed 's/Claude //' | sed 's/ (.*//')
[ -z "$MODEL" ] && MODEL="$J_MODEL_RAW"
case "$MODEL" in
  claude-sonnet-4-6*|Sonnet\ 4.6*) MODEL="Snt 4.6" ;;
  claude-sonnet-4-5*|Sonnet\ 4.5*) MODEL="Snt 4.5" ;;
  claude-opus-4-6*|Opus\ 4.6*)     MODEL="Opus 4.6" ;;
  claude-opus-4-5*|Opus\ 4.5*)     MODEL="Opus 4.5" ;;
  claude-haiku-4*|Haiku\ 4*)       MODEL="Haiku 4"  ;;
esac
# strip control bytes — model name comes from untrusted JSON (terminal OSC injection)
MODEL="${MODEL//[$'\x01'-$'\x1f'$'\x7f']/}"

# ── Effort level ──────────────────────────────────────────────────────────────
# effort.level on stdin is the live session value and follows a mid-session
# /effort change. settings.json only ever holds the configured default, so it goes
# stale the moment the level is changed — stdin wins, and the file stays as the
# fallback for a Claude Code that does not send the field. The field is also absent
# for a model with no effort parameter; the two cases cannot be told apart.
EFFORT_RAW="$J_EFFORT"
if [ -z "$EFFORT_RAW" ] && [ -f "$SETTINGS_FILE" ]; then
    EFFORT_RAW=$(jq -r '.effortLevel // empty' "$SETTINGS_FILE" 2>/dev/null)
fi
EFFORT_LABEL=""
case "$EFFORT_RAW" in
    low)    EFFORT_LABEL="lo" ;;
    medium) EFFORT_LABEL="md" ;;
    high)   EFFORT_LABEL="hi" ;;
    xhigh)  EFFORT_LABEL="xh" ;;
    max)    EFFORT_LABEL="mx" ;;
esac

# ── Context window ────────────────────────────────────────────────────────────
CTX_PERCENT="$(num "${J_CTX_PCT:-0}")"
CTX_LABEL="Ctx"
[ "$J_CTX_SIZE" -ge 900000 ] 2>/dev/null && CTX_LABEL="1M"   # ≥900k → extended 1M context

make_bar "$CTX_PERCENT"
CTX_COLOR="$BAR_COLOR" CTX_BAR="$BAR_STR"

# ── Session cost + duration ───────────────────────────────────────────────────
COST_STR="" DURATION_STR=""
if [[ "$J_COST" =~ ^[0-9]+(\.[0-9]+)?([eE][+-]?[0-9]+)?$ ]] && [ "$J_COST" != "0" ]; then
    COST_STR=$(printf '$%.2f' "$J_COST" 2>/dev/null)
fi
if [ -n "$J_DURATION" ] && [ "$J_DURATION" != "0" ] && [ "$J_DURATION" != "null" ]; then
    DURATION_STR=$(format_remaining $(( $(num "$J_DURATION") / 1000 )))
fi

# ── Git branch ────────────────────────────────────────────────────────────────
CWD="$J_CWD"
BRANCH="" DIRTY=""
if [ -n "$CWD" ] && [ -d "$CWD" ]; then
    BRANCH=$(git -C "$CWD" --no-optional-locks symbolic-ref --short HEAD 2>/dev/null)
    if [ -n "$BRANCH" ] && git -C "$CWD" --no-optional-locks diff --quiet HEAD 2>/dev/null; then
        [ -n "$(git -C "$CWD" --no-optional-locks ls-files --others --exclude-standard 2>/dev/null)" ] && DIRTY="★"
    else
        [ -n "$BRANCH" ] && DIRTY="★"
    fi
fi
[ -z "$BRANCH" ] && BRANCH="(no git)"
[ "${#BRANCH}" -gt 30 ] && BRANCH="${BRANCH:0:27}..."

# ── Refresh usage via Anthropic OAuth API ────────────────────────────────────
# Reads the subscription OAuth token from either the legacy credentials file
# (Linux / older Claude Code installs) or the macOS Keychain (current Darwin
# installs store the token there instead of on disk).
read_oauth_token() {
    if [ -f "$CREDENTIALS_FILE" ]; then
        jq -r '.claudeAiOauth.accessToken // empty' "$CREDENTIALS_FILE" 2>/dev/null
        return
    fi
    # An explicit CREDENTIALS_FILE means "this file only" (tests pass /dev/null):
    # never fall through to the real Keychain.
    [ "$CREDENTIALS_FILE" = "$DEFAULT_CREDENTIALS_FILE" ] || return
    if [ "$(uname)" = "Darwin" ] && command -v security >/dev/null 2>&1; then
        security find-generic-password -s "Claude Code-credentials" -a "$(whoami)" -w 2>/dev/null \
            | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null
    fi
}

refresh_usage_api() {
    local token
    token=$(read_oauth_token)
    [ -z "$token" ] && return 1
    local resp
    # Header via stdin (-H @-), not argv: other local users can read argv in ps.
    resp=$(printf 'Authorization: Bearer %s\n' "$token" | curl -s --max-time 3 \
        "https://api.anthropic.com/api/oauth/usage" \
        -H @- \
        -H "anthropic-beta: oauth-2025-04-20" \
        -H "Content-Type: application/json" 2>/dev/null)
    echo "$resp" | jq -e '.five_hour.utilization' >/dev/null 2>&1 || return 1
    local tmp
    tmp=$(mktemp "${USAGE_FILE}.XXXXXX") || return 1
    if echo "$resp" | jq '{
        timestamp: (now | todate),
        source: "api",
        metrics: {
            session: {
                percent_used: .five_hour.utilization,
                percent_remaining: (100 - .five_hour.utilization),
                resets_at: .five_hour.resets_at
            },
            week_all: {
                percent_used: .seven_day.utilization,
                percent_remaining: (100 - .seven_day.utilization),
                resets_at: .seven_day.resets_at
            },
            # Per-model quotas moved to limits[] (kind weekly_scoped); seven_day_sonnet
            # is now always null but kept as a fallback for older accounts.
            week_model: (
                ([(.limits | arrays // [])[] | select(.kind == "weekly_scoped" and (.percent | type) == "number")]
                    | first | if . then {
                        name: (.scope.model.display_name // "Model"),
                        percent_used: .percent,
                        percent_remaining: (100 - .percent),
                        resets_at: .resets_at
                    } else null end)
                // (if .seven_day_sonnet then {
                        name: "Sonnet",
                        percent_used: .seven_day_sonnet.utilization,
                        percent_remaining: (100 - .seven_day_sonnet.utilization),
                        resets_at: .seven_day_sonnet.resets_at
                    } else null end))
        }
    }' > "$tmp"; then
        mv "$tmp" "$USAGE_FILE"
    else
        rm -f "$tmp"; return 1
    fi
}

# Native stdin rate_limits (Pro/Max, CC ≥2.1.x) cover session + weekly-all. The
# API is only needed for the per-model quota (SHOW_WEEKLY) or as a fallback when the
# stdin field is absent — so most renders make no network call at all.
HAVE_STDIN_SESSION=0
[ -n "$J_RL_5H_PCT" ] && [ "$J_RL_5H_PCT" != "null" ] && HAVE_STDIN_SESSION=1
NEED_API=1
[ "$HAVE_STDIN_SESSION" = 1 ] && [ "$SHOW_WEEKLY" != "1" ] && NEED_API=0
# With both windows on stdin, the API would only add the per-model quota.
[ "$HAVE_STDIN_SESSION" = 1 ] && [ "$SHOW_MODEL_WEEKLY" != "1" ] \
    && [ -n "$J_RL_7D_PCT" ] && [ "$J_RL_7D_PCT" != "null" ] && NEED_API=0

[[ "$REFRESH_INTERVAL" =~ ^[0-9]+$ ]] || REFRESH_INTERVAL=300

# Lock outside world-writable /tmp to avoid a symlink/clobber on shared hosts.
LOCK_FILE="${XDG_RUNTIME_DIR:-$HOME/.claude}/statusline-refresh.lock"
if [ "$NEED_API" = 1 ] && [ "$(cache_age_sec)" -gt "$REFRESH_INTERVAL" ]; then
    # 2>/dev/null: if the lock dir is missing, skip the refresh quietly (no stderr noise)
    if command -v flock >/dev/null 2>&1; then
        ( flock -n 9 || exit 0; refresh_usage_api ) 9>"$LOCK_FILE" 2>/dev/null
    else
        # macOS has no `flock`. Without a lock, windows that render while the
        # cache is stale each make their own call; better than never refreshing.
        refresh_usage_api 2>/dev/null
    fi
fi

# ── Resolve usage metrics: native stdin (preferred) → API cache (fallback) ────
NOW=$(date +%s)

SESS_PCT="" SESS_EPOCH="" SESS_FROM_CACHE=0
WEEK_PCT="" WEEK_EPOCH="" MODEL_Q_PCT="" MODEL_Q_NAME=""

# Leave the epoch empty when no reset is sent — num("") is "0", which render_quota
# would read as a past reset and wrongly zero the live percentage.
if [ "$HAVE_STDIN_SESSION" = 1 ]; then
    SESS_PCT="$J_RL_5H_PCT"
    [ -n "$J_RL_5H_RESET" ] && [ "$J_RL_5H_RESET" != "null" ] && SESS_EPOCH="$(num "$J_RL_5H_RESET")"
fi
if [ "$SHOW_WEEKLY" = "1" ] && [ -n "$J_RL_7D_PCT" ] && [ "$J_RL_7D_PCT" != "null" ]; then
    WEEK_PCT="$J_RL_7D_PCT"
    [ -n "$J_RL_7D_RESET" ] && [ "$J_RL_7D_RESET" != "null" ] && WEEK_EPOCH="$(num "$J_RL_7D_RESET")"
fi

# Cache only fills metrics stdin didn't provide. resets_at parsed as ISO 8601
# (API format); the per-model weekly quota is API-only (absent from stdin).
# week_sonnet: cache written before week_model existed.
if [ -f "$USAGE_FILE" ]; then
    IFS=$'\x1f' read -r CACHE_SOURCE U_SESS_PCT U_SESS_RESETS U_WEEK_PCT U_WEEK_RESETS U_MODEL_Q_PCT U_MODEL_Q_NAME \
        < <(jq -j '[
            (.source // "legacy"),
            (.metrics.session.percent_used     // ""),
            (.metrics.session.resets_at        // ""),
            (.metrics.week_all.percent_used    // ""),
            (.metrics.week_all.resets_at       // ""),
            (.metrics.week_model.percent_used // .metrics.week_sonnet.percent_used // ""),
            (.metrics.week_model.name // "Sonnet" | tostring | explode | map(select(. >= 32 and . != 127)) | implode)
        ] | join("\u001f")' "$USAGE_FILE" 2>/dev/null)

    if [ -z "$SESS_PCT" ] && [ -n "$U_SESS_PCT" ] && [ "$U_SESS_PCT" != "null" ]; then
        SESS_PCT="$U_SESS_PCT"; SESS_FROM_CACHE=1
        [ "$CACHE_SOURCE" = "api" ] && [ -n "$U_SESS_RESETS" ] && SESS_EPOCH="$(iso_to_epoch "$U_SESS_RESETS")"
    fi
    if [ "$SHOW_WEEKLY" = "1" ]; then
        if [ -z "$WEEK_PCT" ] && [ -n "$U_WEEK_PCT" ] && [ "$U_WEEK_PCT" != "null" ]; then
            WEEK_PCT="$U_WEEK_PCT"
            [ "$CACHE_SOURCE" = "api" ] && [ -n "$U_WEEK_RESETS" ] && WEEK_EPOCH="$(iso_to_epoch "$U_WEEK_RESETS")"
        fi
        [ -n "$U_MODEL_Q_PCT" ] && [ "$U_MODEL_Q_PCT" != "null" ] \
            && MODEL_Q_PCT="$U_MODEL_Q_PCT" MODEL_Q_NAME="$U_MODEL_Q_NAME"
    fi
fi

# ── Stale indicator: only when the session came from the cache. stdin rate_limits
# are always fresh, so cache age is irrelevant there.
IS_STALE=0
if [ "$SESS_FROM_CACHE" = 1 ] && [ -f "$USAGE_FILE" ] && [ "$REFRESH_INTERVAL" -gt 0 ] 2>/dev/null; then
    [ "$(cache_age_sec)" -gt $(( REFRESH_INTERVAL * 3 )) ] && IS_STALE=1   # 3 missed refresh windows
fi

WEEK_INT="" WEEK_RESET_LABEL="" MODEL_Q_INT=""
if [ "$SHOW_WEEKLY" = "1" ]; then
    if [ -n "$WEEK_PCT" ] && [ "$WEEK_PCT" != "null" ]; then
        WEEK_INT="$(num "$WEEK_PCT")"
        if [ -n "$WEEK_EPOCH" ]; then
            # GNU date -d @epoch || BSD date -r epoch
            WEEK_RESET_LABEL=$(tz_date "${TIMEZONE}" -d "@$WEEK_EPOCH" +"%a %Hh" 2>/dev/null \
                || tz_date "${TIMEZONE}" -r "$WEEK_EPOCH" +"%a %Hh" 2>/dev/null)
            WEEK_RESET_LABEL=$(echo "$WEEK_RESET_LABEL" | tr '[:upper:]' '[:lower:]')
        fi
    fi
    if [ "$SHOW_MODEL_WEEKLY" = "1" ] && [ -n "$MODEL_Q_PCT" ] && [ "$MODEL_Q_PCT" != "null" ]; then
        MODEL_Q_INT="$(num "$MODEL_Q_PCT")"
    fi
fi

DIR_NAME=""
if [ "$SHOW_DIR" = "1" ] && [ -n "$CWD" ]; then
    # Strip one trailing separator, then keep the last component; \ covers Windows paths.
    DIR_NAME="${CWD%[/\\]}"
    DIR_NAME="${DIR_NAME##*[/\\]}"
    DIR_NAME="${DIR_NAME//[$'\x01'-$'\x1f'$'\x7f']/}"
fi

CTX_TOKENS_STR=""
if [ "$SHOW_CONTEXT_TOKENS" = "1" ]; then
    CTX_TOK="$(num "$J_CTX_TOKENS")" CTX_MAX="$(num "$J_CTX_SIZE")"
    if [ "$CTX_TOK" -gt 0 ]; then
        CTX_TOKENS_STR="$(( CTX_TOK / 1000 ))k"
        [ "$CTX_MAX" -gt 0 ] && CTX_TOKENS_STR+="/$(( CTX_MAX / 1000 ))k"
    fi
fi

# ── Segments ──────────────────────────────────────────────────────────────────
# One ordered list for both styles. Each seg_* renders itself for the active style
# and appends to PARTS, or appends nothing when it has nothing to show.
SEGMENTS=(dir branch model context session week timer cost)
PARTS=()

seg_dir() {
    [ -n "$DIR_NAME" ] || return 0
    if is_plain; then PARTS+=("${C_DIR}${DIR_NAME}${C_RESET}"); else PARTS+=("$DIR_NAME"); fi
}

seg_branch() {
    [ -n "$BRANCH" ] || return 0
    if is_plain; then
        # No placeholder outside a repository: the segment is dropped instead.
        [ "$BRANCH" = "(no git)" ] || PARTS+=("${C_DIM}${BRANCH}${DIRTY}${C_RESET}")
    else
        PARTS+=("🌿 $BRANCH$DIRTY")
    fi
}

seg_model() {
    [ -n "$MODEL" ] || return 0
    if [ -n "$EFFORT_LABEL" ]; then PARTS+=("$MODEL/$EFFORT_LABEL"); else PARTS+=("$MODEL"); fi
}

seg_context() {
    if [ -n "$CTX_TOKENS_STR" ]; then
        if is_plain; then PARTS+=("${CTX_COLOR}${CTX_TOKENS_STR} [${CTX_BAR}]${C_RESET}")
        else PARTS+=("$CTX_COLOR $CTX_TOKENS_STR $CTX_BAR"); fi
    elif [ -n "$CTX_PERCENT" ]; then
        if is_plain; then PARTS+=("${CTX_COLOR}${CTX_LABEL} [${CTX_BAR}] ${CTX_PERCENT}%${C_RESET}")
        else PARTS+=("$CTX_COLOR $CTX_LABEL $CTX_BAR ${CTX_PERCENT}%"); fi
    fi
}

seg_session() {
    { [ -n "$SESS_PCT" ] && [ "$SESS_PCT" != "null" ]; } || return 0
    local out
    if is_plain; then
        out="$(render_quota_plain "5h" "$SESS_PCT" "$SESS_EPOCH")"
        [ "$IS_STALE" = 1 ] && out="⚠ $out"
    else
        out="$(render_quota "⏳" "$SESS_PCT" "$SESS_EPOCH")"
        if [ "$IS_STALE" = 1 ]; then
            # ⚠ in place of the color dot. Exactly one dot is present; the other two
            # replacements are no-ops.
            out="${out/🟢/⚠}"; out="${out/🟡/⚠}"; out="${out/🔴/⚠}"
        fi
    fi
    PARTS+=("$out")
}

seg_week() {
    if is_plain; then
        [ -n "$WEEK_INT" ]    && PARTS+=("$(render_quota_plain "7d" "$WEEK_INT" "")")
        [ -n "$MODEL_Q_INT" ] && PARTS+=("$(render_quota_plain "$MODEL_Q_NAME" "$MODEL_Q_INT" "")")
        return 0
    fi
    local week_color="" model_q_color="" out=""
    [ -n "$WEEK_INT" ]    && { make_bar "$WEEK_INT"; week_color="$BAR_COLOR"; }
    [ -n "$MODEL_Q_INT" ] && { make_bar "$MODEL_Q_INT"; model_q_color="$BAR_COLOR"; }
    if [ -n "$WEEK_INT" ] && [ -n "$MODEL_Q_INT" ]; then
        out="📅 ${week_color} ${WEEK_INT}% / ${MODEL_Q_NAME} ${model_q_color} ${MODEL_Q_INT}%"
        [ -n "$WEEK_RESET_LABEL" ] && out+=" ↻ ${WEEK_RESET_LABEL}"
    elif [ -n "$WEEK_INT" ]; then
        out="📅 ${week_color} ${WEEK_INT}%"
        [ -n "$WEEK_RESET_LABEL" ] && out+=" ↻ ${WEEK_RESET_LABEL}"
    elif [ -n "$MODEL_Q_INT" ]; then
        out="${MODEL_Q_NAME} ${model_q_color} ${MODEL_Q_INT}%"
    fi
    [ -n "$out" ] && PARTS+=("$out")
    return 0
}

# Plain style only: the 5-hour reset as its own segment, "now/reset (remaining)".
# The emoji style already carries the countdown inside the session segment.
seg_timer() {
    is_plain || return 0
    { [ -n "$SESS_EPOCH" ] && [ "$SESS_EPOCH" -gt "$NOW" ]; } 2>/dev/null || return 0
    local clock
    clock=$(tz_date "${TIMEZONE}" -d "@$SESS_EPOCH" +"%H:%M" 2>/dev/null \
        || tz_date "${TIMEZONE}" -r "$SESS_EPOCH" +"%H:%M" 2>/dev/null)
    [ -n "$clock" ] || return 0
    PARTS+=("${C_TIMER}$(tz_date "${TIMEZONE}" +"%H:%M")${C_DIM}/${clock} ($(format_remaining $(( SESS_EPOCH - NOW ))))${C_RESET}")
}

# Cost + duration, only when non-zero
seg_cost() {
    [ -n "$COST_STR" ] || return 0
    if [ -z "$DURATION_STR" ]; then PARTS+=("$COST_STR")
    elif is_plain; then PARTS+=("$COST_STR $DURATION_STR")
    else PARTS+=("$COST_STR ⏱ $DURATION_STR"); fi
}

for seg in "${SEGMENTS[@]}"; do "seg_$seg"; done

# ── Assemble ──────────────────────────────────────────────────────────────────
SEP=" │ "
is_plain && SEP=" ${C_DIM}|${C_RESET} "
RESULT=""
for part in "${PARTS[@]}"; do
    [ -z "$RESULT" ] && RESULT="$part" || RESULT="$RESULT$SEP$part"
done

echo "${RESULT}"
