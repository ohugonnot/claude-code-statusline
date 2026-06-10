#!/bin/bash
# install.sh — Claude Code Status Line installer
# Usage: bash install.sh [--refresh SECONDS]
#    or: curl -fsSL https://raw.githubusercontent.com/ohugonnot/claude-code-statusline/main/install.sh | bash -s -- --refresh 120
set -euo pipefail

# Parse arguments
CUSTOM_REFRESH=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --refresh)
            CUSTOM_REFRESH="${2:?--refresh requires a value (seconds)}"
            [[ "$CUSTOM_REFRESH" =~ ^[0-9]+$ ]] || { echo "  --refresh must be a number of seconds" >&2; exit 1; }
            shift 2 ;;
        *) shift ;;
    esac
done

REPO_RAW="https://raw.githubusercontent.com/ohugonnot/claude-code-statusline/main"
HOOKS_DIR="$HOME/.claude/hooks"
SETTINGS_FILE="$HOME/.claude/settings.json"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-/dev/null}")" 2>/dev/null && pwd || echo "")"

echo "=== Claude Code Status Line Installer ==="

# 1. Check dependencies
echo ""
echo "Checking dependencies..."

MISSING=()
for dep in jq curl; do
    if command -v "$dep" >/dev/null 2>&1; then
        echo "  [ok] $dep"
    else
        echo "  [missing] $dep"
        MISSING+=("$dep")
    fi
done

if [ ${#MISSING[@]} -gt 0 ]; then
    echo ""
    read -rp "Install missing packages (${MISSING[*]})? [Y/n] " answer
    if [[ -z "$answer" || "$answer" =~ ^[Yy] ]]; then
        if command -v apt >/dev/null 2>&1; then
            sudo apt install -y "${MISSING[@]}"
        elif command -v brew >/dev/null 2>&1; then
            brew install "${MISSING[@]}"
        else
            echo "  Could not detect package manager (apt/brew). Please install manually: ${MISSING[*]}"
            exit 1
        fi
        echo "  Packages installed."
    else
        echo "  Skipped. Some features may not work without: ${MISSING[*]}"
    fi
fi

# 2. Install statusline.sh
echo ""
echo "Installing statusline.sh..."

mkdir -p "$HOOKS_DIR"

if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/statusline.sh" ]; then
    cp "$SCRIPT_DIR/statusline.sh" "$HOOKS_DIR/statusline.sh"
else
    echo "  Downloading from GitHub..."
    curl -fsSL "$REPO_RAW/statusline.sh" -o "$HOOKS_DIR/statusline.sh"
fi
chmod +x "$HOOKS_DIR/statusline.sh"

# Apply custom refresh interval if provided
if [ -n "$CUSTOM_REFRESH" ]; then
    tmp="$(mktemp)"
    sed "s/REFRESH_INTERVAL=\"\${REFRESH_INTERVAL:-[0-9]*}\"/REFRESH_INTERVAL=\"\${REFRESH_INTERVAL:-$CUSTOM_REFRESH}\"/" "$HOOKS_DIR/statusline.sh" > "$tmp"
    mv "$tmp" "$HOOKS_DIR/statusline.sh"
    echo "  Refresh interval set to ${CUSTOM_REFRESH}s"
fi

echo "  Installed: $HOOKS_DIR/statusline.sh"

# 3. Clean up old tmux scraper artifacts (from v1)
echo ""
echo "Cleaning up old tmux scraper artifacts..."
rm -f /tmp/claude-usage-refresh.lock /tmp/.claude-usage-scraper.sh /tmp/.claude-usage-raw.txt
if tmux kill-session -t claude-usage-bg 2>/dev/null; then echo "  Killed old tmux scraper session"; fi
echo "  Done"

# 4. Update settings.json
echo ""
echo "Configuring Claude Code..."

STATUS_LINE_CONFIG='{"type":"command","command":"bash ~/.claude/hooks/statusline.sh"}'

if [ -f "$SETTINGS_FILE" ]; then
    if ! jq empty "$SETTINGS_FILE" 2>/dev/null; then
        echo "  settings.json is not valid JSON — fix it manually, statusLine not configured" >&2
        exit 1
    fi
    tmp="$(mktemp)"
    jq --argjson sl "$STATUS_LINE_CONFIG" '
      .statusLine = $sl |
      # Remove old SessionStart hook for statusline if present
      if (.hooks.SessionStart | type) == "array" then
        .hooks.SessionStart = [.hooks.SessionStart[] | select(.hooks[0].command != "bash ~/.claude/hooks/statusline.sh < /dev/null")]
      else . end |
      # Clean up empty SessionStart array
      if .hooks.SessionStart == [] then del(.hooks.SessionStart) else . end |
      if .hooks == {} then del(.hooks) else . end
    ' "$SETTINGS_FILE" > "$tmp" && mv "$tmp" "$SETTINGS_FILE"
    echo "  Updated statusLine in existing settings.json"
else
    mkdir -p "$(dirname "$SETTINGS_FILE")"
    jq -n --argjson sl "$STATUS_LINE_CONFIG" '{statusLine: $sl}' > "$SETTINGS_FILE"
    echo "  Created settings.json with statusLine"
fi

# 5. Done
echo ""
echo "Done! Restart Claude Code to see the status line."
echo ""
echo "Test command:"
echo "  echo '{\"model\":\"claude-sonnet-4-6\",\"context_window\":{\"used_percentage\":42}}' | bash $HOOKS_DIR/statusline.sh"
