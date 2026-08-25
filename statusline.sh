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
SHOW_WEEKLY="${SHOW_WEEKLY:-0}"                      # set to 1 to show weekly + sonnet quotas
USAGE_FILE="${USAGE_FILE:-$HOME/.claude/usage-exact.json}"
CREDENTIALS_FILE="${CREDENTIALS_FILE:-$HOME/.claude/.credentials.json}"
SETTINGS_FILE="${SETTINGS_FILE:-$HOME/.claude/settings.json}"

# ── Style and optional sections ───────────────────────────────────────────────
# "emoji" is the upstream rendering. "plain" drops every emoji for an ANSI-colored
# line: wider bars, a dim pipe separator, and the reset clock as its own segment.
STATUSLINE_STYLE="${STATUSLINE_STYLE:-emoji}"        # emoji | plain
BAR_BLOCKS="${BAR_BLOCKS:-}"                          # bar width; default 6 (emoji) / 10 (plain)
SHOW_SONNET="${SHOW_SONNET:-1}"                       # 0 = never call the usage API for the Sonnet-only quota
SHOW_DIR="${SHOW_DIR:-0}"                             # 1 = leading project directory name
SHOW_BRANCH="${SHOW_BRANCH:-1}"                       # 0 = hide the git branch
SHOW_MODEL="${SHOW_MODEL:-1}"                         # 0 = hide model + effort
SHOW_COST="${SHOW_COST:-1}"                           # 0 = hide session cost + duration
SHOW_CONTEXT_TOKENS="${SHOW_CONTEXT_TOKENS:-0}"       # 1 = "168k/1000k" alongside the context bar
SHOW_BURN_RATE="${SHOW_BURN_RATE:-0}"                 # 1 = tokens/min over the last BURN_WINDOW_MIN
SHOW_SESSIONS="${SHOW_SESSIONS:-0}"                   # 1 = count of concurrently active sessions
BURN_WINDOW_MIN="${BURN_WINDOW_MIN:-10}"
SESSION_ACTIVE_MIN="${SESSION_ACTIVE_MIN:-5}"
PROJECTS_DIR="${PROJECTS_DIR:-$HOME/.claude/projects}"

if [ -z "$BAR_BLOCKS" ]; then
    if [ "$STATUSLINE_STYLE" = "plain" ]; then BAR_BLOCKS=10; else BAR_BLOCKS=6; fi
fi
[[ "$BAR_BLOCKS" =~ ^[1-9][0-9]?$ ]] || BAR_BLOCKS=6

# ANSI palette, used by the "plain" style only
C_RESET=$'\033[0m'   C_DIM=$'\033[2m'
C_DIR=$'\033[1;93m'  C_CTX=$'\033[2;38;5;225m'
C_GREEN=$'\033[38;5;194m' C_ORANGE=$'\033[38;5;208m' C_RED=$'\033[31m'
C_TIMER=$'\033[35m'  C_CYAN=$'\033[96m'

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

