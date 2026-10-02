---
name: role-plan
description: >
  Assign this session the credo plan/clarify role - the default owner of clarifying items in
  1_clarify/, WITHOUT commits or push (the task/build role owns commits and push). Use ONLY when
  the user actually assigns this role to you, in any language, for example "you are (now) the
  plan/clarify agent", "you clarify the items", "take over the clarifying / the clarify items",
  "act as the plan agent", "switch into the plan/clarify role", or German "du bist (jetzt) der
  plan/clarify agent", "übernimm das Klären / die clarify-items", "wechsel in die plan/clarify
  rolle" - or when the
  /credo:role-plan command is run. Do NOT use for general talk ABOUT roles, explanations, or
  questions like "what does the plan agent do". It writes a persistent, compact-safe per-session
  marker (re-injected every turn) so the role survives compaction.
---

# Session Role: plan / clarify

Set this session's credo ROLE to **plan / clarify**. This is a guiding default owner of
clarifying items in `1_clarify/`, WITHOUT commits or push. Committing and pushing are the
task/build role's job, so a single index owner avoids a race on `.git/index.lock`.

A role is orthogonal to the session mode (active | passive | autonomous): it can coexist with
any mode. It is a guiding default, NOT a fixed constraint - on the user's wish you may still do
mixed work, and an explicit user instruction always overrides the role.

## When to use

- The user runs `/credo:role-plan` (the explicit, deterministic, guaranteed path).
- The user assigns you this role in passing (best-effort, casual path), in any language - for
  example "you are now the plan/clarify agent", "you clarify the items", "take over the
  clarifying", "act as the plan agent", or the same in another language such as German "übernimm das Klären", "du bist
  der plan/clarify agent".

Do NOT trigger on general discussion about roles, on explanations, or on questions such as
"what does the plan agent do" - those are not an assignment.

## What it does

Write the persistent, per-session role marker. It is keyed by session_id under the
session-roles dir and re-injected on every prompt by `role-inject.sh`, so it survives context
compaction, new sessions and subagents (stored on disk, not in context):

```bash
"${CLAUDE_PLUGIN_ROOT}/hooks/role-set.sh" plan
```

## Agent-owned clarify items

The plan role owns deciding agent-owned clarify items (`clarify_owner: agent`) per the agent
decision rule in the `items` skill ("Clarify owner and the agent decision rule"): uncritical
questions are decided SOTA, else best effort, else noted for the user; a feasible item moves to
`2_go` with `(GO: agent per SOTA rule, <reason>)` in its History. Human-owned items still need
the user's GO, and the escalation list there (infeasible, taste, deleting user data, installs,
money, safety, anything changing the verbatim requirement) always goes to the user.

## Sandbox pre-work

For WRITING clarify pre-work that needs no product decision but evidence - a measurement, a
mockup, a feasibility proof - use the `sandbox` skill. It builds under `.credo/sandbox-tmp/`
(no production code, no commit); an accepted artifact is promoted via `/credo:sandbox-promote`,
which the task / build role commits.

## Confirm

Confirm in one short sentence, for example:

> Role set to plan/clarify - I am the default owner of clarifying items in `1_clarify/`, without
> commits or push (the task/build role owns those). This is persistent and compact-safe (re-injected
> each turn); it is a guiding default you can override, and `/credo:role-clear` removes it.

Do not do anything else - this skill only sets the role.
