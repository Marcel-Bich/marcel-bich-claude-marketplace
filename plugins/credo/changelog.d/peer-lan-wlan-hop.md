---
bump: patch
---

### Fixed

- peer-lan: the advertised self address follows the active WLAN when the machine hops between two bound networks. The WSL network probe no longer falls back to the route of an adapter that is not up (that adapter's stale address was advertised), breaks metric ties by interface index, and gives no answer when there is no default route.
  A probe that started earlier can no longer overwrite the answer of a later one (the recheck, a dial and the start-up probe overlap). The start-up address and the address printed by `check` and `init` now come from the same netinfo the relay advertises. Unbound networks stay off and unknown addresses are still refused.
