---
bump: patch
---

### Fixed

- Two sessions of one project could issue the same typed code (two questions under one `Q382`), so the owner's answer was ambiguous. Every new T, Q or V number now comes from one locked counter per project, shared by all sessions. The SessionStart legend, the verify skill and the compact-plus handoff note say to take each new number from that counter; the handoff's next free number is informational only.

### Added

- `scripts/credo-code-next.sh T|Q|V [count]` prints the next free number or numbers of that type, one per line. The counter (`code-counters` in the project's `.credo`) never goes down, and it is raised above the highest code found in the project's requirements logs and handoffs, with a warning on stderr. A hub or a cwd without a project uses a counter in the active profile's credo dir.
- `scripts/credo-counter-lib.sh`: the lock, read and atomic write that `credo-id-next.sh` and `credo-code-next.sh` now share.
