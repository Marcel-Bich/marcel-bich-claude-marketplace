---
description: credo - Set this session's default role to plan/clarify (owns clarifying 1_clarify items, no commits/push)
arguments: none
allowed-tools:
  - Bash(${CLAUDE_PLUGIN_ROOT}/hooks/role-set.sh:*)
  - Skill
---

# Session Role: plan / clarify

Set the persistent, per-session credo ROLE to **plan / clarify**: the default owner of
clarifying items in `1_clarify/`, WITHOUT commits or push (the task/build role owns commits
and push, so a single index owner avoids the `.git/index.lock` race). The role is a guiding
default, orthogonal to the session mode, and an explicit user instruction always overrides it.

**Invoke the `role-plan` skill via the Skill tool.** The skill writes the persistent,
compact-safe marker (via `role-set.sh plan`, re-injected every turn) and holds the
confirmation wording. Clear it any time with `/credo:role-clear`.

For writing clarify pre-work without production code (a measurement, mockup, or feasibility
proof), use the `sandbox` skill; promote accepted artifacts with `/credo:sandbox-promote`.
