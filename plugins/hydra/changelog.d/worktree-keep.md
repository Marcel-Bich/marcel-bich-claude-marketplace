---
bump: patch
---

### Added

- `/hydra:cleanup` documents the keep marker: locked worktrees are kept and shown with their lock reason, with the commands to keep (`git worktree lock --reason "keep: owner" <path>`), list and release (`git worktree unlock <path>`) them; unlocking asks the user first

### Fixed

- `/hydra:cleanup` no longer tells agents to run `git worktree remove --force`, which dogma's bash-guard denies: it removes without the force flag and, for a verified merged+clean worktree with untracked scratch, uses credo's cleanup script or hands the forced command to the user
