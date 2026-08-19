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

## Output convention - item references in inline code

Item references are always written in inline-code style: `#37`, `#90`, `#91` (backticks) -
never bold or plain. This improves scannability of item numbers.

## Autonomous-mode specifics (A3)

### Steward, not initiator

In autonomous mode you are a steward of already-approved work, not an initiator. Work ONLY
items in `1_todo/2_go` - approved, buildable GO items (credo `items` go-gate). Do NOT start
new features, invent scope, or make product decisions on the user's behalf. Anything not
already GO waits (or becomes a deferred question, below); it does not get built
autonomously.

go=go: a `2_go` item IS buildable by the folder - build it (best effort), never self-skip or
self-demote it for size, UI, or "not sure it is verifiable". See the go=go build-side anchor
in the credo `items` skill for the full rule and the hypothesis-vs-open-decision line.

Work the WHOLE queue, not just one thread. After you finish an item, immediately pick the next
buildable `2_go` item and continue - keep going until the buildable queue is empty (confirmed by
the fresh listing in "Empty buildable queue = end-of-run" below). Building every buildable GO
item IS the mandate of autonomous mode, not over-reach. "I built the thread I started with" is
NOT a reason to stop while other buildable items remain.

### A non-buildable item in 2_go

An item is normally clarified when it is in `2_go` (GO=GO). If you nonetheless meet one that
is genuinely non-buildable, act by the reason:

- **Genuine user-only decision** (the Named-Decision-Test in the credo `items` skill passes -
  typically surfacing mid-build): do NOT guess and do NOT build on an invented decision.
  Raise a deferred question (below) AND move the item `2_go -> 1_clarify` marked URGENT - the
  sanctioned carve-out (credo `items`). It probably leaves something broken, so it is top of
  the clarify queue for when the user returns.
- **Hard block on another unbuilt item**: this is the `3_blocked` path (credo `items`), not a
  self-demote.
- **Anything else** (placement / hygiene, "too big / too hard"): do NOT self-demote -
  placement is a move-side axis owned by the entry gate (credo `migrate`). FLAG it (in the
  digest and the handoff) rather than silently skipping it.

Auto-unblock (credo `items`) still applies during the run: when an item reaches `2_done`,
check its `blocks` and return any now-unblocked `3_blocked` item to `2_go`.

### Bringing up a local surface to verify (autonomous)

A `ui: true` item is not verify-dead in autonomous mode. If its runtime surface is down, and
you can POSITIVELY verify the target is local (a process on THIS machine, bound to localhost -
not a deployed, remote, or shared environment), bring it up or restart it per the
project-declared procedure and then run the credo `verify` skill. Locality is judged by where
the process runs, NOT by the git branch: a checkout named `main` / `develop` / `prod` does not
make it remote. If locality cannot be positively established, do NOT restart - defer the
visual verify as human-only. See the credo `verify` skill for the full rule and the config key.

### Never interrupt an autonomous run for a mode change (hard rule)

In autonomous mode the agent NEVER asks via the Ask tool about switching mode - not even
if the user keeps prompting during the autonomous run. An autonomous run must not be
interrupted for a mode-awareness question. At most, the agent may mention in normal output
that a mode change has to be made manually (via a `/credo:session-*` command) or on an
explicit user request; it never raises an Ask round to propose one. A mode switch happens
only on an explicit user instruction. This is the exception to the common core's
"Suggest a session mode when none is set" rule: that Ask-based suggestion logic applies
only in presence or no-mode sessions, never in autonomous.

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
until when (per the budget skill), and performs the mandatory budget-start read-back (see
"Budget-start read-back" below) - show the schedule row in force and reflect the
understanding back ONCE before starting. Never exceed a cap to finish "just one more thing".

### Keep-alive (hook-enforced, only while credo-autonomy-active is set)

Keep the session awake so an unattended run does not fall asleep while there is open work
and budget. "Open work" means BUILDABLE work - at least one buildable item remaining - NOT
"any file physically in `2_go`" (see "Empty buildable queue = end-of-run" below). When no
buildable item is left, that is an end-of-run condition, not a reason to keep the keep-alive
spinning. This discipline is now hook-enforced. A registered `Stop` hook
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

