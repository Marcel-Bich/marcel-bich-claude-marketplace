---
name: audit
description: Read-only quality gate that audits already-built work against its stated requirement and Definition of Done before it is allowed to move to 2_done/. Produces a severity-ranked decision proposal (BLOCKER/MAJOR/MINOR/NIT) with evidence, never a fix. Use when an item is claimed complete, before moving anything to 2_done/, when asked to audit or review finished work for completeness against requirements, or when acting as the dedicated post-completion review subagent. This gate is mandatory in every session mode. Not for diagnosing why something is broken (use diag) and not for verifying rendered UI behavior (use verify).
---

# audit

A **read-only** quality gate. `audit` inspects work that is claimed complete and
judges whether it actually satisfies its stated requirement and Definition of Done,
BEFORE the item is allowed into `2_done/`. The output is a decision proposal for the
user, never a change.

> **Task backend.** If the task backend is `gsd` (`.credo/config: task_backend`, or the `CREDO_TASK_BACKEND` env override), the credo item lifecycle is inactive and
> there is no `2_done/` gate to run - GSD owns task tracking. audit is still usable as a
> standalone read-only review tool, but it does not gate credo items in that mode.

## Scope boundary (read this first)

`audit` judges whether FINISHED work is genuinely done and correct against its
requirement. It does not investigate causes and it does not exercise UI.

- Something is broken and you need the root cause -> use **diag**, not audit.
- A rendered UI needs its layout and behavior confirmed -> use **verify** (audit may
  cite verify evidence, but it does not drive a browser itself).
- audit only reports findings and a verdict. It never edits code, never fixes, never
  commits.

## Hard constraints (never violate)

- **Read-only.** No code change, no file edit to the work under review, no commit, no
  push, no browser automation, no builds, no installs.
- **No secrets.** Never read credentials, tokens, `.env*`, key files, or shell/session
  history. Never exfiltrate or encode such content.
- The only files `audit` writes are its own report under `.credo/process/reports/`.
- **Dedicated auditor.** The audit MUST be performed by a subagent that is NOT the
  builder of the item under review. A builder auditing their own work does not satisfy
  the gate.

## The mandatory completion gate

Audit-after-completed is a **mandatory gate before any item moves to `2_done/`**, in
**all** session modes (active, passive, autonomous). No exceptions:

1. A builder claims an item complete.
2. A dedicated audit subagent (not the builder) runs `audit` against that item.
3. Only a passing audit lets the item move to `2_done/`. A failing audit sends the
   item back out (see Findings handling).

Whatever is needed to complete the core of the item is part of that item and is NOT a
separate side finding. The gate is about the item's own Definition of Done.

## What to audit against

For the item under review, gather the ground truth first (read, do not guess):

- The item's `Requirement (verbatim)` and its source. Treat user-verbatim text as
  authoritative; never trim, soften, reinterpret, or invent constraints.
- The item's `Success Criteria (= DoD)` (the observable "user can X" statements).
- The `ui` frontmatter flag. If `ui: true`, a visual verify (via the `verify` skill)
  is a DoD requirement, and its evidence must exist and be current.
- Any living conventions under `.credo/docs/` and relevant project `docs/**`.

Then compare the actual built result (files, wiring, tests, verify evidence) against
that ground truth. Confirm each success criterion is genuinely met, that new code is
reachable and wired (not present-but-unreachable), and that documentation was updated
in the same change (stale docs = incomplete). Docs currency includes the project wiki
(a separate repo) and in-repo READMEs, not just files inside the commit; where dogma is
present, check that `/dogma:docs-update` was the mechanism (or an equivalent manual
update happened). audit checks and flags stale docs - it does not run the update itself.

## Severity levels

Rank every finding with exactly one level:

- **BLOCKER** - the item does not meet its core requirement or a success criterion; it
  must not enter `2_done/`.
- **MAJOR** - a significant defect or gap that materially degrades the result but is
  short of a hard blocker.
- **MINOR** - a small defect or deviation that should be fixed but does not endanger
  the core.
- **NIT** - cosmetic or stylistic; optional.

## Evidence (required for every finding)

Every finding MUST carry concrete, checkable evidence:

