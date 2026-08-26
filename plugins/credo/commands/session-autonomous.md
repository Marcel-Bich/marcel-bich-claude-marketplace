---
description: credo - Set the session mode to autonomous (work approved GO items unattended, hook-enforced keep-alive ON)
argument-hint: "[optional: a suspend-on-idle order like 'suspend when done', or its revocation 'no suspend']"
allowed-tools:
  - Bash(${CLAUDE_PLUGIN_ROOT}/hooks/session-mode-set.sh:*)
  - Bash(${CLAUDE_PLUGIN_ROOT}/scripts/credo-dir-decision.sh:*)
  - Bash(${CLAUDE_PLUGIN_ROOT}/scripts/credo-suspend-directive.sh:*)
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
3. **Suspend-on-idle directive (durable, per session).** If this invocation's argument (or a
   natural-language user statement) contains an explicit suspend-on-idle order - "suspend when
   done", "power down at the end", "hibernate afterwards", German "am Ende suspend", "danach
   runterfahren" - record it durably:
   `${CLAUDE_PLUGIN_ROOT}/scripts/credo-suspend-directive.sh set`
   If it instead REVOKES a standing order - "no suspend", "leave it on", German "kein suspend",
   "lass an" - clear it:
   `${CLAUDE_PLUGIN_ROOT}/scripts/credo-suspend-directive.sh clear`
   If there is NO argument and no such statement, do NOT touch an existing directive - it
   persists across re-invokes and compaction (that persistence is the point). The directive is
   only meaningful in autonomous mode; it gates the end-of-run power-down together with the
   sleep config and OVERRIDES `sleep.enabled: false` when set (see the `session-autonomous`
   skill). Do NOT set it from mere user presence or a casual remark - only an explicit order.
4. Load the skill `session-autonomous` and follow its rules strictly (budget
   caps, ntfy per task and question, ScheduleWakeup plus wake marker,
   compact-plus).
5. Load the `items` skill now (the credo work-item model and done-gate), UNLESS it is
   already active in your current context - do not reload it if you already have it. This
   puts the item model and go-gate in context before you act on approved GO items.
6. Give the autonomous-start read-back per the `session-autonomous` skill ("Budget-start
   read-back"). Full four-part read-back on the FIRST start; on every invocation - including
   this one - emit AT LEAST the three-axis short form and NEVER start without it:
   - **Budget:** the binding axis + both live figures (5h% and weekly%).
   - **Suspend/hibernate:** the end-of-run posture (one line), DERIVED FROM the persisted
     suspend directive plus the sleep config - a set directive means you WILL power down at
     end-of-run provided `sleep.command` exists (overriding `sleep.enabled: false`); announced
     = committed.
   - **ntfy:** whether it is active and what will be reported (normally every go -> done item
     completion, plus come-to-PC pushes) - or that it runs silent if unconfigured.
7. Read the approved GO order back verbatim before you start.
