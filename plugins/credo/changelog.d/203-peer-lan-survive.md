---
bump: patch
---

### Fixed

- LAN relay no longer dies with the session that started it: `ensure`, `start` and
  `restart` launch the daemon as its own transient systemd user service
  (`systemd-run --user --collect`) where a systemd user manager answers, else via a
  double fork with `setsid` and SIGHUP ignored. Before, a daemon started by the
  SessionStart hook stayed in that session's process group and systemd scope and was
  killed with them (`shutting down` without a reason, holders `rc=-15`).
  `CREDO_PEER_LAN_SPAWN` (`auto`, `systemd`, `setsid`) selects the method.

### Added

- Self-healing relay: the autostart hook also runs on UserPromptSubmit, silent and
  throttled to one `ensure` per profile every 5 minutes (`CREDO_PEER_LAN_ENSURE_MINUTES`),
  only for a served profile with a bound network, fail-open.
- `peer-lan.log` lines carry an ISO 8601 local timestamp; the daemon logs its process
  context (parent, process group, session, spawn method, cgroup) at start and the reason
  of every shutdown (signal name plus that context); uncaught exceptions are logged.
