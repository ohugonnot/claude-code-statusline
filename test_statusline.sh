#!/bin/bash
# Tests for statusline.sh
# shellcheck disable=SC1090  # source <(sed ...) — dynamic, can't be followed
# shellcheck disable=SC2016  # single-quoted '$1.50' etc. are intentional literal assertions

STATUSLINE_SH="$(dirname "$(realpath "$0")")/statusline.sh"
PASS=0; FAIL=0

# Track temp files for cleanup
TMPFILES=()
cleanup_tests() {
    for f in "${TMPFILES[@]}"; do rm -f "$f"; done
}
trap cleanup_tests EXIT INT TERM

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$actual" = "$expected" ]; then
        echo "  ✓ $desc"; ((PASS++))
    else
        echo "  ✗ $desc"
        echo "    expected: $expected"
        echo "    actual:   $actual"
        ((FAIL++))
    fi
}

assert_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if echo "$haystack" | grep -qF "$needle"; then
        echo "  ✓ $desc"; ((PASS++))
    else
        echo "  ✗ $desc"
        echo "    expected to contain: $needle"
        echo "    actual: $haystack"
        ((FAIL++))
    fi
}

assert_not_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if ! echo "$haystack" | grep -qF "$needle"; then
        echo "  ✓ $desc"; ((PASS++))
    else
        echo "  ✗ $desc"
        echo "    expected NOT to contain: $needle"
        echo "    actual: $haystack"
        ((FAIL++))
    fi
}

assert_absent() {  # fail if <path> exists — for injection canaries
    local desc="$1" path="$2"
    if [ -e "$path" ]; then
        echo "  ✗ $desc (canary $path was created)"; ((FAIL++))
    else
        echo "  ✓ $desc"; ((PASS++))
    fi
}

# ── Unit tests: make_bar ──────────────────────────────────────────────────────
echo ""
echo "=== Unit tests: make_bar ==="

# Source every helper (config + functions) up to the stdin read — robust against
# refactors, unlike extracting a single function by name with awk. LC_ALL=C and
# an ASCII sentinel keep BSD sed (macOS) from aborting on the file's UTF-8
# box-drawing chars under a C-locale CI runner ("illegal byte sequence").
source <(LC_ALL=C sed '/^JSON=/,$d' "$STATUSLINE_SH")

run_make_bar() {
    BAR_STR=""; BAR_COLOR=""
    make_bar "$1"
}

count_char() {
    local char="$1" str="$2"
    echo -n "$str" | grep -o "$char" | wc -l
}

# pct=0 → 6 empty blocks
run_make_bar 0
assert_eq "pct=0: all empty" "░░░░░░" "$BAR_STR"

# pct=100 → 6 full blocks
run_make_bar 100
assert_eq "pct=100: all full" "▓▓▓▓▓▓" "$BAR_STR"

# pct=50 → 3 full blocks
run_make_bar 50
FULL_COUNT=$(count_char "▓" "$BAR_STR")
assert_eq "pct=50: 3 full blocks" "3" "$FULL_COUNT"

# pct=25 → 2 full blocks
run_make_bar 25
FULL_COUNT=$(count_char "▓" "$BAR_STR")
assert_eq "pct=25: 2 full blocks" "2" "$FULL_COUNT"

# Total bar length is always 6
for pct in 0 1 17 34 50 68 85 99 100; do
    run_make_bar $pct
    TOTAL=$(count_char "▓" "$BAR_STR")
    TOTAL=$((TOTAL + $(count_char "░" "$BAR_STR")))
    assert_eq "pct=$pct: total bar length 6" "6" "$TOTAL"
done

# Color thresholds
run_make_bar 0;   assert_eq "pct=0: green"    "🟢" "$BAR_COLOR"
run_make_bar 49;  assert_eq "pct=49: green"   "🟢" "$BAR_COLOR"
run_make_bar 50;  assert_eq "pct=50: yellow"  "🟡" "$BAR_COLOR"
run_make_bar 79;  assert_eq "pct=79: yellow"  "🟡" "$BAR_COLOR"
run_make_bar 80;  assert_eq "pct=80: red"     "🔴" "$BAR_COLOR"
run_make_bar 100; assert_eq "pct=100: red"    "🔴" "$BAR_COLOR"

