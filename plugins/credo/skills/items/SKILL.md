---
name: items
description: >
  The credo work-item model, where the FOLDER an item file lives in is the single source
  of truth for its status, gated by a hard Definition of Done. Use whenever you create,
  update, or track a work item; whenever you decide whether something is "done" and may
  move to 2_done/; whenever you move an item between status folders (clarify, go, done,
  archived, parked); whenever new code might be unwired; or when someone asks where a task
  stands. This is the credo task system: .credo/items/ replaces ad-hoc task lists. Applies
  inside subagents too - if you build or complete work, record and gate it as an item.
---

# items - the credo work-item model

A work item is a single Markdown file under `.credo/items/`. The **folder the file lives
in is the only source of truth for its status**. There is no status field, no marker, no
task-tracker entry - an item changes status by physically moving between folders. This is
deliberate anti-drift: multiple status sources drift out of sync, one physical location
cannot. `.credo/items/` IS the task system; do not mirror items into a separate task list.
"Do not mirror" does NOT mean "never use the harness task list at all" - it means no FULL
items live there; references to items are fine (see "Harness task-list vs .credo items"
below).

> **Task backend.** If the task backend is `gsd` (set in `.credo/config` as `task_backend`, or via the `CREDO_TASK_BACKEND` env override; resolve with `credo-config.sh backend`), the credo item system is inactive - GSD's
> phases are the task system for this project. Do NOT create or move `.credo/items/`; use
> GSD's workflow instead. This skill applies only when the backend is `credo` (the default)
> or `none`.

## Status = folder (the only truth)

The folder tree (created by `credo-init`) and what each folder means:

```
.credo/items/
  1_todo/
    1_clarify/     open questions - NOT buildable yet (human-owned: needs the user; agent-owned: decision rule below)
    2_go/          clarified and approved - buildable (go-gate: only 2_go is buildable)
    3_blocked/     GO'd but hard-blocked by another (unbuilt) credo item; auto-returns to its origin (unblock_to: go|clarify) when every blocker is delivered
  2_done/          Definition of Done met (agent and/or user), gate passed
  3_verified/      human-authorized - human-in-the-loop confirmation (main agent moves here only on explicit user instruction)
  4_archived/      abandoned / deprecated / rejected
  parked/
    hold/          blocked by an EXTERNAL dependency (not another credo item)
    future/        deliberately deferred
```

Never encode status anywhere else. If you want to know an item's status, look at which
folder its file is in - nothing else is authoritative.

## Harness task-list vs .credo items

The Claude Code harness has its own task list (the `TaskCreate` / `TaskList` tools). It is
NOT a second status source and NOT a mirror of `.credo/items/`. This section is the single
source for how the two relate; the credo `orchestration` and `session-init` docs only point
here.

1. **The GO folder is always the primary work set.** A task / build agent's PRIMARY work set
   is ALWAYS the GO folder (`.credo/items/1_todo/2_go`). An EMPTY harness task list does NOT
   mean "nothing to do" - the agent must always fall back to the GO folder. An empty harness
   list is never a stop condition; the GO folder is the authority for what to build.
2. **The harness task list is the ephemeral coordination layer.** It is a temporary,
   compact-surviving scratchpad: reminders, ordering constraints between item
   implementations, HOLD conditions, and small things not worth their own `.credo` item. It
   is NOT a mirror of `.credo` items and must NOT contain full items - only references.
3. **References are welcome; the substance stays in `.credo`.** An item's substance lives in
   its `.credo` file, never in the task list; the harness list carries only references to it.
4. **Completed entries PERSIST - never clear them.** The user reviews the list after an
   autonomous run to see completed vs pending as a next-day reference, so completed entries
   must stay. "Tidying" the list means keeping it current and correct, NOT deleting completed
   entries. This pairs with the end-of-run come-see-results moment and the fresh-listing
   pending backstop in the credo `session-autonomous` skill (end-of-run), where the user
   reviews completed vs pending after an unattended run.

Tag convention: each line is one of `[GO]` / `[HOLD]` / `[REMINDER]` / `[DONE]`, then a
backticked item `#ref`, then a short topic. The `#ref` is written in backticks, matching the
inline-code item-reference convention used throughout the credo skills. Example lines:

```
1. [GO] `#xyz` - topic                (an ordering constraint)
[HOLD] `#xyz` do not build until the user explicitly orders it
[REMINDER] `#1234` X still needed there, but only later after Y is done
```

**Numbering: `#N` only for real items.** `#N` is reserved for real items (credo items, issues,
PRs, tickets). A harness task entry is never referred to as `#N`, because the harness ids
overlap with item numbers: in replies and task subjects write it as `§cct_N` (cct = Claude Code task, e.g. "task `§cct_2`
is still open", never "task #2"). The same goes for any other numbering that is not a real
item. The user writes it the same way ("§cct_2 dd" = harness task 2 done).

> **Terminology.** "task list" / "task liste" means primarily the harness `TaskCreate` /
> `TaskList` entries; only if none exist may the agent interpret what was otherwise meant.

**When the task-list tools are missing.** Newer Claude Code versions offer `TaskCreate` /
`TaskGet` / `TaskUpdate` / `TaskList` on newer models only when the env var
`CLAUDE_CODE_ENABLE_TODO_TOOLS=1` is set (profile `settings.json` `env` object or the process
environment), and subagents only get them when the parent session has them. If you need the
list and the tools are not available to you:

1. Say so ONCE in the session (one short line, not on every turn), naming the opt-in: run
   `/credo:setup` (Step 10) or answer yes to the `[credo-todo-tools]` session-start offer,
   which sets the variable with a backup of `settings.json`. A subagent reports it back to
   the main agent instead.
2. Do NOT silently emulate the list in prose (no hand-numbered `§cct_N` lists in replies
   pretending to be the harness list). The GO folder stays the primary work set, so work
   continues; coordination notes that must survive go into the relevant `.credo` item body
   or the handoff instead.
3. Never set the variable yourself without the user's yes, and never ask about it in
   autonomous mode (there, note it once in the end-of-run report). This also applies to
   the `[credo-todo-tools]` session-start offer: at a fresh start the session mode is
   often not set yet when the hook runs, so the offer itself opens with that rule - check
   the mode before asking.
4. After a yes, the tools may only appear after a restart of Claude Code
   (`credo-todo-tools.sh status` shows `restart_needed=yes` while the variable is in
   settings.json but not yet in the session).

## go=go - the folder is authoritative for building

An item in `2_go` IS buildable, by definition of the folder. This is the build-side
counterpart to the entry gate that governs what may enter `2_go` in the first place (the
credo `migrate` skill owns the G1-G6 entry gate).

- **The folder overrides body-level doubt.** An unproven root-cause hypothesis, a
  "GO unclear" note, or any hedge in the body does NOT override the folder. If the file is
  in `2_go`, build it (best effort).
- **A stale-looking body is NEVER grounds to self-skip or self-demote.** A head or a note
  that still reads "open / not built / needs clarification" is by itself never a reason to
  skip a `2_go` item or to treat it as not-yet-buildable - such prose goes stale (the item
  was already built or clarified but the text was not reconciled; see the Full-body
  reconciliation sweep and the Body-freshness invariant below). Before you treat a `2_go`
  item as still-open or non-buildable on the strength of its prose, you MUST first read the
  WHOLE body AND check the requirements log (`.credo/process/requirements/*.md`) and any
  existing audit reports (`.credo/process/reports/`) - the clarification or the build is
  often already there, just not written back into the head. This is distinct from the
  Named-Decision-Test below: stale prose is NOT a Named-Decision. Only a genuine, still-open
  user-only decision that passes that test sends an item back; a merely stale-looking body
  is reconciled (Full-body reconciliation sweep) and built.
- **Never self-skip, never self-demote.** The building agent does NOT skip a `2_go` item and
  does NOT move it down for reasons of size, UI, or "not sure it is verifiable". It MAY
  re-scope or phase a large item into slices, but it must build. The ONE carve-out is a
  genuine user-only decision that passes the Named-Decision-Test (below) - that is not a
  size/difficulty demotion and is the only sanctioned `2_go -> 1_clarify` path.
- **Verify the real scope before calling a point LARGE.** Before you classify a point as
  large or move it into a follow-up item for size reasons, FIRST briefly verify feasibility
  and the real scope - sketch how it would actually be done - instead of guessing. Size must
  be checked, not assumed: a size claim used to defer must be backed by a quick actual look
  at the implementation, not an estimate. This does not forbid genuine follow-up items when
  they are warranted; it only bars deferring on an assumed size ("too big / too hard" is
  still not grounds - see the Named-Decision-Test). This build-time scope check has a PRE-GO
  cousin: obligations (b) brief pre-measure and (c) brief pre-investigate of the over-clarify
  standard sketch scope and sanity-check measurements DURING clarify, before GO (credo
  `session-active` skill, CLARIFY-FIRST).
- **`ui: true` is not a reason not to build.** UI items are verified via the credo `verify`
  skill, which is autonomous-capable; a required visual verify does not make an item
  unbuildable.
- **Uncertainties are NOTED, not a veto.** Record an uncertainty in the item History or a
  note; it is never a reason to leave a `2_go` item unbuilt.
- **Hypothesis vs open decision (the fine line).** An unproven *hypothesis* WITH a clear fix
  approach (for example a root-cause hypothesis pinned to `file:line`) is buildable - build
  it. An open *design decision / build-detail* is NOT a build-side call: per the entry gate
  (G5) such an item should never have entered `2_go`. If one is found in `2_go` anyway, the
  agent does NOT invent the decision and does NOT silently build on a made-up one - it
  applies the Named-Decision-Test below (a deferred question in autonomous mode, an Ask in a
  presence session, and a move back to `1_clarify` when the test passes).

## Named-Decision-Test - the only ground for sending a 2_go item back

GO=GO is the norm: an item in `2_go` is clarified and gets built. Sending one back to
`1_clarify` is a RARE exception, and only this test authorizes it - never "too big / too
hard / not sure it is verifiable / UI". A `2_go` item may return to `1_clarify` ONLY when
ALL three hold:

1. **A genuine user-only decision exists** - the requirement does not determine the
   outcome, and choosing needs product / taste / scope / UX judgement that is the user's to
   make, not a technical detail the agent can settle with a defensible engineering default.
2. **It is phrasable as an explicit either/or question** - "decide A vs B, because the
   requirement is silent on X". If you cannot write it as a concrete choice, you do not have
   a decision, you have an excuse: build it (go=go).
3. **It blocks correct completion** - the item's core cannot be finished without that
   decision (not a cosmetic detail with an obvious default).

Explicitly NOT grounds (these stay in `2_go` and get built): "too big / too hard /
uncertain whether verifiable", UI, an unproven root-cause *hypothesis that has a clear fix
approach*, or anything resolvable by a defensible engineering default. The test must be
well-founded and must NOT be used as an argument against building the item itself.

Every item in `2_go` is agent-owned (`clarify_owner: agent`, set by the move helper on
entry), so a question surfacing mid-build first goes through the agent decision rule
("Clarify owner and the agent decision rule" below): the agent decides it itself per SOTA /
best effort and builds on. Only a question on that rule's escalation list (user taste or
preference, a change to the verbatim requirement, infeasible or really not good, the hard
safety rules) can pass condition 1 here. An item sent back by this test gets
`clarify_owner: human` again, because its open question is the user's by definition:
`credo-item-move.sh <id> clarify` sets it and logs `clarify_owner <old> -> human` in the
History. A GO line from before the send-back no longer counts; the item needs a new GO.

Typically this surfaces DURING the build, not at read time: an item is normally fully
clarified when it reaches `2_go`, but something critical can still come up mid-build where
building on naively would be wrong instead of clarifying. When the test passes, the agent
MAY move the item back (the one carve-out from "never self-demote" above). Because such an
item was interrupted for a critical reason and likely leaves something broken, it is
URGENT - see below.

## URGENT clarify (surfaced first)

