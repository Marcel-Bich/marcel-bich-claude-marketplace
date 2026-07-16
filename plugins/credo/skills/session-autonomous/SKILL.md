---
name: session-autonomous
description: >
  The credo behavior for a session running in AUTONOMOUS mode - work approved GO items
  unattended while the user is away, best-effort self-scheduled keep-alive, budget caps always on. Load this when
  the session-mode inject line says "Load skill session-autonomous", right after the
  /credo:session-autonomous command, or whenever you are working autonomously and unattended.
  Shares the canonical common core defined in the credo session-active skill, then adds the
  autonomous-mode specifics: steward not initiator, ScheduleWakeup keep-alive, the
  deferred-question flow, end-of-run hibernate with veto, and per-task ntfy. This is the
  umbrella skill of the credo building blocks - it references them, never duplicates them.
  Only active while credo-autonomy-active is set. One mode is active at a time.
---

# session-autonomous - work approved GO items unattended

A credo session runs in exactly one mode - `active`, `passive`, or `autonomous` - set by
the `/credo:session-*` commands and surfaced on every prompt by the session-mode inject
line. This skill is the umbrella for **autonomous** mode: the user is away, you work
approved GO items on your own, keep the session alive, respect the budget caps, notify via
ntfy, and hibernate cleanly at the end. It is the dach / umbrella over the credo building
blocks - it wires them together and adds the unattended-run machinery, and it duplicates
none of their content.

Autonomous mode is only in force while the autonomy flag `credo-autonomy-active` is set -
which is what the `/credo:session-autonomous` command sets (and it lifts the
`credo-autonomy-paused` opt-out). If that flag is not set, do not run the keep-alive or
hibernate behavior below.

## Common core (shared - read the session-active skill)

Autonomous mode uses the same **canonical common core** as every credo session skill. It
is defined once in the credo `session-active` skill and applies here in full - read it
there. It covers: CLARIFY-FIRST and the go-gate; clarify via Ask (G1); bug report is not
an immediate fix (G2); read-back scaled to complexity (A4); the soft old-item reminder; no
silent rename / restructure plus consistency sweep (G6) and independent evaluation of
foreign handoffs (G7); the authority order (E5); the ntfy hybrid model (D); the git-push
policy (G5); the `safety` skill always; and the building blocks a session ties together.
The autonomous specifics below narrow or extend that core - they do not replace it.

Where the core points at a building block, that still holds here. In particular, ALL
budget cap / reset / 09:00-guard / task-sizing / weekly-99 / commit-identity rules live in
the credo `budget` skill; this skill references it and never restates a cap value.

## Autonomous-mode specifics (A3)

### Steward, not initiator

In autonomous mode you are a steward of already-approved work, not an initiator. Work ONLY
items in `1_todo/2_go` - approved, buildable GO items (credo `items` go-gate). Do NOT start
new features, invent scope, or make product decisions on the user's behalf. Anything not
already GO waits (or becomes a deferred question, below); it does not get built
autonomously.

### Budget caps are always on

Budget enforcement is unconditional in autonomous mode. Apply the credo `budget` skill in
full: the daily cap schedule, the critical 09:00 guard, the 5-hour guard (skill behavior,
check frequently including while subagents run, stop subagents with TaskStop before the
ceiling), the task-sizing recommendation, the absolute fail-safe caps, and the
commit-identity gate before every commit. Before starting an autonomous run, the main agent
first confirms with the user whether the default caps fit or need a temporary override, and
until when (per the budget skill). Never exceed a cap to finish "just one more thing".

### Keep-alive (best-effort, only while credo-autonomy-active is set)

Keep the session awake so an unattended run does not fall asleep while there is open work
and budget. Keep-alive is best-effort and instruction-driven: YOU schedule your own
wake-ups. There is no registered Stop hook that forces the turn to continue, so upholding
the discipline below is what actually keeps an unattended run alive.

- ScheduleWakeup is the PRIMARY self-wake mechanism. Its single delay is clamped to
  [60, 3600] seconds, so for a longer pause CHAIN several wake-ups rather than one long one.
- Record each planned wake with `credo-autonomy-wake-mark.sh` so your own tracking stays
  consistent. It is a plain helper script, not a registered hook, so it does not enforce
  anything by itself - it just keeps a record of the next wake.
- On each wake, re-check the flag. If autonomy has been turned off (the user returned, or
  the run ended), do not keep building - end quietly.
- Never end a turn without a scheduled wake-up while the flag is set and there is open work
  plus budget. This is the standing keep-alive duty; because nothing enforces it for you,
  you must uphold it yourself.

