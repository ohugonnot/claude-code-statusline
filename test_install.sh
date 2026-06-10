#!/bin/bash
# Tests for install.sh
# shellcheck disable=SC2016  # single-quoted assertions are intentional

INSTALL_SH="$(dirname "$(realpath "$0")")/install.sh"
PASS=0; FAIL=0

TMPDIRS=()
cleanup_tests() {
    for d in "${TMPDIRS[@]}"; do rm -rf "$d"; done
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

assert_zero() {
    local desc="$1" code="$2"
    if [ "$code" -eq 0 ]; then
        echo "  ✓ $desc"; ((PASS++))
    else
        echo "  ✗ $desc (exit code: $code)"; ((FAIL++))
    fi
}

assert_nonzero() {
    local desc="$1" code="$2"
    if [ "$code" -ne 0 ]; then
        echo "  ✓ $desc"; ((PASS++))
    else
        echo "  ✗ $desc (expected non-zero, got 0)"; ((FAIL++))
    fi
}

# Run install.sh with a fake HOME. The script uses BASH_SOURCE[0] to locate the
# local statusline.sh, so running it via 'bash <path>' keeps SCRIPT_DIR correct.
run_install() {
    local fake_home="$1"; shift
    HOME="$fake_home" bash "$INSTALL_SH" "$@" 2>&1
}

# ── Test 1: fresh install — no settings.json ─────────────────────────────────
echo ""
echo "=== Test 1: fresh install ==="
FAKE_HOME=$(mktemp -d); TMPDIRS+=("$FAKE_HOME")
run_install "$FAKE_HOME" > /dev/null
EXIT_CODE=$?

assert_zero "install exits 0" "$EXIT_CODE"

SETTINGS="$FAKE_HOME/.claude/settings.json"
[ -f "$SETTINGS" ] && VALID=0 || VALID=1
assert_eq "settings.json created" "0" "$VALID"

if [ -f "$SETTINGS" ]; then
    jq empty "$SETTINGS" 2>/dev/null
    assert_zero "settings.json is valid JSON" "$?"

    SL_TYPE=$(jq -r '.statusLine.type // ""' "$SETTINGS" 2>/dev/null)
    assert_eq "statusLine.type is command" "command" "$SL_TYPE"

    SL_CMD=$(jq -r '.statusLine.command // ""' "$SETTINGS" 2>/dev/null)
    assert_contains "statusLine.command references statusline.sh" "statusline.sh" "$SL_CMD"
fi

SCRIPT="$FAKE_HOME/.claude/hooks/statusline.sh"
[ -f "$SCRIPT" ] && PRESENT=0 || PRESENT=1
assert_eq "statusline.sh installed" "0" "$PRESENT"

# ── Test 2: existing settings.json — other keys preserved ────────────────────
echo ""
echo "=== Test 2: existing settings with other keys ==="
FAKE_HOME2=$(mktemp -d); TMPDIRS+=("$FAKE_HOME2")
mkdir -p "$FAKE_HOME2/.claude"
printf '{"theme":"dark","model":"claude-opus-4-6"}' > "$FAKE_HOME2/.claude/settings.json"

run_install "$FAKE_HOME2" > /dev/null
EXIT_CODE=$?

assert_zero "install exits 0 with existing settings" "$EXIT_CODE"

SETTINGS2="$FAKE_HOME2/.claude/settings.json"
jq empty "$SETTINGS2" 2>/dev/null
assert_zero "merged settings.json still valid JSON" "$?"

THEME=$(jq -r '.theme // ""' "$SETTINGS2" 2>/dev/null)
assert_eq "existing theme key preserved" "dark" "$THEME"

MODEL_KEY=$(jq -r '.model // ""' "$SETTINGS2" 2>/dev/null)
assert_eq "existing model key preserved" "claude-opus-4-6" "$MODEL_KEY"

SL_TYPE2=$(jq -r '.statusLine.type // ""' "$SETTINGS2" 2>/dev/null)
assert_eq "statusLine added to existing file" "command" "$SL_TYPE2"

# ── Test 3: invalid JSON — exit non-zero, file intact ────────────────────────
echo ""
echo "=== Test 3: invalid JSON — reject cleanly ==="
FAKE_HOME3=$(mktemp -d); TMPDIRS+=("$FAKE_HOME3")
mkdir -p "$FAKE_HOME3/.claude"
printf '{broken' > "$FAKE_HOME3/.claude/settings.json"
ORIGINAL_CONTENT=$(cat "$FAKE_HOME3/.claude/settings.json")

ERR_OUT=$(run_install "$FAKE_HOME3" 2>&1)
EXIT_CODE=$?

assert_nonzero "install exits non-zero on invalid JSON" "$EXIT_CODE"
assert_contains "error message mentions settings.json" "settings.json" "$ERR_OUT"

AFTER_CONTENT=$(cat "$FAKE_HOME3/.claude/settings.json")
assert_eq "file unchanged after rejected install" "$ORIGINAL_CONTENT" "$AFTER_CONTENT"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ $FAIL -eq 0 ] && exit 0 || exit 1