An item sent back to `1_clarify` via the Named-Decision-Test - especially one interrupted
mid-build - is top priority: it probably leaves something broken and must be resolved
before things run clean again. Mark it in the item body with a short
`> URGENT: <what is broken / which decision blocks it>` note at the top of the History
section, rather than adding a priority field or a new folder - "folder = status" and the
lean frontmatter stay intact. The rule that rides on the marker: when the user is available,
an agent surfaces these URGENT clarify items FIRST, before any other clarify or build work.

## Clarify owner and the agent decision rule

The default intention is to build everything as well as at all possible (state of the
art); where that is not possible, best effort; only where even that does not work or would
really not be good, the point is noted and presented to the user. How much work it is never
counts against an item: feasible = GO.

**Who decides depends on the owner** (frontmatter `clarify_owner`, missing = `human`):

- **Human-owned clarify items** (`clarify_owner: human` or missing) are ALWAYS clarified
  with the user, never decided autonomously. In a clarify round the agent recommends per
  the rule below (the recommended option first) and the user decides. Only the user gives
  the GO: `credo-item-move.sh` refuses `-> go` for a human-owned item unless the History
  carries a `(GO: <user quote>)` line or the main agent passes `--user-authorized` on the
  user's explicit GO. A detour via `parked/*` or `3_blocked` does not get around it.
- **Agent-owned items** (`clarify_owner: agent`, plus everything in `2_go`): uncritical
  questions are decided by the plan agent. If no plan agent peer is known (none was
  announced as owning this responsibility), the EXECUTING agent takes this pseudo plan role
  for the moment, without changing its real role, and decides by the same rule:
  1. SOTA - the best solution known today;
  2. else best effort;
  3. else note it and present it to the user later.
  Size or effort is never a reason against a solution. Feasible = GO: an agent-owned clarify
  item may move to `2_go` with the History line
  `-> go <date> (GO: agent per SOTA rule, <reason>)`.
  **No slicing around the user:** an item with `parent: <id>` may only be agent-GO'd while
  its parent is GO'd (in `2_go`, `2_done`, `3_verified`, or `3_blocked` with a GO). Children
  of a human-owned parent that is still in `1_clarify` (or parked, archived, missing) are
  human-owned until the user decides the parent; the move helper refuses the agent GO.
  **Provable owner:** `clarify_owner: agent` counts only when the move helper wrote the flip
  (`clarify_owner human -> agent` in the History) or the item was created as an agent item
  (`parent:` or a `created by agent` History line). A hand-edited `clarify_owner: agent` on a
  user item is treated as human.
  Log EVERY such decision in the item History (what was decided, why) and name it in the
  next reply or report, so the user can veto it.

**Still escalated to the user, also on agent-owned items:**

- anything infeasible or really not good (step 3 above);
- the user's taste or preference (look, wording, product direction);
- deleting user data, installs, money, and the hard safety rules (credo `safety`);
- **verbatim guard:** a question whose answer would change or narrow the user's verbatim
  requirement (the `Requirement (verbatim)` section of the item or of its `parent`) always
  goes to the user (credo `requirements-verbatim`).

**By mode:** interactive (active, passive) - decide the uncritical questions, ask the rest
via the Ask tool (one item per round, Recommended option first). Autonomous - decide the
uncritical questions, park the rest for the end-of-run report (deferred-question flow,
credo `session-autonomous`); never adopt a default for an escalated question.

A user GO in the user's own words is always a valid GO for any item; this rule only adds
that agent-owned items do not wait for one.

## Mandatory frontmatter (lean)

Exactly five required fields. Keep it minimal:

```yaml
---
id: 124                 # integer from credo-id-next.sh (monotone counter, folder is a safety floor)
title: Short imperative title
created: 2026-07-04      # YYYY-MM-DD, the day the item was created (in 1_clarify)
type: feature           # one of: bug | optimization | feature | question | chore
ui: false               # bool - true means a visual verify is a DoD requirement
---
```

- `type`: `bug` | `optimization` | `feature` | `question` | `chore`.
- `ui`: boolean. When `true`, a passing **visual** verification (the credo `verify` skill,
  measured layout + real interaction at every configured viewport) is a mandatory part of
  this item's Definition of Done.
- `audit` (optional, normally absent): the single value `audit: full` forces the full audit
  tier for this item (credo `audit` skill, "Audit depth (risk tiers)"). Absent = the main
  agent picks the tier by risk. There is no `audit: lean` override - an item can only be
  pushed up to `full`, never down.

Everything else (`priority`, `source`, `relates_to`, `regression`, ...) is
**not** a mandatory field. Do not add speculative frontmatter. Write such information only
when it actually applies, free-form in the body.

The one exception is the blocker relation `blocked_by: [ids]` / `blocks: [ids]`: these are
structured (not free-form) and are REQUIRED while an item sits in `1_todo/3_blocked` (see
"GO-but-blocked" below). Outside that state they are omitted. They form a relational
dependency graph, NOT a second status source, so principle "folder = status" stays intact
and the lean-frontmatter philosophy is not broken.

The other documented optional field is `clarify_depth`. It is normally unset/empty, which
means the full over-clarify standard and the pre-GO self-check apply (credo `session-active`
skill, CLARIFY-FIRST). The single value `clarify_depth: waived` records that the USER has
explicitly decided this item does NOT need the deep clarify - a small / easy item, or simply
their choice - so the depth obligations and the self-check are intentionally skipped and
never re-done against their will. Add a short reason inline or on an adjacent line, e.g.
`clarify_depth: waived  # user: trivial rename, no deep clarify`. Only the user sets this;
an agent NEVER self-waives to save effort (same spirit as "never self-demote / size is not
grounds"). Like the blocker relations it is optional and adds no second status source - the
folder still owns status.

Two further optional fields serve parallel scheduling (credo `orchestration` skill,
"Parallel code tracks: touches and resource gate"). Both are normally absent and, like the
fields above, add no second status source:

- `touches` (optional): a list of paths or globs the item will likely edit, e.g.
  `touches: [plugins/credo/scripts/credo-touches-check.sh, docs/*.md]` or a block list.
  The plan / clarify agent sets it, at the latest at GO. It is guidance, not a contract:
  the main agent re-checks it right before spawning builders and updates it when files were
  renamed or moved. `credo-touches-check.sh <id> <id> ...` reports overlapping items, which
  then run sequentially. Absent = the main agent classifies the item itself (parallel by
  default).
- `heavy` (optional): `heavy: true` marks model / benchmark tests or large downloads. A
  heavy item never runs in parallel to another heavy item and starts only when
  `credo-resource-check.sh --heavy` says `ok`.

Two optional fields record who owns an item's open questions (the full rule is in
"Clarify owner and the agent decision rule" below). Like the fields above they add no
second status source:

- `clarify_owner` (optional): `human` or `agent`. **Missing = `human`** (fail-safe); any
  other value is also treated as `human`. `human` = the item comes from the user's own
  words, so its open questions are clarified with the user and only the user gives its GO.
  `agent` = a builder, plan or task agent created it (a slice, a follow-up, a build
  question, an audit finding), so the agent decision rule applies. `credo-item-move.sh`
  sets `clarify_owner: agent` on every move into `2_go` and keeps the origin in the History
  (`(origin: created by user; clarify_owner human -> agent)`): once an item is GO'd, a later
  question about it very likely had no human in the loop. The helper is the only writer of
  the human -> agent flip; never edit `clarify_owner: human` to `agent` by hand (the GO gate
  then treats the item as human). On every move into `1_clarify` the helper sets
  `clarify_owner: human` and logs `clarify_owner <old> -> human`; only an agent-internal
  re-clarify passes `--keep-owner` (the unblock sweep does so for `unblock_to: clarify`).
- `parent` (optional): `parent: <id>` on an agent-created item names the item it came from
  (the sliced, audited or built item). Set it together with `clarify_owner: agent`. While
  the parent is not GO'd, the child counts as human-owned (no agent GO, see the rule below).

When creating an item: from the user's own words (a request, a bug report, an idea the
user stated) -> `clarify_owner: human` (or leave it out); created by a builder, plan or task
agent -> `clarify_owner: agent` plus `parent: <id>`, and the first History line says so:
`- created by agent (clarify) <date> (<why: slice / follow-up / build question / audit
finding of #<id>>)`. Without `parent:` or that line the GO gate treats a `clarify_owner:
agent` item as human. When in doubt, human.

## Filenames and ids

- File name: `<id>-<slug>.md`, e.g. `124-live-reload-panel.md`. The slug is a short,
  lowercase, ASCII, dash-separated summary of the title.
- Frontmatter `id:` matches the number in the filename.
- Reference an item elsewhere as `#124` (plus its date/short context - transcript line
  numbers are not stable references).

> **Output convention.** Item references are always written in inline-code style: `#37`,
> `#90`, `#91` (backticks) - never bold or plain. This improves scannability of item numbers.
- **Get ids only from the counter helper, never compute one yourself.** Issue the next id with:

  ```
  "${CLAUDE_PLUGIN_ROOT}/scripts/credo-id-next.sh"
  ```

  It is deterministic and never-reuse: the monotone counter, not the folder, decides the
  number, so a deleted `#124` is never reissued. On each call the helper also scans the
  items tree as a safety floor and takes `max(counter, highest existing id) + 1`, so a
  stale or rolled-back counter (merge, clone, restore, sync) never hands out an id that is
  already in use (it warns on stderr when it reconciles). Do not compute an id by scanning
  files or taking `max+1` yourself - that reuses deleted ids and skips the lock.

## Body sections

Use these English headings in this order. A blank template ships at
`"${CLAUDE_PLUGIN_ROOT}/templates/item.template.md"`.

1. **Requirement (verbatim)** - the requirement in the user's own words, quoted exactly,
   with its source. Never trim, soften, reinterpret, or invent constraints. Keep
   user-verbatim text strictly separate from any assistant proposal (label proposals as
   such). This mirrors the credo `requirements-verbatim` rule.
