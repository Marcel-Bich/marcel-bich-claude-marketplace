---
description: credo - Interactive guide to available topics and workflows
arguments:
  - name: question
    description: Optional question or topic to explore
    required: false
allowed-tools:
  - Bash
  - Read
  - Write
  - Edit
  - AskUserQuestion
  - Skill
---

# Credo - The Preacher's Guide

## Step 0: Gather the Sacred Tools (MANDATORY)

Before the faithful can walk the path, they must possess the sacred tools. Check this BEFORE proceeding.

```bash
# Verify the sacred tools are present
claude plugin list 2>/dev/null | grep -q "dogma@marcel-bich-claude-marketplace" && echo "dogma: installed" || echo "dogma: MISSING"
claude plugin list 2>/dev/null | grep -q "get-shit-done@marcel-bich-claude-marketplace" && echo "get-shit-done: installed" || echo "get-shit-done: MISSING"
```

### If Tools Are Missing

The faithful cannot proceed without proper preparation. Use AskUserQuestion:

```
The preacher's teachings require sacred tools that are not yet installed:

Missing: [list missing plugins]

Shall the preacher summon them for you?
- Yes, install now (Recommended)
- No, I will gather them myself
- Proceed without (the path will be incomplete)
```

### The Faithful Choose: "Yes, install now"

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

Then seek /credo:psalm once more.
```

**Halt here** - the tools must awaken before the journey continues.

### The Faithful Choose: "No, I will gather them myself"

Provide the incantations:

```
Gather the tools yourself with these commands:

claude plugin install dogma@marcel-bich-claude-marketplace
claude plugin install get-shit-done@marcel-bich-claude-marketplace

Then restart Claude and return to /credo:psalm.
```

**Halt here** - await their return.

### The Faithful Choose: "Proceed without"

Warn of the incomplete path:

```
You walk an incomplete path. Many teachings will fail:
- /dogma:* commands will not respond
- /gsd:* commands will not respond
- The Project Setup workflow will be broken

The preacher advises returning later with proper tools.
```

Continue to the Entry Point, but the journey will be hindered.

### All Tools Are Present

The faithful possess the sacred tools. But are the teachings present?

Check if Claude instructions exist:

```bash
ls -d CLAUDE/ 2>/dev/null && echo "Teachings present" || echo "Teachings missing"
```

**If CLAUDE/ directory is missing:** Use AskUserQuestion:

```
The sacred tools are ready, but the teachings have not yet been received.

Shall the preacher sync the teachings now?
- Yes, run /dogma:sync (Recommended)
- No, continue without (I will sync later)
```

**If user chooses "Yes":** Execute `/dogma:sync` via the Skill tool, then continue to Entry Point.

**If user chooses "No" or CLAUDE/ exists:** Continue silently to the Entry Point.

---

## Entry Point

If the user runs `/credo` without arguments, help them discover available topics.

**IMPORTANT: Smart Detection First**

Before showing options, silently run these checks to determine project state:

```bash
# Check project state (run all, don't show output to user)
ls -d CLAUDE/ 2>/dev/null && echo "CLAUDE_EXISTS" || echo "CLAUDE_MISSING"
ls -d .planning/codebase/ 2>/dev/null && echo "CODEBASE_MAPPED" || echo "CODEBASE_NOT_MAPPED"
ls -d .planning/ROADMAP.md 2>/dev/null && echo "ROADMAP_EXISTS" || echo "ROADMAP_MISSING"
git rev-parse --is-inside-work-tree 2>/dev/null && echo "GIT_INIT" || echo "NO_GIT"
find . -maxdepth 2 -type f \( -name "*.ts" -o -name "*.js" -o -name "*.py" -o -name "*.go" -o -name "*.rs" \) 2>/dev/null | head -1 | grep -q . && echo "HAS_CODE" || echo "NO_CODE"
```

**Decision Logic:**

1. **If CLAUDE_MISSING:** Project needs setup - offer `/dogma:sync` first
2. **If CLAUDE_EXISTS + CODEBASE_NOT_MAPPED + HAS_CODE:** Suggest `/gsd:map-codebase`
3. **If CLAUDE_EXISTS + CODEBASE_MAPPED + ROADMAP_MISSING:** Suggest `/gsd:create-roadmap`
4. **If everything exists:** Project is set up - go directly to topics

**If project is already set up:** Skip "Project Setup" in the options and go directly to topic selection:

```
What would you like to explore?

