#!/bin/bash
# ════════════════════════════════════════════════════════════════════════════
# Claude Code — Status Line with real-time usage tracking
#
# Self-contained: everything is in this single file, no external scripts.
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
    # macOS/BSD fallback: strip timezone offset then fractional seconds, parse core
    local core="${iso%[+-][0-9][0-9]:*}"  # strip +HH:MM / -HH:MM suffix
    core="${core%Z}"                       # strip trailing Z
    core="${core%%.*}"                     # strip .fractional
    # TZ=UTC: API returns UTC ISO timestamps; without this, BSD date treats
    # the stripped core as local time and the epoch ends up offset by TZ.
    TZ=UTC date -jf "%Y-%m-%dT%H:%M:%S" "$core" +%s 2>/dev/null
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

# make_bar <percent> → sets BAR_COLOR and BAR_STR (6-block bar)
make_bar() {
    local pct="$1"
    [ "$pct" -lt 0 ] 2>/dev/null && pct=0
    [ "$pct" -gt 100 ] 2>/dev/null && pct=100
    local filled=$(( (pct + 16) / 17 )); [ $filled -gt 6 ] && filled=6
    local empty=$(( 6 - filled ))
    BAR_STR=""
    local i
    for ((i=0; i<filled; i++)); do BAR_STR+="▓"; done
    for ((i=0; i<empty;  i++)); do BAR_STR+="░"; done
    if   [ "$pct" -lt 50 ]; then BAR_COLOR="🟢"
    elif [ "$pct" -lt 80 ]; then BAR_COLOR="🟡"
    else                         BAR_COLOR="🔴"
    fi
}

# ── Read JSON input from stdin ────────────────────────────────────────────────
JSON=$(cat)

# ── Parse all stdin fields in a single jq call ───────────────────────────────
IFS='|' read -r J_MODEL_DISPLAY J_MODEL_RAW J_CTX_PCT J_CTX_SIZE J_COST J_DURATION J_CWD \
    < <(echo "$JSON" | jq -r '[
        (if .model | type == "object" then .model.display_name // "" else "" end),
        (if .model | type == "string" then .model else "" end),
        (.context_window.used_percentage // 0 | tostring | split(".")[0]),
        (.context_window.context_window_size // 0),
        (.cost.total_cost_usd // ""),
        (.cost.total_duration_ms // ""),
        (.workspace.current_dir // "")
    ] | join("|")' 2>/dev/null)

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

# ── Effort level (from settings.json — not yet in stdin JSON) ────────────────
EFFORT_LABEL=""
SETTINGS_FILE="$HOME/.claude/settings.json"
if [ -f "$SETTINGS_FILE" ]; then
    case "$(jq -r '.effortLevel // empty' "$SETTINGS_FILE" 2>/dev/null)" in
        low)    EFFORT_LABEL="lo" ;;
        medium) EFFORT_LABEL="md" ;;
        high)   EFFORT_LABEL="hi" ;;
        max)    EFFORT_LABEL="mx" ;;
    esac
fi

# ── Context window ────────────────────────────────────────────────────────────
CTX_PERCENT="${J_CTX_PCT:-0}"
CTX_LABEL="Ctx"
[ "$J_CTX_SIZE" -ge 900000 ] 2>/dev/null && CTX_LABEL="1M"

make_bar "$CTX_PERCENT"
CTX_COLOR="$BAR_COLOR" CTX_BAR="$BAR_STR"

# ── Session cost + duration ───────────────────────────────────────────────────
COST_STR="" DURATION_STR=""
if [ -n "$J_COST" ] && [ "$J_COST" != "0" ] && [ "$J_COST" != "null" ]; then
    COST_STR=$(printf '$%.2f' "$J_COST" 2>/dev/null)
fi
if [ -n "$J_DURATION" ] && [ "$J_DURATION" != "0" ] && [ "$J_DURATION" != "null" ]; then
    DURATION_STR=$(format_remaining $(( J_DURATION / 1000 )))
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
    echo "$resp" | jq '{
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
    }' > "${USAGE_FILE}.tmp" && mv "${USAGE_FILE}.tmp" "$USAGE_FILE"
}

LOCK_FILE="/tmp/statusline-refresh.lock"
if [ "$(cache_age_sec)" -gt "$REFRESH_INTERVAL" ]; then
    ( flock -n 9 || exit 0; refresh_usage_api ) 9>"$LOCK_FILE"
fi

# ── Read cached usage metrics ─────────────────────────────────────────────────
BLOCK_DISPLAY="" WEEK_SONNET_DISPLAY=""
NOW=$(date +%s)

