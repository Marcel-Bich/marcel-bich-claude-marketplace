---
bump: patch
---

### Fixed

- A dogma script run through an interpreter (`bash`, `sh`, `python3`, ...) is no longer denied as a write; writes into the installed plugin stay blocked
