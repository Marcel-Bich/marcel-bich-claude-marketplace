---
bump: patch
---

### Fixed

- An installed dogma script given as the first argument of an interpreter (`bash x.sh`, `python3 x.py`) is no longer denied as a write; any option before it, later arguments and every write into the installed plugin stay blocked
