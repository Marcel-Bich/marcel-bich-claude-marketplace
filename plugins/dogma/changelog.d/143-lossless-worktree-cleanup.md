---
bump: patch
---

### Changed

- Auto worktree cleanup option names the lossless case: a merged worktree whose only leftovers are `.credo/` changes already present in the main checkout is removed too; setup symlinks into the main checkout do not count as changes
