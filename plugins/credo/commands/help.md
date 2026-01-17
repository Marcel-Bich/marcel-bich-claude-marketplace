---
description: credo - Comprehensive guide for project setup and plugin workflows
allowed-tools:
  - Bash
  - Read
  - Write
  - Edit
  - AskUserQuestion
  - Skill
---

# Project Setup Workflow

Guide users through setting up Claude Code for new or existing projects.

## Prerequisites

This workflow requires plugins from marcel-bich-claude-marketplace:

| Plugin | Purpose | Required |
|--------|---------|----------|
| **get-shit-done** (Taches) | Project planning, roadmaps, phases | Yes |
| **dogma** | Claude instructions sync, linting hooks | Yes |
| **hydra** | Parallel worktree execution | Optional |
| **credo** | This workflow guide | Yes |

**If plugins are missing:** Install them from marcel-bich-claude-marketplace.

## How to Use

Present each step as a checklist. After each step:
1. Ask user if step is complete or needs help
2. Offer to execute commands if applicable
3. Move to next step only after confirmation

## Step 0: Check Prerequisites

First, verify required plugins are installed:
- Check if `/gsd:help` works (get-shit-done)
- Check if `/dogma:sync` works (dogma)

If plugins are missing, install them from the marketplace first.

## Step 1: Determine Project Type

Ask user first:
```
Is this a new project (greenfield) or an existing project (brownfield)?
- New project: Start from scratch
- Existing project: Add Claude Code to existing codebase
```

## Workflow Steps

### Step 1: Project Directory

**For NEW projects (greenfield):**
```bash
mkdir -p <project-name>
cd <project-name>
git init
```

**For EXISTING projects (brownfield):**
```bash
cd <existing-project-path>
```

Ensure git is initialized. If not: `git init`

### Step 2: Update Claude and Start Session

```bash
claude update
claude --dangerously-skip-permissions
```

**Note:** `--dangerously-skip-permissions` is for initial setup only.

### Step 3: Update Marketplaces

If user has custom marketplaces:
- Check `~/.claude/settings.json` for marketplace paths
- Run `git pull` in marketplace directories if needed
- Install new plugins from marketplaces

### Step 4: Set Project Language

Ask user:
```
What is the main language for this project?
- German (no English needed)
- English (no German needed)
- Bilingual (both languages)
```

Document in CLAUDE.md or tell Claude directly.

### Step 5: Sync Claude Instructions

```
/dogma:sync
```

When prompted for DOGMA-PERMISSIONS.md, recommended settings:

```markdown
## Git Operations
- [x] May run `git add` autonomously
- [x] May run `git commit` autonomously
- [?] May run `git push` autonomously

## File Operations
- [?] May delete files autonomously (rm, unlink, git clean)
```

Legend: `[x]` = auto, `[?]` = ask, `[ ]` = deny

### Step 6: Disable Unnecessary Features (Optional)

If project doesn't need certain features (e.g., no code = no linting):

Create `.claude/settings.local.json`:
```json
{
  "env": {
    "CLAUDE_MB_DOGMA_LINT_ON_STOP": "false",
    "CLAUDE_MB_DOGMA_PRE_COMMIT_LINT": "false",
    "CLAUDE_MB_DOGMA_SKIP_LINT_CHECK": "true"
  }
}
```

Or disable entire plugins:
```json
{
  "enabledPlugins": {
    "dogma@marcel-bich-claude-marketplace": false
  }
}
```

**Important:** Restart Claude after changing settings.

### Step 7: Initialize Project with GSD

**For NEW projects:**
```
/gsd:new-project
```

Describe what the project is about:
- Purpose and goals
- Target audience
- Offline/online (push to remote?)
- Suggested folder structure

**For EXISTING projects (brownfield):**
```
/gsd:map-codebase
```

Claude analyzes the codebase and creates documentation in `.planning/codebase/`.

### Step 8: Create Roadmap

```
/gsd:create-roadmap
```

Review and adjust until satisfied.

### Step 9: Plan Phases

```
/clear
/gsd:plan-phase 1
```

Use `/hydra` commands for parallel work if beneficial.

### Step 10: Execute Phases

```
/clear
/gsd:execute-phase 1
/clear
/gsd:execute-phase 2
...
```

Continue until all phases complete.

### Step 11: Complete Milestone

