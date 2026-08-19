---
description: credo - Set the session mode to autonomous (work approved GO items unattended, hook-enforced keep-alive ON)
arguments: none
allowed-tools:
  - Bash(${CLAUDE_PLUGIN_ROOT}/hooks/session-mode-set.sh:*)
  - Bash(${CLAUDE_PLUGIN_ROOT}/scripts/credo-dir-decision.sh:*)
  - Skill
---

# Session Mode: autonomous

Set the persistent, per-session credo mode to **autonomous**.

Use this ONLY when full autonomy plus AFK has been explicitly granted.

1. Run: `${CLAUDE_PLUGIN_ROOT}/hooks/session-mode-set.sh autonomous`
   This writes the per-session state (keyed by the current session_id) and turns
   keep-alive ON (sets `credo-autonomy-active`, lifts the
   `credo-autonomy-paused` opt-out). Keep-alive is hook-enforced: a registered
   Stop hook blocks a stop that has no scheduled ScheduleWakeup and instructs the
   model to set one, and a registered UserPromptSubmit hook turns autonomy off on
   any real user message (see the loaded skill).
2. Remember this directory as opted-in (persistent, per-directory), so a future session here
   skips the onboarding ASK - the same effect as accepting the ASK: `${CLAUDE_PLUGIN_ROOT}/scripts/credo-dir-decision.sh set accepted`
3. Load the skill `session-autonomous` and follow its rules strictly (budget
   caps, ntfy per task and question, ScheduleWakeup plus wake marker,
   compact-plus).
4. Load the `items` skill now (the credo work-item model and done-gate), UNLESS it is
   already active in your current context - do not reload it if you already have it. This
   puts the item model and go-gate in context before you act on approved GO items.
5. Read the approved GO order back verbatim before you start.
