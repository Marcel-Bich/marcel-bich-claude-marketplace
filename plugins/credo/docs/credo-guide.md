# Credo Guide

Architecture, how-to, and dependency notes for the credo plugin. The `README.md` is the short overview; this guide goes deeper.

## 1. What credo is and why

credo is a self-contained process framework for Claude Code. It exists to make good working habits enforceable and project-local instead of tribal knowledge: a per-session working mode, a work-item lifecycle with a hard Definition of Done, budget-aware autonomy, visual verification, and safety rules that survive delegation into subagents.

Design principles:

- **Self-contained.** No dependency on foreign skills. Every rule lives inside credo. The only external touchpoints are the `limit` plugin (recommended prerequisite for a few features) and `ntfy` (optional).
- **Folder is the truth.** An item's status is where its file lives, not a field that can drift.
- **Proof over claims.** Done means audited and, for UI, visually verified in a real browser; not "the test passed".
- **Rules travel.** Safety and quality rules are re-injected into every subagent so delegation cannot dilute them.
- **State survives compaction.** Requirements, handoffs, and items live on disk under `.credo/`, not only in conversation.

## 2. Architecture

### 2.1 Components

- **commands/** - six slash commands: `psalm`, `setup`, `session-init`, and the three mode setters `session-active`, `session-passive`, `session-autonomous`.
- **skills/** - fourteen auto-discovered skills (see section 6). Each auto-triggers when it applies, including inside subagents.
- **hooks/** - exactly two hooks are registered in `hooks/hooks.json`:
  - `session-mode-inject.sh` (`UserPromptSubmit`) - re-injects the active session mode on every prompt and names the skill to load.
  - `credo-subagent-inject.sh` (`SubagentStart`) - primes every subagent with the load-bearing rules.

  The autonomy scripts (`credo-autonomy-on.sh`, `credo-autonomy-off.sh`, `credo-autonomy-clear.sh`, `credo-autonomy-keepalive.sh`, `credo-autonomy-wake-mark.sh`) and `session-mode-set.sh` are plain helper scripts invoked by the session commands and skills - they are NOT registered as hooks. In particular `credo-autonomy-keepalive.sh` is written as a `Stop` hook and `credo-autonomy-clear.sh` as a `UserPromptSubmit` companion, but neither is wired into `hooks.json`. So there is no runtime Stop-hook enforcement of keep-alive today; autonomous keep-alive is best-effort and instruction-driven (see section 4).
- **scripts/** - `check-setup.sh`, `credo-init.sh`, `credo-id-next.sh`, `credo-config.sh`, `credo-budget-read.sh`, `credo-item-move.sh`.
- **templates/** - `config.default.yaml` (builtin config defaults) and `item.template.md` (the work-item template).

Skills and hooks are auto-discovered by Claude Code from their directories, matching the convention used by the sibling `limit` and `dogma` plugins. Only commands are declared in the manifest.

### 2.2 Per-session mode mechanic

The mode (active | passive | autonomous) is stored on disk, one file per session id under `~/.claude/credo/session-modes/` (overridable via `CREDO_SESSION_MODES_DIR`). A session-setter command writes the file; the `UserPromptSubmit` hook reads it and injects a short reminder line plus the name of the skill to load. Because the state is keyed by session id and re-read every prompt, the mode is stable across compaction, new sessions, and subagents. The hook is failure-safe: any problem means exit 0 with no output, never a blocked prompt.

### 2.3 Subagent priming

The `SubagentStart` hook injects a compact rule block into every subagent before its first prompt: inherited security (no installs without approval, never read secrets, never delete protected paths), quality gates (visual verify, item + audit gating, verbatim requirements), honesty, delegation rules, and output hygiene. It cannot block subagent creation; it only adds context. This is the mechanism that makes a delegation-first main agent safe even when its own context has rotted.

### 2.4 State on disk

All credo state is per project under `.credo/` (see section 3) or per user under `~/.claude/credo/`. State files are written atomically. `.credo/**` is excluded from git on purpose; persistence across a compact is the files on disk plus your normal backups, not commits.

## 3. The `.credo/` structure

`scripts/credo-init.sh` creates this tree in the target repo (idempotent) and adds the git-exclude lines:

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
    reports/           diag / audit / verification reports (frontmatter kind:)
  checklists/          auto-generated cross-cutting checklists
  config               per-project config (YAML)
  id-counter           deterministic integer counter
```

By default `credo-init.sh` excludes all of `.credo/**` from git. Opt-in versioning is a per-project decision: run `credo-init.sh` with `CREDO_VERSION_TRACKED=1` to version `.credo/**` in the repo EXCEPT the per-project `config` and the `screenshots/`, which stay local always. This is useful when the team should see items and process in the repo's own history; `config` (may hold machine-specific overrides) and `screenshots/` (verify evidence, often large) remain excluded either way. The exclude entries live in a marker-delimited managed block in `.git/info/exclude`, so re-running toggles the mode cleanly in either direction. The default (variable unset) keeps `.credo/` fully unversioned.

### 3.1 Config cascade

YAML, merged lowest to highest:

```
builtin (templates/config.default.yaml) < global (~/.claude/credo/config) < project (.credo/config)
```

The builtin template holds universal defaults only:

- `verify.viewports`: 320, 768, 1440
- `windows.veto_minutes`: 20, `windows.deferred_question_minutes`: 5
- `compact.thresholds`: 70, 90
- `wakeup.reset_offset_minutes`: 5, `wakeup.fallback_offset_minutes`: 1
- `budget.*`: the 5-hour soft/hard band, the work-hours 09:00 guard reserve, task-sizing bands, and the day-by-day cap schedule
- `budget_failsafe`: absolute caps used if an explicit order is lost to a compact

Personal fields under `personal:` (ntfy topic, commit-identity hint, WSL `lan_ip` plus an `endpoints[]` list of `{name, port, reach}`, living-docs list) ship empty. They are filled just-in-time by the skill that needs them, with permission per change. `/credo:setup` can pre-initialize the global config.

### 3.2 Deterministic id-counter

`scripts/credo-id-next.sh` owns id allocation. The counter file holds the last id given out. Allocation is atomic under flock: read (0 if empty), increment, write, print. It never scans folders to choose a number, so a deleted item id is never reused. A recovery fallback (max existing id plus one) applies only if the counter file is missing. Never derive an id from folder contents; always call the helper.

## 4. Session modes: how-to

Set the mode with a command; it also loads the matching skill.

- `/credo:session-active` - intensive live collaboration, user at the keyboard, no keep-alive.
- `/credo:session-passive` - agent carries most work, user reachable for clarifications only, no keep-alive.
- `/credo:session-autonomous` - approved GO items worked unattended, best-effort keep-alive (the model schedules its own `ScheduleWakeup` wake-ups; there is no Stop hook that forces it), budget caps enforced, ntfy per task and question, progress secured via compact-plus.

The active skill defines the common core shared by all three; passive and autonomous layer their differences on top. On every prompt the inject line reminds you of the current mode, so it cannot be silently forgotten.

Honest note on keep-alive: autonomous mode sets the `credo-autonomy-active` flag and instructs the model to keep itself awake by scheduling its own wake-ups, but nothing enforces this at runtime - the `Stop`/`UserPromptSubmit` autonomy hooks are shipped as helper scripts and are not registered (section 2.1). Keep-alive is therefore best-effort: it works as long as the model follows the instruction and calls `ScheduleWakeup` itself.

## 5. The item workflow: how-to

**Task backend (`CREDO_TASK_BACKEND`).** credo's item model is the default task system, but it can stand down in favour of get-shit-done. The variable takes `credo` (default), `gsd`, or `none`; anything unset, empty, or unknown behaves like `credo`, so the default behaviour is unchanged.

- `credo` (or unset / `none`) - the item lifecycle below is active. `credo-init.sh` creates the `items/` tree and id-counter, and the subagent priming tells delegated agents to record and gate work as credo items.
- `gsd` - the credo item model stands down: `credo-init.sh` skips the `items/` tree and id-counter, the subagent priming drops the item/audit sentence, and the items/audit/verify skills note that they do not gate credo items. GSD's phases own task tracking; set this when you run GSD as the task system so there is no `.credo/items/` vs `.planning/` double-bookkeeping. The operating layer (session modes, budget, safety, verify, subagent priming) stays on regardless.

The rest of this section describes the `credo` backend.

1. Get an id: `scripts/credo-id-next.sh`.
2. Copy `templates/item.template.md` to `items/1_todo/1_clarify/<id>-<slug>.md`. Fill the mandatory frontmatter: `id`, `title`, `created`, `type`, `ui`.
3. Capture the requirement verbatim and draft observable success criteria (the Definition of Done).
4. On an explicit GO, move to `items/1_todo/2_go/` (`scripts/credo-item-move.sh`).
5. Build, wiring the new code so a caller reaches it. Record what was built with file:line references.
6. Run the Definition of Done gate (section 5.1). On pass, move to `items/2_done/`.
7. Only the user moves an item to `items/3_verified/`.

Parked work goes under `items/parked/{hold,future}`; abandoned work under `items/4_archived/`.

### 5.1 Definition of Done gate

An item may enter `2_done/` only when all hold:

- success criteria are observably met and the code is wired in,
- a dedicated audit subagent (not the builder) reviewed the work against its requirement and Definition of Done and returned a pass,
- for `ui: true`, a visual verify drove the real surface in a browser across the configured viewports and captured screenshot evidence under `.credo/screenshots/`,
- docs were updated in the same change.

## 6. Skills reference

- **audit** - read-only quality gate against requirement and Definition of Done; severity-ranked decision, never a fix. Mandatory before `2_done/`.
- **diag** - read-only root-cause diagnosis at file:line; the fix is a separate GO-gated step.
- **verify** - visual verification as Definition of Done for any runtime surface; real browser, computed layout.
- **items** - the folder-is-status work-item model gated by the Definition of Done.
- **requirements-verbatim** - append-only verbatim capture of requirements, decisions, approvals, GOs.
- **budget** - API budget caps and reset rules for the 5-hour and weekly limits, plus the commit-identity gate.
- **compact-plus** - secures approved work before a compaction and reports whether it is safe; does not run `/compact`.
- **orchestration** - safe, efficient delegation to subagents (count, disjoint files, monitoring, inherited security, return-and-resume).
- **safety** - hard filesystem-protection and no-autonomous-installs rules; highest priority.
- **cross-cutting-checklist-generator** - detects scattered concerns and auto-generates a project-local checklist.
- **wsl-env** - reach Windows-side services, processes, and launchers from WSL; self-detecting.
- **session-active / session-passive / session-autonomous** - per-mode behavior; the active skill holds the shared core.

## 7. Dependencies (honest)

### 7.1 `limit` plugin - recommended prerequisite

Required for two features:

- **Context-percent triggers.** Auto-running compact-plus at the session-context fill thresholds relies on the limit plugin's inject hook. Point it at credo:
  - `CLAUDE_MB_LIMIT_COMPACT_SKILL=credo:compact-plus`
  - `CLAUDE_MB_LIMIT_INJECT_THRESHOLDS=70,90`
- **Budget data.** The budget skill reads the limit cache (`/tmp/claude-mb-limit-cache_*.json`) via `scripts/credo-budget-read.sh` for the 5-hour and weekly utilization and reset times. That helper exits with a distinct code when no fresh cache is present.

Without the `limit` plugin these features are silently unavailable. No error is raised; credo just does not run logic that has no data.

### 7.2 `ntfy` - optional

Push notifications use `ntfy`. The topic is `personal.ntfy_topic` in the credo config. Unset means ntfy is silently skipped. Nothing else depends on it.

## 8. Testing conventions

Every hook, state, and config mechanism is testable against a temporary HOME (for example `HOME=$(mktemp -d) bash hook.sh`) so tests never touch the real `~/.claude`. Hooks are failure-safe: any error exits 0 with no output and never blocks a prompt or a subagent.