```
/clear
/gsd:complete-milestone
```

Choose: yes / wait / adjust

---

## Project is Ready

After completing all steps, the project is initialized and ready for work.

### For Development Projects

Use these commands as needed:
- `/gsd:new-milestone` - Plan next milestone
- `/gsd:verify-work` - Manual acceptance tests
- `/hydra:create` - Create worktree for parallel work

### Tips

**Worktree settings:** Customize settings per worktree:
```json
{
  "env": {
    "CLAUDE_MB_DOGMA_LINT_ON_STOP": "false",
    "CLAUDE_MB_DOGMA_PRE_COMMIT_LINT": "false",
    "CLAUDE_MB_DOGMA_SKIP_LINT_CHECK": "true"
  }
}
```

**Agent failures:** If an agent fails due to hooks, adjust settings and respawn.

**Environment variables:** See `~/.claude/settings.json` for available options.

---

## Plugin Showcase: Optional Topics

Before diving into examples, ask the user which topics interest them:

**Use AskUserQuestion with these options:**

```
Which productivity topics would you like to explore?

- Parallel Development: Run multiple features simultaneously with hydra
- Brownfield Onboarding: Understand existing codebases quickly
- Code Quality: Automatic linting and formatting
- Debugging: Systematic debugging methodology
- Documentation: Cache and search API docs locally
- Decision Making: Use mental frameworks for tough choices
- Prioritization: Find what matters most with Eisenhower matrix
- Resource Monitoring: Track tokens, costs, and rate limits
- Custom Configuration: Per-project and per-worktree settings
- Something else: Ask your own question
```

Only explain the topics the user selects. For custom questions, help based on project structure and configuration files.

### Topic: Parallel Development (hydra)

Run multiple features simultaneously without Git conflicts:

```
Use all fitting /hydra commands to complete the following tasks
as parallel as possible. Use as many subagents as makes sense
(even minimal benefit is worth it):

- Feature A: Add authentication
- Feature B: Create API endpoints
- Feature C: Build UI components
```

Hydra handles worktree creation, agent spawning, and cleanup automatically.

After completion:
```
/hydra:merge feature-auth
/hydra:cleanup
```

### Topic: Brownfield Onboarding (gsd)

Join an existing project and need context fast:

```
/gsd:map-codebase
```

Creates documentation in `.planning/codebase/`. Then:

```
/gsd:discuss-phase 1
/gsd:plan-phase 1
```

### Topic: Code Quality (dogma)

Automatic formatting and linting on every commit:

```
/dogma:lint:setup
```

Sets up ESLint + Prettier. Hooks enforce clean code automatically.

For version sync issues:

```
/dogma:versioning
```

Finds and syncs all version files in the project.

### Topic: Debugging (gsd)

Stuck on a hard bug:

```
/gsd:debug
```

Activates systematic debugging with hypotheses, tests, and logging.

When breakthrough happens or user input needed, signal plugin plays a sound.

### Topic: Documentation (import)

Need current docs for a library:

```
/import:url https://docs.example.com/api
```

Caches docs locally. Later:

```
/import:search "authentication"
/import:update
```

### Topic: Decision Making (taches-cc-resources)

Facing an architecture decision:

```
/consider:first-principles
/consider:swot
/consider:10-10-10
```

Claude analyzes options using proven mental frameworks.

### Topic: Prioritization (taches-cc-resources)

Too many tasks, unclear what's urgent:

```
/consider:eisenhower-matrix
```

Categorizes tasks by urgency and importance.

### Topic: Resource Monitoring (limit + hydra)

Multiple agents running in parallel:

```
/hydra:watch
```

Live table with status of all worktree agents.

In the status line (limit plugin) you see:
- Token usage
- Rate limits
- Costs

### Topic: Custom Configuration

Different settings per worktree (e.g., disable linting for a subagent):

```json
// In worktree .claude/settings.local.json:
{
  "env": {
    "CLAUDE_MB_DOGMA_LINT_ON_STOP": "false",
    "CLAUDE_MB_DOGMA_PRE_COMMIT_LINT": "false",
    "CLAUDE_MB_DOGMA_SKIP_LINT_CHECK": "true"
  }
}
```

Respawn agent - done.

---

## Further Help

- `/gsd:help` - All GSD commands
- `/hydra:help` - Worktree management
