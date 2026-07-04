---
name: verify
description: >
  Visual verification as the Definition of Done for any change with a runtime surface
  (a rendered page, a UI, a live view). Use whenever you are about to call a UI or
  frontend change done, before moving an item to done, whenever an item is marked
  ui: true, or when someone asks "does it actually render / work". Proves behavior by
  driving the real thing in a browser and measuring computed layout - a passing pytest,
  a served file, a node check, or a subagent code-review is NOT proof. Applies inside
  subagents too: if you built or touched a runtime surface, run this before claiming done.
---

# verify - visual verification as Definition of Done

Visual verification is the credo Definition-of-Done gate for anything with a runtime
surface. If a change renders something, updates something on screen, or reacts to a
user action, it is not done until that behavior has been observed - either by the user
in a real browser, or by a reliable automated Playwright check that drives the real
build. This skill is the DoD gate that `ui: true` items require.

## What does NOT count as verification

None of these are a substitute for visual proof:

- pytest / unit tests / integration tests passing
- `node --check`, a type-check, a lint pass, or a successful build
- "the file is served" / "the server returned 200"
- a subagent code-review or a static read of the source

They can all be green while the surface renders broken, never updates, or ignores the
user. Verification means the rendered surface was exercised and observed.

## Two accepted forms of proof

1. Browser verification by the user - the user opens the real surface and confirms it.
2. A reliable Playwright check - drives the actual build in a real browser, measures
   computed layout, exercises the real interaction, and captures evidence.

Anything else is "wired-but-behavior-unverified", not "exercised".

## Scope of a real verification

- Rendered layout measured via computed layout - read `getBoundingClientRect()` (and
  computed styles where relevant), do not rely on a screenshot alone. A screenshot is
  evidence, not the measurement; a plausible-looking screenshot can still hide a
  zero-height or off-canvas element that the box metrics expose.
- Live update without a full reload where that is required - if the surface is meant to
  update in place (no F5), verify it actually does, by triggering the update and
  observing the change without reloading.
- Real interaction - click, type, submit, hover as a user would; verify the observable
  result, not just that a handler exists.
- Hard reload after a rebuild - after rebuilding, force a hard reload (bypass cache)
  before verifying, so you are testing the new build and not a stale cached bundle.

## Viewports

Verify at each configured viewport width. The universal defaults are 320, 768 and 1440
px, but read them from config as the source of truth - they may be overridden per
project:

```
"${CLAUDE_PLUGIN_ROOT}/scripts/credo-config.sh" get verify.viewports
```

(Config key: `verify.viewports`.) Resize to each width, then measure and capture at
that width.

## Run it in a subagent singleton browser

Run the Playwright verification inside a subagent that owns a single browser instance
(a singleton), rather than spawning browsers in the main agent or opening several in
parallel. One browser, driven step by step, keeps the run deterministic and keeps
browser noise out of the main context. See the credo orchestration skill for how to
delegate and monitor such a subagent without flooding the main context.

## Evidence: screenshots

Capture one screenshot per viewport and save it to `.credo/screenshots/` using this
exact naming rule:

```
<task-or-feature>-<viewport>-<YYYY-MM-DD>.png
```

Example: `login-form-320-2026-07-04.png`. `<task-or-feature>` is a short slug (an item
slug or feature name), `<viewport>` is the width in px, and the date is the day of the
verification. The `.credo/` directory is git-excluded by design, so screenshots are
local evidence, not committed artifacts.

## Definition-of-Done gate

A change with a runtime surface is done only when its observable success criteria are
`exercised` (or confirmed by the user for human-only criteria). For items marked
`ui: true`, a passing visual verification at every configured viewport - measured
layout, real interaction, live update where required, hard reload after rebuild, and
saved screenshots - is mandatory before the item may move to done. If verification
surfaces a defect, the item is not done: it goes back to clarification with a note on
what was missed, per the credo item model. Never downgrade or self-approve this gate.
