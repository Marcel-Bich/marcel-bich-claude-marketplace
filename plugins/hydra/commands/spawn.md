---
description: hydra - Start an agent in an existing worktree
arguments:
  - name: worktree
    description: Name of the worktree
    required: true
  - name: prompt
    description: Task for the agent
    required: true
allowed-tools:
  - Bash
  - Task
  - Read
---

# Worktree Spawn

You are executing the `/hydra:spawn` command. Start an agent in an existing worktree.

## Arguments

`$ARGUMENTS` is parsed as:
- First word: Worktree name
- Rest: Prompt for the agent

Example: `feature-a Implement the new feature`
- worktree: `feature-a`
- prompt: `Implement the new feature`

## Process

### 1. Parse Arguments

```bash
# First word = Worktree
WORKTREE_NAME=$(echo "$ARGUMENTS" | awk '{print $1}')

# Rest = Prompt
AGENT_PROMPT=$(echo "$ARGUMENTS" | cut -d' ' -f2-)
```

If either is missing, show help:

```
Usage: /hydra:spawn {worktree} {prompt}

Example:
  /hydra:spawn feature-a "Implement login form"
```

### 2. Check if Worktree Exists

```bash
git worktree list | grep -E "$WORKTREE_NAME|hydra/$WORKTREE_NAME"
```

If not found:

```
Worktree '{name}' not found.

Options:
1. Create it first: /hydra:create {name}
2. Show available: /hydra:list
```

### 3. Determine Absolute Path

```bash
WORKTREE_PATH=$(git worktree list --porcelain | grep -B1 "$WORKTREE_NAME" | grep "worktree " | head -1 | cut -d' ' -f2-)

# Convert to absolute path
WORKTREE_PATH=$(cd "$WORKTREE_PATH" && pwd)
```

### 4. Start Agent with Task Tool

Use the Task tool with these parameters:

```
subagent_type: general-purpose
run_in_background: true (optional, depending on task)
prompt: [see below]
```

**Construct agent prompt:**

```
You are working in an isolated Git worktree.

IMPORTANT - Your working directory:
  {WORKTREE_PATH}

All file operations must be relative to this directory.
Use absolute paths or ensure you are in the correct directory.

Your task:
{AGENT_PROMPT}

When finished:
1. Commit your changes in the worktree
2. Show git status and git log -3
```

### 5. Output

After starting:

```
Agent started in worktree '{name}':

  Worktree path: {path}
  Task: {prompt}
  Agent ID: {id if background}

Next steps:
  - /hydra:status {name}       # Check progress
  - TaskOutput with agent ID   # Get result (if background)
  - /hydra:merge {name}        # When done: merge back
```

## Notes

- The agent works completely isolated in the worktree
- No conflicts with other parallel agents
- Agent should commit at the end
- Use `run_in_background: true` for long tasks