echo ""
echo "-- Edge cases --"
run_make_bar 1
assert_contains "pct=1: has filled block" "▓" "$BAR_STR"

# ── Unit tests: num (security — arithmetic injection guard) ──────────────────
echo ""
echo "=== Unit tests: num ==="
assert_eq "num strips decimal"        "46" "$(num 46.0)"
assert_eq "num plain integer"         "42" "$(num 42)"
assert_eq "num leading zero (octal)"  "8"  "$(num 08)"
assert_eq "num empty → 0"             "0"  "$(num '')"
assert_eq "num non-numeric → 0"       "0"  "$(num 'abc')"
# An arithmetic-injection payload must be rendered inert (no $() survives)
assert_eq "num neutralizes injection" "0"  "$(num 'x[$(touch /tmp/should-not-exist-$$)]')"
assert_absent "num did not execute payload" "/tmp/should-not-exist-$$"

# ── Unit tests: format_remaining ──────────────────────────────────────────────
echo ""
echo "=== Unit tests: format_remaining ==="
assert_eq "format_remaining 0 → empty" ""      "$(format_remaining 0)"
assert_eq "format_remaining 59s → <1m" "<1m"   "$(format_remaining 59)"
assert_eq "format_remaining 90s → 1m"  "1m"    "$(format_remaining 90)"
assert_eq "format_remaining 1h2m"      "1h2m"  "$(format_remaining 3720)"

# ── Integration tests ─────────────────────────────────────────────────────────
echo ""
echo "=== Integration tests ==="

run_statusline() {
    local json="$1"; shift
    echo "$json" | env "$@" CREDENTIALS_FILE=/dev/null bash "$STATUSLINE_SH" 2>/dev/null
}

# Portable helpers (GNU coreutils on Linux / BSD on macOS) so the suite is green
# on both CI runners.
touch_ago() {  # <minutes> <file> — set mtime N minutes in the past
    local ts
    ts=$(date -d "$1 minutes ago" '+%Y%m%d%H%M.%S' 2>/dev/null || date -v-"$1"M '+%Y%m%d%H%M.%S')
    touch -t "$ts" "$2"
}
iso_in() {  # <±N hours> → UTC ISO 8601 with +00:00 offset, N hours from now
    date -u -d "$1 hours" '+%Y-%m-%dT%H:%M:%S+00:00' 2>/dev/null \
        || date -u -v"${1}"H '+%Y-%m-%dT%H:%M:%S+00:00'
}
epoch_in() {  # <±N hours> → Unix epoch seconds, N hours from now
    date -d "$1 hours" +%s 2>/dev/null || date -v"${1}"H +%s
}

# Test 1 — model + context window
echo ""
echo "-- Test 1: model + context window --"
OUT=$(run_statusline '{"model": "claude-sonnet-4-6", "context_window": {"used_percentage": 34.5}}' \
    USAGE_FILE=/dev/null)
assert_contains "model name" "Snt 4.6" "$OUT"
assert_contains "34%" "34%" "$OUT"

# Test 2 — Opus model + git branch
echo ""
echo "-- Test 2: Opus model + git branch --"
REPO_DIR="$(dirname "$(realpath "$0")")"
GIT_BRANCH=$(git -C "$REPO_DIR" symbolic-ref --short HEAD 2>/dev/null)
OUT=$(run_statusline "{\"model\": \"claude-opus-4-6\", \"context_window\": {\"used_percentage\": 0}, \"workspace\": {\"current_dir\": \"$REPO_DIR\"}}" \
    USAGE_FILE=/dev/null)
assert_contains "Opus 4.6" "Opus 4.6" "$OUT"
if [ -n "$GIT_BRANCH" ]; then
    assert_contains "git branch '$GIT_BRANCH'" "$GIT_BRANCH" "$OUT"
fi

