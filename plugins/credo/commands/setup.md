---
description: credo - Set up Claude Code with recommended workflows and plugins
arguments: none
allowed-tools:
  - Bash
  - Read
  - Write
  - Edit
  - AskUserQuestion
  - Skill
---

# Credo Setup

Set up Claude Code with the preacher's recommended tools, instructions, and project structure. credo is the core; everything else is recommended or optional and slots in around it.

**Goal:** Only ask about things that are NOT yet done. Skip everything already configured.

## Step 1: Run Setup Check

Run the setup check script to gather all information at once:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/check-setup.sh"
```

This outputs structured results for all checks. Parse the output to determine:

- `plugins.dogma` - Is the recommended dogma plugin installed?
- `plugins.gsd` - Is the optional get-shit-done plugin installed?
- `directories.claude` - Are Claude instructions present?
- `files.project_md` - Does PROJECT.md exist? (only relevant if GSD is used)
- `directories.codebase_map` - Is codebase mapped? (only relevant if GSD is used)
- `files.roadmap` - Does ROADMAP.md exist? (only relevant if GSD is used)
- `project.state` - Overall state (needs_setup, needs_mapping, needs_project, needs_roadmap, ready)
- `todo_tools.state` / `todo_tools.declined` - Is the Claude Code task-list tools opt-in on for the active profile (see Step 10)?
- `tmux.installed` / `tmux.inside` / `tmux.platform` / `tmux.pkg_manager` / `tmux.login_shell` - Is tmux installed, does this session run inside it, and how could it be installed (see Step 11)?

**If project.state = ready:** Skip directly to "Setup Complete" section. Do NOT ask any questions.

## Step 2: Initialize the credo Framework (Core)

This is the real first step - credo's own state tree. It is self-contained and needs no other plugin.

Run the init script (idempotent - safe to run again):

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/credo-init.sh"
```

This creates the `.credo/` structure (items, process, screenshots, checklists, config, id-counter) and adds the git-exclude lines. `.credo/**` stays local by default. For teams that want items and process versioned in the repo, run it with `CREDO_VERSION_TRACKED=1` instead (per-project `config` and `screenshots/` stay local either way).

### Handling the target guard (fail-safe)

credo-init is fail-safe: it never creates `.credo/` in the wrong place. If the current directory is a launch hub, or is ambiguous (no `.credo/` yet and no explicit target given), the script exits non-zero (code 4) with a message like:

```
credo-init: cwd '<path>' is a hub or has no credo project, and no explicit target was given.
Set CREDO_DIR to the target repo, or pin it with /credo:project <path>, then retry.
```

**If you see this (a non-zero exit), do NOT force a directory.** The user must not have to know about env vars or config keys - guide them with AskUserQuestion:

```
credo could not decide which repo to target from here.

Where should credo set up its project layer (.credo/)?
- This directory - the current working directory IS the repo I want credo in
- Another repo - I will give you the absolute path of the target repo
- This is a launch hub - I start other repos from here; never auto-target it
```

Then act on the answer:

- **This directory:** re-run init pinned to the cwd, which creates `.credo/` here:
  ```bash
  CREDO_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)/.credo" bash "${CLAUDE_PLUGIN_ROOT}/scripts/credo-init.sh"
  ```
- **Another repo:** ask for the absolute path, pin it, then re-run init:
  ```bash
  "${CLAUDE_PLUGIN_ROOT}/hooks/session-project-set.sh" "<abs-path>"
  bash "${CLAUDE_PLUGIN_ROOT}/scripts/credo-init.sh"
  ```
  (The pin is layer 2 of the resolver, so plain `credo-init.sh` now finds the target.)
- **This is a launch hub:** mark the cwd as a hub so credo never auto-targets it. Write `hub: true` at the top level of `<cwd>/.credo/config` (create the file if missing) with Read + Edit or Write, then tell the user to pin the real repo with `/credo:project <path>` whenever they work. Do NOT create the full `.credo/` item tree here - a hub is not a work repo.

**Existing repository with prior work?** Instead of the fresh-init path above, run `/credo:migrate` once to onboard the existing codebase into the `.credo/` structure (it inventories current state and seeds items rather than assuming a blank slate).

