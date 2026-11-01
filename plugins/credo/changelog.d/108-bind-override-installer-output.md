---
bump: patch
---

### Added

- `bind --adapter <name>` and `bind --subnet <cidr>` override the auto-detected adapter and subnet for the network fingerprint; the relay matches through the adapter when one is stored.
- The elevated Windows `-Install` prints an explicit `-Install OK` line or a `-Install FAILED` line with the reason, and exits 1 on failure. The installer script version is bumped to 4.