# Test 3 — Legacy cache with session + week_all
echo ""
echo "-- Test 3: legacy cache --"
USAGE_TMP=$(mktemp /tmp/test-usage-XXXX.json); TMPFILES+=("$USAGE_TMP")
cat > "$USAGE_TMP" <<'JSON'
{"timestamp":"2026-02-21T10:00:00+00:00","source":"/usage","metrics":{"session":{"percent_used":46.0,"percent_remaining":54.0,"resets":null},"week_all":{"percent_used":59.0,"percent_remaining":41.0,"resets":null}}}
JSON
OUT=$(run_statusline '{"model":"claude-sonnet-4-6","context_window":{"used_percentage":0}}' \
    USAGE_FILE="$USAGE_TMP" REFRESH_INTERVAL=999999 SHOW_WEEKLY=1)
assert_contains "session 46%" "46%" "$OUT"
assert_contains "week_all 59%" "59%" "$OUT"
assert_not_contains "session pct has no decimal" "46.0" "$OUT"

# Test 4 — API cache with ISO 8601 resets_at
echo ""
echo "-- Test 4: API cache with ISO 8601 --"
USAGE_API=$(mktemp /tmp/test-usage-api-XXXX.json); TMPFILES+=("$USAGE_API")
FUTURE=$(iso_in +3)
cat > "$USAGE_API" <<JSON
{"timestamp":"2026-02-21T10:00:00Z","source":"api","metrics":{"session":{"percent_used":35.0,"percent_remaining":65.0,"resets_at":"$FUTURE"},"week_all":{"percent_used":22.0,"percent_remaining":78.0,"resets_at":"2026-04-02T13:00:00+00:00"},"week_sonnet":{"percent_used":15.0,"percent_remaining":85.0,"resets_at":"2026-04-02T13:00:00+00:00"}}}
JSON
OUT=$(run_statusline '{"model":"claude-sonnet-4-6","context_window":{"used_percentage":0}}' \
    USAGE_FILE="$USAGE_API" REFRESH_INTERVAL=999999 SHOW_WEEKLY=1)
assert_contains "API session 35%" "35%" "$OUT"
assert_contains "API week_all 22%" "22%" "$OUT"
assert_contains "API sonnet 15%" "15%" "$OUT"
# Anchor the countdown to the session block — a bare "h" also matches the week label
assert_contains "session countdown present" "35% ↻" "$OUT"

# Test 5 — Stale cache shows ⚠
echo ""
echo "-- Test 5: stale cache --"
USAGE_STALE=$(mktemp /tmp/test-usage-stale-XXXX.json); TMPFILES+=("$USAGE_STALE")
echo '{"timestamp":"2026-02-21T09:00:00+00:00","source":"api","metrics":{"session":{"percent_used":30.0,"percent_remaining":70.0,"resets_at":null}}}' > "$USAGE_STALE"
touch_ago 30 "$USAGE_STALE"
OUT=$(run_statusline '{"model":"claude-sonnet-4-6","context_window":{"used_percentage":0}}' \
    USAGE_FILE="$USAGE_STALE" REFRESH_INTERVAL=300)
assert_contains "stale cache shows ⚠" "⚠" "$OUT"

# Test 6 — Fresh cache does NOT show ⚠
echo ""
echo "-- Test 6: fresh cache no ⚠ --"
USAGE_FRESH=$(mktemp /tmp/test-usage-fresh-XXXX.json); TMPFILES+=("$USAGE_FRESH")
echo '{"timestamp":"2026-02-21T10:00:00+00:00","source":"api","metrics":{"session":{"percent_used":20.0,"percent_remaining":80.0,"resets_at":null}}}' > "$USAGE_FRESH"
OUT=$(run_statusline '{"model":"claude-sonnet-4-6","context_window":{"used_percentage":0}}' \
    USAGE_FILE="$USAGE_FRESH" REFRESH_INTERVAL=300)
assert_not_contains "fresh cache no ⚠" "⚠" "$OUT"

