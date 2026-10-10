Changelog of the signal plugin. Newest first. Months group releases; no day dates. Releases up to v1.5 are summarized by minor version.

# 2026-10

## v1

### v1.5

#### v1.5.4

##### Added

- `CLAUDE_MB_NOTIFY_TOAST` (default `true`): `false` skips every toast and desktop notification attempt and the preflight; sounds are unaffected
- Once-a-day toast preflight at session start (only with the switch on): on WSL a read-only registry check whether Windows toasts are enabled (`PushNotifications ToastEnabled`, `Notifications\Settings` global switch, the per-app key of the toast sender; absent value = enabled; Focus Assist is not checked), on native Linux only whether `gdbus` or `notify-send` exists. On WSL the registry read runs detached in the background and the NEXT session start reports it (SessionStart stays fast); the daily stamp is only set after a usable result, a failed read is retried at most once per hour. When toasts are off, `powershell.exe` is missing or no tool exists, one short context line asks the agent to tell the user once and to open the settings only after the user said yes; nothing is ever changed automatically. `toast-preflight.sh decline` stops the hint for good, `reset` brings it back, `open-settings` opens the Windows notification settings
- State dir `${CLAUDE_MB_SIGNAL_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/claude-mb-signal}` (mode 0700, owner-checked, never a symlink) for the cached path, the log and the once-a-day markers

##### Fixed

- Toasts and sounds no longer fail silently on WSL when `powershell.exe` is not on `PATH`: it is looked up on `PATH`, then in the Windows drive mounts of `/proc/mounts` (9p/drvfs mounts with a drive letter, below `Windows/System32/WindowsPowerShell/v1.0/`), never from a hardcoded drive. The found path is cached in the state dir and re-checked before every use
- Exit codes are evaluated: a failed or hung `powershell.exe` run (killed after 20 seconds, `CLAUDE_MB_SIGNAL_PS_TIMEOUT`) is logged and reported once a day, and when no notification channel worked (Linux: gdbus and notify-send both missing or failing; WSL: no `powershell.exe`) one rate-limited warning goes to stderr and the state log. Hooks stay non-blocking
- Session start only clears the toast history when `powershell.exe` can be resolved
- PowerShell scripts are passed with `-EncodedCommand` (UTF-16LE base64) instead of a multi-line argv string; background runs get stdin from `/dev/null`; the toast tag (session id) is restricted to `[A-Za-z0-9-]` and title and body are flattened to one line each
- On Linux a gdbus `Notify` call with exit code 0 counts as delivered even when the reply id cannot be parsed (no duplicate via `notify-send`)
- State dir hardening: below `$HOME` every level must be a real directory owned by the user, not world-writable (unless sticky) and group-writable only for one of the user's own groups (default Ubuntu umask 002 makes `~/.local` group-writable), no symlink below the anchor; `signal.log`, the cached `powershell.exe` path, the once-a-day markers and the preflight files are never written through a symlink. Only GNU or BSD `stat`, `cd -P` and `id` are used (no `realpath -e`), so macOS works too
- Without a usable state dir (HOME unset, symlinked parent) warnings are limited to once a day by a private per-user marker in `${TMPDIR:-/tmp}` instead of firing on every call
- Toast title and body: control characters other than tab and newline are stripped (invalid in the toast XML), and the length caps (title 200, body 1000 characters) apply before the XML escaping, so the encoded command stays far below the Windows command-line limit even for 2000 `&`
- The failed-run marker is kept per kind (toast, sound, remove-group): a working sound run no longer hides a failing toast; sound failures are reported once a day like toast failures. `toast-preflight.sh reset` clears them too
- Atomic state-file writes use `mktemp` next to the target and refuse a symlink or directory target; a missing `/proc/mounts` no longer prints a shell error; the PowerShell runs set `$ProgressPreference = 'SilentlyContinue'`
- Preflight: a missing `powershell.exe` no longer sets the daily stamp; it uses the failure marker (retry at most once per hour) and the hint line is shown once a day
- `CLAUDE_MB_NOTIFY_TOAST`: surrounding whitespace is ignored and `disabled` counts as off

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
