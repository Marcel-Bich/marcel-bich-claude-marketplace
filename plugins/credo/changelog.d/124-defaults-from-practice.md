---
bump: patch
---

### Added

- Config keys `builders.min_per_area` (default 2) and `builders.max_per_area` (default 4) for parallel writing builders per independent area
- Config key `release.auto` (default off) with `release.fallback_fragments` (15) and `release.fallback_days` (7); `/credo:setup` and the migration ask once
- Opt-in config key `dont_ask_twice` (default off): search the requirement logs, items, handoff and earlier Ask answers before asking again
- Idle capacity rule for passive and autonomous mode, and stall limits (30 min or 60 tool calls, stop after 15 min without a step)
- Safety rules: target path check before every write, no deletion through paths with a shell variable, no sensitive data in web searches, licence rule for reused code, own disposable files may be deleted
- Verify rule: flaky tests are fixed, never retried, skipped or deferred

### Changed

- Fix rounds follow the active preset stage ladder instead of a fixed 2-FAIL emergency brake (audit, items, orchestration)
- Resource gate checks CPU and RAM before every agent start and stops at `resources.max_busy_percent` (default 90); `gate_from_agents`, `min_free_ram_gb`, `max_load_per_cpu`, the `--running` and `--heavy` flags are removed
- Builder guidance uses the configured 2-4 range per area instead of a fixed 3-4
- Active mode applies no budget stops; autonomous mode never uses the Ask tool
- Findings beyond the Definition of Done go into one collection item per project instead of their own items
