# signal

Desktop notifications showing what Claude Code is working on - stay informed even when the terminal is not in focus.

## Features

- Live status updates via desktop notifications
- Sound alerts with context-aware sounds:
  - "Complete" sound for permission prompts (requires attention)
  - "Message" sound for general notifications
- Configurable sound volume via environment variables
- Optional AI summaries (using Haiku)
- Smart filtering to prevent notification spam
- Cross-platform: Linux and WSL2 (Windows 10/11)

## Requirements

- `jq` - JSON processor (install: `sudo apt install jq`)

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

Claude Code, Claude Code Plugin, Claude Code Extension, Claude Code Notifications, Claude Code Desktop Notifications, Claude Code Terminal Notifications, Claude Code Alerts, Claude Code Sound, Claude Code Audio, Claude Code Toast, Claude Code Status, Claude Code Progress, Claude Code Monitoring, Claude Code Background, Claude Code Autonomous, Claude Code Dangerously Skip Permissions, Anthropic CLI, Anthropic Plugin, Anthropic Extension, Anthropic Claude, Anthropic AI, AI Agent Notifications, AI Agent Alerts, AI Agent Status, AI Agent Monitoring, AI Code Assistant, AI Coding, AI Programming, AI Development, Desktop Notifications, Terminal Notifications, System Notifications, Toast Notifications, Push Notifications, Sound Alerts, Audio Alerts, Notification Sound, Complete Sound, Attention Sound, WSL, WSL2, WSL Notifications, Windows Subsystem Linux, Windows 10, Windows 11, Windows Notifications, Linux Notifications, GNOME Notifications, KDE Notifications, Ubuntu Notifications, Debian Notifications, notify-send, gdbus, BurntToast, PowerShell Notifications, PulseAudio, paplay, pactl, Cross Platform, Background Tasks, Autonomous Coding, Haiku Summary, AI Summary, Task Completion, Tool Waiting, Permission Prompt, Input Required, Claude Code Hooks, Stop Hook, PreToolUse Hook, Notification Hook, Marcel Bich, marcel-bich-claude-marketplace, signal plugin, notification plugin

</details>
