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
     silently. In autonomous mode there is no Ask tool, so this question goes into
     the end-of-run report as text with a Q code.
   - If it is empty, the fallback chain applies with no question.

2. **Else Playwright.** If no primary test level is configured, drive the real build in a
   browser with Playwright for the optical, responsive, and theme behavior (measured
   layout, real interaction, each configured viewport).

3. **Else a reviewer / audit agent.** If neither applies, fall back to a reviewer or
   audit agent as the last resort.

Passing the applicable level in this chain is the condition for bringing an item to
`done`. Do not skip up the chain: a configured `verify.primary_test` is not satisfied by
running Playwright instead.

## Playwright version (newest installed, never installed by credo)

Every Playwright version needs its own browser revision (250-600 MB each), so old lockfile
pins pile up old browsers under `~/.cache/ms-playwright`.

- **(a) Raise Playwright as its own step - only with consent.** When you work in a project
  whose Playwright is older than the newest version, propose raising it (lockfile update,
  then `npx playwright install` for the browsers) as a separate step with a test run. Green
  -> keep it; red -> go back to the old version and report. Raising it changes the lockfile
  and downloads browsers, so it IS an install. It needs the owner's explicit consent each
  time (credo `safety`, no-autonomous-installs). In autonomous runs or wherever the Ask tool
  is not used, never do it. Note it as a proposal for the owner and carry on with the
  installed version.
