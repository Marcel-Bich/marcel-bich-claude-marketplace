---
bump: patch
---

### Fixed

- Declining credo in a directory, or for a session, no longer hides the model preset. The SessionStart hook keeps injecting the preset instructions; only the items workflow stays off there.
- The preset block also reaches the main agent in a session that has not made a credo decision yet, and under the gsd task backend.
- The `/credo:disable` description states that model presets and shorthands stay on.
- `/credo:disable` also records the current session as declined, so a session that was already active stops getting the workflow text on resume and compact.

### Changed

- The preset block carries a one-line rule for every subagent spawn. It points to `credo-preset.sh stage <role> <attempt>`, which supplies the model, effort and prompt.