# make_bar <percent> → sets BAR_COLOR and BAR_STR (BAR_BLOCKS wide)
# The step is ceil(100/blocks), so any non-zero percentage lights the first block.
# At BAR_BLOCKS=6 the step is 17 and the arithmetic is identical to the original.
# BAR_COLOR carries the emoji dot in emoji style, an ANSI code in plain style.
make_bar() {
    local pct; pct="$(num "$1")"
    [ "$pct" -gt 100 ] && pct=100
    local step=$(( (100 + BAR_BLOCKS - 1) / BAR_BLOCKS ))
    local filled=$(( (pct + step - 1) / step )); [ $filled -gt "$BAR_BLOCKS" ] && filled=$BAR_BLOCKS
    local empty=$(( BAR_BLOCKS - filled ))
    local fill_glyph="▓"
    [ "$STATUSLINE_STYLE" = "plain" ] && fill_glyph="█"
    BAR_STR=""
    local i
    for ((i=0; i<filled; i++)); do BAR_STR+="$fill_glyph"; done
    for ((i=0; i<empty;  i++)); do BAR_STR+="░"; done
    if [ "$STATUSLINE_STYLE" = "plain" ]; then
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

# render_quota_plain <label> <percent> <reset_epoch> → "label [bar] pct%".
# Same rollover rule as render_quota: a reset already in the past means the window
# rolled over, so the percentage is back to 0. The countdown is not appended here —
# the plain style renders the clock as its own segment.
render_quota_plain() {
    local label="$1" reset="$3" pct
    pct="$(num "$2")"
    if [ -n "$reset" ] && [ "$reset" -le "$NOW" ] 2>/dev/null; then pct=0; fi
    make_bar "$pct"
    printf '%s%s [%s] %s%%%s' "$BAR_COLOR" "$label" "$BAR_STR" "$pct" "$C_RESET"
}

# tokens/min over the last <window> minutes of a transcript.
# Deduplicated on message.id: the transcript logs each assistant message two or
# three times, so summing the raw lines would inflate the rate by that factor.
# Counts input + cache_creation + output and excludes cache_read, which runs to
# ~190k tokens per turn here and would drown out any signal about real activity.
# Divides by the full window rather than the observed span, which keeps the number
# steady instead of spiking on a single burst.
burn_rate_per_min() {
    local transcript="$1" window_min="$2" cutoff
    [ -f "$transcript" ] || return 1
    cutoff=$(( $(date +%s) - window_min * 60 ))
    tail -n 400 "$transcript" 2>/dev/null | jq -s -r \
        --argjson cutoff "$cutoff" --argjson win "$window_min" '
        [ .[]
          | select(type == "object" and .type == "assistant"
                   and (.message.usage != null) and (.timestamp != null))
          | { id: (.message.id // .uuid // "?"),
              ts: (.timestamp | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601? // 0),
              tok: (((.message.usage.input_tokens // 0)
                     + (.message.usage.cache_creation_input_tokens // 0)
                     + (.message.usage.output_tokens // 0))) }
          | select(.ts >= $cutoff) ]
        | unique_by(.id)
        | if length == 0 then empty else ((map(.tok) | add) / $win | floor) end
    ' 2>/dev/null
}

# Sessions with transcript activity in the last <minutes>, counted one per project
# directory so several transcripts of the same project do not count twice.
count_active_sessions() {
    local dir="$1" minutes="$2"
    [ -d "$dir" ] || return 1
    find "$dir" -name '*.jsonl' -type f -mmin "-$minutes" 2>/dev/null \
        | sed 's|/[^/]*$||' | sort -u | wc -l | tr -d ' '
}

# ── Read JSON input from stdin ────────────────────────────────────────────────
JSON=$(cat)

# ── Parse all stdin fields in a single jq call ───────────────────────────────
# Joined on US (0x1f), not "|": a "|" in a branch path or model name would shift
# every field. US is non-whitespace so read preserves empty fields (absent
# rate_limits). rate_limits.* is native since Claude Code 2.1.x (Pro/Max) —
# preferred over the API call when present.
IFS=$'\x1f' read -r J_MODEL_DISPLAY J_MODEL_RAW J_CTX_PCT J_CTX_SIZE J_COST J_DURATION J_CWD \
    J_RL_5H_PCT J_RL_5H_RESET J_RL_7D_PCT J_RL_7D_RESET J_CTX_TOKENS J_TRANSCRIPT \
    < <(echo "$JSON" | jq -r '[
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
        (.context_window.total_input_tokens // 0),
        (.transcript_path // "")
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

# ── Effort level (from settings.json — not yet in stdin JSON) ────────────────
EFFORT_LABEL=""
if [ -f "$SETTINGS_FILE" ]; then
    case "$(jq -r '.effortLevel // empty' "$SETTINGS_FILE" 2>/dev/null)" in
        low)    EFFORT_LABEL="lo" ;;
        medium) EFFORT_LABEL="md" ;;
        high)   EFFORT_LABEL="hi" ;;
        max)    EFFORT_LABEL="mx" ;;
    esac
fi

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
refresh_usage_api() {
    [ ! -f "$CREDENTIALS_FILE" ] && return 1
    local token
    token=$(jq -r '.claudeAiOauth.accessToken // empty' "$CREDENTIALS_FILE" 2>/dev/null)
    [ -z "$token" ] && return 1
    local resp
    resp=$(curl -s --max-time 3 \
        "https://api.anthropic.com/api/oauth/usage" \
        -H "Authorization: Bearer $token" \
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
            week_sonnet: (if .seven_day_sonnet then {
                percent_used: .seven_day_sonnet.utilization,
                percent_remaining: (100 - .seven_day_sonnet.utilization),
                resets_at: .seven_day_sonnet.resets_at
            } else null end)
        }
    }' > "$tmp"; then
        mv "$tmp" "$USAGE_FILE"
    else
        rm -f "$tmp"; return 1
    fi
}

# Native stdin rate_limits (Pro/Max, CC ≥2.1.x) cover session + weekly-all. The
# API is only needed for the Sonnet quota (SHOW_WEEKLY) or as a fallback when the
# stdin field is absent — so most renders make no network call at all.
HAVE_STDIN_SESSION=0
[ -n "$J_RL_5H_PCT" ] && [ "$J_RL_5H_PCT" != "null" ] && HAVE_STDIN_SESSION=1
NEED_API=1
if [ "$HAVE_STDIN_SESSION" = 1 ]; then
    if [ "$SHOW_WEEKLY" != "1" ]; then
        NEED_API=0
    elif [ "$SHOW_SONNET" != "1" ] && [ -n "$J_RL_7D_PCT" ] && [ "$J_RL_7D_PCT" != "null" ]; then
        # stdin already carries both windows and the Sonnet-only quota was not asked
        # for, so there is nothing left to fetch: no network call, and no read of the
        # credentials file either.
        NEED_API=0
    fi
fi

[[ "$REFRESH_INTERVAL" =~ ^[0-9]+$ ]] || REFRESH_INTERVAL=300

# Lock outside world-writable /tmp to avoid a symlink/clobber on shared hosts.
LOCK_FILE="${XDG_RUNTIME_DIR:-$HOME/.claude}/statusline-refresh.lock"
if [ "$NEED_API" = 1 ] && [ "$(cache_age_sec)" -gt "$REFRESH_INTERVAL" ]; then
    # 2>/dev/null: if the lock dir is missing, skip the refresh quietly (no stderr noise)
    ( flock -n 9 || exit 0; refresh_usage_api ) 9>"$LOCK_FILE" 2>/dev/null
fi

# ── Resolve usage metrics: native stdin (preferred) → API cache (fallback) ────
BLOCK_DISPLAY="" WEEK_SONNET_DISPLAY=""
NOW=$(date +%s)

SESS_PCT="" SESS_EPOCH="" SESS_FROM_CACHE=0
WEEK_PCT="" WEEK_EPOCH="" SONNET_PCT=""

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
# (API format); the Sonnet weekly quota is API-only (absent from stdin).
if [ -f "$USAGE_FILE" ]; then
    IFS=$'\x1f' read -r CACHE_SOURCE U_SESS_PCT U_SESS_RESETS U_WEEK_PCT U_WEEK_RESETS U_SONNET_PCT \
        < <(jq -r '[
            (.source // "legacy"),
            (.metrics.session.percent_used     // ""),
            (.metrics.session.resets_at        // ""),
            (.metrics.week_all.percent_used    // ""),
            (.metrics.week_all.resets_at       // ""),
            (.metrics.week_sonnet.percent_used // "")
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
        [ -n "$U_SONNET_PCT" ] && [ "$U_SONNET_PCT" != "null" ] && SONNET_PCT="$U_SONNET_PCT"
    fi
fi

# ── Render ────────────────────────────────────────────────────────────────────
[ -n "$SESS_PCT" ] && [ "$SESS_PCT" != "null" ] && \
    BLOCK_DISPLAY="$(render_quota "⏳" "$SESS_PCT" "$SESS_EPOCH")"

if [ "$SHOW_WEEKLY" = "1" ]; then
    WEEK_INT="" WEEK_COLOR="" WEEK_RESET_LABEL="" SONNET_INT="" SONNET_COLOR=""
    if [ -n "$WEEK_PCT" ] && [ "$WEEK_PCT" != "null" ]; then
        WEEK_INT="$(num "$WEEK_PCT")"; make_bar "$WEEK_INT"; WEEK_COLOR="$BAR_COLOR"
        if [ -n "$WEEK_EPOCH" ]; then
            # GNU date -d @epoch || BSD date -r epoch
            WEEK_RESET_LABEL=$(tz_date "${TIMEZONE}" -d "@$WEEK_EPOCH" +"%a %Hh" 2>/dev/null \
                || tz_date "${TIMEZONE}" -r "$WEEK_EPOCH" +"%a %Hh" 2>/dev/null)
            WEEK_RESET_LABEL=$(echo "$WEEK_RESET_LABEL" | tr '[:upper:]' '[:lower:]')
        fi
    fi
    if [ -n "$SONNET_PCT" ] && [ "$SONNET_PCT" != "null" ]; then
        SONNET_INT="$(num "$SONNET_PCT")"; make_bar "$SONNET_INT"; SONNET_COLOR="$BAR_COLOR"
    fi
    if [ -n "$WEEK_INT" ] && [ -n "$SONNET_INT" ]; then
        WEEK_SONNET_DISPLAY="📅 ${WEEK_COLOR} ${WEEK_INT}% / Snt ${SONNET_COLOR} ${SONNET_INT}%"
        [ -n "$WEEK_RESET_LABEL" ] && WEEK_SONNET_DISPLAY+=" ↻ ${WEEK_RESET_LABEL}"
    elif [ -n "$WEEK_INT" ]; then
        WEEK_SONNET_DISPLAY="📅 ${WEEK_COLOR} ${WEEK_INT}%"
        [ -n "$WEEK_RESET_LABEL" ] && WEEK_SONNET_DISPLAY+=" ↻ ${WEEK_RESET_LABEL}"
    elif [ -n "$SONNET_INT" ]; then
        WEEK_SONNET_DISPLAY="Snt ${SONNET_COLOR} ${SONNET_INT}%"
    fi
fi

# ── Stale indicator — ⚠ in place of color dot. Only when session came from the
# cache: stdin rate_limits are always fresh, so cache age is irrelevant there.
IS_STALE=0
if [ "$SESS_FROM_CACHE" = 1 ] && [ -f "$USAGE_FILE" ] && [ "$REFRESH_INTERVAL" -gt 0 ] 2>/dev/null; then
    [ "$(cache_age_sec)" -gt $(( REFRESH_INTERVAL * 3 )) ] && IS_STALE=1   # 3 missed refresh windows
fi
if [ "$IS_STALE" = 1 ] && [ -n "$BLOCK_DISPLAY" ]; then
    # Exactly one color dot is present; the other two replacements are no-ops.
    BLOCK_DISPLAY="${BLOCK_DISPLAY/🟢/⚠}"
    BLOCK_DISPLAY="${BLOCK_DISPLAY/🟡/⚠}"
    BLOCK_DISPLAY="${BLOCK_DISPLAY/🔴/⚠}"
fi

# ── Optional ported sections ─────────────────────────────────────────────────
DIR_NAME=""
if [ "$SHOW_DIR" = "1" ] && [ -n "$CWD" ]; then
    DIR_NAME="${CWD##*/}"
    DIR_NAME="${DIR_NAME//[$'\x01'-$'\x1f'$'\x7f']/}"
fi

CTX_TOKENS_STR=""
if [ "$SHOW_CONTEXT_TOKENS" = "1" ]; then
    CTX_TOK="$(num "${J_CTX_TOKENS:-0}")"
    if [ "$CTX_TOK" -gt 0 ]; then
        CTX_TOKENS_STR="$(( CTX_TOK / 1000 ))k/$(( $(num "${J_CTX_SIZE:-0}") / 1000 ))k"
    fi
fi

BURN_STR=""
if [ "$SHOW_BURN_RATE" = "1" ] && [ -n "$J_TRANSCRIPT" ]; then
    BURN_RAW=$(burn_rate_per_min "$J_TRANSCRIPT" "$BURN_WINDOW_MIN")
    if [ -n "$BURN_RAW" ] && [ "$BURN_RAW" -gt 0 ] 2>/dev/null; then
        if [ "$BURN_RAW" -ge 1000 ]; then
            BURN_STR="$(awk "BEGIN {printf \"%.1fk/min\", $BURN_RAW / 1000}")"
        else
            BURN_STR="${BURN_RAW}/min"
        fi
    fi
fi

SESSIONS_STR=""
if [ "$SHOW_SESSIONS" = "1" ]; then
    SESSIONS_N=$(count_active_sessions "$PROJECTS_DIR" "$SESSION_ACTIVE_MIN")
    [ -n "$SESSIONS_N" ] && [ "$SESSIONS_N" -gt 0 ] 2>/dev/null && SESSIONS_STR="×${SESSIONS_N}"
fi

# The plain style renders the 5-hour reset as its own clock segment: current time,
# the reset time dimmed, and the remaining span.
TIMER_STR=""
if [ "$STATUSLINE_STYLE" = "plain" ] && [ -n "$SESS_EPOCH" ] && [ "$SESS_EPOCH" -gt "$NOW" ] 2>/dev/null; then
    RESET_CLOCK=$(tz_date "${TIMEZONE}" -d "@$SESS_EPOCH" +"%H:%M" 2>/dev/null \
        || tz_date "${TIMEZONE}" -r "$SESS_EPOCH" +"%H:%M" 2>/dev/null)
    if [ -n "$RESET_CLOCK" ]; then
        TIMER_STR="$(tz_date "${TIMEZONE}" +"%H:%M")${C_DIM}/${RESET_CLOCK} ($(format_remaining $(( SESS_EPOCH - NOW ))))${C_RESET}"
    fi
fi

# ── Assemble ──────────────────────────────────────────────────────────────────
PARTS=()
if [ "$STATUSLINE_STYLE" = "plain" ]; then
    [ -n "$DIR_NAME" ] && PARTS+=("${C_DIR}${DIR_NAME}${C_RESET}")
    # Outside a repository the plain style drops the segment entirely rather than
    # printing a placeholder: a permanent "(no git)" is noise in any non-repo cwd.
    [ "$SHOW_BRANCH" != "0" ] && [ -n "$BRANCH" ] && [ "$BRANCH" != "(no git)" ] \
        && PARTS+=("${C_DIM}${BRANCH}${DIRTY}${C_RESET}")
    if [ "$SHOW_MODEL" != "0" ] && [ -n "$MODEL" ]; then
        if [ -n "$EFFORT_LABEL" ]; then PARTS+=("$MODEL/$EFFORT_LABEL"); else PARTS+=("$MODEL"); fi
    fi
    if [ -n "$CTX_TOKENS_STR" ]; then
        PARTS+=("${C_CTX}${CTX_TOKENS_STR} [${CTX_BAR}]${C_RESET}")
    elif [ -n "$CTX_PERCENT" ]; then
        PARTS+=("${C_CTX}${CTX_LABEL} [${CTX_BAR}] ${CTX_PERCENT}%${C_RESET}")
    fi
    [ -n "$SESS_PCT" ] && [ "$SESS_PCT" != "null" ] && \
        PARTS+=("$(render_quota_plain "5h" "$SESS_PCT" "$SESS_EPOCH")")
    if [ "$SHOW_WEEKLY" = "1" ] && [ -n "$WEEK_PCT" ] && [ "$WEEK_PCT" != "null" ]; then
        PARTS+=("$(render_quota_plain "7d" "$WEEK_PCT" "$WEEK_EPOCH")")
    fi
    if [ "$SHOW_WEEKLY" = "1" ] && [ -n "$SONNET_PCT" ] && [ "$SONNET_PCT" != "null" ]; then
        PARTS+=("$(render_quota_plain "snt" "$SONNET_PCT" "")")
    fi
    [ -n "$TIMER_STR" ]   && PARTS+=("${C_TIMER}${TIMER_STR}${C_RESET}")
    [ -n "$BURN_STR" ]    && PARTS+=("${C_CYAN}${BURN_STR}${C_RESET}")
    [ -n "$SESSIONS_STR" ] && PARTS+=("${C_CYAN}${SESSIONS_STR}${C_RESET}")
    if [ "$SHOW_COST" != "0" ] && [ -n "$COST_STR" ]; then
        if [ -n "$DURATION_STR" ]; then PARTS+=("$COST_STR $DURATION_STR"); else PARTS+=("$COST_STR"); fi
    fi
    SEP=" ${C_DIM}|${C_RESET} "
else
    [ -n "$DIR_NAME" ] && PARTS+=("$DIR_NAME")
    [ "$SHOW_BRANCH" != "0" ] && [ -n "$BRANCH" ] && PARTS+=("🌿 $BRANCH$DIRTY")
    if [ "$SHOW_MODEL" != "0" ] && [ -n "$MODEL" ]; then
        if [ -n "$EFFORT_LABEL" ]; then PARTS+=("$MODEL/$EFFORT_LABEL"); else PARTS+=("$MODEL"); fi
    fi
    if [ -n "$CTX_TOKENS_STR" ]; then
        PARTS+=("$CTX_COLOR $CTX_TOKENS_STR $CTX_BAR")
    elif [ -n "$CTX_PERCENT" ]; then
        PARTS+=("$CTX_COLOR $CTX_LABEL $CTX_BAR ${CTX_PERCENT}%")
    fi
    [ -n "$BLOCK_DISPLAY" ]       && PARTS+=("$BLOCK_DISPLAY")
    [ -n "$WEEK_SONNET_DISPLAY" ] && PARTS+=("$WEEK_SONNET_DISPLAY")
    [ -n "$BURN_STR" ]            && PARTS+=("$BURN_STR")
    [ -n "$SESSIONS_STR" ]        && PARTS+=("$SESSIONS_STR")
    # Cost + duration (only if non-zero)
    if [ "$SHOW_COST" != "0" ] && [ -n "$COST_STR" ] && [ -n "$DURATION_STR" ]; then
        PARTS+=("$COST_STR ⏱ $DURATION_STR")
    elif [ "$SHOW_COST" != "0" ] && [ -n "$COST_STR" ]; then
        PARTS+=("$COST_STR")
    fi
    SEP=" │ "
fi

RESULT=""
for part in "${PARTS[@]}"; do
    [ -z "$RESULT" ] && RESULT="$part" || RESULT="$RESULT$SEP$part"
done

echo "${RESULT}"
