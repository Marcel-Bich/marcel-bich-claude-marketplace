---
bump: minor
---

### Added

- Worktree guard (PreToolUse hook): while hydra is installed and the Hydra checkbox in DOGMA-PERMISSIONS.md is on, the Agent tool with `isolation: "worktree"`, `EnterWorktree` without a `path`, and `git worktree add` in command position to any destination other than `../<repo>-worktrees/<name>` are denied, with the hydra flow named in the reason
- Shell variables, globs and unparseable destinations in `git worktree add` are denied while the guard is active
- Comments, heredoc bodies and quoted text are not checked, only `git` in command position counts; `EnterWorktree` with a `path` (an existing worktree) is allowed

### Changed

- `/hydra:create` and `/hydra:parallel` write the worktree paths literally (no shell variables), so the guard can check them
