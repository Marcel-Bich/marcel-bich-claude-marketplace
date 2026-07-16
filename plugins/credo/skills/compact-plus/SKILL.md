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
  trailing instructions to perform in addition to the securing checklist.
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
- `CLAUDE_MB_LIMIT_INJECT_THRESHOLDS=70,90` - the session-context fill percentages that fire.

The intended thresholds also live in credo config under `compact.thresholds` (default
70 and 90) as the documented source of truth. Read them with:

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

## Securing checklist

Do every step in the correct repo, then report.

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
   Move the prior handoff into `.credo/process/handoffs/archive/` before overwriting.
   Note any in-flight subagent work explicitly - either finish and fold it in, or record
   that it is still running and what it will produce. This file is git-excluded too.
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
