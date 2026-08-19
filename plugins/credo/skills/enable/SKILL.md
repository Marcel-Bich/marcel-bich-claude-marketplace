---
name: enable
description: >
  Enable credo for the current directory. Use when the user wants credo active here - for
  example "enable credo here", "use credo here", "turn credo on here", "credo hier an", "credo
  hier aktivieren", "credo hier einschalten" - or runs the /credo:enable command. It persists a
  per-directory accepted decision (keyed by the git top-level else the working directory), which
  overrides any earlier declined: credo becomes active for this directory again, so its knowledge
  is re-fed at the next SessionStart and the onboarding ASK no longer fires here.
---

# Enable credo here

Opt the current directory back in to credo. This flips the persistent per-directory decision to
accepted, overriding any earlier `/credo:disable` (declined). From here on credo treats this
directory as opted-in: the SessionStart hook re-feeds credo's command and skill knowledge, and
the one-time onboarding ASK no longer fires here.

## When to use

- The user runs `/credo:enable`.
- The user says, in any wording, that they want credo on for this directory / repo - for example
  "enable credo here", "use credo here", "turn credo on here", "credo hier an", "credo hier
  aktivieren".

## What it does

Record this directory as opted-in (persistent, per-directory - keyed by the git top-level else
the current working directory; overrides an earlier declined):

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/credo-dir-decision.sh" set accepted
```

## Confirm

Confirm in one or two short sentences, and point out the session-mode option, for example:

> credo enabled for this directory - its knowledge is re-fed at the next SessionStart and the
> onboarding question no longer fires here. For a specific working style you can additionally set
> a session mode now: `/credo:session-active` (intensive live collaboration) or
> `/credo:session-passive` (the agent carries most of the work, you answer clarifications).

Do not do anything else - this skill only enables credo for the directory. Setting a session
mode is the user's call via the commands above.
