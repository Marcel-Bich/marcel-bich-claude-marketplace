---
name: session-autonomous
description: >
  The credo behavior for a session running in AUTONOMOUS mode - work approved GO items
  unattended while the user is away, hook-enforced self-scheduled keep-alive, budget caps always on.
  Load this the MOMENT the user hands off full-autonomy, unattended, or AFK work - EVEN BEFORE the
  mode is set - so this skill can bootstrap autonomous mode itself. Trigger on a semantic
  full-autonomy / AFK-handoff grant (match the intent, not a rigid phrase list); the skill itself
  then only ENTERS autonomous mode on an unambiguous, explicit grant and confirms first when unsure.
  Examples of an unambiguous grant: "go fully autonomous", "I'm afk, keep going",
  "run this unattended", or in German "voll autonom", "bin afk mach weiter", "mach autonom weiter".
  A vague or casual "keep going / carry on" is NOT such a grant. Also load it when the session-mode
  inject line says "Load skill session-autonomous", right after the /credo:session-autonomous
  command, or whenever you are working autonomously and unattended.
  Shares the canonical common core defined in the credo session-active skill, then adds the
  autonomous-mode specifics: steward not initiator, ScheduleWakeup keep-alive, the
  deferred-question flow, end-of-run hibernate with veto, and per-task ntfy. This is the
  umbrella skill of the credo building blocks - it references them, never duplicates them.
  The keep-alive and hibernate RULES apply only while credo-autonomy-active is set, but the skill
  should still LOAD on the grant intent so it can enter the mode. One mode is active at a time.
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

## Bootstrap - enter the mode only on an unambiguous grant

This skill may LOAD on a full-autonomy / AFK-handoff intent, but entering autonomous mode
requires an unambiguous, explicit user grant. If this skill loaded because the user just handed
off full-autonomy / unattended / AFK work and the mode is NOT yet set (no `credo-autonomy-active`
flag), FIRST enter autonomous mode by running `/credo:session-autonomous`. That command runs
`session-mode-set.sh autonomous`, sets the flag, and activates the rules below - which resolves the
chicken-and-egg problem of needing the mode set before this skill's keep-alive can apply. Then
follow the rules below. If the mode is already autonomous, skip this and continue.

Do NOT enter autonomous mode on a vague or casual signal (for example a bare "keep going",
"carry on", "work on this"); only on an unambiguous full-autonomy / AFK grant such as
"run this unattended", "go fully autonomous", or a clear AFK handoff. If unsure whether the user
really wants unattended autonomy, stay in normal (non-autonomous) collaboration and confirm with
the user first rather than setting the flag. A user who never asks for autonomy is never put into
autonomous mode.

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

### Never build a skill autonomously (hard guarantee)

The credo `skill-capture` skill is mode-gated, and autonomous mode takes its strictest
branch: autonomous mode NEVER builds a skill from a recurring workflow, no matter how often
the pattern recurs. Building a skill needs an explicit user GO, which an autonomous run does
not have; a build-on-detection rule would be a showstopper. When you notice the same
multi-step workflow recur (about three times), append ONE candidate note to
`.credo/skill-candidates.md` and continue the actual work - do not stop, do not ask, do not
create the skill. A later presence-mode session picks the candidate up. This is consistent
with steward-not-initiator: noticing a pattern is fine, acting on it into new tooling is not.

### Budget caps are always on

Guardrail-availability gate (autonomy never runs without budgets/limits). At autonomous-mode
entry, and before any autonomous start, check budget-data availability via the read-only
`"${CLAUDE_PLUGIN_ROOT}/scripts/credo-budget-read.sh"`:

- Exit 0 (fresh data): percentage caps are measurable and MANDATORY - proceed as today.
- Exit 3 or 4 (no cache / stale cache): percentage caps CANNOT be enforced (credo `budget`
  skill, B8 - the fail-safe caps are percentages too, so they are equally unenforceable).
  Do NOT run blind and do NOT silently ignore budgets. Use AskUserQuestion with three
  options:
  a. Install the `limit` plugin for real budget safety, then re-check availability.
  b. Run with a wall-clock timebox (max X hours / until a clock time) - the only guardrail
     enforceable without the cache. Record the deadline and self-enforce it: end the run via
     `credo-autonomy-off.sh` when the clock reaches it.
  c. Proceed without budget guardrails - an explicit, user-accepted risk.

This gate is what makes "autonomy never runs without budgets/limits" true. Send the
come-to-PC ntfy before the AskUserQuestion (per the ntfy hybrid).

Budget enforcement is unconditional in autonomous mode. Apply the credo `budget` skill in
full: the daily cap schedule, the critical 09:00 guard, the 5-hour guard (skill behavior,
check frequently including while subagents run, stop subagents with TaskStop before the
ceiling), the task-sizing recommendation, the absolute fail-safe caps, and the
commit-identity gate before every commit. Before starting an autonomous run, the main agent
first confirms with the user whether the default caps fit or need a temporary override, and
until when (per the budget skill). Never exceed a cap to finish "just one more thing".

### Keep-alive (hook-enforced, only while credo-autonomy-active is set)

