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

### dogma

Intelligent sync of Claude instructions with enforcement hooks for security and consistency.

**Install:**
```bash
claude plugin install dogma@marcel-bich-claude-marketplace
```

Or within a Claude session:
```
/plugin install dogma@marcel-bich-claude-marketplace
```

**Features:**
- `/dogma:sync` - Sync CLAUDE.md, CLAUDE/*.md, .claude/ from a central source with interactive review
- `/dogma:cleanup` - Find and fix AI-typical patterns in code
- Enforcement hooks for git permissions, secrets, dependencies, file protection
- All hooks toggleable via environment variables

**Usage Warning:** The enforcement hooks run on every prompt and tool use, increasing token consumption significantly. Recommended for Claude Max 20x (or minimum Max 5x). For sync-only usage without hooks, any plan works.

See [plugins/dogma/README.md](plugins/dogma/README.md) for full documentation.

---

## Troubleshooting

### Plugin not found after adding marketplace

If `claude plugin install` says "Plugin not found":

```bash
# 1. Manually update the marketplace clone
cd ~/.claude/plugins/marketplaces/marcel-bich-claude-marketplace
git pull origin main

# 2. Try installing again
claude plugin install <plugin>@marcel-bich-claude-marketplace
```

### Plugin updates not working

If the normal update process via `/plugin` doesn't work:

```bash
# 1. Manually update the marketplace clone
cd ~/.claude/plugins/marketplaces/marcel-bich-claude-marketplace
git pull origin main

# 2. Reinstall the plugin
claude plugin uninstall <plugin>@marcel-bich-claude-marketplace
claude plugin install <plugin>@marcel-bich-claude-marketplace

# 3. Restart Claude Code
```

Replace `<plugin>` with `signal`, `limit`, or `dogma`.

This is a known limitation of the Claude CLI plugin system where the local marketplace clone is not always automatically synced.

### Using limit plugin with ccstatusline

The limit plugin uses Claude Code's statusLine feature. Since only one statusLine can be active, you need a wrapper script to combine it with [ccstatusline](https://www.npmjs.com/package/ccstatusline).

**Quick setup:**
```bash
curl -sL https://raw.githubusercontent.com/Marcel-Bich/marcel-bich-claude-marketplace/main/plugins/limit/scripts/setup-combined-statusline.sh | bash
```

See [plugins/limit/README.md](plugins/limit/README.md#combining-with-ccstatusline) for manual setup instructions.

## License

MIT - See [LICENSE](LICENSE) file for full terms.
