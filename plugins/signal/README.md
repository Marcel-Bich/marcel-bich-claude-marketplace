# signal

Desktop notifications showing what Claude Code is working on - stay informed even when the terminal is not in focus. Optional sound alerts and AI summaries.

## Features

- Live status updates via desktop notifications
- Location context in every notification:
  - Title: `<event> | cwd: .../<parent>/<dir>` (short paths like `/tmp` are shown as is), e.g. `Tool waiting | cwd: .../marcel/workstation`
  - General notifications (permission prompt, waiting for input) use the session caption as `<event>`: the `/rename` title, else the limit statusline caption, else the kitty tab title, else the tmux session, else `Claude Code`
  - Body, first line: `git: <parent>/<repo>` of the repo the session works in - resolved from the limit plugin's per-session work-repo state, then git discovery from the cwd, then the credo session pin (limit and credo are optional); omitted when no repo resolves
  - Body, last line (after an empty line): `tmux: <session> | kitty: <tab>` with only the parts that exist; omitted outside tmux/kitty. tmux is the session of the current pane; kitty is the tab title without `[ai...]`/`[ask]`/`[fin]` prefixes, taken from the tab indicator's saved title or, if the indicator is disabled or has no saved title, read live via `kitty @ ls` (needs the kitty socket)
  - On WSL2 the body lines are joined with ` | ` because the toast shows the body as a single text field
  - On GNOME Shell the line breaks are sent as carriage returns, because GNOME turns every `\n` in the body into a space (empty lines are kept)
- Sound alerts with context-aware sounds:
  - "Complete" sound for permission prompts (requires attention)
  - "Message" sound for general notifications
- Configurable sound volume via environment variables
- Optional AI summaries (using Haiku)
- Smart filtering to prevent notification spam
- "Tool waiting" hints are skipped in bypass permissions mode (no tool ever waits there, switch: `CLAUDE_MB_NOTIFY_BYPASS_TOOLS`); real permission prompts are still notified
- Non-stacking notifications: one slot per session and hook type; each new notification replaces the previous one of the same session (previous one is closed first to prevent Linux tray stacking). Hooks firing at the same moment (parallel tool calls) are serialized with `flock`, so they no longer leave several notifications behind
- Kitty terminal tab indicator for active Claude sessions
- Cross-platform: Linux and WSL2 (Windows 10/11)

## Requirements

- `jq` - JSON processor (install: `sudo apt install jq`)

### Optional (sound alerts on Linux)

Sound is optional. On Linux the plugin tries the first available player in this order:

- `paplay` (PulseAudio, `pulseaudio-utils`) - honours the configured volume
- `pw-play` (PipeWire, `pipewire-bin` on Debian/Ubuntu) - honours the configured volume
- `ffplay` (ffmpeg) - plays at full volume (no per-play volume control)

If none is installed, notifications still work; only the sound is skipped. On WSL2 the Windows system sound is used instead.

## Configuration

| Variable | Values | Default |
|---|---|---|
| `CLAUDE_MB_NOTIFY_SOUND_ATTENTION` | volume `0.0`-`1.0`, `0` disables | `0.25` |
| `CLAUDE_MB_NOTIFY_SOUND_COMPLETE` | volume `0.0`-`1.0`, `0` disables (permission prompts) | `0.4` |
| `CLAUDE_MB_NOTIFY_SUBAGENT_TOOLS` | `true` / `false` - `false` silences "Tool waiting" hints for subagent tool calls | `true` |
| `CLAUDE_MB_NOTIFY_BYPASS_TOOLS` | `true` / `false` - `true` shows "Tool waiting" hints in bypass permissions mode too | `false` |

## Kitty Tab Indicator

Marks the kitty terminal tab title with a prefix during active Claude sessions so you can tell at a glance which tabs are running Claude.

- `[ai...]` prefix while Claude is working
- `[ask]` prefix when user input or permission is required
- `[fin]` prefix when the session ends, automatically removed after you focus the tab for 3 seconds

### Configuration

| Variable | Values | Default |
|---|---|---|
| `CLAUDE_MB_KITTY_TAB` | `true` / `false` | `true` |

### Requirements

- [kitty](https://sw.kovidgoyal.net/kitty/) terminal
- `allow_remote_control yes` in `kitty.conf`
- `listen_on unix:/tmp/mykitty` in `kitty.conf`

Works inside tmux (the client of the current pane is used) and with kitty started via the `x-terminal-emulator` alternative.

## Installation

```bash
claude plugin marketplace add Marcel-Bich/marcel-bich-claude-marketplace
claude plugin install signal@marcel-bich-claude-marketplace
```

## Documentation

Full documentation, configuration options, and troubleshooting:

**[View Documentation on Wiki](https://github.com/Marcel-Bich/marcel-bich-claude-marketplace/wiki/Claude-Code-Signal-Plugin)**

## License

MIT - See [LICENSE](LICENSE) for full terms.

---

<details>
<summary>Keywords / Tags</summary>

Claude Code, Claude Code Plugin, Claude Code Extension, Claude Code Notifications, Claude Code Desktop Notifications, Claude Code Terminal Notifications, Claude Code Alerts, Claude Code Sound, Claude Code Audio, Claude Code Toast, Claude Code Status, Claude Code Progress, Claude Code Monitoring, Claude Code Background, Claude Code Autonomous, Claude Code Dangerously Skip Permissions, Anthropic CLI, Anthropic Plugin, Anthropic Extension, Anthropic Claude, Anthropic AI, AI Agent Notifications, AI Agent Alerts, AI Agent Status, AI Agent Monitoring, AI Code Assistant, AI Coding, AI Programming, AI Development, Desktop Notifications, Terminal Notifications, System Notifications, Toast Notifications, Push Notifications, Sound Alerts, Audio Alerts, Notification Sound, Complete Sound, Attention Sound, WSL, WSL2, WSL Notifications, Windows Subsystem Linux, Windows 10, Windows 11, Windows Notifications, Linux Notifications, GNOME Notifications, KDE Notifications, Ubuntu Notifications, Debian Notifications, notify-send, gdbus, BurntToast, PowerShell Notifications, PulseAudio, paplay, pactl, PipeWire, pw-play, ffplay, ffmpeg, Cross Platform, Background Tasks, Autonomous Coding, Haiku Summary, AI Summary, Task Completion, Tool Waiting, Permission Prompt, Input Required, Claude Code Hooks, Stop Hook, PreToolUse Hook, Notification Hook, Marcel Bich, marcel-bich-claude-marketplace, signal plugin, notification plugin

</details>
