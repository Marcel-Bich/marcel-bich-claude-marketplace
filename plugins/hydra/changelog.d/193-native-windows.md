---
bump: minor
---
### Fixed

- The worktree guard no longer switches itself off silently on native Windows: Python is found as `python3`, then `python`, then `py -3` (the Microsoft Store stub is rejected). Without any Python 3 it denies the worktree creations it cannot check and shows a one-time message.
- The worktree guard compares MSYS (`/c/...`) and Windows (`C:/...`, `C:\...`) paths correctly and case-insensitively; a `git worktree add` destination on another drive is denied instead of passing through a relpath error.
- `worktree-setup.sh` creates native Windows symlinks in Git Bash instead of silently copying the linked paths; when Windows refuses symlinks it skips the path with a Developer Mode hint. It no longer needs Python for relative link targets (`realpath --relative-to`), runs dogma's list script through `${BASH:-bash}` (a bare `bash` can be the WSL launcher on Windows), reads Windows `installPath` entries, and no longer exits silently when the last installed dogma version lacks `worktree-files.sh`.
- `/hydra:watch` uses the output file path the tools report instead of a hard-coded `/tmp/claude` path.

### Added

- Windows test suite `scripts/test-windows.sh` (Python probe, guard without Python, Windows path handling, native symlink setup).
