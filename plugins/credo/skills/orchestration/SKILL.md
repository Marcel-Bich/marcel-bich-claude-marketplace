---
name: orchestration
description: Delegate work to subagents safely and efficiently - decide how many subagents to run, keep parallel tracks on disjoint files (item `touches:` overlap check) and within machine resources (resource gate, `heavy:` items), give each code track a set-up git worktree (hydra or native, automatic), monitor them without flooding your context, inherit security to every subagent, and use return-and-resume so a subagent can ask a question and continue with full context. Use whenever you are about to spawn one or more subagents, run work in parallel, or coordinate delegated tasks. Applies to any agent that delegates, including subagents that spawn their own helpers.
---

# orchestration

How to delegate work to subagents so results come back correct, parallel work does not
collide, and the delegating agent's context stays lean. This is the reusable
delegation core; the session skills reference it instead of restating it.

## When this fires

- You are about to spawn a subagent for any non-trivial task.
- You have two or more independent tasks that could run in parallel.
- You are coordinating or monitoring already-running subagents.
- A subagent returns needing a decision, and you must route the answer back.

## Delegation-first

Prefer delegating substantive work to a subagent over doing it inline in the main
context. The main agent orchestrates: it splits work, dispatches, integrates results,
and commits. Reserve the main context for coordination and user interaction, not for
large reads or long builds that a subagent can carry.

## How many subagents (situational, no colony rule)

- The delegating agent decides the count based on the actual work. There is NO fixed
  colony pattern and no rule to always fan out wide. Large colonies are expensive; use
  them only ad hoc when a specific task genuinely benefits.
- Parallelism is wanted. There is no fixed cap on code tracks; parallel code tracks are
  limited only by (a) file overlap (`touches:`, below) and (b) the resource gate (below).
- Read-only work (research, clarify, exploration) stays freely parallel: it writes no
  files, so it needs no overlap check (the resource gate still applies to every spawn).

## Parallel code tracks: touches and resource gate

### (a) File overlap - `touches:`

An item may carry the optional frontmatter field `touches:` - a list of paths or globs the
item will likely edit (credo `items` skill). The plan / clarify agent sets it, at the
latest at GO.

- It is GUIDANCE, not a contract. Until implementation it is the source of truth for
  planning parallelism.
- Before spawning builders, run
  `"${CLAUDE_PLUGIN_ROOT}/scripts/credo-touches-check.sh" <id> <id> ...` over the candidate
  items. Exit 0 = no overlap, 3 = overlapping pairs printed (`--json` for a structured
  result); items without `touches:` are listed as `unknown`.
- Overlapping items run SEQUENTIALLY, never in parallel.
- Right before spawning, quickly re-check that the listed paths still exist and fit (files
  may have been renamed or moved since planning). If that check disagrees, the main agent's
  re-assessment wins: it updates the item's `touches:` / plan instead of sending a
  subagent down a wrong track.
- Items without `touches:` (`unknown`): the main agent classifies them itself, best-effort,
  from the item text and plan. Parallel is the default; run them sequentially only in
  serious doubt, or when clearly foreseeable conflicts that are not easy to resolve would
  occur.

### (b) Resource gate - `credo-resource-check.sh`

Before every spawn, run
`"${CLAUDE_PLUGIN_ROOT}/scripts/credo-resource-check.sh" --running <N>` with N = agents
currently running (add `--heavy` for a heavy item). It prints `ok` (exit 0) or
`wait:<reason>` (exit 5).

- Below `resources.gate_from_agents` running agents (default 6) it answers `ok` without
  looking at the machine. From that count on it checks free RAM
  (`resources.min_free_ram_gb`, default 4) and the 1-minute load per CPU
  (`resources.max_load_per_cpu`, default 1.0). Thresholds live in the credo config.
- On `wait`: start no new agent. Re-check when the next running agent finishes (its
  completion notification) - no polling loop, no sleep loop.
- Fail-safe: unreadable system values never block (`ok` plus a note on stderr).

