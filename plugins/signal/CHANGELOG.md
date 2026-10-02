Changelog of the signal plugin. Newest first. Months group releases; no day dates. Releases up to v1.5 are summarized by minor version.

# 2026-10

## v1

### v1.5

#### v1.5.2

##### Changed

- Code comment uses a neutral example home path

# 2026-09

## v1

### v1.5

#### Added

- `CLAUDE_MB_NOTIFY_BYPASS_TOOLS` keeps Tool waiting hints in bypass permissions mode

#### Changed

- Notification titles use the session caption, one notification per session and hook type
- Parallel hooks are serialized; line breaks are kept on GNOME

### v1.4

#### Added

- Notifications show cwd, git repo and tmux/kitty session

### v1.3

#### Added

- `CLAUDE_MB_NOTIFY_SUBAGENT_TOOLS` switch for subagent tool calls

#### Changed

- Tool waiting hints are skipped in bypass permissions mode

# 2026-07

## v1

### v1.2

#### Added

- kitty tab indicator for active sessions, with an `[ask]` prefix while a permission is pending
- kitty tab title used in desktop notifications
- pw-play and ffplay sound fallbacks on Linux

# 2026-02

## v1

### v1.1

#### Added

- Desktop notifications with sounds for Claude Code hooks
- WSL2/Windows 10+ support with volume control
- Notification replacement and clearing of old notifications at session start

#### Changed

- Previous notifications are closed to prevent tray stacking on Linux
