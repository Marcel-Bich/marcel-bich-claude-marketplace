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

## Clarify via the Ask tool (G1)

The default channel for a clarification is ALWAYS the Ask tool. Short decisions and
choices go through Ask. For long lists, use prose in the normal message instead - Ask
truncates - but the decision itself still comes back through Ask where practical.

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
  interval - default 60 minutes, from `ntfy.digest_interval_minutes` in config.
- Priorities: `default` = status / digest, `high` = come to the PC, `max` = data loss
  imminent (use rarely). A run completion is `high`.

Read the config values with:

```
"${CLAUDE_PLUGIN_ROOT}/scripts/credo-config.sh" get personal.ntfy_topic
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
- `verify` - visual verification as DoD for anything with a runtime surface.
- `requirements-verbatim` - the append-only verbatim log of what the user approved.
- `audit` and `diag` - read-only completion audit and root-cause diagnosis.
- `orchestration` - how to delegate to subagents safely (disjoint files, sequential
  commit, monitor without flooding, return-and-resume, subagents >= main model).
- `cross-cutting-checklist-generator` - auto-generated project checklists.
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
