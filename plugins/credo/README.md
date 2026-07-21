# Credo

Credo (Latin: "I believe") is the mentor framework for Claude Code: a self-contained process layer that governs how a whole session runs. It turns a loose set of good habits into an enforced, project-local workflow: a per-session working mode, a work-item lifecycle with a hard Definition of Done, budget-aware autonomy, visual verification, and safety rules that travel into every subagent.

It is opinionated by design and stands alone. Two external touchpoints are documented honestly below: the `limit` plugin (recommended prerequisite for a few features) and `ntfy` (optional push notifications). Everything else lives inside this plugin.

## What credo is

credo is built from small, composable pieces:

- **Session modes** - every session runs in one of three modes (active, passive, autonomous). The mode is per session, stored on disk, and re-surfaced on every prompt.
- **Work-item lifecycle** - each task is a Markdown file under `.credo/items/`. The folder the file lives in is the single source of truth for its status. A hard Definition of Done gate controls promotion to done.
- **Definition of Done** - work counts as done only after a dedicated post-completion audit, plus a visual verify for anything with a UI surface.
- **Budget awareness** - one place that governs how much of the 5-hour and weekly API limits may be spent, when to throttle, pause, wake up, or stop.
- **Visual verification** - a UI change is proven by driving the real thing in a browser and measuring computed layout, not by a green test.
- **Safety** - filesystem-protection and no-autonomous-installs rules, doubled into a skill so they apply inside subagents too.
- **Subagent self-sufficiency** - every subagent is primed at start with the load-bearing rules, so delegated work stays correct even if the main agent context has drifted.

## Commands

| Command | Description |
|---------|-------------|
| `/credo:psalm` | Interactive guide to available topics and workflows |
| `/credo:setup` | Interactive setup wizard: install plugins, sync instructions, init project |
| `/credo:session-init` | Load the main-agent delegation-first workflow instructions |
| `/credo:session-active` | Set the session mode to active |
| `/credo:session-passive` | Set the session mode to passive |
| `/credo:session-autonomous` | Set the session mode to autonomous |

Skills and hooks are auto-discovered by Claude Code from the `skills/` and `hooks/` directories, so they are not hand-listed in the manifest.

## Session modes

The mode is per session and set with a command. It is stored on disk keyed by the session id, so it survives compaction, new sessions, and subagents. The `UserPromptSubmit` hook re-injects a one-line reminder of the active mode on every prompt, and names the matching skill to load.

- **active** (`/credo:session-active`) - intensive live collaboration with the user at the keyboard. Progress is logged via the limit thresholds and compact-plus, open GO items are picked up alongside, clarifications happen during subagent waits. No keep-alive.
- **passive** (`/credo:session-passive`) - the agent carries most of the work while the user is reachable only for clarifications. Every item is pushed toward a full GO; less is more, so only genuinely ambiguous items go back to the user. No keep-alive.
- **autonomous** (`/credo:session-autonomous`) - approved GO items are worked unattended. Keep-alive is hook-enforced: a registered Stop hook blocks a stop that has no scheduled ScheduleWakeup and instructs the model to set one (loop-safe, and inert outside autonomy); a registered UserPromptSubmit hook turns autonomy off on any real user message. Budget caps are enforced, ntfy fires per task and per question, and progress is secured via compact-plus.

Each command sets the mode and loads its skill. The three session skills share one canonical common core (defined in the session-active skill) and layer their mode-specific rules on top.

## The `.credo/` structure

`scripts/credo-init.sh` creates a per-project `.credo/` tree in the target repo (idempotent) and adds the git-exclude lines so `.credo/**` is not committed. The layout:

```
.credo/
  docs/                stable "how we work here" conventions
  screenshots/         visual-verify evidence: <task>-<viewport>-<YYYY-MM-DD>.png
  items/
    1_todo/{1_clarify,2_go}
    2_done/
    3_verified/        only the user files here
    4_archived/
    parked/{hold,future}
  process/
    requirements/      append-only verbatim log
    handoffs/          rolling HANDOFF.md plus handoffs/archive/
    reports/           diag / audit / verification reports
  checklists/          auto-generated cross-cutting checklists
  config               per-project config (YAML)
  id-counter           deterministic integer counter
```

`.credo/**` is deliberately kept out of git. Persistence across a compact is disk plus your normal backups, not commits.

**Opt-in versioning (per project).** The default (all of `.credo/**` excluded) is right for solo or private work. If you want the items and process visible in the team's history, run `credo-init.sh` with `CREDO_VERSION_TRACKED=1`: it then versions `.credo/**` in the repo except the per-project `config` and the `screenshots/`, which stay local always. The exclude entries are kept in a marker-delimited managed block in `.git/info/exclude`, so re-running switches the mode cleanly in either direction (drop the variable to go back to fully unversioned). This is a deliberate per-project decision; the default is unversioned.

### Config cascade

Config is YAML, merged lowest to highest:

```
builtin (templates/config.default.yaml) < global (~/.claude/credo/config) < project (.credo/config)
```

The builtin template ships universal, safe-for-everyone defaults (viewports 320/768/1440, timing windows, the compact thresholds 70/90, the budget schedule, wakeup offsets). On first need the global config is created from this template. Personal and environment-specific fields (ntfy topic, commit-identity hint, WSL reachability, living-docs list) are intentionally left empty and are filled just-in-time by the skill that needs them, with permission per change. `/credo:setup` is an optional way to pre-initialize this.

### Deterministic id-counter

