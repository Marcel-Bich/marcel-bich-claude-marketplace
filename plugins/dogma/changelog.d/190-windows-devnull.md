---
bump: patch
---
### Fixed

- A harmless `2>/dev/null` or `>/dev/null` is no longer blocked on native Windows as "overwrite of a protected path (C:devnull)". File protection (and git permissions and dependency verification, through the shared findings helper) ran the shell-aware analysis through `python3` by name; with a native Windows Python that analysis resolved `/dev/null` to `C:\dev\null`. The analysis now runs only under a POSIX Python 3 (otherwise the text rules decide), refuses to judge under a native Windows Python, and treats the literal redirect targets `/dev/null`, `/dev/stdout`, `/dev/stderr` and `/dev/fd/N` as no files on every platform.
- The delete guard's text fallback (no POSIX Python 3) now also blocks redirects and `tee` onto protected paths (`> /etc/passwd`, `>> ~/.bashrc`, the home level, system dirs, devices, Windows system and profile config paths); deletes stay blocked as before.
- No dogma hook or helper needs a binary named `python3` any more: Python is looked up as `python3`, then `python`, then `py -3` (python.org ships no `python3.exe`), the Microsoft Store stub is still rejected. The notice hook, `notices-pending.sh`, `source-cache.sh`, `permissions-summary.sh` and `worktree-files.sh` only parse JSON or text and also accept a native Windows Python (UTF-8 I/O, CRLF output turned into LF).
