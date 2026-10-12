---
description: credo - Switch the credo items workflow off for this directory and this session (silence onboarding and the workflow text here; model presets and shorthands stay on, reversible)
arguments: none
allowed-tools:
  - Bash(${CLAUDE_PLUGIN_ROOT}/scripts/credo-dir-decision.sh:*)
  - Bash(${CLAUDE_PLUGIN_ROOT}/scripts/credo-decision-set.sh:*)
  - Bash(${CLAUDE_PLUGIN_ROOT}/hooks/session-mode-set.sh:*)
  - Skill
---

# Disable the credo workflow here

Switch the credo items workflow off for the current directory: remember this directory as declined
(so the SessionStart onboarding ASK and the items workflow text stay silent here), record this
session as declined (so an already active session stops getting the workflow text on resume and
compact), clear the active session mode for this session, and switch keep-alive autonomy off.
Model presets and shorthands stay on.

**Invoke the `disable` skill via the Skill tool.** The skill holds the full logic and the
confirmation wording. This is reversible with `/credo:enable`.
