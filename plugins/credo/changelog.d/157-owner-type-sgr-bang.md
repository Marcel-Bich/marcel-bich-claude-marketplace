---
bump: patch
---

### Fixed

- Type-as-owner: the scrollback and visible captures are compared without escape sequences, so a colour reset that tmux carries into the first visible row no longer causes a permanent `pane-changed` refusal.
- Type-as-owner and pane guard: a message starting with `!` (Claude Code bash mode, the prompt marker turns into `!`) is recognised as an input box, so it is submitted instead of stopping with `dialog-after-paste`.
