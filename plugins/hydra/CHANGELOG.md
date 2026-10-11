Changelog of the hydra plugin. Newest first. Months group releases; no day dates. Releases up to v0.2 are summarized by minor version.

# 2026-10

## v0

### v0.3

#### v0.3.0

##### Added

- Worktree guard (PreToolUse hook): while hydra is installed and the Hydra checkbox in DOGMA-PERMISSIONS.md is on, the Agent tool with `isolation: "worktree"`, `EnterWorktree` without a `path`, and `git worktree add` in command position to any destination other than `../<repo>-worktrees/<name>` are denied, with the hydra flow named in the reason
- Shell variables and globs in the `git worktree add` destination are denied while the guard is active; a command that cannot be parsed is allowed
- Only `git` in command position counts; text in comments, `echo` arguments and `git commit -F -` heredoc messages is not checked. `EnterWorktree` with a `path` (an existing worktree) is allowed
- `/hydra:cleanup` documents the keep marker: locked worktrees are kept and shown with their lock reason, with the commands to keep (`git worktree lock --reason "keep: owner" <path>`), list and release (`git worktree unlock <path>`) them; unlocking asks the user first

##### Changed

- `/hydra:create` and `/hydra:parallel` write the worktree paths literally (no shell variables), so the guard can check them

##### Fixed

- `/hydra:cleanup` no longer tells agents to run `git worktree remove --force`, which dogma's bash-guard denies: it removes without the force flag and, for a verified merged+clean worktree with untracked scratch, uses credo's cleanup script or hands the forced command to the user

### v0.2

#### Added

- Excluded files are linked into new worktrees; untracked paths that are not ignored are skipped
- Agents get the main checkout path and shared cleanup criteria

#### Changed

- Agents commit on their worktree branch, never push or merge

# 2026-01

## v0

### v0.1

#### Added

- hydra plugin for Git worktrees (renamed from the worktree plugin)
- `/hydra:watch` command
- Safety guard against deleting the main worktree
