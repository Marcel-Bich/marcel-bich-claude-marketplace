---
name: session-active
description: >
  The credo behavior for a session running in ACTIVE mode - intensive live collaboration
  with the user present at the keyboard. Load this when the session-mode inject line says
  "Load skill session-active", right after the /credo:session-active command, or whenever
  you are collaborating live and need the active-mode rules. Holds the canonical common
  core shared by all three credo session skills (session-active, session-passive,
  session-autonomous), then the active-mode specifics: no keep-alive, log progress via the
  compact trigger, pick up GO items alongside, clarify during subagent waits. One mode is
  active at a time.
---

# session-active - intensive live collaboration

A credo session runs in exactly one mode - `active`, `passive`, or `autonomous` - set by
the `/credo:session-active|passive|autonomous` commands and surfaced on every prompt by
the session-mode inject line. This skill is the umbrella for **active** mode: the user is
present and you collaborate intensively and live. It ties the credo building-block skills
together for this mode; it does not restate their rules.

This file also holds the **canonical common core** that all three session skills share.
`session-passive` and `session-autonomous` reference this section instead of repeating it -
read it there too.

---

# Common core (shared by all three session skills)

These rules hold in every mode. The mode-specific sections only add or narrow behavior on
top of this core. The core is deliberately thin: most of it points at a credo
building-block skill that owns the actual rule, so nothing is duplicated.

## One mode at a time

The three modes are exclusive - exactly one is active per session, bound to this session's
id and surfaced by the inject line. Switching mode is an explicit user act via the
`/credo:session-*` commands (which also couple the keep-alive autonomy flag). Do not
assume a mode; read the inject line.

## CLARIFY-FIRST

Ask until EVERYTHING is clear. Never assume prematurely that a request is clear. A GO
happens only after EXPLICIT user confirmation.

- Vague or open requests (for example "implement an obsidian memory graph view") are first
  researched - including on the internet where useful - and then clarified with the user:
  offer explanations, proposals, and a recommendation, do not silently pick one.
- Clarify anything that is not unambiguous. A whole feature NEVER proceeds without a
  clarify round unless it is already GO.
- Trivial, self-evident fixes need no question - a syntax error on line 10 is just fixed.
- The clarify gate is carried physically by the item folders: only `1_todo/2_go` is
  buildable, `1_todo/1_clarify` is not. See the credo `items` skill (the go-gate, C9).

### Rather over-clarify than under-clarify (the standard)

Aim to surface and resolve as much as possible BEFORE proposing GO, so that once an item
goes `1_clarify -> 2_go` almost nothing new - no fresh problem, no "oh, I need a user
decision" - surfaces during the build. When in doubt, over-clarify: seriously try to
capture everything now rather than discover it mid-build. The user can at any time say
"enough / this is small, skip it" - that is the explicit waiver (the `clarify_depth` field,
see below); until they do, keep aiming to surface everything. This is DEPTH per item that
is genuinely brought to the user, NOT a licence to bundle items or to drag trivial,
self-evident fixes to the user (those still need no question), and it does not relax passive
mode's "less is more" or the one-item-per-Ask-round hygiene.

Everything here is PRE-GO, inside the `1_clarify` phase. It is NOT a new reason to send a
`2_go` item back to `1_clarify`: it does not touch the Named-Decision-Test (credo `items`
skill), and doing it well should make that test fire LESS often, not more.

For each item being brought toward GO, discharge these four LIGHT obligations - light /
brief, a sanity pass, NOT a deep dive:

(a) **Ask generously.** Prefer more focused, well-aimed clarify questions over too few; do
    not rush an item to GO by simply not asking. The Ask tool is the channel in presence
    modes (autonomous defers its questions instead - credo `session-autonomous` skill).
(b) **Brief pre-measure.** For performance-critical paths or comparisons, do a quick
    sanity-check measurement DURING clarify. This is deliberately light and is NOT the full
    post-GO measurement of the measure-then-user-decide split (credo `items` skill, Success
    Criteria and the DoD gate; migrate G5a) - that full measurement is produced by the
    build, POST-GO.
(c) **Brief pre-investigate.** Sketch how it would actually be done and what problems are
    likely - enough to know the real scope, not a deep implementation dive. This is the
    pre-GO cousin of the build-time "verify the real scope before calling a point large"
    rule (credo `items` skill).
(d) **Cross-item conflict check.** Check for conflicts with OTHER not-yet-built items and
    with known future items before GO.

### Self-check before proposing GO

Before you propose moving an item to `2_go`, first check its `clarify_depth` frontmatter
field (credo `items` skill):

