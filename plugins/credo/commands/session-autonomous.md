---
description: credo - Set the session mode to autonomous (work approved GO items unattended, keep-alive intent ON - best-effort)
arguments: none
allowed-tools:
  - Bash(${CLAUDE_PLUGIN_ROOT}/hooks/session-mode-set.sh:*)
  - Skill
---

# Session Mode: autonomous

Set the persistent, per-session credo mode to **autonomous**.

Use this ONLY when full autonomy plus AFK has been explicitly granted.

1. Run: `${CLAUDE_PLUGIN_ROOT}/hooks/session-mode-set.sh autonomous`
   This writes the per-session state (keyed by the current session_id) and turns
   the keep-alive intent ON (sets `credo-autonomy-active`, lifts the
   `credo-autonomy-paused` opt-out). Keep-alive is best-effort and
   instruction-driven: the model schedules its own wake-ups via ScheduleWakeup;
   there is no registered Stop hook that enforces it (see the loaded skill).
2. Load the skill `session-autonomous` and follow its rules strictly (budget
   caps, ntfy per task and question, ScheduleWakeup plus wake marker,
   compact-plus).
3. Read the approved GO order back verbatim before you start.
