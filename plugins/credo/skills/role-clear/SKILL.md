---
name: role-clear
description: >
  Clear this session's credo role, returning to the default of NO role (the agent does
  everything). Use ONLY when the user actually drops the role, for example "clear the role", "no
  role", "forget the role", "you are no longer the plan/task agent", "back to doing everything",
  "rolle weg", "keine rolle mehr", "vergiss die rolle" - or when the /credo:role-clear command is
  run. Do NOT use for general talk ABOUT roles or explanations. It removes the persistent
  per-session role marker so no role line is injected any more.
---

# Session Role: clear

Clear this session's credo ROLE, returning to the default of NO role: the agent does
everything, as it does when no role is set. This is safe to run even if no role is set.

## When to use

- The user runs `/credo:role-clear` (the explicit, deterministic, guaranteed path).
- The user drops the role in passing (best-effort, casual path) - for example "clear the role",
  "no role", "forget the role", "you are no longer the plan/task agent", "back to doing
  everything", "rolle weg", "keine rolle mehr".

Do NOT trigger on general discussion about roles or on explanations - those are not a request to
clear.

## What it does

Remove the persistent, per-session role marker. With no marker, `role-inject.sh` injects no
role line (silent):

```bash
"${CLAUDE_PLUGIN_ROOT}/hooks/role-set.sh" clear
```

## Confirm

Confirm in one short sentence, for example:

> Role cleared - back to no role, I handle everything as usual.

Do not do anything else - this skill only clears the role.