### Heavy items - `heavy: true`

An item with the optional frontmatter `heavy: true` (model or benchmark tests, large
downloads):

- never runs in parallel to another heavy item, and
- starts only when `credo-resource-check.sh --running <N> --heavy` says `ok` - the check
  always runs for heavy items, even below the agent gate.

### Worktrees for parallel code tracks (hydra or native, automatic)

Parallel code tracks work in git worktrees. Decide the flow once per batch, without any
user command:

```
"${CLAUDE_PLUGIN_ROOT}/scripts/credo-worktree-flow.sh"   # flow=hydra|ask|native, setup=<script>
```

It reads the DOGMA-PERMISSIONS checkbox `use Hydra for 2+ independent tasks` (`### Hydra`
subsection; read via `credo-dogma-mode.sh`, works without dogma) and whether hydra is
installed:

- `flow=hydra` (`[x]`, no checkbox or no DOGMA-PERMISSIONS.md - default on - + hydra
  installed): use hydra's create flow automatically
  (`git worktree add -b hydra/<name> ../<repo>-worktrees/<name>`, then hydra's
  `worktree-setup.sh`), as `/hydra:create` describes - no user command needed.
- `flow=ask` (`[?]` + hydra installed): ask the user ONCE per batch whether to use hydra.
  In autonomous mode never ask - treat it as `native`.
- `flow=native` (`[ ]` or hydra not installed):
  plain `git worktree add -b <branch> <path>`, then `credo-worktree-setup.sh`.

Right after EVERY `git worktree add`, run the `setup=` script on the new worktree
(`<setup> <worktree-path>`). A fresh worktree only has versioned files; the setup links
(relative symlinks) or copies the excluded ones - CLAUDE.md, CLAUDE/, GUIDES/,
DOGMA-PERMISSIONS.md and everything unversioned under .credo/ by default, or the
"Worktree files" list of DOGMA-PERMISSIONS.md (`link:` / `copy:` entries). It never
overwrites an existing path, skips versioned paths and untracked paths that are not
ignored (a `git add -A` in the worktree would commit them; builders read them in the
main checkout), and prints `main=<main checkout>`.
When the harness created the worktree itself (Agent tool `isolation: worktree`), the
builder runs the setup on its own worktree root as its first step.

Every worktree builder brief names the ABSOLUTE main-checkout path (the `main=` line) with
this rule: when something important is missing in the worktree (neither checked out,
linked nor copied), look it up READ-ONLY in the main checkout - never write, commit or run
state-changing git commands there - and mention in the report anything that should be
added to the worktree files list.

