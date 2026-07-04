---
name: requirements-verbatim
description: Capture a user requirement, decision, approval, or constraint word-for-word into an append-only dated log so it survives context compaction and can never be trimmed, softened, or reinterpreted. Use whenever the user states or approves a requirement, gives a GO, sets a constraint, or makes any decision that later work must honor - and also inside subagents, which must log requirements they receive before acting on them. Use before any compaction to secure verbatim intent to disk.
---

# requirements-verbatim

Record requirements, decisions, approvals, and constraints exactly as the user
stated them, into a durable on-disk log. The log is the ground truth for what was
asked. It outranks memory, paraphrase, and model inference (see the authority order
below). Its single job: nothing the user approved can be lost, altered, or quietly
reinterpreted between now and when the work is verified.

## When this fires

- The user states a requirement, gives a GO, sets a constraint, or makes a decision.
- The user approves or rejects a proposal (log what was approved, verbatim).
- You (or a subagent) are handed a requirement and are about to act on it: log it first.
- Before any compaction (see the credo `compact-plus` skill): the verbatim log must
  already hold everything approved, because a compact must not be able to lose or
  alter it.

This fires inside subagents too. A subagent that receives a requirement from the main
agent logs the verbatim source itself rather than trusting a paraphrase.

## Where it lives

Append-only log files under `.credo/process/requirements/` in the current project
(the credo per-project namespace created by `scripts/credo-init.sh`). One dated file,
for example `.credo/process/requirements/2026-07-04.md`, appended to across the day.

- Append only. Never edit or delete an existing entry. A correction is a NEW entry
  that references the earlier one; the original stays.
- Write atomically (temp file plus `mv -f`) per the credo persistence convention, so a
  crash mid-write cannot corrupt the log.
- `.credo/**` is intentionally git-excluded. Durability comes from disk plus whatever
  external backup the environment provides (for example an automatic file backup), not
  from commits. Do not add or force-add `.credo/` to git.

## Verbatim fidelity (anti-censorship - absolute)

- Quote the user WORD FOR WORD. Preserve wording, ordering, emphasis, and any explicit
  numbers or limits.
- NEVER trim, soften, summarize away, reinterpret, sanitize, or censor what the user
  said. This holds regardless of the content, including sensitive or uncomfortable
  material. If in doubt, quote more, not less.
- NEVER invent a constraint the user did not state. Do not present your own
  interpretation as the user's requirement.
- Keep user-verbatim STRICTLY separate from anything you add. Every entry has two
  clearly labeled zones:
  - `User (verbatim)` - the exact words, quoted. Nothing of yours here.
  - `Assistant (proposal / finding)` - optional. Your interpretation, proposal, open
    question, or note. Clearly marked as yours, never mixed into the verbatim zone.

## Reference convention

Refer to a logged requirement by DATE plus a short context phrase (for example
"2026-07-04, ntfy topic in config"). Do NOT reference by transcript line number:
transcript positions are not globally stable across sessions or compaction and will
point at the wrong thing later. Date plus a short unique context phrase is stable.

## Entry format

Append one block per requirement:

```
## <HH:MM local> - <short context phrase>

### User (verbatim)
> <the user's exact words, quoted line for line>

Source: <how it arrived, e.g. chat message / approval of proposal X / GO on item #124>

### Assistant (proposal / finding)   <!-- optional, omit if nothing to add -->
<your interpretation, proposal, or open question - clearly yours, never verbatim>
```

If you must correct or supersede an earlier entry, append a new block and name the
earlier one by its date and context phrase. Never rewrite the old block.

## Authority order (why this log wins)

When sources disagree, precedence descends:
1. User-verbatim / approved (this log).
2. Committed docs and standing orders.
3. Derived or computed facts.
4. Remembered items.
5. Model inference.

Do not re-derive this for every trivial decision. When something is unclear, first
check this log and the committed docs (levels 1-3); only then ask the user, or fall
back to a documented default if the user is away.

## Config

Personal and environment-specific values (backup locations, identities, topics) live
in the credo config cascade, not in this skill:
`builtin template < ~/.claude/credo/config < .credo/config`, read via
`scripts/credo-config.sh`. This skill hardcodes no personal paths or values.

## Boundaries

- Self-contained: no dependency on non-credo skills. May be referenced by name from
  other credo skills (for example `compact-plus`, the session skills, `orchestration`).
- The log records intent; it does not itself commit, build, or verify. Acting on a
  requirement is the job of the relevant session or building-block skill.
