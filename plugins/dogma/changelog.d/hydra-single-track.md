---
bump: patch
---

### Changed

- The per-prompt orchestration inject says that while hydra is installed every worktree is created via hydra, also for a single isolated track; the Agent tool with `isolation: "worktree"` and a bare `git worktree add` outside `../<repo>-worktrees` are named as not allowed
