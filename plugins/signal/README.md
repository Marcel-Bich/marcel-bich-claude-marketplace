# signal

Desktop notifications showing what Claude Code is working on - stay informed even when the terminal is not in focus. Optional sound alerts and AI summaries.

## Features

- Live status updates via desktop notifications
- Location context in every notification:
  - Title (every toast: done, tool waiting, permission prompt, waiting for input): `<name> | cwd: .../<parent>/<dir>` (short paths like `/tmp` are shown as is), e.g. `alice-task | cwd: .../alice/workstation`. What the toast is about is in the body; the Done toast keeps its sparkle in front as the only event marker
  - `<name>` uses one order everywhere, first hit wins, every name has control characters removed and is cut to 20 characters:
    - the session name set by the user (the session file of Claude Code marks it `nameSource: user`; the transcript is not used); a name Claude Code or a tool derived on its own never counts
    - the kitty tab title
    - the tmux session of the session's pane
    - the short session id: first character of each dash group joined by `-`, plus the last character, e.g. `a1b2c3d4-e5f6-7890-8bcd-0123456789d8` becomes `a-e-7-8-08`
    - `Claude Code` when no session id is known
  - For sessions hosted by the Claude Code background daemon, or when `TMUX_PANE` is missing in the hook environment, the tmux pane is taken from the client terminal process (`TMUX` and `TMUX_PANE` read from its environment, nothing else); a client that cannot be verified is ignored, so the tmux parts are then simply omitted
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
- Cross-platform: Linux and WSL2 (Windows 10/11); `powershell.exe` is found even when it is not on `PATH`, failed deliveries are logged and warned about once a day, and a once-a-day preflight tells you when toasts are switched off (see "Delivery and preflight")

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
| `CLAUDE_MB_NOTIFY_TOAST` | `true` / `false` - `false` (also `off`, `no`, `0`, `disabled`; any case, surrounding spaces ignored) skips every toast and desktop notification attempt and the preflight; sounds are unaffected | `true` |
| `CLAUDE_MB_SIGNAL_STATE_DIR` | state dir (cached `powershell.exe` path, log, once-a-day markers; mode 0700, parents checked (not world-writable, group-writable only for your own groups), never written through a symlink) | `${XDG_STATE_HOME:-$HOME/.local/state}/claude-mb-signal` |

## Delivery and preflight

- **WSL2:** `powershell.exe` is looked up on `PATH`, then in the Windows drive mounts of `/proc/mounts` (`Windows/System32/WindowsPowerShell/v1.0/powershell.exe` below a 9p/drvfs mount with a drive letter; no drive is hardcoded). The found path is cached in the state dir and re-checked before use. If it cannot be found, toasts and sounds are skipped with one warning per day (stderr and `signal.log` in the state dir)
- **Exit codes** of `powershell.exe` runs (killed after 20 s) and of gdbus/notify-send are evaluated; a failure is logged, and when no channel worked one warning per day is emitted. Hooks never block on it
- **Preflight** (SessionStart, at most once a day, only with `CLAUDE_MB_NOTIFY_TOAST` on): on WSL a read-only registry check whether Windows toasts are enabled (absent value = enabled, Focus Assist is not checked); on native Linux only whether `gdbus` or `notify-send` exists. The WSL check runs detached in the background (a cold `powershell.exe` can be slower than the SessionStart timeout), so it is reported by the NEXT session start; a failed check (or a `powershell.exe` that cannot be found) is retried at most once per hour (`CLAUDE_MB_SIGNAL_PREFLIGHT_TIMEOUT`, default 20 s). If something is off, one short context line asks Claude to tell you once and ask whether it should open the notification settings (it never does that on its own). Nothing is changed automatically; you switch it on yourself (Settings > System > Notifications > "Get notifications from apps and other senders"). No other fallback is used
- **Stop the hints or start over:** `bash <plugin>/scripts/toast-preflight.sh decline` (no further hints), `... reset` (hints and warnings come back), `... open-settings` (opens `ms-settings:notifications`)

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
