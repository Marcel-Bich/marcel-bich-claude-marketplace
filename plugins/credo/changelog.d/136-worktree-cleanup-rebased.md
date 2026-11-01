---
bump: patch
---

### Changed

- Worktree cleanup counts a rebased branch as merged when every commit is patch-equivalent in the base; the worktree is removed, the branch is kept because `git branch -d` refuses it, and the output gives `git branch -D <branch>` for the owner to run
- Worktree cleanup also runs after every release, not only at item close
- A merged worktree that is locked, has uncommitted or untracked files, or has a live process inside is kept and marked `(ask owner)` instead of being removed; untracked files now count as changes, ignored files still go with the worktree
- The periodic reminder asks to clean up merged worktrees and branches with the cleanup script
