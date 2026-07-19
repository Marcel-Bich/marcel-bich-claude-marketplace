---
name: skill-capture
description: >
  Turn a recurring in-session workflow into a reusable Claude Code skill. Load this the
  moment you notice you have run the SAME multi-step sequence (same ordered steps or
  commands, small variation allowed) about three times in the current session, or when
  open candidates are waiting in .credo/skill-candidates.md at session start or resume. It
  is heuristic and in-session only - no persistent counter, no tracking backend. Mode-gated
  like the audit nit-disposition policy: autonomous mode NEVER builds a skill (it only
  appends a candidate note and keeps working), active / passive / default propose the
  capture via the Ask tool and build only on an explicit GO. Applies inside subagents too,
  where the safest branch (autonomous: candidate note only, never ask, never build) is the
  default whenever the mode cannot be determined.
---

# skill-capture - recurring workflow becomes a reusable skill

When the same ordered, multi-step workflow keeps recurring in a session, that repetition is
a signal: the workflow is worth capturing once as a Claude Code skill so it need not be
re-derived every time. This skill governs how credo notices that repetition and, only with
the right permission, turns it into a discoverable skill - without inventing any new
infrastructure.

## Detection heuristic (in-session, no backend)

Detection is purely heuristic and lives entirely in the current session's context. There is
NO persistent counter, NO tracking file that increments, NO new infrastructure. You notice
the pattern the same way a person would:

- A candidate is the SAME multi-step sequence - the same ordered steps or commands, small
  variation allowed (different arguments, paths, or names) - that you have carried out about
  three times in the running session.
- One-off actions and trivial single commands are not candidates. The value is in a
  multi-step ordered sequence that you would otherwise reconstruct from scratch each time.
- Detection resets with the session. This skill does not try to remember across sessions via
  a counter; cross-session memory lives only in the two `.credo/` files below, which are
  written when a pattern is actually noted or built, never as a running tally.

## Mode gating (hard guarantee)

How you act on a detected candidate depends strictly on the session mode, mirroring the
audit skill's nit-disposition policy (presence modes ask, autonomous acts on a documented
default). The mode comes from the session-mode inject line.

**Safe default when the mode is not determinable.** A subagent gets no session-mode inject
line, so its mode is often unknown. When you cannot determine the mode, apply the SAFEST
branch = the autonomous behavior below: append a candidate note only, never ask, never
build. This is the same principle by which safety rules always take their strictest reading
inside subagents - an unknown mode must never fall through to the ask-and-build branch.

- **Autonomous mode - NEVER build a skill, no matter how often the pattern recurs.** A skill
  needs an explicit user GO, which an autonomous run never has; a build-on-detection rule
  would be a showstopper. Instead, append ONE candidate note to
  `.credo/skill-candidates.md` and continue the actual work normally. Never block, never ask,
  never create the skill. The note is what lets a later presence-mode session pick it up.
- **Active / passive / default with the user present (main agent, mode determinable) -
  propose, never auto-create.** Explain the recurring pattern briefly and use the Ask tool to
  propose capturing it as a skill, with a clear recommendation (default: capture, when the
  pattern is genuinely reusable). Build the skill ONLY after an explicit GO. Without a GO,
  either drop it or record it as an open candidate (below) - never create a skill unasked.
  This ask-and-build branch requires that the mode is actually determinable and the user is
  reachable; an unknown mode takes the safe default above, not this branch.

This gating is the load-bearing guarantee: autonomous work is never derailed into building a
skill, and no skill is ever created without the user's explicit GO.

## Where the generated skill goes (standard discovery path)

A generated skill MUST land on a real Claude Code skill-discovery path, or Claude Code will
never find it. Derive the scope from the workflow, propose the location via Ask, and let the
user confirm or change it:

- **Repo-specific workflow** (only meaningful in this project) -> `<repo>/.claude/skills/`.
- **Generally useful workflow** (useful across projects) -> `~/.claude/skills/`.

Do NOT place a generated skill under `.credo/skills/` or anywhere else outside the discovery
paths - a plain `.credo/skills/` folder is NOT scanned for skills, so a skill written there
would silently never load. `.credo/` holds only the two tracking files below, never the
generated skill itself.

## Origin marking (all three, together)

Every skill built from a recurring workflow carries all three origin markers, so it is
always recognizable as credo-generated and traceable back to its pattern:

1. **Name prefix `credo-<name>`** - the skill's `name` (and folder) starts with `credo-`, so
   generated skills group visibly in the skills list. Example: `credo-hotfix-pr`.
2. **Frontmatter marker plus a dated body note** - each generated `SKILL.md` frontmatter
   carries `origin: credo-repetition`, and the body opens with a short comment naming the
   source, for example: "Built from a recurring workflow on 2026-07-19." Keep the note to
   one line.
3. **Register line** - append one line per built skill to `.credo/generated-skills.md` (see
   below).

## The two `.credo/` files (append-only, created on first use)

Both files live at the root of `.credo/` (resolve `.credo` via the repo root, same as every
other credo file), are plain append-only Markdown, and are created the first time they are
needed - do not pre-create them. Like the rest of `.credo/**` they are git-excluded by
default, so they stay local unless the project opted into `.credo` versioning.

- **`.credo/generated-skills.md`** - the register of skills that were actually BUILT. One
  line per built skill: name, path, date, and the observed pattern.
- **`.credo/skill-candidates.md`** - patterns that were SEEN but not built. Autonomous mode
  appends here. Active / passive read it at session start and offer the open candidates
  (below). Append-only: to resolve a candidate you APPEND a resolution line referencing it
  (built or discarded), you do not rewrite earlier lines. An "open" candidate is one with no
  later resolution line.

### Example line format

`.credo/generated-skills.md` (one line per built skill):

```
- 2026-07-19 | credo-hotfix-pr | ~/.claude/skills/credo-hotfix-pr/SKILL.md | pattern: branch -> edit -> commit -> push -> gh pr create, seen ~3x
```

`.credo/skill-candidates.md` (a candidate, then its later resolution):

```
- 2026-07-19 | candidate: release bump (edit plugin.yaml + plugin.json version, validate JSON), seen ~3x | scope: repo (marcel-bich-claude-marketplace) | status: open
- 2026-07-20 | resolved candidate 2026-07-19 (release bump): built as credo-version-bump (<repo>/.claude/skills/credo-version-bump/SKILL.md)
```

A discarded candidate resolves the same way: `... | resolved candidate <date> (<short>): discarded - <reason>`.

## Session-start loop (presence modes)

In active and passive mode, at session start or resume, read `.credo/skill-candidates.md`
and gently offer any OPEN candidates (those without a resolution line) - exactly the tone of
the common-core "Soft old-item reminder": surface a few, recommend, then let it go. No hook,
no compulsion, no pushing back against the current work; the only goal is that a candidate
noted by an earlier (often autonomous) session is not forgotten. On a GO, build it and
append both the register line and a candidate resolution line; on a decline, append a
discarded resolution line. Autonomous mode does not run this offer loop - it only ever
appends candidates, never builds.

## KISS / YAGNI

This feature is deliberately behavior-only. It needs NO new shell script, NO tracking
backend, and NO config options - just this skill's text plus the two Markdown files that
Claude maintains by hand. Do not add a counter, a hook, or a config key for it unless a
concrete need actually appears (YAGNI). When you do build a generated skill, keep the skill
itself minimal and follow the normal skill conventions.

## dogma-first

Where dogma already governs a concern (git rules, language, versioning, linting) for the
generated skill or its files, follow dogma first and treat credo rules as fallback only.
DOGMA-PERMISSIONS always take precedence.
