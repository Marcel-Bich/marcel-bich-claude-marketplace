---
bump: minor
---

### Changed

- The Agent/Task spawn check (`credo-agent-spawn-check.sh`, decision in the new `scripts/credo-preset-guard.py`) now enforces the active preset as a minimum instead of only warning: a spawn without `model` or `effort`, or with a model/effort pair below every rung of the roles that fit it (Explore/Plan -> explore, others -> build/review/hard), is denied with the minimum pairs and `credo-preset.sh stage <role> <attempt>`
  Equal pairs pass; stronger pairs (model haiku < sonnet < opus < fable, effort low < ... < max) pass with a visible `stronger than preset` line; a fork passes only when the parent's model is at least a rung model. No `preset:` configured means no check; internal errors fail open with a logged warning

- The subagent DELEGATION rule now says helpers get model and effort per the active preset (absolute `credo-preset.sh stage <role> <attempt>`), never below it, with a role tag; stronger only on purpose (was "at least as capable as yours")
- The SessionStart per-spawn rule asks for the role tag in the Agent description

### Added

- Role tag `[credo-role: explore|build|review|hard]` in the Agent description or prompt: the spawn guard then checks only that role's ladder; without a tag, read-only types (Explore, Plan, web-fetch, claude-code-guide, `*:cavecrew-investigator`) count as explore

- Preset exceptions for weaker pairs: `preset exception: <all|role,...> -> <model>/<effort>` as a line in `.credo/RULES.md`, or in the handoff `## Rules (temporary)` with an owner source and an unexpired until date
