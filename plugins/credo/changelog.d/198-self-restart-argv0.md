---
bump: patch
---

### Fixed

- `/credo:self-restart` keeps a bare original argv0 (e.g. `claude`) in the relaunch, so a
  wrapper or shim earlier on PATH still applies; the resolved absolute path is only used
  as a fallback when the launcher's PATH does not find the name
