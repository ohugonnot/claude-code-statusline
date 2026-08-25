# claude-code-statusline

![test](https://github.com/ohugonnot/claude-code-statusline/actions/workflows/test.yml/badge.svg) ![MIT](https://img.shields.io/badge/License-MIT-blue.svg)

**Know your Claude Code rate limits in real time.** No more guessing when your session or weekly quota resets — see your actual usage data live in the status bar.

```
🌿 main★ │ Opus 4.6 │ 🟢 Ctx ▓▓▓░░░ 42% │ ⏳ 🟡 ▓▓░░░░ 35% ↻ 2h30m │ $0.42 ⏱ 1h4m
```

## Why?

Claude Code has rate limits but no built-in way to see them in the status bar. The `/usage` command exists, but you have to stop what you're doing to check it manually.

This script displays your usage directly in the status line — session rate limit with reset countdown, all at a glance. It reads the **`rate_limits` field Claude Code now passes on stdin** (no network call) when available, and falls back to the Anthropic usage API otherwise.

## What you get

Color-coded progress bars: 🟢 under 50% │ 🟡 50-80% │ 🔴 80% and above

| Segment | Example | Description |
|---------|---------|-------------|
| **Git** | `🌿 main★` | Current branch + `★` if dirty |
| **Model** | `Opus 4.6` | Active model. With effort set: `Opus 4.6/mx` |
| **Context** | `🟢 Ctx ▓▓▓░░░ 42%` | Context window fill. Shows `1M` for 1M context |
| **Session** | `⏳ 🟡 ▓▓░░░░ 35% ↻ 2h30m` | 5-hour session quota + countdown to reset |
| **Cost** | `$0.42 ⏱ 1h4m` | Session cost + wall-clock duration |
| **Burn rate** | `6.8k/min` | Tokens per minute, opt-in via `SHOW_BURN_RATE=1` |
| **Sessions** | `×3` | Concurrently active sessions, opt-in via `SHOW_SESSIONS=1` |

With `SHOW_WEEKLY=1`:

```
🌿 main★ │ Opus 4.6 │ 🟢 1M ▓▓▓░░░ 42% │ ⏳ 🟡 ▓▓░░░░ 35% ↻ 2h30m │ 📅 🟢 17% / Snt 🟢 10% ↻ thu 13h │ $0.42 ⏱ 1h4m
```

| Segment | Example | Description |
|---------|---------|-------------|
| **Weekly** | `📅 🟢 17% / Snt 🟢 10% ↻ thu 13h` | Weekly all-models + Sonnet quotas, reset day |

## How it works

```
Claude Code → JSON stdin → statusline.sh → formatted status string
                              │  rate_limits in stdin?  ── yes ─→ use it (no network)
                              └─ no / Sonnet quota needed ─→ curl → usage API → cache
```

**Preferred path (no network):** Claude Code ≥2.1.x passes `rate_limits.five_hour` and `.seven_day` directly on stdin for Pro/Max subscribers. The script uses these — session and weekly-all quotas with zero API calls.

**Fallback path:** when the stdin field is absent (older Claude Code, not a Pro/Max plan), or when the per-model Sonnet weekly quota is requested (`SHOW_WEEKLY=1`, not in stdin), the script calls the Anthropic usage API with your OAuth token. The call takes ~200ms and runs inline (cached for `REFRESH_INTERVAL`, default 5 minutes) — no background processes, no tmux, no scraping.

The OAuth token is read from `~/.claude/.credentials.json`, which Claude Code maintains automatically during active sessions. If the token is expired or the API is unreachable, the script silently falls back to cached data or displays without usage info.

### About the Usage API

The fallback uses `https://api.anthropic.com/api/oauth/usage`, an **undocumented** Anthropic endpoint discovered by the community. It returns session (5h) and weekly (7d) quota utilization as percentages with ISO 8601 reset timestamps, plus a Sonnet-only weekly figure not present in the stdin field.

This is not an official API — it could change without notice. There's an open feature request for official programmatic access: [anthropics/claude-code#13585](https://github.com/anthropics/claude-code/issues/13585).

If Anthropic removes this endpoint, the script still works for subscribers via the native stdin field, and otherwise degrades gracefully: you still get git, model, and context info — just no usage bars.

## Install

### One-liner

```bash
curl -fsSL https://raw.githubusercontent.com/ohugonnot/claude-code-statusline/main/install.sh | bash
```

> Piping a remote script straight into `bash` runs whatever the server returns. If you'd rather inspect first, read it (`curl -fsSL …/install.sh | less`) or use the **Manual** clone-and-run path below.

With custom refresh interval (e.g. every 2 minutes):

```bash
curl -fsSL https://raw.githubusercontent.com/ohugonnot/claude-code-statusline/main/install.sh | bash -s -- --refresh 120
```

### Manual

```bash
git clone https://github.com/ohugonnot/claude-code-statusline.git
cd claude-code-statusline
bash install.sh
```

### Fully manual

```bash
mkdir -p ~/.claude/hooks
cp statusline.sh ~/.claude/hooks/statusline.sh
chmod +x ~/.claude/hooks/statusline.sh
```

Merge this key into your existing `~/.claude/settings.json` (create the file if it doesn't exist):

```json
{"statusLine": {"type": "command", "command": "bash ~/.claude/hooks/statusline.sh"}}
```

## Requirements

- Linux, WSL, or macOS
- `bash`, `jq`, `curl` (no tmux, no python)
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) CLI installed

> **Migrating from the tmux scraper (pre-v1.3)?** The old tmux+python scraper is no longer needed. Run `install.sh` to upgrade — it will clean up old tmux sessions and lock files automatically.

## Configuration

Export in your shell profile or edit the top of `statusline.sh`:

| Variable | Default | Description |
|----------|---------|-------------|
| `REFRESH_INTERVAL` | `300` | Seconds between API calls — **do not set to 0** (causes rate limiting) |
| `SHOW_WEEKLY` | `0` | Set to `1` to show weekly + Sonnet quotas |
| `TIMEZONE` | *(system default)* | Override display timezone (e.g. `America/New_York`) |
| `USAGE_FILE` | `~/.claude/usage-exact.json` | Cache file path |
| `CREDENTIALS_FILE` | `~/.claude/.credentials.json` | OAuth credentials path |
| `SETTINGS_FILE` | `~/.claude/settings.json` | Source for the effort-level suffix |
| `SHOW_SONNET` | `1` | Set to `0` to never call the usage API for the Sonnet-only quota. With both windows on stdin, the script then makes no network call and never reads the credentials file |

### Style and segments

`STATUSLINE_STYLE=plain` renders the same data without emoji: labelled quotas, wider
bars, a dim pipe separator, and the reset as its own clock segment. The emoji style
remains the default.

```
my-project | main★ | Opus 4.6/mx | 194k/1000k [██░░░░░░░░] | 5h [█████░░░░░] 47% | 7d [█████████░] 84% | 17:34/19:45 (2h11m) | 6.8k/min | ×3 | $0.42 1h4m
```

| Variable | Default | Description |
|---|---|---|
| `STATUSLINE_STYLE` | `emoji` | `plain` drops every emoji for an ANSI-colored line |
| `BAR_BLOCKS` | `6` emoji / `10` plain | Bar width in blocks |
| `SHOW_DIR` | `0` | Set to `1` to prefix the line with the project directory name |
| `SHOW_BRANCH` | `1` | Set to `0` to hide the git branch |
| `SHOW_MODEL` | `1` | Set to `0` to hide the model and effort level |
| `SHOW_COST` | `1` | Set to `0` to hide session cost and duration |
| `SHOW_CONTEXT_TOKENS` | `0` | Set to `1` to render context as `194k/1000k` instead of a percentage |
| `SHOW_BURN_RATE` | `0` | Set to `1` to show tokens/min over the last `BURN_WINDOW_MIN` |
| `SHOW_SESSIONS` | `0` | Set to `1` to show the count of concurrently active sessions |
| `BURN_WINDOW_MIN` | `10` | Window, in minutes, the burn rate averages over |
| `SESSION_ACTIVE_MIN` | `5` | A session counts as active if its transcript changed within this many minutes |
| `PROJECTS_DIR` | `~/.claude/projects` | Where transcripts live, for the burn rate and session count |

The burn rate reads the transcript and deduplicates on `message.id`, since each
assistant message is logged more than once and summing the raw lines inflates the
rate. It counts input, cache creation and output tokens, and excludes cache reads:
at tens of thousands of tokens per turn those would drown out any signal about
actual activity.

## Testing

```bash
bash test_statusline.sh   # core behavior
bash test_ports.sh        # plain style and the opt-in segments
bash test_install.sh      # installer
```

## Troubleshooting

**Usage display frozen / not updating?**
You may have been rate-limited by the Anthropic API (e.g. `REFRESH_INTERVAL` was too low or set to `0`). Wait a few minutes, then test the API directly — a `rate_limit_error` response confirms it. Once the rate limit clears, the statusline resumes auto-updating.

> **Multiple Claude Code windows?** When the API fallback is in use, all windows share the same cache file (`~/.claude/usage-exact.json`). Whichever window renders first past the `REFRESH_INTERVAL` mark calls the API and refreshes the cache for all others (guarded by a `flock`), so you won't get multiple simultaneous API calls from the same machine. When the native stdin field is available, no API calls happen at all.

**Usage bars missing?**
Check that `~/.claude/.credentials.json` exists and contains a valid `claudeAiOauth.accessToken`. This file is created automatically when you log into Claude Code.

**Force a refresh:**
```bash
rm -f ~/.claude/usage-exact.json
```

**Check cached data:**
```bash
cat ~/.claude/usage-exact.json | jq .
```

**Test the API directly:**
```bash
TOKEN=$(jq -r '.claudeAiOauth.accessToken' ~/.claude/.credentials.json)
curl -s "https://api.anthropic.com/api/oauth/usage" \
  -H "Authorization: Bearer $TOKEN" \
  -H "anthropic-beta: oauth-2025-04-20" | jq .
```

**Migrating from the tmux scraper (pre-v1.3)?**
Run `install.sh` — it cleans up old artifacts automatically. Or manually:
```bash
rm -f /tmp/claude-usage-refresh.lock /tmp/.claude-usage-scraper.sh
tmux kill-session -t claude-usage-bg 2>/dev/null
```

## Uninstall

```bash
rm -f ~/.claude/hooks/statusline.sh
rm -f ~/.claude/usage-exact.json
# Remove the "statusLine" key from ~/.claude/settings.json
```

## License

MIT
