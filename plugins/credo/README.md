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
| `/credo:migrate` | Migrate an existing repo into the `.credo/` structure |
| `/credo:project` | Pin the target repo for credo's project layer (hub-aware), or show the resolved target |
| `/credo:session-init` | Load the main-agent delegation-first workflow instructions |
| `/credo:session-active` | Set the session mode to active |
| `/credo:session-passive` | Set the session mode to passive |
| `/credo:session-autonomous` | Set the session mode to autonomous |
| `/credo:role-task` | Set this session's default role to task/build (owns implementing GO items incl. commits/push per dogma) |
| `/credo:role-plan` | Set this session's default role to plan/clarify (owns clarifying 1_clarify items, no commits/push) |
| `/credo:role-clear` | Clear this session's default role (back to no role; the agent does everything) |
| `/credo:sandbox-promote` | Promote an accepted sandbox artifact from `.credo/sandbox-tmp/` to `.credo/sandbox/` |
| `/credo:explain` | Explain something in depth (what/why/example/consequences) |
| `/credo:optimize` | Run the opt-in optimisation audit for this repo (read-only scan, findings offered one by one) |
| `/credo:disable` | Disable credo for this directory (silence onboarding and the [credo] line here, reversible) |
| `/credo:enable` | Enable credo for this directory (opt in; overrides a previous decline) |

Skills and hooks are auto-discovered by Claude Code from the `skills/` and `hooks/` directories, so they are not hand-listed in the manifest.

## Session modes

The mode is per session and set with a command. It is stored on disk keyed by the session id, so it survives compaction, new sessions, and subagents. The `UserPromptSubmit` hook re-injects a one-line reminder of the active mode on every prompt, and names the matching skill to load. A second hook injects the current local date and time (mode-independent) - on every prompt via `UserPromptSubmit`, and additionally on `PostToolUse` (throttled + delta-guarded) so the clock stays fresh during long autonomous runs instead of freezing at the last prompt. This keeps the agent date/time-aware: when no mode is set it proposes a fitting presence mode via Ask (never autonomous, never silently), and it mentions the active mode in normal output now and then, especially after a long gap since the last prompt. An autonomous run is never interrupted by a mode-change question.

A third `UserPromptSubmit` hook (`credo-skill-nudge.sh`) re-surfaces a single low-cadence self-assess reminder, because the SessionStart knowledge list ages out over a long session and the credo skills get underused. It never forces a skill: the agent is asked to judge by effort and risk and actively use the fitting credo skill (diag / verify / audit / items / requirements-verbatim) on non-trivial or complex work, and skip it on small or trivial changes. It fires in all credo modes. Toggle with `CREDO_SKILL_NUDGE` (default true) and set the cadence with `CREDO_SKILL_NUDGE_EVERY` (default 5); the fire slot is offset by half the window from `credo-attended-reminder.sh` so the two reminders never stack in the same turn.

