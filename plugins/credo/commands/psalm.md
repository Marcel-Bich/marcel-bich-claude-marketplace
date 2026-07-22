---
description: credo - Interactive guide to available topics and workflows
arguments:
    - name: question
      description: Optional question or topic to explore
      required: false
allowed-tools:
    - Bash
    - Read
    - Write
    - Edit
    - AskUserQuestion
    - Skill
---

# Credo - The Preacher's Guide

credo is the mentor: a self-contained process framework. This guide starts with credo's own teachings and only then points to the wider marketplace. The other plugins are recommended or optional and slot in around credo.

## Step 0: Run Setup (Recommended)

Before the faithful walk the path, ensure the project is set up.

**Invoke /credo:setup via Skill tool.**

This handles:
- Initializing the credo framework (`.credo/` tree) - the core, self-contained.
- Optional companions: dogma (recommended), get-shit-done (optional, spec-driven alternative to credo items).
- Claude instructions sync (`/dogma:sync`, if dogma is installed).
- Choosing a task system (credo items by default).
- Autonomy preferences and, when the limit plugin is present, wiring its auto-compact trigger to `credo:compact-plus`.

**After setup completes, continue to Entry Point.**

---

## Entry Point

After setup, help the user discover topics. credo's own capabilities come first.

**If user runs `/credo:psalm` without arguments:**

Use AskUserQuestion to show available topics:

```
What would you like to explore?

- The credo workflow: how a piece of work flows end to end
- Session Modes: active / passive / autonomous working modes
- Item Lifecycle: work items with a hard Definition of Done
- Budget and Autonomy: unattended work within 5h and weekly caps
- Verify and Safety: visual verify, filesystem protection, subagent priming
- The Wider Marketplace: hydra, dogma, import, limit and more (optional)
- Something else: Ask your own question
```

**If arguments provided:** The user already has a question. Answer it directly using this guide, or navigate to the most relevant section.

---

## Credo's Own Teachings

These are the heart of the framework. Everything below lives inside credo - no foreign plugin required.

### Topic: The credo workflow (end to end)

How one piece of work flows through credo, tying the topics below into one path:

1. Set up once: `/credo:setup` - framework, optional companions, autonomy and compact preferences.
2. Pick a session mode for how present you are: active / passive / autonomous (see Session Modes).
3. Capture the work as an item: requirement verbatim, plus observable success criteria (the Definition of Done). Clarify first; nothing is built before an explicit GO (see Item Lifecycle).
4. On GO, build - delegation-first via subagents (load `/credo:session-init` for the main-agent workflow), wiring new code so a caller actually reaches it.
5. Pass the hard Definition of Done gate: an independent audit subagent (not the builder), visual verify for any runtime surface, docs updated in the same change. Findings are dispositioned, not dropped.
6. Only the user files the item as verified.

Cross-cutting throughout: budget caps, filesystem safety, and subagent priming apply the whole way, especially in autonomous mode (see Budget and Autonomy plus Verify and Safety).

Load `/credo:session-init` to bring in the delegation-first working workflow; the individual topics below drill into each step.

### Topic: Session Modes

credo runs a session in one of three exclusive modes. The active mode is re-injected on every prompt, so it is never silently forgotten.

- `/credo:session-active` - intensive live collaboration, you at the keyboard, no keep-alive.
- `/credo:session-passive` - the agent carries most of the work; you stay reachable for clarifications only, no keep-alive.
- `/credo:session-autonomous` - approved GO items worked unattended, keep-alive on (hook-enforced: a registered Stop hook blocks a stop without a scheduled wake-up), budget caps enforced, ntfy per task and question, progress secured via compact-plus. It self-bootstraps on an unambiguous full-autonomy grant, needing no host CLAUDE.md line.

