---
name: disable
description: >
  Disable the credo items workflow for the current directory. Use when the user wants to stop
  credo's workflow here - for example "stop using credo here", "disable credo for this repo",
  "turn credo off here", "no credo in this directory", "credo hier aus", "credo hier
  deaktivieren", "credo hier abschalten" - or runs the /credo:disable command. It persists a
  per-directory declined decision (so the SessionStart onboarding ASK and the workflow text stay
  silent here across future sessions), records the current session as declined, clears its active
  session mode, and switches keep-alive autonomy off (same effect as switching to active/passive).
  Model presets and the shorthand legend stay on. Fully reversible via /credo:enable.
---

# Disable the credo workflow here

Switch the credo items workflow off for the directory the user is working in. This is a
per-directory opt-out. It makes the items workflow stop here (no onboarding ASK, no workflow
text) and winds down any active workflow state for the current session. It does NOT uninstall the
plugin and it is fully reversible.

Two things stay on here, because they are not part of the items workflow. They are the model presets (the
main-agent prompt and the per-spawn rule for `credo-preset.sh stage`) and the chat-shorthand
legend (`dd` / `vf` / `cf` / `???` / `cc-up` / `exclude`). Both are pure model-choice and
user-intent parsing, not workflow advertising. Someone who wants none of credo's features removes
the plugin instead; this skill does not do that.

## When to use

- The user runs `/credo:disable`.
- The user says, in any wording, that they want the credo workflow off for this directory / repo -
  for example "stop using credo here", "disable credo for this repo", "turn credo off here", "credo
  hier aus", "credo hier deaktivieren".

If the user clearly means globally uninstalling credo (not just this directory), do not use this
skill - explain that this only switches the items workflow off for the current directory (presets
and shorthands stay on) and that removing the plugin is a separate `claude plugin` action.

## What it does (run all three)

Run these steps, then confirm briefly. Each step is independent and failure-safe; if one prints
an error, report it plainly and continue with the other.

1. Remember this directory as declined (persistent, per-directory - keyed by the git top-level
   else the current working directory):

   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/credo-dir-decision.sh" set declined
   ```

   This is what makes the onboarding ASK and the items workflow text stay silent here in this and
   every future session, until it is re-enabled. It does not touch the model presets or the
   shorthand legend.

2. Clear the active session mode for THIS session and switch keep-alive autonomy off, in one
   step. `session-mode-set.sh clear` removes this session's mode file and runs the same keep-alive
   teardown that active/passive use for THIS session only (removes
   `credo/autonomy/<session_id>/active`, sets `credo/autonomy/<session_id>/paused`; other
   sessions are untouched):

   ```bash
   "${CLAUDE_PLUGIN_ROOT}/hooks/session-mode-set.sh" clear
   ```

   With no mode file and a declined directory, the session-mode inject line stays silent (no
   `[credo-mode]` and no `[credo]` bootstrap line).

3. Record the current session's credo decision as declined. Without this, a session that was
   already active (decision `accepted`) would get the workflow text again on resume and compact,
   because the hook counts an accepted session as active. The session id is resolved from
   `CLAUDE_CODE_SESSION_ID`, the same way step 2 resolves it:

   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/credo-decision-set.sh" declined
   ```

## Confirm

Confirm in one or two short sentences, for example:

> credo workflow disabled for this directory and this session - the onboarding question and the
> workflow text stay silent here, the active session mode is cleared, and keep-alive autonomy is
> off. Model presets and the shorthand legend keep working. Reversible any time with `/credo:enable` (or by setting a
> session mode with `/credo:session-active` or `/credo:session-passive`).

Do not do anything else - this skill only disables the items workflow for the directory and the
current session.