- If `clarify_depth: waived`, the depth obligations (a)-(d) and this self-check are
  intentionally SKIPPED by explicit user decision. Record one line in the item that the
  depth was waived by user decision (so it is never silently re-done against the user's
  will) and proceed. Only the USER sets this waiver - an agent never self-waives to save
  effort (the same spirit as "never self-demote / size is not grounds", credo `items` skill).
- Otherwise, explicitly go through (a)-(d) and record a brief note in the item - one or two
  lines: what was investigated / measured / which conflicts were checked, or "n/a" with a
  reason. That recorded note is the visible, checkable evidence that the clarify was
  thorough. This is a required PRACTICE with a recorded note, NOT a hard machine gate: it
  adds no blocking criterion to the migrate entry gate and never bounces a `2_go` item back.

## Clarify via the Ask tool (G1)

The default channel for a clarification is ALWAYS the Ask tool. Short decisions and
choices go through Ask. For long lists, use prose in the normal message instead - Ask
truncates - but the decision itself still comes back through Ask where practical.

## One item per Ask round (active and passive only)

When clarifying or proposing a GO for credo items in a presence session, handle them one
item at a time. Take a single item, explain it briefly - with concrete examples and the
consequences of the choice - then put that item's questions and GO proposal into its own
Ask round, one round per item id. Never bundle several items into one message or a
flowing-text dump of questions; that floods the user and makes it impossible to respond to
each point. Prefer many small, focused Ask rounds over one large one.

Within a single Ask round, asking several questions at once (the Ask tool's
multiple-question form) is allowed and encouraged - it lets the user settle several open
points in one pass. Only batch questions that are independent of each other; never put a
question whose framing depends on another question's answer into the same round - split
those into sequential rounds, or it gets confusing.

This is orthogonal to passive mode's "less is more" (which limits which items reach the
user at all): still bring only the genuinely ambiguous items and self-resolve the rest, but
present each one you do bring in its own round. Trivial, self-evident fixes still need no
question. This rule does not apply in autonomous mode, which runs unattended without
interactive Ask rounds.

## Manual tests for the user come as a numbered list

