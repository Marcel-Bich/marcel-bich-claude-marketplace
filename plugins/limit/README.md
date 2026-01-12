# limit

Live API usage display in Claude Code statusline - shows your utilization with colored progress bars and reset times using real Anthropic API data.

## Features

- Real API data from Anthropic (same as `/usage`)
- Colored progress bars with signal colors
- Multiple limits: 5-hour, 7-day, Opus, Sonnet, Extra Credits
- Reset times for each limit
- Cross-platform: Linux, macOS, and WSL2
- Extended features (CWD, Git, Context, Tokens, Session)

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

## Documentation

Full documentation, configuration options, ccstatusline integration, and troubleshooting:

**[View Documentation on Wiki](https://github.com/Marcel-Bich/marcel-bich-claude-marketplace/wiki/Claude-Code-Limit-Plugin)**

## License

MIT - See [LICENSE](LICENSE) for full terms.

---

<details>
<summary>Keywords / Tags</summary>

Claude Code, Claude Code Plugin, Claude Code Extension, Claude Code Usage, Claude Code Limit, Claude Code Rate Limit, Claude Code API Usage, Claude Code Statusline, Claude Code Status Bar, Claude Code Progress Bar, Claude Code Utilization, Claude Code Quota, Claude Code Credits, Claude Code Tokens, Claude Code Cost, Claude Code Billing, Claude Code Subscription, Claude Code Max, Claude Code Pro, Claude Code 5h Limit, Claude Code 7d Limit, Claude Code Opus Limit, Claude Code Sonnet Limit, Claude Code Reset Time, Anthropic CLI, Anthropic Plugin, Anthropic Extension, Anthropic Claude, Anthropic AI, Anthropic API, Anthropic OAuth, Anthropic Usage, Anthropic Billing, Anthropic Limits, Anthropic Rate Limit, AI Agent Usage, AI Agent Limits, AI Agent Quota, AI Agent Cost, AI Code Assistant, AI Coding, AI Programming, AI Development, API Usage Tracking, API Rate Limit, API Quota, API Credits, Usage Display, Usage Monitor, Usage Tracker, Live Usage, Real-time Usage, Statusline, Status Bar, Progress Bar, Terminal Statusline, CLI Statusline, Colored Progress Bar, ANSI Colors, WSL, WSL2, Windows Subsystem Linux, Windows 10, Windows 11, Linux, macOS, Ubuntu, Debian, Cross Platform, ccstatusline, OAuth Token, Credentials, API Key, Cache, Rate Limiting, jq, curl, bash, Shell Script, Marcel Bich, marcel-bich-claude-marketplace, limit plugin, usage plugin, rate limit plugin

</details>
