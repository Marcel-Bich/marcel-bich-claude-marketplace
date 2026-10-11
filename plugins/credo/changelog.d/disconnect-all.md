---
bump: minor
---

### Added

- LAN relay `disconnect-all` (`--dry-run`, `--yes`, `--full`) resets the relay to "no other device known": removes the pairings, pending repairs, trust grants, stored peer addresses and LAN mirrors of every served profile, then restarts the relay. It lists what goes and asks first; the slash command `/credo:peer-lan disconnect-all` explains it and asks before running it
- `disconnect-all --full` also removes the Windows-side setup under WSL (scheduled task, firewall rule, portproxy) through the setup's own `credo-peer-lan-winproxy.ps1 -Uninstall`, with one elevated prompt; elsewhere it is skipped with a note
- Kept by `disconnect-all`: this machine's identity, the bound networks and their allowlists, the `profiles` list, the listen settings and the token