if [ -f "$USAGE_FILE" ]; then
    # Single jq call to read all cache fields
    IFS='|' read -r CACHE_SOURCE U_SESS_PCT U_SESS_RESETS U_WEEK_PCT U_WEEK_RESETS U_SONNET_PCT \
        < <(jq -r '[
            (.source // "legacy"),
            (.metrics.session.percent_used     // ""),
            (.metrics.session.resets_at        // .metrics.session.resets // ""),
            (.metrics.week_all.percent_used    // ""),
            (.metrics.week_all.resets_at       // .metrics.week_all.resets // ""),
            (.metrics.week_sonnet.percent_used // "")
        ] | join("|")' "$USAGE_FILE" 2>/dev/null)

    if [ -n "$CACHE_SOURCE" ]; then
        # Session block
        if [ -n "$U_SESS_PCT" ] && [ "$U_SESS_PCT" != "null" ]; then
            SESS_INT="${U_SESS_PCT%.*}"
            REMAIN_STR=""
            RESET_EPOCH=""
            if [ -n "$U_SESS_RESETS" ] && [ "$U_SESS_RESETS" != "null" ]; then
                if [ "$CACHE_SOURCE" = "api" ]; then
                    RESET_EPOCH=$(iso_to_epoch "$U_SESS_RESETS")
                else
                    RESET_TZ=$(echo "$U_SESS_RESETS" | sed -n 's/.*(\([^)]*\)).*/\1/p')
                    [ -z "$RESET_TZ" ] && RESET_TZ="${TIMEZONE}"
                    RESET_TIME_STR=$(echo "$U_SESS_RESETS" | sed 's/ *([^)]*)//')
                    RESET_EPOCH=$(tz_date "${RESET_TZ}" -d "today $RESET_TIME_STR" +%s 2>/dev/null)
                    [ -n "$RESET_EPOCH" ] && [ "$RESET_EPOCH" -le "$NOW" ] && \
                        RESET_EPOCH=$(tz_date "${RESET_TZ}" -d "tomorrow $RESET_TIME_STR" +%s 2>/dev/null)
                fi
                if [ -n "$RESET_EPOCH" ] && [ "$RESET_EPOCH" -gt "$NOW" ]; then
                    REMAIN_STR=$(format_remaining $(( RESET_EPOCH - NOW )))
                elif [ -n "$RESET_EPOCH" ] && [ "$RESET_EPOCH" -le "$NOW" ]; then
                    # Session has reset since last API call — usage is back to ~0%
                    SESS_INT=0
                fi
            fi
            make_bar "$SESS_INT"
            if [ -n "$REMAIN_STR" ]; then
                BLOCK_DISPLAY="⏳ ${BAR_COLOR} ${BAR_STR} ${SESS_INT}% ↻ ${REMAIN_STR}"
            else
                BLOCK_DISPLAY="⏳ ${BAR_COLOR} ${BAR_STR} ${SESS_INT}%"
            fi
        fi

        # Weekly + Sonnet (opt-in)
        WEEK_INT="" WEEK_COLOR="" WEEK_RESET_LABEL="" SONNET_INT="" SONNET_COLOR=""
        if [ "$SHOW_WEEKLY" = "1" ] && [ -n "$U_WEEK_PCT" ] && [ "$U_WEEK_PCT" != "null" ]; then
            WEEK_INT="${U_WEEK_PCT%.*}"
            if [ -n "$U_WEEK_RESETS" ] && [ "$U_WEEK_RESETS" != "null" ]; then
                if [ "$CACHE_SOURCE" = "api" ]; then
                    WEEK_EPOCH=$(iso_to_epoch "$U_WEEK_RESETS")
                else
                    WEEK_TZ=$(echo "$U_WEEK_RESETS" | sed -n 's/.*(\([^)]*\)).*/\1/p')
                    [ -z "$WEEK_TZ" ] && WEEK_TZ="${TIMEZONE}"
                    DATE_PART=$(echo "$U_WEEK_RESETS" | sed 's/ *([^)]*)//' | sed 's/,//')
                    WEEK_EPOCH=$(tz_date "${WEEK_TZ}" -d "$DATE_PART" +%s 2>/dev/null)
                fi
                [ -n "$WEEK_EPOCH" ] && \
                    WEEK_RESET_LABEL=$(tz_date "${TIMEZONE}" -d "@$WEEK_EPOCH" +"%a %Hh" 2>/dev/null \
                        | tr '[:upper:]' '[:lower:]')
            fi
            make_bar "$WEEK_INT"; WEEK_COLOR="$BAR_COLOR"
        fi
        if [ "$SHOW_WEEKLY" = "1" ] && [ -n "$U_SONNET_PCT" ] && [ "$U_SONNET_PCT" != "null" ]; then
            SONNET_INT="${U_SONNET_PCT%.*}"
            make_bar "$SONNET_INT"; SONNET_COLOR="$BAR_COLOR"
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
fi

# ── Stale indicator — replace color dot with ⚠ when cache is stale ──────────
IS_STALE=0
if [ -f "$USAGE_FILE" ] && [ "$REFRESH_INTERVAL" -gt 0 ] 2>/dev/null; then
    [ "$(cache_age_sec)" -gt $(( REFRESH_INTERVAL * 3 )) ] && IS_STALE=1
fi
[ "$IS_STALE" = 1 ] && [ -n "$BLOCK_DISPLAY" ] && \
    BLOCK_DISPLAY=$(echo "$BLOCK_DISPLAY" | sed 's/🟢\|🟡\|🔴/⚠/')

# ── Assemble ──────────────────────────────────────────────────────────────────
PARTS=()
[ -n "$BRANCH" ] && PARTS+=("🌿 $BRANCH$DIRTY")
if [ -n "$MODEL" ] && [ -n "$EFFORT_LABEL" ]; then
    PARTS+=("$MODEL/$EFFORT_LABEL")
elif [ -n "$MODEL" ]; then
    PARTS+=("$MODEL")
fi
[ -n "$CTX_PERCENT" ]         && PARTS+=("$CTX_COLOR $CTX_LABEL $CTX_BAR ${CTX_PERCENT}%")
[ -n "$BLOCK_DISPLAY" ]       && PARTS+=("$BLOCK_DISPLAY")
[ -n "$WEEK_SONNET_DISPLAY" ] && PARTS+=("$WEEK_SONNET_DISPLAY")
# Cost + duration (only if non-zero)
if [ -n "$COST_STR" ] && [ -n "$DURATION_STR" ]; then
    PARTS+=("$COST_STR ⏱ $DURATION_STR")
elif [ -n "$COST_STR" ]; then
    PARTS+=("$COST_STR")
fi

RESULT=""
for part in "${PARTS[@]}"; do
    [ -z "$RESULT" ] && RESULT="$part" || RESULT="$RESULT │ $part"
done

echo "${RESULT}${REFRESH_SUFFIX}"
