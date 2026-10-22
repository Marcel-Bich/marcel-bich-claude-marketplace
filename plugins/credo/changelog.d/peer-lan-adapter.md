---
bump: patch
---

### Fixed

- peer-lan network detection under WSL now ignores default routes of Windows adapters that are not connected or only have a link-local 169.254 address (a disconnected Ethernet adapter with a lower metric no longer hides the active WLAN); falls back to all routes when none belongs to a connected adapter with a usable address.
