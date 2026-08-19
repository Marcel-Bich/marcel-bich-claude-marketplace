---
description: credo - Clear this session's default role (back to no role; the agent does everything)
arguments: none
allowed-tools:
  - Bash(${CLAUDE_PLUGIN_ROOT}/hooks/role-set.sh:*)
  - Skill
---

# Session Role: clear

Clear the persistent, per-session credo ROLE, returning to the default of NO role: the
agent does everything, as it does when no role is set.

**Invoke the `role-clear` skill via the Skill tool.** The skill removes this session's role
marker (via `role-set.sh clear`) and holds the confirmation wording.
