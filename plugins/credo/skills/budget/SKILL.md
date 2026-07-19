---
name: budget
description: >
  The single source for all API budget cap and reset rules - how much of the 5-hour and
  weekly API limits may be spent, when to throttle, pause, wake up, or hibernate, and the
  commit-identity gate that runs before any commit. Use whenever you are about to start or
  continue autonomous work, before spawning or stopping subagents, when deciding how large
  a task chunk to take on, when a limit is near a cap, before a commit, or whenever someone
  asks "how much budget is left" or "can I keep going". Works standalone (no session skill
  required) and applies inside subagents too: any agent that spends API budget or commits
  must apply these rules.
---

# budget - API budget caps, resets, and the commit-identity gate

This skill is the one place that decides how much API budget may be spent and what to do
as a limit fills up. It is config-driven: the cap schedule and thresholds live in the
credo config, this skill explains how to read and apply them. It also owns the
commit-identity gate that must pass before any commit.

## Three axes - never confuse them (B11)

There are three completely separate budget axes. Keep them strictly apart; a rule for one
never applies to another:

1. The 5-hour API limit - a rolling window that resets roughly every 5 hours. Field
   `five_hour.utilization` (percent used). This skill governs it.
2. The weekly API limit - a 7-day window. Field `seven_day.utilization` (percent used).
   This skill governs it.
3. The SESSION context fill - how full the current context window is (the compact axis).
   This is NOT an API budget. It is governed by the compact-plus skill and its
   `compact.thresholds` config, not here. Do not mix it into 5h/weekly reasoning.

When you say "budget" be explicit about which axis. "5h at 80 percent" and "context at 80
percent" are unrelated facts with unrelated responses.

## Data source: the limit-plugin cache only (B8)

The limit plugin is a PREREQUISITE for all budget data. Without a fresh cache, NO
percentage-based cap is measurable or enforceable - not the schedule caps and not the
fail-safe caps below, because every one of them is a percentage of a number that only the
cache provides. Do not treat the fail-safe caps as a substitute; they too are unenforceable
with no fresh cache. The only guardrail enforceable without the cache is a wall-clock
timebox.

- For non-autonomous, ad-hoc reads ("how much budget is left"): budget data is simply
  unavailable - note that it cannot be read, do not error.
- For AUTONOMOUS mode entry: never run blind and never silently ignore budgets. The
  guardrail-availability gate in the credo `session-autonomous` skill decides what to do -
  it asks the user (install the limit plugin, run a wall-clock timebox, or proceed at an
  explicitly accepted risk). See that skill; this skill only supplies the honesty rationale.

Two ways to read the current numbers:

- The `[limit] ... | 5h X% | Weekly Y%` context line, injected by the limit plugin's hook.
  When that line is present, use those percentages directly - no file read needed.
- The limit cache file for exact values and reset timestamps. Use the read-only helper:

  ```
  "${CLAUDE_PLUGIN_ROOT}/scripts/credo-budget-read.sh"          # key=value lines
  "${CLAUDE_PLUGIN_ROOT}/scripts/credo-budget-read.sh" --json   # trimmed JSON
  ```

  It finds the newest `/tmp/claude-mb-limit-cache_*.json` (one per profile), checks the
  file is fresh, and prints `five_hour_utilization`, `five_hour_resets_at`,
  `seven_day_utilization`, `seven_day_resets_at`, `seven_day_sonnet_utilization`, plus the
  cache age. Exit codes: `0` fresh data printed, `3` no cache (limit plugin absent), `4`
  cache stale (do not use). Only use the cache when it is present AND fresh; a stale cache
  (old mtime, limit plugin dormant) must NOT be trusted - treat it like absent.

### Security (hard rule, non-negotiable)

- NEVER read `~/.claude/.credentials.json` or any OAuth token.
- NEVER run the usage-statusline script (it touches the token).
- Only read the existing limit cache - it holds display values (percentages, reset times)
  only, no secrets. The helper above obeys this boundary; if you read the cache by hand,
  obey it too.

## The default cap schedule (B1) - config-driven

The cap schedule is a universal default in the config under `budget.schedule`; read it,
do not re-invent it. Each entry has `day`, `window`, `five_hour_cap`, `weekly_cap`
(percentages). Read it with:

