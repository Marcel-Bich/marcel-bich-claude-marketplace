---
bump: minor
---
### Added

- Provenance ledger (`credo-ledger.py` hooks): every Bash/Write/Edit call records what it created (birth time after the call's mark in `/tmp`, `/dev/shm`, `.credo/sandbox-tmp`, `<main>-worktrees` and, in the background, `$HOME` without crossing into other file systems; new files of Write/Edit), per session id with device, inode and birth time. Nothing under `~/.claude*/` is ever recorded. Tool calls that write the ledger or the keep list are denied (a guard against mistakes, documented as not proof against the same user).
- `credo-cleanup.py own-rm` deletes without a prompt only in three places: the session TMPDIR and scratchpad, Write/Edit-created entries in temp dirs confirmed by the session transcript, and ignored build output of the agent's own worktree. Everything the Bash birth-time scan found, home and worktrees-dir entries and kept results are report-only. Every delete checks the whole tree (born after the entry, no older modification times, no mounts incl. bind mounts, no worktree or foreign repository, nothing git-tracked, no socket, no process inside, no change within 2 minutes) and runs on file descriptors without following symlinks. Also `keep`, `report`, `purge` (done-gate), `item-close` (report only), `sweep`, `worktrees`, `caches`, `playwright-prune` and `rescue-credo`. Refusals are report lines, never blockers.
- No environment overrides at runtime: the home comes from the password database and session ids must be UUIDs, so an env prefix cannot widen what the helper deletes.
- Per-session `TMPDIR` (`/tmp/credo-tmp-<uid>/<session_id>`, private base) exported through `CLAUDE_ENV_FILE` at SessionStart (config read capped at 3 s, fail open); listed at item close, removed by the sweep after the session ended.
- Daily Playwright prune: browser revisions that no installation names (Node, pnpm, Python and .NET driver, Java jar) and no running process uses are removed; `mcp-chrome-*` and unknown names are never touched, anything unclear prunes nothing, and nothing is ever installed.
- Config block `cleanup:` (`enabled`, `session_tmpdir`, `keep_paths`, `cache_caps`), read from the local layers only.

### Changed

- Writes into a real `.credo/` of a linked worktree are denied with the main-checkout path; `credo-worktree-cleanup.sh` rescues stray `.credo` files into the main checkout first (never an item that lives under another status folder) and reports unmerged worktrees with `--details` (unique commits, uncommitted changes, size). SessionStart runs the merged-worktree cleanup in the background.
- Items DoD point 7: the agent removes its own leftovers before done; failures are listed, never asked about. The verify skill states that raising Playwright is an install that needs the owner's consent.