- Parallel Development: Run multiple features simultaneously with hydra
- Code Quality: Automatic linting and formatting
- Debugging: Systematic debugging methodology
- Decision Making: Mental frameworks for tough choices
- Something else: Ask your own question
```

**If project needs setup:** Show what's missing and offer to fix it:

```
I detected the following:
- [x] Git initialized
- [x] CLAUDE/ instructions present
- [ ] Codebase not yet mapped

Would you like to:
- Run /gsd:map-codebase now (Recommended)
- Skip and explore topics
- Full setup walkthrough
```

**If arguments provided:** The user already has a question. Answer it directly using this guide's best practices, or navigate to the most relevant section.

---

# Project Setup Workflow

Guide users through setting up Claude Code for new or existing projects.

**IMPORTANT: This section is only for projects that actually need setup. If the project already has CLAUDE/, .planning/, etc., skip directly to the topics section.**

## Smart Detection (MANDATORY)

Before ANY setup steps, automatically detect project state:

```bash
# Detect project type and state - run silently
HAS_FILES=$(find . -maxdepth 2 -type f ! -path "./.git/*" 2>/dev/null | head -5 | wc -l)
HAS_GIT=$(git rev-parse --is-inside-work-tree 2>/dev/null && echo "yes" || echo "no")
HAS_CLAUDE=$(ls -d CLAUDE/ 2>/dev/null && echo "yes" || echo "no")
HAS_PLANNING=$(ls -d .planning/ 2>/dev/null && echo "yes" || echo "no")
HAS_CODEBASE_MAP=$(ls -d .planning/codebase/ 2>/dev/null && echo "yes" || echo "no")
HAS_LANGUAGE=$(ls CLAUDE/CLAUDE.language.md 2>/dev/null && echo "yes" || echo "no")
```

**Auto-detect Greenfield vs Brownfield:**
- `HAS_FILES > 0` AND `HAS_GIT = yes` = **Brownfield** (existing project)
- `HAS_FILES = 0` OR `HAS_GIT = no` = **Greenfield** (new project)

**NEVER ask the user if this is greenfield or brownfield - detect it automatically.**

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

**Skip steps that are already complete.** Only show steps that actually need action.

For each incomplete step:
1. Explain what needs to be done
2. Offer to execute it
3. Move to next incomplete step

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

**Warning:** `--dangerously-skip-permissions` allows Claude to execute any command without asking for permission. This includes file deletions, system modifications, and other potentially destructive operations. **Use at your own risk.** You are solely responsible for any data loss, system crashes, or other damages that may occur.

### Step 3: Install Recommended Plugins (Optional)

**Skip if:** User already has all needed plugins installed.

To check and install recommended plugins/MCPs:
```
/dogma:recommended:setup
```

**After installing new plugins:** Restart Claude (Ctrl+C, then `claude`) to load them.

### Step 4: Set Project Language

**Skip if:** `CLAUDE/CLAUDE.language.md` already exists (language is already configured).

**Only ask if CLAUDE.language.md is missing AND /dogma:sync won't create it:**

The language setting comes automatically through `/dogma:sync`. Only ask about language if the user is NOT using dogma sync.

### Step 5: Sync Claude Instructions

```
/dogma:sync
```

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

### Step 6b: Restart Claude (After Settings Changes)

**Required:** After modifying `.claude/settings.local.json`, restart Claude:

1. Exit Claude (Ctrl+C or type `exit`)
2. Start again:
```bash
claude update
claude --dangerously-skip-permissions
```

**Warning:** See disclaimer above regarding `--dangerously-skip-permissions`.

Settings changes only take effect after Claude restart.

### Step 7: Initialize Project with GSD

**Skip if:** `.planning/codebase/` already exists (codebase is already mapped) or `.planning/PROJECT.md` exists (project is already initialized).

**For NEW projects (auto-detected as greenfield):**
```
/gsd:new-project
```

Describe what the project is about:
- Purpose and goals
- Target audience
- Offline/online (push to remote?)
- Suggested folder structure

**For EXISTING projects (auto-detected as brownfield):**

Check first:
```bash
ls -d .planning/codebase/ 2>/dev/null && echo "Already mapped - skip" || echo "Needs mapping"
```

If not yet mapped:
```
/gsd:map-codebase
```

Claude analyzes the codebase and creates documentation in `.planning/codebase/`.

### Step 8: Create Roadmap

**Skip if:** `.planning/ROADMAP.md` already exists.

Check first:
```bash
ls .planning/ROADMAP.md 2>/dev/null && echo "Roadmap exists - skip" || echo "Needs roadmap"
```

If no roadmap yet:
```
/gsd:create-roadmap
```

Review and adjust until satisfied.

### Step 9: Plan Phases

```
/clear
/gsd:plan-phase 1
```

The preacher recommends `/hydra` commands for parallel work when beneficial.

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

## The Project is Blessed

After completing all steps, the project is anointed and ready to serve.

### For Development Projects

Use these commands as needed:
- `/gsd:new-milestone` - Plan next milestone
- `/gsd:verify-work` - Manual acceptance tests
- `/hydra:create` - Create worktree for parallel work

### The Preacher's Tips

**Worktree settings BEFORE spawn:** When using hydra, configure `.claude/settings.json` in the worktree BEFORE spawning agents. This ensures agents start with the correct environment:

1. Create worktree: `/hydra:create`
2. Navigate to worktree and adjust `.claude/settings.json`
3. Then spawn agent: `/hydra:spawn`

Example settings to disable linting for agents that don't need it:
```json
{
  "env": {
    "CLAUDE_MB_DOGMA_LINT_ON_STOP": "false",
    "CLAUDE_MB_DOGMA_PRE_COMMIT_LINT": "false",
    "CLAUDE_MB_DOGMA_SKIP_LINT_CHECK": "true"
  }
}
```

**Agent failures:** If an agent fails due to hooks, adjust settings in the worktree and respawn the agent.

**Environment variables:** See `~/.claude/settings.json` for available options - use as template for worktree settings.

**Avoid interrupting running processes:** The preacher recommends NOT adding intermediate messages while Claude is working (even though the temptation is strong). Only add messages that REALLY contribute to the current topic in a focused way. Don't fix off-topic bugs or address unrelated issues mid-process.

Instead:
1. Open a notepad (or similar) alongside Claude
2. Write down everything that comes to mind while waiting
3. Once all tasks for the current topic are complete, work through your notes
4. Use the hydra example prompt below for parallel processing of collected notes
5. Alternative without hydra: process them one by one, ideally after `/clear`

Discipline brings clarity. Chaos breeds confusion.

### Hydra Example Prompt: Complete Workflow

```
Use /hydra to work on a feature in a worktree:

plugin signal improvement:
Add sound notification when user input is required, so user hears
when they need to act (ensure cross-platform: Linux, macOS, Windows)

For worktrees, adjust .claude/settings.json BEFORE spawning:
Example if agent would be disturbed by linting:
{
  "env": {
    "CLAUDE_MB_DOGMA_LINT_ON_STOP": "false",
    "CLAUDE_MB_DOGMA_PRE_COMMIT_LINT": "false",
    "CLAUDE_MB_DOGMA_SKIP_LINT_CHECK": "true"
  }
}

The env variables in ~/.claude/settings.json serve as template.
Adjust per worktree as needed (only disable what's necessary!).

If agent fails due to hooks: fix settings in worktree and respawn.
```

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
- Git Ignore Patterns: Never forget an ignore location
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

**Safety:** `/hydra:delete` and `/hydra:cleanup` will never accidentally delete the main worktree.

**Read-only verification:** Hydra also works for parallel checking tasks:

```
Use hydra to verify in parallel (read-only):
- Check if all tests pass
- Verify documentation is complete
- Confirm no TODO comments remain
- Check for security issues
```

**Pro tip:** You don't need to run `/credo` (or any other command/skill) - just mention it in your prompt:

```
Follow the patterns from /credo to verify these requirements...
```

Claude will apply the best practices without executing the command.

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
/import:url-or-path https://docs.example.com/api
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

### Topic: Git Ignore Patterns (dogma)

Never forget an ignore location when adding patterns:

```
/dogma:ignore
```

Adds patterns to all relevant locations at once:
- `.gitignore` (versioned, shared with team)
- `.git/info/exclude` (local only, not versioned)

To audit which patterns are missing where:

```
/dogma:ignore:audit
```

Shows gaps across all ignore locations so nothing is forgotten.

---

## Further Help

- `/gsd:help` - All GSD commands
- `/hydra:help` - Worktree management

### Wiki (Fallback for Details)

If information is missing or more details are needed, check the marketplace wiki:

**URL:** https://github.com/Marcel-Bich/marcel-bich-claude-marketplace/wiki

Use WebFetch to retrieve specific wiki pages when users ask for more details about a plugin or feature not fully covered here.

---

## Preacher's Complete Workflow (Real-World Example)

This is how the preacher handles most new projects - a complete demonstration including all repetitions like `/clear` commands. Walk this path.

### New Project Setup

```bash
# Create project directory
mkdir -p my-project
cd my-project
git init

# Start Claude
claude update
claude --dangerously-skip-permissions
```

**Warning:** See disclaimer above regarding `--dangerously-skip-permissions`.

### Update Marketplaces and Plugins

```
# Manually update marketplaces if needed (git pull in marketplace directories)
# Install missing/new plugins from available marketplaces
```

### Restart Claude (Required After Plugin Changes)

```bash
# Exit Claude, then:
claude update
claude --dangerously-skip-permissions
```

### Set Project Language

Tell Claude the main language, e.g.:
```
The main language of this project is German, we don't need any English at all.
```

### Sync Claude Instructions

```
/dogma:sync
```

When prompted for DOGMA-PERMISSIONS.md:
- add: true
- commit: true
- rm: ask

### Disable Features for This Project (Optional)

**To disable PARTS of a plugin** (e.g., no linting for non-code projects):

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

**To disable ENTIRE plugins** (e.g., no dogma rules for acquisition projects - though the preacher recommends keeping dogma and just disabling hooks):

```json
{
  "enabledPlugins": {
    "dogma@marcel-bich-claude-marketplace": false
  }
}
```

### Restart Claude (Required After Settings Changes)

```bash
# Exit Claude, then:
claude update
claude --dangerously-skip-permissions
```

### Initialize Project with GSD

```
/gsd:new-project
```

Describe what the entire project represents (not individual tasks, but the purpose):

```
Example for an acquisition project:

In this project I provide acquisition data, e.g., in the form of tickets or
ticket comments, containing various tasks that are defined or emerge from them.
The project serves to fulfill these tasks (mostly customer acquisition through
analysis and assessments).

The project is offline and will never be pushed.

Suggested folder structure:
./archive/ => completed/cancelled projects no longer being worked on but useful as future references
  ./archive/completed/project-x/
  ./archive/cancelled/project-a/
./ => projects in progress
  ./project-y/

The structure within project folders can be designed as you see fit.
Further project info will be conveyed through roadmaps/milestones/phases/plans.
```

### Create Roadmap

```
/gsd:create-roadmap
```

If the result doesn't fit, have it adjusted as needed.

### Plan Phases

Once the roadmap is satisfactory:

```
/clear
/gsd:plan-phase 1
```

Plan all phases. Use `/hydra` commands for parallel work IF BENEFICIAL (not when worktree setup overhead exceeds the benefit). If parallel doesn't work, do it sequentially.

### Execute Phases

```
/clear
/gsd:execute-phase 1
/clear
/gsd:execute-phase 2
/clear
/gsd:execute-phase 3
/clear
...
```

Continue until all phases are complete.

### Complete Milestone

```
/clear
/gsd:complete-milestone
```

Choose: yes / wait / adjust

---

**The project is now initialized and ready for use.**

### For This Acquisition Example

Start working directly without needing additional skills.

### For Development Projects (Code and Features)

Continuously use these to extend/debug/develop code:

```
/clear
/gsd:new-milestone   # Plan next milestone
```

or

```
/clear
/gsd:verify-work     # Manual acceptance tests
```

### Hydra Example Prompt

```
Use /hydra to do the following in a worktree:

plugin signal improvement:
permission required signals - where user REALLY needs to act, play the same
sound as on finish, so user hears they're up again (ensure cross-platform
compatibility: Linux, macOS, Windows)