```
"${CLAUDE_PLUGIN_ROOT}/scripts/credo-config.sh" get budget.schedule
"${CLAUDE_PLUGIN_ROOT}/scripts/credo-config.sh" get budget.work_hours
"${CLAUDE_PLUGIN_ROOT}/scripts/credo-config.sh" get budget.five_hour
```

The schedule renews daily. How to pick the row that applies now:

1. Take the local weekday and the local hour.
2. `budget.work_hours` gives `start` (default 9) and `end` (default 17). Work hours apply
   Mon-Fri only; on Saturday and Sunday there is no work-hours row.
3. Match the `window` for the day:
   - `all_day` - the whole day (Sunday).
   - `work_hours` - Mon-Fri, hour in [start, end).
   - `off_hours` - Mon-Thu, outside [start, end).
   - `after_17` - Friday from `end` onward.
   - `before_reset` / `after_reset` - Saturday, split at the weekly reset (`seven_day.resets_at`,
     around 18:00 local): before the reset the weekly ceiling is high (weekend catch-up),
     after the reset the fresh week starts low again.
4. The matched row's `five_hour_cap` is the hard 5h cap for now; `weekly_cap` is the
   weekly ceiling for now.

For the 5-hour axis, off-hours use a soft/hard band from `budget.five_hour`:
`soft_percent` (default 92, warn and start winding down) and `hard_percent` (default 95,
stop). The schedule's `five_hour_cap` for off-hours rows equals the hard value. Work-hours
rows cap the 5h window low (default 40) so the 09:00 guard below can hold.

Worked examples (with the shipped defaults):

- Wednesday 11:00 local -> Wed `work_hours` row -> 5h cap 40, weekly cap 60.
- Wednesday 21:00 local -> Wed `off_hours` row -> 5h band soft 92 / hard 95, weekly cap 60.
- Friday 14:00 -> Fri `work_hours` -> 5h cap 40, weekly cap 80.
- Friday 22:00 -> Fri `after_17` -> 5h soft 92 / hard 95, weekly cap 99.
- Saturday 15:00 (before the ~18:00 reset) -> Sat `before_reset` -> 5h 95, weekly 99.
- Saturday 20:00 (after the reset) -> Sat `after_reset` -> 5h 95, weekly 30.
- Sunday any time -> Sun `all_day` -> 5h 95, weekly 30.

### Explicit user orders override the schedule (temporarily)

An explicit budget order from the user (for example "stay under 25 percent weekly today")
overrides the schedule, but ONLY until the user-named end. The main agent must actively
ask for that end (date/time) and must, before every autonomous start, ask whether the
default caps fit or need a temporary change and until when. When the named end passes, the
schedule defaults resume automatically. Do not persist an override past its end and do not
invent one the user did not state.

## The 09:00 guard (critical)

Independent of the real reset timing, at 09:00 on each work day at least
`budget.nine_oclock_guard_reserve_percent` of the 5h limit must remain - default 60, i.e.
no more than 40 percent consumed by 09:00. Throttle proactively as 09:00 approaches: do
not spend the window down late at night such that it cannot recover to the reserve by 09:00.
This guard is why the work-hours 5h cap is low. Read the reserve with:

```
"${CLAUDE_PLUGIN_ROOT}/scripts/credo-config.sh" get budget.nine_oclock_guard_reserve_percent
```

## Task-sizing recommendation by remaining 5h (B12) - never a standstill

Size the next chunk to the remaining 5h budget. Thresholds are in
`budget.task_sizing` (`large_below_percent` default 60, `medium_below_percent` default 80),
expressed as percent USED of the 5h window:

- used below `large_below_percent` (default < 60) -> take large chunks first.
- used between the two (default 60-80) -> take medium tasks.
- used at or above `medium_below_percent` (default >= 80) -> take only small tasks, and
  check the limit more frequently (smaller overshoot / abort risk).

This is a RECOMMENDATION only. It must NEVER cause a standstill - never leave work
unstarted because a task looks "too big". If budget is tight, go piecemeal: break the work
down and make incremental progress. In doubt, prefer stopping a subagent with a saved
intermediate result over a hard stop that loses work. This complements the 5h guard below.

