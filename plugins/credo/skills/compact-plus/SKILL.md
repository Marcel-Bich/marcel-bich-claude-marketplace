---
name: compact-plus
description: >
  Secure everything the user approved before a context compaction so a later /compact
  can never lose or alter it. Writes verbatim intent and handoff state to disk and
  commits plus pushes the tracked work product in the correct repository, then reports
  whether it is safe to compact. It does NOT run /compact itself - it makes a later
  compact safe. Run this only when the limit plugin's injected ACTION line names it
  (session-context fill crossed a configured threshold) or when the user invokes it
  manually. Never self-trigger it proactively - that only wastes tokens. Accepts extra
  trailing instructions to perform in addition to the securing checklist. A minimal
  mode (invoke as /compact-plus min) secures only intent plus handoff to disk - no
  audit, no commit or push - for a quick token-cheap save.
---

# compact-plus - secure progress before a compact

A standard /compact thins the conversation summary. Anything that lives only in the
chat or in volatile task metadata can be lost or quietly altered when that happens.
`compact-plus` is the ritual that runs BEFORE a /compact so nothing approved is lost:
it secures the user's approved work and requirements into durable files, then confirms
it is safe to compact.

This skill only SECURES. It never calls /compact itself. Securing and compacting are
two separate acts: compact-plus makes the later compact (manual or automatic) safe.

## When this runs

Exactly two triggers, never a third:

1. The limit plugin injects an ACTION line naming this skill, because the session
   context fill crossed a configured threshold. Run it then.
2. The user invokes it manually.

The ACTION line is meant for the MAIN session only. A subagent that sees one ignores it
and does not run compact-plus (or a self-compact); the main session gets it on its own.

Do NOT run this on your own initiative. The model must never decide by itself that now
is a good time to secure and then start the checklist unprompted - that burns tokens on
every turn. Wait for the hook ACTION line or a manual invocation. This is a hard rule.

## The auto-run trigger (session context, not budget)

The trigger axis is the SESSION CONTEXT fill percentage - how full the current context
window is - which is the axis a /compact acts on. Keep it separate from the two budget
axes (the 5 hour API limit and the weekly API limit); those are handled by the credo
budget skill and never trigger this one.

credo does not ship its own hook for this. The limit plugin already provides the exact
mechanism: its inject hook reads the canonical session-context fill from the statusline
cache and, at each configured threshold, injects an ACTION line telling the agent to run
a named skill. That hook is deterministic:

- Each threshold fires EXACTLY ONCE per session (the crossed thresholds are recorded).
- The fired thresholds reset only after the fill actually drops back below them, which
  is what a real compact does - so after a genuine compact the same threshold can fire
  again later. It does not re-fire on every prompt in between.

To point that mechanism at this skill, the limit plugin configuration must set:

- `CLAUDE_MB_LIMIT_COMPACT_SKILL=credo:compact-plus` - names this skill in the ACTION line.
- `CLAUDE_MB_LIMIT_INJECT_THRESHOLDS=80,92` - the fire percentages. Since limit v2.32.0
  these are percent of the way to auto-compact (the tacho), not percent of the full window.

`/credo:setup` offers to set these in `~/.claude/settings.json` for you (Step 9) when the
limit plugin is installed, so setting them by hand is optional.

The intended thresholds also live in credo config under `compact.thresholds` (default
80 and 92) as the documented source of truth. Read them with:

```
"${CLAUDE_PLUGIN_ROOT}/scripts/credo-config.sh" get compact.thresholds
```

Keep the limit env thresholds and `compact.thresholds` in agreement; the limit env var
is what actually fires. If the limit plugin is not installed or not active, the auto-run
is silently disabled - no error - and manual invocation still works.

## Verbatim fidelity (hard rules, always)

- Capture EVERYTHING the user approved, completely and faithfully. Never trim, soften,
  reinterpret, censor, or omit any approved detail, whatever the topic. Preserve it
  exactly as stated.
- Never invent constraints the user did not state. Never present your own interpretation
  as the user's requirement. Keep user-verbatim strictly separate from your own proposal.
  When in doubt, quote the user verbatim instead of paraphrasing.

## Target the RIGHT repository (not the shell cwd)

The session shell may run at a different path than the actual work repo (for example a
WSL session whose work repo lives on a mounted Windows drive). Do not assume the current
directory is the repo. Determine the repo where this session's work happened and operate
there. Verify the toplevel explicitly before acting:

```
git -C <path> rev-parse --show-toplevel
```

Nested repositories resolve to the nearest enclosing repo, so run this from a path known
to be inside the intended repo. If more than one repo received work this session, secure
each of them. If unsure which repo, ask the user.

## Two securing channels

credo splits the securing across two durable channels, because the process artifacts and
the work product persist differently:

- On disk (git-excluded `.credo/`): the verbatim requirements log and the rolling
  handoff. `.credo/**` is intentionally excluded from git, so these are made
  compact-safe by being written to disk (and picked up by the disk backup), NOT by being
  committed. Do not try to commit `.credo/` content.
- Committed and pushed: the tracked work product (code, project docs under `docs/`,
  version bumps, and anything else git tracks) in the correct repository. This is the
  channel where commit plus push and the origin verification apply.

## Modes: full (default) vs minimal

- FULL (default): the complete securing checklist below (steps 1-8) - disk securing
  plus the audit gate and the commit-and-push of the tracked work product.
