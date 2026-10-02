---
name: audit
description: Read-only quality gate that audits already-built work against its stated requirement and Definition of Done before it is allowed to move to 2_done/. Produces a severity-ranked decision proposal (BLOCKER/MAJOR/MINOR/NIT) with evidence; the judgement never edits, only a recorded post-audit step may fix small findings. Use when an item is claimed complete, before moving anything to 2_done/, when asked to audit or review finished work for completeness against requirements, or when acting as the dedicated post-completion review subagent. This gate is mandatory in every session mode. Not for diagnosing why something is broken (use diag) and not for verifying rendered UI behavior (use verify).
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
- The audit judgement only reports findings and a verdict; it never edits code while
  judging. The one sanctioned edit is the separate, recorded post-audit step "Fixing small
  findings" below.

## Hard constraints (never violate)

- **Read-only judgement.** While auditing: no code change, no file edit to the work under
  review, no commit, no push, no browser automation, no builds, no installs. Only after
  the findings are recorded may the auditor fix small ones ("Fixing small findings").
- **No secrets.** Never read credentials, tokens, `.env*`, key files, or shell/session
  history. Never exfiltrate or encode such content.
- The only files `audit` writes are its own report under `.credo/process/reports/` (plus,
  in the fix step, the small fixes on the item's worktree branch).
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

## Audit depth (risk tiers)

The gate above is mandatory for every item and is always run by a dedicated subagent that
is not the builder. The tier only decides HOW DEEP the audit goes, never WHETHER it runs.
Depth follows risk: there are two tiers, `full` and `lean`.

**full** - every check in this skill, with current verify evidence required. An item is
`full` when ANY of these holds:

- frontmatter `ui: true` (current browser evidence from the `verify` skill is required; the
  audit cites it, it does not drive a browser itself);
- security-relevant: permissions or rights, hooks that allow or block, secrets handling,
  deletion, installs;
- writes outside the repo (a foreign project, user files) or runs commands;
- touches shared core files (central registries, modules other items build on);
- data migration;
- large scope (guide value: more than ~10 files touched, or a new component);
- frontmatter `audit: full` (the only override, see the `items` skill);
- when in doubt -> `full`.

`full` is the default. **lean** - only small, low-risk items that meet none of the above.
It reviews the diff and runs the tests, at about half the cost of `full`. Tentative: 6
trials so far; the rule stays tentative until 10+. Checks:

- the diff against each DoD point (every success criterion met by the change), plus the
  relevant tests;
- wiring / reachability of new code (not present-but-unreachable);
- docs current for the change (README / wiki / `docs/**` the change affects);
- stale head / body claims, inside the item itself only.

A lean audit still produces severity-ranked findings with evidence, a verdict, and a report.

**Who picks the tier.** The main agent picks the tier when it spawns the audit subagent and
names it in the brief. The audit report states the tier plus a one-line reason in its
Summary (e.g. "lean: 3 files, no UI, no security area"). An auditor that finds a `full`
criterion on a lean-briefed item escalates to `full` and says so in the report. There is NO
`audit: lean` override - a risky item can never be downgraded.

**Tests.** The builder and the audit run the repo's `relevant` stage command when dogma
defines one: resolve the newest installed dogma with
`ls -d "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"/plugins/cache/*/dogma/*/ | sort -V | tail -1`
and run `<that dir>/scripts/test-commands.sh get relevant` (exit 4 / empty output = not
defined). When dogma is absent or defines no `relevant` command, choose the relevant tests
as before. An audit of a branch touching shared core files runs the whole core test
folder. The full suite runs where dogma says (stage `all`, Final Verification, or once
per release bundle when DOGMA-PERMISSIONS sets "run ALL tests only at release"), else
once per batch release (credo `orchestration`, "Default batch workflow") - NOT per item,
in neither tier. Running tests is a read-only check and does not break the audit's hard
constraints.

**Batching.** A bundle (2-3 small related items built in one worktree, credo
`orchestration`) gets ONE audit; bundle only `lean`-eligible items. Several finished
`lean` items from the same period may also go to ONE audit subagent. Each item still gets its own verdict and its own report section (one report per
item, or one report with a clearly separated section and verdict per item; the item move
follows each item's own verdict). `full` items are always audited singly, never batched.

## What to audit against

For the item under review, gather the ground truth first (read, do not guess):

- The item's `Requirement (verbatim)` and its source. Treat user-verbatim text as
  authoritative; never trim, soften, reinterpret, or invent constraints.
- The item's `Success Criteria (= DoD)` (the observable "user can X" statements).
- The `ui` frontmatter flag. If `ui: true`, a visual verify (via the `verify` skill)
  is a DoD requirement, and its evidence must exist and be current.
- Pending human-only checks (credo `items`, "Human-only checks do not block done"): a
  check only the human can run is NOT a finding against the move to `2_done` when the item
  records it in `## Verify` as `human-only: pending` with what to check. Flag it only when
  that record is missing, or when the agent could have run the check itself.
- Ticks: a DoD point ticked with a caveat ("done, but ...") is not met - flag it.
- Any living conventions under `.credo/docs/` and relevant project `docs/**`.

Then compare the actual built result (files, wiring, tests, verify evidence) against
that ground truth. Confirm each success criterion is genuinely met, that new code is
reachable and wired (not present-but-unreachable), and that documentation was updated
in the same change (stale docs = incomplete). Docs currency includes the project wiki
(a separate repo) and in-repo READMEs, not just files inside the commit; where dogma is
present, check that `/dogma:docs-update` was the mechanism (or an equivalent manual
update happened). audit checks and flags stale docs - it does not run the update itself.

**Stale head / body check (the freshness backstop).** As part of this comparison, run the
Body-freshness invariant from the credo `items` skill against the item: flag any place
where the item's head or body still claims "open / not built / needs a decision" while the
requirements log, an audit report, the code, or the version shows it was already clarified,
built, or shipped. This is the post-completion backstop that catches what the build-time
Full-body reconciliation sweep and the read/build-gate let through. Severity: a stale claim
of this kind is a **BLOCKER** when it misrepresents whether the core requirement is met
(the item text asserts open/unbuilt for something core that is actually done, or vice
versa), and a **MAJOR** when it materially misleads the next reader without hiding a core
miss. Evidence is the contradicting `file:line` / log / report location plus the stale
claim's own location, per the evidence rule below.

**Completeness against the whole item.** Check that the built work realizes EVERYTHING the
whole item specifies (body + Success Criteria / DoD + the requirements log), not only what a
brief or summary happened to mention. A planned requirement that was silently omitted is a
finding: **BLOCKER** when the omission means the core requirement or a success criterion is
unmet, otherwise **MAJOR**. Evidence is the exact item / DoD text that is left unfulfilled.

**User-facing rule text vs source of truth.** Check user-facing text or logic that encodes a
domain rule (grades, thresholds, formulas, enums, marker semantics) substantively against the
authoritative code source - not merely that something is present. A domain rule presented to
the user incorrectly is a **BLOCKER**; text that is materially misleading without falsifying
the core statement is a **MAJOR**. Evidence is the cited `file:symbol` plus the correct value
versus the shipped text. This differs from the stale head / body check above: that concerns
stale claims inside the item; these two concern the BUILT work against the item and against
the code.

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

**The judgement only proposes.** The audit names each finding and its recommended
disposition before anything is changed. Small findings the auditor then fixes itself ("Fixing
small findings" below); everything else is carried out by the acting/building agent per the audit's
proposal - that separation is the point of the gate.

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

## Fixing small findings (post-audit step)

Default in the batch workflow (credo `orchestration`): after the findings and the verdict
are written down, the same fresh audit subagent (never the builder) fixes SMALL findings
itself - a local, obvious fix with no design decision and no scope change (typically MINOR
or NIT, also a MAJOR whose fix is local and clear). It commits on the item's worktree
branch only (never push or merge), re-runs the relevant tests, and records each one as
"Fixed now" in the report with the commit. The report keeps the original findings; the
verdict states the state after the fixes. Anything larger - a BLOCKER, a redesign, a
user-only decision - is not fixed here; it follows "Findings handling" above.
In presence modes the fixes are listed to the user with the report; a borderline
call is left unfixed for the user.

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
tier: full
verdict: fail
highest_severity: BLOCKER
auditor: <subagent role, not the builder>
---

## Summary
<tier + one-line reason, e.g. "lean: 3 files, no UI, no security area">
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
