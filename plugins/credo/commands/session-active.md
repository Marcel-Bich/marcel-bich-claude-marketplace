---
description: credo - Set the session mode to active (intensive live collaboration, no keep-alive)
arguments: none
allowed-tools:
  - Bash(${CLAUDE_PLUGIN_ROOT}/hooks/session-mode-set.sh:*)
  - Skill
---

# Session Mode: active

Set the persistent, per-session credo mode to **active**.

1. Run: `${CLAUDE_PLUGIN_ROOT}/hooks/session-mode-set.sh active`
   This writes the per-session state (keyed by the current session_id) and turns
   the keep-alive autonomy OFF (clears `credo-autonomy-active`, sets the
   `credo-autonomy-paused` opt-out).
2. Load the skill `session-active` and work by its rules from now on.
3. Confirm briefly: mode active, keep-alive off.