2. **Success Criteria (= DoD)** - observable "the user can X" statements, each one
   checkable. These ARE the Definition of Done for this item. Vague criteria that cannot
   be observed are not acceptable; make each one exercisable.
   - **Measure-then-user-decide is not one blocking DoD point.** A criterion where the
     decision is the user's alone and only arises AFTER a measurement the build itself
     produces (for example "measure whether the full solution is worth the cost, then decide
     build vs skip") is NOT a single blocking criterion. Split it at the GO gate (see the
     Definition of Done gate below and the `migrate` G4/G5 entry gate): the buildable
     MEASUREMENT (produce the numbers / the concrete cost-benefit finding) stays in this item
     as a criterion the builder CAN complete; the user-only decision becomes a SEPARATE item
     in `1_clarify`, blocked on the measurement until the numbers exist, and only then does
     the user decide. The parent then stays a clean all-or-nothing item over its buildable
     criteria (the measurement included); it does not sit stuck half-done and is not bounced
     whole back to `1_clarify` over a decision that is not yet open.
   - **Tricky items carry their acceptance measurement BEFORE the build.** An item whose
     result is an algorithm, a detection, or a quality or numeric outcome names in its
     Success Criteria, before the build starts, the data set to measure on and the target
     value (e.g. "on `fixtures/set-a` (120 cases) at least 95 % detected, 0 false
     positives"). The builder measures against it before reporting done and records the
     measured value in `## Verify`. This is different from the measure-then-user-decide
     split above: here the target is fixed up front.
3. **Implemented** - what was actually built, with concrete `file:line` references. This
   is where the wiring is recorded (which caller reaches the new code).
4. **Verify** - the honest 4-valued verification state, per layer. See below.
5. **History (MANDATORY)** - the folder journey with dates. Every move writes a line
   `-> <target> <date> (<reason>)`, e.g.
   `created (clarify) 2026-07-04 -> go 2026-07-04 (GO: user, chat) -> done 2026-07-05`.
   Record why an item moved, especially any move backwards. **Folder<->History invariant:**
   the folder an item is in MUST match the target of its last History line. A mismatch is a
   detected mis-move - flag it and correct it. This is the contradiction detector, achieved
   without adding a second status source.

### Body-freshness invariant

A second contradiction detector, a sibling of the Folder<->History invariant above: the
body must NOT claim open / unbuilt / decision-needed for anything the reality of the item
contradicts - History `(GO:` and later `-> done` lines, `## Implemented` `file:line`
evidence, the requirements log (`.credo/process/requirements/*.md`), an audit report
(`.credo/process/reports/`), or the code / version itself. When the body says
"open / not built / still to decide" but one of those shows it was already GO'd, built,
clarified, or shipped, that is a detected contradiction. On such a contradiction, do NOT
silently build on it and do NOT silently keep reading past it: FLAG it fail-loud AND
reconcile the body in the SAME move (the Full-body reconciliation sweep in the
Build-completion gate is what performs that reconciliation). Like the Folder<->History and
not-started contradictions, this is a skill-level judgement, not a script: the staleness
lives in free-form prose, so it is caught by reading, not by a mechanical scan.

## Item text is perspective-neutral (no "who is doing it")

An item file is durable and read by whoever builds it later - often a different agent or
session than the one that wrote it. Its text therefore describes the WORK and its
DEPENDENCIES, never who is currently handling it. Perspective-relative wording like
"another agent", "hands-off (other agent)", or "I do X, the other agent does Y" breaks
this: a later builder reads "another agent" as someone other than themselves and misreads
the item. Keep who-does-what coordination OUT of the item - it belongs only in the harness
task list (the ephemeral coordination layer defined in "Harness task-list vs .credo items"
above), not in the durable item. State dependencies
by item id (for example `blocked_by: [807]`), not by actor.

## The 4-valued Verify (honest, per layer)

For each relevant layer (`backend`, `ui`, `human-only`), record exactly one of four
states - honestly, never optimistically:

- **not-started** - the code/behavior for this layer does not exist yet; work on it has
  not begun. Distinct from `n/a`, which means the layer does not apply at all.
- **present** - the code/behavior exists in the source, but has not been shown to run.
- **wired-but-behavior-unverified** - it is reachable and called (wired into a real code
  path), but its actual runtime behavior has not been observed.
- **exercised** - the behavior was actually driven end-to-end and observed to be correct
  (for `ui`, that means a real visual verify - see the credo `verify` skill).

For any `human-only` layer that only a person can confirm, add a `why_human` note
explaining what the user must check and why an agent cannot. Until the user has run it,
that layer reads `human-only: pending` (see below).

A verify attempt that surfaces a defect is a **failed** verify: that is not one of the
four progress states above, it is a defect outcome that sends the item back (see "Bug
found during verify"). Only `exercised` counts toward the Definition of Done; a
`human-only: pending` point does not hold the item back (next section).

### Human-only checks do not block done

Checks that only a human can run belong to the verify phase, not to done. An item is done
as soon as everything is built and the agent cannot do anything more on it without a human;
the human-only tests it still needs are recorded in the done item.

- An item moves to `2_done` once everything is built and every check the agent CAN run is
  `exercised`. Pending human-only tests never hold an item in `2_go`.
- Write each one into the done item's `## Verify` as `human-only: pending` with the
  `why_human` note and what to check (a numbered step list per the credo `verify` skill).
  The user runs them in the verify phase (`2_done -> 3_verified`); a failure there sends the
  item back per "Bug found during verify".
- Not a loophole: a check the agent can run itself (a test, a CLI call, a local browser) is
  never human-only. Human-only means it genuinely needs the human - their hands or eyes on
  real hardware, their account, a remote or shared environment the agent must not touch.

Wiring matters: new code with no caller / not reachable is a gap, not "done". At most it
is `present`. The DoD requires `exercised`, which forces the wiring to exist and to run.
If you find unwired code, that is a gap - raise or reopen an item for it.

### Wiring items (only for split server/client architectures)

This rule is CONDITIONAL: it applies ONLY when the project actually has a separated
server/client (or backend/frontend) architecture. Not every repo does - a single-surface
project has nothing to wire across a boundary, and this rule does not apply to it. State
the condition explicitly before invoking the rule.

Where the two halves ARE separate, an item without its wiring is useless: a server-side
capability that no UI ever calls delivers nothing. So when server and client parts are
split, a SECOND wiring item MUST exist that connects them, with a bidirectional reference
between the two (`blocked_by` / `blocks`).

- A server-side item MAY reach `2_done` while its UI-wiring item exists but is still in
  `1_clarify` - the existence of the wiring item is what makes the server work meaningful;
  it does not have to be built first.
- An agent MAY autonomously create and GO this wiring item and build it best-effort. It
  is an agent-created item (`clarify_owner: agent`, `parent:` the server-side item), so
  this is the agent decision rule applied ("Clarify owner and the agent decision rule");
  human-owned items still follow clarify-first (only the user sets their GO).

Before you record `failed` or "not started" for a capability, you MUST first run a wiring
check against the real code: search the source for the endpoint, class, function, or
tests that would implement it. This matters most for items cut from older specs - the
feature may already have been built under a DIFFERENT task or item number, so assuming it
is missing is often simply wrong. If the check shows it is built but its runtime behavior
has not been observed, record `wired-but-behavior-unverified`, not `failed`. Reserve
`failed` for a real defect actually surfaced by exercising the code.

## Build-completion gate (record what you built, in the same move)

The moment build code is committed - an item has actually been built, not just planned -
the building agent MUST, in the SAME turn, bring the item file into line with that reality
(steps 1-3) and check its own work (step 4):

1. Fill `## Implemented` with concrete `file:line` evidence for what was built (which
   caller reaches the new code).
2. Update the DoD / Success-Criteria ticks to match what is now true. Tick only fully met
   points, never with a caveat ("done, but ..." stays unticked).
3. Move `## Verify` off `not-started` for the built layer(s) - at minimum to `present`, or
   `wired-but-behavior-unverified` when the code is reachable and called. (`not-started`
   means "work has not begun"; a build commit proves it has.)

4. Before reporting done, run an adversarial self-check: try to break what you built
   (edge cases, bad input, the failure path, a second run, the unhappy UI path) and list in
   the report what you tried and what held or was fixed. For a tricky item, also measure
   against its acceptance measurement (Success Criteria above). This list is input for the
   audit, not a replacement for it.

This is a mandatory step of the build routine, not a new script. An item with a build
commit that still says "not started" (in any language, e.g. German "noch nicht begonnen") is a CONTRADICTION between
the committed code and the item text - flag it and resolve it, exactly as with the
Folder<->History invariant. Leaving the item stale after committing build code is a
detected mis-state, never an acceptable end.

### Full-body reconciliation sweep (mandatory after every build AND every clarification)

The three steps above cover the fields you just touched. They are the floor, not the
ceiling: after every build (a build commit) AND after every clarification (a question
answered, a decision recorded), you MUST additionally reconcile the WHOLE item body against
the new reality, not only the fields you happened to edit. An item must NEVER be left
claiming "open / not built / decision needed" for anything that is now built or clarified -
items must not go stale. Sweep the entire file:

- ALL Success-Criteria / DoD ticks (not just the ones you touched) against what is now true.
- Every `## Verify` state against the real commit / verify reality.
- Any free-form "open / not built / still to decide / GO unclear" prose ANYWHERE in the
  file - including the head, the `Requirement` section, and `History` notes (for example a
  `> URGENT:` note that a now-answered decision has resolved) - updated or removed.
- Cross-references to other items that a change has made stale.

"Where needed / sensible": this is not a licence-to-churn - it forces no cosmetic edit and
no rewrite of prose that is still accurate. But every stale CLAIM must go: nothing in the
body may still assert open / unbuilt / undecided once the build or the clarification has
made it true. This applies to CLARIFY as well as BUILD - a clarified question is recorded
in the body as clarified and the old open-question prose is updated or removed in the SAME
move, not only after a code build. Leaving stale claims standing after a build or a
clarification is a detected mis-state, exactly like the Folder<->History invariant and the
not-started contradiction above - flag it and reconcile it in the same turn.

## Definition of Done (the gate into 2_done/)

An item may move into `2_done/` ONLY when ALL of these hold. This gate is hard.

1. **Every Success Criterion the agent can check is `exercised`.** Nothing left at
   `not-started`, `present`, or `wired-but-behavior-unverified`. A genuinely human-only
   criterion does not block: it is recorded as `human-only: pending` with what to check and
   runs in the verify phase ("Human-only checks do not block done").
2. **If `ui: true`, a passing visual verify is mandatory** - the credo `verify` skill at
   every configured viewport (measured layout, real interaction, live update where
   required, hard reload after rebuild), with screenshots saved under
   `.credo/screenshots/`. Verify screenshots ALWAYS live under `.credo/screenshots/` and
   follow the name pattern `<slug>-<viewport>-<YYYY-MM-DD>.png` - this holds even when an
   ad-hoc verifier (not the formal `verify` skill) produces them, so every screenshot is
   found in one place under one convention. The required level of test obligation is
   defined by the credo `verify` skill (config `verify.primary_test`), not here. Only a
   visual verify the `verify` skill itself defers as human-only (locality not established)
   may stay `human-only: pending`.
3. **No open remainder** - nothing needed for the item's core is still outstanding that
   the agent could do without the human (pending human-only tests are not a remainder).
4. **Mandatory audit-after-completed by a DEDICATED subagent** - the credo `audit` skill
   MUST be run by a subagent that is NOT the builder of this item. A builder auditing
   their own work does not satisfy the gate. This applies in every session mode (active,
   passive, autonomous), no exceptions. Only a passing audit lets the item enter
   `2_done/`. The audit DEPTH follows risk (`full` or `lean` tier, see the `audit` skill,
   "Audit depth (risk tiers)"); the gate itself is never skipped.
5. **Docs updated in the same change** - documentation is part of the change, not a
   follow-up. Any change that affects documented behavior MUST update the docs in the same
   change; stale docs = incomplete (C14). Prefer `/dogma:docs-update` when dogma is
   installed - it is the canonical README + wiki sync; if dogma is not installed, do a
   best-effort manual update of the affected docs (companion tool when present, graceful
   degrade when not). Scope explicitly includes the project wiki (a separate repo) and
   in-repo READMEs, not just files inside this commit - "same change" is not "same repo
   only". Search `docs/**`, `.credo/docs/`, in-repo READMEs, and the wiki for what the
   change affects and update it now.
6. **Version bump as part of the DoD** - bump the version as part of completing the work,
   dogma-first (follow dogma's versioning if present), credo as fallback only.

The parent's DoD is all-or-nothing over its BUILDABLE criteria ONLY. A
"measure-then-user-decide" point (a user-only decision that arises only after a measurement
the build produces) is NOT a blocking DoD point of the parent: at the GO gate it is split
into a buildable measurement criterion that stays in this item and a separate user-decision
item in `1_clarify` blocked on the measurement (see Success Criteria above and the `migrate`
G4/G5 entry gate). So the parent completes cleanly once its buildable criteria - the
measurement included - are `exercised`; it does not stay stuck half-done waiting on a
user-only decision, and it is not bounced whole back to `1_clarify` by the Named-Decision-Test.

`completed != done`: a builder saying "I finished" is not done. Done is the physical
`2_done/` folder, reached only after the audit gate passes. The marker is the folder, not
a claim and not a task-tracker field.

### Main-agent verification before claiming status or moving

Before the main agent asserts an item's status OR moves it between folders, it MUST read
the WHOLE item file - especially the latest verbatim statements and decisions in the
History and Requirement sections - and check the actual code/state against the item's
INTENT. Inferring status from a commit grep, a commit headline, or a subagent's report
ALONE is not grounds for approval: those are signals, not verification. Already-committed
work is not blindly blessed as done just because a commit exists - the main agent confirms
the built reality matches what the item requires before it claims a status or advances the
item.

The same whole-file read is required before the READ / BUILD decision, not only before a
status move: before ANY agent (main or subagent) treats a `2_go` item as still-open or
not-buildable, it reads the WHOLE body plus the requirements log and existing audit reports
(the read/build-gate in "go=go" above), never the head alone. A stale-looking head is not a
build decision - the whole body and the log are.

## 3_verified/ is human-authorized

An agent NEVER moves an item into `3_verified/` on its own initiative. `3_verified/` is
human-in-the-loop confirmation: the human is the sole authority for it. The agent's job is
to actively ask the user to re-test items sitting in `2_done/`, handing over a numbered
step-by-step test list (credo `verify` skill, "Handing a manual test to the user").

When the user explicitly instructs the move ("schieb #X nach verified", "item X =
verified", or similar), the MAIN agent - the one in direct user contact - executes it; it
does NOT refuse and does NOT tell the user to `mv` the file themselves. It runs:

```
"${CLAUDE_PLUGIN_ROOT}/scripts/credo-item-move.sh" <id> verified --user-authorized
```

The `--user-authorized` opt-in (or the env `CREDO_VERIFIED_USER_AUTHORIZED=1`) is what the
move helper requires for this target; without it the helper refuses. This does not weaken
the rule: the agent still never decides to verify on its own - it only mechanically carries
out an explicit user instruction. Subagents NEVER perform this move; they report back and
the main agent does it.

A `PreToolUse` hook (`credo-item-move-guard.sh`) additionally blocks a raw `mv` / `git mv`
of any item file in the status tree, so status changes go through the helper (which enforces
this opt-in for `3_verified/`).

## Bug found during verify -> back to 1_todo/1_clarify

If verification (or audit) surfaces a bug in work that was claimed done, the item goes
back to **`1_todo/1_clarify`** - not to `2_go` - with a `History` note describing what was
missed. It needs clarification before it is buildable again. **Agents never self-degrade
`2_done/`**: an agent does not silently move a done item down; it records the finding and
moves it back to clarify per this rule (or, for a clear and approved fix, the audit skill
governs whether it returns to `2_go`).

Fix rounds after a failing audit follow the credo `audit` skill: a FRESH fix agent gets
only the findings, the branch state and the test commands (never the builder's resumed
context), and after 2 FAIL audits of the same item there is no third fix round by default -
the item is stopped and re-cut smaller or sent back to `1_clarify` ("Emergency brake").

This is the DONE-work case. A different case is a critical open user-only decision that
surfaces while building a `2_go` item (not yet done): that is governed by the
Named-Decision-Test above, which sends the item `2_go -> 1_clarify` (URGENT), not by this
done-work rule.

## GO-but-blocked (1_todo/3_blocked)

`3_blocked` holds an item that is fully clarified and GO'd (by the user, or for an
agent-owned item by the agent decision rule), but which is
hard-blocked by ANOTHER, still-unbuilt credo item. It is NOT a demotion of the GO - the GO
stands; the block only pauses it. When every blocking item is delivered, the item
auto-returns to its origin folder (its `unblock_to` target, `go` or `clarify`).

Distinct from `parked/hold`, which is for an EXTERNAL dependency (not another credo item) or
a block on something not yet GO'd. `3_blocked` is specifically an internal-item block on an
already-GO'd item, and that internal relation is what enables the automatic return.

### Blocker relations (structured, not a second status)

- `blocked_by: [ids]` on the blocked item, and `blocks: [ids]` on the blocking item.
- Bidirectional dependency graph, relational only - NOT a second status source. The folder
  still says "blocked"; the relations only say by which item(s). Keep both sides in sync.
- Required whenever an item sits in `3_blocked`.
- `unblock_to: go|clarify` records the RETURN target for the auto-unblock sweep - the folder
  the item came from before it was blocked. `credo-item-move.sh <id> blocked` writes it
  automatically (source `1_clarify` -> `clarify`, `2_go` -> `go`, anything else -> `go`);
  override with `--unblock-to clarify|go`. It is set only while the item sits in `3_blocked`
  and is NOT a status source (the folder still owns status). A legacy blocked item WITHOUT
  `unblock_to` defaults to `go` on unblock (the old contract).

### Block-guard (a block needs a concrete blocker)

An item may move to `3_blocked` ONLY with a concrete `blocked_by` referencing an unfinished
item. "Too big / too hard / uncertain" is NOT a block: such an item stays in `2_go` and gets
built (see "go=go" above). This stops an agent from parking buildable work as "blocked" to
avoid building it - the exact RETRO regression this guards against.

### Auto-unblock (deterministic, no new GO needed)

Auto-unblock is ENFORCED by `credo-unblock-sweep.sh`, not left to an agent to remember. The
sweep runs at two moments, so a delivered blocker never leaves a dependent stranded:

- **On every successful move into `2_done` or `3_verified`** - `credo-item-move.sh` invokes
  the sweep (defensively; a sweep error never fails the move), so dependents return the
  instant their last blocker is delivered.
- **At every SessionStart** (startup, resume, clear, compact, fork) via a hook, which
  reconciles any backlog that built up while no move happened.

What the sweep does, for each item in `3_blocked`:

1. It reads the item's OWN `blocked_by` ids - the FORWARD edge - and looks up each blocker's
   status (the folder it lives in). It deliberately does NOT walk the `blocks:` back-pointers,
   which drift; the forward `blocked_by` edge is authoritative.
2. If EVERY blocker is in `2_done` OR `3_verified`, the block is over: it moves the item to
   its `unblock_to` target (`go` or `clarify`; a legacy item without the field -> `go`) and
   appends a History line `-> <target> <date> (auto-unblock: #<ids> done)`. **`4_archived`
   does NOT count as delivered** - an archived blocker means the dependency was abandoned, so
   the item stays blocked and is surfaced (below).

This is NOT a new GO - the original GO (the user's, or for an agent-owned item the logged
agent decision) still stands; the block merely paused it. The move helper still applies its
owner gate on this return, so a human-owned item that never had a user GO stays blocked
instead of slipping into `2_go`. The sweep is idempotent
(an unblocked item leaves `3_blocked`, so a re-run does not touch it) and never deletes
anything (it moves via `credo-item-move.sh`).

### Surfacing stranded blocked items (a nudge, no move)

For items that REMAIN in `3_blocked` after the auto-unblock pass, the sweep emits a short
nudge (at SessionStart, as `additionalContext`) when a blocker is not heading toward done:

- blocker in `1_clarify` - waiting on an undecided question;
- blocker in `4_archived` - stranded: the dependency was abandoned;
- transitive dead-end - the blocker is itself still `3_blocked`.

This is surfacing ONLY - the sweep never moves these; it just makes the dead-end visible so
the user or agent resolves the blocker (or re-decides). A blocker still in `2_go`/`parked` is
normal in-progress work and is NOT surfaced.

### Decision-hub items unblock their dependents by reaching done

A decision / clarify-hub item whose deliverable is a DECISION, not code (for example "decide
A vs B" that several other items are `blocked_by`), is **done once its decisions are captured
AND propagated into the dependent items** - then it may move to `2_done`, so it stops blocking
its dependents permanently. This is a convention, not a mechanism: there is no auto-move to
`2_done` for such an item; a human/agent moves it through the normal DoD gate once the
decision is recorded and the dependents updated. (Because `4_archived` does not count as
delivered, closing such a hub by archiving it would leave its dependents stranded - resolve
it to `2_done` instead.)

## Moving items (lifecycle)

Prefer the move helper - it is atomic, never deletes, and gates the human-authorized
`verified` target behind an explicit opt-in:

```
"${CLAUDE_PLUGIN_ROOT}/scripts/credo-item-move.sh" <id> <target>
# target: clarify | go | blocked | done | verified | archived | hold | future
# verified needs the --user-authorized opt-in and only on explicit user instruction:
#   credo-item-move.sh <id> verified --user-authorized
# go for a human-owned item needs a "(GO: <user quote>)" History line, or the main agent's
#   --user-authorized on the user's explicit GO (see "Clarify owner and the agent decision rule")
```

A raw `mv` / `git mv` of an item file inside the status tree is blocked by the
`credo-item-move-guard.sh` PreToolUse hook - always use the helper.

### Worktree cleanup at item close

Every item close - a move to `done`, `verified` or `archived` via `credo-item-move.sh` -
also cleans up finished parallel-track worktrees, automatically, without any prior command.
The helper reads the DOGMA-PERMISSIONS checkbox in the `### Hydra` subsection (via
`credo-dogma-mode.sh`, works without dogma):

```
- [x] clean up merged worktrees automatically
```

- `[x]` - remove now, without asking (the user authorized it with the setting). The move
  output lists `worktree cleanup: removed ...` and every kept worktree with its reason.
- `[?]` or no checkbox (older files predate the setting) - the move output lists the
  `candidate` worktrees and says to ask the user; on a yes run
  `"${CLAUDE_PLUGIN_ROOT}/scripts/credo-worktree-cleanup.sh"` (in autonomous mode leave
  them for the user and mention them in the run report).
- `[ ]` - never.

`credo-worktree-cleanup.sh [--dry-run] [--json]` removes ONLY worktrees whose branch is
fully merged into the main branch (the branch checked out in the main worktree) AND that have
no changes to tracked files; untracked scratch (cache/, the setup symlinks) goes with them.
It never touches the main worktree, the worktree it runs in, locked ones, unmerged or dirty
ones (those are reported as `kept` with the reason), and keeps a never-committed worktree
while it is younger than 24h or has untracked files (an agent may be starting in it). It
removes via `git worktree remove --force` (git unlinks symlinks and never follows them) and
deletes the merged branch with `git branch -d`. Every run covers all worktrees of the
repository, so the first run also sweeps the backlog. A cleanup error never fails the move.

Valid transitions (folder = status):

- `1_clarify -> 2_go` once the user gives an explicit GO (go-gate: only `2_go` is
  buildable; `1_clarify` is not). For an agent-owned item (`clarify_owner: agent`) the agent
  decision rule may give the GO instead (`(GO: agent per SOTA rule, <reason>)`, see "Clarify
  owner and the agent decision rule"); a human-owned item always needs the user's GO, and
  the move helper refuses it otherwise. In a presence session, clarify and propose that GO one
  item at a time, each item in its own Ask round - see "One item per Ask round" in the
  common core (session-active skill). Before proposing that GO, discharge the over-clarify
  standard and its pre-GO self-check unless `clarify_depth: waived` (credo `session-active`
  skill, CLARIFY-FIRST). At the latest at GO, set the optional `touches:` (and `heavy: true`
  where it applies) when the likely edited files are foreseeable - see the optional fields
  above.
- `2_go -> 3_blocked` when a concrete blocker on another unbuilt item is found (block-guard
  above; requires `blocked_by`). NOT for "too big / too hard".
- `2_go -> 1_clarify` when a genuine user-only decision surfaces (the Named-Decision-Test
  passes), typically mid-build. Agent-permitted - the one carve-out from "never self-demote";
  NOT for "too big / too hard". Mark the returned item URGENT (see above) and record why;
  the move helper sets `clarify_owner: human` (the open decision is the user's) and logs it.
- `3_blocked -> <unblock_to>` (`go` or `clarify`; legacy item without the field -> `go`) on
  auto-unblock when EVERY blocker is in `2_done`/`3_verified` (not a new GO), enforced
  deterministically by `credo-unblock-sweep.sh` on done/verified moves and at SessionStart.
  `4_archived` does NOT count as delivered.
- `2_go -> 2_done` only after the full Definition of Done gate above passes (pending
  human-only tests do not hold it in `2_go`).
- `2_done -> 1_clarify` when a bug is found (see above). The move helper sets
  `clarify_owner: human` on entry into `1_clarify`; for a bug found by an audit or an agent
  that the agent decision rule may settle, pass `--keep-owner` to keep `agent`.
- any -> `parked/hold` (external block) or `parked/future` (deferred), or `4_archived`
  (abandoned/rejected); `3_blocked -> parked/*` or `4_archived` as usual.
- `2_done -> 3_verified` is **human-authorized**: an agent never does it on its own
  initiative. Only the MAIN agent, and only on the user's explicit instruction, runs
  `credo-item-move.sh <id> verified --user-authorized`; subagents never (they report back,
  the main agent moves it). The human stays the sole authority - the agent only mechanically
  executes an explicit instruction.

After any move, update the item's `History` section with the transition and its date.
Whenever you move something by hand instead of the helper, use `mv` (never delete + write)
so the id-counter invariant and the file's identity are preserved.

## dogma-first

Where dogma already governs a concern (versioning, git rules, language, linting), follow
dogma first and treat these credo rules as fallback only, never as a duplicate or a
conflict. DOGMA-PERMISSIONS always take precedence.
