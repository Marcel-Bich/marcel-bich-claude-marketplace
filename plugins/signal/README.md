# signal

Desktop notifications showing what Claude Code is working on - stay informed even when the terminal is not in focus.

**Use case:** You're working in your IDE or browser while Claude Code runs in a terminal. With this plugin, you'll see desktop notifications about what Claude is doing - no need to constantly switch back to the terminal.

Works great with `claude --dangerously-skip-permissions` for autonomous workflows where you want to monitor progress without watching the terminal.

## Features

- **Live Status** - See what Claude is working on without switching to the terminal
- **Desktop Notifications** - Non-stacking notifications that replace each other
- **Sound Alerts** - Configurable volume, separate for completion and attention sounds
- **AI Summaries** - Optional Haiku-powered summaries of completed work (disabled by default)
- **Smart Filtering** - No spam from subagents, debounced notifications

## Requirements

- Linux with desktop notifications (GNOME, KDE, etc.)
- `jq` - JSON processor
- `gdbus` or `notify-send` - For desktop notifications
- `paplay` and `pactl` - For sound alerts (optional, part of PulseAudio)
- `bc` - For volume calculations (optional)

## Installation

```bash
claude plugin marketplace add Marcel-Bich/marcel-bich-claude-marketplace
claude plugin install signal@marcel-bich-claude-marketplace
```

## Configuration

Configure via environment variables in `~/.claude/settings.json`:

```json
{
  "env": {
    "CLAUDE_NOTIFY_HAIKU": "false",
    "CLAUDE_NOTIFY_SOUND_COMPLETE": "0.4",
    "CLAUDE_NOTIFY_SOUND_ATTENTION": "0.25"
  }
}
```

### Options

| Variable | Default | Description |
|----------|---------|-------------|
| `CLAUDE_NOTIFY_HAIKU` | `false` | Enable AI summaries on task completion |
| `CLAUDE_NOTIFY_SOUND_COMPLETE` | `0.4` | Completion sound volume (0-1, 0 = off) |
| `CLAUDE_NOTIFY_SOUND_ATTENTION` | `0.25` | Attention sound volume (0-1, 0 = off) |

### Sound Volume

Sound volume is relative to your system volume:
- `0.4` = 40% of current system volume
- `0.25` = 25% of current system volume
- `0` = Sound disabled

### AI Summaries (disabled by default)

> **Cost Warning:** Enabling this feature will use your Anthropic API credits. Each notification triggers a Haiku API call which costs real money. You are responsible for monitoring your own API usage and costs.

When enabled (`CLAUDE_NOTIFY_HAIKU=true`), the plugin uses Haiku to generate a brief summary of the work completed. This:
- **Costs API credits** (~0.001-0.01 USD per notification, depending on context size)
- Requires the `claude` CLI to be available and authenticated
- Shows a one-sentence summary in the notification

## Notification Types

### Completion (Stop)
- Triggered when a task completes
- Shows AI summary (if enabled) or generic message
- Plays `complete.oga` sound

### Tool Waiting (PreToolUse)
- Triggered when Bash commands need approval
- Shows the command being executed
- Plays `message.oga` sound

### Input Required (Notification)
- Triggered for permission prompts, idle prompts, etc.
- Shows what type of input is needed
- Plays `message.oga` sound

## Troubleshooting

### No notifications appearing
- Check if `notify-send` or `gdbus` is installed
- Verify your desktop environment supports notifications

### No sound
- Check if `paplay` and `pactl` are installed
- Verify PulseAudio is running: `pactl info`
- Check sound volume isn't set to 0

### Notifications stacking
- The plugin uses gdbus for notification replacement
- If falling back to notify-send, stacking may occur

## Disclaimer

This software is provided "as is", without warranty of any kind. Use at your own risk.

- The author is **not responsible** for any costs, damages, or issues arising from use of this plugin
- **You are solely responsible** for any API costs incurred (especially when enabling Haiku summaries)
- **You are solely responsible** for ensuring this plugin is compatible with your system
- No support or maintenance is guaranteed

## License

MIT - See [LICENSE](LICENSE) file for full terms.