Pick the mode that matches how present you are. Switch any time by running the matching command. credo injects the local date and time on every prompt, so the agent is time-aware: when no mode is set it proposes a fitting presence mode via Ask (never autonomous, never silently), and it mentions the active mode now and then, especially after a long gap. An autonomous run is never interrupted by a mode-change question - switch it only with an explicit command.

When clarifying or proposing a GO in a presence mode, the agent works one item per Ask round rather than dumping many items at once (see the session-active common core).

### Topic: Item Lifecycle and Definition of Done

Work lives as items under `.credo/`, where the folder is the status - no separate field that can drift:

```
items/1_todo/1_clarify -> items/1_todo/2_go -> items/2_done -> items/3_verified
```

The path of an item:

1. Get an id (`scripts/credo-id-next.sh`), copy the item template into `1_clarify/`.
2. Capture the requirement verbatim and draft observable success criteria (the Definition of Done).
3. On an explicit GO, move to `2_go/` and build - wiring the new code so a caller actually reaches it.
4. Run the Definition of Done gate. Only on a pass does it move to `2_done/`.
5. Only the user files an item under `3_verified/`.

To onboard an existing repository into this structure, run `/credo:migrate` - it sets up `.credo/` and walks the repo through the migration procedure once.

credo targets the repo you point it at (hub-aware): when your shell cwd is a launch hub rather than the repo you are working on, pin the real target with `/credo:project <path>` so the item tree and config resolve to the right place. A directory marked `hub: true` is never auto-targeted.

**The Definition of Done is hard:** success criteria observably met, code wired in, an independent audit subagent (not the builder) passed it, UI work visually verified in a real browser with screenshot evidence, and docs updated in the same change - including the project wiki, via `/dogma:docs-update` where dogma is installed (a best-effort manual update otherwise). The audit gate dispositions every finding down to NITs and prefers a real code fix over a doc-only workaround. "The test passed" is not done.

### Topic: Budget and Autonomy

credo is limit-aware. In autonomous mode it reads the 5-hour and weekly usage caps (via the `limit` plugin cache), sizes tasks to fit the remaining budget, and pauses or hands off before a wall is hit. When the limit cache is absent it asks for a budget decision rather than running blind, and the weekly reset is handled as a pause-and-resume, not a showstopper. Approved GO items are worked unattended with keep-alive; each task and question fires an ntfy push so you can step away and still be called back. Autonomous machine power-down (sleep) is opt-in (default off, server-safe): the mode (StandBy / suspend or Ruhezustand / hibernate) and the exact command are chosen per platform at `/credo:setup`. ntfy is used only if you configured a topic.

### Topic: Verify and Safety

- **Verify** - for any runtime surface, done means a real browser drove the actual UI across the configured viewports and captured evidence, not a claim.
- **Safety** - filesystem protection and no-autonomous-installs rules are the highest priority, and they are re-injected into EVERY subagent. Delegation cannot dilute them.
- **Subagent priming** - every subagent starts with the load-bearing security, quality, honesty, and output-hygiene rules already in context, so a delegation-first main agent stays safe even when its own context has rotted.

### Topic: PR Vetting and Issue Triage

Two orchestration skills for maintaining a public repo. They trigger on their own, but you can also ask for them by name.

- **pr-vetting** - rigorous multi-subagent vetting of external pull requests across technical, security, value/fit, contributor reputation, and license/compliance dimensions, with automated mass-PR / product-injection detection. Merges the findings into one decision-ready report; the merge/close decision stays with the maintainer.
- **issue-triage** - selection-first GitHub issue triage: shortlist and prioritize before deep-triaging chosen issues via parallel subagents, then recommend close/fix/keep/needs-info for the owner to approve before any action.

### Topic: Capturing Recurring Workflows (skill-capture)

When the same multi-step workflow keeps coming back in a session - about three times - credo can turn it into a reusable Claude Code skill instead of re-deriving it each time. Detection is in-session and heuristic; there is no counter and no backend.