Item ids come from `scripts/credo-id-next.sh`. The counter file holds the last id given out; allocation is atomic (flock): read the counter, scan the items tree, take `max(counter, highest existing id) + 1`, write it back, print it. The counter, not the folder, decides the number - deleting the highest item never lowers the next id, so a deleted id is never reused; the folder scan is only a safety floor that lifts a counter which fell behind the items on disk (merge, clone, backup restore, sync) and warns on stderr when it does. Always take an id from the helper; never hand-pick one.

## The item workflow

A work item is one Markdown file (`templates/item.template.md`). Its frontmatter is lean and mandatory: `id`, `title`, `created`, `type` (bug | optimization | feature | question | chore), and `ui` (true means a visual verify is part of the Definition of Done). There is no status field, because the folder is the status.

The lifecycle, moving the file with `scripts/credo-item-move.sh`:

1. **clarify** (`items/1_todo/1_clarify/`) - requirement captured verbatim, success criteria drafted.
2. **go** (`items/1_todo/2_go/`) - the user gave an explicit GO; ready to build.
3. **done** (`items/2_done/`) - built and wired, and the Definition of Done gate has passed.
4. **verified** (`items/3_verified/`) - only the user moves an item here.

Parked work lives under `items/parked/{hold,future}`; abandoned work under `items/4_archived/`.

### The Definition of Done gate

An item may move to `2_done/` only when:

- the success criteria are observably met and the new code is actually wired in (a caller reaches it),
- a dedicated **audit** subagent (not the builder) has reviewed the work against its stated requirement and Definition of Done and returned a pass,
- for `ui: true`, a **visual verify** has driven the real surface in a browser across the configured viewports and captured screenshot evidence,
- docs are updated in the same change.

## Building-block skills

Auto-discovered under `skills/`. Each auto-triggers when it applies, including inside subagents.

- **audit** - read-only quality gate; reviews already-built work against its requirement and Definition of Done before it may move to `2_done/`. Proposes a severity-ranked decision (BLOCKER/MAJOR/MINOR/NIT), never a fix.
- **diag** - read-only root-cause diagnosis for a symptom; establishes the mechanism at file:line before any fix. The fix is a separate, GO-gated step.
- **verify** - visual verification as the Definition of Done for any change with a runtime surface; proves behavior in a real browser with computed layout.
- **items** - the work-item model where the folder is the status truth, gated by the Definition of Done.
- **requirements-verbatim** - captures a requirement, decision, approval, or GO word-for-word into an append-only dated log so it survives compaction.
- **budget** - the single source for API budget caps and reset rules across the 5-hour and weekly limits, plus the commit-identity gate before any commit.
- **compact-plus** - secures everything the user approved before a context compaction, then reports whether it is safe to compact. It does not run `/compact` itself.
- **orchestration** - how to delegate to subagents safely: how many to run, keeping parallel tracks on disjoint files, monitoring without flooding context, inheriting security, and return-and-resume.
- **safety** - the hard filesystem-protection and no-autonomous-installs rules; highest priority, no instruction overrides them.
- **cross-cutting-checklist-generator** - detects a concern scattered across many places and auto-generates a project-local checklist so it is never partially updated again.
- **skill-capture** - turns a workflow that recurs about three times in a session into a reusable Claude Code skill. Heuristic and in-session (no counter, no backend), mode-gated: autonomous only appends a candidate note, presence modes propose the capture via Ask and build on GO only. Generated skills land on the real discovery path (`<repo>/.claude/skills/` or `~/.claude/skills/`), carry a `credo-` name prefix plus an `origin: credo-repetition` marker, and are registered in `.credo/generated-skills.md`; seen-but-unbuilt patterns wait in `.credo/skill-candidates.md`.
- **wsl-env** - reach and act on Windows-side services, processes, and launchers when the agent runs inside WSL; self-detecting.
- **session-active / session-passive / session-autonomous** - the per-mode behavior; the active skill holds the shared common core.

## Subagent self-sufficiency

credo primes every subagent at start. The `SubagentStart` hook (`credo-subagent-inject.sh`) injects the load-bearing rules (security, quality gates, honesty, delegation, output hygiene) into each subagent before its first prompt, for all subagent types. This complements the skill descriptions, which are written to auto-trigger inside subagents as well. So even a main agent that only delegates gets correct results, independently of its own context state.

## Dependencies

credo works on its own. Two touchpoints are external:

### `limit` plugin - recommended prerequisite

The [`limit`](https://github.com/Marcel-Bich/marcel-bich-claude-marketplace/wiki/Claude-Code-Limit-Plugin) plugin is a prerequisite for two features:

- **Context-percent triggers** - the auto-run of compact-plus at the configured session-context fill thresholds relies on the limit plugin's inject hook. Point it at credo with:
  - `CLAUDE_MB_LIMIT_COMPACT_SKILL=credo:compact-plus`
  - `CLAUDE_MB_LIMIT_INJECT_THRESHOLDS=70,90`
  - `/credo:setup` offers to set these for you (Step 9) when the limit plugin is installed, so hand-editing is optional.
- **Budget data source** - the budget skill reads the limit cache (`/tmp/claude-mb-limit-cache_*.json`) for the 5-hour and weekly utilization and reset times.

If the `limit` plugin is absent, these features are silently unavailable. There is no error; credo simply does not run the budget or auto-compact logic that has no data.

### `ntfy` - optional

Push notifications use `ntfy`. The topic is a personal field in the credo config (`personal.ntfy_topic`). If it is unset, ntfy is silently skipped; nothing else changes.

## Installation

Add the marketplace and install `credo`, or copy the plugin into your `.claude-plugin/` location. Then run `/credo:setup` to initialize a project and, optionally, pre-fill config.
