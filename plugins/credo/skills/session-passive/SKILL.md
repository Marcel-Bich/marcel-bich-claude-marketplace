---
name: session-passive
description: >
  The credo behavior for a session running in PASSIVE mode - you carry most of the work
  alongside and the user is available only for clarifications, with no keep-alive. Load
  this when the session-mode inject line says "Load skill session-passive", right after
  the /credo:session-passive command, or whenever you are working mostly on your own but
  the user is still reachable for questions. Shares the canonical common core defined in
  the credo session-active skill, then adds the passive-mode specifics: drive items toward
  a full GO, "less is more" (only ambiguous items via Ask), gently prefer older items
  first. One mode is active at a time.
---

# session-passive - work alongside, user available for clarifications

A credo session runs in exactly one mode - `active`, `passive`, or `autonomous` - set by
the `/credo:session-*` commands and surfaced on every prompt by the session-mode inject
line. This skill is the umbrella for **passive** mode: you handle most of the work
yourself while the user stays reachable for clarifications, and there is no keep-alive.

## Common core (shared - read the session-active skill)

Passive mode uses the same **canonical common core** as every credo session skill. It is
defined once in the credo `session-active` skill and applies here in full - read it there.
It covers, all unchanged for passive mode:

- CLARIFY-FIRST and the go-gate (only `1_todo/2_go` is buildable) - credo `items`.
- Clarify via the Ask tool (G1); a bug report is not an immediate fix (G2).
- Read-back scaled to complexity (A4); autonomous read-back on an active <-> passive
  transition.
- The soft old-item reminder (gentle, on start / resume and occasionally).
- No silent rename / restructure and the consistency sweep (G6); evaluate foreign handoffs
  independently (G7).
- Authority order (E5) and its scoping.
- The ntfy hybrid model (section D): immediate `high` only for come-to-PC events, progress
  bundled into one digest per `ntfy.digest_interval_minutes`; skip silently if
  `personal.ntfy_topic` is empty.
- Git-push policy (G5): commit and push immediately; the commit-identity gate lives in the
  credo `budget` skill; forbidden commit/push -> WARN, work not securable.
- The credo `safety` skill applies always.
- The building blocks a session ties together (`items`, `verify`, `requirements-verbatim`,
  `audit`, `diag`, `orchestration`, `cross-cutting-checklist-generator`, `skill-capture`,
  `budget`, `compact-plus`, `wsl-env`).

The section below only states where passive mode DIFFERS from that core.

## Passive-mode specifics (A2)

Passive mode is "you drive, the user reviews". The user is present for clarifications but
is not collaborating turn-by-turn.

### Handle most of the work alongside

Carry the bulk of the work yourself. Pick up buildable items (`1_todo/2_go`) and move them
through the full Definition-of-Done gate - dedicated-subagent audit before `2_done/`,
visual verify for `ui: true` - never self-approving (credo `items` and `verify`). Delegate
substantive work to subagents per the credo `orchestration` skill so the main context
stays lean.

### Proactively drive items toward a full GO

Push open items proactively toward being 100 percent GO: resolve what can be resolved,
research the vague, and prepare clarify-stage items (`1_todo/1_clarify`) so that a single
Ask turns them into `2_go`. The aim is that when the user does engage, items are ready to
build rather than still half-specified.

### Less is more - only ambiguous items via Ask

This is the defining passive-mode rule. Do NOT over-ask. Bring only the genuinely
ambiguous items to the user, through the Ask tool. Anything you can resolve yourself
within the authority order (self-resolve up to level 3) you resolve; you do not narrate
every step or ask for confirmation on the self-evident. Batch and minimize interruptions -
the user's attention is the scarce resource. Each item you do bring still gets its own Ask
round - see "One item per Ask round" in the common core (session-active skill).

### Gently prefer older items first

When choosing what to advance, gently prefer older open items over newer ones, so old
numbers get closed out. This is a soft preference, not a hard "oldest first" rule and not
a block on new work - the same gentle spirit as the common core's old-item reminder.

### Capture recurring workflows (Ask allowed)

Passive mode has the user reachable for clarifications, so the credo `skill-capture` skill
applies in its presence-mode form: when a multi-step workflow recurs about three times, and
when open candidates sit in `.credo/skill-candidates.md` at session start, propose capturing
them as a reusable skill via the Ask tool - build only on an explicit GO, never unasked.
Keep it within the "less is more" rule: bring only genuinely reusable patterns.

### No keep-alive

Passive mode does NOT keep the session awake. The `/credo:session-passive` command clears
`credo-autonomy-active` and sets the `credo-autonomy-paused` opt-out. Keep-alive exists
only in autonomous mode (`/credo:session-autonomous`).

### Commit and push immediately

Per the common-core git-push policy, commit and push work as it lands.
