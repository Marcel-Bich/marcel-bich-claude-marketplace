# limit

Live API usage in Claude Code statusline - colored progress bars, Git info, tokens, session metrics, device tracking, and more.

## Features

**API Usage Tracking**
- Real API data from Anthropic (same as `/usage`)
- Colored progress bars with signal colors (gray/green/yellow/orange/red)
- Multiple limits: 5-hour, 7-day, Sonnet, Extra Credits
- Reset times for each limit (rounded to nearest hour)

**Highscore Tracking** (enabled by default, disable with `CLAUDE_MB_LIMIT_LOCAL=false`)
- Tracks highest token usage per plan (max20, max5, pro)
- Separate highscores for 5h and 7d windows
- Automatic plan detection from credentials
- LimitAt Achievement: Discover your real plan limit when hitting >95% API usage

**Extended Features**
- CWD (Current Working Directory)
- Git: branch, worktree name, changes (+insertions, -deletions) with colors
- Token metrics: Input, Output, Cached, Total
- Context usage with percentage of max and usable (before auto-compact)
- Session timing: Total duration, API time
- Session ID display
- Session caption (from /rename, summary, or first user prompt)

**Agent Context Injection** (enabled by default, disable with `CLAUDE_MB_LIMIT_INJECT=false`)
- Lets the agent read its own context fill, limits and cost (it cannot see the statusline)
- Context fill, window size and limits from Claude Code's own data (1M beta detected automatically) - accurate even during autonomous runs
- Auto-runs a skill of your choice at configurable context-fill thresholds (you wire up which skill)

**Platform Support**
- Cross-platform: Linux, macOS, and WSL2

## Commands

- `/limit:highscore` - Display all highscores and LimitAt achievements

## Requirements

- `jq` - JSON processor (install: `sudo apt install jq`)

## Installation

```bash
claude plugin marketplace add Marcel-Bich/marcel-bich-claude-marketplace
claude plugin install limit@marcel-bich-claude-marketplace
```

After installation, add to `~/.claude/settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "~/.claude/plugins/marketplaces/marcel-bich-claude-marketplace/plugins/limit/scripts/usage-statusline.sh"
  }
}
```

## Configuration

All features can be toggled via environment variables. Export them in your shell profile or set them before running Claude Code.

**Feature Toggles** (all default to `true` unless noted):

| Variable | Default | Description |
|----------|---------|-------------|
| `CLAUDE_MB_LIMIT_MODEL` | true | Show current model with style and cost |
| `CLAUDE_MB_LIMIT_5H` | true | Show 5-hour limit |
| `CLAUDE_MB_LIMIT_7D` | true | Show 7-day limit |
| `CLAUDE_MB_LIMIT_SONNET` | true | Show Sonnet-specific limit |
| `CLAUDE_MB_LIMIT_EXTRA` | true | Show extra credits usage |
| `CLAUDE_MB_LIMIT_CWD` | true | Show current working directory |
| `CLAUDE_MB_LIMIT_GIT` | true | Show git branch, worktree, changes |
| `CLAUDE_MB_LIMIT_TOKENS` | true | Show token metrics |
| `CLAUDE_MB_LIMIT_CTX` | true | Show context usage |
| `CLAUDE_MB_LIMIT_SESSION` | true | Show session timing |
| `CLAUDE_MB_LIMIT_SESSION_ID` | true | Show session ID |
| `CLAUDE_MB_LIMIT_CAPTION` | true | Show session caption (from /rename, summary, or first prompt) |
| `CLAUDE_MB_LIMIT_PROFILE` | true | Show active profile name |
| `CLAUDE_MB_LIMIT_COLORS` | true | Enable colored output |
| `CLAUDE_MB_LIMIT_PROGRESS` | true | Show progress bars |
| `CLAUDE_MB_LIMIT_RESET` | true | Show reset times |
| `CLAUDE_MB_LIMIT_SEPARATORS` | true | Show visual separators |
| `CLAUDE_MB_LIMIT_OPUS` | true | Show Opus limit (future-ready) |

**Highscore Settings** (enabled by default):