Once `.credo/` exists here, record this directory as opted-in. Running setup is an explicit act of
setting credo up here, so this FORCES the accepted state, overriding any earlier `/credo:disable`
(declined) for this directory:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/credo-dir-decision.sh" set accepted
```

After this, credo's session modes, item lifecycle, Definition of Done, budget awareness, verify, and safety are ready. Pick a session mode when you start working:

- `/credo:session-active` - intensive live collaboration.
- `/credo:session-passive` - agent carries most work, you answer clarifications.
- `/credo:session-autonomous` - approved GO items worked unattended.

## Step 2b: Per-repo special rules (optional)

credo supports per-repo **special rules** - project-local grants that widen credo's autonomy
for THIS repo (for example "restarting local services is always allowed without asking" in a
debug-only repo). They live in `.credo/RULES.md`, travel with the repo, and are honored every
session and inside subagents (credo `rules` skill).

Offer to capture some now with AskUserQuestion:

```
Do you want to set any per-repo credo rules for this repo? (grants that widen autonomy,
e.g. "always allowed to restart local services without asking")

- Yes, let me name a rule
- No, skip (you can add rules any time by just asking)
```

If yes, invoke the credo `rules` skill (Skill tool) to write the rule verbatim into
`.credo/RULES.md`. If no, continue - rules can be added later at any time.

## Step 2c: Optimisation audit (optional, opt-in)

Only in a git repo. Check whether the per-repo answer is already recorded:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/credo-optimize-state.sh" optin
```

If it prints `yes` or `no`, skip this step. If it prints nothing, ask with AskUserQuestion
(nothing is scanned before the answer):

```
Optimisation audit wanted for this repo? A read-only scan (conflict hotspots, changelog
fragments, test-stage convention, dogma settings, parallelism readiness); every finding
is offered to you as Implement / Later / Never.

- Yes - run it after this setup; later it is offered again only when you return after a
  longer break (default 7 days idle, config optimize.idle_days)
- No - never offered automatically; /credo:optimize stays available any time
```

Record the answer with `"${CLAUDE_PLUGIN_ROOT}/scripts/credo-optimize-state.sh" optin yes`
or `... optin no`. On Yes, run `/credo:optimize` once the remaining setup steps are done
(before "Setup Complete").

## Step 3: Install Recommended and Optional Plugins

**Skip if:** `plugins.dogma = true` (and, if the user wants GSD, `plugins.gsd = true`)

credo works on its own. These plugins complement it:

- **dogma** (recommended) - syncs and enforces Claude instructions.
- **get-shit-done** (optional) - a spec-driven planning system, an alternative to credo's own item workflow. Only install it if you prefer up-front project decomposition or already like the GSD flow. See "credo vs Get-Shit-Done" in the marketplace README.

**If dogma is missing (dogma: false):**

Use AskUserQuestion:

```
The preacher recommends dogma to sync and enforce your Claude instructions.

Shall the preacher summon it for you?
- Yes, install dogma (Recommended)
- Also install get-shit-done (optional spec-driven planning, alternative to credo items)
- No, I will gather tools myself
- Proceed without (credo alone still works)
```

**The Faithful Choose: "Yes, install dogma"**

Summon the tool:

```bash
claude plugin install dogma@marcel-bich-claude-marketplace
```

**The Faithful Choose: "Also install get-shit-done"**

Summon both:

```bash
claude plugin install dogma@marcel-bich-claude-marketplace
claude plugin install get-shit-done@marcel-bich-claude-marketplace
```

After installing any plugin, speak:

```
The tools have been summoned.

But they slumber until Claude awakens anew.

Please:
1. Leave this session (Ctrl+C or 'exit')
2. Return: claude

Then seek /credo:setup once more.
```

**Halt here** - the tools must awaken before the journey continues.

**The Faithful Choose: "No, I will gather tools myself"**

Provide the incantations:

```
Gather the tools yourself with these commands:

claude plugin install dogma@marcel-bich-claude-marketplace
# Optional, only if you want the GSD planning workflow:
claude plugin install get-shit-done@marcel-bich-claude-marketplace

Then restart Claude and return to /credo:setup.
```

**Halt here** - await their return.

**The Faithful Choose: "Proceed without"**

```
You proceed with credo alone - that is a complete, self-contained setup.

Note: without dogma, /dogma:* commands will not respond. Without get-shit-done,
/gsd:* commands will not respond and the optional GSD planning path is unavailable.
credo's own workflow (session modes, items, Definition of Done) is unaffected.
```

Continue.

## Step 4: Install Recommended Plugins and MCPs (Recommended)

**Skip if:** `directories.claude = true` (user already ran setup before - recommended plugins were offered then)

**Only ask on first setup** (when `directories.claude = false`):

Ask the user:
```
Would you like to install recommended plugins and MCP servers?

This includes tools for planning, debugging, parallel execution, and more.
You can skip this step if you prefer to set them up manually later.

1. Yes, run /dogma:recommended:setup (Recommended)
2. No, skip for now
```