Merged and clean worktrees are removed at item close (credo `items` skill, "Worktree
cleanup at item close").

## Parallel safety

- Disjoint files: parallel tracks must edit non-overlapping file sets. Assign each
  track its own files up front (from `touches:` where set). If two tracks would touch the
  same file, they are not independent - sequence them instead.
- Sequential commit: in the MAIN checkout only the MAIN agent commits, one track's result
  at a time. Subagents do not commit there. This keeps history clean and avoids two agents
  racing on the index or on a shared file. Exception (owner-approved): a subagent working
  in its OWN git worktree (hydra or native, see "Worktrees for parallel code tracks") has
  its own index and MAY commit on its worktree branch - never push, never merge; merge,
  push and release stay with the main agent. (By the same index-race logic, the default agent roles put
  commits and push with the task / build agent, not the plan / clarify agent - a guiding
  default, not a constraint; see `session-init`.)
- If a clean disjoint split is not possible, run the tracks sequentially rather than
  forcing false parallelism.

## Monitoring without context flooding

- Launch background subagents non-blocking (`block=false`) so the main agent stays
  responsive and does not stall waiting.
- Do NOT pull a subagent's whole transcript into the main context. Consume only the
  subagent's final result (its returned message), plus short status checks. Pulling
  full transcripts is what floods and rots the main context.
- Check status periodically rather than streaming everything continuously.
- Waiting on background work: prefer the harness completion notification over any
  polling. When you must poll, wait on a result file or one specific PID, always with a
  time limit (`for i in $(seq 1 60); do [ -f done ] && break; sleep 10; done`). Never
  loop on `pgrep -f "<pattern>"`: it matches the waiting shell's own command line, so
  `until ! pgrep -f X` never ends (`credo-wait-hint.sh` flags such loops, it does not
  block). On every wake, check for stuck agents: no new output for a long stretch ->
  inspect and report instead of waiting on.
- A subagent's report is NEVER grounds to claim or move an item status. Consuming only
  the final result keeps context lean, but it does not transfer the subagent's judgment
  to the main agent. Before the main agent asserts a status or moves an item, it must
  read the whole item itself and verify the actual code and state against the item's
  stated intent - a subagent report plus a commit grep is not sufficient evidence. The
  main agent owns the status decision and must ground it in first-hand verification.

## Security inheritance (every subagent, always)

Subagents inherit the same hard security rules as the main agent, with no exceptions:
- Install nothing (no pip / npm / apt / system / global installs) without explicit
  prior approval.
- Read no secrets: no credential files, tokens, key material, or shell history.
- The same filesystem-protection and deletion rules apply. A subagent may not do what
  the main agent may not do.

State these constraints in the task you hand each subagent so they hold even if the
subagent does not otherwise load them.

## Node / tooling version precheck (before any node run)

Before an agent OR a subagent runs node / npm / pnpm / yarn tooling in a repo, derive the
repo's Node version deterministically and activate it - do NOT rely on the random system Node
of the subagent shell:

- Read `.nvmrc` or `.node-version` AND `package.json` `engines.node`, then activate the matching
  Node (`nvm use`, or the project's equivalent) before running the tooling.
- Concrete failure this prevents: pre-work ran on the system Node while the repo required a
  higher major - the `.nvmrc` / `engines` were unambiguous, they just were not switched to, so
  the run failed for a reason that had nothing to do with the actual task.

This applies to every tooling-running agent, not only sandbox pre-work.

## Priming subagents with credo rules

credo does not rely on the main agent to remember the rules. Two mechanisms keep a
subagent self-sufficient even when the main agent's context has rotted:

- The credo `SubagentStart` hook (`hooks/credo-subagent-inject.sh`) injects the
  load-bearing credo rules (security, quality gates, honesty, output hygiene) into
  every subagent at start, automatically.
- The credo skill descriptions are phrased to auto-trigger inside subagents too, so
  the relevant skill loads itself when its trigger is hit.

As a backup for environments where the hook is not active, still name the relevant
credo skills (for example `verify`, `audit`, `items`, `requirements-verbatim`) in the
task you hand each subagent, so a subagent is primed regardless of the hook.

Also pass the project's per-repo special rules to every subagent (credo `rules`): include
the resolved `.credo/RULES.md` content, or an instruction to load it via
`scripts/credo-config.sh rules`, in the task. Project grants must not be lost across
delegation - a subagent has to honor the same widened latitude as the main agent.

## The item is the source of truth

When you delegate a build or implementation task that realizes a credo item, the item
- not your brief - is the authoritative, complete specification. The brief is only a
pointer, and pointers are lossy.

- Every such brief MUST name the item path. Where the work touches domain rules or logic,
  it MUST also name the relevant source of truth as `file:symbol`, not just describe it.
  When the builder works in a worktree, the brief also names the absolute main-checkout
  path plus the read-only lookup rule ("Worktrees for parallel code tracks" above).
- The subagent MUST read the WHOLE item itself and treat it as the single source of truth:
  the complete body, the Success Criteria / DoD, the Historie, AND the requirements log
  under `.credo/process/requirements/` - not just the head, and never the brief alone. It
  builds against ALL requirements the item states, gaplessly. Nothing the item asks for may
  be silently dropped.
- The brief is ORIENTATION, not the authoritative or complete spec (the analogy: a lead
  hands over a ticket saying "this is roughly about X" - the builder listens, then forms a
  full picture from the actual requirements). On any imprecision or contradiction between
  brief and item, the WHOLE item wins. The subagent does not adopt the delegator's summary
  or paraphrase as fact.
- Gated tightening - for user-facing text OR logic that encodes a domain rule (grades,
  thresholds, formulas, enum meanings, marker semantics): the subagent MUST derive each such
  factual claim from the named code source of truth and verify it itself, citing the source
  (`file:symbol` + the value) - never from the brief's paraphrase. For example, a brief
  saying "tier gold / platinum" is a lossy hint; read the rating source and derive which
  tier is the default and which is gated, rather than restating the hint. A bare file
  pointer is not enough when the term lives only in client-side presentation and not in the
  named file - trace it to where the rule is actually defined.
- The paired audit check (completeness against the whole item, and rule-text correctness
  against the source) catches such misses downstream; see the `audit` skill.

This is the build-time, subagent-side duty. It is distinct from the main agent reading the
whole item before it asserts a status or moves it (see "Monitoring without context
flooding"): that governs the status decision after the fact, this governs building against
the item before and during the work.

## Delegating audit subagents

When you spawn the mandatory audit subagent (never the builder), pick the audit tier per
the credo `audit` skill ("Audit depth (risk tiers)": `full` or `lean`) and name tier plus a
one-line reason in the brief. Several finished `lean` items may be batched into ONE audit
subagent (one verdict and report section per item); `full` items are always audited
singly. The tier changes only the depth, never whether the audit runs.

## Delegating verify / UI subagents

When you delegate any verification or UI-checking subagent - the formal credo `verify`
skill or an ad-hoc one you brief inline - the subagent saves each screenshot under the
naming rule `<slug>-<viewport>-<YYYY-MM-DD>.png` (for example
`login-form-320-2026-07-04.png`). A bare filename is enough; the subagent does not resolve
or pass any directory.

A credo PostToolUse hook then relocates every screenshot into the session-resolved
`<pinned-project>/.credo/screenshots/` automatically. This works from a launch hub and
even when a subagent never loads the verify skill. The reason it is hook-based rather than
a path instruction: the screenshot tool is sandboxed to its cwd and cannot write into the
pinned project directly, so no preamble can steer it there - the hook moves the file after
the fact. You therefore do not need to name the target folder in the spawn preamble; just
require the naming rule. See the credo `verify` skill for the full evidence and naming rules.

## Model policy (no downgrade, no model-choice logic)

Subagents always run at a model at least as capable as the main agent's model - never
downgrade a subagent to a weaker model. There is no model-selection logic to reason
about: best quality everywhere. Do not spend effort choosing models.

## return-and-resume (subagent asks, then continues)

Proven pattern for a subagent that hits a question it cannot answer:

1. The subagent returns `{status: needs_decision, question: <the question>}` instead of
   guessing or finishing with a wrong assumption.
2. The main agent obtains the answer (from the user, from the verbatim requirements
   log, or from a documented default when the user is away).
3. The main agent passes the answer back to the SAME subagent via SendMessage to its
   agentId.
4. The subagent resumes with its FULL prior context intact - no throwaway, no rebuild.

Use this instead of killing and re-spawning a subagent when a mid-task decision is
needed. It preserves the subagent's accumulated context and avoids redoing work.

## Config

Any environment-specific values relevant to delegated work live in the credo config
cascade (`builtin template < ~/.claude/credo/config < .credo/config`, read via
`scripts/credo-config.sh`), not in this skill.

## Boundaries

- Self-contained: no dependency on non-credo skills. Referenced by name from the credo
  session skills.
- This skill governs how to delegate. What a subagent should verify, audit, or log is
  covered by the respective credo building-block skills (for example `verify`, `audit`,
  `requirements-verbatim`).
- Cross-track ordering constraints and HOLD notes between item implementations live in the
  harness task list (the ephemeral coordination layer), defined in the credo `items` skill
  ("Harness task-list vs .credo items") - not duplicated here.
