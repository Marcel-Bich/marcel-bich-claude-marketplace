# limit

Live API usage display in Claude Code statusline - shows your utilization with colored progress bars and reset times using real Anthropic API data.

**Use case:** You want to see your actual API usage limits (the same data shown by `/usage`) directly in the statusline, updating with each Claude response.

Unlike tools that estimate usage from local logs, this plugin fetches the real utilization data from Anthropic's API.

## Features

- **Real API Data** - Shows actual utilization from Anthropic's OAuth API (same as `/usage`)
- **Colored Progress Bars** - Visual indicators with signal colors based on utilization
- **Multiple Limits** - 5-hour, 7-day, Opus, Sonnet, and Extra Credits
- **Reset Times** - Shows exact reset date and time for each limit
- **Smart Display** - Only shows limits that are available/relevant
- **Cross-Platform** - Works on Linux, macOS, and WSL2

## Output Example

```
5h [==--------]  14% reset 2026-01-08 22:00 | 7d [----------]   3% reset 2026-01-09 20:00
```

With high utilization (colored in terminal):
```
5h [=========-]  85% reset 2026-01-08 22:00 | 7d [===-------]  35% reset 2026-01-09 20:00
```

## Color Coding

| Utilization | Color  | Meaning |
|-------------|--------|---------|
| < 30%       | Gray   | Low usage |
| 30-49%      | Green  | Normal |
| 50-74%      | Yellow | Moderate |
| 75-89%      | Orange | High |
| >= 90%      | Red    | Critical |

## Displayed Limits

| Limit | Description | When Shown |
|-------|-------------|------------|
| 5h | 5-hour rolling window | Always |
| 7d | 7-day rolling window (all models) | Always (if available) |
| Opus | 7-day Opus-specific limit | Only if you have Opus usage |
| Sonnet | 7-day Sonnet-specific limit | Only if utilization > 0 |
| Extra | Extra usage credits | Only if enabled AND used > $0 |

## Requirements

- `jq` - JSON processor (install: `sudo apt install jq`)
- `curl` - HTTP client
- `date` - GNU date (Linux/WSL) or BSD date (macOS)
- Valid Claude Code OAuth session (login via `claude` CLI)

## Installation

```bash
claude plugin marketplace add Marcel-Bich/marcel-bich-claude-marketplace
claude plugin install limit@marcel-bich-claude-marketplace
```

After installation, add the statusline configuration to `~/.claude/settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "~/.claude/plugins/limit@marcel-bich-claude-marketplace/scripts/usage-statusline.sh"
  }
}
```

**Note:** Restart Claude Code after changing settings.json.

## Updating

To update the plugin when a new version is available:

1. Run `/plugin` in Claude Code
2. Go to the **Marketplaces** tab
3. Select "Update marketplace" (or enable "Enable auto-update" for automatic updates)
4. Go to the **Installed** tab
5. Select the limit plugin and choose "Update"
6. Restart Claude Code

## Configuration

Configure via environment variables in `~/.claude/settings.json`:

```json
{
  "env": {
    "CLAUDE_LIMIT_SHOW_ERRORS": "false",
    "CLAUDE_LIMIT_DEBUG": "false"
  },
  "statusLine": {
    "type": "command",
    "command": "~/.claude/plugins/limit@marcel-bich-claude-marketplace/scripts/usage-statusline.sh"
  }
}
```

### Options

| Variable | Default | Description |
|----------|---------|-------------|
| `CLAUDE_LIMIT_5H` | `true` | Show 5-hour limit |
| `CLAUDE_LIMIT_7D` | `true` | Show 7-day limit |
| `CLAUDE_LIMIT_OPUS` | `true` | Show Opus limit (if available) |
| `CLAUDE_LIMIT_SONNET` | `true` | Show Sonnet limit (if available) |
| `CLAUDE_LIMIT_EXTRA` | `true` | Show extra credits (if used) |
| `CLAUDE_LIMIT_COLORS` | `true` | Enable colored output |
| `CLAUDE_LIMIT_PROGRESS` | `true` | Show progress bars |
| `CLAUDE_LIMIT_RESET` | `true` | Show reset times |
| `CLAUDE_LIMIT_SHOW_ERRORS` | `false` | Show "limit: error" on failures |
| `CLAUDE_LIMIT_DEBUG` | `false` | Show raw API response for debugging |

### Example: Minimal Output

To show only the 5-hour percentage without colors or progress bars:

```json
{
  "env": {
    "CLAUDE_LIMIT_7D": "false",
    "CLAUDE_LIMIT_COLORS": "false",
    "CLAUDE_LIMIT_PROGRESS": "false",
    "CLAUDE_LIMIT_RESET": "false"
  }
}
```

Output: `5h  14%`

## How It Works

1. Reads your OAuth token from `~/.claude/.credentials.json`
2. Fetches usage data from Anthropic's OAuth API
3. Formats each limit with colored progress bar, percentage, and reset time
4. Updates automatically with each Claude response (statusline refresh)

## Troubleshooting

### Nothing displayed

- Verify you're logged in: `claude /login`
- Check if credentials exist: `ls ~/.claude/.credentials.json`
- Test manually: Run the script directly in your terminal
- Enable error display: `CLAUDE_LIMIT_SHOW_ERRORS=true ./path/to/script.sh`

### Debug mode

To see the raw API response:
```bash
CLAUDE_LIMIT_DEBUG=true ~/.claude/plugins/limit@marcel-bich-claude-marketplace/scripts/usage-statusline.sh
```

### "OAuth token missing user:profile scope"

Some accounts may see this error. Workaround:
1. Run `claude /login` to re-authenticate
2. If issue persists, see: https://github.com/anthropics/claude-code/issues/15243

### Colors not showing

- Ensure your terminal supports ANSI color codes
- Some terminals may need specific configuration for 256-color support (orange)

### macOS date parsing issues

The script supports both GNU date (Linux) and BSD date (macOS). If you encounter issues on macOS, ensure you have a recent version of the system tools.

### Plugin not found or updates not working

If the normal update process via `/plugin` doesn't work:

```bash
# 1. Manually update the marketplace clone
cd ~/.claude/plugins/marketplaces/marcel-bich-claude-marketplace
git pull origin main

# 2. Reinstall the plugin
claude plugin uninstall limit@marcel-bich-claude-marketplace
claude plugin install limit@marcel-bich-claude-marketplace

# 3. Restart Claude Code
```

This is a known limitation of the Claude CLI plugin system where the local marketplace clone is not always automatically synced.

## Security

This plugin reads your OAuth token from the local credentials file to authenticate API requests. The token is:

- Only used locally to fetch your own usage data
- Never transmitted anywhere except to Anthropic's official API
- Never displayed in the statusline output

**Important:** Do not let Claude Code read or execute this script during a session, as the script output could end up in the conversation context. The statusline runs in a separate process that does not feed back into Claude's context.

## Known Limitations

1. **Unofficial API** - The `/api/oauth/usage` endpoint is not officially documented and may change
2. **Token Expiry** - If your OAuth token expires, you'll need to re-login with `claude /login`
3. **Rate Limits** - The script is called on each statusline refresh; Anthropic may rate-limit excessive calls

## Disclaimer

This software is provided "as is", without warranty of any kind. Use at your own risk.

- The author is **not responsible** for any issues arising from use of this plugin
- The API endpoint used is not officially documented and may change without notice
- **You are solely responsible** for ensuring this plugin works with your setup

## License

MIT - See [LICENSE](LICENSE) file for full terms.
