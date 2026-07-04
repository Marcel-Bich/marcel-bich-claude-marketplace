---
name: orchestration
description: Delegate work to subagents safely and efficiently - decide how many subagents to run, keep parallel tracks on disjoint files, monitor them without flooding your context, inherit security to every subagent, and use return-and-resume so a subagent can ask a question and continue with full context. Use whenever you are about to spawn one or more subagents, run work in parallel, or coordinate delegated tasks. Applies to any agent that delegates, including subagents that spawn their own helpers.
---

# orchestration

How to delegate work to subagents so results come back correct, parallel work does not
collide, and the delegating agent's context stays lean. This is the reusable
delegation core; the session skills reference it instead of restating it.

## When this fires

- You are about to spawn a subagent for any non-trivial task.
- You have two or more independent tasks that could run in parallel.
- You are coordinating or monitoring already-running subagents.
- A subagent returns needing a decision, and you must route the answer back.

## Delegation-first

Prefer delegating substantive work to a subagent over doing it inline in the main
context. The main agent orchestrates: it splits work, dispatches, integrates results,
and commits. Reserve the main context for coordination and user interaction, not for
large reads or long builds that a subagent can carry.

## How many subagents (situational, no colony rule)

- The delegating agent decides the count based on the actual work. There is NO fixed
  colony pattern and no rule to always fan out wide. Large colonies are expensive; use
  them only ad hoc when a specific task genuinely benefits.
- For code tracks that touch the repository, keep it to roughly two tracks running at a
  time. More than that raises collision and integration cost faster than it buys speed.
- Read-only exploration can fan out more freely than code-editing tracks, since it does
  not write files.

## Parallel safety

- Disjoint files: parallel tracks must edit non-overlapping file sets. Assign each
  track its own files up front. If two tracks would touch the same file, they are not
  independent - sequence them instead.
- Sequential commit: the MAIN agent commits, one track's result at a time. Subagents do
  not commit in parallel. This keeps history clean and avoids two agents racing on the
  index or on a shared file.
- If a clean disjoint split is not possible, run the tracks sequentially rather than
  forcing false parallelism.

## Monitoring without context flooding

- Launch background subagents non-blocking (`block=false`) so the main agent stays
  responsive and does not stall waiting.
- Do NOT pull a subagent's whole transcript into the main context. Consume only the
  subagent's final result (its returned message), plus short status checks. Pulling
  full transcripts is what floods and rots the main context.
- Check status periodically rather than streaming everything continuously.

## Security inheritance (every subagent, always)

Subagents inherit the same hard security rules as the main agent, with no exceptions:
- Install nothing (no pip / npm / apt / system / global installs) without explicit
  prior approval.
- Read no secrets: no credential files, tokens, key material, or shell history.
- The same filesystem-protection and deletion rules apply. A subagent may not do what
  the main agent may not do.

State these constraints in the task you hand each subagent so they hold even if the
subagent does not otherwise load them.

## Model policy (no downgrade, no model-choice logic)

Subagents always run at a model at least as capable as the main agent's model - never
downgrade a subagent to a weaker model. There is no model-selection logic to reason
about: best quality everywhere. Do not spend effort choosing models.

## return-and-resume (subagent asks, then continues)

Proven pattern for a subagent that hits a question it cannot answer:

1. The subagent returns `{status: needs_decision, question: <the question>}` instead of
   guessing or finishing with a wrong assumption.
2. The main agent obtains the answer (from the user, from the verbatim requirements
   log, or from a documented default when the user is away).
3. The main agent passes the answer back to the SAME subagent via SendMessage to its
   agentId.
4. The subagent resumes with its FULL prior context intact - no throwaway, no rebuild.

Use this instead of killing and re-spawning a subagent when a mid-task decision is
needed. It preserves the subagent's accumulated context and avoids redoing work.

## Config

Any environment-specific values relevant to delegated work live in the credo config
cascade (`builtin template < ~/.claude/credo/config < .credo/config`, read via
`scripts/credo-config.sh`), not in this skill.

## Boundaries

- Self-contained: no dependency on non-credo skills. Referenced by name from the credo
  session skills.
- This skill governs how to delegate. What a subagent should verify, audit, or log is
  covered by the respective credo building-block skills (for example `verify`, `audit`,
  `requirements-verbatim`).