It is mode-aware. In autonomous mode credo never builds a skill on its own - it just notes the pattern in `.credo/skill-candidates.md` and keeps working. In active or passive mode it explains the pattern and proposes capturing it via a question, building only on your GO. A built skill lands on the normal discovery path (`<repo>/.claude/skills/` or `~/.claude/skills/`), is marked as credo-generated (a `credo-` name prefix and an `origin: credo-repetition` marker), and is logged in `.credo/generated-skills.md`. Open candidates are offered again gently at the next session start.

### The Full Commandments (credo)

| Command | Purpose |
| --------------------------- | -------------------------------------------------------------- |
| `/credo:setup`              | Initialize the framework and offer recommended/optional tools  |
| `/credo:migrate`            | Migrate an existing repo into the `.credo/` structure          |
| `/credo:project`            | Pin the active repo credo targets (hub-aware) or show it       |
| `/credo:psalm`              | This guide - credo topics first, then the wider marketplace    |
| `/credo:session-init`       | Load the main-agent delegation-first workflow                  |
| `/credo:session-active`     | Set the session to active (live collaboration)                 |
| `/credo:session-passive`    | Set the session to passive (clarifications only)               |
| `/credo:session-autonomous` | Set the session to autonomous (unattended GO items, keep-alive)|

credo also ships auto-discovered skills that trigger on their own (including audit, diag, verify, items, requirements-verbatim, budget, compact-plus, orchestration, safety, cross-cutting-checklist-generator, skill-capture, wsl-env, pr-vetting, issue-triage, and the session-mode skills). You do not call them by hand; they apply when they apply, including inside subagents.

---

## Optional: A Spec-Driven Task System (get-shit-done)

credo's items are the recommended default. If you prefer up-front decomposition of a large, well-understood project - or you already know and like the original GSD flow - get-shit-done is an optional alternative execution core. Pick ONE task system per project (credo items OR GSD phases), never both, to avoid competing sources of truth. credo's session modes, budget, safety, and verify still apply on top of either.

If you chose GSD, its hierarchy is:

```
PROJECT.md          <- What is the project?
ROADMAP.md          <- All milestones
  Milestone v1.0
    Phase 1-9
      Plans         <- Executable work packages
```

Typical GSD flow: `/gsd:new-project` (or `/gsd:map-codebase` for existing code) -> `/gsd:create-roadmap` -> `/clear` then `/gsd:plan-phase N` -> `/clear` then `/gsd:execute-phase N` (repeat) -> `/gsd:complete-milestone`. See `/gsd:help` for the full command set.

---

## The Wider Marketplace (Optional)

credo governs the session; these plugins each solve one problem around it. Ask the user which interest them:

**Use AskUserQuestion with these options:**

```
Which marketplace topics would you like to explore?

- Parallel Development: Run multiple features simultaneously with hydra
- Code Quality: Automatic linting and formatting with dogma
- Documentation: Cache and search API docs locally with import
- Resource Monitoring: Track tokens, costs, and rate limits with limit
- Decision Making: Mental frameworks for tough choices
- Prioritization: Find what matters most with the Eisenhower matrix
- Git Ignore Patterns: Never forget an ignore location
- Something else: Ask your own question
```

Only explain the topics the user selects.

### Topic: Parallel Development (hydra)

Run multiple features simultaneously without Git conflicts:

```
Use all fitting /hydra commands to complete the following tasks
as parallel as possible. Use as many subagents as makes sense:

- Feature A: Add authentication
- Feature B: Create API endpoints
- Feature C: Build UI components
```

Hydra handles worktree creation, agent spawning, and cleanup. After completion:

```
/hydra:merge feature-auth
/hydra:cleanup
```

`/hydra:delete` and `/hydra:cleanup` will never accidentally delete the main worktree.

**Worktree settings BEFORE spawn:** configure `.claude/settings.json` in the worktree before spawning agents, e.g. to disable linting for agents that do not need it:

