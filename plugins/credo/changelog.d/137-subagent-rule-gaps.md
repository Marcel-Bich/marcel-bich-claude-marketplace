---
bump: patch
---

### Fixed

- Subagent priming no longer forbids commits on a subagent's own linked worktree branch; the main checkout rule stays and push, merge and release stay with the main agent
- A repo's `.credo/RULES.md` overrides the early hand-back on an unchanged finding; an audit subagent no longer declares a brake, and while preset attempts are left the main agent decides the next fix round, never the owner
- Subagents are told to read the repo's `.credo/RULES.md` first when it exists
- The preset ladder note for until-done stages states the same RULES.md switch

### Added

- `PreToolUse` check on Agent and Task calls (`credo-agent-spawn-check.sh`): warns, never blocks, when a spawn has no model or effort, or a model/effort pair outside the active preset ladder; the warning names `credo-preset.sh stage <role> <attempt>` and the ladder per role
- Blocker and owner-decision claims of a subagent are proposals; the main agent verifies the cited source before it asks the owner or declares a blocker
- Every brief carries the repo's mandatory brief lines from `.credo/RULES.md`
