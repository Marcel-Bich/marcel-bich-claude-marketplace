---
description: hydra - Remove already merged worktrees and their branches
arguments:
  - name: dry-run
    description: "Show only what would be removed (optional: --dry-run)"
    required: false
allowed-tools:
  - Bash
  - AskUserQuestion
---

# Worktree Cleanup

You are executing the `/hydra:cleanup` command. Remove already merged worktrees and their branches.

## Arguments

- `$ARGUMENTS`:
  - `--dry-run` or `-n`: Show only what would be removed
  - Empty: Perform cleanup with confirmation

## Process

### 1. Determine Mode

```bash
DRY_RUN=false
if [[ "$ARGUMENTS" == "--dry-run" || "$ARGUMENTS" == "-n" ]]; then
  DRY_RUN=true
fi
```

### 2. Collect All Worktrees

```bash
# All worktrees except the main worktree
git worktree list | tail -n +2
```

### 3. Check Each Worktree for Merge Status

For each worktree:

```bash
# Branch of the worktree
BRANCH=$(git worktree list --porcelain | grep -A2 "$WORKTREE_PATH" | grep "branch " | sed 's/branch refs\/heads\///')

# Is the branch merged into main/master?
MAIN_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || echo "main")

git branch --merged "$MAIN_BRANCH" | grep -q "$BRANCH"
if [[ $? -eq 0 ]]; then
  echo "MERGED: $WORKTREE_NAME ($BRANCH)"
else
  echo "NOT MERGED: $WORKTREE_NAME ($BRANCH)"
fi
```

### 4. Show Cleanup Candidates

```
Cleanup Analysis:

MERGED worktrees (will be removed):
  - feature-a (hydra/feature-a) - 3 commits, merged 2 days ago
  - feature-b (hydra/feature-b) - 5 commits, merged 1 week ago

NOT MERGED worktrees (will be kept):
  - feature-c (hydra/feature-c) - 2 commits, still open
  - feature-d (hydra/feature-d) - 7 commits, still open

{If dry-run}
--dry-run mode: No changes made.
Run without --dry-run to clean up.
```

### 5. Confirmation (if not dry-run)

If not `--dry-run` and there are candidates:

Use AskUserQuestion:

```
Should the following worktrees and branches be removed?

  - feature-a (hydra/feature-a)
  - feature-b (hydra/feature-b)

Options:
- Remove all
- Confirm individually
- Cancel
```

### 6. Perform Cleanup

For each confirmed worktree:

```bash
# Remove worktree
git worktree remove "$WORKTREE_PATH"

# Remove branch
git branch -d "$BRANCH"
```

### 7. Output

```
Cleanup completed:

Removed:
  - feature-a (worktree + branch)
  - feature-b (worktree + branch)

Kept (not merged):
  - feature-c
  - feature-d

Total: 2 worktrees removed, 2 kept
```

If no candidates:

```
No already merged worktrees found.

Active worktrees:
  - feature-c (hydra/feature-c) - 2 commits
  - feature-d (hydra/feature-d) - 7 commits

Use /hydra:merge {name} to merge worktrees.
```

## Safety Features

- Only fully merged branches are removed
- No force-delete (`git branch -d` not `-D`)
- Confirmation before deletion (except dry-run)
- Non-merged worktrees are always kept
