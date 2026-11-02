---
bump: patch
---

### Added

- `credo-owner-type.py send --session <id|name> (--text T | --stdin) [--force-append]` types the owner's message into a session's tmux pane and presses Enter. The session is looked up in the session registry and must be live with a pane that still belongs to it. Works while the session runs (the text is queued by Claude Code) when the input field is empty; `--force-append` appends after the existing text, which is sent together with it and never deleted by the tool. Multi-line text is typed with a backslash and Enter; each line break and the final Enter are checked, and a line break that submits early is reported as partly sent.
- `credo-owner-type.py show --session <id|name>` prints the whole dialog block of the open Ask box, review page or permission prompt (verbatim, top rule to footer) and its digest, the sha256 over those rows.
- `credo-owner-type.py answer --session <id|name> --ask <spec> --expect <digest>` answers an open Ask box (digit, option label, `esc`, `free:<text>`, `multi:<d,d>`), one question per call, or a permission prompt (digit or `esc`), and the review page (`1`). Every answer needs `--expect <digest>` from `show`, and the prompt is checked again before every key. Only a permission option whose full label is exactly Yes or No runs without `--persist`; every other option needs it. Anything else on screen, including a dialog-shaped footer above the input box, is refused with nothing typed.
- Every delivery and refusal is appended to `<profile>/credo/owner-type.log` (time, session id, mode, character count, result, option label); message text only with `CREDO_OWNER_TYPE_LOG_TEXT=1`.