## The 5-hour guard (B3) - skill behavior, no hook

The 5h guard is pure skill behavior; there is deliberately no hook enforcing it.

- Check the 5h utilization frequently, including while subagents run in parallel.
- As you approach the applicable cap, wind down: stop starting new work.
- If running subagents would blow the cap, stop them with TaskStop - prefer capturing an
  intermediate result first.
- Before the absolute ceiling, pause and schedule a wake-up until the window resets
  (see wake-up below), then resume automatically.

## Range convention: lower vs upper cap (B5/I10)

Treat the cap as a range, not a single hard line:

- Lower bound = finish up. Aim to have work land just short of the cap so the main agent
  still has room to process the subagents' output.
- Upper bound = hard stop the subagents AND reserve roughly 2-3 percent for the main agent
  to pause/hibernate cleanly. A clean pause/hibernate takes priority over processing
  leftover output - catch that up after the reset.

There is no fixed percent of overshoot beyond the ceiling; do not plan to exceed it.

## Weekly ceiling and hibernate (B4)

When the weekly axis reaches 99 percent (`seven_day.utilization >= 99`), move to rest /
hibernate as soon as possible. This 99 hibernate is the absolute LAST-RESORT net (it equals
the absolute weekly fail-safe below); it always still triggers if the pause path fails or
weekly climbs to 99. The hibernate mechanics (veto window, double-hibernate protection, the
"never auto-hibernate unless autonomous" rule) live in the autonomous session skill; this
skill only sets the weekly triggers - both the pause path here and the 99 net.

### Weekly pause-and-resume - the PREFERRED path before the net (autonomous mode)

The weekly reset is NOT a default showstopper. In autonomous mode, before falling to the 99
net, prefer to pause the session across the weekly reset and then resume with a fresh weekly
budget. Gate the whole path on `budget.weekly_pause.enabled` (default true); when false, only
the 99 hibernate net applies.

```
"${CLAUDE_PLUGIN_ROOT}/scripts/credo-config.sh" get budget.weekly_pause.enabled
"${CLAUDE_PLUGIN_ROOT}/scripts/credo-config.sh" get budget.weekly_pause.switch_percent
```

Read `seven_day_utilization` and `seven_day_resets_at` from the limit cache
(`credo-budget-read.sh` - those are the exact keys it prints). "Reset is near" =
`seven_day_resets_at` falls on the SAME local
calendar day as now - read this dynamically from the cache, NEVER a hardcoded weekday (the
reset day can change).

- Weekly utilization below `switch_percent` (default 97): work normally under the
  schedule's `weekly_cap`. No pause.
- Weekly utilization at or above `switch_percent` AND the reset is near: do NOT hibernate.
  Secure current work first (commit/push per the git-push policy), stop taking new large
  chunks, then CHAIN ScheduleWakeup until just after `seven_day_resets_at` (use the wake
  offset `wakeup.reset_offset_minutes`, fallback `wakeup.fallback_offset_minutes`; a single
  ScheduleWakeup delay is clamped to at most one hour, so CHAIN for the longer wait). After
  the reset, resume with the fresh weekly budget.
- Weekly utilization at or above `switch_percent` but the reset is NOT near (a different
  calendar day): the pause would mean sleeping too long - fall through to the normal
  hibernate-at-99 path (the last-resort net).

Reserve rule: never burn to 100 percent (the hard API wall). The ~97 switch point must leave
room for the wake-chain itself (chained wakes cost budget) and a clean resume; that is why
the switch fires below 99.

The absolute weekly fail-safe (`budget_failsafe.weekly_percent`, default 99) always still
triggers hibernate as the final net. The hibernate ACTION itself lives in the autonomous
session skill; this skill only sets the weekly triggers (both the pause path and the 99 net).

## Wake-up after a reset (B7)

When you pause for a limit to reset, schedule the wake-up for the configured offset after
the reset. Take `resets_at` from the limit cache (`five_hour_resets_at` or
`seven_day_resets_at`). Offsets are in the config:

```
"${CLAUDE_PLUGIN_ROOT}/scripts/credo-config.sh" get wakeup.reset_offset_minutes    # default 5
"${CLAUDE_PLUGIN_ROOT}/scripts/credo-config.sh" get wakeup.fallback_offset_minutes # default 1
```

Default: wake 5 minutes after the reset; fall back to 1 minute if the preferred offset
cannot be used. ScheduleWakeup clamps a single delay to at most one hour, so for a longer
wait chain several wake-ups. (The keep-alive/wake mechanics themselves belong to the
autonomous session skill.)

## Ignoring budgets is prompt-driven, not a flag (B9)

Whether to relax or ignore budgets is decided purely by the user's prompt - there is no
persisted "ignore budgets" flag. If a compact drops an explicit user order, the schedule
(B1) plus the absolute fail-safe caps act as a safety net so nothing runs away:

```
"${CLAUDE_PLUGIN_ROOT}/scripts/credo-config.sh" get budget_failsafe.five_hour_percent  # default 98
"${CLAUDE_PLUGIN_ROOT}/scripts/credo-config.sh" get budget_failsafe.weekly_percent      # default 99
```

Even with no other rule in effect, never exceed 5h 98 percent or weekly 99 percent.

## Commit-identity gate (verify before every commit)

credo is a verify gate before any commit. Before committing, confirm the local identity
that would author the commit matches the identity already used in this repository -
mismatched identities pushed to a shared repo invite force-push damage and history
rewrites.

Procedure:

1. Determine the existing commit authors of the repo:
   `git -C <repo> log --format='%an <%ae>' | sort -u` (recent history is enough on large
   repos).
2. Determine the local identity that would commit:
   `git -C <repo> config user.name` and `git -C <repo> config user.email`.
3. Compare. If the local identity is not among the repo's established authors, DO NOT
   commit. Raise a showstopper warning (this is a force-push / wrong-identity danger) and
   get it resolved before any commit.

Rules for this gate:

- No hardcoded name or email anywhere in this skill. Identity provisioning stays
  dogma-first: rely on dogma, the git config, and the gh logins already in place. Inspect
  dogma first; credo is only the gate, not the provisioner.
- The `git log` comparison against the repo's own history is ALWAYS the primary source
  and is run for every repo at commit time - never skip it, and never let a hint stand in
  for it. On a mismatch, do NOT commit; warn.
- An optional expected-identity hint may live in the config
  (`personal.commit_identity_hint`); when set, use it only as an additional cross-check on
  top of the `git log` comparison, never as a replacement. It is runtime-decidable and
  cascades global < project: a global hint is a default identity that a per-project value
  overrides, so a work repo vs a private repo each get the right identity. Empty means
  rely on git/dogma.

  ```
  "${CLAUDE_PLUGIN_ROOT}/scripts/credo-config.sh" get personal.commit_identity_hint
  ```

- If commit or push is forbidden by permissions, that is itself a showstopper for
  autonomous work (the work cannot be secured) - surface it, do not silently continue.

## Config keys this skill uses

- `budget.schedule` - the daily cap rows (day, window, five_hour_cap, weekly_cap).
- `budget.work_hours.start` / `budget.work_hours.end` - work-hours boundaries (Mon-Fri).
- `budget.five_hour.soft_percent` / `budget.five_hour.hard_percent` - off-hours 5h band.
- `budget.nine_oclock_guard_reserve_percent` - reserve that must remain at 09:00.
- `budget.task_sizing.large_below_percent` / `budget.task_sizing.medium_below_percent`.
- `budget.weekly_pause.enabled` - gate for the weekly pause-and-resume path (default true).
- `budget.weekly_pause.switch_percent` - weekly percent at which, if the reset is near, the
  session pauses across the reset instead of hibernating (default 97).
- `budget_failsafe.five_hour_percent` / `budget_failsafe.weekly_percent` - absolute caps.
- `wakeup.reset_offset_minutes` / `wakeup.fallback_offset_minutes`.
- `personal.commit_identity_hint` - optional identity cross-check.

All of these are read through `scripts/credo-config.sh get <key>` so global and per-project
overrides apply automatically. Personal values live in the git-excluded config, never in
this skill.
