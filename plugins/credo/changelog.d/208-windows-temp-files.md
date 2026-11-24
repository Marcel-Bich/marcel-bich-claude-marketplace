---
bump: patch
---

### Fixed

- Agents no longer strand Windows-side temp files they cannot delete: the `wsl-env` skill and
  the subagent inject say to keep such files in the session TMPDIR and hand Windows tools the
  `wslpath -w` path (`\\wsl.localhost\<distro>\...`); reading through it was measured at a few
  milliseconds extra per note
- `credo-cleanup.py own-rm` on WSL also removes a single file this session's Write tool created
  in a Windows temp dir (`%TEMP%`, `C:\Users\Public`, `C:\tmp` as `/mnt/<drive>/...`): drvfs has
  no birth time, so the ledger records it when the pre hook saw no file and its change time is
  not older than the call, and the NTFS file id must be unchanged; deleted through drvfs, same
  2-minute rule, everything else stays report-only
