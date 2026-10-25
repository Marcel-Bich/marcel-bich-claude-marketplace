---
bump: patch
---

### Fixed

- A running relay daemon rewrites its pidfile when the file is missing or names no live credo daemon, so `status` no longer reports a running relay as "not running" and `start` no longer launches a second daemon that exits at once. Two live daemons on one pidfile path no longer rewrite it in turn.
- A port held while the pidfile names no live daemon is reported as held (pid unknown, maybe not a credo relay) instead of "not running". `start` refuses to start a second daemon, `ensure` leaves it alone, and `restart`, `stop` and `disconnect-all` refuse to act on it and print the manual recovery steps.
