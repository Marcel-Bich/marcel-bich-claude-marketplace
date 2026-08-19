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

> **Task backend.** If the task backend is `gsd` (set in `.credo/config` as `task_backend`, or via the `CREDO_TASK_BACKEND` env override; resolve with `credo-config.sh backend`), the credo item system is inactive - GSD's
> phases are the task system for this project. Do NOT create or move `.credo/items/`; use
> GSD's workflow instead. This skill applies only when the backend is `credo` (the default)
> or `none`.

## Status = folder (the only truth)

The folder tree (created by `credo-init`) and what each folder means:

```
.credo/items/
  1_todo/
    1_clarify/     open questions - needs the user, NOT buildable yet
    2_go/          clarified and approved - buildable (go-gate: only 2_go is buildable)
    3_blocked/     GO'd but hard-blocked by another (unbuilt) credo item; auto-returns to 2_go on unblock
  2_done/          Definition of Done met (agent and/or user), gate passed
  3_verified/      human-authorized - human-in-the-loop confirmation (main agent moves here only on explicit user instruction)
  4_archived/      abandoned / deprecated / rejected
  parked/
    hold/          blocked by an EXTERNAL dependency (not another credo item)
    future/        deliberately deferred
```

Never encode status anywhere else. If you want to know an item's status, look at which
folder its file is in - nothing else is authoritative.

## go=go - the folder is authoritative for building

An item in `2_go` IS buildable, by definition of the folder. This is the build-side
counterpart to the entry gate that governs what may enter `2_go` in the first place (the
credo `migrate` skill owns the G1-G6 entry gate).

- **The folder overrides body-level doubt.** An unproven root-cause hypothesis, a
  "GO unclear" note, or any hedge in the body does NOT override the folder. If the file is
  in `2_go`, build it (best effort).
- **Never self-skip, never self-demote.** The building agent does NOT skip a `2_go` item and
  does NOT move it down for reasons of size, UI, or "not sure it is verifiable". It MAY
  re-scope or phase a large item into slices, but it must build. The ONE carve-out is a
  genuine user-only decision that passes the Named-Decision-Test (below) - that is not a
  size/difficulty demotion and is the only sanctioned `2_go -> 1_clarify` path.
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

Everything else (`priority`, `source`, `relates_to`, `regression`, ...) is
**not** a mandatory field. Do not add speculative frontmatter. Write such information only
when it actually applies, free-form in the body.

The one exception is the blocker relation `blocked_by: [ids]` / `blocks: [ids]`: these are
structured (not free-form) and are REQUIRED while an item sits in `1_todo/3_blocked` (see
"GO-but-blocked" below). Outside that state they are omitted. They form a relational
dependency graph, NOT a second status source, so principle "folder = status" stays intact
and the lean-frontmatter philosophy is not broken.

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
3. **Implemented** - what was actually built, with concrete `file:line` references. This
   is where the wiring is recorded (which caller reaches the new code).
4. **Verify** - the honest 4-valued verification state, per layer. See below.
5. **History (MANDATORY)** - the folder journey with dates. Every move writes a line
   `-> <target> <date> (<reason>)`, e.g.
   `created (clarify) 2026-07-04 -> go 2026-07-04 (GO: Marcel, chat) -> done 2026-07-05`.
   Record why an item moved, especially any move backwards. **Folder<->History invariant:**
   the folder an item is in MUST match the target of its last History line. A mismatch is a
   detected mis-move - flag it and correct it. This is the contradiction detector, achieved
   without adding a second status source.

## Item text is perspective-neutral (no "who is doing it")

An item file is durable and read by whoever builds it later - often a different agent or
session than the one that wrote it. Its text therefore describes the WORK and its
DEPENDENCIES, never who is currently handling it. Perspective-relative wording like
"another agent", "hands-off (other agent)", or "I do X, the other agent does Y" breaks
this: a later builder reads "another agent" as someone other than themselves and misreads
the item. Keep who-does-what coordination OUT of the item - it belongs only in the session
task list (the ephemeral coordination layer), not in the durable item. State dependencies
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
explaining what the user must check and why an agent cannot.

