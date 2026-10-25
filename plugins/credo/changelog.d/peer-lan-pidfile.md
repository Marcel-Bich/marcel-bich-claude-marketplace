---
bump: patch
---

### Fixed

- A running relay daemon rewrites its pidfile when the file is missing, so `status` no longer reports a running relay as "not running" and `start` no longer launches a second daemon that exits at once.
- A relay that holds its port without a readable pidfile is found by that port. `status` reports it with the pid unknown, `start` and `ensure` leave it running, and `restart` and `stop` refuse to act on an unverified pid (exit 1).
