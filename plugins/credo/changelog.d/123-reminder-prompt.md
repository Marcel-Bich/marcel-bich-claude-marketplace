---
bump: patch
---

### Added

- Periodic quality reminder: a prompt that the session types into its own tmux pane, per credo session mode, configured under the `reminder` key of the credo config (every mode off by default). A mode triggers after N real user turns, after M minutes, or both; a session is armed after its 10th user turn and keeps the reminder across compact and resume. Needs tmux.

### Changed

- The empty-input rule of the tmux self-tools (self-compact, self-reload) and of the reminder: fewer than 2 visible (non-whitespace) characters in the input field count as empty. Such a leftover is removed (End, BSpace) before anything is typed; if text remains, nothing is typed.
