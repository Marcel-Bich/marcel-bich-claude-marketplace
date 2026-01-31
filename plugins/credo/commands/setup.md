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

Set up Claude Code with the preacher's recommended tools, instructions, and project structure.

## Step 1: Run Setup Check

Run the setup check script to gather all information at once:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/check-setup.sh"
```

This outputs structured results for all checks. Parse the output to determine:

- `plugins.dogma` / `plugins.gsd` - Are required plugins installed?
- `directories.claude` - Are Claude instructions present?
- `project.state` - Overall project state (needs_setup, needs_mapping, needs_roadmap, ready)

## Step 2: Install Required Plugins

**If plugins are missing (dogma: false OR gsd: false):**

Use AskUserQuestion:

```
The preacher's teachings require sacred tools that are not yet installed:

Missing: [list missing plugins based on check output]

Shall the preacher summon them for you?
- Yes, install now (Recommended)
- No, I will gather them myself
- Proceed without (the path will be incomplete)
```

**The Faithful Choose: "Yes, install now"**

Summon the missing tools:

```bash
# Only for those not yet present:
claude plugin install dogma@marcel-bich-claude-marketplace
claude plugin install get-shit-done@marcel-bich-claude-marketplace
```

Then speak:

```
The tools have been summoned.

But they slumber until Claude awakens anew.

Please:
1. Leave this session (Ctrl+C or 'exit')
2. Return: claude

Then seek /credo:setup once more.
```

**Halt here** - the tools must awaken before the journey continues.

**The Faithful Choose: "No, I will gather them myself"**

Provide the incantations:

```
Gather the tools yourself with these commands:

claude plugin install dogma@marcel-bich-claude-marketplace
claude plugin install get-shit-done@marcel-bich-claude-marketplace

Then restart Claude and return to /credo:setup.
```

**Halt here** - await their return.

**The Faithful Choose: "Proceed without"**

Warn of the incomplete path:

```
You walk an incomplete path. Many teachings will fail:
- /dogma:* commands will not respond
- /gsd:* commands will not respond
- The Project Setup workflow will be broken

The preacher advises returning later with proper tools.
```

Continue, but the journey will be hindered.

## Step 3: Install Recommended Plugins and MCPs (Recommended)

**Skip if:** User explicitly declines or already has all needed plugins installed.

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

## Step 4: Sync Claude Instructions

**Skip if:** `directories.claude = true` (dogma already configured)

**If directories.claude is false:**

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

## Step 5: Initialize Project with GSD

**Skip if:** Project is already initialized (directories.codebase_map = true OR files.project_md = true)

**For NEW projects (project.is_greenfield = true):**

Use AskUserQuestion:
```
The project directory appears to be new.

Would you like to initialize it with GSD?
- Yes, run /gsd:new-project (Recommended) - Creates PROJECT.md with project context
- No, skip for now - I will set it up later with /gsd:new-project
```

If user chooses "Yes": Run `/gsd:new-project` via Skill tool.

**For EXISTING projects (project.is_greenfield = false):**

Use AskUserQuestion:
```
I detected existing code that hasn't been mapped yet.

Would you like to map the codebase?
- Yes, run /gsd:map-codebase (Recommended) - Analyzes codebase and creates documentation
- No, skip for now - I will map it later with /gsd:map-codebase
```

If user chooses "Yes": Run `/gsd:map-codebase` via Skill tool.

## Step 6: Create Roadmap (Optional)

**Skip if:** `files.roadmap = true`

If no roadmap yet:

Use AskUserQuestion:
```
Would you like to create a project roadmap?

- Yes, run /gsd:create-roadmap - Plan milestones and phases
- No, skip for now
```

If user chooses "Yes": Run `/gsd:create-roadmap` via Skill tool.

## Setup Complete

```
Setup complete!

Your project now has:
- Required plugins installed
- Claude instructions synced
- Project structure initialized

Next steps:
- Run /credo:psalm to explore workflow guides and best practices
- Run /gsd:plan-phase 1 to start planning your first phase
- Run /hydra:help to learn about parallel development
```
