---
bump: patch
---

### Fixed

- `credo-worktree-cleanup.sh` no longer ends silently with exit 141 on a repo with many worktrees. Reading only the main block of `git worktree list --porcelain` made git die of SIGPIPE, which `pipefail` turned into a silent abort; the list is now read to the end.
