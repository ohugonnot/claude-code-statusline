#!/bin/bash
# ════════════════════════════════════════════════════════════════════════════
# Tests for the sections ported from cc-statusline: plain style, context tokens,
# burn rate, session counter, and the API-skip guard.
#
# test_statusline.sh remains the oracle for upstream behavior. This file only
# covers what the port added.
# ════════════════════════════════════════════════════════════════════════════
# shellcheck disable=SC2016  # single-quoted '$0.42' is an intentional literal pattern
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATUSLINE="$SCRIPT_DIR/statusline.sh"

PASS=0
FAIL=0

ok()   { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad()  { echo "  ✗ $1"; echo "      got: $2"; FAIL=$((FAIL + 1)); }

assert_contains() {
    case "$2" in
        *"$1"*) ok "$3" ;;
        *)      bad "$3" "$2" ;;
    esac
}

assert_absent() {
    case "$2" in
        *"$1"*) bad "$3" "$2" ;;
        *)      ok "$3" ;;
    esac
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# ── Fixtures ──────────────────────────────────────────────────────────────────
NOW=$(date +%s)
RESET=$(( NOW + 7200 ))

payload() {
    # $1 = extra jq filter applied on top of the base payload.
    # The heredoc must stay literal JSON — jq variables only exist in the filter —
    # so the reset epoch and transcript path are injected by the filter itself.
    jq -c --argjson reset "$RESET" --arg transcript "${TRANSCRIPT:-}" '
        .transcript_path = $transcript
        | .rate_limits.five_hour.resets_at = $reset
        | .rate_limits.seven_day.resets_at = $reset
        | '"${1:-.}" <<'EOF'
{
  "workspace": { "current_dir": "/home/someone/my-project" },
  "model": { "display_name": "Opus 5" },
  "transcript_path": "",
  "context_window": {
    "total_input_tokens": 194250,
    "context_window_size": 1000000,
    "used_percentage": 19
  },
  "cost": { "total_cost_usd": 0.42, "total_duration_ms": 3840000 },
  "rate_limits": {
    "five_hour": { "used_percentage": 47, "resets_at": 0 },
    "seven_day": { "used_percentage": 84, "resets_at": 0 }
  }
}
EOF
}

# A transcript holding 2 distinct assistant messages, each logged 3 times, as the
# real transcripts do. 1000 billable tokens per distinct message.
make_transcript() {
    local file="$1" iso
    iso=$(date -u -d "@$NOW" +"%Y-%m-%dT%H:%M:%S.000Z" 2>/dev/null \
        || date -u -r "$NOW" +"%Y-%m-%dT%H:%M:%S.000Z")
    : > "$file"
    local id
    for id in msg_aaa msg_bbb; do
        for _ in 1 2 3; do
            printf '{"type":"assistant","timestamp":"%s","message":{"id":"%s","usage":{"input_tokens":100,"cache_creation_input_tokens":400,"cache_read_input_tokens":190000,"output_tokens":500}}}\n' \
                "$iso" "$id" >> "$file"
        done
    done
}