A `SessionStart` hook makes the session credo-aware. Until the session has made a credo decision, and only on a human-present (re)start (`startup`/`clear`), it asks - via Ask - whether to use the credo workflow (yes runs `/credo:session-init`, no records a marker so it never asks again); it never asks in autonomous work, nor on `compact`/`resume`/`fork`. Once credo is active, the same hook re-injects the full credo command + skill list on every start (including after a compact, when the model context is gone), tagged by execution class so it is clear which commands the agent may run itself, which need the user, and which it must never trigger autonomously. The activation ASK can be turned off on its own with `CREDO_SESSION_START_ASK=false` (the whole hook with `CREDO_SESSION_START_INJECT=false`), and when the task backend is `gsd` the workflow text stays silent, since GSD is then the task system rather than credo. The same hook always appends a compact user-shorthand legend (see [Chat shorthands](#chat-shorthands)) - in every state, including declined or `/credo:disable`d directories and the `gsd` backend.

- **active** (`/credo:session-active`) - intensive live collaboration with the user at the keyboard. Progress is logged via the limit thresholds and compact-plus, open GO items are picked up alongside, clarifications happen during subagent waits. No keep-alive.
- **passive** (`/credo:session-passive`) - the agent carries most of the work while the user is reachable only for clarifications. Every item is pushed toward a full GO; less is more, so only genuinely ambiguous items go back to the user. No keep-alive.
- **autonomous** (`/credo:session-autonomous`) - approved GO items are worked unattended. Keep-alive is hook-enforced: a registered Stop hook blocks a stop that has no scheduled ScheduleWakeup and instructs the model to set one (loop-safe, and inert outside autonomy); a registered UserPromptSubmit hook turns autonomy off on any real user message. Budget caps are enforced, ntfy sends immediate come-to-PC pushes (questions, blockers, completion) plus a mandatory content-rich progress digest on a fixed interval, and progress is secured via compact-plus.

Each command sets the mode and loads its skill. The three session skills share one canonical common core (defined in the session-active skill) and layer their mode-specific rules on top.

### Session roles

Orthogonal to the mode, a session can carry a persistent default role that scopes which part of the item lifecycle it owns. Like the mode, the role is stored on disk keyed by the session id, so it survives compaction and new prompts.

- **plan/clarify** (`/credo:role-plan`) - owns clarifying `1_clarify` items; it does not commit or push.
- **task/build** (`/credo:role-task`) - owns implementing GO items, including commits and push per dogma.
- **none** (`/credo:role-clear`) - clears the role, back to no role, so the agent does everything.

## Chat shorthands

credo teaches the agent a few short chat shorthands, so you can type them without adding anything to your own `CLAUDE.md`. The `SessionStart` hook injects a small legend on every start (`startup`, `resume`, `clear`, `compact`, `fork`), so it survives compaction. It is pure user-intent parsing, not workflow: it applies in every directory - credo active or not, hub directories, directories without `.credo/`, and directories silenced via `/credo:disable`. Each shorthand refers to what precedes it and has a general meaning first, plus a credo-item mapping when an item is named.

| Shorthand | Meaning |
|-----------|---------|
| `dd` | Done. `<thing> dd` = that thing is done; bare `dd` = the last discussed or requested thing is done; `cc-up dd` = the update is done. On a single Definition of Done point, `dd` ticks only that point, never the whole item. For a credo item (`#123 dd`) the agent runs the normal Definition of Done gate (audit, plus verify for `ui: true`) and on a pass moves it with `credo-item-move.sh 123 done`. The shorthand is your statement, never a gate bypass: if the gate fails, the agent reports instead of moving. |
| `vf` | Verified or verify, by context. In a manual test round where you were asked to check something, `vf` means you checked it and it passes. The scope is exactly what it refers to: on a single Definition of Done point only that point is ticked as verified and the item stays where it is; only when the whole item was under test (`#123 vf`) does it move to `3_verified/` via `credo-item-move.sh 123 verified --user-authorized` (main agent only). Otherwise it is an instruction to verify for real with runtime proof, not a code review (in credo: the verify skill, via subagents). If it is unclear which is meant, the agent asks briefly. |
| `cf` | Start or continue a clarify round: structured questions until the open points are resolved. In credo: the `1_clarify` items, one item per Ask round, or the named one (`#57 cf`). |
| `go` / `bk` / `pk` / `ar` | Item moves, valid only right after an item ref (`#57 go`); bare they are ordinary words. `#N go` = your GO approval: the agent adds a `(GO: <your words>)` line to the item History and moves it to `2_go` if the GO entry gate (G1-G6) passes, otherwise reports why not. `#N bk` = block it: the agent asks for the concrete blocker if you did not name one (`blocked_by` is mandatory) and moves it to `3_blocked`. `#N pk` = park on hold, `#N pk future` = park for later. `#N ar` = archive. All moves go through `credo-item-move.sh`. |
| `???` | Explain the thing it follows (or the last thing, when alone) in depth: What / Why / Example / Consequences. Same behavior as `/credo:explain`. |
| `cc-up` | You fully updated Claude Code (plugins and marketplaces fetched and installed, `/reload-plugins`, full quit and restart, possibly resumed). The running state is current; the agent takes this at face value and never asks for update steps or proof. Also valid when mentioned in passing. |
| `cm` | Commit, following the repo's commit rules. No push. |
| `ph` | Commit and push, following the repo's rules (push only where they allow it). |
| `exclude` / `excluded` | Always the local `.git/info/exclude`, never `.gitignore`. Only `ignore` / `ignored` / `gitignore` means `.gitignore`. |
| `#N` vs `§cct_N` | `#N` only for real items (credo items, issues, PRs, tickets). Claude's harness tasks and any other numbering are `§cct_N` (cct = Claude Code task, e.g. `§cct_2`), so the two never get confused. `§cct_2 dd` = harness task 2 done. |
| Test/question letters | Every manual test and every question to the user gets a letter from one continuous sequence shared by both (A..Z across replies, wrap to A after Z), under a visible heading `### 🧪 B) <topic>` (test, numbered steps, 1-2 items per round) or `### ❓ Y) <topic>` (question). Answer with `B vf`, `B2 vf` (step 2 of B) or `Y: ...`. Each reply ends with the open letters in bold (`**Open for testing: C, D** · **Open questions: Y**`); the next free letter survives a compact via the handoff. |

Turn off only the legend with `CREDO_SESSION_START_SHORTHANDS=false`; `CREDO_SESSION_START_INJECT=false` silences the whole hook, legend included.

## The `.credo/` structure

`scripts/credo-init.sh` creates a per-project `.credo/` tree in the target repo (idempotent) and adds the git-exclude lines so `.credo/**` is not committed by default (except `RULES.md`, see below). The layout:

```
.credo/
  docs/                stable "how we work here" conventions
  screenshots/         visual-verify evidence: <task>-<viewport>-<YYYY-MM-DD>.png (a PostToolUse hook files screenshots here automatically, even from a hub)
  items/
    1_todo/{1_clarify,2_go,3_blocked}
    2_done/
    3_verified/        human-authorized; agent files here only on your explicit instruction
    4_archived/
    parked/{hold,future}
  process/
    requirements/      append-only verbatim log
    handoffs/          rolling HANDOFF.md plus handoffs/archive/
    reports/           diag / audit / verification reports
  checklists/          auto-generated cross-cutting checklists
  config               per-project config (YAML)
  id-counter           deterministic integer counter
  RULES.md             per-repo special rules (grants); versioned by default
```

`.credo/**` is deliberately kept out of git, with ONE exception: `RULES.md` (per-repo special rules) is versioned by default, because those rules are meant to travel with the repo. Everything else's persistence across a compact is disk plus your normal backups, not commits.

**Opt-in versioning (per project).** The default (all of `.credo/**` excluded except `RULES.md`) is right for solo or private work. If you want the items and process visible in the team's history, run `credo-init.sh` with `CREDO_VERSION_TRACKED=1`: it then versions `.credo/**` in the repo except the per-project `config` and the `screenshots/`, which stay local always. The exclude entries are kept in a marker-delimited managed block in `.git/info/exclude`, so re-running switches the mode cleanly in either direction (drop the variable to go back to fully unversioned). This is a deliberate per-project decision; the default is unversioned.

### Config cascade

Config is YAML, merged lowest to highest:

```
builtin (templates/config.default.yaml) < global (~/.claude/credo/config) < profile ($CLAUDE_CONFIG_DIR/credo/config) < project (.credo/config)
```

The builtin template ships universal, safe-for-everyone defaults (viewports 320/768/1440, timing windows, the compact thresholds 80/92, the budget schedule, wakeup offsets). On first need the global config is created from this template. Personal and environment-specific fields (ntfy topic, commit-identity hint, WSL reachability, living-docs list) are intentionally left empty and are filled just-in-time by the skill that needs them, with permission per change. `/credo:setup` is an optional way to pre-initialize this.

The **profile layer** sits between global and project: `$CLAUDE_CONFIG_DIR/credo/config` (for example `~/.claude-private/credo/config`) lets a second Claude Code profile override the shared global per key, while every key it does not set still falls back to global. It is optional and never auto-created; for the default profile it equals global and is skipped. Session state (modes, decisions, project pins) and the autonomy flags likewise follow the active profile, so two profiles run side by side without sharing state.

### Deterministic id-counter

Item ids come from `scripts/credo-id-next.sh`. The counter file holds the last id given out; allocation is atomic (flock): read the counter, scan the items tree, take `max(counter, highest existing id) + 1`, write it back, print it. The counter, not the folder, decides the number - deleting the highest item never lowers the next id, so a deleted id is never reused; the folder scan is only a safety floor that lifts a counter which fell behind the items on disk (merge, clone, backup restore, sync) and warns on stderr when it does. Always take an id from the helper; never hand-pick one.

## The item workflow

A work item is one Markdown file (`templates/item.template.md`). Its frontmatter is lean and mandatory: `id`, `title`, `created`, `type` (bug | optimization | feature | question | chore), and `ui` (true means a visual verify is part of the Definition of Done). The optional `audit: full` forces the full audit tier (see Audit depth). There is no status field, because the folder is the status.

The lifecycle, moving the file with `scripts/credo-item-move.sh`:

1. **clarify** (`items/1_todo/1_clarify/`) - requirement captured verbatim, success criteria drafted.
2. **go** (`items/1_todo/2_go/`) - the user gave an explicit GO; ready to build. Entry is gated (G1-G6): only a fully clarified, GO'd item with no open build-details or unbuilt-item dependency may enter. Once here it IS buildable by definition (go=go): the building agent never self-skips or self-demotes it for size, UI, or "not sure it is verifiable". A stale-looking body is likewise never a reason to self-skip or demote a `2_go` item (body-freshness invariant). The one sanctioned way back is the **Named-Decision-Test**: a genuine user-only decision surfacing mid-build sends the item to `1_clarify` marked URGENT - never "too big / too hard".
3. **blocked** (`items/1_todo/3_blocked/`) - GO'd but hard-blocked by another, unbuilt credo item (structured `blocked_by`/`blocks` relations). Auto-returns to `2_go` when the blocker is done. Distinct from `parked/hold`, which is for an external dependency. "Too big / too hard" is never a block.
4. **done** (`items/2_done/`) - built and wired, and the Definition of Done gate has passed. A move to done (or verified / archived) also cleans up merged and clean worktrees per DOGMA-PERMISSIONS (see "Parallel work: worktrees").
5. **verified** (`items/3_verified/`) - human-authorized. The agent never self-verifies, but may perform the mechanical move on your explicit instruction (`credo-item-move.sh <id> verified --user-authorized`). Raw `mv`/`git mv` of item files is blocked and redirected to the move helper (enforced by `credo-item-move-guard.sh`).

Parked work lives under `items/parked/{hold,future}`; abandoned work under `items/4_archived/`.

`scripts/credo-item-counts.sh [--json]` prints the item count per status folder of the resolved project (read-only, exit 4 when no credo project resolves), so any renderer can show live counts without knowing the folder layout.

`scripts/credo-item-list.sh [--json] [--per N]` prints, per status folder, the total plus the newest N items (default 15) as id and title (frontmatter `title:`, else the slug); same project resolution and exit codes. `scripts/credo-session-status.sh [--json] [session_id]` prints one session's mode, role and autonomy state (running, paused, next wake) from the per-session state files (read-only, exit 2 when no session id resolves).

### The Definition of Done gate

An item may move to `2_done/` only when:

- the success criteria are observably met and the new code is actually wired in (a caller reaches it),
- a dedicated **audit** subagent (not the builder) has reviewed the work against its stated requirement and Definition of Done and returned a pass,
- for `ui: true`, a **visual verify** has driven the real surface in a browser across the configured viewports and captured screenshot evidence,
- docs are updated in the same change.

#### Audit depth

The audit gate always runs, by a dedicated subagent that is not the builder; only its depth follows risk. **full** (every audit check, current verify evidence) applies to `ui: true` items, security-relevant work (permissions, allow/block hooks, secrets, deletion, installs), writes outside the repo, data migration, large scope (guide value: more than ~10 files or a new component), items with the optional frontmatter `audit: full`, and anything in doubt. **lean** applies to everything else: the diff against each DoD point, wiring of new code, docs current for the change, and stale claims inside the item - still with severity-ranked findings and a verdict. The main agent picks the tier and the report states it with a one-line reason. There is no `audit: lean` override, so a risky item is never downgraded. Builder and audit run dogma's `relevant` test stage when the repo defines one; the full suite runs where dogma places it (for example once per release bundle), not per item. Several lean items may share one audit subagent with one verdict each; full items are always audited singly.

## Building-block skills

Auto-discovered under `skills/`. Each auto-triggers when it applies, including inside subagents.

- **audit** - read-only quality gate; reviews already-built work against its requirement and Definition of Done before it may move to `2_done/`. Proposes a severity-ranked decision (BLOCKER/MAJOR/MINOR/NIT), never a fix.
- **diag** - read-only root-cause diagnosis for a symptom; establishes the mechanism at file:line before any fix. The fix is a separate, GO-gated step.
- **verify** - visual verification as the Definition of Done for any change with a runtime surface; proves behavior in a real browser with computed layout. A down surface may be brought up or restarted autonomously ONLY when the target is positively verified local (a process on this machine, not a deployed/remote/shared environment - judged by where it runs, not by the git branch), via `verify.local_bringup`; otherwise the visual verify defers as human-only.
- **pr-vetting** - rigorous multi-subagent vetting of a pull request across technical, security, value/fit, and contributor-reputation dimensions; merges the findings into one decision-ready report while the merge/close decision stays with the maintainer.
- **issue-triage** - selection-first GitHub issue triage: shortlist and prioritize before deep-triaging the chosen issues via parallel subagents, then recommend close/fix/keep/needs-info for the owner to approve before any action.
- **items** - the work-item model where the folder is the status truth, gated by the Definition of Done.
- **sandbox** - WRITE pre-work for a `1_clarify` item blocked by a knowledge gap (a missing measurement, a mockup, or a feasibility proof), done under `.credo/sandbox-tmp/` without touching production code and without git, so the task/build agent is never disturbed. An accepted artifact is promoted to `.credo/sandbox/` via `/credo:sandbox-promote`.
- **rules** - per-repo special rules in `.credo/RULES.md`: project-local grants that widen credo's autonomy for that one repo (for example "restarting local services is always allowed without asking" in a debug-only repo). Loaded and honored every session and inside subagents, versioned so they travel with the repo, resolved via the project layer (works from a hub). Grants can only widen latitude within the safety floor (precedence: safety > DOGMA-PERMISSIONS > RULES.md > defaults); set one any time by just asking.
- **optimize** - the opt-in optimisation audit (see [Optimisation audit](#optimisation-audit)): freshness check, read-only scan, report, and every finding offered as Implement / Later / Never.
- **requirements-verbatim** - captures a requirement, decision, approval, or GO word-for-word into an append-only dated log so it survives compaction.
- **budget** - the single source for API budget caps and reset rules across the 5-hour and weekly limits, plus the commit-identity gate before any commit. An autonomous start does a mandatory budget read-back: the values are read fresh from the limit cache, never from memory. It also shows the active profile, the config layers and which layer supplies the caps (`credo-config.sh source budget.schedule`), plus the limit cache file it read.
- **compact-plus** - secures everything the user approved before a context compaction, then reports whether it is safe to compact. It does not run `/compact` itself.
- **orchestration** - how to delegate to subagents safely: how many to run, keeping parallel tracks on disjoint files (item `touches:` overlap check) and within machine resources (resource gate, `heavy:` items), giving each code track a set-up worktree (hydra or native), monitoring without flooding context, inheriting security, and return-and-resume.
- **safety** - the hard filesystem-protection and no-autonomous-installs rules; highest priority, no instruction overrides them.
- **cross-cutting-checklist-generator** - detects a concern scattered across many places and auto-generates a project-local checklist so it is never partially updated again.
- **skill-capture** - turns a workflow that recurs about three times in a session into a reusable Claude Code skill. Heuristic and in-session (no counter, no backend), mode-gated: autonomous only appends a candidate note, presence modes propose the capture via Ask and build on GO only. Generated skills land on the real discovery path (`<repo>/.claude/skills/` or `~/.claude/skills/`), carry a `credo-` name prefix plus an `origin: credo-repetition` marker, and are registered in `.credo/generated-skills.md`; seen-but-unbuilt patterns wait in `.credo/skill-candidates.md`.
- **wsl-env** - reach and act on Windows-side services, processes, and launchers when the agent runs inside WSL; self-detecting.
- **session-active / session-passive / session-autonomous** - the per-mode behavior; the active skill holds the shared common core.

## Subagent self-sufficiency

credo primes every subagent at start. The `SubagentStart` hook (`credo-subagent-inject.sh`) injects the load-bearing rules (security, quality gates, honesty, delegation, output hygiene) into each subagent before its first prompt, for all subagent types. It also injects a fresh, authoritative time (and best-effort live budget from the statusline cache) so a subagent works from the real clock instead of the possibly frozen time/limit values inherited from the main agent's context. This complements the skill descriptions, which are written to auto-trigger inside subagents as well. So even a main agent that only delegates gets correct results, independently of its own context state.

## Cross-profile peer bridge

Cross-session messaging (`ListAgents` / `SendMessage`) only discovers peers that share the same `sessions/` registry, so sessions started under different profiles (different `CLAUDE_CONFIG_DIR`, e.g. `~/.claude` vs `~/.claude-private`) cannot see or message each other by default - even though the inbox sockets live in one shared runtime dir and the transport works across profiles. Because agents talking to each other regardless of profile is part of the workflow, credo bridges this.

The `credo-peer-bridge.sh` hook (SessionStart, UserPromptSubmit, PostToolUse) autodiscovers sibling profiles (`~/.claude*` dirs that own a `sessions/` registry) and mirrors each **live** peer descriptor into the current profile's `sessions/` dir as a **regular file** tagged with an ownership marker (`credoPeerBridge`). That makes cross-profile peers appear in `ListAgents` and become reachable via `SendMessage`. Regular-file copies are used deliberately: the discovery reader enumerates regular files only and does not follow symlinks, so per-file symlinks are legacy v1 and are not honored by the discovery reader.

- **Resume stays clean.** `/resume` reads transcripts under `projects/`, never `sessions/`, so a mirrored descriptor (which has no local transcript) never pollutes the resume picker. Work/private history remain fully separate.
- **Safe by construction.** The hook only ever removes files that carry its own `credoPeerBridge` marker (plus leftover legacy symlinks and its own temp files). A real local descriptor is an unmarked regular file and is never touched or overwritten; it never removes directories and never touches anything outside the profile's `sessions/` dir, and it always exits 0 so it cannot surface as a hook error. Entries whose source session has ended are pruned on the next run.
- **Disable** with `CREDO_PEER_BRIDGE=0`.
- **Caveat:** the descriptor format is internal to Claude Code and undocumented, so a future version may change it. The bridge is fail-safe - if that happens, peers simply stop appearing; nothing is corrupted.

## LAN peer relay (cross-machine, no cloud)

The cross-profile bridge above only reaches sessions on the SAME machine. The LAN relay (`scripts/credo-peer-lan.py`) extends the same peer model to sessions on DIFFERENT machines in one trusted network, without the Anthropic cloud (no Remote Control, no API). A daemon runs on each machine, publishes its local sessions to its configured peers over TCP, and mirrors every remote session into the local `sessions/` registry - so a remote peer appears in `ListAgents` and is reachable via `SendMessage`, with replies routing back over the LAN.

A remote session has no local process, so its descriptor would be reaped (the discovery reader validates the pid is a live local process, matching `procStart` = field 22 of `/proc/<pid>/stat` to resist pid reuse). For each remote session the daemon therefore spawns one lightweight local **holder** subprocess that listens on a local **proxy** unix socket and forwards frames over the LAN. The holder is a real live local process, so its pid and `procStart` are real; the mirrored descriptor uses the holder pid as both the `<pid>` filename and the descriptor's `pid`/`procStart`, copies `pidDomain` from a real local session (so it is treated as local), points `messagingSocketPath` at the proxy socket, keeps the remote name suffixed with the machine (`name@machine`), and carries the marker `credoPeerLan` - NOT `credoPeerBridge`, so the cross-profile bridge never touches it.

- **Mode-agnostic by design.** The injected envelope NEVER carries a `from-mode` attribute; the receiving session applies its OWN consent gate. The relay only carries name, body, and reply address.
- **Authenticated.** Transport is line-based JSON over TCP, authenticated with a shared token via HMAC-SHA256; a message that does not verify is rejected.
- **Safe lifecycle.** The daemon only ever removes descriptors carrying its own `credoPeerLan` marker, plus the proxy sockets and holders it created; on SIGTERM it removes all of them. A stale descriptor from a dead run (holder pid gone) is pruned on the next start.
- **Off by default.** It is a no-op until a config exists at `~/.claude/credo/peer-lan.json` (override with `CREDO_PEER_LAN_CONFIG`; see `scripts/peer-lan.example.json`). Disable globally with `CREDO_PEER_LAN=0`.
- **Manual network step.** Opening the `listen_port` in the firewall for the LAN (and, under WSL, any portproxy) is a manual action the user performs. Start/stop/status via `/credo:peer-lan`.
- **Caveat:** the descriptor format is internal to Claude Code and undocumented; the relay is fail-safe - if it changes, remote peers simply stop appearing.

## Peer message etiquette

Peer sessions tend to over-communicate: every ack, status note or handoff lands as a new turn, and the receiver often reacts right away (a reply, an immediate commit and push). `credo-peer-message.sh` only informs, it never blocks:

- **Receiver** (UserPromptSubmit): when the prompt is a `<cross-session-message>`, it injects the handling rule. `[urgent]` (or untagged but asking a question or needing a decision) is handled now; `[info]` and other untagged messages get no reply and no immediate action, and resulting `.credo`/item changes are batched into the next natural commit (idle time, next release, before a compact).
- **Sender** (PreToolUse `SendMessage`): reminds the agent to start the message with `[info]` or `[urgent]`, bundle points, never send pure acks, and end with "No reply needed" when no answer is needed.
- **Autonomy:** a peer message never pauses autonomy (`credo-autonomy-clear.sh` exempts it); only the user's own messages do.
- **Disable** with `CREDO_PEER_ETIQUETTE=0`.

## Parallel work: touches and resource gate

Parallel subagents are wanted; there is no fixed cap on code tracks. Two things limit them:

- **File overlap.** An item may carry the optional frontmatter `touches:` - a list of paths or globs it will likely edit, set by the plan / clarify agent at the latest at GO. It is guidance: the main agent re-checks it right before spawning builders and updates it when files moved. `scripts/credo-touches-check.sh [--json] <id> <id> ...` prints overlapping item pairs (glob-aware, conservative) and lists items without `touches:` as `unknown` (exit 0 no overlap, 3 overlap, 4 no project, 1 bad args). Overlapping items run sequentially; `unknown` items are classified by the main agent, parallel by default. Read-only work (research, clarify) stays freely parallel.
- **Resource gate.** `scripts/credo-resource-check.sh --running N [--heavy] [--json]` prints `ok` (exit 0) or `wait:<reason>` (exit 5). Below `resources.gate_from_agents` running agents it answers `ok` without checking; from there on (and always with `--heavy`) it compares `MemAvailable` from `/proc/meminfo` against `resources.min_free_ram_gb` and the 1-minute load per CPU against `resources.max_load_per_cpu`. Unreadable values never block. On `wait` no new agent starts; the main agent re-checks when the next agent finishes (no polling loop).
- **Heavy items.** `heavy: true` (model or benchmark tests, large downloads) never runs in parallel to another heavy item and starts only when the check with `--heavy` says `ok`, even below the gate.

Config keys (defaults in the builtin template):

| Key | Default | Meaning |
| --- | --- | --- |
| `resources.gate_from_agents` | `6` | check the machine only from this many running agents |
| `resources.min_free_ram_gb` | `4` | wait when less RAM is available (GB) |
| `resources.max_load_per_cpu` | `1.0` | wait when the 1-minute load per CPU is higher |

The procedure lives in the orchestration skill; tests: `scripts/test-touches-check.sh`, `scripts/test-resource-check.sh`.

## Parallel work: worktrees (setup and cleanup)

Parallel code tracks work in git worktrees. Everything below runs automatically - you never have to run a command.

- **Which flow.** `scripts/credo-worktree-flow.sh [--json] [dir]` prints `flow=hydra|ask|native` and the `setup=` script to use. It reads the DOGMA-PERMISSIONS checkbox `use Hydra for 2+ independent tasks` (`### Hydra` subsection) (stable id `§xw1i`) through `scripts/credo-dogma-mode.sh [--id <id>] <subsection> <pattern> [dir]` (matches the id first, anywhere in `<permissions>`, then the subsection + text as fallback for files without ids; prints `auto|ask|deny|missing`, works without dogma, falls back to the main worktree's file; picks the file like dogma - `dir` as the target, else the credo pinned project, else the current folder - and inherits settings the file does not define from the session folder's file (the folder the session was started in, recorded per session by the `credo-session-dir-record.sh` SessionStart hook so it is still found after a `cd <project> && ...`; without a record `$PWD`) unless it says `- [ ] (§r3nx) inherit permissions`): `[x]` or no checkbox / no file (default on) with hydra installed = hydra's create flow, `[?]` = ask the user once per batch (never in autonomous mode: native), `[ ]` or no hydra = native `git worktree add`.
- **Setup.** A fresh worktree only has versioned files, so rules and items are missing. Right after every `git worktree add`, `scripts/credo-worktree-setup.sh <worktree> [main-checkout]` (or hydra's identical `worktree-setup.sh`) links (relative symlinks) or copies the excluded files: the "Worktree files" list of DOGMA-PERMISSIONS.md (`link: <path>` / `copy: <path>`, read via dogma's `worktree-files.sh`), else the default - CLAUDE.md, CLAUDE/, GUIDES/, DOGMA-PERMISSIONS.md and everything unversioned under .credo/, each only if it exists. Only ignored paths are linked or copied: an untracked path that is not ignored in the main checkout (e.g. a new uncommitted item file) is skipped with `skipped <path> (untracked, not ignored - read it in the main checkout)`, because a `git add -A` in the worktree would commit the link and a merge would put it into main; such paths are never added to the shared `info/exclude`. A directory with tracked files inside (or a not-ignored one holding ignored entries) is recursed into and only its untracked, ignored entries are linked; versioned paths are skipped with a warning; an existing path is never overwritten. A linked directory ignored only by a `dir/` pattern gets an anchored `/dir` line in the shared `.git/info/exclude` (a `dir/` pattern does not match a symlink). It prints `main=<main checkout>`, which goes into every builder brief: builders may look up anything missing read-only in the main checkout, never write or commit there.
- **Cleanup at item close.** Every move to done, verified or archived runs `scripts/credo-worktree-cleanup.sh [--dry-run] [--json] [--base <branch>] [--fresh-hours N] [dir]` per the checkbox `clean up merged worktrees automatically` (stable id `§36ch`; `[x]` remove without asking, `[?]` or no checkbox list and ask, `[ ]` never). It removes only worktrees whose branch is fully merged into the main branch and that have no changes to tracked files (untracked scratch and the setup links go with them), via `git worktree remove --force` (symlinks are unlinked, never followed) and `git branch -d`. The main worktree, the current one, locked, unmerged and dirty worktrees are kept and reported with the reason; a never-committed worktree is kept while younger than 24h or holding untracked files. Every run covers all worktrees, so the first one sweeps the backlog.

Tests: `scripts/test-worktree-setup.sh` (credo and hydra setup), `scripts/test-worktree-cleanup.sh` (including the item-move wiring), `scripts/test-worktree-flow.sh`.

## Optimisation audit

`/credo:optimize` (skill `optimize`) is an audit credo offers but never forces. It is language-agnostic and respects the repo's existing conventions: it detects what the repo already does first and recommends an ecosystem standard only where nothing exists, for the user to confirm.

- **Opt-in per repo.** The question is asked once, together with the credo onboarding question (SessionStart ASK), in `/credo:setup` (Step 2c) and in `/credo:session-init`; for a directory where credo is already active, `credo-optimize-hook.sh` asks it on the next fresh start. Nothing is scanned before the answer. Yes = run it now, later offered again only to returners; No = never offered automatically, `/credo:optimize` stays available by hand. The answer is stored per repo and per profile.
- **Only for returners.** `credo-optimize-hook.sh` (SessionStart, also on resume) offers the audit again only when the repo has been idle for at least `optimize.idle_days` (default 7) by wall-clock: credo's own per-repo last-seen timestamp (updated on every prompt by the same hook on `UserPromptSubmit`), the newest reflog entry, the mtime of `.git/index`, and the newest mtime among the files `git status --porcelain` reports as modified or untracked must ALL be older. It is evaluated before last-seen is updated, asked once per return, never in autonomous mode (the offer then stays pending for the next attended session). Silent in `/credo:disable`d directories and with the `gsd` backend. Toggle: `CREDO_OPTIMIZE_HOOK` (default true).
- **Fresh state first.** Before every run, `scripts/credo-optimize-fresh.sh` checks that the repo is on its default branch and not behind its remote (`git fetch` is its only non-read action). If not, the agent proposes `git switch <default>` and `git pull --ff-only` and runs them only with consent; a stale state is never audited silently.
- **Scan (read-only, by a subagent).** Conflict hotspots from `git log` (auto-discovery instead of central registration lists, smaller modules, generated instead of hand-written mirror lists, splitting a growing `CLAUDE.md` into the dogma `CLAUDE/<topic>.md` + `GUIDES/` pattern with fixed `@`-paths); changelog fragments (a versioned `changelog.d/` assembled by `/dogma:versioning` at the release commit, never a tag); the test-stage convention; dogma settings inferred from the workflow (Test Commands stages, the release-only option, the Hydra checkboxes - passed as suggestions to `/dogma:permissions`, credo holds no dogma logic); parallelism readiness (worktree files list, large files that block parallel work).
- **Result.** A report at `.credo/process/reports/optimize-<YYYY-MM-DD>.md`, and every finding offered as Implement / Later / Never. Accepted larger findings become credo items, small ones may be done directly after confirmation, and Never is remembered per repo and finding.

Scripts: `credo-optimize-state.sh` (opt-in, last-seen, pending offer, last-offer, never-list; `get --json`), `credo-optimize-idle.sh [--days N] [--json]` (`idle=yes|no` plus the four signal ages; exit 0 idle, 1 not idle, 4 not a git repo), `credo-optimize-fresh.sh [--no-fetch] [--json]` (exit 0 fresh, 1 stale, 3 unknown, 4 not a git repo). State lives under `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/credo/optimize/<repo-hash>/` (linked worktrees share the main checkout's state).

| Key | Default | Meaning |
| --- | --- | --- |
| `optimize.idle_days` | `7` | offer the audit again only when every activity signal is at least this many days old |

Tests: `scripts/test-optimize-state.sh`, `scripts/test-optimize-idle.sh`, `scripts/test-optimize-fresh.sh`, `scripts/test-optimize-hook.sh`.

## Wait-loop hint

`credo-wait-hint.sh` (PreToolUse Bash) adds a hint when a command loops on `pgrep -f` (`until ! pgrep -f "X"` matches the waiting shell's own command line and never ends): wait on a result file or one specific PID with a time limit, or rely on the harness completion notification. It never blocks; the rule itself is in the orchestration skill. Disable with `CREDO_WAIT_HINT=0`.

## Claude Code band (optional)

When credo runs inside Claude Code with mods support, `hooks/band.tsx` (listed under `modules` in `hooks/hooks.json`) draws a small band above the prompt. It is optional: it only reads credo's state through the core scripts above and renders it. The core - hooks, scripts, skills, items - works exactly the same without it and in harnesses without mods.

- **Counts line** - `◆ credo` plus the item count per status (`cf go bk`, `dd vf`, `pk ar`), colored per group, zero counts dimmed. Changes flash for 6 s (fuchsia for moves, white for new items) with a toast. Without a credo project (no item system, also in a pinned project without items) the counts and the item controls (`i`, `l`, `e`) are left out, but the session line - mode/role, open test/question letters, `h` help - and the autonomy line still show whenever there is something to show (also in a declined directory or without a credo mode: only the item system is off there); the prompt hint then lists the shorthands that work without items (`cf dd vf ??? cm ph`) and the `h` cheatsheet leaves out the `#N` item moves.
- **Session line** - this session's mode/role (`autonomous paused/task` when a user message paused the autonomous run; pausing and re-arming flash the tag like an item move), the open test/question letters (🧪 / ❓) from the last answer, and the controls: `i` items pane, `h` shorthand cheatsheet (both in one shared pane, from `credo-item-list.sh` and `templates/shorthands.json`), `l` short/long labels (`go: 12` vs `Go(go): 12`), `e` rotates the presets `all` / `no parked` / `open + dogma` / `open only` (`open only` also hides the dogma band).
- **Autonomy line** - only while this session runs autonomously: `⟳ auto` with the 5h utilization, the next ladder rung and the next wake time.
- **Prompt hint** - `Shortcuts: ...` lists the shorthands the band does not show (long form `key(word)` follows `l`).
- `/credo-items` opens the items pane too. It refreshes on session start, after Bash calls, at turn end and every 10 s.

## Dependencies

credo works on its own. Two touchpoints are external:

### `limit` plugin - recommended prerequisite

The [`limit`](https://github.com/Marcel-Bich/marcel-bich-claude-marketplace/wiki/Claude-Code-Limit-Plugin) plugin is a prerequisite for two features:

- **Context-percent triggers** - the auto-run of compact-plus at the configured session-context fill thresholds relies on the limit plugin's inject hook. Point it at credo with:
  - `CLAUDE_MB_LIMIT_COMPACT_SKILL=credo:compact-plus`
  - `CLAUDE_MB_LIMIT_INJECT_THRESHOLDS=80,92`
  - `/credo:setup` offers to set these for you (Step 9) when the limit plugin is installed, so hand-editing is optional.
- **Budget data source** - the budget skill reads the limit cache (`/tmp/claude-mb-limit-cache_*.json`) for the 5-hour and weekly utilization and reset times.

If the `limit` plugin is absent, these features are silently unavailable. There is no error; credo simply does not run the budget or auto-compact logic that has no data.

### `ntfy` - optional

Push notifications use `ntfy`. The topic is a personal field in the credo config (`personal.ntfy_topic`). If it is unset, ntfy is silently skipped; nothing else changes. Progress is bundled into a digest on a fixed interval (`ntfy.digest_interval_minutes`); when a topic is set, sending it is mandatory whenever there is progress (with no topic it stays silently skipped), and each completed item carries a content standard (what / how / where / why, verify state, what needs the user, budget snapshot) so a terse one-liner is never enough. One message is preferred, split into `n/m` when it would exceed ntfy's size limit.

## Installation

Add the marketplace and install `credo`, or copy the plugin into your `.claude-plugin/` location. Then run `/credo:setup` to initialize a project and, optionally, pre-fill config.
