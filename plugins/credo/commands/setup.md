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
