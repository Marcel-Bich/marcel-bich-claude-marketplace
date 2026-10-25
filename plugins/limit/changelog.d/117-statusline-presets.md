---
bump: minor
---

### Added

- `CLAUDE_MB_LIMIT_PRESET` selects the statusline layout: `professional` (default), `casual` or `enthusiast`. A per-feature variable set explicitly still wins over the preset

### Changed

- The default statusline is now `professional`: no Tokens, Context or local highscore lines. Set `CLAUDE_MB_LIMIT_PRESET=enthusiast` to keep the previous layout

### Fixed

- Scoped limit lines (e.g. `7d <Model>`) and the Opus line are hidden at 0 % utilization, like the Sonnet line