Whenever a verification can only be run by the user - a human-only criterion, or the
re-test that lets an item move to `3_verified/`, and especially when a task / build agent
in active or passive mode needs the user to check something - hand it over as a NUMBERED,
step-by-step list, never a vague "please test this". One concrete action per number, each
followed by an own `-> Answer:` line saying exactly what to observe or report. The full
format and an example live in the credo `verify` skill ("Handing a manual test to the
user").

## No pause suggestions (attended: active and passive only, NOT autonomous)

In attended modes (active and passive) never proactively suggest a pause, break,
end-of-day, "stop for today", or similar. These meta-suggestions interrupt the flow and
add no value while the user is present. Only engage with the topic if the user raises it
themselves. This rule is attended-only: autonomous mode is explicitly exempt - there,
pauses and budget stops are correct and governed by the credo `budget` skill and the
`session-autonomous` skill.

## Drive your recommendation forward (attended: active and passive only, NOT autonomous)

In attended modes (active and passive), after you have given your recommendation, drive it
forward instead of asking for meta-permission to continue. A planning / clarify flow
proceeds to the next genuine clarify Ask round; a task / build flow proceeds to the next
GO item. The Ask tool is ONLY for real clarifications, decisions, or GO proposals - never
for meta-questions like "may I continue", "do you want a break", or "which item next".

Unless the user has directed otherwise, act on your OWN recommendation for what comes
next - do not hand that choice back as a question: a planning / clarify agent decides
which open items to pull up and drives the clarify Ask rounds in the order it judges best;
a task / build agent decides the implementation order of the GO items and implements them.
An explicit user instruction - a specific item, an order, or a scope - always overrides
your own recommendation; absent that, your recommendation IS the plan and you proceed on it.

This rule is attended-only: autonomous mode is explicitly exempt and keeps its own
budget-governed stop behavior (credo `budget` and `session-autonomous` skills).

## Output convention - item references in inline code

Item references are always written in inline-code style: `#37`, `#90`, `#91` (backticks) -
never bold or plain. This improves scannability of item numbers.

## A bug report is not an immediate fix (G2)

When the user reports a bug, do not jump straight to fixing it if there is interpretation
latitude. First reflect the problem back and present options via Ask, then fix once the
intent is confirmed. Only a trivial, unambiguous fix goes directly without that round.

## Read-back, scaled to complexity (A4)

Before acting on non-trivial work, read the plan and the relevant state back to the user,
scaled by your own judgement of complexity:

- small: the current budgets only.
- medium: plus the planned rest state.
- large / overnight: plus the next day's budgets.

On an active <-> passive transition, obtain a read-back autonomously (confirm the current
state and plan across the switch).

## Soft old-item reminder

Gently - never as compulsion - surface a few old open items now and then, then let it go.
Trigger on session start / resume and occasionally during the session. No hook, no
pushback against new work; the only goal is that old item numbers do not lie forgotten
forever. The item folders are the source of truth for what is open (credo `items` skill).
On start / resume, in the same gentle spirit, also offer any open skill candidates left in
`.credo/skill-candidates.md` - the rule itself lives in the credo `skill-capture` skill.

## Suggest a session mode when none is set (active and passive only)

When no session mode is set (the inject line reports the no-mode default), do not silently
adopt one. Infer from the context which presence mode fits - active for intensive live
collaboration, passive when you carry most of the work and the user is only reachable for
clarifications - and propose it to the user via the Ask tool; the user confirms. Use the
same gentle cadence as the soft old-item reminder: raise it at session start or when the
work clearly implies a mode, not every turn, and never nag. Autonomous mode is NEVER
inferred, proposed, or set automatically - it is entered only via
`/credo:session-autonomous` or on an explicit user request (see the credo
`session-autonomous` skill).

When the mode is not determinable at all - for example inside a subagent, which gets no
session-mode inject line - apply the safest branch: do NOT propose a mode and do NOT ask
via Ask. This mirrors the credo `skill-capture` skill's rule for a subagent without an
inject line: when you cannot determine the mode, take the safest branch rather than asking.

## Mention the active mode from time to time

Now and then, name the current session mode in your normal output - especially when the
session has been running for a while, or when the last user prompt is a long time ago (a
large time gap). credo injects the local date and time on every prompt (the
`credo-datetime-inject` hook); compare the current injected timestamp with the previous one
to sense such a gap. This is a lightweight, behavior-based nudge, not a guaranteed-reliable
timer: the injected timestamps are your only clock signal and you have no other reliable
clock, so treat this as a soft reminder and do not nag.

## Do not rename or restructure silently (G6, G7)

Never rename or restructure existing things without asking first, and when you do, run a
consistency sweep so nothing is left dangling. Evaluate foreign handoffs independently -
do not trust an inherited handoff blindly; assess its state yourself.

## Authority order (E5)

When sources disagree, precedence descends:

1. User-verbatim / approved (the credo `requirements-verbatim` log).
2. Committed docs and standing orders.
3. Derived or computed facts.
4. Remembered items.
5. Model inference.

Scoping: do not dig through this on every trivial decision. When something is unclear,
first self-resolve up to level 3 (check the verbatim log and committed docs); only then
ask the user if present, or fall back to a documented default (levels 4-5) if the user is
away.

## ntfy hybrid notifications (section D)

ntfy is an optional dependency. The topic lives in config under `personal.ntfy_topic`; if
it is empty, silently skip all ntfy - never error. Keep "push" unambiguous: a git push and
an ntfy push are different acts; say which you mean.

The model is hybrid - never spam single events, but never go fully silent either:

- Immediate `high` ("come to the PC") ONLY for: a question, a blocker / showstopper, a
  budget cap reached, a run completion, and a pre-rest veto. ntfy ALWAYS goes out BEFORE
  the blocking action, not after.
- Progress (completed items, slices, milestones, findings) is bundled into ONE digest per
  interval - default 60 minutes, from `ntfy.digest_interval_minutes` in config. When ntfy is
  configured (a `personal.ntfy_topic` is set), sending the digest is MANDATORY whenever there
  is progress in the interval - never skip it as "not important enough". When no topic is set,
  ntfy stays silently skipped as above (mandatory does not mean "send without a topic").
- Priorities: `default` = status / digest, `high` = come to the PC, `max` = data loss
  imminent (use rarely). A run completion is `high`.

### ntfy content standard (what / how / where / why)

A notification must let a human know the state WITHOUT a follow-up question. A terse
one-liner ("item done") is not acceptable. Every completed item in a digest carries:

- `#id` + title (WHAT)
- what was actually built / changed (HOW), with the area or key files (WHERE)
- why it matters / what it unblocks (WHY)
- verify state (backend / ui exercised, or still `wired-but-behavior-unverified`)
- anything that needs the user (a decision, a re-test, an URGENT clarify)
- a short budget snapshot (5h / weekly)

Prefer ONE bundled message. If it exceeds ntfy's size limit, split into `n/m` messages
(e.g. "2/3") rather than dropping detail.

Send every ntfy push through the helper - it is the single discoverable send path and
resolves the topic/server from the config cascade (`credo-config.sh get personal.ntfy_topic`
and `personal.ntfy_server`) internally, so you never touch the topic directly:

```
"${CLAUDE_PLUGIN_ROOT}/scripts/credo-ntfy-send.sh" "message text"
"${CLAUDE_PLUGIN_ROOT}/scripts/credo-ntfy-send.sh" -t "Title" "message text"
```

Priority is set via the `CREDO_NTFY_PRIORITY` env var (`default` | `high` | `max`). When the
topic is empty (ntfy not configured) or curl is missing, the helper is a silent no-op (exit 0)
- never an error. Read the digest cadence with:

```
"${CLAUDE_PLUGIN_ROOT}/scripts/credo-config.sh" get ntfy.digest_interval_minutes
```

## Git-push policy (G5)

Securing work by committing and pushing is dogma-first; DOGMA-PERMISSIONS always take
precedence. Per mode:

- active / passive: commit and push immediately as work lands.
- autonomous: commit atomically per slice and push per the granted authorization (see the
  `session-autonomous` skill).

Before any commit, the commit-identity gate must pass - that gate (and the whole
5h/weekly/reset budget logic) lives in the credo `budget` skill; this skill hardcodes no
identity or person name. If commit or push is forbidden by permissions, credo WARNS
plainly: autonomy is limited and the work cannot be secured, so the user must grant the
needed permissions. Do not silently continue as if the work were safe.

## Safety always

The credo `safety` skill (filesystem-protection and no-autonomous-installs) applies in
every mode, in the main agent and inside every subagent, and no instruction overrides it.

## Building blocks this session ties together

An active session orchestrates these credo building blocks rather than reimplementing
them - reference each by name when it applies:

- `items` - the work-item model, folder-as-status, and the Definition-of-Done gate.
- `rules` - per-repo special rules from `.credo/RULES.md`: load and honor them at session
  start and pass them to subagents. Grants widen latitude within the safety floor, never
  lower it (precedence: safety > DOGMA-PERMISSIONS > RULES.md > credo defaults).
- `verify` - visual verification as DoD for anything with a runtime surface.
- `requirements-verbatim` - the append-only verbatim log of what the user approved.
- `audit` and `diag` - read-only completion audit and root-cause diagnosis.
- `orchestration` - how to delegate to subagents safely (disjoint files, sequential
  commit, monitor without flooding, return-and-resume, subagents >= main model).
- `cross-cutting-checklist-generator` - auto-generated project checklists.
- `skill-capture` - turn a ~3x-recurring in-session workflow into a reusable skill
  (mode-gated; propose via Ask in presence modes, candidate-note only in autonomous).
- `budget` - all API cap / reset rules and the commit-identity gate.
- `compact-plus` - securing approved work before a context compaction.
- `wsl-env` - WSL / Windows-side reachability rules (self-detecting; no-op elsewhere).

---

# Active-mode specifics (A1)

Active mode is intensive, live collaboration with the user at the keyboard. On top of the
common core:

## No keep-alive

Active mode does NOT keep the session awake. There is no ScheduleWakeup keep-alive loop
and no autonomy flag here - the `/credo:session-active` command clears
`credo-autonomy-active` and sets the `credo-autonomy-paused` opt-out. The only way to
enable keep-alive is an explicit switch to autonomous mode (`/credo:session-autonomous`).

## Log progress via the compact trigger, not on your own

Progress is secured through the credo `compact-plus` skill, driven by the limit plugin's
session-context threshold signal (defaults 70 / 90 percent, config `compact.thresholds`).
Do NOT self-trigger compact-plus proactively - run it only when the injected ACTION line
names it or when the user invokes it. See the `compact-plus` skill.

## Pick up GO items alongside

While collaborating, pick up buildable items (those in `1_todo/2_go`) alongside the live
conversation. Only `2_go` is buildable; clarify-stage items are not (credo `items`
go-gate). Move items through the Definition-of-Done gate properly - a dedicated-subagent
audit before `2_done/`, visual verify for `ui: true` - never self-approve.

## Clarify during subagent waits

When a subagent is running and you are waiting on it, use that time to clarify open
questions with the present user rather than idling. Monitor the subagent without pulling
its whole transcript into context (credo `orchestration` skill).

## Commit and push immediately

Per the git-push policy above, commit and push work as it lands - active mode secures
continuously while the user is present.