If user chooses option 1:
```
/dogma:recommended:setup
```

**After installing new plugins:** Restart Claude (Ctrl+C, then `claude`) to load them.

## Step 5: Sync Claude Instructions

**Skip if:** `directories.claude = true` (dogma already configured) OR dogma is not installed.

**If directories.claude is false and dogma is installed:**

Use AskUserQuestion:

```
The sacred tools are ready, but the teachings have not yet been received.

Would you like to set up dogma now?
- Yes, run /dogma:sync (Recommended) - Syncs Claude instructions from the official Marcel-Bich dogma repo
- Use custom source - Provide your own repo URL or local path as source
- No, skip for now - I will set it up later with /dogma:sync
```

**If user chooses "Yes":** Run `/dogma:sync` via Skill tool.

**If user chooses "Use custom source":** Ask for the repo URL or local path, then run `/dogma:sync <provided-source>`.

When prompted for DOGMA-PERMISSIONS.md, the preacher's recommended settings:

```markdown
## Git Operations

- [x] May run `git add` autonomously
- [x] May run `git commit` autonomously
- [?] May run `git push` autonomously

## File Operations

- [?] May delete files autonomously (rm, unlink, git clean)
```

Legend: `[x]` = auto, `[?]` = ask, `[ ]` = deny

## Step 6: Choose a Task System (Optional)

credo's item lifecycle (from Step 2) is the recommended default and needs no further setup - just create items as you work.

**Only relevant if the user installed get-shit-done and prefers spec-driven planning.** Pick ONE task system per project (credo items OR GSD phases), never both, to avoid competing sources of truth.

**If the user picks GSD as the task system:** write `task_backend: gsd` into the project `.credo/config` for them (see "Writing the GSD backend" below) so credo's own item features stand down (no `.credo/items/` vs `.planning/` double-bookkeeping). credo's operating layer - session modes, budget, safety, verify, subagent priming - keeps working on top of GSD regardless. Leaving the config untouched (backend `credo`) keeps credo items as the task system, no action needed. The `CREDO_TASK_BACKEND` env var still overrides the config if ever needed.

**Writing the GSD backend.** `.credo/config` already exists (credo-init created it in Step 2). Read it: if a top-level `task_backend:` line is present, update its value to `gsd`; otherwise append a `task_backend: gsd` line at the top level. Use Read + Edit (or Write) to make the change - do not shell out to a config setter. Example resulting line:

```yaml
task_backend: gsd
```

**Skip if:** GSD is not installed, OR `files.project_md = true`, OR `directories.codebase_map = true`, OR the user is happy with credo items.

**For NEW projects (project.is_greenfield = true AND no existing code):**

Use AskUserQuestion:
```
You have get-shit-done installed. For this project, which task system?

- credo items (Recommended) - lightweight, already set up, no further action
- GSD: run /gsd:new-project - up-front spec-driven planning (creates PROJECT.md)
```

If user chooses GSD: Run `/gsd:new-project` via Skill tool, then write `task_backend: gsd` into `.credo/config` (see "Writing the GSD backend" above).

**For EXISTING projects (project.is_greenfield = false):**

Use AskUserQuestion:
```
You have get-shit-done installed and existing code that hasn't been mapped.

- credo items (Recommended) - lightweight, already set up, no further action
- GSD: run /gsd:map-codebase - analyze the codebase for spec-driven planning
```

If user chooses GSD: Run `/gsd:map-codebase` via Skill tool, then write `task_backend: gsd` into `.credo/config` (see "Writing the GSD backend" above).

## Step 7: Create Roadmap (Optional, GSD only)

**Skip if:** GSD is not being used, OR `files.roadmap = true`.

If the user chose the GSD path and has no roadmap yet:

Use AskUserQuestion:
```
Would you like to create a GSD project roadmap?

- Yes, run /gsd:new-milestone - Plan milestones and phases
- No, skip for now
```

If user chooses "Yes": Run `/gsd:new-milestone` via Skill tool.

## Step 8: Autonomy Preferences (Optional)

