Changelog of the hydra plugin. Newest first. Months group releases; no day dates. Releases up to v0.2 are summarized by minor version.

# 2026-10

## v0

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
