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

After this, credo's session modes, item lifecycle, Definition of Done, budget awareness, verify, and safety are ready. Pick a session mode when you start working:

- `/credo:session-active` - intensive live collaboration.
- `/credo:session-passive` - agent carries most work, you answer clarifications.
- `/credo:session-autonomous` - approved GO items worked unattended.

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

- Yes, run /gsd:create-roadmap - Plan milestones and phases
- No, skip for now
```

If user chooses "Yes": Run `/gsd:create-roadmap` via Skill tool.

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

## Setup Complete

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
