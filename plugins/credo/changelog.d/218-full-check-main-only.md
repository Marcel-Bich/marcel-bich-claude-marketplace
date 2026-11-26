---
bump: patch
---

### Fixed

- Builders and reviewers no longer get told to run the project's full check: the subagent
  inject and the orchestration skill say a builder runs only its touched-module tests plus
  the fast check and the main agent runs one full check per merged batch, capped by a shared
  serialising lock (#218)

### Added

- The Agent spawn hook warns (never denies) when a build, review or hard brief contains the
  dogma `all` stage command, a full-check command from `.credo/RULES.md` or a marker such as
  `--full`, "full suite" or "all tests"; it runs in the preset guard's process and
  `CREDO_BRIEF_CHECK=0` turns it off (#218)