- MINIMAL: invoked as `/compact-plus min` (also `minimal`, or an equivalent trailing
  "minimal" / "min" instruction). Do ONLY steps 1-3 (capture verbatim intent, append to
  the requirements-verbatim log, update the rolling handoff - all on disk), then jump
  straight to the report. SKIP the audit (step 4) and the commit-and-push (steps 5-7).
  Use it for a quick, token-cheap disk-only securing when there is nothing to commit or
  the user only wants intent plus handoff preserved. Minimal mode never commits or
  pushes and never runs the audit subagent.

Pick the mode from the invocation argument BEFORE starting: an argument of `min` /
`minimal` (or an equivalent trailing instruction) selects MINIMAL; otherwise FULL.

## Securing checklist

Do every step in the correct repo, then report. In MINIMAL mode do only steps 1-3,
then go straight to the report (step 8) and skip steps 4-7.

1. Review THIS conversation for everything the user explicitly approved, requested,
   decided, or corrected since the last secure point - exact wording, concrete examples,
   parameter values, every detail.
2. Append that verbatim intent to the on-disk requirements log using the credo
   `requirements-verbatim` skill: an append-only dated file under
   `.credo/process/requirements/` (for example `.credo/process/requirements/<YYYY-MM-DD>.md`).
   Mark user-verbatim separately from your own proposal. This log is git-excluded and is
   secured by being on disk, not by a commit.
3. Update the rolling handoff at `.credo/process/handoffs/HANDOFF.md` so the current
   plan and the done/pending state survive: what is done, what is open, what comes next.
   Include the test/question letter state: the next free letter and the still-open test and
   question letters (credo `verify` skill, "Test and question letters"), so the sequence
   continues after the compact instead of restarting at A.
   Move the prior handoff into `.credo/process/handoffs/archive/` before overwriting.
   Note any in-flight subagent work explicitly - either finish and fold it in, or record
   that it is still running and what it will produce. This file is git-excluded too.
   Then drop the one-shot post-compact rehydrate breadcrumb so the next SessionStart
   (after the compact) reminds you to reload this handoff:

   ```
   "${CLAUDE_PLUGIN_ROOT}/scripts/credo-rehydrate-mark.sh" .credo/process/handoffs/HANDOFF.md
   ```

   This also marks the session as credo-engaged if you had not formally opted in, so the
   credo workflow knowledge is re-fed after the compact. It never overrides an explicit
   earlier decision.
4. Run the audit gate before committing. The completed work must pass the credo `audit`
   skill, run by a dedicated subagent (not the builder). Hand the subagent the verbatim
   location of what to audit and let it read the source itself - do not paraphrase the
   work for it. If the audit finds a core deviation, the work is not done: it is not
   safe to present as secured until that is resolved per the credo item model.
5. Commit and push the tracked work product in the correct repo. Securing ends only when
   nothing is local-only. Verify both:

   ```
   git -C <repo> status --short --branch
   git -C <repo> log origin/<branch>..HEAD
   ```

   The status line must show no "ahead" and the log must be empty. If a commit or push
   is forbidden by permissions, do not silently stop: warn plainly that the work cannot
   be secured (autonomy is limited) and that the user must grant the needed permissions,
   per the credo git policy.
6. When locating where something belongs (a doc, a spec section), search `docs/**`
   thematically rather than guessing the path.
7. Perform any trailing instructions passed with the invocation, in addition to the
   checklist above.
8. Report: list what was secured on disk and what was committed and pushed, confirm that
   `git -C <repo> log origin/<branch>..HEAD` is empty (no "ahead"), state what the
   trailing instructions did, and then say plainly either "safe to /compact" or name
   exactly what is still unsecured.

Only after that green report is a /compact safe. This skill never issues the /compact
itself.

## After a green report: the real /compact via /credo:self-compact

The separate command `/credo:self-compact` (`scripts/credo-self-compact.py`) runs the real
Claude Code `/compact` on this session to save tokens. compact-plus still never calls
`/compact` itself; the command's detached worker types it into this session's OWN tmux
pane, and only once the session is idle, the input field is empty and no dialog, Ask
question, permission prompt or menu is open. It refuses without the rehydrate breadcrumb
from step 3, so it only works after compact-plus.

- Only after a green report ("safe to /compact"). The breadcrumb must be fresh (default
  at most 2 h old); an older one is refused - run compact-plus again.
- No background work of any kind blocks it. Background subagents, background Bash
  shells, scripts, monitors and any other background service survive `/compact` and keep
  working (it can even be good that they
  run during the compact). No background check and no `--no-background-work` flag are
  needed; the worker ignores background rows in the pane footer. Only
  `/credo:self-restart` keeps the background gate (a restart kills that work).
- credo autonomous mode - no question, already at the FIRST ACTION: run compact-plus,
  and right after its green report set the `ScheduleWakeup` plus wake mark the keep-alive
  demands, then run `credo-self-compact.py run --auto` and END THE TURN - unless something
  important speaks against it (then record why).
- Interactive modes - ask ONCE via the Ask tool whether to run the real /compact now. Only
  after an explicit yes run `credo-self-compact.py run --user-confirmed` and END THE
  TURN.
  No answer or no -> leave it; the user compacts when they want.
- After the compact the session wakes itself. The worker waits for the compact-done
  signal (SessionStart source `compact`) and types `.` (60 s fallback re-send), so the work
  continues without relying on a subagent or background script happening to finish.
- tmux only; outside tmux `check` says so and the user compacts by hand.

Details and the owner rule: `commands/self-compact.md`.
