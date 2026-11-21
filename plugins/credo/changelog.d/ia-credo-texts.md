---
bump: patch
---

### Changed

- compact-plus has a mode gate for the limit ACTION line. Autonomous mode runs it directly,
  interactive modes ask once (one question covering compact-plus and the real /compact), a
  session that forbids Ask only mentions the ACTION; a manual invocation always runs
- The subagent rule block tells subagents to decide uncritical questions themselves (SOTA,
  else best effort, else note it), honour per-repo grants, log each decision in their report,
  and return `needs_decision` only for owner-only decisions (taste, money, deleting user data,
  installs, safety, infeasible options)
- One open-codes footer form everywhere, with item refs in backticks:
  ``**🧪: T3** · **❓: Q4, `#177`** · **✋: V2, V5**``
- The full test suite timing follows DOGMA-PERMISSIONS. When §8eyz ("run ALL tests only at
  release") is `[x]` it runs only at the release, never at a merge; new orchestration
  section "When the full suite runs"