### 5h-budget-guard (autonomous only, hook-enforced)

Autonomous runs pace the 5h axis on a staggered ladder that the `credo-5h-budget-guard.sh`
PreToolUse hook enforces (it fires in the main agent AND inside subagents). This applies
ONLY in autonomous mode; active and passive are unchanged. The ladder OVERRIDES the budget
skill's soft/hard band on the 5h axis (no double-firing); everything else in the budget
skill still holds. Full rationale: `docs/TODO-credo-5h-budget-guard-concept.md`.

Two tracks (the main agent orchestrates - spawns, commits, schedules; a subagent runs ONE
task and reports back):

- **Main track:** 83 soft, 87 soft, 90 soft-strong, 92 HARD, 97 Lockdown.
- **Subagent track:** 83 soft, 90 HARD, 92 HARD.

Zones:

- **Soft zone** = recommendation only. The hook injects a throttled, concrete instruction
  (wind down, no big new fan-outs, wrap up running subagents, secure results); the agent
  stays at the wheel and judges. It does NOT block. Do not capitulate early - the hard zone
  is the safety net, so exploit the budget deliberately up to it.
- **Hard zone** = the hook BLOCKS disallowed tool-calls. Still allowed in the hard zone:
  `git` commit / push, writing under `.credo/`, `TaskStop`, `ScheduleWakeup`, and
  `credo-autonomy-wake-mark.sh`. New agent spawns and builds are blocked. At 92 the main
  agent hard-kills running subagents via `TaskStop`, then does only organisational work
  (commit / push, write the resume block, task status). At 97 (Lockdown) everything is
  dropped - even an open commit / push - and only the resume wake-up is set.

### resume-after-reset.md protocol

Location `.credo/process/resume-after-reset.md` (durable, git-excluded like the other
`.credo` process files). It is a ROLLING log of at most TWO blocks: the newest block always
on top, the previous one below it, and the oldest drops out entirely when a new one is
added. Each block records:

