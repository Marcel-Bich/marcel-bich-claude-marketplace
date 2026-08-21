---
name: sandbox
description: >
  Do WRITING pre-work for a clarify item that is blocked by a knowledge gap - a missing
  measurement, a mockup, or a feasibility proof - WITHOUT touching production code, without git,
  and without disturbing the task / build agent. Use when a 1_clarify item cannot be answered by
  a product decision alone but needs something built or measured first; when working in the
  plan / clarify role and a clarify question needs evidence; and for isolated read-and-write
  pre-work in autonomous / AFK runs. Triggers on clarify pre-work such as "measure this before we
  decide", "build a quick mockup to clarify", "prove this is feasible", "sandbox this",
  "Messung / Mockup / Machbarkeit vor der Klaerung", "bau eine Sandbox dafuer". Do NOT use for a
  pure product decision (nothing to measure - that is answered by asking the user), and never for
  production code or commits.
---

# sandbox - writing pre-work for clarify items

Clarify items often hang on a knowledge gap that is NOT a product decision: a missing
measurement, a mockup, or a proof that something is feasible. The plan / clarify role
(`role-plan`) must not touch production code and must not commit. The sandbox gives it a place
to do writing pre-work OFF to the side - no production code, no git, no interference with the
task / build agent - so the clarify question can be answered with evidence instead of guesswork.

## Two folders

- `.credo/sandbox-tmp/` = UNVERSIONED work in progress. One folder per item:
  `.credo/sandbox-tmp/<id>-<slug>/` with a `README.md`. This is where pre-work is built.
- `.credo/sandbox/` = the PROMOTION TARGET for accepted, version-worthy artifacts. It follows
  the credo folder-versioning policy: in an untracked repo it stays local; in a version-tracked
  repo (`CREDO_VERSION_TRACKED=1`) it IS versioned.
- `docs/` is NOT the promotion target. Extracting a promoted artifact into `docs/` is a
  SEPARATE step the user prompts for explicitly; it never happens automatically.

### exclude behavior (owned by credo-init)

The git-exclude is managed by `credo-init` in a single managed block in `.git/info/exclude`
(see the credo-init policy). Do not write that block from anywhere else.

- Default (untracked, `CREDO_VERSION_TRACKED` unset): all of `.credo/**` is excluded, so both
  `sandbox-tmp/` and `sandbox/` stay local. Nothing extra is needed.
- Tracked (`CREDO_VERSION_TRACKED=1`): `.credo/**` is versioned EXCEPT the entries credo-init
  lists, which include `.credo/sandbox-tmp/`. So WIP stays local even in a tracked repo, while
  the promoted `sandbox/` is versioned.

The helper `scripts/credo-sandbox-init.sh` never writes the managed block; it only WARNS when
`sandbox-tmp` is not effectively git-excluded and points at `/credo:setup` to refresh it.

## Reference search order

When resolving a sandbox reference for an item, ALWAYS look in this order:

1. `.credo/sandbox/<name>/` (promoted, accepted artifact) - use this if present.
2. `.credo/sandbox-tmp/<name>/` (WIP) - fall back to this.

The promoted copy wins because promotion is the signal that the artifact was accepted.

## INDEX per folder

Each folder carries its own INDEX, kept separate (do not merge them):

- `sandbox-tmp/INDEX.md` = the WIP map.
- `sandbox/INDEX.md` = the promoted map.

The same principle holds for any other collection file that lives outside a single item folder:
keep one per folder, never a shared one spanning both. An INDEX entry records, per item:
the item -> its deliverables -> the key finding -> which clarify question it unblocks. It also
lists the NO items (clarify items with no pre-work) with the reason (a pure product decision has
nothing to measure).

## Item pointer

Every clarify item that has pre-work gets a `## Sandbox pre-work` section in the item file. It
records the sandbox path plus the search order above, so anyone reading the item finds the
evidence. (The item file is credo item content and follows the item language; the section header
is that fixed pointer name.)

## Lifecycle

1. **Triage** all `1_clarify` items into JA (has a buildable deliverable) / NEIN (nothing to
   measure), naming the concrete deliverable for each JA item. This triage is delegatable to a
   subagent. A NEIN item is justified explicitly (a pure product decision - answer it by asking
   the user, do not build anything).
2. **Build** each JA item in `.credo/sandbox-tmp/<id>-<slug>/` via the helper
   `scripts/credo-sandbox-init.sh <id>-<slug>` (it creates the folder, a README template, and
   the WIP INDEX). One subagent per folder, parallelizable on disjoint folders (credo
   `orchestration`).
3. **Record** the `sandbox-tmp/INDEX.md` entry and the item's `## Sandbox pre-work` pointer.
4. **Clarify** with the user. When an artifact is accepted and version-worthy, promote it via
   `/credo:sandbox-promote <slug>` (Ask + move + fix up references).
5. **Extract to docs/** only when the user explicitly prompts for it - a separate manual step.
6. **Resolve references** always in the search order above (promoted first, WIP fallback).

## Guardrails (hard)

- Write ONLY under `.credo/sandbox-tmp/` (and, at promotion, `.credo/sandbox/`). NEVER production
  code, NEVER git, NEVER an install. Use only devDeps that already exist; if a tool is missing,
  hand-roll it install-free or flag it as a recommendation - do not install anything.
- Do not disturb the task / build agent: `sandbox-tmp` is git-excluded, so it never lands in that
  agent's `git add`.
- Node / tooling version: before running any node / npm / pnpm / yarn tooling, activate the
  repo's Node version - see the credo `orchestration` skill's Node-version precheck. Do not
  duplicate that rule here; just follow it.
- Honesty: label every measurement with what it does NOT measure, so a partial proof is never
  read as a full one.

## Role and mode

- This fits the plan / clarify role (`role-plan`): the clarify owner does the pre-work but does
  NOT commit. It is also valuable in autonomous / AFK runs, which are read-heavy - the sandbox
  lets such a run do isolated writing pre-work without touching production code.
- The promotion commit is made by the task / build role (`role-task`), never by the plan agent -
  a single index owner avoids the `.git/index.lock` race (credo `orchestration`).
