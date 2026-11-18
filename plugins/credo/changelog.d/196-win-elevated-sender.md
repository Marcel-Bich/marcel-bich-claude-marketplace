---
bump: minor
---

### Added

- WSL -> Windows peer bridge reaches Windows sessions that run elevated (as
  administrator) again, through an optional elevated sender helper
  (`credo-win-elevsend.ps1`). It is installed once with `credo-win-bridge.py
  elevsend-install` (one UAC prompt) as a scheduled task without a trigger. The bridge
  starts it on demand, and it exits when idle or when no bridge is alive. The bridge
  uses it only after a direct write was denied by an elevated session's inbox, and only
  when the helper pipe is owned by Administrators
- `credo-win-bridge.py status` reports whether the helper is installed or outdated;
  `elevsend-uninstall` removes it, and `credo-peer-lan.py disconnect-all --full` removes
  it in the same elevated run as the LAN relay's Windows side