# Test 7 — REFRESH_INTERVAL=0 never shows ⚠
echo ""
echo "-- Test 7: REFRESH_INTERVAL=0 no stale indicator --"
touch_ago 30 "$USAGE_STALE"
OUT=$(run_statusline '{"model":"claude-sonnet-4-6","context_window":{"used_percentage":0}}' \
    USAGE_FILE="$USAGE_STALE" REFRESH_INTERVAL=0)
assert_not_contains "interval=0 no ⚠" "⚠" "$OUT"

# Test 8 — week_sonnet shown with SHOW_WEEKLY=1
echo ""
echo "-- Test 8: week_sonnet --"
USAGE_SNT=$(mktemp /tmp/test-usage-snt-XXXX.json); TMPFILES+=("$USAGE_SNT")
echo '{"timestamp":"2026-02-21T10:00:00+00:00","source":"api","metrics":{"week_sonnet":{"percent_used":72.0,"percent_remaining":28.0,"resets_at":null}}}' > "$USAGE_SNT"
OUT=$(run_statusline '{"model":"claude-sonnet-4-6","context_window":{"used_percentage":0}}' \
    USAGE_FILE="$USAGE_SNT" REFRESH_INTERVAL=999999 SHOW_WEEKLY=1)
assert_contains "sonnet 72%" "72%" "$OUT"
assert_contains "Snt label" "Snt" "$OUT"

# Test 9 — Haiku model
echo ""
echo "-- Test 9: Haiku model --"
OUT=$(run_statusline '{"model":"claude-haiku-4-5-20251001","context_window":{"used_percentage":10}}' \
    USAGE_FILE=/dev/null)
assert_contains "Haiku 4" "Haiku 4" "$OUT"

# Test 10 — Default() unwrap
echo ""
echo "-- Test 10: Default() unwrap --"
OUT=$(run_statusline '{"model":{"display_name":"Default (Claude Sonnet 4.5)"},"context_window":{"used_percentage":0}}' \
    USAGE_FILE=/dev/null)
assert_contains "unwraps to Snt 4.5" "Snt 4.5" "$OUT"

# Test 11 — Context bar 0% / 100%
echo ""
echo "-- Test 11: context bars --"
OUT=$(run_statusline '{"model":"claude-sonnet-4-6","context_window":{"used_percentage":0}}' USAGE_FILE=/dev/null)
assert_contains "0% all empty" "░░░░░░" "$OUT"
OUT=$(run_statusline '{"model":"claude-sonnet-4-6","context_window":{"used_percentage":100}}' USAGE_FILE=/dev/null)
assert_contains "100% all full" "▓▓▓▓▓▓" "$OUT"

# Test 12 — Missing usage file
echo ""
echo "-- Test 12: no cache --"
OUT=$(run_statusline '{"model":"claude-sonnet-4-6","context_window":{"used_percentage":20}}' \
    USAGE_FILE=/tmp/nonexistent-xxxxx.json)
assert_not_contains "no ⏳" "⏳" "$OUT"
assert_not_contains "no 📅" "📅" "$OUT"

# Test 13 — Branch emoji present
echo ""
echo "-- Test 13: branch emoji --"
OUT=$(run_statusline "{\"model\":\"claude-sonnet-4-6\",\"context_window\":{\"used_percentage\":0},\"workspace\":{\"current_dir\":\"$REPO_DIR\"}}" \
    USAGE_FILE=/dev/null)
assert_contains "🌿 present" "🌿" "$OUT"

# Test 14 — All metrics together
echo ""
echo "-- Test 14: all metrics --"
USAGE_ALL=$(mktemp /tmp/test-usage-all-XXXX.json); TMPFILES+=("$USAGE_ALL")
echo '{"timestamp":"2026-02-21T10:00:00+00:00","source":"api","metrics":{"session":{"percent_used":30.0,"percent_remaining":70.0,"resets_at":null},"week_all":{"percent_used":60.0,"percent_remaining":40.0,"resets_at":null},"week_sonnet":{"percent_used":45.0,"percent_remaining":55.0,"resets_at":null}}}' > "$USAGE_ALL"
OUT=$(run_statusline '{"model":"claude-sonnet-4-6","context_window":{"used_percentage":10}}' \
    USAGE_FILE="$USAGE_ALL" REFRESH_INTERVAL=999999 SHOW_WEEKLY=1)