Wake-up offsets after a limit reset (default 5 minutes, fallback 1) come from the budget
skill's `wakeup.*` config - use them when you pause for a limit to reset.

### Per-task and per-question ntfy

Autonomous mode is where the common-core ntfy hybrid does the most work. Send an immediate
`high` ntfy for come-to-PC events (a deferred question, a blocker / showstopper, a budget
cap reached, run completion, the pre-hibernate veto) and BEFORE the blocking action.
Bundle progress (completed items, slices, milestones, findings) into one digest per
`ntfy.digest_interval_minutes`. If `personal.ntfy_topic` is empty, skip ntfy silently -
but then note that autonomy is running blind on notifications. Run completion is `high`.

### Deferred-question flow (core of autonomous mode)

When you hit a previously-unknown question that genuinely needs the user - one you cannot
self-resolve up to authority level 3 - do NOT stop the whole run and do NOT guess:

1. Send an immediate ntfy `high` stating the question clearly (come to the PC).
2. Schedule a wake-up for the deferred-question window - `windows.deferred_question_minutes`
   (default 5) - to check for an answer:

   ```
   "${CLAUDE_PLUGIN_ROOT}/scripts/credo-config.sh" get windows.deferred_question_minutes
   ```

3. If the answer arrives within the window: incorporate it and continue. Log it verbatim
   (credo `requirements-verbatim`).
4. If no answer arrives: adopt a documented default - record the decision and its rationale
   in the item / handoff so it is auditable - and continue fully autonomously. Do not block
   the run on an absent user.

This replaces blocking on the user with a bounded wait plus a safe, documented fallback. If
a subagent is the one that hit the question, use return-and-resume (credo `orchestration`):
the subagent returns `{status: needs_decision, question}`, the main agent obtains the answer
(user, verbatim log, or documented default) and passes it back via SendMessage so the
subagent continues with full context.

### Hibernate at the end (I9)

The global "never auto-hibernate" rule lives HERE now, scoped by mode:

- Non-autonomous modes (active, passive): NEVER auto-hibernate. Only hibernate on an
  explicit user request.
- Autonomous mode: hibernate when EITHER everything is done, OR a showstopper occurs, OR
  the weekly axis reaches 99 percent (that weekly trigger is set by the credo `budget`
  skill; this skill owns the hibernate action).

Hibernate procedure (with protection against a spurious or double hibernate):

1. Send an ntfy `high` announcing the pending hibernate and open a veto window -
   `windows.veto_minutes` (default 20):

   ```
   "${CLAUDE_PLUGIN_ROOT}/scripts/credo-config.sh" get windows.veto_minutes
   ```

2. During the veto window, watch for the user coming back. If the user responds or
   otherwise signals presence, CANCEL the hibernate - do not sleep the machine out from
   under an active user.
3. Double-hibernate protection: record a timestamp / flag when a hibernate is initiated and
   check it (plus whether the user is back) before issuing another, so a repeated trigger
   cannot fire hibernate twice.
4. Before hibernating, make sure work is secured (git-push policy and, where relevant, the
   credo `compact-plus` securing) so nothing is lost across the sleep.

Never hibernate on your own initiative outside these autonomous triggers.

### Authority order when the user is away

The common-core authority order (E5) applies, with the away-user branch active: self-
resolve up to level 3 (the verbatim log and committed docs); if that is not enough, either
raise a deferred question (above) when it truly needs the user, or fall back to a
documented default (levels 4-5) and continue. Do not silently invent a requirement.

### Git-push: atomic per slice

Per the common-core git-push policy, in autonomous mode commit ATOMICALLY per slice and
push per the granted authorization, so each unit of work is secured as it completes. The
commit-identity gate (credo `budget` skill) must pass before every commit. If commit or
push is forbidden by permissions, that is a SHOWSTOPPER for autonomous work - the work
cannot be secured - so warn via ntfy and stop; do not keep building unsecured work.

### Read-back for an overnight run

Per the common-core read-back (A4), a large / overnight autonomous run reads back not just
the current budgets and the planned rest state but also the next day's budgets before it
starts, so the whole unattended run stays inside the intended envelope.

### Marker plus compact-plus

Secure progress across context compaction via the credo `compact-plus` skill, driven by the
limit plugin's session-context threshold signal (config `compact.thresholds`). Do not
self-trigger compact-plus proactively - only on the injected ACTION line or a manual
invocation. Pair the keep-alive wake marker with this securing so a long unattended run
neither falls asleep nor loses approved work.
