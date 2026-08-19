---
description: credo - Set this session's default role to task/build (owns implementing GO items incl. commits/push per dogma)
arguments: none
allowed-tools:
  - Bash(${CLAUDE_PLUGIN_ROOT}/hooks/role-set.sh:*)
  - Skill
---

# Session Role: task / build

Set the persistent, per-session credo ROLE to **task / build**: the default owner of
implementing GO items (items in `2_go/`), INCLUDING commits and push where dogma
permissions allow. The role is a guiding default, orthogonal to the session mode, and an
explicit user instruction always overrides it.

**Invoke the `role-task` skill via the Skill tool.** The skill writes the persistent,
compact-safe marker (via `role-set.sh task`, re-injected every turn) and holds the
confirmation wording. Clear it any time with `/credo:role-clear`.
