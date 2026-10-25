---
bump: patch
---

### Fixed

- peer-lan: a paired peer that followed its address is now also dialed at that address, from the persisted pairing record and under the same outbound gate. Before, only the configured address was dialed, so after a restart the side with the stale address could not restore the link until the other side dialed. Rosters go to the followed address too, and a roster over a followed inbound link is no longer flagged as coming from an unexpected address. A pairing that was followed before this release is marked on the first start, so it is dialed at its new address from then on.
