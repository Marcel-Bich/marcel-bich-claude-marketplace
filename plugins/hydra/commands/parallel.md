---
description: hydra - Start multiple agents in parallel across worktrees
arguments:
  - name: tasks
    description: "Tasks in format: worktree1:prompt1 | worktree2:prompt2"
    required: true
allowed-tools:
  - Bash
  - Task
  - Read
---

# Worktree Parallel

You are executing the `/hydra:parallel` command. Start multiple agents simultaneously in different worktrees.

## Arguments

`$ARGUMENTS` is parsed as a pipe-separated list of tasks:

```
worktree1:prompt1 | worktree2:prompt2 | worktree3:prompt3
```

Example:
```
/hydra:parallel feature-a:Implement login | feature-b:Implement logout | feature-c:Write tests
```

## Process

### 1. Parse Tasks

Split `$ARGUMENTS` at `|` and parse each part:

```bash
# Example parsing
echo "$ARGUMENTS" | tr '|' '\n' | while read task; do
  WORKTREE=$(echo "$task" | cut -d':' -f1 | xargs)
  PROMPT=$(echo "$task" | cut -d':' -f2- | xargs)
  echo "Worktree: $WORKTREE, Prompt: $PROMPT"
done
```

### 2. Validate All Worktrees

For each task:

```bash
git worktree list | grep -qE "$WORKTREE|hydra/$WORKTREE"
```

If a worktree is missing, offer to create it:

```
The following worktrees do not exist:
  - feature-x
  - feature-y

Should I create them? (Branches will be forked from main)
```

If yes, create missing worktrees:

```bash
# Determine paths (always relative to repo root, not CWD)
REPO_ROOT=$(git rev-parse --show-toplevel)
REPO_NAME=$(basename "$REPO_ROOT")
WORKTREES_DIR="$(dirname "$REPO_ROOT")/${REPO_NAME}-worktrees"

for WT in feature-x feature-y; do
  git worktree add -b "hydra/$WT" "$WORKTREES_DIR/$WT"
  # bring excluded files (rules, .credo/, ...) into the fresh worktree
  "${CLAUDE_PLUGIN_ROOT}/scripts/worktree-setup.sh" "$WORKTREES_DIR/$WT"
done
```

Run `worktree-setup.sh` right after every `git worktree add` (see `/hydra:create`).

### 3. Start All Agents in Parallel

**IMPORTANT:** Use a single response with multiple Task tool calls!

For each task, call Task tool with:

```
subagent_type: general-purpose
run_in_background: true
prompt: [like in /hydra:spawn]
```

Every prompt also names the absolute main checkout path (the `main=` line of `worktree-setup.sh`) with this rule: when something important is missing in the worktree (neither checked out, linked nor copied), look it up READ-ONLY in the main checkout; never write, commit or run state-changing git commands there; mention in the report anything that should be added to the worktree files list. Inside its own worktree the agent may commit on its worktree branch, but never push or merge - that stays with the main agent.

All Task calls must be in ONE response for true parallelism.

### 4. Collect Results

After starting all agents:

```
Parallel agents started:

  Worktree      | Agent ID        | Task
  --------------|-----------------|---------------------------
  feature-a     | agent-abc123    | Implement login
  feature-b     | agent-def456    | Implement logout
  feature-c     | agent-ghi789    | Write tests

All agents running in background.

Next steps:
  - /hydra:status                # Progress of all worktrees
  - TaskOutput agent-abc123      # Result of one agent
  - /hydra:merge feature-a       # When done: merge individually
```

## Input Format Alternatives

If JSON preferred:

```json
[
  {"worktree": "feature-a", "prompt": "Implement login"},
  {"worktree": "feature-b", "prompt": "Implement logout"}
]
```

If line breaks:

```
feature-a: Implement login
feature-b: Implement logout
feature-c: Write tests
```

Detect the format automatically and parse accordingly.

## Notes

- Maximum parallelism: ~3-5 agents (system limit)
- Each agent works in isolation
- No Git conflicts between agents
- Results can finish in any order