These two preferences are personal / machine-level, so they belong in the GLOBAL credo
config (all repos inherit them), NOT the project `.credo/config`. Get or create the global
config path, then Read + Edit that file to set the keys directly (same approach as the
`task_backend` write in Step 6 - do NOT shell out to a setter):

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/credo-config.sh" ensure-global
```

That prints (and creates if missing) the global config path. Only ask each question below if
it was not already chosen - but detect "already chosen" from the GLOBAL config FILE itself
(the ensure-global path), NOT from `credo-config.sh get`:

- Sleep (machine power-down): to decide whether it was already chosen, check the GLOBAL
  config file itself (the ensure-global path) for a top-level `sleep:` block (e.g. grep the
  file for a `sleep:` line). Do NOT use `credo-config.sh get sleep.enabled` for this decision -
  it returns the builtin template default `false` via the config cascade even when the global
  file never set it, so it would wrongly look "already configured" and skip the question on
  first-ever setup. Ask the sleep question UNLESS the global file already contains a `sleep:`
  block.
- ntfy: check the same GLOBAL config file for a non-empty `personal.ntfy_topic:` value OR
  `personal.ntfy_optout: true`. Skip the ntfy question if EITHER is present (a set topic means
  configured; an opt-out means the user already declined). Otherwise ask.

### (a) Machine power-down (sleep)

The power-down command is OS-specific and the right MODE differs by platform, so this is a
platform-aware flow. It writes `sleep.enabled`, `sleep.mode`, and `sleep.command` to the
GLOBAL config (Read + Edit the ensure-global path; append or update the `sleep:` block, same
approach as `task_backend`). Ask only if no `sleep:` block exists (per the detection above).

Step 1 - first AskUserQuestion, may it power down THIS machine at all:

```
May autonomous work power down THIS machine when it finishes or hits the weekly cap?

- No, never power down this machine (Recommended) - required for servers; autonomous runs just end cleanly
- Yes, power it down when autonomous work is done - only for a personal machine
```

- "No" -> write the `sleep:` block with `enabled: false` (leave `mode` and `command` empty).
  Done - skip the rest of part (a).
- "Yes" -> continue to Step 2.

Step 2 - detect the platform:

- WSL: `grep -qiE "microsoft|wsl" /proc/version` succeeds.
- else read `uname -s`: `Linux` -> native Linux, `Darwin` -> macOS.

Step 3 - on native Linux only, check power-state availability before offering modes:

- `grep -qw disk /sys/power/state` -> hibernate (suspend-to-disk) is available.
- `grep -qw mem /sys/power/state` -> suspend (suspend-to-RAM) is available.

If `disk` is absent, do NOT offer hibernate (it is unavailable, typically because swap is
smaller than RAM) - steer to suspend and say why.

Step 4 - second AskUserQuestion, which mode, with a PLATFORM-SPECIFIC recommendation and the
concrete command shown. Per-platform command table:

- WSL: recommended Hibernate (`shutdown.exe /h`); alternative StandBy
  (`rundll32.exe powrprof.dll,SetSuspendState 0,1,0`).
- native Linux: recommended StandBy (`systemctl suspend`); alternative Ruhezustand / hibernate
  (`systemctl hibernate`) - offer the hibernate alternative ONLY if `/sys/power/state` had
  `disk`.
- macOS: StandBy (`pmset sleepnow`) - single reasonable option.

Present it like this, adapted to the detected platform (drop the hibernate row where it is
unavailable, and mark the Recommended one per platform):

```
Which power-down mode? (detected platform: <WSL|Linux|macOS>)

- StandBy (suspend) - <command> (Recommended on Linux) - low power, reliable, fast resume
- Ruhezustand (hibernate) - <command> (Recommended on WSL) - writes RAM to disk, zero power
```

The shown command is a PROPOSAL the user can accept or override with their own command string
(some machines differ). If the user gives a custom command, take it verbatim.

Step 5 - write to the GLOBAL config: `sleep.enabled: true`, `sleep.mode: suspend` or
`hibernate` (matching the chosen mode), and `sleep.command:` set to the chosen or custom
command. Read + Edit the YAML directly (append or update the `sleep:` block).

### (b) ntfy push notifications

Use AskUserQuestion:

```
credo can send push notifications (via ntfy) so you get called back to the PC during autonomous work. Set it up?

