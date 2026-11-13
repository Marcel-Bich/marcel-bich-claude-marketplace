---
bump: patch
---
### Added

- WSL <-> Windows peer bridge (`credo-win-bridge.py` with `credo-win-bridge.ps1`): under WSL with Windows interop, native Windows Claude Code sessions of the same user appear in `ListAgents` of WSL sessions and the WSL sessions appear on Windows; `SendMessage` and replies work both ways. Windows inboxes get the auth line from the target's own key file, read only on Windows. Started by a SessionStart hook; off with `peer.win_bridge.enabled: false` or `CREDO_WIN_BRIDGE=0`.
- The LAN relay publishes the bridged Windows sessions to its LAN peers, and its mirrors of remote sessions are offered on Windows, so Windows sessions of a WSL machine reach the LAN peer network.
- Native Windows LAN relay (`credo-peer-lan-win.ps1`, PowerShell only, no admin): a Windows machine without WSL joins the LAN peer network as an unpaired relay over an outbound link, with a fail-closed network binding and a per-user scheduled task (`-Action Init`, `-Action Install`).
- `/credo:peer-lan win-bridge [status|start|stop]`.
