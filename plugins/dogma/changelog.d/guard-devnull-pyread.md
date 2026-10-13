---
bump: patch
---

### Fixed

- A redirect to `/dev/null` after a compound command (loop, group, subshell, `if`, `case`) is no longer reported as a truncate; a redirect of such a command to a real file still is
- Inline python `open()` without a write mode (no mode, `r`, `rb`, `rt`) on a dogma hook file is a read and no longer denied; write, append, create and update modes stay denied
- Inline python paths are also checked as the file a symlink names, so a write through a symlink to a dogma hook file is denied