- Yes, I have an ntfy topic - I will paste my topic string
- No, skip notifications - autonomous work runs without push (silent)
```

- "Yes" -> ask for the topic string, then write it to `personal.ntfy_topic` in the GLOBAL
  config AND set `personal.ntfy_optout: false` (Read + Edit both values).
- "No" -> leave `personal.ntfy_topic` empty and set `personal.ntfy_optout: true` in the GLOBAL
  config (this explicit opt-out marker is what stops setup re-asking on every future run -
  symmetric with the `sleep:` block). Note in the setup output that autonomous work will then
  run without push notifications (silent) - this is fine and purely informational.

ntfy is decided HERE at setup only. `personal.ntfy_optout` governs ONLY whether setup re-asks;
it adds NO runtime prompt. At autonomous RUNTIME credo does NOT ask about ntfy: if a topic is
set it is used, if empty it is silently skipped. Do not imply a runtime prompt.

## Step 9: Compact Trigger Wiring (Optional)

This step offers to wire the `limit` plugin's auto-compact trigger to credo's
`compact-plus` skill, so the user does not have to hand-edit it. The `limit` plugin's
inject hook runs whatever skill is named in the env var `CLAUDE_MB_LIMIT_COMPACT_SKILL`
(it ships no default). credo wants that pointed at `credo:compact-plus`. This writes an
ENV VAR to `~/.claude/settings.json` (the host settings file where that var lives, under
the top-level `env` object) - it does NOT touch `~/.claude/CLAUDE.md`. This is analogous
to Step 8 writing sleep/ntfy to the global credo config.

### Relevance gate (skip silently if limit is not used)

This step is only relevant if the `limit` plugin is installed or active. Detect this
best-effort; if limit cannot be confirmed, SKIP this step silently (do not ask - failing
toward NOT nagging is the correct behavior). Any ONE of these is a sufficient signal that
limit is present:

- The limit plugin is installed: `grep -q '"limit@marcel-bich-claude-marketplace"' "$HOME/.claude/plugins/installed_plugins.json"` succeeds (same installed-plugins file the setup check reads for dogma/gsd).
- A limit cache exists: `ls /tmp/claude-mb-limit-cache_*.json` matches at least one file.
- A `[limit] ...` inject line has appeared in this session's context.

If none of these hold, limit is not in use here - skip Step 9 entirely and continue to
"Setup Complete".

### Inspect the current value

Read `env.CLAUDE_MB_LIMIT_COMPACT_SKILL` from `~/.claude/settings.json` (the file may not
exist yet, and the `env` object may be absent - treat both as "unset"):

```bash
SETTINGS="$HOME/.claude/settings.json"
CUR="$( [ -f "$SETTINGS" ] && jq -r '.env.CLAUDE_MB_LIMIT_COMPACT_SKILL // ""' "$SETTINGS" 2>/dev/null || echo "" )"
echo "current: [$CUR]"
```

The target value is exactly `credo:compact-plus` with NO leading slash (credo skills are
referenced without a leading slash). Also read the optional thresholds var, which is
handled INDEPENDENTLY of the skill value:

```bash
CURTH="$( [ -f "$SETTINGS" ] && jq -r '.env.CLAUDE_MB_LIMIT_INJECT_THRESHOLDS // ""' "$SETTINGS" 2>/dev/null || echo "" )"
```

Classify the skill value in `$CUR`:

- **Already correct:** `$CUR` is exactly `credo:compact-plus`.
- **Needs fixing:** any of these cases ->
  - unset or empty
  - a leading-slash form (e.g. `/credo:compact-plus` or `/compact-plus`)
  - a stale/nonexistent target: the old personal `compact-plus` / `/compact-plus`
    slash-command name, or a `credo:<name>` whose skill does not exist. Verify a
    `credo:<name>` target by checking that `"${CLAUDE_PLUGIN_ROOT}/skills/<name>/SKILL.md"`
    exists; for `credo:compact-plus` that file is present, so it counts as valid.

The thresholds var (`CLAUDE_MB_LIMIT_INJECT_THRESHOLDS`) is decoupled from the skill state:
an unset thresholds var is worth offering even when the skill value is already correct,
because setup is a deliberate, user-initiated moment, not a runtime nag.

### Offer via AskUserQuestion (permission-per-change)

Pick the flow from the state above:

**Skill needs fixing** - offer the skill, and fold in the thresholds within the same
question when `$CURTH` is empty:

```
The limit plugin is installed, but its auto-compact trigger is not wired to credo's
compact-plus in the expected form. credo can set
env.CLAUDE_MB_LIMIT_COMPACT_SKILL = "credo:compact-plus" in
~/.claude/settings.json so compact-plus runs automatically at the context-fill thresholds.

- Yes, wire compact-plus (Recommended) - sets CLAUDE_MB_LIMIT_COMPACT_SKILL to credo:compact-plus; also sets CLAUDE_MB_LIMIT_INJECT_THRESHOLDS to 80,92 if unset
- Set the skill only - just CLAUDE_MB_LIMIT_COMPACT_SKILL, leave thresholds untouched
- No, leave settings.json unchanged - I will set it myself (or I do not use auto-compact)
```

**Skill already correct** - do NOT skip the step. If `$CURTH` is empty, offer the
thresholds on their own:

```
The limit auto-compact trigger already points at credo:compact-plus, but the fire
thresholds (CLAUDE_MB_LIMIT_INJECT_THRESHOLDS) are unset. credo can set them to 80,92
in ~/.claude/settings.json.

