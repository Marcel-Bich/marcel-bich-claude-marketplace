# limit

Live API usage display in Claude Code statusline - shows your utilization with colored progress bars and reset times using real Anthropic API data.

## Features

**API Usage Tracking**
- Real API data from Anthropic (same as `/usage`)
- Colored progress bars with signal colors (gray/green/yellow/orange/red)
- Multiple limits: 5-hour, 7-day, Opus, Sonnet, Extra Credits
- Reset times for each limit (rounded to nearest hour)

**Highscore Tracking** (optional, enable with `CLAUDE_MB_LIMIT_LOCAL=true`)
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

**Platform Support**
- Cross-platform: Linux, macOS, and WSL2

## Commands

- `/limit:highscore` - Display all highscores and LimitAt achievements
- `/limit:setup` - Configure statusline settings

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
| `CLAUDE_MB_LIMIT_OPUS` | true | Show Opus-specific limit |
| `CLAUDE_MB_LIMIT_SONNET` | true | Show Sonnet-specific limit |
| `CLAUDE_MB_LIMIT_EXTRA` | true | Show extra credits usage |
| `CLAUDE_MB_LIMIT_CWD` | true | Show current working directory |
| `CLAUDE_MB_LIMIT_GIT` | true | Show git branch, worktree, changes |
| `CLAUDE_MB_LIMIT_TOKENS` | true | Show token metrics |
| `CLAUDE_MB_LIMIT_CTX` | true | Show context usage |
| `CLAUDE_MB_LIMIT_SESSION` | true | Show session timing |
| `CLAUDE_MB_LIMIT_SESSION_ID` | true | Show session ID |
| `CLAUDE_MB_LIMIT_COLORS` | true | Enable colored output |
| `CLAUDE_MB_LIMIT_PROGRESS` | true | Show progress bars |
| `CLAUDE_MB_LIMIT_RESET` | true | Show reset times |
| `CLAUDE_MB_LIMIT_SEPARATORS` | true | Show visual separators |

**Highscore Settings** (requires `CLAUDE_MB_LIMIT_LOCAL=true`):

| Variable | Default | Description |
|----------|---------|-------------|
| `CLAUDE_MB_LIMIT_LOCAL` | false | Enable highscore tracking |
| `CLAUDE_MB_LIMIT_DEVICE_LABEL` | hostname | Custom device label for display |

**Other Settings**:

| Variable | Default | Description |
|----------|---------|-------------|
| `CLAUDE_MB_LIMIT_CACHE_AGE` | 120 | Cache duration in seconds |
| `CLAUDE_MB_LIMIT_DEFAULT_COLOR` | `\033[90m` | Default color (ANSI escape sequence) |
| `CLAUDE_MB_LIMIT_DEBUG` | false | Enable debug logging to `/tmp/claude-mb-limit-debug.log` |

## Highscore Concept

Instead of complex calibration, we track the highest token usage ever measured on this device:

- **Highscores can only increase, never decrease** - Your record only gets broken by higher usage
- **Converges to real limit over time** - The more you work, the closer you get to the real API limit
- **Separate highscores per plan** - Switching plans (max20/max5/pro) uses the correct highscore for each
- **5h and 7d are independent records** - Each window has its own highscore

**LimitAt Achievement:** If you push hard enough to reach >95% API utilization when breaking your highscore, you discover the real limit of your plan - like an Easter-Egg!

**State file:** `~/.claude/limit-highscore-state.json`

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
