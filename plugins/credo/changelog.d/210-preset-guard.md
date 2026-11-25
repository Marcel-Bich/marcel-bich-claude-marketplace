---
bump: minor
---

### Changed

- The Agent/Task spawn check (`credo-agent-spawn-check.sh`, decision in the new `scripts/credo-preset-guard.py`) now enforces the active preset as a minimum instead of only warning: a spawn without `model` or `effort`, or with a model/effort pair below every rung of the roles that fit it (Explore/Plan -> explore, others -> build/review/hard), is denied with the minimum pairs and `credo-preset.sh stage <role> <attempt>`
  Equal pairs pass; stronger pairs (model haiku < sonnet < opus < fable, effort low < ... < max) pass with a visible `stronger than preset` line; a fork passes only when the parent's model is at least a rung model. No `preset:` configured means no check; internal errors fail open with a logged warning

### Added

- Preset exceptions for weaker pairs: `preset exception: <all|role,...> -> <model>/<effort>` as a line in `.credo/RULES.md`, or in the handoff `## Rules (temporary)` with an owner source and an unexpired until date
