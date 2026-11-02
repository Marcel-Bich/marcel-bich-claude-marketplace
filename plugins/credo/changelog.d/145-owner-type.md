---
bump: patch
---

### Added

- `credo-owner-type.py send --session <id|name> (--text T | --stdin) [--force-append]` types the owner's message into a session's tmux pane and presses Enter. The session is looked up in the session registry and must be live with a pane that still belongs to it. Works while the session runs (the text is queued by Claude Code) when the input field is empty; `--force-append` appends after the existing text, which is sent together with it and never deleted by the tool. Multi-line text is typed with a backslash and Enter; each line break and the final Enter are checked, and a line break that submits early is reported as partly sent.
- `credo-owner-type.py show --session <id|name>` prints the open Ask box or permission prompt, with the command text of a permission prompt, and its digest.
- `credo-owner-type.py answer --session <id|name> --ask <spec>` answers an open Ask box (digit, option label, `esc`, `free:<text>`, `multi:<d,d>`), one question per call, or a permission prompt (digit or `esc`), and the review page (`1`). A permission prompt needs `--expect <digest>` from `show`; the prompt is checked again right before each key. An option that keeps approval for later prompts needs `--persist`. Anything else on screen is refused with nothing typed.
- Every delivery and refusal is appended to `<profile>/credo/owner-type.log` (time, session id, mode, character count, result, option label); message text only with `CREDO_OWNER_TYPE_LOG_TEXT=1`.
