---
bump: patch
---

### Fixed

- The automatic merged-worktree cleanup no longer removes a fresh worktree whose branch was only fast-forwarded to main (for example after a sync with main) and has no commit of its own. Such a branch was reported as "merged into main, clean" and removed at once, because the fast-forward added a second reflog entry that skipped the fresh-worktree guard
- A branch counts as having its own commits only when its reflog holds a commit, cherry-pick or revert entry; the 24h fresh guard (`--fresh-hours`) applies to every branch without them. A merged, clean branch with own commits is still removed at once, also when it was merged by fast-forward

### Changed

- The kept reason for a fresh worktree without own commits reads `no commits yet (fresh worktree), created Nh ago - may be in use`