assert_contains "session 30%" "30%" "$OUT"
assert_contains "week 60%" "60%" "$OUT"
assert_contains "sonnet 45%" "45%" "$OUT"
assert_contains "separator" "│" "$OUT"

# Test 15 — Parenthetical stripped
echo ""
echo "-- Test 15: strip parenthetical --"
OUT=$(run_statusline '{"model":{"display_name":"Claude Opus 4.6 (some info)"},"context_window":{"used_percentage":0}}' \
    USAGE_FILE=/dev/null)
assert_contains "Opus 4.6" "Opus 4.6" "$OUT"
assert_not_contains "no parens" "(some info)" "$OUT"

# Test 16 — Cost + duration
echo ""
echo "-- Test 16: cost + duration --"
OUT=$(run_statusline '{"model":"claude-sonnet-4-6","context_window":{"used_percentage":20},"cost":{"total_cost_usd":1.234,"total_duration_ms":3720000}}' \
    USAGE_FILE=/dev/null)
assert_contains "cost shown" '$1.23' "$OUT"
assert_contains "duration shown" "⏱" "$OUT"
assert_contains "duration value" "1h2m" "$OUT"

# Test 17 — No cost when zero
echo ""
echo "-- Test 17: no cost when zero --"
OUT=$(run_statusline '{"model":"claude-sonnet-4-6","context_window":{"used_percentage":20},"cost":{"total_cost_usd":0,"total_duration_ms":0}}' \
    USAGE_FILE=/dev/null)
assert_not_contains "no dollar" '$' "$OUT"
assert_not_contains "no timer" "⏱" "$OUT"

# Test 18 — 1M context label
echo ""
echo "-- Test 18: 1M context label --"
OUT=$(run_statusline '{"model":"claude-opus-4-6","context_window":{"used_percentage":30,"context_window_size":1000000}}' \
    USAGE_FILE=/dev/null)
assert_contains "1M label" "1M" "$OUT"
assert_not_contains "no Ctx label" "Ctx" "$OUT"

# Test 19 — Regular context stays "Ctx"
echo ""
echo "-- Test 19: Ctx label for 200k --"
OUT=$(run_statusline '{"model":"claude-sonnet-4-6","context_window":{"used_percentage":30,"context_window_size":200000}}' \
    USAGE_FILE=/dev/null)
assert_contains "Ctx label" "Ctx" "$OUT"

# Test 20 — Native stdin rate_limits are preferred over the cache, and never stale
echo ""
echo "-- Test 20: native stdin rate_limits preferred --"
USAGE_OLD=$(mktemp /tmp/test-usage-old-XXXX.json); TMPFILES+=("$USAGE_OLD")
echo '{"source":"api","metrics":{"session":{"percent_used":88.0,"percent_remaining":12.0,"resets_at":null}}}' > "$USAGE_OLD"
touch_ago 60 "$USAGE_OLD"   # stale cache that must be ignored
FUTURE_EPOCH=$(epoch_in +2)
OUT=$(run_statusline "{\"model\":\"claude-sonnet-4-6\",\"context_window\":{\"used_percentage\":0},\"rate_limits\":{\"five_hour\":{\"used_percentage\":12,\"resets_at\":$FUTURE_EPOCH}}}" \
    USAGE_FILE="$USAGE_OLD" REFRESH_INTERVAL=300)
assert_contains "uses stdin 12%" "12%" "$OUT"
assert_not_contains "ignores cache 88%" "88%" "$OUT"
assert_not_contains "stdin source never stale" "⚠" "$OUT"

# Test 20b — stdin session WITHOUT resets_at keeps the live %, must not zero it
OUT=$(run_statusline '{"model":"claude-sonnet-4-6","context_window":{"used_percentage":0},"rate_limits":{"five_hour":{"used_percentage":42}}}' \
    USAGE_FILE=/dev/null REFRESH_INTERVAL=999999)