| Variable | Default | Description |
|----------|---------|-------------|
| `CLAUDE_MB_LIMIT_LOCAL` | true | Enable highscore tracking |
| `CLAUDE_MB_LIMIT_DEVICE_LABEL` | hostname | Custom device label for display |

**Other Settings**:

| Variable | Default | Description |
|----------|---------|-------------|
| `CLAUDE_MB_LIMIT_CACHE_AGE` | 120 | Cache duration in seconds |
| `CLAUDE_MB_LIMIT_DEFAULT_COLOR` | `\033[90m` | Default color (ANSI escape sequence) |
| `CLAUDE_MB_LIMIT_SHOW_ERRORS` | false | Show "limit: error" on failures |
| `CLAUDE_MB_LIMIT_AVERAGE` | true | Show rolling average display |
| `CLAUDE_MB_LIMIT_DEBUG` | false | Enable debug logging to `/tmp/claude-mb-limit-debug_${PROFILE_NAME}.log` |
| `CLAUDE_MB_LIMIT_HISTORY_ENABLED` | true | Enable history tracking for average display |
| `CLAUDE_MB_LIMIT_HISTORY_INTERVAL` | 600 | Minimum seconds between history writes (10 min) |
| `CLAUDE_MB_LIMIT_HISTORY_DAYS` | 28 | History retention in days |
| `CLAUDE_MB_LIMIT_PROGRESSBAR_MODE` | auto-compact | Progress bar mode (auto-compact uses ContextLeft as threshold) |
| `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` | 85 | Auto-compact threshold percentage (used by auto-compact mode) |

**Agent Context Injection** (lets the agent read its own usage and act on it):

| Variable | Default | Description |
|----------|---------|-------------|
| `CLAUDE_MB_LIMIT_CTX_CACHE` | true | Statusline writes a per-session cache `/tmp/claude-mb-context-cache_${session_id}.json` (window size, limits, cost) |
| `CLAUDE_MB_LIMIT_INJECT` | true | Inject hook injects a short status line into the agent's context (UserPromptSubmit + PostToolUse) |
| `CLAUDE_MB_LIMIT_COMPACT_SKILL` | (unset) | The skill the agent should run when a threshold is reached, e.g. `/my-skill`. Empty = status only, no skill named |
| `CLAUDE_MB_LIMIT_INJECT_INTERVAL` | 180 | Minimum seconds between routine status injects (throttle) |
| `CLAUDE_MB_LIMIT_INJECT_THRESHOLDS` | 70,90 | Comma-separated context-fill %% at which the skill hint fires (any count, e.g. `33,66,92`) |
| `CLAUDE_MB_LIMIT_INJECT_MAX_AGE` | 300 | Ignore the cache (inject nothing) if older than this many seconds - avoids reporting stale numbers |

**Multi-Account Support:**

| Variable | Default | Description |
|----------|---------|-------------|
| `CLAUDE_CONFIG_DIR` | `~/.claude` | Base directory for Claude config |

When using multiple accounts, set `CLAUDE_CONFIG_DIR` before starting Claude Code:

```bash
CLAUDE_CONFIG_DIR=~/.claude-work claude
```

Each profile gets separate state files (highscores, history, cache).

## Highscore Concept

Instead of complex calibration, we track the highest token usage ever measured on this device:

- **Highscores can only increase, never decrease** - Your record only gets broken by higher usage
- **Converges to real limit over time** - The more you work, the closer you get to the real API limit
- **Separate highscores per plan** - Switching plans (max20/max5/pro) uses the correct highscore for each
- **5h and 7d are independent records** - Each window has its own highscore

**LimitAt Achievement:** If you push hard enough to reach >95% API utilization when breaking your highscore, you discover the real limit of your plan - like an Easter-Egg!

**State file:** `~/.claude/marcel-bich-claude-marketplace/limit/limit-highscore-state_${PROFILE_NAME}.json`

## Agent Context Injection

The agent (Claude) cannot read the statusline - it is a separate process. This
feature gives the running agent its own resource usage so it can act on it (for
example run a securing or compacting skill before an auto-compact loses progress),
even during long autonomous runs where no user prompts arrive.

