---
bump: minor
---

### Fixed

- Subagents no longer run a delete whose path contains a shell variable (an empty variable could delete a parent dir); they write the literal path or a fresh scratch dir, so an unattended run is not blocked by a permission prompt
- A permission prompt in an autonomous credo session now sends a high-priority ntfy push, so the owner is called back to the PC
