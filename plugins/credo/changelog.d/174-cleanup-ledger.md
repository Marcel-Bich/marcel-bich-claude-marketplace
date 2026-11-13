---
bump: minor
---
### Added

- Provenance ledger (`credo-ledger.py` hooks): every Bash/Write/Edit call records what it created (birth time after the call's mark in `/tmp`, `/dev/shm`, `.credo/sandbox-tmp`, `<main>-worktrees` and, in the background, `$HOME`; new files of Write/Edit), per session id with device+inode, so the main agent inherits its subagents' entries. Only hooks write the ledger; tool calls that write it are denied. Nothing under `~/.claude*/` is ever recorded.
- `credo-cleanup.py`: `own-rm` removes ledger-owned paths without a prompt (never follows symlinks, never crosses file systems; refuses the home, `~/.claude*/**`, mounts, linked worktrees, repositories outside the temp roots, git-tracked files, ambiguous entries and the local `cleanup.keep_paths`), plus `keep`, `report`, `purge` (done-gate), `item-close`, `sweep`, `worktrees`, `caches`, `playwright-prune` and `rescue-credo`. Refusals are report lines, never blockers.
- Provenance checks before every delete: the whole tree must be born after the ledger entry (or the session dir) with no modification time older than its birth, so data moved in, extracted or copied with preserved times is reported, never deleted; deletion runs on file descriptors without following symlinks, re-checks each inode, and refuses any mount point at or below the target (bind mounts via `/proc/self/mountinfo`). The automatic paths (item-close, purge, sweep) additionally require the deepest change to be 30 minutes old, no socket/fifo and no process inside; purge removes only Write-created temp entries and session TMPDIR children, Bash-recorded entries are listed.
- Per-session `TMPDIR` (`/tmp/credo-tmp-<uid>/<session_id>`) exported through `CLAUDE_ENV_FILE` at SessionStart; idle entries are cleared at item close, the dir is swept once the session no longer runs.
- Daily Playwright prune. Browser revisions no `playwright-core/browsers.json` on disk names are removed; `mcp-chrome-*` and unknown names are never touched, and nothing is ever installed.
- Config block `cleanup:` (`enabled`, `session_tmpdir`, `keep_paths`, `cache_caps`), read from the local layers only.

### Changed

- Writes into a real `.credo/` of a linked worktree are denied with the main-checkout path; `credo-worktree-cleanup.sh` rescues stray `.credo` files into the main checkout first and reports unmerged worktrees with `--details` (unique commits, uncommitted changes, size). SessionStart runs the merged-worktree cleanup in the background.
- Items DoD point 7: the agent removes its own leftovers before done; failures are listed, never asked about. The verify skill states that raising Playwright is an install that needs the owner's consent.
