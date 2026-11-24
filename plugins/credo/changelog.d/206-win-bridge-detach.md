---
bump: patch
---

### Fixed

- WSL <-> Windows peer bridge survives the session that started it: the daemon now runs
  as its own transient systemd user service (else a double fork with setsid, SIGHUP
  ignored) instead of inside the starting Claude Code session's systemd scope, with the
  same session-bound and secret-like environment filtering as the LAN relay
- Bridge log lines carry an ISO 8601 timestamp with milliseconds and offset, the daemon
  logs how it was spawned and its cgroup, and every shutdown logs its reason

### Changed

- Detached spawn and daemon log helpers moved into the shared `scripts/credo_detach.py`,
  used by the LAN relay and the WSL bridge (`CREDO_WIN_BRIDGE_SPAWN` mirrors
  `CREDO_PEER_LAN_SPAWN`)
