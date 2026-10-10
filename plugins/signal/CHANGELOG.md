Changelog of the signal plugin. Newest first. Months group releases; no day dates. Releases up to v1.5 are summarized by minor version.

# 2026-10

## v1

### v1.5

#### v1.5.3

##### Changed

- Every toast title (Done, Tool waiting, permission prompt, waiting for input) uses one name order:
  the session name set by the user (a derived name never counts), else the kitty tab title, else the tmux session, else the short session id
- Every name in the title (user name, kitty label, tmux label) has control characters removed and is cut to 20 characters
- The user name comes from the session file (`nameSource: user`, a file without a matching session id is skipped), and only that; checked on a live setup, a manual `/rename` sets `nameSource: user` in the session file. The transcript `custom-title` is not used
- The `session_name` hook field and the Limit statusline caption are no longer used as title sources (the caption could be a name Claude Code derived on its own)
- The Done toast title uses that name instead of the fixed "Done" text and keeps its sparkle in front as the only event marker; the body is unchanged

##### Fixed

- The tmux part of the body and of the title fallback is found in daemon-hosted sessions and when `TMUX_PANE` is missing, by taking the pane of the client terminal
- The Done toast resolves the kitty tab title like the other toasts

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
