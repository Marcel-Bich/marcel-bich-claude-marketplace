---
bump: patch
---

### Changed

- Worktree cleanup removes a merged worktree whose only changes are `.credo/` files whose lines all already exist in the same file of the main checkout (lossless), as a clean worktree is removed, when the cleanup setting is `[x]`. A repeated line needs a second copy in the main checkout. With `[?]` such a worktree is listed as a candidate, with `[ ]` it is kept. A `.credo/` file with a NUL byte is never lossless.
- A real ignored file under `.credo/` makes the worktree dirty, so it is kept as an owner question. A setup link into the main checkout (`.credo` or one file as a symlink) does not count as a change.
- An untracked symlink into the main checkout, such as a setup link for `node_modules`, is no longer a change, so the worktree is removed like a clean one. A symlink pointing elsewhere still counts.
- The live-process check runs again right before a lossless worktree is removed.
- If the cleanup setting cannot be read (helper missing or failing), it is treated as `[ ]`, not as an unanswered question.
- Subagents and the orchestration skill write `.credo/` changes into the main checkout path, never into the worktree copy.

### Added

- `credo-worktree-cleanup.sh --allow-lossless <path|branch>` approves one lossless worktree for one run after the owner answered yes. Repeatable; a bare `--allow-lossless` is an error. It never overrides `[ ]`. The item-close hint prints one `--allow-lossless <branch>` per listed lossless candidate.
