---
description: credo - Switch the credo items workflow off for this directory (silence onboarding and the workflow text here; model presets stay on, reversible)
arguments: none
allowed-tools:
  - Bash(${CLAUDE_PLUGIN_ROOT}/scripts/credo-dir-decision.sh:*)
  - Bash(${CLAUDE_PLUGIN_ROOT}/hooks/session-mode-set.sh:*)
  - Skill
---

# Disable the credo workflow here

Switch the credo items workflow off for the current directory: remember this directory as declined
(so the SessionStart onboarding ASK and the items workflow text stay silent here), clear the active
session mode for this session, and switch keep-alive autonomy off. Model presets and the shorthand
legend stay on.

**Invoke the `disable` skill via the Skill tool.** The skill holds the full logic and the
confirmation wording. This is reversible with `/credo:enable`.
