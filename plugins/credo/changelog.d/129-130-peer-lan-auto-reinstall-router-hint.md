---
bump: patch
---

### Added

- LAN peer relay: `check` and `start` re-run the elevated Windows `-Install` themselves when the installed proxy script is outdated (WSL, interactive sessions only, one attempt per session; the user only confirms UAC)
- LAN peer relay: while a router-change or Public-category hint is pending, a send to a LAN peer or a message that came over the relay gets one loud warning, so the agent asks the user once; local peers get nothing