```json
{
    "env": {
        "CLAUDE_MB_DOGMA_LINT_ON_STOP": "false",
        "CLAUDE_MB_DOGMA_PRE_COMMIT_LINT": "false",
        "CLAUDE_MB_DOGMA_SKIP_LINT_CHECK": "true"
    }
}
```

If an agent fails due to hooks, adjust settings in the worktree and respawn.

**Pro tip:** you do not need to run `/credo` (or any command) to benefit from it - just mention it in your prompt:

```
Follow the patterns from /credo to verify these requirements...
```

### Topic: Code Quality (dogma)

Automatic formatting and linting on every commit:

```
/dogma:lint:setup
```

For version sync issues across the project:

```
/dogma:versioning
```

### Topic: Documentation (import)

Need current docs for a library:

```
/import:url-or-path https://docs.example.com/api
/import:search "authentication"
/import:update
```

### Topic: Resource Monitoring (limit + hydra)

The limit plugin shows token usage, rate limits, and costs in the statusline. For parallel agents:

```
/hydra:watch
```

Live table with the status of all worktree agents.

### Topic: Decision Making (taches-cc-resources)

Facing an architecture decision:

```
/consider:first-principles
/consider:swot
/consider:10-10-10
```

### Topic: Prioritization (taches-cc-resources)

Too many tasks, unclear what is urgent:

```
/consider:eisenhower-matrix
```

### Topic: Git Ignore Patterns (dogma)

Never forget an ignore location when adding patterns:

```
/dogma:ignore
/dogma:ignore:audit
```

Adds patterns to `.gitignore` (shared) and `.git/info/exclude` (local only), and audits which are missing where.

### The Full Commandments (Wiki Reference)

Deeper command tables for the wider marketplace:

**Dogma:**

| Command                    | Purpose                                                           |
| -------------------------- | ----------------------------------------------------------------- |
| `/dogma:lint`              | Run linting and formatting on staged files (non-interactive)      |
| `/dogma:cleanup`           | Find and purge AI-typical patterns from your code                 |
| `/dogma:permissions`       | Create or update DOGMA-PERMISSIONS.md interactively               |
| `/dogma:force`             | Apply all CLAUDE rules to your project with full control          |
| `/dogma:sanitize-git`      | Cleanse git history from Claude/AI traces                         |
| `/dogma:docs-update`       | Synchronize documentation across README and wiki                  |
| `/dogma:recommended:setup` | Check and install recommended plugins and MCP servers             |
| `/dogma:ignore:sync-all`   | Sync ignore patterns to all local repositories (marketplace only) |

**Hydra:**

| Command           | Purpose                                               |
| ----------------- | ----------------------------------------------------- |
| `/hydra:parallel` | Spawn multiple agents simultaneously across worktrees |
| `/hydra:list`     | Show all worktrees with paths and branches            |
| `/hydra:status`   | Detailed status including uncommitted changes         |

**Import:**

| Command               | Purpose                            |
| --------------------- | ---------------------------------- |
| `/import:url-or-path` | Import from URL or local file path |
| `/import:list`        | List all cached documentation      |
| `/import:search`      | Search within cached docs          |
| `/import:update`      | Re-fetch from original source      |

**Signal:** no user-invocable commands - it works through hooks that notify you when Claude needs attention or completes work.

**Limit:** displays in your statusline automatically. One command: `/limit:highscore` shows highscores and LimitAt achievements.

---

## Further Help

- `/credo:session-init` - load the delegation-first main-agent workflow
- `/gsd:help` - all GSD commands (if the optional GSD path is used)
- `/hydra:help` - worktree management

### Wiki (Fallback for Details)

If more detail is needed, check the marketplace wiki:

**URL:** https://github.com/Marcel-Bich/marcel-bich-claude-marketplace/wiki

Use WebFetch to retrieve specific wiki pages when users ask for more details not covered here.
