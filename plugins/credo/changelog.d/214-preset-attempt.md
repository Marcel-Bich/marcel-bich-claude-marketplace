---
bump: minor
---

### Added

- The role tag carries the attempt: `[credo-role: <role>#<attempt>]` (e.g.
  `[credo-role: review#3]`, the same attempt passed to `credo-preset.sh stage`; 1 for the
  first try of a role on the item, plus one per failed try). The spawn guard then checks
  exactly the rung of that attempt: a pair that only reaches an earlier rung is denied, a
  stronger one passes with the visible `stronger than preset` line (#214).
- `preset continue: <all|role,...>` lines (in `.credo/RULES.md`, or as an owner rule with an
  until date in the handoff `## Rules (temporary)`, same rules as `preset exception:`) allow
  continuing past back-to-human on the last real rung of the role.

### Changed

- A role tag without attempt on a role with more than one rung is denied with the
  attempt -> rung map and an example tag; a single-rung role keeps the attempt optional.
- An attempt past the last rung (back-to-human) is denied - the owner decides now - unless a
  `preset continue:` line or a `preset exception:` pair covers the role; such a spawn passes
  with a visible `continuing per owner rule` line.
- Untagged read-only types (Explore, Plan, web-fetch, ...) count as explore attempt 1; other
  untagged spawns still pass on any build/review/hard rung and are asked to tag.
- ok and deny messages name role, attempt, expected rung and chosen pair; a deny gives the
  exact fix (`pass model: opus, effort: medium, tag [credo-role: review#3]`).
- The orchestration skill, README, guide, the subagent DELEGATION rule and the SessionStart
  spawn rule describe the attempt in the tag.
