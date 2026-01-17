---
description: credo - Step-by-step workflow guide for setting up new projects
allowed-tools:
  - Bash
  - Read
  - Write
  - Edit
  - AskUserQuestion
  - Skill
---

# Project Setup Workflow

Guide the user through setting up a new Claude Code project step by step.

## How to Use

Present each step as a checklist. After each step:
1. Ask user if step is complete or needs help
2. Offer to execute commands if applicable
3. Move to next step only after confirmation

## Workflow Steps

### Step 1: Create Project Directory

```bash
mkdir -p <project-name>
cd <project-name>
git init
```

Ask user for project name if not provided.

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

When prompted for DOGMA-PERMISSIONS.md:
- `add: true` - allow adding files
- `commit: true` - allow commits
- `rm: ask` - ask before removing

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

```
/gsd:new-project
```

Describe what the project is about:
- Purpose and goals
- Target audience
- Offline/online (push to remote?)
- Suggested folder structure

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
    "CLAUDE_MB_DOGMA_LINT_ON_STOP": "false"
  }
}
```

**Agent failures:** If an agent fails due to hooks, adjust settings and respawn.

**Environment variables:** See `~/.claude/settings.json` for available options.
