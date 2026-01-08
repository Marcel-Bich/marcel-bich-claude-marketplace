# marcel-bich-claude-marketplace

A collection of productivity plugins for Claude Code.

## Requirements

All plugins require:
- `jq` - JSON processor (install: `sudo apt install jq`)

## Installation

Add this marketplace to Claude Code:

```bash
claude plugin marketplace add Marcel-Bich/marcel-bich-claude-marketplace
```

Or within a Claude session:
```
/plugin marketplace add Marcel-Bich/marcel-bich-claude-marketplace
```

When using `/plugin` commands within a Claude session, restart Claude afterwards for changes to take effect.

## Updating

To receive plugin updates:

1. Run `/plugin` in Claude Code
2. Go to the **Marketplaces** tab
3. Enable **"Enable auto-update"** for automatic updates, or select **"Update marketplace"** manually
4. Go to the **Installed** tab and update individual plugins as needed
5. Restart Claude Code after updating

## Available Plugins

### signal

Desktop notifications showing what Claude Code is working on - stay informed even when the terminal is not in focus.

**Install:**
```bash
claude plugin install signal@marcel-bich-claude-marketplace
```

Or within a Claude session:
```
/plugin install signal@marcel-bich-claude-marketplace
```

**Features:**
- Live status updates via desktop notifications
- Sound alerts for task completion and attention requests
- Optional AI summaries (using Haiku)
- Smart filtering to prevent notification spam

See [plugins/signal/README.md](plugins/signal/README.md) for full documentation.

---

### limit

Live API usage display in Claude Code statusline - shows your utilization with colored progress bars and reset times.

**Install:**
```bash
claude plugin install limit@marcel-bich-claude-marketplace
```

Or within a Claude session:
```
/plugin install limit@marcel-bich-claude-marketplace
```

**Features:**
- Real API data from Anthropic (same as `/usage`)
- Colored progress bars with signal colors
- Multiple limits: 5-hour, 7-day, Opus, Sonnet, Extra Credits
- Reset times for each limit
- All features toggleable via environment variables

See [plugins/limit/README.md](plugins/limit/README.md) for full documentation.

---

## License

MIT - See [LICENSE](LICENSE) file for full terms.
