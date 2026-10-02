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

- **commands/** - the slash commands, among them `psalm`, `setup`, `migrate`, `project`, `session-init`, `optimize` (the opt-in optimisation audit, section 5.3), and the three mode setters `session-active`, `session-passive`, `session-autonomous`.
- **skills/** - the auto-discovered skills (see the skills reference section). Each auto-triggers when it applies, including inside subagents.
- **hooks/** - the hooks registered in `hooks/hooks.json` include:
  - `credo-session-start.sh` (`SessionStart`) - makes a session credo-aware. Two separate mechanisms driven by on-disk per-session state, plus an always-on legend: (1) ASK - while no credo decision has been made and only on a human-present (re)start (`source` in `startup`/`clear`), it instructs the agent to ask the user via AskUserQuestion whether to use the credo workflow (yes -> `/credo:session-init`, no -> a `declined` marker so it never asks again); never in autonomous work. (2) KNOWLEDGE - once credo is active for the session (a mode is set, or the decision is `accepted`), it re-injects the full credo command + skill list on every `SessionStart` (`startup`, `resume`, `clear`, `compact`, `fork`), because the model context is gone after each reset; commands are tagged by execution class (A run yourself / B only on user request / C never autonomously). (3) SHORTHANDS - a compact user-shorthand legend (section 5.2) is appended to every output and emitted on its own where the hook would otherwise stay silent, in every state and directory. `compact`/`resume`/`fork` never ASK. Toggles: `CREDO_SESSION_START_INJECT` (default on) gates the whole hook; `CREDO_SESSION_START_ASK` (default on) turns off ONLY the activation ASK while keeping the KNOWLEDGE re-feed; `CREDO_SESSION_START_SHORTHANDS` (default on) turns off ONLY the shorthand legend. Backend gate: when `task_backend` is `gsd` (resolved via `credo-config.sh backend`), the workflow text stands down (no ASK, no KNOWLEDGE, only the shorthand legend) because GSD is the task system and advertising the credo item workflow would mislead. Autonomy guard: the ASK is also suppressed whenever a full-autonomy run is active for THIS session (its per-session `credo/autonomy/<session_id>/active` flag is set and not paused), so an autonomous session is never blocked by an unanswerable Ask prompt; another session's autonomous run never suppresses it. Failure-safe (any problem -> exit 0).
  - `session-mode-inject.sh` (`UserPromptSubmit`) - re-injects the active session mode on every prompt and names the skill to load.
  - `credo-datetime-inject.sh` (`UserPromptSubmit` + `PostToolUse`) - injects the current local date and time, independent of session mode (makes the agent date/time-aware and gives the mode-awareness rules a clock signal). On every prompt via `UserPromptSubmit`; additionally on `PostToolUse` during long autonomous runs where no user prompt arrives, so the clock does not freeze at the last prompt's value. The `PostToolUse` path is throttled (`CREDO_DATETIME_INJECT_INTERVAL`, default 120s) and delta-guarded (only when the rendered minute changed), and since `PostToolUse` fires only on tool activity, idle waits inject nothing. Gated by `CREDO_DATETIME_INJECT` (default on).
  - `credo-autonomy-clear.sh` (`UserPromptSubmit`) - a real user message turns autonomy off for the session it was typed in (drops that session's flag, sets its paused opt-out).
  - `credo-subagent-inject.sh` (`SubagentStart`) - primes every subagent with the load-bearing rules.
  - `credo-autonomy-keepalive.sh` (`Stop`) - in autonomous mode, blocks a stop that has no scheduled self-wake and instructs the agent to call ScheduleWakeup.
  - `credo-optimize-hook.sh` (`SessionStart` + `UserPromptSubmit`) - keeps the per-repo last-seen timestamp current on every prompt and, at session start (also on resume), asks the optimisation-audit opt-in once (credo active, answer open) or injects the welcome-back offer for a returner (section 5.3). Never in autonomous mode, silent in `/credo:disable`d directories; toggle `CREDO_OPTIMIZE_HOOK` (default on).
  - `credo-todo-tools-hint.sh` (`SessionStart`) - while the Claude Code task-list tools opt-in (`CLAUDE_CODE_ENABLE_TODO_TOOLS=1`, needed on newer models for `TaskCreate` / `TaskList`) is off for the active profile and not declined, offers it once via AskUserQuestion (enable with a backup of `settings.json` / not now / never ask again), at most once per `CREDO_TODO_TOOLS_HINT_DAYS` (default 7) days per profile, only on a human-present start (`startup`/`clear`) where credo is active, never in autonomous work (the injected text opens with that rule, since the session mode is often not set yet at a fresh start), silent in `/credo:disable`d directories, and silent without using its slot when `credo-optimize-hook.sh` asks its own opt-in or welcome-back question at the same start (at most one credo opt-in question per start). It never changes settings itself; the helper `credo-todo-tools.sh` does that on a yes (also offered in `/credo:setup` Step 10). Toggle `CREDO_TODO_TOOLS_HINT` (default on).

  The remaining autonomy scripts (`credo-autonomy-on.sh`, `credo-autonomy-off.sh`, `credo-autonomy-wake-mark.sh`), `session-mode-set.sh`, and `session-project-set.sh` are plain helper scripts invoked by the session commands and skills - they are NOT hooks. `credo-autonomy-lib.sh` is a sourced helper (not a hook) shared by all of them; it resolves the session_id and the per-session state dir. Because the `Stop` and second `UserPromptSubmit` hooks are now wired into `hooks.json`, autonomous keep-alive is hook-enforced at runtime (loop-safe, and inert outside autonomy - see section 4).
- **scripts/** - `check-setup.sh`, `credo-init.sh`, `credo-id-next.sh`, `credo-config.sh`, `credo-budget-read.sh`, `credo-item-move.sh`, `credo-decision-set.sh` (records the per-session credo-workflow decision for the `SessionStart` hook), and the read-only renderer helpers `credo-item-counts.sh` (item count per status), `credo-item-list.sh` (per status the total plus the newest N items as id + title) and `credo-session-status.sh` (one session's mode, role and autonomy state). The three helpers resolve the project and session exactly like the hooks (`CREDO_DIR` / `credo-config.sh resolve-project`; session id from the argument, `CREDO_SESSION_ID` or `CLAUDE_CODE_SESSION_ID`), print key=value lines or `--json`, and exit 4 when no credo project resolves (2 when no session id resolves for `credo-session-status.sh`). Parallel worktrees: `credo-worktree-flow.sh` (hydra or native flow from the DOGMA-PERMISSIONS Hydra checkbox), `credo-worktree-setup.sh` (links/copies excluded files into a fresh worktree), `credo-worktree-cleanup.sh` (removes merged and clean worktrees at item close) `credo-optimize-state.sh` / `credo-optimize-idle.sh` / `credo-optimize-fresh.sh` (optimisation audit state, returner detection and freshness check, section 5.3), `credo-todo-tools.sh` (task-list tools opt-in: status with settings vs running-session state and `restart_needed`, JSON-safe enable with backup, decline, hint throttle), and `credo-dogma-mode.sh` (reads one DOGMA-PERMISSIONS checkbox without dogma; `--id <id>` matches the stable `(§xxxx)` id first, the subsection + text pattern only as fallback; same file choice as dogma - target dir, else pinned project, else session folder - with inheritance of missing settings from the session folder's file, switch `(§r3nx)`, default on).
- **templates/** - `config.default.yaml` (builtin config defaults), `item.template.md` (the work-item template) and `shorthands.json` (the compact shorthand cheatsheet data the optional band renders: `key`, a one-`word` meaning and a one-line `meaning` per entry).
- **hooks/band.tsx** (optional, Claude Code mods only) - listed under `modules` in `hooks/hooks.json`; see section 2.5. `types/index.d.ts` is its state contract, named as `types` in `plugin.json`.

Skills and hooks are auto-discovered by Claude Code from their directories, matching the convention used by the sibling `limit` and `dogma` plugins. Only commands are declared in the manifest.

### 2.2 Per-session mode mechanic

The mode (active | passive | autonomous) is stored on disk, one file per session id under `~/.claude/credo/session-modes/` (overridable via `CREDO_SESSION_MODES_DIR`). A session-setter command writes the file; the `UserPromptSubmit` hook reads it and injects a short reminder line plus the name of the skill to load. Because the state is keyed by session id and re-read every prompt, the mode is stable across compaction, new sessions, and subagents. The hook is failure-safe: any problem means exit 0 with no output, never a blocked prompt.

**Self-bootstrap (no host CLAUDE.md needed).** Autonomous mode bootstraps itself, so no line in the user's global `~/.claude/CLAUDE.md` is required. Two pieces: (1) when no mode is set, the inject hook emits one short, informational hint that autonomous mode exists and how to enter it (gated by `CREDO_AUTONOMY_BOOTSTRAP`, default on; the default no-mode state stays normal, non-autonomous collaboration - the line sets no flag and changes no behavior); (2) the `session-autonomous` skill description auto-triggers on a full-autonomy / AFK-handoff grant even before the mode is set, and its bootstrap step then enters the mode via `/credo:session-autonomous`. Guardrail: the skill enters autonomous mode only on an unambiguous, explicit grant and confirms first when the signal is vague - a user who never asks for autonomy is never put into it.

### 2.3 Subagent priming

The `SubagentStart` hook injects a compact rule block into every subagent before its first prompt: inherited security (no installs without approval, never read secrets, never delete protected paths), quality gates (visual verify, item + audit gating, verbatim requirements), honesty, delegation rules, and output hygiene. It cannot block subagent creation; it only adds context. This is the mechanism that makes a delegation-first main agent safe even when its own context has rotted.

### 2.4 State on disk

All credo state is per project under `.credo/` (see section 3) or per user under `~/.claude/credo/`. State files are written atomically. `.credo/**` is excluded from git on purpose; persistence across a compact is the files on disk plus your normal backups, not commits.

### 2.5 Claude Code band (optional)

In Claude Code builds with mods support, `hooks/band.tsx` draws a band above the prompt. It is strictly a renderer: it holds no business logic and no second source of truth, it only runs the read-only core scripts (`credo-item-counts.sh`, `credo-session-status.sh`, `credo-item-list.sh`, `credo-budget-read.sh`, `credo-config.sh get budget.autonomous_5h.main_ladder`) with this session's id (`CREDO_SESSION_ID`) and reads `templates/shorthands.json`. Everything else in credo works the same without it, and in other harnesses.

- Line 1: `◆ credo` and the item count per status, short (`go: 12`) or long (`Go(go): 12`); colored per group (open yellow, blocked red when non-zero, finished green, parked gray), zero dimmed, 2 spaces inside a color group and 4 between groups, packed by hand to the band width. A count change flashes for 6 s (fuchsia for moves, white for pure creations) and raises a toast. Exit 4 from the counts script (no credo project) hides the band.
- Line 2: the session mode/role (cyan), the open test/question letters (🧪 / ❓) parsed from the language-neutral footer of the last main-loop answer (`**🧪: C, D** · **❓: Y**`; the older word labels `Open for testing:` / `Open questions:` and their German forms are still read), and the buttons `☰ items` (`i`), `? help` (`h`), `⇆` (`l`, short/long form) and `◐ <preset>` (`e`, rotating `all` / `no parked` / `open + dogma` / `open only`).
- Line 3, only while this session's autonomy runs: `⟳ auto 5h <now>%→<next rung>  wake HH:MM` (red once the 5h figure reaches the fourth ladder rung).
- Items and help share one pane (`credo-panel`, also opened by `/credo-items`): per status the total and the newest 15 items, or the cheatsheet; one line per entry, truncated at the end.
- The prompt hint gets `Shortcuts: <keys not visible in the band>`; with the long form on, each as `key(word)`.
- Refresh: on session start, after Bash tool calls, on turn end and every 10 s. The preset is the state value `{ plugin: 'credo', key: 'preset' }`, which the dogma band reads to hide itself at `open only`.

## 3. The `.credo/` structure

`scripts/credo-init.sh` creates this tree in the target repo (idempotent) and adds the git-exclude lines:

```
.credo/
  docs/                stable "how we work here" conventions
  screenshots/         visual-verify evidence: <task>-<viewport>-<YYYY-MM-DD>.png (a PostToolUse hook files screenshots here automatically, even from a hub)
  items/
    1_todo/{1_clarify,2_go,3_blocked}
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
builtin (templates/config.default.yaml) < global (~/.claude/credo/config) < profile ($CLAUDE_CONFIG_DIR/credo/config) < project (.credo/config)
```

`credo-config.sh paths` lists the layers for the active profile, `credo-config.sh source <key>` names the layer and file that supplies a key (e.g. `source budget.schedule` -> `global: ~/.claude/credo/config`). On the default profile (`~/.claude`, `CLAUDE_CONFIG_DIR` unset) the global config is the profile config; there is no separate profile layer.

The builtin template holds universal defaults only:

- `verify.viewports`: 320, 768, 1440
- `windows.veto_minutes`: 20, `windows.deferred_question_minutes`: 5
- `compact.thresholds`: 80, 92 (percent of the way to auto-compact - the tacho, not the full window; matches limit v2.32.0)
- `wakeup.reset_offset_minutes`: 5, `wakeup.fallback_offset_minutes`: 1
- `budget.*`: the 5-hour soft/hard band, the work-hours 09:00 guard reserve, task-sizing bands, and the day-by-day cap schedule
- `budget_failsafe`: absolute caps used if an explicit order is lost to a compact

Personal fields under `personal:` (ntfy topic, commit-identity hint, WSL `lan_ip` plus an `endpoints[]` list of `{name, port, reach}`, living-docs list) ship empty. They are filled just-in-time by the skill that needs them, with permission per change. `/credo:setup` can pre-initialize the global config.

### 3.2 Deterministic id-counter

`scripts/credo-id-next.sh` owns id allocation. The counter file is the monotone issuing point and holds the last id given out. Allocation is atomic under flock: read the counter (0 if empty, missing, or non-numeric), scan the items tree for the highest existing id, take `base = max(counter, scan)`, write `base + 1`, print it. The counter, not the folder, decides the number, so deleting the highest item does not lower the next id and a deleted id is never reused. The folder scan is a safety floor, not the source of the id: it only lifts a counter that fell behind the items on disk (merge, clone, backup restore, sync), and when it reconciles up it warns on stderr while stdout stays the bare id. Never derive an id from folder contents by hand; always call the helper.

### 3.3 Project resolution (hub-aware)

The PROJECT layer (`.credo/`, config, items) is resolved by one shared function, `scripts/credo-config.sh resolve-project`, used by `credo-init.sh` (where to create/operate) and `check-setup.sh` (reporting). This is separate from the AUTONOMY layer, which is HOME-global keep-alive state and is never affected by project resolution. Precedence:

1. `CREDO_DIR` env (explicit) - use it.
2. Session pin, if set and resolvable - use it (see below).
3. cwd git-toplevel (or cwd if not in a repo):
   - if that directory's OWN project config (`<dir>/.credo/config`) has `hub: true` - it is a launch hub, so credo does NOT auto-target it and signals "needs explicit target";
   - else if `<dir>/.credo/` already exists - use it (established project);
   - else (a new `.credo` would be created and no explicit target was given) - signal "needs explicit target".

The `hub` flag is read from the PROJECT layer file directly (that dir's `.credo/config`), never the merged cascade, so a global default can never mark every directory a hub.

`resolve-project` prints the target `.credo` directory and exits 0, or prints nothing and exits 4 ("needs explicit target", distinct from the 1/3 codes of `get`). When it signals 4, `credo-init.sh` creates nothing and exits 4 with an actionable message; this is fail-safe and non-interactive-safe (it fails rather than creating `.credo/` in the wrong place). The config-READ path (`get`, `backend`) is unchanged and still falls back to the builtin defaults for the normal case.

**Session pin (`/credo:project`).** When the shell cwd is a launch hub rather than the repo you are working on, pin the real target with `/credo:project <abs-path>`. This mirrors the session-mode mechanic: `hooks/session-project-set.sh` writes the absolute repo path atomically to a file keyed by session_id under `${CREDO_SESSION_PROJECTS_DIR:-$HOME/.claude/credo/session-projects}/<session_id>`. The session_id is resolved as arg > `$CREDO_SESSION_ID` > `$CLAUDE_CODE_SESSION_ID`. The resolver reads the pin as layer 2; a missing or unresolvable pin never errors the resolver, it just falls through to layer 3. `/credo:project` without an argument reports the resolved target and whether the cwd is a hub. Mark a hub by setting `hub: true` in that directory's own `.credo/config`.

## 4. Session modes: how-to

Set the mode with a command; it also loads the matching skill.

- `/credo:session-active` - intensive live collaboration, user at the keyboard, no keep-alive.
- `/credo:session-passive` - agent carries most work, user reachable for clarifications only, no keep-alive.
- `/credo:session-autonomous` - approved GO items worked unattended, hook-enforced keep-alive (a registered `Stop` hook blocks a stop with no scheduled `ScheduleWakeup` and instructs the model to set one), budget caps enforced, ntfy per task and question, progress secured via compact-plus.

The active skill defines the common core shared by all three; passive and autonomous layer their differences on top. On every prompt the inject line reminds you of the current mode, so it cannot be silently forgotten.

Honest note on keep-alive: autonomous mode sets the session's autonomy flag, and a registered `Stop` hook (`credo-autonomy-keepalive.sh`) enforces the keep-alive discipline - if you try to end the turn without a marked self-wake, it blocks the stop and instructs you to call `ScheduleWakeup` now; the registered `UserPromptSubmit` hook (`credo-autonomy-clear.sh`) turns autonomy off on any real user message (section 2.1). This is enforcement of the nudge, not a guarantee of infinite wakefulness: the hook forces the block plus instruction, but staying awake still depends on the model then calling `ScheduleWakeup`. It is loop-safe (at most one forced continuation per stop attempt, via the `stop_hook_active` guard) and completely inert outside autonomous mode.

Autonomy state is per session, exactly like modes and roles: `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/credo/autonomy/<session_id>/` holds `active` (autonomy on), `paused` (hard opt-out, Stop hook inert) and `wake-scheduled` (Unix timestamp of the next marked self-wake); `CREDO_AUTONOMY_DIR` overrides the base dir. The session_id comes from the hook stdin JSON in hooks, and from an explicit argument, else `$CREDO_SESSION_ID`, else `$CLAUDE_CODE_SESSION_ID` in the helper scripts. Autonomy in one session never affects another: the keep-alive, the 5h budget guard and the autonomous re-injects act only on the session whose flag is set, and an autonomy-off or a user message in one session never ends another session's run. Scripts that write the state (`credo-autonomy-on.sh`, `credo-autonomy-off.sh`, `credo-autonomy-wake-mark.sh`, `credo-autonomy-clear.sh`) refuse with an error and write nothing when no valid session_id resolves; hooks that only read it treat an unknown session as not autonomous. The former global files `~/.claude/credo-autonomy-active`, `credo-autonomy-paused` and `credo-wake-scheduled` are no longer read or written (a leftover copy is harmless and can be removed by hand).

**Mode awareness.** credo injects the current local date and time on every prompt (the `credo-datetime-inject.sh` hook, section 2.1), independent of session mode, so the agent is date/time-aware and can compare successive timestamps to sense how long ago the last user prompt was. Three behavior rules build on this: (1) when no mode is set, the agent infers a fitting presence mode and proposes it via the Ask tool rather than adopting one silently - autonomous is never inferred or auto-set, only entered via `/credo:session-autonomous` or on an explicit request; (2) the agent mentions the active mode in normal output from time to time, especially after a large time gap - a lightweight, behavior-based nudge, not a guaranteed timer; (3) in autonomous mode this is switched off: an autonomous run is NEVER interrupted by an Ask about a mode change, even if the user keeps prompting - a switch happens only on an explicit user instruction. The suggestion cadence is gentle (session start or when the work clearly implies a mode), never per turn.

## 5. The item workflow: how-to

**Task backend (`.credo/config: task_backend`).** credo's item model is the default task system, but it can stand down in favour of get-shit-done. It is config-driven: set `task_backend` in `.credo/config` (via the config cascade builtin < global < project) to `credo` (default), `gsd`, or `none`. The `CREDO_TASK_BACKEND` env var overrides the config when set and non-empty. Anything unset, empty, or unknown behaves like `credo`, so the default behaviour is unchanged, and any resolution error falls back to `credo`. `/credo:setup` writes `task_backend: gsd` for you when you choose GSD.

- `credo` (or unset / `none`) - the item lifecycle below is active. `credo-init.sh` creates the `items/` tree and id-counter, and the subagent priming tells delegated agents to record and gate work as credo items.
- `gsd` - the credo item model stands down: `credo-init.sh` skips the `items/` tree and id-counter, the subagent priming drops the item/audit sentence, and the items/audit/verify skills note that they do not gate credo items. GSD's phases own task tracking; set this when you run GSD as the task system so there is no `.credo/items/` vs `.planning/` double-bookkeeping. The operating layer (session modes, budget, safety, verify, subagent priming) stays on regardless.

The rest of this section describes the `credo` backend.

1. Get an id: `scripts/credo-id-next.sh`.
2. Copy `templates/item.template.md` to `items/1_todo/1_clarify/<id>-<slug>.md`. Fill the mandatory frontmatter: `id`, `title`, `created`, `type`, `ui`. Items from the user's own words are human-owned (`clarify_owner: human`, or leave it out - missing means human); items a builder, plan or task agent creates (slices, follow-ups, build questions, audit findings) get `clarify_owner: agent` plus `parent: <id>`.
3. Capture the requirement verbatim and draft observable success criteria (the Definition of Done). For an algorithm, a detection, or a quality or numeric result, add the acceptance measurement (data set + target value) before the build.
4. On a GO, move to `items/1_todo/2_go/` (`scripts/credo-item-move.sh`). Who gives the GO depends on the owner (see "Who decides" below): a human-owned item only on the user's explicit GO - the helper refuses unless the History has a `(GO: <user quote>)` line or the main agent passes `--user-authorized`, from any source folder; an agent-owned item also on the agent decision rule, logged as `(GO: agent per SOTA rule, <reason>)`. On entry the helper sets `clarify_owner: agent` and keeps the origin in the History. Entry is a gate (G1-G6): a provable item-scoped GO, no deferred/FUTURE marker, no hard dependency on an unbuilt item, no open clarify section, no open build-details, and a sweep cross-check against the folder listing. An item in `2_go` is buildable by definition (go=go): the building agent never self-skips or self-demotes it for size, UI, or verifiability - it may re-scope or phase, but it builds. `credo-item-move.sh go` refuses a human-owned item without a user GO and warns where a GO-citation is missing but not required.
5. If a GO'd item is hard-blocked by another, still-unbuilt credo item, move it to `items/1_todo/3_blocked/` (`credo-item-move.sh blocked`, requires a `blocked_by`). It auto-returns to `2_go` when the blocker reaches `2_done`. "Too big / too hard" is never a block.
6. Build, wiring the new code so a caller reaches it. Record what was built with file:line references. Before reporting done, the builder tries to break its own work and lists what it tried, and measures a tricky item against its acceptance measurement.
7. Run the Definition of Done gate (section 5.1). On pass, move to `items/2_done/`. The move (like one to verified or archived) also cleans up merged and clean worktrees per the DOGMA-PERMISSIONS checkbox `clean up merged worktrees automatically` (`[x]` remove, `[?]` or missing: ask, `[ ]` never) via `credo-worktree-cleanup.sh`.
8. Only the user moves an item to `items/3_verified/`.

Parked work goes under `items/parked/{hold,future}` (external / not-GO'd blocks); abandoned work under `items/4_archived/`.

**Ask discipline (presence modes).** When clarifying items or proposing a GO in an active or passive session, handle one item per Ask round: explain the single item with concrete examples and consequences, then put its questions and GO proposal into its own Ask round, one round per item id. Do not bundle several items into one message or a flowing-text dump. Within a single round, asking several independent questions at once is fine and encouraged; a question whose framing depends on another answer goes into a later round. This does not apply in autonomous mode (no interactive Ask rounds). The rule lives in the common core (session-active skill).

**Who decides (clarify owner).** The default is to build everything as well as at all possible (state of the art), else best effort; only what is infeasible or would really not be good is noted and presented to the user. Effort or size never counts against an item: feasible = GO.

- Human-owned clarify items are always clarified with the user. The agent recommends (Recommended option first); the user decides and gives the GO.
- Agent-owned items (and every item in `2_go`): the plan agent decides uncritical questions itself - or, with no known plan agent peer, the executing agent in a temporary pseudo plan role, without changing its real role. Each decision is logged in the item History and named in the next reply or report, so the user can veto it.
- Always the user's call: anything infeasible or really not good, the user's taste or preference, deleting user data, installs, money, the hard safety rules, and any question that would change or narrow the user's verbatim requirement.
- Interactive modes decide the uncritical questions and ask the rest via the Ask tool; autonomous mode decides the uncritical questions and parks the rest for the end-of-run report.

The full rule is in the `items` skill ("Clarify owner and the agent decision rule").

**Fix rounds.** After an audit with a MAJOR or FAIL that the auditor does not fix itself, a fresh fix agent gets only the findings, the branch state and the test commands - never the builder's resumed context. After 2 FAIL audits of the same item there is no third fix round by default: the item is stopped and re-cut smaller or sent back to clarify; the user may raise this limit per item. When cutting parallel batches, central registry files are shared surfaces; prefer fragment files such as `changelog.d/` (`orchestration` and `audit` skills).

### 5.1 Definition of Done gate

An item may enter `2_done/` only when all hold:

- success criteria are observably met and the code is wired in,
- a dedicated audit subagent (not the builder) reviewed the work against its requirement and Definition of Done and returned a pass,
- for `ui: true`, a visual verify drove the real surface in a browser across the configured viewports and captured screenshot evidence under `.credo/screenshots/`,
- docs were updated in the same change.

Tests only a human can run do not block this gate: they are written into the done item as `human-only: pending` with what to check, and the user runs them in the verify phase (`2_done` -> `3_verified`). A check the agent can run itself is never human-only.

### 5.2 Chat shorthands

The `SessionStart` hook injects a small legend so the agent understands the user's chat shorthands without any line in the user's own `CLAUDE.md`. It fires on every start (`startup`, `resume`, `clear`, `compact`, `fork`), so it survives compaction, and it is pure user-intent parsing rather than workflow: it applies in every directory (credo active or not, hubs, no `.credo/`, `/credo:disable`d dirs, `gsd` backend). Each shorthand refers to what precedes it and has a general meaning first, plus the credo-item mapping:

- `dd` - done. `<thing> dd` = that thing is done, bare `dd` = the last discussed or requested thing, `cc-up dd` = the update is done. On a single Definition of Done point it ticks only that point, never the whole item. A named credo item (`#123 dd`) goes through the normal Definition of Done gate (section 5.1) and on a pass moves with `credo-item-move.sh 123 done`; the shorthand is the user's statement, never a gate bypass - a failing gate is reported instead of moving.
- `vf` - verified or verify, by context. In a manual test round where the user was asked to check something: checked and passing. The scope is exactly what it refers to: a single Definition of Done point is ticked as verified and the item stays; only the whole item under test (`#123 vf`) moves via `credo-item-move.sh 123 verified --user-authorized` (main agent only). Otherwise: verify for real with runtime proof, not code review (credo verify skill via subagents). Unclear which? The agent asks briefly.
- `cf` - start or continue a clarify round: structured questions until the open points are resolved (in credo: the `1_clarify` items, one per Ask round, or the named one, `#57 cf`).
- `go` / `bk` / `pk` / `ar` - item moves, valid only right after an item ref (`#57 go`); bare they are ordinary words. `#N go` = the user's GO approval (a `(GO: <quote>)` History line, then `credo-item-move.sh N go` once the GO entry gate G1-G6 passes; a failing gate is reported, never bypassed), `#N bk` = block (ask for the concrete blocker if unnamed, `blocked_by` is mandatory), `#N pk` = park on hold, `#N pk future` = park for later, `#N ar` = archive.
- `???` - explain the pointed-at thing in depth: What / Why / Example / Consequences (explain skill, same as `/credo:explain`).
- `cc-up` - the user fully updated Claude Code (plugins and marketplaces fetched and installed, `/reload-plugins`, full quit and restart, possibly resumed). The running state is current; taken at face value, never doubted, no request for steps or proof. Also valid in passing.
- `cm` - commit, per the repo's commit rules, no push.
- `ph` - commit and push, per the repo's rules (push only where they allow it).
- `exclude` / `excluded` - always the local `.git/info/exclude`, never `.gitignore`; only `ignore` / `ignored` / `gitignore` means `.gitignore`.
- Test/question letters - every manual test and every question gets a letter from one continuous sequence shared by both (A..Z across replies, wrap after Z) under a visible `### 🧪 B) <topic>` / `### ❓ Y) <topic>` heading; answer with `B vf`, `B2 vf`, `Y: ...`; each reply ends with the open letters in bold; the next free letter survives a compact (details: `verify` skill, "Test and question letters").
- `#N` vs `§cct_N` - `#N` is reserved for real items (credo items, issues, PRs, tickets); harness task entries and any other numbering are `§cct_N` (e.g. `§cct_2`), in both directions (`§cct_2 dd` = harness task 2 done).

### 5.3 Optimisation audit (opt-in)

`/credo:optimize` (skill `optimize`) audits how the repo is organised and worked on, and offers improvements one by one. credo offers it, never forces it.

- **Opt-in.** Asked once per repo (and per profile), together with the credo onboarding question, in `/credo:setup` Step 2c, in `/credo:session-init`, or by `credo-optimize-hook.sh` on the next fresh start where credo is already active. Nothing is scanned before the answer. Yes runs it now; No means manual only. Stored by `credo-optimize-state.sh optin`.
- **Returners only.** With Yes, the audit is offered again only when the repo has been idle for `optimize.idle_days` (default 7, wall-clock): credo's per-repo last-seen (updated on every prompt), the newest reflog entry (mtime of `logs/HEAD`), the mtime of the index, and the newest mtime of the files `git status --porcelain` lists as modified or untracked must all be older (`credo-optimize-idle.sh`; `git status` runs with `GIT_OPTIONAL_LOCKS=0` and after the index is read, so the check never refreshes the index). Evaluated at `SessionStart` before last-seen is updated; the offer is marked pending and asked once (`credo-optimize-state.sh offered` after any answer); in autonomous mode it stays pending.
- **Freshness.** `credo-optimize-fresh.sh` runs before every audit: default branch, `git fetch`, behind count. Stale -> the agent proposes `git switch <default>` / `git pull --ff-only` and runs them only with consent; a failed fetch makes freshness unknown. An audit of a stale state runs only on the user's explicit request.
- **Scan and result.** A read-only subagent scans conflict hotspots, changelog fragments, the test-stage convention, dogma settings (suggestions passed to `/dogma:permissions`), parallelism readiness and - only after a separate yes - instruction consistency (contradictions between the global and repo instruction files, plugin-injected texts and credo), always detecting existing conventions first. The report goes to `.credo/process/reports/optimize-<YYYY-MM-DD>.md`; each finding is offered as Implement / Later / Never; larger accepted findings become items, Never is remembered per repo and finding id (`credo-optimize-state.sh never-add`).

## 6. Capturing recurring workflows into skills

When the same ordered, multi-step workflow recurs in a session, the `skill-capture` skill can turn it into a reusable Claude Code skill. It adds no infrastructure - it is behavior plus two Markdown files.

- **Detection** - heuristic and in-session only: the same multi-step sequence (same ordered steps or commands, small variation allowed) run about three times in the running session. There is no persistent counter and no tracking backend; detection resets with the session.
- **Mode gating** (mirrors the audit nit-disposition policy): in **autonomous** mode a skill is NEVER built - the run only appends a candidate note to `.credo/skill-candidates.md` and keeps working (a skill needs an explicit GO an autonomous run cannot give). In **active / passive / default** mode the pattern is explained and the capture is proposed via the Ask tool; the skill is built only on an explicit GO.
- **Location** - a generated skill goes on a real discovery path so Claude Code finds it: `<repo>/.claude/skills/` for a repo-specific workflow, `~/.claude/skills/` for a generally useful one. Scope is derived from the workflow and confirmed via Ask. A plain `.credo/skills/` folder is NOT a discovery path, so generated skills never live there.
- **Origin marking** (all three): a `credo-<name>` name prefix, an `origin: credo-repetition` frontmatter marker plus a one-line dated body note, and a register line in `.credo/generated-skills.md`.
- **Two `.credo/` files** (append-only, created on first use, git-excluded like the rest of `.credo/`): `.credo/generated-skills.md` registers skills that were BUILT; `.credo/skill-candidates.md` records patterns that were SEEN but not built. Autonomous mode writes candidates; active / passive read them at session start and gently offer the open ones (analogous to the soft old-item reminder), then append a resolution line - built or discarded - to close each out.

## 7. Skills reference

- **audit** - quality gate against requirement and Definition of Done; read-only severity-ranked judgement, after which the fresh auditor may fix small findings on the item's worktree branch. `full` by default, `lean` (diff plus tests) only for small low-risk items. Mandatory before `2_done/`.
- **diag** - read-only root-cause diagnosis at file:line; the fix is a separate GO-gated step.
- **verify** - visual verification as Definition of Done for any runtime surface; real browser, computed layout.
- **items** - the folder-is-status work-item model gated by the Definition of Done.
- **optimize** - the opt-in optimisation audit: freshness check, read-only scan, report, findings offered as Implement / Later / Never. See section 5.3.
- **requirements-verbatim** - append-only verbatim capture of requirements, decisions, approvals, GOs.
- **budget** - API budget caps and reset rules for the 5-hour and weekly limits, plus the commit-identity gate.
- **compact-plus** - secures approved work before a compaction and reports whether it is safe; does not run `/compact`.
- **orchestration** - safe, efficient delegation to subagents (count, disjoint files, monitoring, inherited security, return-and-resume) and the measured default batch workflow: plan once per batch, 3-4 single-item builders plus 1 bundle builder in worktrees, a fresh audit per item, one release per batch with one full test suite; a fresh fix agent after a failing audit and an emergency brake after 2 FAIL audits of the same item.
- **safety** - hard filesystem-protection and no-autonomous-installs rules; highest priority.
- **cross-cutting-checklist-generator** - detects scattered concerns and auto-generates a project-local checklist.
- **skill-capture** - turns a workflow that recurs ~3x in a session into a reusable skill; heuristic and in-session (no counter, no backend), mode-gated (autonomous only notes a candidate, presence modes propose via Ask and build on GO). See section 6.
- **wsl-env** - reach Windows-side services, processes, and launchers from WSL; self-detecting.
- **session-active / session-passive / session-autonomous** - per-mode behavior; the active skill holds the shared core.

## 8. Dependencies (honest)

### 8.1 `limit` plugin - recommended prerequisite

Required for two features:

- **Context-percent triggers.** Auto-running compact-plus at the session-context fill thresholds relies on the limit plugin's inject hook. Point it at credo:
  - `CLAUDE_MB_LIMIT_COMPACT_SKILL=credo:compact-plus`
  - `CLAUDE_MB_LIMIT_INJECT_THRESHOLDS=80,92`
  - `/credo:setup` offers to set these for you (Step 9, when the limit plugin is present); the manual values above still apply if you do not run setup.
- **Budget data.** The budget skill reads the limit cache (`/tmp/claude-mb-limit-cache_*.json`) via `scripts/credo-budget-read.sh` for the 5-hour and weekly utilization and reset times. That helper exits with a distinct code when no fresh cache is present.

Without the `limit` plugin these features are silently unavailable. No error is raised; credo just does not run logic that has no data.

### 8.2 `ntfy` - optional

Push notifications use `ntfy`. The topic is `personal.ntfy_topic` in the credo config. Unset means ntfy is silently skipped. Nothing else depends on it.

## 9. Testing conventions

Every hook, state, and config mechanism is testable against a temporary HOME (for example `HOME=$(mktemp -d) bash hook.sh`) so tests never touch the real `~/.claude`. Hooks are failure-safe: any error exits 0 with no output and never blocks a prompt or a subagent.
