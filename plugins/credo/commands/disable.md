---
description: credo - Disable credo for this directory (silence onboarding and the [credo] line here, reversible)
arguments: none
allowed-tools:
  - Bash(${CLAUDE_PLUGIN_ROOT}/scripts/credo-dir-decision.sh:*)
  - Bash(${CLAUDE_PLUGIN_ROOT}/hooks/session-mode-set.sh:*)
  - Skill
---

# Disable credo here

Turn credo off for the current directory: remember this directory as declined (so the
SessionStart onboarding ASK and the `[credo]` prompt line stay silent here), clear the active
session mode for this session, and switch keep-alive autonomy off.

**Invoke the `disable` skill via the Skill tool.** The skill holds the full logic and the
confirmation wording. This is reversible with `/credo:enable`.