You decide what runs at the thresholds: set `CLAUDE_MB_LIMIT_COMPACT_SKILL` to the
skill you want auto-run (any skill, e.g. `/my-skill`). This plugin ships no skill of
its own - if the variable is unset, the agent just gets a "secure progress" hint
without a skill name. Set the threshold points with `CLAUDE_MB_LIMIT_INJECT_THRESHOLDS`
(comma-separated, any number of values, e.g. `70,90` or `33,66,92`).

How it works:

- The **statusline** writes a small per-session cache `/tmp/claude-mb-context-cache_${session_id}.json`
  with the values Claude Code hands only to the statusline: the context fill
  percentage and window size (`context_window_size` is canonical - it reflects model
  switches AND the 1M beta mid-session automatically, no lookup table needed), plus
  the 5h / weekly limits and session cost. One file per session, so parallel sessions
  never overwrite each other.
- The **inject hook** (`scripts/inject-status.sh`, on `UserPromptSubmit` + `PostToolUse`)
  reads that cache and injects a short status line via `additionalContext` - visible
  to the agent, not flooding the user chat. It skips silently if the cache is missing
  or stale (`CLAUDE_MB_LIMIT_INJECT_MAX_AGE`), so it never reports outdated numbers.
- It is **throttled** (`CLAUDE_MB_LIMIT_INJECT_INTERVAL`); each threshold in
  `CLAUDE_MB_LIMIT_INJECT_THRESHOLDS` fires once and adds an action hint to run the
  skill from `CLAUDE_MB_LIMIT_COMPACT_SKILL`. Thresholds reset after a compact drops the fill.

Example injected line (with `CLAUDE_MB_LIMIT_COMPACT_SKILL=/my-skill`):

```
[limit] Context 72% (720k/1.0M) | 5h 64% | Weekly 31% | $4.20
ACTION: Context-Fill >= 70% - run /my-skill now to secure progress before an auto-compact.
```

## Debug Scripts

The plugin includes debug scripts for troubleshooting:

- `debug-progress.sh` - Debug progress bar rendering

Run from the plugin scripts directory:

```bash
~/.claude/plugins/marketplaces/marcel-bich-claude-marketplace/plugins/limit/scripts/debug-progress.sh
```

## Documentation

For additional documentation, ccstatusline integration, and troubleshooting:

**[View Documentation on Wiki](https://github.com/Marcel-Bich/marcel-bich-claude-marketplace/wiki/Claude-Code-Limit-Plugin)**

## License

MIT - See [LICENSE](LICENSE) for full terms.

---

<details>
<summary>Keywords / Tags</summary>

Claude Code, Claude Code Plugin, Claude Code Extension, Claude Code Usage, Claude Code Limit, Claude Code Rate Limit, Claude Code API Usage, Claude Code Statusline, Claude Code Status Bar, Claude Code Progress Bar, Claude Code Utilization, Claude Code Quota, Claude Code Credits, Claude Code Tokens, Claude Code Cost, Claude Code Billing, Claude Code Subscription, Claude Code Max, Claude Code Pro, Claude Code 5h Limit, Claude Code 7d Limit, Claude Code Opus Limit, Claude Code Sonnet Limit, Claude Code Reset Time, Anthropic CLI, Anthropic Plugin, Anthropic Extension, Anthropic Claude, Anthropic AI, Anthropic API, Anthropic OAuth, Anthropic Usage, Anthropic Billing, Anthropic Limits, Anthropic Rate Limit, AI Agent Usage, AI Agent Limits, AI Agent Quota, AI Agent Cost, AI Code Assistant, AI Coding, AI Programming, AI Development, API Usage Tracking, API Rate Limit, API Quota, API Credits, Usage Display, Usage Monitor, Usage Tracker, Live Usage, Real-time Usage, statusline, Statusline, Status Bar, Progress Bar, Terminal Statusline, CLI Statusline, Colored Progress Bar, ANSI Colors, WSL, WSL2, Windows Subsystem Linux, Windows 10, Windows 11, Linux, macOS, Ubuntu, Debian, Cross Platform, ccstatusline, OAuth Token, Credentials, API Key, Cache, Rate Limiting, jq, curl, bash, Shell Script, Marcel Bich, marcel-bich-claude-marketplace, limit plugin, usage plugin, rate limit plugin, Git Worktree, Git Branch, Git Changes, Context Window, Session Tracking

</details>