- **(b) Unreferenced revisions are pruned automatically.** Once a day the SessionStart
  maintenance runs `credo-cleanup.py playwright-prune`: it finds every
  `playwright-core/browsers.json` on disk (also `~/.npm/_npx`, global and pnpm installs, plus
  Playwright's own `.links`) and removes the revision directories under
  `~/.cache/ms-playwright` (or `PLAYWRIGHT_BROWSERS_PATH`) that none of them names. It only
  deletes and never downloads or installs anything. A project that still needs a removed
  revision gets it back only when a user (or an agent with consent) runs its install. It
  never touches `mcp-chrome-*` or any directory that is not a known browser-revision name,
  keeps revisions installed less than 2 hours ago, and prunes nothing when the search did
  not finish or found no installation.

## Flaky tests and speed

- A flaky test is a defect. Find the cause and fix it. Flaky tests are always fixed,
  never retried, skipped or deferred (no retry loop, no skip marker, no "fix it later").
- Tests and deploys are optimised for speed, so the user never waits longer than really
  needed. Run the relevant subset first, parallelise where safe, cut idle waits and
  redundant steps. Large projects may legitimately take long; speed never replaces a
  required test level.

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

- Keep a test round small: 1-2 items per round, not a long checklist of everything.

Example:

```
### 🧪 T1) #37 Auto-Grant + Auto-Submit
1. Hard-reload localhost:5173 (Ctrl+Shift+R), Network tab, filter api.
-> Answer: on load, without a click, does a POST /api/games appear? Status? With token+seed?
2. Win the board (just play).
-> Answer: on the win, does a POST /api/result fire automatically? Status (201?)?
```

Use plain `-` and `->`, no special arrow or dash characters.

Owner-facing tests and tasks follow the presence rule of the session-active skill ("Owner
actions in full while the owner is present"). While the owner is present, the steps go into
the chat reply in full, copyable commands and the expected result included, never as "see
item" or "see report". While the owner is away, the test stays open and is presented in full
at the first owner prompt after the absence.

### Typed codes: tests, questions, vetos (visible, monotonic)

Every manual test block, every question to the user and every product-visible decision the owner may overrule gets a typed code (internal process decisions get none, see the veto rules below), so the user can answer unambiguously ("T3 vf", "Q4: option 2", "V12 ok"). This applies in every session mode and every repo where credo is active. The agent keeps the convention by following this text; no hook enforces it.

- **Three separate counters per project.** Tests use `T1, T2, T3 ...`, questions `Q1, Q2, Q3 ...`, vetos `V1, V2, V3 ...`. Each counter is monotonic: a number is never reused, never reset, and there is no wrap-around. The numbers carry on across replies and across compacts. When unsure whether a number is free, skip it rather than repeat one: one number too many is fine, a repeated number is not.
- **Steps are numbered inside a test** (1. 2. 3.). A step is addressed with a dot: "T3.2 vf" = step 2 of test T3 checked and passing. The dot is required, because "T32" would read as test 32.
- **Visible headings.** Each test block, question and veto starts with its own markdown `###` heading line, never inline text:
  - The emoji is mandatory wherever a code asks something of the user (heading, Ask question text, inline mention): always "🧪 T5", "❓ Q4", "✋ V2", never a bare "T5" or "**T5, test ...**", so the user can match each block to its footer entry at a glance.
  - test: `### 🧪 T3) <topic>`
  - question: `### ❓ Q4) <topic>` (a question asked through the Ask tool carries the same `❓ Q4)` prefix in its question text)
  - veto: `### ✋✋ V2) Veto possible: <what was decided or done> ✋✋` (in a German conversation the marker word is `Veto möglich`). Use it only when an agent decides or does something on its own that the owner notices in the product (behaviour, visible text, money or cost, taste, data) and may want to overrule, typically in autonomous runs, instead of a plain "veto possible" sentence. Internal process, measurement, test-set or tooling decisions get no veto code: they go only into the requirements log and the item History. Each veto states the consequences for the user when they are not obvious.
- **Answers.** `T3 vf` (test passed), `T3.2 vf` (step 2 passed), `Q4: <answer>` (question answered), `V12 <objection>` (veto objected to: the agent acts on the objection, and the veto is closed), `V12 ok` (veto accepted, closed).
- **Vetos stay open.** A veto has no deadline. It can be raised or resolved at any time, also long after the fact. It stays open, in every footer, until one of these happens: the user resolves it by its code; the user resolves all open vetos at once ("drop all vetos", "alle vetos weg"); or the context shows that the user already accepted that point elsewhere; or the agent closes it itself, without the owner's word, when its item is done or verified and nothing of the decision is still open, or when later work superseded it. The agent notes each such closure in the handoff, and the periodic reminder checks every open veto against its item status. A closed veto leaves the footer and the band.
- **Shortened repeats keep the command.** A question or test that is repeated in a shorter form
  while it is still open keeps the full copyable command whenever one of its options is an owner
  action (the #131 rule): the owner runs that command, so a short form never replaces it. The
  numbered steps and the expected result come back with it.
- **Open-codes footer.** End every reply that has open tests, questions or vetos with one line listing ALL still-open codes in bold, in the language-neutral emoji form (the same in every conversation language, no translated labels): `**🧪: T3** · **❓: Q4, #177** · **✋: V2, V5**`. Repeat the still-open codes in every reply: the band reads only the footer of the last reply. Omit a part with no open codes, and omit the footer when nothing is open. The footer is a comma list of codes, never prose. An open question about an item still gets its own code (`### ❓ Q4) #177 <topic>`), and item refs may stand next to codes (`**❓: Q4, #177**`). credo's band reads this line; it still accepts the older English and German word labels for tests and questions (vetos have no word label).
- **Legacy codes.** Open codes from before this convention (single letters such as `B` or `DX`) stay as they are until closed and may still appear in footers. All new codes use T, Q or V.
- **One shared counter per project.** Get every new T/Q/V number from credo-code-next.sh <type>; never count yourself; the handoff's next free number is informational only. Run `"${CLAUDE_PLUGIN_ROOT}/scripts/credo-code-next.sh" Q` (one number per output line; a count as second argument, `Q 3` for three numbers). All sessions of one project share the counters, so two sessions never issue the same code.
- **Survives a compact.** The next free number per type and all open codes are part of the handoff state (the credo `compact-plus` skill records them in HANDOFF.md), so the numbering continues after a `/compact` instead of restarting at 1.
- **Separate from other numbering.** Typed codes are neither item numbers (`#N`) nor harness task numbers (`§cct_N`); never mix them.
- **Remote mirror markers (optional sink, `remote.mirror_command`).** Only two markers in a reply reach the owner's remote sink, and only when the owner has set that sink: a test block whose heading carries `[blocking]` (`### 🧪 T4) <topic> [blocking]`, for a test that must pass before the work can go on) and a blocker line `Blocker: <what only the owner can solve>` (or `**Blocker:** ...`). `Blocker: none` is not a blocker. The lines below the blocker line, up to the next heading, go to the sink as its context, so write the question and what you need from the owner in that block. An ordinary test without the marker is never mirrored, and the marker is for real owner blockers only, not for status. A question heading (`### ❓ Q4) ...`) is mirrored by the hook as well; the rest of this section is unchanged.

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
  restart. Defer the visual verify as human-only (`human-only: pending` in the item, which
  does not block the move to `2_done`) and record why.

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
local evidence, not committed artifacts. They are kept as evidence; the disposable-files
exception of the credo `safety` skill does not cover `.credo/screenshots/`.

You do not need to resolve the path to `.credo/screenshots/` yourself: save with the bare
filename above, and a credo PostToolUse hook relocates the screenshot into the pinned
project's `.credo/screenshots/` automatically (the screenshot tool is sandboxed to its cwd
and cannot write into the project directly, so the hook moves the file afterwards). Keep
the naming rule exactly; only the naming is your responsibility.

## Definition-of-Done gate

A change with a runtime surface is done only when every observable success criterion the
agent can check is `exercised`. A genuinely human-only check never holds an item in
`2_go`: it is written into the done item as `human-only: pending` with the numbered steps
("Handing a manual test to the user") and the user runs it in the verify phase (credo
`items`, "Human-only checks do not block done"). For items marked `ui: true`, a passing
visual verification at every configured viewport - measured layout, real interaction,
live update where required, hard reload after rebuild, and saved screenshots - is
mandatory before the item may move to done. Where the item carries an acceptance
measurement (data set + target value, credo `items`), the measured value is part of this
proof, and the builder's adversarial self-check covers the unhappy paths of the surface too
(bad input, empty and error states, a reload mid-action). If verification
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
