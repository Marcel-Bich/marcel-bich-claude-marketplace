---
bump: patch
---

### Fixed

- A redirect to the literal `/dev/null` after a compound command (loop, group, subshell, `if`, `case`) is no longer reported as a truncate; a normalized or dotdot form of it and a redirect of such a command to a real file still are
- Inline code paths are also checked as the file a symlink names, so a write through a symlink to a protected file is refused
- Inline code string literals joined by implicit concatenation (`'.git' '/hooks/pre-commit'`) or by `+` (`'DOGMA-PERM' + 'ISSIONS.md'`) are also checked as the path they form, so such writes to protected files are refused
