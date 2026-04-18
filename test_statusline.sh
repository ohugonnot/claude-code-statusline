#!/bin/bash
# Tests for statusline.sh

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

# Portable "touch to N minutes ago" — `touch -d '30 minutes ago'` works on GNU
# coreutils but not on BSD (macOS), which only accepts a fixed timestamp format
# via `-t`. Compute the timestamp with whichever `date` dialect is available.
touch_minutes_ago() {
    local minutes="$1" file="$2" ts
    ts=$(date -d "$minutes minutes ago" +%Y%m%d%H%M.%S 2>/dev/null) \
        || ts=$(date -v "-${minutes}M" +%Y%m%d%H%M.%S)
    touch -t "$ts" "$file"
}

# ── Unit tests: make_bar ──────────────────────────────────────────────────────
echo ""
echo "=== Unit tests: make_bar ==="

# Extract make_bar function from statusline.sh and source it
eval "$(awk '/^make_bar\(\)/,/^\}/' "$STATUSLINE_SH")"

run_make_bar() {
    BAR_STR=""; BAR_COLOR=""
    make_bar "$1"
}

count_char() {
    local char="$1" str="$2"
    # BSD `wc -l` right-pads the count with whitespace; GNU does not. Strip it
    # so downstream string comparisons work on both.
    echo -n "$str" | grep -o "$char" | wc -l | tr -d ' '
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

# ── Integration tests ─────────────────────────────────────────────────────────
echo ""
echo "=== Integration tests ==="

run_statusline() {
    local json="$1"; shift
    echo "$json" | env "$@" CREDENTIALS_FILE=/dev/null bash "$STATUSLINE_SH" 2>/dev/null
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

# Test 4 — API cache with ISO 8601 resets_at
echo ""
echo "-- Test 4: API cache with ISO 8601 --"
USAGE_API=$(mktemp /tmp/test-usage-api-XXXX.json); TMPFILES+=("$USAGE_API")
FUTURE=$(date -d "+3 hours" -Iseconds 2>/dev/null || date -v+3H -Iseconds 2>/dev/null)
cat > "$USAGE_API" <<JSON
{"timestamp":"2026-02-21T10:00:00Z","source":"api","metrics":{"session":{"percent_used":35.0,"percent_remaining":65.0,"resets_at":"$FUTURE"},"week_all":{"percent_used":22.0,"percent_remaining":78.0,"resets_at":"2026-04-02T13:00:00+00:00"},"week_sonnet":{"percent_used":15.0,"percent_remaining":85.0,"resets_at":"2026-04-02T13:00:00+00:00"}}}
JSON
OUT=$(run_statusline '{"model":"claude-sonnet-4-6","context_window":{"used_percentage":0}}' \
    USAGE_FILE="$USAGE_API" REFRESH_INTERVAL=999999 SHOW_WEEKLY=1)
assert_contains "API session 35%" "35%" "$OUT"
assert_contains "API week_all 22%" "22%" "$OUT"
assert_contains "API sonnet 15%" "15%" "$OUT"
assert_contains "has countdown" "h" "$OUT"

# Test 5 — Stale cache shows ⚠
echo ""
echo "-- Test 5: stale cache --"
USAGE_STALE=$(mktemp /tmp/test-usage-stale-XXXX.json); TMPFILES+=("$USAGE_STALE")
echo '{"timestamp":"2026-02-21T09:00:00+00:00","source":"api","metrics":{"session":{"percent_used":30.0,"percent_remaining":70.0,"resets_at":null}}}' > "$USAGE_STALE"
touch_minutes_ago 30 "$USAGE_STALE"
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
touch_minutes_ago 30 "$USAGE_STALE"
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

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ $FAIL -eq 0 ] && exit 0 || exit 1
