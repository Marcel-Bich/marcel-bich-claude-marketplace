---
bump: minor
---

### Added

- A paired LAN peer whose DHCP address changes follows its pairing without confirmation once it connects from its newly advertised, allowlisted address and its key proof succeeds (the old address stays reserved for 7 days); `CREDO_PEER_LAN_FOLLOW_ADDRESS=0` keeps the refusal and the pending repair (`pair-reset`)
