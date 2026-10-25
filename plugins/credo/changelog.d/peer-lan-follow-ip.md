---
bump: patch
---

### Fixed

- peer-lan: a dial now advertises the self address as it is at dial time (re-read from the network detection, or the route lookup natively; a configured advertise_host still wins). Before, the re-dial right after a DHCP address change advertised the old address until the next network recheck, and the peer refused the moved pairing (pending repair) instead of following it to the new address inside its allowlist.
