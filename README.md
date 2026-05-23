# claude-code-statusline

**Know your Claude Code rate limits in real time.** No more guessing when your session or weekly quota resets — see your actual usage data live in the status bar.

```
🌿 main★ │ Opus 4.6 │ 🟢 Ctx ▓▓▓░░░ 42% │ ⏳ 🟡 ▓▓░░░░ 35% ↻ 2h30m │ $0.42 ⏱ 1h4m
```

## Why?

Claude Code has rate limits but no built-in way to see them while you work. The `/usage` command exists, but you have to stop what you're doing to check it manually.

This script **fetches your usage via API every 60 seconds** and displays the results directly in your status line — session rate limit with reset countdown, all at a glance.

## What you get

Color-coded progress bars: 🟢 under 50% │ 🟡 50-80% │ 🔴 over 80%

| Segment | Example | Description |
|---------|---------|-------------|
| **Git** | `🌿 main★` | Current branch + `★` if dirty |
| **Model** | `Opus 4.6` | Active model. With effort set: `Opus 4.6/mx` |
| **Context** | `🟢 Ctx ▓▓▓░░░ 42%` | Context window fill. Shows `1M` for 1M context |
| **Session** | `⏳ 🟡 ▓▓░░░░ 35% ↻ 2h30m` | 5-hour session quota + countdown to reset |
| **Cost** | `$0.42 ⏱ 1h4m` | Session cost + wall-clock duration |

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
                              ↓ (if cache > 60s old)
                         curl → Anthropic OAuth API → ~/.claude/usage-exact.json
```

Every 60 seconds (configurable), the script calls the Anthropic usage API with your OAuth token. The call takes ~200ms and runs inline — no background processes, no tmux, no scraping.

The OAuth token is read from `~/.claude/.credentials.json`, which Claude Code maintains automatically during active sessions. On macOS, where Claude Code stores credentials in the system Keychain instead of a file, the script falls back to `security find-generic-password -s "Claude Code-credentials" -w`. If the token is expired or the API is unreachable, the script silently falls back to cached data or displays without usage info.

### About the Usage API

The script uses `https://api.anthropic.com/api/oauth/usage`, an **undocumented** Anthropic endpoint discovered by the community. It returns session (5h) and weekly (7d) quota utilization as percentages with ISO 8601 reset timestamps.

This is not an official API — it could change without notice. There's an open feature request for official programmatic access: [anthropics/claude-code#13585](https://github.com/anthropics/claude-code/issues/13585).

If Anthropic removes this endpoint, the script degrades gracefully: you still get git, model, and context info — just no usage bars.

## Install

### One-liner

```bash
curl -fsSL https://raw.githubusercontent.com/ohugonnot/claude-code-statusline/main/install.sh | bash
```

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

# Add this key to ~/.claude/settings.json:
# "statusLine": { "type": "command", "command": "bash ~/.claude/hooks/statusline.sh" }
```

## Requirements

- Linux, WSL, or macOS
- `bash`, `jq`, `curl` (no tmux, no python)
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) CLI installed

> **Migrating from v1?** The old tmux+python scraper is no longer needed. Run `install.sh` to upgrade — it will clean up old tmux sessions and lock files automatically.

## Configuration

Export in your shell profile or edit the top of `statusline.sh`:

| Variable | Default | Description |
|----------|---------|-------------|
| `REFRESH_INTERVAL` | `300` | Seconds between API calls — **do not set to 0** (causes rate limiting) |
| `SHOW_WEEKLY` | `0` | Set to `1` to show weekly + Sonnet quotas |
| `TIMEZONE` | *(system default)* | Override display timezone (e.g. `America/New_York`) |
| `USAGE_FILE` | `~/.claude/usage-exact.json` | Cache file path |
| `CREDENTIALS_FILE` | `~/.claude/.credentials.json` | OAuth credentials path |

## Testing

```bash
bash test_statusline.sh
```

## Troubleshooting

**Usage display frozen / not updating?**
You may have been rate-limited by the Anthropic API (e.g. `REFRESH_INTERVAL` was too low or set to `0`). Wait a few minutes, then test the API directly — a `rate_limit_error` response confirms it. Once the rate limit clears, the statusline resumes auto-updating.

> **Multiple Claude Code windows?** All windows share the same cache file (`~/.claude/usage-exact.json`). Whichever window renders first past the 60s mark will call the API and refresh the cache for all others. You won't get multiple simultaneous API calls from the same machine.

**Usage bars missing?**
Check that `~/.claude/.credentials.json` exists and contains a valid `claudeAiOauth.accessToken`. This file is created automatically when you log into Claude Code. On macOS, credentials live in the Keychain instead — verify with `security find-generic-password -s "Claude Code-credentials" -w | jq .claudeAiOauth.accessToken`.

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

**Migrating from v1 (tmux scraper)?**
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
