---
bump: patch
---

### Added

- `credo-owner-type.py send --session <id|name> (--text T | --stdin) [--force-append]` types the owner's message into a session's tmux pane and presses Enter. The session is looked up in the session registry and must be live with a pane that still belongs to it. Works while the session runs (the text is queued by Claude Code) when the input field is empty; `--force-append` appends after text already in the field and never deletes it. Multi-line text is typed with a backslash and Enter; the text is confirmed in the field before Enter, and an unconfirmed or interrupted send takes back only its own text.
- `credo-owner-type.py answer --session <id|name> --ask <spec>` answers an open Ask box (digit, option label, `esc`, `free:<text>`, `multi:<d,d>`) or a permission prompt (digit or `esc`), and the review page (`1`). Anything else on screen is refused with nothing typed.
- Every delivery and refusal is appended to `<profile>/credo/owner-type.log` (time, session id, mode, character count, result); message text only with `CREDO_OWNER_TYPE_LOG_TEXT=1`.