For worktrees, adjust .claude/settings.json BEFORE spawning:
Example if agent would be disturbed by linting:
{
  "env": {
    "CLAUDE_MB_DOGMA_LINT_ON_STOP": "false",
    "CLAUDE_MB_DOGMA_PRE_COMMIT_LINT": "false",
    "CLAUDE_MB_DOGMA_SKIP_LINT_CHECK": "true"
  }
}

The env variables in ~/.claude/settings.json serve as template.
Adjust per worktree as needed (only disable what's truly necessary,
e.g., debug or linting!).

If an agent fails due to hooks: fix settings and respawn the agent.
```

---

## The Full Commandments (Wiki Reference)

The preacher's guide above covers the blessed path. But the faithful may seek deeper knowledge of all available commands. Here lies the complete scripture.

### Dogma - The Full Arsenal

Beyond what the main workflow covers, dogma offers these additional rituals:

| Command | Purpose |
|---------|---------|
| `/dogma:lint` | Run linting and formatting on staged files (non-interactive) |
| `/dogma:cleanup` | Find and purge AI-typical patterns from your code |
| `/dogma:permissions` | Create or update DOGMA-PERMISSIONS.md interactively |
| `/dogma:force` | Apply all CLAUDE rules to your project with full control |
| `/dogma:sanitize-git` | Cleanse git history from Claude/AI traces |
| `/dogma:docs-update` | Synchronize documentation across README and wiki |
| `/dogma:ignore:sync-all` | Sync ignore patterns to all local repositories (marketplace only) |

**The preacher's wisdom:**

```
# After making changes, ensure code is clean
/dogma:lint

