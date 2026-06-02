# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Real-time status line for Claude Code that displays rate limit usage, session cost, model, git branch, and context window in the IDE status bar. Prefers the native `rate_limits` field Claude Code passes on stdin (≥2.1.x, Pro/Max); falls back to the undocumented Anthropic OAuth usage API (cached to JSON) when that field is absent or the Sonnet weekly quota is needed. Renders color-coded progress bars.

**Stack**: Bash, jq, curl. No build step, no external test framework.

## Commands

```bash
# Run tests
bash test_statusline.sh

# Manual test (pipe JSON to statusline)
echo '{"model":"claude-sonnet-4-6","context_window":{"used_percentage":42}}' | bash statusline.sh

# Install locally
bash install.sh
bash install.sh --refresh 120  # custom interval
```

## Architecture

Three files, single-purpose each:

- **statusline.sh** (core) — Claude Code status line hook. Reads JSON from stdin (model, context_window, workspace, rate_limits), outputs a formatted status string. Uses native stdin `rate_limits` when present, else refreshes via API when cache is stale.
- **install.sh** — Copies `statusline.sh` to `~/.claude/hooks/`, updates `~/.claude/settings.json`, checks/installs dependencies, cleans up old tmux scraper artifacts.
- **test_statusline.sh** — Unit + integration tests with simple assert helpers (`assert_eq`, `assert_contains`, `assert_not_contains`).

### Data Flow

```
Claude Code → JSON stdin → statusline.sh → formatted status string
                              │  rate_limits in stdin?  ── yes ─→ use it (no network)
                              └─ else / Sonnet quota ─→ curl → usage API → ~/.claude/usage-exact.json
```

### Key Design Decisions

- **Native stdin first**: `rate_limits.five_hour` / `.seven_day` (epoch `resets_at`) feed the session + weekly-all blocks with no network call. The API is hit only when the field is absent (older CC / non-subscriber) or for the Sonnet weekly quota (API-only). `NEED_API` gates the refresh; most renders make zero calls.
- **Field parsing via US (0x1f) separator**: stdin/cache fields are joined with US (`\u001f`), not `|` — a `|` in a branch path or model name would shift every field. `IFS=$'\t'` is wrong here (tab is IFS-whitespace → empty fields collapse); US is non-whitespace so empties (absent rate_limits) survive.
- **Arithmetic-injection guard (`num()`)**: every value reaching `$(( ))` or `[ -lt ]` is coerced to a bare integer first — a cache/stdin value like `x[$(cmd)]` would otherwise execute `cmd` via arithmetic array-subscript evaluation.
- **Inline API call**: single `curl` (~200ms), atomic `mktemp + mv` write, `flock` so concurrent windows don't double-call. No background processes, no tmux, no python.
- **Cross-platform**: GNU vs BSD `stat` in `file_mtime()`, GNU `date -d` with a BSD `date -j` fallback in `iso_to_epoch()`. Avoids `grep -P`.
- **Graceful degradation**: token/network/endpoint failure → silently fall back to cached data, or render without usage bars.
- **No legacy tmux cache parsing**: the v1 `resets`-text format is no longer parsed (it was GNU-only / broken on macOS). A v1 cache just shows no usage until the next API refresh repopulates it; `install.sh` still cleans up v1 artifacts.

### Usage API

The script uses `https://api.anthropic.com/api/oauth/usage`, an undocumented Anthropic endpoint. Authentication is via Bearer token from `~/.claude/.credentials.json` (maintained by Claude Code). The endpoint returns:

```json
{
  "five_hour": { "utilization": 18.0, "resets_at": "2026-03-27T10:00:00+00:00" },
  "seven_day": { "utilization": 17.0, "resets_at": "2026-04-02T13:00:00+00:00" },
  "seven_day_sonnet": { "utilization": 10.0, "resets_at": "2026-04-02T13:00:00+00:00" }
}
```

Tracked upstream: [anthropics/claude-code#13585](https://github.com/anthropics/claude-code/issues/13585)

### Configuration (env vars)

| Variable | Default | Notes |
|----------|---------|-------|
| `TIMEZONE` | system | Override for display (e.g. `America/New_York`) |
| `REFRESH_INTERVAL` | `300` | Seconds between API calls — do not set to 0 (rate limiting) |
| `SHOW_WEEKLY` | `0` | Set to `1` to show weekly + Sonnet quotas |
| `USAGE_FILE` | `~/.claude/usage-exact.json` | Cache location |
| `CREDENTIALS_FILE` | `~/.claude/.credentials.json` | OAuth token source |
| `SETTINGS_FILE` | `~/.claude/settings.json` | Effort-level source (also used by tests) |

## Testing Patterns

Unit tests source the helper section of `statusline.sh` (everything above the stdin read, via `sed`) so pure functions like `make_bar`, `num`, `format_remaining` can be called directly. Integration tests pipe JSON through `statusline.sh` with overridden env vars (`USAGE_FILE`, `REFRESH_INTERVAL`, `SETTINGS_FILE`, `CREDENTIALS_FILE=/dev/null`) to control behavior without triggering the real API. To exercise the native path, include a `rate_limits` object in the stdin JSON. Temp files are tracked in `TMPFILES` array and cleaned via trap.

To add a test: create a temp JSON cache file, use `run_statusline` helper with appropriate env overrides, assert on stdout.
