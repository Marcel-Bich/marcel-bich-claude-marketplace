---
bump: patch
---

### Fixed

- A `/credo:project` session pin now sets the whole project config: from a hub cwd, `credo-config.sh get`, `source`, `paths`, `backend` and the model preset (SessionStart, `credo-preset.sh`) read the pinned repo's `.credo/config` instead of the hub's, and the hooks that read them pass their session id on
