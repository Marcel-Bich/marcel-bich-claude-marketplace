---
description: credo - Set the session mode to active (intensive live collaboration, no keep-alive)
arguments: none
allowed-tools:
  - Bash(${CLAUDE_PLUGIN_ROOT}/hooks/session-mode-set.sh:*)
  - Bash(${CLAUDE_PLUGIN_ROOT}/scripts/credo-decision-set.sh:*)
  - Bash(${CLAUDE_PLUGIN_ROOT}/scripts/credo-dir-decision.sh:*)
  - Skill
---

# Session Mode: active

Set the persistent, per-session credo mode to **active**.

1. Run: `${CLAUDE_PLUGIN_ROOT}/hooks/session-mode-set.sh active`
   This writes the per-session state (keyed by the current session_id) and turns
   the keep-alive autonomy OFF (clears `credo-autonomy-active`, sets the
   `credo-autonomy-paused` opt-out).
2. Record the credo decision as accepted: `${CLAUDE_PLUGIN_ROOT}/scripts/credo-decision-set.sh accepted`
   Setting a mode means credo is opted in, so this makes the acceptance durable
   (its knowledge is re-fed after resets even if the mode is ever cleared).
3. Remember this directory as opted-in (persistent, per-directory), so a future session here
   skips the onboarding ASK - the same effect as accepting the ASK: `${CLAUDE_PLUGIN_ROOT}/scripts/credo-dir-decision.sh set accepted`
4. Load the skill `session-active` and work by its rules from now on.
5. Load the `items` skill now (the credo work-item model and done-gate), UNLESS it is
   already active in your current context - do not reload it if you already have it. This
   puts the item model and go-gate in context from the start, instead of only when
   something later happens to trigger them.
6. Confirm briefly: mode active, keep-alive off.
