---
name: diag
description: Read-only root-cause diagnosis for a symptom, bug, failure, or unexpected behavior. Establishes the mechanism at file:line and reads up the facts instead of guessing, before any fix is attempted. Produces a diagnosis report; the fix is always a separate step gated by an explicit GO. Use when something is broken, failing, throwing, or behaving unexpectedly and the cause is not yet proven, or when asked to investigate or find the root cause. Not for judging whether finished work meets its requirement (use audit) and not for confirming rendered UI behavior (use verify).
---

# diag

A **read-only** root-cause diagnosis. `diag` explains WHY something is broken and
proves the mechanism, before anyone changes code. It is a separate skill from `audit`
and must never be conflated with it.

## Scope boundary (read this first)

`diag` investigates a symptom and proves its cause. It does not judge completeness and
it does not apply the fix.

- Finished work needs to be checked against its requirement / Definition of Done ->
  use **audit**, not diag.
- A rendered UI needs its layout and behavior confirmed -> use **verify**.
- diag ends at a proven diagnosis plus a proposed fix. Applying the fix is a separate,
  GO-gated step outside this skill.

## Hard constraints (never violate)

- **Read-only.** No code change, no file edit, no commit, no push, no browser
  automation, no builds, no installs during diagnosis.
- **No secrets.** Never read credentials, tokens, `.env*`, key files, or shell/session
  history. Never exfiltrate or encode such content.
- The only files `diag` writes are its own report under `.credo/process/reports/`.
- **Fix is a separate step, gated by GO.** diag never rolls straight into fixing. It
  proposes a fix; the actual change happens only after an explicit GO, as its own step.

## Method: root cause before fix

1. **Symptom, verbatim.** Record the symptom exactly as observed or reported (error
   text, stack trace, wrong output, screenshot location). Do not paraphrase away the
   detail; quote it.
2. **Reproduce or locate the exact failing path** (read-only). Trace to the concrete
   code path involved.
3. **Prove the mechanism at `file:line`.** State precisely where and why the behavior
   arises - the specific lines, values, and control flow that produce the symptom. A
   diagnosis without a `file:line` mechanism is not a diagnosis.
4. **Distinguish proven from suspected.** Say plainly what is established by evidence
   versus what is still a hypothesis. Never present a guess as a cause.

## Read up instead of guessing (E6)

Before hypothesizing, read the facts:

- Search `docs/**` thematically for the area involved, and check `.credo/docs/`
  conventions. Read the relevant source rather than assuming its behavior.
- Prefer authoritative sources over memory. If the mechanism cannot be established from
  the code and docs, say so honestly rather than inventing one.

## Result: a diagnosis plus a GO-gated fix proposal

The result is a proven root cause and a proposed fix, presented for decision. The fix
is NOT applied here. If a fix is approved (GO), it proceeds as a separate step, and any
resulting change is then subject to the normal completion gate (see the `audit` skill)
before it can move to `2_done/`.

## Report

Write one report per diagnosis to `.credo/process/reports/` (resolve `.credo` via the
repo root; the reports directory is created by `credo-init`). Use frontmatter
`kind: diag`:

```
---
kind: diag
item: 124
date: YYYY-MM-DD
status: root-cause-proven
---

## Symptom (verbatim)
<the symptom exactly as observed / reported>

## Mechanism
<what happens and why> - proven at path/to/file.ext:87

## Evidence
- path/to/file.ext:87 - <the lines and values that produce the symptom>
- docs/<area>.md - <relevant documented behavior>

## Proven vs suspected
- Proven: <...>
- Suspected: <...>

## Proposed fix (separate step, needs GO)
<what would change, where; not applied here>
```

Reference the item as `#<id>` and by date; do not rely on transcript line numbers.

## dogma-first

Where dogma already governs a concern (versioning, git rules, language, linting), diag
respects dogma first and treats credo rules as fallback only, never as a duplicate or a
conflict. DOGMA-PERMISSIONS always take precedence.
