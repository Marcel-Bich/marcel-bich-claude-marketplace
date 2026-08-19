---
description: credo - Enable credo for this directory (opt in; overrides a previous decline)
arguments: none
allowed-tools:
  - Bash(${CLAUDE_PLUGIN_ROOT}/scripts/credo-dir-decision.sh:*)
  - Skill
---

# Enable credo here

Opt this directory back in to credo: the SessionStart onboarding ASK stops and credo's
knowledge is re-fed on the next SessionStart. Overrides a previous `/credo:disable`.

**Invoke the `enable` skill via the Skill tool.** The skill holds the full logic and the
confirmation wording.
