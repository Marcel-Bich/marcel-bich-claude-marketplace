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
  2_done/          Definition of Done met (agent and/or user), gate passed
  3_verified/      USER-ONLY - human-in-the-loop confirmation (an agent never places here)
  4_archived/      abandoned / deprecated / rejected
  parked/
    hold/          blocked by an external dependency
    future/        deliberately deferred
```

Never encode status anywhere else. If you want to know an item's status, look at which
folder its file is in - nothing else is authoritative.

## Mandatory frontmatter (lean)

Exactly five required fields. Keep it minimal:

```yaml
---
id: 124                 # integer from credo-id-next.sh, never derived from folder contents
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

Everything else (`priority`, `source`, `blocked_by`, `relates_to`, `regression`, ...) is
**not** a mandatory field. Do not add speculative frontmatter. Write such information only
when it actually applies, free-form in the body.

## Filenames and ids

- File name: `<id>-<slug>.md`, e.g. `124-live-reload-panel.md`. The slug is a short,
  lowercase, ASCII, dash-separated summary of the title.
- Frontmatter `id:` matches the number in the filename.
- Reference an item elsewhere as `#124` (plus its date/short context - transcript line
  numbers are not stable references).
- **Get ids only from the counter, never from folder contents.** Issue the next id with:

  ```
  "${CLAUDE_PLUGIN_ROOT}/scripts/credo-id-next.sh"
  ```

  It is deterministic and never-reuse: a deleted `#124` is never reissued. Do not compute
  an id by scanning existing files or taking `max+1` yourself - that reuses deleted ids.

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
5. **History** - the folder journey with dates, e.g.
   `created (clarify) 2026-07-04 -> go 2026-07-04 -> done 2026-07-05`. Record why an item
   moved, especially any move backwards.

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

Before you record `failed` or "not started" for a capability, you MUST first run a wiring
check against the real code: search the source for the endpoint, class, function, or
tests that would implement it. This matters most for items cut from older specs - the
feature may already have been built under a DIFFERENT task or item number, so assuming it
is missing is often simply wrong. If the check shows it is built but its runtime behavior
has not been observed, record `wired-but-behavior-unverified`, not `failed`. Reserve
`failed` for a real defect actually surfaced by exercising the code.

## Definition of Done (the gate into 2_done/)

An item may move into `2_done/` ONLY when ALL of these hold. This gate is hard.

1. **Every Success Criterion is `exercised`** (or, for a human-only criterion, explicitly
   confirmed by the user). Nothing left at `not-started`, `present`, or
   `wired-but-behavior-unverified`.
2. **If `ui: true`, a passing visual verify is mandatory** - the credo `verify` skill at
   every configured viewport (measured layout, real interaction, live update where
   required, hard reload after rebuild), with screenshots saved under
   `.credo/screenshots/`.
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

## 3_verified/ is USER-ONLY

An agent NEVER moves an item into `3_verified/` autonomously. `3_verified/` is
human-in-the-loop confirmation: only the user places an item there after re-testing it
themselves. The agent's job is to actively ask the user to re-test items sitting in
`2_done/` and, when the user confirms, let the user move them to `3_verified/`.

(Future option, not built here: a `PreToolUse` hook that blocks any agent write or move
into `*/3_verified/*`. For now the rule is enforced by this skill and by the move helper
refusing that target.)

## Bug found during verify -> back to 1_todo/1_clarify

If verification (or audit) surfaces a bug in work that was claimed done, the item goes
back to **`1_todo/1_clarify`** - not to `2_go` - with a `History` note describing what was
missed. It needs clarification before it is buildable again. **Agents never self-degrade
`2_done/`**: an agent does not silently move a done item down; it records the finding and
moves it back to clarify per this rule (or, for a clear and approved fix, the audit skill
governs whether it returns to `2_go`).

## Moving items (lifecycle)

Prefer the move helper - it is atomic, never deletes, and refuses the user-only target:

```
"${CLAUDE_PLUGIN_ROOT}/scripts/credo-item-move.sh" <id> <target>
# target: clarify | go | done | archived | hold | future
```

Valid transitions (folder = status):

- `1_clarify -> 2_go` once the user gives an explicit GO (go-gate: only `2_go` is
  buildable; `1_clarify` is not).
- `2_go -> 2_done` only after the full Definition of Done gate above passes.
- `2_done -> 1_clarify` when a bug is found (see above).
- any -> `parked/hold` (external block) or `parked/future` (deferred), or `4_archived`
  (abandoned/rejected).
- `2_done -> 3_verified` is **user-only** and is never done by an agent or the helper.

After any move, update the item's `History` section with the transition and its date.
Whenever you move something by hand instead of the helper, use `mv` (never delete + write)
so the id-counter invariant and the file's identity are preserved.

## dogma-first

Where dogma already governs a concern (versioning, git rules, language, linting), follow
dogma first and treat these credo rules as fallback only, never as a duplicate or a
conflict. DOGMA-PERMISSIONS always take precedence.