A verify attempt that surfaces a defect is a **failed** verify: that is not one of the
four progress states above, it is a defect outcome that sends the item back (see "Bug
found during verify"). Only `exercised` (or a user-confirmed human-only criterion) counts
toward the Definition of Done.

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
- Narrowly scoped exception to clarify-first: an agent MAY autonomously create and GO
  EXACTLY this one wiring-item type and build it best-effort. This carve-out is limited to
  the cross-boundary wiring item and nothing else - everything else still follows
  clarify-first (only the user sets GO).

Before you record `failed` or "not started" for a capability, you MUST first run a wiring
check against the real code: search the source for the endpoint, class, function, or
tests that would implement it. This matters most for items cut from older specs - the
feature may already have been built under a DIFFERENT task or item number, so assuming it
is missing is often simply wrong. If the check shows it is built but its runtime behavior
has not been observed, record `wired-but-behavior-unverified`, not `failed`. Reserve
`failed` for a real defect actually surfaced by exercising the code.

## Build-completion gate (record what you built, in the same move)

The moment build code is committed - an item has actually been built, not just planned -
the building agent MUST, in the SAME turn, bring the item file into line with that reality:

1. Fill `## Implemented` with concrete `file:line` evidence for what was built (which
   caller reaches the new code).
2. Update the DoD / Success-Criteria ticks to match what is now true.
3. Move `## Verify` off `not-started` for the built layer(s) - at minimum to `present`, or
   `wired-but-behavior-unverified` when the code is reachable and called. (`not-started`
   means "work has not begun"; a build commit proves it has.)

This is a mandatory step of the build routine, not a new script. An item with a build
commit that still says "not started" (or "noch nicht begonnen") is a CONTRADICTION between
the committed code and the item text - flag it and resolve it, exactly as with the
Folder<->History invariant. Leaving the item stale after committing build code is a
detected mis-state, never an acceptable end.

## Definition of Done (the gate into 2_done/)

An item may move into `2_done/` ONLY when ALL of these hold. This gate is hard.

1. **Every Success Criterion is `exercised`** (or, for a human-only criterion, explicitly
   confirmed by the user). Nothing left at `not-started`, `present`, or
   `wired-but-behavior-unverified`.
2. **If `ui: true`, a passing visual verify is mandatory** - the credo `verify` skill at
   every configured viewport (measured layout, real interaction, live update where
   required, hard reload after rebuild), with screenshots saved under
   `.credo/screenshots/`. Verify screenshots ALWAYS live under `.credo/screenshots/` and
   follow the name pattern `<slug>-<viewport>-<YYYY-MM-DD>.png` - this holds even when an
   ad-hoc verifier (not the formal `verify` skill) produces them, so every screenshot is
   found in one place under one convention. The required level of test obligation is
   defined by the credo `verify` skill (config `verify.primary_test`), not here.
3. **No open remainder** - nothing needed for the item's core is still outstanding.
4. **Mandatory audit-after-completed by a DEDICATED subagent** - the credo `audit` skill
   MUST be run by a subagent that is NOT the builder of this item. A builder auditing
   their own work does not satisfy the gate. This applies in every session mode (active,
   passive, autonomous), no exceptions. Only a passing audit lets the item enter
   `2_done/`.
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

This is the DONE-work case. A different case is a critical open user-only decision that
surfaces while building a `2_go` item (not yet done): that is governed by the
Named-Decision-Test above, which sends the item `2_go -> 1_clarify` (URGENT), not by this
done-work rule.

## GO-but-blocked (1_todo/3_blocked)

`3_blocked` holds an item that is fully clarified and the user has GO'd, but which is
hard-blocked by ANOTHER, still-unbuilt credo item. It is NOT a demotion of the GO - the GO
stands; the block only pauses it. When the blocking item is done, the item auto-returns to
`2_go`.

Distinct from `parked/hold`, which is for an EXTERNAL dependency (not another credo item) or
a block on something not yet GO'd. `3_blocked` is specifically an internal-item block on an
already-GO'd item, and that internal relation is what enables the automatic return.

### Blocker relations (structured, not a second status)

- `blocked_by: [ids]` on the blocked item, and `blocks: [ids]` on the blocking item.
- Bidirectional dependency graph, relational only - NOT a second status source. The folder
  still says "blocked"; the relations only say by which item(s). Keep both sides in sync.
- Required whenever an item sits in `3_blocked`.

### Block-guard (a block needs a concrete blocker)

An item may move to `3_blocked` ONLY with a concrete `blocked_by` referencing an unfinished
item. "Too big / too hard / uncertain" is NOT a block: such an item stays in `2_go` and gets
built (see "go=go" above). This stops an agent from parking buildable work as "blocked" to
avoid building it - the exact RETRO regression this guards against.

### Auto-unblock (no new GO needed)

When an item B reaches `2_done`, read `B.blocks`. For each referenced item A in `3_blocked`
whose `blocked_by` set is now fully done, move A `3_blocked -> 2_go` and write the History
line. This is NOT a new GO - the GO was the user's originally and still stands; the block
merely paused it, so the automatic return respects "only the user sets GO".

## Moving items (lifecycle)

Prefer the move helper - it is atomic, never deletes, and gates the human-authorized
`verified` target behind an explicit opt-in:

```
"${CLAUDE_PLUGIN_ROOT}/scripts/credo-item-move.sh" <id> <target>
# target: clarify | go | blocked | done | verified | archived | hold | future
# verified needs the --user-authorized opt-in and only on explicit user instruction:
#   credo-item-move.sh <id> verified --user-authorized
```

A raw `mv` / `git mv` of an item file inside the status tree is blocked by the
`credo-item-move-guard.sh` PreToolUse hook - always use the helper.

Valid transitions (folder = status):

- `1_clarify -> 2_go` once the user gives an explicit GO (go-gate: only `2_go` is
  buildable; `1_clarify` is not). In a presence session, clarify and propose that GO one
  item at a time, each item in its own Ask round - see "One item per Ask round" in the
  common core (session-active skill).
- `2_go -> 3_blocked` when a concrete blocker on another unbuilt item is found (block-guard
  above; requires `blocked_by`). NOT for "too big / too hard".
- `2_go -> 1_clarify` when a genuine user-only decision surfaces (the Named-Decision-Test
  passes), typically mid-build. Agent-permitted - the one carve-out from "never self-demote";
  NOT for "too big / too hard". Mark the returned item URGENT (see above) and record why.
- `3_blocked -> 2_go` on auto-unblock when the blocking item(s) are done (not a new GO).
- `2_go -> 2_done` only after the full Definition of Done gate above passes.
- `2_done -> 1_clarify` when a bug is found (see above).
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
