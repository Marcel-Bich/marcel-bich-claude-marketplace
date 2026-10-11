---
bump: patch
---

### Added

- Worktree cleanup opt-out: `git worktree lock --reason "keep: owner" <path>` keeps a worktree. `credo-worktree-cleanup.sh` never removes a locked worktree and reports it as `kept <path> branch=<b> reason=locked: <lock reason>` (normal, `--dry-run` and JSON with `lock_reason`; a locked worktree whose directory is gone is reported as locked, not as prunable)
- `credo-worktree-cleanup.sh --keep <path|branch>` (repeatable) keeps a worktree for a single run; a `--keep` that matches no worktree warns on stderr
- `credo-worktree-cleanup.sh --list-locked [--json]` lists the locked worktrees with their reasons (no base branch needed)

### Changed

- Skills `items`, `safety`, `orchestration`, `session-autonomous`, README and credo guide: when the user says to keep a worktree the agent locks it with the reason `keep: owner`, names the kept worktrees before an item close, and unlocks only by this rule: autonomous mode may unlock a `keep: owner` lock itself once the keep reason no longer applies, every other mode asks first via the Ask tool, and a lock with another reason is never unlocked on its own
