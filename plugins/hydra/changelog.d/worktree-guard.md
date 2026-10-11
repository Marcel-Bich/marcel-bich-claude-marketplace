---
bump: minor
---

### Added

- Worktree guard (PreToolUse hook): while hydra is installed and the Hydra checkbox in DOGMA-PERMISSIONS.md is on, the Agent tool with `isolation: "worktree"`, `EnterWorktree` and `git worktree add` to any destination other than `../<repo>-worktrees/<name>` are denied, with the hydra flow named in the reason
- Shell variables, globs and unparseable destinations in `git worktree add` are denied while the guard is active

### Changed

- `/hydra:create` and `/hydra:parallel` write the worktree paths literally (no shell variables), so the guard can check them
