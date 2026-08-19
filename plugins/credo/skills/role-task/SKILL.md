---
name: role-task
description: >
  Assign this session the credo task/build role - the default owner of implementing GO items
  (items in 2_go/), INCLUDING commits and push where dogma permissions allow. Use ONLY when the
  user actually assigns this role to you, for example "you are (now) the task/build agent", "you
  build the GO items", "build the GO items", "take over building / implementing", "act as the
  build agent", "switch into the task/build role", "du bist (jetzt) der task/build agent", "du
  baust die GO-items", "übernimm das Bauen / Implementieren", "wechsel in die task/build rolle"
  - or when the /credo:role-task command is run. Do NOT use for general talk ABOUT roles,
  explanations, or questions like "what does the task agent do". It writes a persistent,
  compact-safe per-session marker (re-injected every turn) so the role survives compaction.
---

# Session Role: task / build

Set this session's credo ROLE to **task / build**. This is a guiding default owner of
implementing GO items (items in `2_go/`), INCLUDING commits and push where dogma permissions
allow. Only the task/build role commits and pushes, so a single index owner avoids a race on
`.git/index.lock`.

A role is orthogonal to the session mode (active | passive | autonomous): it can coexist with
any mode. It is a guiding default, NOT a fixed constraint - on the user's wish you may still do
mixed work, and an explicit user instruction always overrides the role.

## When to use

- The user runs `/credo:role-task` (the explicit, deterministic, guaranteed path).
- The user assigns you this role in passing (best-effort, casual path) - for example "you are
  now the task/build agent", "you build the GO items", "take over the implementing", "act as the
  build agent", "du baust die GO-items", "uebernimm das Bauen".

Do NOT trigger on general discussion about roles, on explanations, or on questions such as
"what does the task agent do" - those are not an assignment.

## What it does

Write the persistent, per-session role marker. It is keyed by session_id under the
session-roles dir and re-injected on every prompt by `role-inject.sh`, so it survives context
compaction, new sessions and subagents (stored on disk, not in context):

```bash
"${CLAUDE_PLUGIN_ROOT}/hooks/role-set.sh" task
```

## Confirm

Confirm in one short sentence, for example:

> Role set to task/build - I am the default owner of building GO items (items in `2_go/`),
> including commits and push where dogma permits. This is persistent and compact-safe (re-injected
> each turn); it is a guiding default you can override, and `/credo:role-clear` removes it.

Do not do anything else - this skill only sets the role.
