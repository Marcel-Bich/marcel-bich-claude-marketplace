---
bump: patch
---

### Changed

- `init` warns when an added peer address is not reachable from this machine; a peer behind NAT should run `init` towards this machine instead, and the return channel carries the traffic
- A pending repair is dropped once its address is no longer a configured peer (daemon start, `init`, `check`, `pairs`); the pairing itself is never touched
- `check` adds a hint under a pending repair whose address is not reachable from this machine

### Fixed

- A roster send to an unreachable peer is logged once when the peer goes down and once when it recovers, instead of on every roster interval
- `peer-lan.log` is rotated to a single `peer-lan.log.1` backup when it exceeds 5 MB, so the log no longer grows without bound