# Suspicious AI traces in your codebase? Purify it
/dogma:cleanup src/

# Setting up a new project? Create permissions first
/dogma:permissions

# Apply all rules at once with review
/dogma:force

# Before pushing to public: cleanse the history
/dogma:sanitize-git
```

### Hydra - The Complete Spawning Ritual

The parallel development section showed individual commands. Here is the full liturgy:

| Command | Purpose |
|---------|---------|
| `/hydra:parallel` | Spawn multiple agents simultaneously across worktrees |
| `/hydra:list` | Show all worktrees with paths and branches |
| `/hydra:status` | Detailed status including uncommitted changes |

**The preacher's preferred invocation for parallel work:**

```
# Create worktrees for each feature
/hydra:create feature-auth
/hydra:create feature-api
/hydra:create feature-ui

# Spawn all agents at once (the true power of hydra)
/hydra:parallel feature-auth:Implement login | feature-api:Create endpoints | feature-ui:Build components

# Monitor the congregation
/hydra:watch

# Check individual progress
/hydra:status feature-auth

# See all worktrees
/hydra:list
```

### Import - The Complete Scrolls

| Command | Purpose |
|---------|---------|
| `/import:url-or-path` | Import from URL or local file path |
| `/import:list` | List all cached documentation |
| `/import:search` | Search within cached docs |
| `/import:update` | Re-fetch from original source |

### Signal - Silent Watcher

Signal has no user-invocable commands - it works through hooks that notify you when Claude needs attention or completes work. The faithful need not call upon it directly; it watches over them.

### Limit - The Measure of All Things

Limit displays in your statusline automatically. No commands to invoke - simply observe your API usage, tokens, and costs as you work.

---

**For the complete scripture of each plugin, consult the wiki:**
https://github.com/Marcel-Bich/marcel-bich-claude-marketplace/wiki
