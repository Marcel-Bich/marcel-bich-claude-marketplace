---
bump: minor
---

### Added

- A paired LAN peer whose DHCP address changes follows its pairing without confirmation once its key proof succeeds from its newly advertised, allowlisted address (behind the WSL NAT gateway the key proof and the allowlist decide); the old address stays reserved for 7 days, and `CREDO_PEER_LAN_FOLLOW_ADDRESS=0` keeps the refusal and the pending repair (`pair-reset`)