Keep the session awake so an unattended run does not fall asleep while there is open work
and budget. This discipline is now hook-enforced. A registered `Stop` hook
(`credo-autonomy-keepalive.sh`, wired in `hooks/hooks.json`) fires when you try to end the
turn: if autonomy is active and no self-wake is marked, it blocks the stop and instructs you
to call ScheduleWakeup now (and mark it). Paired with the registered `UserPromptSubmit` hook
(`credo-autonomy-clear.sh`), any real user message turns autonomy off. The enforcement is a
nudge, not a guarantee of infinite wakefulness: the hook forces the block plus instruction,
but actually staying awake still relies on you then calling ScheduleWakeup. It is loop-safe -
the hook forces AT MOST ONE continuation per stop attempt (via the `stop_hook_active` guard)
and lets the stop through once a future wake is marked, so it can NOT spin forever. Outside
autonomous mode (no flag set) the hook is completely inert - a plain no-op stop.

- ScheduleWakeup is the PRIMARY self-wake mechanism. Its single delay is clamped to
  [60, 3600] seconds, so for a longer pause CHAIN several wake-ups rather than one long one.
- Record each planned wake with `credo-autonomy-wake-mark.sh` (same delaySeconds as the
  ScheduleWakeup call). This is what the Stop hook checks to let the turn stop, so marking the
  wake is what satisfies the enforcement.
- On each wake, re-check the flag. If autonomy has been turned off (the user returned, or
  the run ended), do not keep building - end quietly.
- Never end a turn without a scheduled wake-up while the flag is set and there is open work
  plus budget. The Stop hook enforces this nudge, but uphold the duty yourself rather than
  relying on the block.
- When the run is truly finished, on a showstopper, or at the weekly hard limit, end the mode
  deliberately with `credo-autonomy-off.sh` - it clears the flag and sets the paused opt-out
  so the Stop hook stays inert and you may stop.

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

### Power down the machine at the end (I9)

The machine power-down can be EITHER suspend (standby / suspend-to-RAM) OR hibernate
(suspend-to-disk), per `sleep.mode`; refer to it generically as "power down / sleep the
machine". The global "never auto power-down" rule lives HERE now, scoped by mode:

- Non-autonomous modes (active, passive): NEVER auto power-down. Only sleep the machine on an
  explicit user request.
- Autonomous mode: the end-of-run triggers are EITHER everything is done, OR a showstopper
  occurs, OR the weekly axis hits its power-down trigger. On the weekly axis the reset is NOT
  a default showstopper: first PREFER the credo `budget` skill's weekly pause-and-resume
  (when the reset is near - same local calendar day - and weekly is at or above
  `switch_percent`, pause via chained ScheduleWakeup across the reset and resume with a fresh
  weekly budget). Only the weekly last-resort net (99 percent) or a pause path that does not
  apply (the reset is on a different calendar day) reaches an end-of-run trigger on the
  weekly axis. The weekly triggers are set by the credo `budget` skill; this skill owns what
  happens on a trigger - and whether that powers down the machine is gated below.

Power-down is OFF by default - it must be opted into (server-safe). Whether an end-of-run
trigger sleeps the machine is gated on `sleep.enabled`:

```
"${CLAUDE_PLUGIN_ROOT}/scripts/credo-config.sh" get sleep.enabled
"${CLAUDE_PLUGIN_ROOT}/scripts/credo-config.sh" get sleep.command
```

- `sleep.enabled` false (the DEFAULT): NEVER power down the machine. This is what keeps a
  SERVER running autonomous work from being powered down unexpectedly. On every end-of-run
  trigger (all done / showstopper / weekly cap reached) do NOT sleep - instead end the
  autonomous run CLEANLY via `credo-autonomy-off.sh` and send a `high` ntfy stating why (run
  complete, showstopper, or weekly cap reached). The machine stays on.
- `sleep.enabled` true (opt-in, personal machine only): run the power-down procedure below
  (veto window, double-fire protection, secure-work-first, then run the EXACT command from
  `sleep.command`) on those same end-of-run triggers.
- MISCONFIG guard: if `sleep.enabled` is true but `sleep.command` is EMPTY, that is a
  misconfiguration. Do NOT guess or hardcode a command. End the run cleanly via
  `credo-autonomy-off.sh` and send a `high` ntfy warning that sleep is enabled but no command
  is configured (re-run `/credo:setup`). Never sleep the machine on a guessed command.

Default OFF means autonomous work never powers down the machine unless the user opted in at
setup (`/credo:setup`). The weekly pause-and-resume path (budget skill) is unaffected either
way - it never powers down anyway; this gate governs only the last-resort 99 net and the
end-of-run / showstopper power-down.

Power-down procedure (only when `sleep.enabled` is true AND `sleep.command` is non-empty;
with protection against a spurious or double power-down):

1. Send an ntfy `high` announcing the pending power-down and open a veto window -
   `windows.veto_minutes` (default 20):

   ```
   "${CLAUDE_PLUGIN_ROOT}/scripts/credo-config.sh" get windows.veto_minutes
   ```

2. During the veto window, watch for the user coming back. If the user responds or
   otherwise signals presence, CANCEL the power-down - do not sleep the machine out from
   under an active user.
3. Double-fire protection: record a timestamp / flag when a power-down is initiated and
   check it (plus whether the user is back) before issuing another, so a repeated trigger
   cannot fire the power-down twice.
4. Before powering down, make sure work is secured (git-push policy and, where relevant, the
   credo `compact-plus` securing) so nothing is lost across the sleep.
5. Run the EXACT command from `sleep.command` (read via the config above) to power down. Do
   NOT hardcode or guess the command - it is platform- and mode-specific and set at setup.

Never power down the machine on your own initiative outside these autonomous triggers.

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
