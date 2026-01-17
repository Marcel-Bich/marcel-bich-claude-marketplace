---
description: hydra - Safely remove a Git worktree
arguments:
  - name: name
    description: Name of the worktree to delete
    required: true
allowed-tools:
  - Bash
  - AskUserQuestion
---

# Worktree Delete

You are executing the `/hydra:delete` command. Safely remove a Git worktree with data loss protection.

## Arguments

- `$ARGUMENTS` - Name of the worktree to delete (required)

## Process

### 1. Check if Worktree Exists

**IMPORTANT:** The main worktree (first in list, usually main/master branch) must NEVER be deleted.
When listing available worktrees, always exclude the main worktree (first line of `git worktree list`).

```bash
# List only secondary worktrees (skip first line = main worktree)
git worktree list | tail -n +2 | grep -E "$ARGUMENTS|hydra/$ARGUMENTS"
```

If user tries to delete main/master:
```
ERROR: Cannot delete the main worktree. This is your project root.
```

If not found:

```
Worktree '{name}' not found.

Available worktrees:
{list}

Tip: Use /hydra:list for an overview.
```

### 2. Determine Path and Branch

```bash
# Find exact path
WORKTREE_PATH=$(git worktree list --porcelain | grep -A2 "worktree.*$ARGUMENTS" | grep "worktree " | cut -d' ' -f2-)

# Find branch
WORKTREE_BRANCH=$(git worktree list --porcelain | grep -A2 "worktree.*$ARGUMENTS" | grep "branch " | sed 's/branch refs\/heads\///')
```

### 3. Check for Uncommitted Changes

```bash
cd "$WORKTREE_PATH"
git status --porcelain
```

If uncommitted changes exist, use AskUserQuestion:

```
WARNING: Worktree '{name}' has unsaved changes:

{git status output}

These changes will be lost!

Question: Delete anyway?
Options:
- Yes, delete (discard changes)
- No, cancel
```

### 4. Remove Worktree

```bash
# Return to main directory
cd "$(git worktree list | head -1 | awk '{print $1}')"

# Remove worktree
git worktree remove "$WORKTREE_PATH"
```

If locked:

```bash
# With --force if locked
git worktree remove --force "$WORKTREE_PATH"
```

### 5. Optional: Delete Branch

Ask if the branch should also be deleted:

```
Worktree removed.

The branch '{branch}' still exists.
Should it also be deleted?

Options:
- Yes, delete branch (git branch -d {branch})
- No, keep branch
```

If yes:

```bash
git branch -d "$WORKTREE_BRANCH"
```

If branch not merged:

```
Branch cannot be deleted - not yet merged.
Use 'git branch -D {branch}' for forced deletion.
```

### 6. Output

On success:

```
Worktree deleted:

  Path:   {path} (removed)
  Branch: {branch} (kept/deleted)

Remaining worktrees: /hydra:list
```

## Safety Features

- Uncommitted changes are ALWAYS shown
- Confirmation required for unsaved changes
- Branch deletion is optional and separate
- No --force without explicit consent