run() {
    # run <env assignments...> -- <payload filter>
    local envs=() filter="."
    while [ $# -gt 0 ]; do
        if [ "$1" = "--" ]; then shift; filter="${1:-.}"; break; fi
        envs+=("$1"); shift
    done
    payload "$filter" | env "${envs[@]}" bash "$STATUSLINE" 2>/dev/null
}

echo "-- Test 1: plain style carries no emoji --"
TRANSCRIPT=""
OUT=$(run STATUSLINE_STYLE=plain SHOW_WEEKLY=1 SHOW_SONNET=0 SHOW_BRANCH=0 SHOW_MODEL=0)
for emoji in "🟢" "🟡" "🔴" "⏳" "📅" "🌿" "⏱" "│"; do
    assert_absent "$emoji" "$OUT" "no $emoji in plain style"
done
assert_contains "5h [" "$OUT" "5h quota labelled"
assert_contains "7d [" "$OUT" "7d quota labelled"
assert_contains "█" "$OUT" "plain bars use full blocks"

echo "-- Test 2: emoji style still the default --"
OUT=$(run SHOW_WEEKLY=1 SHOW_SONNET=0)
assert_contains "⏳" "$OUT" "session emoji present by default"
assert_absent "5h [" "$OUT" "no plain label in emoji style"

echo "-- Test 3: context tokens instead of a bare percentage --"
OUT=$(run STATUSLINE_STYLE=plain SHOW_CONTEXT_TOKENS=1)
assert_contains "194k/1000k" "$OUT" "context rendered as tokens over window size"
OUT=$(run STATUSLINE_STYLE=plain SHOW_CONTEXT_TOKENS=0)
assert_contains "19%" "$OUT" "percentage kept when tokens are off"

echo "-- Test 4: bar width follows BAR_BLOCKS --"
OUT=$(run STATUSLINE_STYLE=plain BAR_BLOCKS=10 SHOW_CONTEXT_TOKENS=0 SHOW_BRANCH=0 SHOW_MODEL=0)
BAR=$(printf '%s' "$OUT" | sed -n 's/.*5h \[\([█░]*\)\].*/\1/p')
if [ "$(printf '%s' "$BAR" | wc -m | tr -d ' ')" = "10" ]; then
    ok "5h bar is 10 blocks wide"
else
    bad "5h bar is 10 blocks wide" "width=$(printf '%s' "$BAR" | wc -m | tr -d ' ') bar=$BAR"
fi

echo "-- Test 5: burn rate deduplicates on message.id --"
TRANSCRIPT="$TMP/transcript.jsonl"
make_transcript "$TRANSCRIPT"
OUT=$(run STATUSLINE_STYLE=plain SHOW_BURN_RATE=1 BURN_WINDOW_MIN=10 SHOW_BRANCH=0 SHOW_MODEL=0)
# 2 distinct messages × (100 input + 400 cache_creation + 500 output) = 2000 tokens
# over a 10-minute window = 200/min. Without dedup the 6 logged lines would give
# 6000 / 10 = 600/min.
assert_contains "200/min" "$OUT" "rate counts each message once"
assert_absent "600/min" "$OUT" "duplicated lines are not summed"

echo "-- Test 6: cache_read excluded from the rate --"
# 190000 cache_read per message would put the rate in the tens of thousands.
assert_absent "k/min" "$OUT" "cache reads do not inflate the rate"

echo "-- Test 7: burn rate absent without a transcript --"
TRANSCRIPT="$TMP/does-not-exist.jsonl"
OUT=$(run STATUSLINE_STYLE=plain SHOW_BURN_RATE=1)
assert_absent "/min" "$OUT" "no rate segment when the transcript is missing"

echo "-- Test 8: session counter --"
TRANSCRIPT=""
mkdir -p "$TMP/projects/alpha" "$TMP/projects/beta"
touch "$TMP/projects/alpha/one.jsonl" "$TMP/projects/alpha/two.jsonl" "$TMP/projects/beta/one.jsonl"
OUT=$(run STATUSLINE_STYLE=plain SHOW_SESSIONS=1 "PROJECTS_DIR=$TMP/projects" SESSION_ACTIVE_MIN=5)
assert_contains "×2" "$OUT" "two project directories counted once each"

echo "-- Test 9: directory name --"
OUT=$(run STATUSLINE_STYLE=plain SHOW_DIR=1)
assert_contains "my-project" "$OUT" "directory basename shown"
OUT=$(run STATUSLINE_STYLE=plain SHOW_DIR=0)
assert_absent "my-project" "$OUT" "directory hidden when off"

echo "-- Test 10: SHOW_SONNET=0 makes no network call --"
# A curl shim on PATH records any invocation. With both windows on stdin and the
# Sonnet quota not requested, nothing should reach the network.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/curl" <<'SHIM'
#!/bin/bash
touch "$CURL_MARKER"
exit 1
SHIM
chmod +x "$TMP/bin/curl"
rm -f "$TMP/curl-called"
OUT=$(payload | env "PATH=$TMP/bin:$PATH" "CURL_MARKER=$TMP/curl-called" \
    STATUSLINE_STYLE=plain SHOW_WEEKLY=1 SHOW_SONNET=0 REFRESH_INTERVAL=0 \
    "USAGE_FILE=$TMP/usage.json" bash "$STATUSLINE" 2>/dev/null)
if [ -f "$TMP/curl-called" ]; then
    bad "no curl with SHOW_SONNET=0" "curl was invoked"
else
    ok "no curl with SHOW_SONNET=0"
fi
assert_contains "7d [" "$OUT" "7d still rendered from stdin"

echo "-- Test 11: branch, model and cost segments toggle --"
# Single-quoted: "$0.42" in double quotes would expand $0 to this script's name
# and the assertion would pass vacuously against a pattern that is never present.
OUT=$(run STATUSLINE_STYLE=plain SHOW_MODEL=0 SHOW_COST=0)
assert_absent "Opus 5" "$OUT" "model hidden when off"
assert_absent '$0.42' "$OUT" "cost hidden when off"
OUT=$(run STATUSLINE_STYLE=plain SHOW_MODEL=1 SHOW_COST=1)
assert_contains '$0.42' "$OUT" "cost shown when on"
assert_contains "1h4m" "$OUT" "session duration shown alongside cost"

echo "-- Test 12: no branch segment outside a repository --"
OUT=$(run STATUSLINE_STYLE=plain SHOW_BRANCH=1 -- '.workspace.current_dir = "/"')
assert_absent "(no git)" "$OUT" "no placeholder branch in plain style"
OUT=$(run SHOW_BRANCH=1 -- '.workspace.current_dir = "/"')
assert_contains "(no git)" "$OUT" "emoji style keeps the upstream placeholder"

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
