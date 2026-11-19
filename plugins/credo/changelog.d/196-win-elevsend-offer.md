---
bump: patch
---

### Fixed

- `credo-win-bridge.py elevsend-install` no longer crashes after a successful install
  when Windows prints in its OEM code page; every text-mode subprocess call of the
  bridge and the LAN relay decodes tolerantly

### Added

- One offer to install the elevated sender helper wherever peers are used: when the WSL
  bridge has seen a Windows session that runs as administrator and the helper is missing
  or outdated, `/credo:setup`, `credo-peer-lan.py check`/`start`/`status`,
  `credo-win-bridge.py status`, the peer check and the bridge log show one line with the
  exact install command (`credo-win-bridge.py elevsend-offer` prints it)
