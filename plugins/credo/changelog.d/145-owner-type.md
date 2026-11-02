---
bump: patch
---

### Added

- `credo-owner-type.py send --session <id|name> (--text T | --stdin) [--force-append]` pastes the owner's message into a session's tmux pane as one bracketed paste and presses Enter. The session is looked up in the session registry and must be live with a pane that still belongs to it. Works while the session runs (Claude Code queues the text) when the input field is empty; `--force-append` appends `" " + text` after the existing text and never changes the existing text. Multi-line text arrives as one message.
- `credo-owner-type.py show --session <id|name>` prints the whole dialog block of the open Ask box, review page or permission prompt (verbatim, top rule to footer, each row prefixed with `| `) and its digest, the sha256 over those rows.
- `credo-owner-type.py answer --session <id|name> --ask <spec> --expect <digest>` answers an open Ask box (digit, option label, `esc`, `free:<text>`, `multi:<d,d>`), a permission prompt (digit or `esc`, `--persist` for options other than Yes or No) and the review page (`1`). Every answer needs `--expect <digest>` from `show`, and the prompt is checked again before every key.
- Dialogs are read from the capture with its scrollback, so a box taller than the pane is read from its real top. A dialog whose top is not in view is refused with `dialog-does-not-fit`; a dialog that holds invisible or bidi characters is refused with `invisible-characters`. Both are answered at the PC.
- Every delivery and refusal is appended to `<profile>/credo/owner-type.log` (time, session id, mode, character count, result, option label); message text only with `CREDO_OWNER_TYPE_LOG_TEXT=1`.
