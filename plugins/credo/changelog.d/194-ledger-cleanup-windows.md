---
bump: patch
---

### Added

- Provenance ledger, cleanup helper and process identity on native Windows (Claude Code native, hooks through Git Bash, a real CPython; stdlib plus ctypes, nothing installed). The ledger records with NTFS facts (creation time, volume serial and file id) in the per-user temp dir from the known-folder API, exports the session TMPDIR with forward slashes and binds a session id through the verified Windows parent chain plus the descriptor's `procStart`.
- Windows safety rules: `own-rm`, `purge` and `sweep` run every check but only report (no equally strong check for other processes' open files and working directories); junctions, symlinks and other reparse points are never followed, recursed into or deleted; anything off a local fixed NTFS/ReFS drive, system trees and the merged-worktree cleanup are report-only. `keep` and `playwright-prune` delete through handles that never follow reparse points, pin every parent directory and re-check the file id first.
- Session registry, peer check and session names read process facts on Windows through ctypes (Toolhelp parent chain, GetProcessTimes, QueryFullProcessImageNameW, the process command line) instead of `/proc`.
- Tests: `test-credo-cleanup-nt.sh` (Windows simulated on Linux) and `test-credo-cleanup-windows.sh` (live under Git Bash with python.exe, fixtures only).

### Fixed

- `credo-ledger.py` and `credo-cleanup.py` no longer exit early on native Windows.