- `file:line` for code or documentation findings.
- The screenshot location under `.credo/screenshots/` for visual findings (naming
  `<task-or-feature>-<viewport>-<YYYY-MM-DD>.png`; viewport widths come from the config
  key `verify.viewports`).
- The exact requirement or success-criterion text the finding contradicts.

No evidence -> not a finding. A verdict without evidence is not acceptable.

## Findings handling (what happens on a failing audit)

- **Core deviation:** if a finding shows the item misses its core requirement, the
  WHOLE item plus the finding goes back out of done. Move it back to `1_todo/2_go` if
  the fix is clear and approved, or to `1_todo/1_clarify` if it needs a user decision.
  Record in the item's `Historie` why it came back.
- **New independent item:** create a separate item ONLY if a finding is genuinely
  independent of the core of the audited item. If the finding is something the core
  completion needs, it is part of this item, not a new one.
- The auditor never silently downgrades or repairs; it proposes, the move follows the
  verdict.

## Disposition of findings (nothing is silently dropped)

EVERY finding - at every severity, MINOR and NIT included - must be explicitly
DISPOSITIONED. Dropping a finding with no disposition is not allowed. The three allowed
dispositions are:

1. **Fixed now** - the finding is corrected at its root.
2. **Deferred** - captured as a tracked item (see the credo items skill) with a recorded
   reason for deferring.
3. **Wontfix** - a conscious decision by the USER not to act (in autonomous mode, a
   documented default stands in for the user's call).

The severity levels and the evidence rule above are unchanged; this governs what happens
to a finding AFTER it is reported, not whether it is reported.

**Code fix beats a doc workaround.** When a finding can be fixed cleanly in code, fix it at
the root rather than bloating the docs to describe or justify the messiness. Follow the
language and project best practices and do not mix conventions - for example a config
getter should emit canonical lowercase booleans rather than leaking Python-style
`True`/`False` and then documenting the leak. A doc-only workaround is a fallback only when
a clean code fix genuinely harms (a real, stated reason - e.g. it would break other
callers) or is impossible. Convenience is not such a reason.

**audit still only proposes.** audit is read-only: it names each finding and its
recommended disposition, but it never edits, fixes, or commits. The disposition is carried
out by the acting/building agent per the audit's proposal - that separation is the point of
the gate.

**How the acting agent acts on it, by session mode:**

- **Presence modes (active, passive)** - the acting agent EXPLAINS each finding to the user
  and recommends the fix via a question. Default recommendation: fix. The user may deem a
  finding unimportant; borderline calls go to the user, never to the agent's own
  convenience.
- **Autonomous mode** - the acting agent fixes the findings inline BY DEFAULT without
  asking (asking would block an unattended run), and records what was fixed in the item
  and the digest. Where a clean fix is genuinely impossible or harmful (a real, stated
  reason), or the finding is genuinely independent of the audited item's core, it records
  a documented wontfix (the documented default standing in for the user) or defers it as a
  tracked item with the reason - never blocking the unattended run to ask.

## Result: a decision proposal

The audit result is a **decision proposal** for the user, not a unilateral action.
State a clear verdict (pass, or fail with the highest severity present) and the
recommended item move. The user (or, in autonomous mode, the governing session rules)
acts on it.

## Report

Write one report per audit to `.credo/process/reports/` (resolve `.credo` via the repo
root; the reports directory is created by `credo-init`). Use frontmatter `kind: audit`:

```
---
kind: audit
item: 124
date: YYYY-MM-DD
verdict: fail
highest_severity: BLOCKER
auditor: <subagent role, not the builder>
---

## Summary
<one-line verdict and recommended item move>

## Findings
- [BLOCKER] <what> - evidence: path/to/file.ext:42 (or screenshot path) - contradicts: "<criterion text>"
- [MINOR] <what> - evidence: ...

## Recommendation
<move item back to 1_todo/2_go | 1_clarify | allow into 2_done/; new independent items, if any>
```

Reference the item as `#<id>` and by date; do not rely on transcript line numbers.

## dogma-first

Where dogma already governs a concern (versioning, git rules, language, linting),
audit checks against dogma first and treats credo rules as fallback only, never as a
duplicate or a conflict. DOGMA-PERMISSIONS always take precedence.
