---
bump: patch
---

### Fixed

- Redirect-like text in an unquoted heredoc body of `cat` or `tee` (`see <dogma>/x`, `a>/x`) is no longer denied as a redirect onto a critical path; command substitutions and backticks in the body are still checked
