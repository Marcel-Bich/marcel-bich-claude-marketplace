---
bump: patch
---

### Fixed

- A redirect to the literal `/dev/null` after a compound command (loop, group, subshell, `if`, `case`) is no longer reported as a truncate; a normalized or dotdot form of it and a redirect of such a command to a real file still are
- Inline code: a write is refused when the path as written or the file it names through symlinks is protected; a `..` after a symlink is not resolved
- Inline code: string literals that follow each other or are joined by `+`, `.` or `,`, in any quote kinds (`'.git' + "/config"`), are also checked as the path they form, so such writes to protected files are refused
