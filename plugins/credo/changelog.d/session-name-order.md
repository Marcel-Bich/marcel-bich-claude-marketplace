---
bump: patch
---

### Added

- `scripts/credo_session_name.py`: one small resolver for every peer / session name credo shows, with a single fallback order: caption, kitty tab title, tmux session, short session id. Every name is capped at 20 characters and keeps only letters, digits, space, `.`, `_` and `-` (NFC), whichever step supplies it. The caption is a user-set name only: for Claude the registry `name` when `nameSource` is `user` (the cwd-based `derived` name never counts), for Codex the newest `thread_name` row of `$CODEX_HOME/session_index.jsonl` for the thread id (read without following symlinks, regular file owned by the current user, last 256 KiB only, sanitized). A daemon-hosted Claude session has no tmux or kitty ancestry of its own, so its labels are resolved through its verified client TUI (fail closed)
- The tmux pane and client lists are reused for 15 seconds across lookups (the LAN roster builds a new lookup on every tick), and one lookup spends at most about 2 seconds in kitty remote-control calls in total
- Tests: `test-credo-session-name.sh`

### Changed

- LAN relay rosters announce the resolved name instead of the registry name, and the peer check (`credo-peer-check.py`) lists Claude and Codex sessions under the same order; a session that nobody named is no longer shown under its cwd-based derived name (for example a host-and-suffix name) but under its kitty tab or tmux session, or its short id when it runs outside tmux and kitty. Peer trust keys on the user-set caption only (see the caption trust entry)
- Peer check: an unnamed Codex thread takes the tmux session of the one free Codex pane (when exactly one pane and one unnamed thread exist; otherwise it keeps its short id), and a live socket without a registry descriptor is named by the same order (kitty tab, tmux session, else `pid N`)
- `sid_short` moved from `credo-peer-lan.py` into `credo_session_name.py` (still importable from `credo-peer-lan.py`); a roster entry without a name is mirrored under its short id instead of the full session id
