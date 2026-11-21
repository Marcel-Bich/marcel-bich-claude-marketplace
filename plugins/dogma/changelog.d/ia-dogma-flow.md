---
bump: minor
---

### Changed

- With credo active for the session, dogma's per-prompt workflow injects step back:
  the mandatory orchestration flow (Subagent-First, Hydra and TDD MANDATORY, handoff
  chain, "Run ALL tests") becomes a short pointer at credo orchestration, the planning
  line points at credo items instead of `/create-plan`, the versioning line drops
  "bump version on changes", the skill reminder suggests a credo item (silent in
  credo's autonomous mode), and checklist tracking accepts `dd` or a passed credo
  done gate instead of a Y/n question. Safety hooks and reminders stay unchanged;
  without credo nothing changes.

### Added

- `scripts/lib-credo.sh`: cheap credo detection (session mode, session decision, or
  per-directory opt-in while credo is enabled; fail open), toggle
  `CLAUDE_MB_DOGMA_CREDO_DEFER` (default `true`), tests in `scripts/test-credo-defer.sh`
