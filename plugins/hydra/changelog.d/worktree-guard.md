---
bump: minor
---

### Added

- Worktree guard (PreToolUse hook): while hydra is installed and the Hydra checkbox in DOGMA-PERMISSIONS.md is on, the Agent tool with `isolation: "worktree"`, `EnterWorktree` without a `path`, and `git worktree add` in command position to any destination other than `../<repo>-worktrees/<name>` are denied, with the hydra flow named in the reason
- Shell variables and globs in the `git worktree add` destination are denied while the guard is active; a command that cannot be parsed is allowed
- Only `git` in command position counts; text in comments, `echo` arguments and `git commit -F -` heredoc messages is not checked. `EnterWorktree` with a `path` (an existing worktree) is allowed

### Changed

- `/hydra:create` and `/hydra:parallel` write the worktree paths literally (no shell variables), so the guard can check them
