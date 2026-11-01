---
bump: patch
---

### Changed

- Worktree cleanup removes a merged worktree whose only changes are `.credo/` files whose lines all already exist in the same file of the main checkout (lossless), as a clean worktree is removed, when the cleanup setting is `[x]`. A repeated line needs a second copy in the main checkout. With `[?]` such a worktree is listed as a candidate, with `[ ]` it is kept.
- An untracked symlink into the main checkout, such as a setup link for `node_modules`, is no longer a change, so the worktree is removed like a clean one. A symlink pointing elsewhere still counts.
- Subagents and the orchestration skill write `.credo/` changes into the main checkout path, never into the worktree copy.

### Added

- `credo-worktree-cleanup.sh --allow-lossless` approves the removal of lossless worktrees for one run after the owner answered yes. It never overrides `[ ]`.
