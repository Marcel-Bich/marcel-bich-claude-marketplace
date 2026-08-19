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

> **Task backend.** If the task backend is `gsd` (`.credo/config: task_backend`, or the `CREDO_TASK_BACKEND` env override), the credo item lifecycle is inactive, so
> there is no credo item to move to done - GSD owns task tracking. The verification method
> here still applies as a general "prove it renders" tool; just do not gate a credo item
> with it in that mode.

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

## Required test level for done (project-configurable)

Which test level a change must pass before it may move to `done` is resolved by a
fallback chain, so a project can pin its own primary method without credo hardcoding any
project-specific tool or device:

1. **Project primary test level.** credo ships `verify.primary_test` pre-filled with a
   default example (a debug read/write device driving a state machine) so the setting is
   discoverable instead of silently empty. credo does not know what the stage is; it is
   referenced only through the config key. Read it with:

   ```
   "${CLAUDE_PLUGIN_ROOT}/scripts/credo-config.sh" get verify.primary_test
   ```

   - If the configured stage EXISTS in this project (you can locate the harness it names),
     THAT is the required level - use it.
   - If it is configured but you CANNOT find such a harness in this project: (a) fall back
     down the chain for THIS verification (step 2, then 3), and (b) ask the user once via
     AskUserQuestion whether to adapt `verify.primary_test` to the project's actual primary
     test entry point or to clear it (empty -> rely on the fallback). Include a short
     explanation of what the setting is and what it is for. Never keep a stale value
     silently.
   - If it is empty, the fallback chain applies with no question.

2. **Else Playwright.** If no primary test level is configured, drive the real build in a
   browser with Playwright for the optical, responsive, and theme behavior (measured
   layout, real interaction, each configured viewport).

3. **Else a reviewer / audit agent.** If neither applies, fall back to a reviewer or
   audit agent as the last resort.

Passing the applicable level in this chain is the condition for bringing an item to
`done`. Do not skip up the chain: a configured `verify.primary_test` is not satisfied by
running Playwright instead.

## Handing a manual test to the user

When a verification can ONLY be done by the human (a human-only criterion, or the
re-test that lets an item move to `3_verified/`), never hand it over as a vague "please
test this". Always give a NUMBERED, step-by-step list the user can execute one step at a
time and answer per step:

- One step per number. Each step is a single, concrete, executable action - never bundle
  several actions into one number.
- Directly under each step, a separate line starting with `-> Answer:` that states
  exactly WHAT to observe or report back (a status, a value, yes/no). This lets the user
  test step by step and answer each step individually.

Example:

```
Test run B - #37 Auto-Grant + Auto-Submit
1. Hard-reload localhost:5173 (Ctrl+Shift+R), Network tab, filter api.
-> Answer: on load, without a click, does a POST /api/games appear? Status? With token+seed?
2. Win the board (just play).
-> Answer: on the win, does a POST /api/result fire automatically? Status (201?)?
```

Use plain `-` and `->`, no special arrow or dash characters.

## Bringing up a down surface (local only, autonomous-capable)

Verification needs the surface running. If it is down, locality decides whether you may
bring it up yourself - this is what keeps a `ui: true` item from being verify-dead in an
autonomous run:

- **Positively verified local** (the restart affects only a process on THIS machine, bound
  to localhost / 127.0.0.1 / ::1 - a local dev server or stack): you MAY bring it up or
  restart it autonomously, then verify. A restart of a confirmed-local runtime is always
  justified - it affects no deployed environment. The git branch is IRRELEVANT: a checkout
  named `main`, `develop`, or `prod` does NOT make the runtime remote - only the actual
  target does. Judge locality by where the process runs, never by the branch name.
- **Locality NOT positively established** (any doubt, or any sign the target is a deployed,
  remote, or shared environment - a staging or production server, a shared host): do NOT
  restart. Defer the visual verify as human-only and record why.

Get the bring-up command from config first; never guess one:

```
"${CLAUDE_PLUGIN_ROOT}/scripts/credo-config.sh" get verify.local_bringup
```

If `verify.local_bringup` is set, use it. If it is empty, fall back to the project's
documented local run procedure (a README step, a package script) only when you can identify
it with confidence; if no safe local command can be established, defer rather than guess -
the credo `safety` skill forbids running a guessed command. After bringing the surface up -
or after any rebuild - force a hard reload before measuring, so you verify the new build.

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

## Real input events (timing, gesture, and hold behavior)

Timing-, gesture-, and hold-dependent behavior - long-press, held chords, drag, and
anything that depends on an input being held over time - may ONLY be verified through a
real input path:

- Playwright real mouse / touch: hold the actual input (for example `mouse.down()` held
  across the duration, real touch), so the press genuinely persists over time, OR
- a human hands-on test.

Synthetically dispatched events (`dispatchEvent`, hand-constructed `PointerEvent`s) are
NOT sufficient proof for "holds while held" behavior. A synthetic event fires once and
does not model an input being held; it can report green while the real held-input path is
broken. Concretely: a synthetic measurement taken before a 200ms long-press timer falsely
reported green, and only a real held mouse exposed the bug. For this class of behavior,
treat synthetic dispatch as no proof at all - use real held input or human hands-on.

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

Passing this gate moves an item to `2_done/`, never to `3_verified/`. `3_verified/` is
human-authorized: an agent never moves an item there on its own initiative. Only the MAIN
agent, and only on the user's explicit instruction, performs that move (via
`credo-item-move.sh <id> verified --user-authorized`); subagents never do - they report
back and the main agent moves it. Hand the user a numbered manual-test list (see "Handing
a manual test to the user" above) so they can confirm before instructing that move.

Visual proof is not the whole DoD: the same change must also carry its docs currency -
including the project wiki (a separate repo), via `/dogma:docs-update` where dogma is
installed or a best-effort manual update otherwise. The credo items skill owns that
requirement; this gate does not restate it.