- Yes, set thresholds to 80,92 (Recommended)
- No, leave settings.json unchanged - I will set them myself
```

If the skill value is already correct AND `$CURTH` is already set, do nothing and do NOT
ask (fully idempotent). No decline-marker is stored: setup is rare and user-initiated, so
re-offering at a later explicit setup run is acceptable, unlike a runtime nag.

No coercion: if the user declines, leave `~/.claude/settings.json` unchanged.

### Write it safely with jq (on acceptance)

Write JSON with `jq`, never by hand-editing, so the rest of `settings.json` is preserved.
Create the file as `{}` first if it is missing, and create the `env` object if absent.
Use a temp file then move it into place. The value has NO leading slash.

Run the skill-write only when the user accepted setting the skill (the "needs fixing"
flow):

```bash
SETTINGS="$HOME/.claude/settings.json"
mkdir -p "$(dirname "$SETTINGS")"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"

TMP="$(mktemp "$(dirname "$SETTINGS")/.settings.XXXXXX")"
jq --arg skill "credo:compact-plus" \
   '.env = (.env // {}) | .env.CLAUDE_MB_LIMIT_COMPACT_SKILL = $skill' \
   "$SETTINGS" > "$TMP" && mv "$TMP" "$SETTINGS"
```

Run the thresholds-write whenever the user accepted the thresholds (in EITHER flow), and
only when `$CURTH` was empty, so an existing custom value is never overwritten:

```bash
TMP="$(mktemp "$(dirname "$SETTINGS")/.settings.XXXXXX")"
jq --arg th "80,92" \
   '.env = (.env // {})
    | (if ((.env.CLAUDE_MB_LIMIT_INJECT_THRESHOLDS // "") == "")
       then .env.CLAUDE_MB_LIMIT_INJECT_THRESHOLDS = $th else . end)' \
   "$SETTINGS" > "$TMP" && mv "$TMP" "$SETTINGS"
```

This is the same env var credo's README and compact-plus docs describe for the manual
setup, now offered automatically. It is idempotent: once the value is `credo:compact-plus`,
a later run does nothing and does not ask.

## Step 10: Claude Code Task-List Tools (Recommended)

Newer Claude Code versions offer the task-list tools (`TaskCreate` / `TaskGet` /
`TaskUpdate` / `TaskList`) by default only on older models. On newer models they are
missing unless the env var `CLAUDE_CODE_ENABLE_TODO_TOOLS` is `1` (Claude Code >= 2.1.233,
see https://code.claude.com/docs/en/tools-reference#task-tool-availability). credo uses
that list as its ephemeral coordination layer (the items skill section "Harness task-list
vs .credo items": `[GO]` / `[HOLD]` / `[REMINDER]` entries and `§cct_N` refs, plus
orchestration), and subagents only get the tools when the parent session has them.

Inspect it with the helper (it checks the process environment and the `env` object of the
ACTIVE profile settings file `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json`; it never
writes anything for `status`):

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/credo-todo-tools.sh" status
```

It prints key=value lines. `state=on` means opted in: the process environment (the running
session, when called from inside Claude Code) has the variable as `1`, OR the settings file
sets it to the string `"1"` (a JSON number `1` does not count). `in_process` / `in_settings`
show each side, and `restart_needed=yes` (with a `summary` such as
`on (settings), session: off -> restart needed`) means it is enabled in settings.json but
not yet active in this session.

- `state=on` -> do NOT ask. If `restart_needed=yes`, tell the user once that a restart of
  Claude Code (e.g. `/credo:self-restart`) may be needed for the tools to appear.
- `state=off` -> ask via AskUserQuestion (also when `declined=yes`: setup is a deliberate,
  user-initiated moment; the decline only silences the periodic session-start hint).
  Never in autonomous mode - there, skip this step silently.

```
credo works best with Claude Code's task-list tools (TaskCreate/TaskList). On newer models
they are only offered when CLAUDE_CODE_ENABLE_TODO_TOOLS=1 is set. credo uses that list for
[GO]/[HOLD]/[REMINDER] coordination entries and §cct_N refs, and subagents only get the
tools when the parent session has them. Tip: Ctrl+T shows or hides the task list. The
list and a mod band (such as the credo band) cannot be shown at the same time, so keep the
list hidden and press Ctrl+T only when you want a quick look. Enable it in <settings path from status>?

- Yes, enable (Recommended) - backs up settings.json, then adds the variable to its "env" object; everything else stays as it is
- Not now - leave settings.json unchanged (credo reminds you at most once a week)
- No, never ask again - leave settings.json unchanged and silence the periodic reminder
```

- "Yes" -> run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/credo-todo-tools.sh" enable` and show
  the user the printed backup path. The edit is JSON-safe (python, key order and all other
  content kept, a symlinked settings.json is edited at its target); exit code 2 means the
  file is not valid JSON, its `env` is not an object, or the backup / write failed (e.g. a
  read-only profile directory) - then settings.json was not changed, tell the user and let
  them fix it by hand. The file is rewritten with 2-space indentation, so its formatting
  may change; the backup keeps the original bytes. If `declined=yes` was set, also run
  `bash "${CLAUDE_PLUGIN_ROOT}/scripts/credo-todo-tools.sh" undecline`.
  A restart of Claude Code (e.g. `/credo:self-restart`) may be needed for the tools to
  appear; tell the user so. (They have been seen to appear live, but that is not
  guaranteed - `status` shows `restart_needed=yes` while the session lacks them.)
  Also tell them: Ctrl+T toggles the task list; it and a mod band cannot be visible at
  once, so a common setup is list hidden, Ctrl+T for a quick look.
- "Not now" -> do nothing.
- "No, never ask again" -> run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/credo-todo-tools.sh" decline`.

Never change settings.json without a Yes. The periodic re-check is the SessionStart hook
`credo-todo-tools-hint.sh`: while the opt-in is off and not declined, it offers it again
at most once per `CREDO_TODO_TOOLS_HINT_DAYS` (default 7) days per profile, only on a
human-present start of a session where credo is active, never in autonomous work
(toggle: `CREDO_TODO_TOOLS_HINT=false`). At a fresh start the session mode is often not
written yet when the hook runs, so the hook cannot always tell an unattended start; the
injected text therefore opens with the rule never to ask in autonomous / unattended mode.
It also stays silent (without using up its weekly slot) when the optimisation hook asks
its own opt-in or welcome-back question at the same start, so a start carries at most one
credo opt-in question.

## Step 11: Run Claude Code Inside tmux (Strongly Recommended)

Several credo features type into the session's OWN terminal pane, and only tmux gives them
a pane they can safely inspect and type into:

- `/credo:self-compact` (the real `/compact` after compact-plus) - tmux only.
- `/credo:self-reload` (`/reload-plugins` + `/reload-skills` typed into the own pane) - tmux only.
- `/credo:self-restart` - works without tmux (new Windows Terminal tab / terminal window),
  but only inside tmux it waits until the pane is idle with an empty input field (so a
  prompt being typed is never lost) and relaunches in the SAME pane.

Never run this step in autonomous mode (setup is user-initiated anyway). Use the `tmux.*`
lines from Step 1:

**(a) `tmux.installed = true` and `tmux.inside = true`** -> nothing to do, skip silently.

**(b) `tmux.installed = true`, `tmux.inside = false`** -> tell the user in 2-3 lines why
tmux matters (the list above) and that this session itself is not inside tmux, so those
features are unavailable until Claude Code is started inside tmux. Then offer the launcher
in (d).

**(c) `tmux.installed = false`** -> explain the benefit in 2-3 lines, then pick the install
command for `tmux.pkg_manager`:

| `pkg_manager` | Command |
|---|---|
| `apt` | `sudo apt update && sudo apt install -y tmux` |
| `dnf` | `sudo dnf install -y tmux` |
| `pacman` | `sudo pacman -S --needed --noconfirm tmux` |
| `zypper` | `sudo zypper --non-interactive install tmux` |
| `brew` | `brew install tmux` |
| `none` | no known package manager: point to https://github.com/tmux/tmux/wiki/Installing and stop here |

`tmux.platform = windows` (native Windows, Git Bash / MSYS / Cygwin) means tmux does not run
natively. Recommend running Claude Code inside WSL (`wsl --install` in an admin PowerShell,
then install Claude Code and tmux inside the Linux distro) and stop - do not run anything.
`tmux.platform = wsl` is fine, because tmux runs inside WSL like on any Linux and a Windows
Terminal tab is simply the window around it.

Show the exact command, then ask via AskUserQuestion (hard rule - never install anything
without the user's explicit yes):

```
tmux is not installed. credo can install it with:
  <exact command>
Run it now?

- Yes, install tmux (Recommended) - runs exactly the command above
- I'll run it myself - show the command only
- No, skip tmux
```

- "Yes" -> for a `sudo` command, first check `sudo -n true 2>/dev/null`. If that fails, sudo
  needs a password, which the agent cannot type. Do NOT run it; tell the user to run the
  exact command in their own terminal (or via the `!` prefix in the Claude Code prompt)
  and to say when it is done. Otherwise run exactly the shown command, then verify with
  `tmux -V`. On failure show the error and stop; never try another package manager or
  source on your own.
- "I'll run it myself" -> show the command again, nothing else.
- "No" -> persist the decline (below), then skip the rest of this step.

**(d) Launcher (optional, after tmux is available and `tmux.inside = false`)** - a shell
function that always starts Claude Code inside a named tmux session (`tmux new-session -A`
attaches to the session when it already exists, so a closed terminal can be re-attached).
`tmux.login_shell` is only `$SHELL`, which may differ from the shell the user really works
in, so let them confirm the shell. Show the exact lines first, then ask via
AskUserQuestion:

```
Start Claude Code inside tmux automatically? This adds a function "ctmux" to <rc file>:
  <exact lines for the chosen shell>
Usage: ctmux (session "claude") or ctmux <name> for a second session.

- Yes, add it for bash (~/.bashrc)
- Yes, add it for zsh (~/.zshrc)
- Yes, add it for fish (~/.config/fish/functions/ctmux.fish)
- No, I start tmux myself
```

Put the detected `tmux.login_shell` option first. The exact lines:

bash / zsh (appended to `~/.bashrc` / `~/.zshrc`):

```bash
# credo: start Claude Code inside tmux (attach if the session exists)
ctmux() { if [ -n "$TMUX" ]; then claude; else tmux new-session -A -s "${1:-claude}" claude; fi; }
```

fish (new file `~/.config/fish/functions/ctmux.fish`):

```fish
# credo: start Claude Code inside tmux (attach if the session exists)
function ctmux
    if set -q TMUX
        claude
    else if set -q argv[1]
        tmux new-session -A -s $argv[1] claude
    else
        tmux new-session -A -s claude claude
    end
end
```

- On a Yes, first check that the target does not already define `ctmux`
  (`grep -n 'ctmux' <rc file>`, or the fish file exists). If it does, show it and do not
  write. Otherwise append the lines (bash/zsh: `printf` with `>>`, never overwrite the rc
  file; fish: create the functions file, `mkdir -p ~/.config/fish/functions` first) and
  show the user what was written. Tell them it takes effect in a new shell (or after
  `source <rc file>`), and that this current session stays outside tmux until they quit
  and start it again with `ctmux` (they can resume it with `claude --resume`).
- "No, I start tmux myself" -> nothing is written to any rc file; persist the decline
  (below).

Never write to any shell rc file without that explicit Yes.

**(e) Persist a decline.** After "No, skip tmux" or "No, I start tmux myself", record it so
the SessionStart tmux hint stays silent from now on. Find the config file with
`bash "${CLAUDE_PLUGIN_ROOT}/scripts/credo-config.sh" paths` - the `profile:` file when a
non-default Claude Code profile is active (it is listed there), else the `global:` file. Add
or set this top-level key with Read + Edit (create the block if it is missing, change only
this key, keep everything else):

```yaml
tmux:
  hint: false
```

Then confirm in one line that the hint is off and how to turn it back on (set `hint: true`
again, or run this step again). `bash "${CLAUDE_PLUGIN_ROOT}/scripts/credo-config.sh" get
tmux.hint` must now print `false`.

## Setup Complete

Before the message below: if Step 2c was skipped because `project.state` was `ready` and
the optimisation-audit answer is still open (`credo-optimize-state.sh optin` prints
nothing, in a git repo), ask Step 2c now. If the user said Yes in Step 2c, run
`/credo:optimize` now. Likewise, if Step 10 was skipped because `project.state` was
`ready` and `todo_tools.state` is `off`, run Step 10 now. Likewise, if Step 11 was skipped
because `project.state` was `ready` and `tmux.installed` or `tmux.inside` is `false`, run
Step 11 now.

**If all steps were skipped (project.state was ready):**

```
Setup already complete! Your project is fully configured.

Proceeding to workflow guides...
```

**If some steps were executed:**

```
Setup complete!

Your project now has:
- The credo framework initialized (.credo/ ready)
- Recommended plugins installed (if chosen)
- Claude instructions synced (if chosen)
- A task system selected (credo items by default)

Proceeding to workflow guides...
```

**Note:** When invoked via `/credo:psalm`, the psalm command continues automatically after this message. When invoked directly via `/credo:setup`, stop here.
