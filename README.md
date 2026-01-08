# marcel-bich-claude-marketplace

A collection of productivity plugins for Claude Code.

## Installation

Add this marketplace to Claude Code:

```bash
claude plugin marketplace add Marcel-Bich/marcel-bich-claude-marketplace
```

Or within a Claude session:
```
/plugin marketplace add Marcel-Bich/marcel-bich-claude-marketplace
```

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

When using those `/plugin` commands within a Claude session, restart Claude afterwards for changes to take effect.

## Updating

To receive plugin updates:

1. Run `/plugin` in Claude Code
2. Go to the **Marketplaces** tab
3. Enable **"Enable auto-update"** for automatic updates, or select **"Update marketplace"** manually
4. Go to the **Installed** tab and update individual plugins as needed
5. Restart Claude Code after updating

## Available Plugins

### signal

**Features:**
- Live status updates via desktop notifications
- Sound alerts for task completion and attention requests
- Optional AI summaries (using Haiku)
- Smart filtering to prevent notification spam

See [plugins/signal/README.md](plugins/signal/README.md) for full documentation.

## License

MIT - See [LICENSE](LICENSE) file for full terms.