- the write timestamp (date + time + TZ),
- the exact 5h-reset time this block is waiting for,
- the open remaining work + next steps (folded in from the subagents' PAUSE reports and the
  main agent's own state).

After the wake-up the main agent works EXCLUSIVELY the newest block (the one written just
before the reset that just happened), never the older one below it; it marks done points as
done. If it runs into the limit again it writes a new block on top and the oldest drops out.

Exception - 97 % Lockdown: write NO protocol (it costs tokens that are already scarce at
97 %). Instead set the resume wake-up IMMEDIATELY and stop; after the reset, continue from
the session context.

### Auto-resume - only the credo method

Pausing across a 5h reset and coming back uses ONLY the credo-documented keep-alive / wake
method described in the Keep-alive section above: `ScheduleWakeup` as the primary self-wake,
marked with `credo-autonomy-wake-mark.sh` (same `delaySeconds`) so the Stop hook lets the
turn stop, and the offset AFTER a reset taken from the budget skill's `wakeup.*` config
(default 5 minutes, fallback 1). Do not invent any other wake mechanism.

### compact-plus precedence (5h reset wins)

The 5h-reset wake-up takes PRECEDENCE over compact-plus. On a collision - the 5h axis is
near its cap AND the session-context threshold has been reached - do NOT run compact-plus
before the reset (it costs tokens and could blow the 5h limit). Set the reset wake-up, stop,
and run compact-plus only AFTER the reset, once it is safe. The same applies to the weekly
axis.

### Per-task and per-question ntfy

Autonomous mode is where the common-core ntfy hybrid does the most work. Send every ntfy
push through the helper `${CLAUDE_PLUGIN_ROOT}/scripts/credo-ntfy-send.sh "message"` (with
`-t "Title"` and `CREDO_NTFY_PRIORITY=high` as needed); it resolves the topic/server through
the cascade internally (`credo-config.sh get personal.ntfy_topic` / `personal.ntfy_server`)
and is a silent no-op when ntfy is not configured, so you never touch the topic directly.
Send an immediate `high` ntfy for come-to-PC events (a deferred question, a blocker /
showstopper, a budget cap reached, run completion, the pre-hibernate veto) and BEFORE the
blocking action.
Progress is bundled into one digest per `ntfy.digest_interval_minutes`, and - when ntfy is
configured (a `personal.ntfy_topic` is set) - sending that digest is MANDATORY per interval
whenever there is progress; it is NOT the agent's discretion to judge it "not important
enough" and stay silent (this is what fixes digests arriving far too rarely). With no topic
set, ntfy stays silently skipped (see the end of this paragraph). Every completed item in the digest carries the full content
standard from the common core (what / how / where / why); a terse one-liner is not
acceptable. Prefer one message; if it exceeds ntfy's size limit, split into `n/m` messages.
If `personal.ntfy_topic` is empty, skip ntfy silently - but then note that autonomy is
running blind on notifications. Run completion is `high`.

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

### Empty buildable queue = end-of-run (kills the idle loop)

No buildable item remaining is an END-OF-RUN condition. The keep-alive notion of "open work"
means BUILDABLE work, not "any file physically in `2_go`". This closes the limbo where an
agent keeps the keep-alive alive while refusing to build (the RETRO's ~7h idle loop). A file
in `2_go` that the agent is treating as non-buildable does NOT count as open work - flag it
(the section above) and, if it is the only thing left, the buildable queue is empty.

**Fresh-listing backstop (mandatory before declaring done or powering down).** Before an
autonomous run declares itself "finished" OR starts the power-down / suspend sequence, it
MUST FRESHLY list the GO folder right then - do not trust an earlier snapshot:

```
ls -1 .credo/items/1_todo/2_go/
```

Judge the actual current contents:

- If buildable, open, autonomous-eligible items are there, the run may NOT stop without a
  reason. Either build them, or - for every remaining item - name the concrete non-build
  reason explicitly (a user-only decision, a hard block, or a placement / hygiene flag; see
  "A non-buildable item in 2_go" above). "I thought I was done" is not a reason.
- Only once the listing is FACTUALLY empty, or every remaining item is flagged
  non-buildable WITH its reason, is the buildable queue empty and the end-of-run /
  power-down sequence allowed to proceed.

When the buildable queue is empty (confirmed by the fresh listing above), run this
end-of-run sequence:

1. Send an immediate `default`-priority ntfy stating nothing was buildable - `default`, not
   `high`, because it need not wake the user.
2. End autonomous mode via `credo-autonomy-off.sh` (clears the flag, makes the Stop hook
   inert so the run can stop).
3. Schedule a ~20 min wake (`windows.veto_minutes`) as a veto window.
4. No veto within the window -> power down, gated on `sleep.enabled` (default OFF; on the
   user's personal machine: on). This REUSES the existing power-down procedure below (veto
   window, retry plus success detection, secure-work-first, the exact `sleep.command`) - do
   not duplicate it.

Distinction: "all work genuinely completed / built" stays a `high` ntfy (come see results).
Only the nothing-was-buildable case uses `default`. Both are end-of-run and feed the same
power-down gate below.

### Power down the machine at the end (I9)

The machine power-down can be EITHER suspend (standby / suspend-to-RAM) OR hibernate
(suspend-to-disk), per `sleep.mode`; refer to it generically as "power down / sleep the
machine". The global "never auto power-down" rule lives HERE now, scoped by mode:

- Non-autonomous modes (active, passive): NEVER auto power-down. Only sleep the machine on an
  explicit user request.
- Autonomous mode: the end-of-run triggers are EITHER everything is done (which includes an
  empty buildable queue - see the section above), OR a showstopper occurs, OR the weekly axis
  hits its power-down trigger. On the weekly axis the reset is NOT
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
with retry plus timestamp-based success detection so a repeated trigger cannot fire the
power-down twice and a successful sleep is never miscounted as a failure):

1. Send an ntfy `high` announcing the pending power-down and open a veto window -
   `windows.veto_minutes` (default 20):

   ```
   "${CLAUDE_PLUGIN_ROOT}/scripts/credo-config.sh" get windows.veto_minutes
   ```

2. During the veto window, watch for the user coming back. If the user responds or
   otherwise signals presence, CANCEL the power-down - do not sleep the machine out from
   under an active user.
3. Before powering down, make sure work is secured (git-push policy and, where relevant, the
   credo `compact-plus` securing) so nothing is lost across the sleep.
4. Retry with success detection (applies to BOTH power-down modes - `suspend` on native
   Linux and `hibernate` on WSL / Windows). Read the three thresholds from config, with the
   named defaults as fallback:

   ```
   "${CLAUDE_PLUGIN_ROOT}/scripts/credo-config.sh" get sleep.retry_count       # default 3
   "${CLAUDE_PLUGIN_ROOT}/scripts/credo-config.sh" get sleep.retry_spacing_s   # default 30
   "${CLAUDE_PLUGIN_ROOT}/scripts/credo-config.sh" get sleep.success_gap_min   # default 5
   ```

   - BEFORE the first power-down attempt, write the pending-suspend timestamp marker:

     ```
     "${CLAUDE_PLUGIN_ROOT}/scripts/credo-suspend-mark.sh" write
     ```

   - Then run the EXACT command from `sleep.command` (read via the config above) to power
     down. Do NOT hardcode or guess the command - it is platform- and mode-specific and set
     at setup.
   - Retry the command up to `sleep.retry_count` times (default 3), waiting
     `sleep.retry_spacing_s` seconds (default 30) between attempts - but ONLY while the
     machine is still obviously awake. A further attempt is made only when we clearly did
     NOT fall asleep (the turn kept running); the moment the machine actually sleeps, the
     process is frozen and no further attempt is issued.

5. Success detection on the next turn / wakeup (this replaces the old double-fire flag).
   Ask the helper how long ago the marker was written and compare the jump:

   ```
   "${CLAUDE_PLUGIN_ROOT}/scripts/credo-suspend-mark.sh" elapsed   # seconds, or exit != 0 / empty if no marker
   ```

   - If the elapsed jump is GREATER than `sleep.success_gap_min` minutes (default 5, set
     deliberately well above the retry window) - the helper reports seconds, so compare
     `elapsed_seconds > success_gap_min * 60` - the machine really slept - the power-down
     SUCCEEDED. Clear the marker, drop the power-down intent, and do NOT re-suspend and do
     NOT score it as aborted / failed:

     ```
     "${CLAUDE_PLUGIN_ROOT}/scripts/credo-suspend-mark.sh" clear
     ```

   - If the marker is absent (helper exits non-zero / prints nothing), there is no pending
     power-down - do nothing.
   - If a user interrupt arrives right after waking (a real user message, which also turns
     autonomy off), do NOT re-suspend - clear the marker and stay awake for the user.
   - Only a small elapsed jump (at or below `sleep.success_gap_min`) with the intent still
     open and no user present means the earlier attempts did not take effect - only then may
     the power-down be attempted again under the same retry budget.

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

### Budget-start read-back (mandatory before any autonomous start)

Before starting an autonomous run - always, not only overnight - the agent MUST give a
COMPLETE, UPFRONT read-back, ONCE, and only then start. The read-back has four parts (a
scattered or late partial read-back is not acceptable):

1. **(a) Show the schedule row that applies now.** Read the cap schedule and print the ONE
   row in force for the current local weekday and hour (day, window, `five_hour_cap`,
   `weekly_cap`), plus the current live budgets:

   ```
   "${CLAUDE_PLUGIN_ROOT}/scripts/credo-config.sh" get budget.schedule
   ```

   Pick the applicable row exactly as the credo `budget` skill's row-selection rule
   describes (B1); do not re-invent caps.
2. **(b) Reflect the understanding back - COMPLETE, not a one-liner.** State, in one short
   read-back, what the current row means for this run - specifically whether there is
   anything to conserve and, if so, how much headroom is left before the cap. This read-back
   must not be a vague one-liner: it MUST print, explicitly, BOTH live figures (the current
   5h% AND the weekly%) AND BOTH applicable row caps (`five_hour_cap` AND `weekly_cap`), in
   addition to naming the binding axis in (c).
3. **(c) Name the binding axis (the current brake).** The read-back MUST state explicitly
   which axis is the brake right now = the SCHEDULE-CAPPED axis with the LEAST headroom to
   its row cap. Read each axis against the correct reference:
   - The 5h axis is read against the enforced autonomous LADDER rung
     (`budget.autonomous_5h.main_ladder`), NOT the soft/hard band - in autonomous mode the
     ladder OVERRIDES that band on the 5h axis (see the "5h-budget-guard" section above and
     its ladder-overrides-the-band note).
   - The weekly axis is read against the applicable schedule row's `weekly_cap`.
   - Binding = whichever CAPPED axis has the LEAST headroom to its cap. If the applicable
     row imposes no real cap on an axis, that axis is NOT binding; if neither axis is really
     capped, state plainly "nothing binding right now". This MUST stay consistent with the
     mental model below - the schedule row decides. Never present the raw 7-day / weekly
     utilization number as the brake when no row caps it: it is context, not a cap.
4. **(d) Declare the suspend posture (one line, ALWAYS present - every case, including
   `sleep.enabled` false).** Read the sleep config at start and declare, in one line, the
   posture the existing sleep gate (see "Power down the machine at the end" above) will
   produce. This DECLARES what that gate will do; it does not restate, fork, or duplicate the
   mechanism or the veto machinery - it reuses them:
   - `sleep.enabled` false (the DEFAULT): "I will NOT power down; the machine stays on; at
     end-of-run I end cleanly via `credo-autonomy-off.sh`."
   - `sleep.enabled` true: "at end-of-run I will `sleep.mode` (suspend or hibernate) per
     `sleep.command`, gated on `sleep.enabled`, with a `windows.veto_minutes` veto window."
   - enabled but `sleep.command` EMPTY (misconfig): state it will end WITHOUT powering down
     (per the misconfig guard above).

**Timing - once upfront, plus a short repeat on genuine transitions.** The full read-back
above stays mandatory ONCE upfront before the run starts. In ADDITION, give a FRESH, SHORT
read-back again whenever the binding situation actually changes mid-run - specifically on a
schedule-row transition (e.g. entering `work_hours`), a user cap-override taking effect or
expiring, or crossing into a hard / ladder-enforced zone. Keep the repeat short: the (new)
binding axis + the numbers that changed + the suspend posture only if it changed. This is NOT
per-turn spam - only on those genuine transitions, never every turn.

Mental model (this is the point, and it is user-agnostic): the schedule (`budget.schedule`)
is the SINGLE SOURCE OF TRUTH for how budget is apportioned. Whether there is anything to
conserve at all is DERIVED FROM THE SCHEDULE, never assumed:

- If the applicable row sets a real cap (some profiles do), budget IS to be conserved -
  pace against that cap.
- If the applicable row sets practically no cap, there is nothing to conserve - do not
  throttle work for a limit the plan does not impose.

Never invent a conservation duty the schedule does not create. In particular, do NOT read a
weekly / 7-day utilization figure as "budget that must be conserved" when no schedule row
caps it - that misreads a raw usage number as a self-imposed ceiling the plan never set. The
schedule row decides; the 7-day number is context, not a cap.

Per the common-core read-back (A4), a large / overnight run additionally reads back the
next day's schedule rows and the planned rest state before it starts, so the whole
unattended run stays inside the intended envelope.

### Marker plus compact-plus

Secure progress across context compaction via the credo `compact-plus` skill, driven by the
limit plugin's session-context threshold signal (config `compact.thresholds`). Do not
self-trigger compact-plus proactively - only on the injected ACTION line or a manual
invocation. Pair the keep-alive wake marker with this securing so a long unattended run
neither falls asleep nor loses approved work.
