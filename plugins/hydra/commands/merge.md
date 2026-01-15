---
description: hydra - Merge a worktree branch back into current branch
arguments:
  - name: worktree
    description: Name of the worktree whose branch will be merged
    required: true
  - name: strategy
    description: "merge (default) or rebase"
    required: false
allowed-tools:
  - Bash
  - AskUserQuestion
---

# Worktree Merge

You are executing the `/hydra:merge` command. Merge a worktree branch back into the current branch.

## Arguments

- `$ARGUMENTS` is parsed as:
  - First word: Worktree name
  - Second word (optional): Strategy (merge/rebase)

Examples:
- `/hydra:merge feature-a` - Merge with default strategy
- `/hydra:merge feature-a rebase` - Rebase instead of merge

## Process

### 1. Parse Arguments and Validate

```bash
WORKTREE_NAME=$(echo "$ARGUMENTS" | awk '{print $1}')
STRATEGY=$(echo "$ARGUMENTS" | awk '{print $2}')
STRATEGY=${STRATEGY:-merge}  # Default: merge

# Validate strategy
if [[ "$STRATEGY" != "merge" && "$STRATEGY" != "rebase" ]]; then
  echo "Unknown strategy: $STRATEGY (allowed: merge, rebase)"
  exit 1
fi
```

### 2. Check if Worktree Exists

```bash
git worktree list | grep -qE "$WORKTREE_NAME|hydra/$WORKTREE_NAME" || {
  echo "Worktree '$WORKTREE_NAME' not found"
  exit 1
}
```

### 3. Determine Branch Names

```bash
WORKTREE_BRANCH=$(git worktree list --porcelain | grep -A2 "$WORKTREE_NAME" | grep "branch " | sed 's/branch refs\/heads\///')
CURRENT_BRANCH=$(git branch --show-current)

echo "Merge: $WORKTREE_BRANCH -> $CURRENT_BRANCH"
```

### 4. Check for Uncommitted Changes

**In current directory (blocks):**

```bash
if [[ -n $(git status --porcelain) ]]; then
  echo "ERROR: Uncommitted changes in current directory"
  echo "Commit or stash your changes first."
  git status --short
  exit 1
fi
```

**In worktree (warning):**

```bash
WORKTREE_PATH=$(git worktree list | grep "$WORKTREE_NAME" | awk '{print $1}')
if [[ -n $(git -C "$WORKTREE_PATH" status --porcelain) ]]; then
  echo "WARNING: Uncommitted changes in worktree '$WORKTREE_NAME'"
  git -C "$WORKTREE_PATH" status --short
  # Ask whether to continue
fi
```

### 5. Show What Will Be Merged

```bash
echo "The following commits will be merged:"
git log --oneline "$CURRENT_BRANCH".."$WORKTREE_BRANCH"

echo ""
echo "Affected files:"
git diff --stat "$CURRENT_BRANCH"..."$WORKTREE_BRANCH"
```

### 6. Execute Merge/Rebase

**Merge:**

```bash
git merge "$WORKTREE_BRANCH" -m "Merge hydra/$WORKTREE_NAME"
```

**Rebase:**

```bash
git rebase "$WORKTREE_BRANCH"
```

### 7. Conflict Handling

If conflicts occur:

```
MERGE CONFLICT detected!

Affected files:
{git status --short shows UU for conflicts}

Options:
1. Resolve conflicts manually:
   - Edit the marked files
   - git add {file}
   - git commit (for merge) or git rebase --continue

2. Abort merge:
   - git merge --abort (for merge)
   - git rebase --abort (for rebase)

3. Keep their version (ours):
   - git checkout --ours {file}

4. Keep their version (theirs):
   - git checkout --theirs {file}
```

### 8. Success Output

```
Merge successful!

  From: hydra/$WORKTREE_NAME
  To: $CURRENT_BRANCH
  Commits: X

Merged files:
{diff --stat output}

Next steps:
  - /hydra:delete $WORKTREE_NAME   # Clean up worktree
  - /hydra:cleanup                  # Clean up all merged
  - git push                        # If desired
```

## Safety Features

- No automatic force-push
- Clear display of what will be merged BEFORE it happens
- Conflict handling with abort option
- Uncommitted changes in main directory block operation
