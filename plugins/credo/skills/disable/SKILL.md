---
name: disable
description: >
  Disable credo for the current directory. Use when the user wants to stop credo here - for
  example "stop using credo here", "disable credo for this repo", "turn credo off here", "no
  credo in this directory", "credo hier aus", "credo hier deaktivieren", "credo hier abschalten"
  - or runs the /credo:disable command. It persists a per-directory declined decision (so the
  SessionStart onboarding ASK and the [credo] prompt line stay silent here across future
  sessions), clears the active session mode for the current session, and switches keep-alive
  autonomy off (same effect as switching to active/passive). Fully reversible via /credo:enable.
---

# Disable credo here

Switch credo off for the directory the user is working in. This is a per-directory opt-out: it
makes credo stop advertising itself here (no onboarding ASK, no `[credo]` prompt line) and winds
down any active credo state for the current session. It does NOT uninstall the plugin and it is
fully reversible.

## When to use

- The user runs `/credo:disable`.
- The user says, in any wording, that they want credo off for this directory / repo - for
  example "stop using credo here", "disable credo for this repo", "turn credo off here", "credo
  hier aus", "credo hier deaktivieren".

If the user clearly means globally uninstalling credo (not just this directory), do not use this
skill - explain that this only silences credo for the current directory and that removing the
plugin is a separate `claude plugin` action.

## What it does (run both)

Run these steps, then confirm briefly. Each step is independent and failure-safe; if one prints
an error, report it plainly and continue with the other.

1. Remember this directory as declined (persistent, per-directory - keyed by the git top-level
   else the current working directory):

   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/credo-dir-decision.sh" set declined
   ```

   This is what makes the onboarding ASK and the `[credo]` prompt line stay silent here in this
   and every future session, until it is re-enabled.

2. Clear the active session mode for THIS session and switch keep-alive autonomy off, in one
   step. `session-mode-set.sh clear` removes this session's mode file and runs the same keep-alive
   teardown that active/passive use (clears `credo-autonomy-active`, sets the
   `credo-autonomy-paused` opt-out):

   ```bash
   "${CLAUDE_PLUGIN_ROOT}/hooks/session-mode-set.sh" clear
   ```

   With no mode file and a declined directory, the session-mode inject line stays silent (no
   `[credo-mode]` and no `[credo]` bootstrap line).

## Confirm

Confirm in one or two short sentences, for example:

> credo disabled for this directory - the onboarding question and the `[credo]` line stay silent
> here, the active session mode is cleared, and keep-alive autonomy is off. Reversible any time
> with `/credo:enable` (or by setting a session mode with `/credo:session-active` or
> `/credo:session-passive`).

Do not do anything else - this skill only disables credo for the directory.