assert_contains "stdin pct kept without resets_at" "⏳ 🟢 ▓▓▓░░░ 42%" "$OUT"
assert_not_contains "session not zeroed without resets_at" "⏳ 🟢 ░░░░░░ 0%" "$OUT"

# Test 21 — Session resets to 0% once resets_at is in the past
echo ""
echo "-- Test 21: session reset to 0% after window rolls over --"
PAST_EPOCH=$(epoch_in -1)
OUT=$(run_statusline "{\"model\":\"claude-sonnet-4-6\",\"context_window\":{\"used_percentage\":0},\"rate_limits\":{\"five_hour\":{\"used_percentage\":75,\"resets_at\":$PAST_EPOCH}}}" \
    USAGE_FILE=/dev/null REFRESH_INTERVAL=999999)
assert_not_contains "stale 75% suppressed" "75%" "$OUT"
assert_contains "session shows 0% after reset" "⏳ 🟢 ░░░░░░ 0%" "$OUT"

# Test 22 — SHOW_WEEKLY=0 (default) hides weekly data even when present in cache
echo ""
echo "-- Test 22: SHOW_WEEKLY=0 hides weekly --"
USAGE_HIDE=$(mktemp /tmp/test-usage-hide-XXXX.json); TMPFILES+=("$USAGE_HIDE")
echo '{"source":"api","metrics":{"session":{"percent_used":30.0,"resets_at":null},"week_all":{"percent_used":99.0,"resets_at":null}}}' > "$USAGE_HIDE"
OUT=$(run_statusline '{"model":"claude-sonnet-4-6","context_window":{"used_percentage":0}}' \
    USAGE_FILE="$USAGE_HIDE" REFRESH_INTERVAL=999999 SHOW_WEEKLY=0)
assert_not_contains "weekly emoji hidden" "📅" "$OUT"
assert_not_contains "week 99% hidden" "99%" "$OUT"

# Test 23 — EFFORT_LABEL from settings.json
echo ""
echo "-- Test 23: effort label --"
SETTINGS_TMP=$(mktemp /tmp/test-settings-XXXX.json); TMPFILES+=("$SETTINGS_TMP")
echo '{"effortLevel":"max"}' > "$SETTINGS_TMP"
OUT=$(run_statusline '{"model":"claude-sonnet-4-6","context_window":{"used_percentage":0}}' \
    USAGE_FILE=/dev/null SETTINGS_FILE="$SETTINGS_TMP")
assert_contains "effort max → /mx" "/mx" "$OUT"
OUT=$(run_statusline '{"model":"claude-sonnet-4-6","context_window":{"used_percentage":0}}' \
    USAGE_FILE=/dev/null SETTINGS_FILE=/dev/null)
assert_not_contains "no effort suffix when absent" "Snt 4.6/" "$OUT"

# Test 24 — Injection regression: malicious cache value must not execute
echo ""
echo "-- Test 24: arithmetic injection neutralized --"
CANARY="/tmp/statusline-pwned-$$"; rm -f "$CANARY"
USAGE_EVIL=$(mktemp /tmp/test-usage-evil-XXXX.json); TMPFILES+=("$USAGE_EVIL")
printf '{"source":"api","metrics":{"session":{"percent_used":"x[$(touch %s)]","resets_at":null}}}' "$CANARY" > "$USAGE_EVIL"
OUT=$(run_statusline '{"model":"claude-sonnet-4-6","context_window":{"used_percentage":42}}' \
    USAGE_FILE="$USAGE_EVIL" REFRESH_INTERVAL=999999)
assert_absent "payload did not execute" "$CANARY"
rm -f "$CANARY"

# Test 25 — Pipe in a field does not corrupt parsing (US-separator regression)
echo ""
echo "-- Test 25: pipe in model name stays intact --"
OUT=$(run_statusline '{"model":{"display_name":"Foo|Bar"},"context_window":{"used_percentage":42},"cost":{"total_cost_usd":1.5}}' \
    USAGE_FILE=/dev/null)
assert_contains "ctx still 42%" "42%" "$OUT"
assert_contains "cost still parsed" '$1.50' "$OUT"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ $FAIL -eq 0 ] && exit 0 || exit 1
