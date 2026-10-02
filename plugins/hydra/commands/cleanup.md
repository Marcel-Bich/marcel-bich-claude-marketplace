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

### 3. Check Each Worktree (same criteria as credo's automatic cleanup)

A worktree is a removal candidate only when ALL of these hold - otherwise it is kept and listed with its reason:
- not the main worktree, not the worktree you are in, not locked, not on a detached HEAD
- its branch is fully merged into the main branch (the branch checked out in the main worktree)
- no changes to tracked files (`git -C <wt> status --porcelain --untracked-files=no` is empty); untracked scratch (cache/, the symlinks from `worktree-setup.sh`) goes with it
- a branch that never got a commit may belong to an agent that just started: keep it while it is younger than 24h or has untracked, non-ignored files

When credo is installed, its `credo-worktree-cleanup.sh [--dry-run] [--json]` implements exactly these checks; prefer it:

```bash
CREDO_CLEANUP=$(ls -d "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"/plugins/cache/*/credo/*/scripts/credo-worktree-cleanup.sh 2>/dev/null | sort -V | tail -1)
[ -n "$CREDO_CLEANUP" ] && "$CREDO_CLEANUP" --dry-run
```

Without credo, check by hand:

For each worktree:

```bash
# Branch of the worktree
BRANCH=$(git worktree list --porcelain | grep -A2 "$WORKTREE_PATH" | grep "branch " | sed 's/branch refs\/heads\///')

# Main branch = branch checked out in the main worktree
MAIN_BRANCH=$(git worktree list --porcelain | awk 'NF==0{exit} /^branch /{sub(/^branch refs\/heads\//,""); print; exit}')

git merge-base --is-ancestor "refs/heads/$BRANCH" "refs/heads/$MAIN_BRANCH"
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
# Remove worktree (--force only for verified merged+clean candidates: it lets git
# drop untracked scratch; git unlinks symlinks and never follows them)
git worktree remove --force "$WORKTREE_PATH"

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

## Automatic cleanup at item close (credo)

With credo installed, closing an item (move to done, verified or archived) runs the same cleanup automatically, controlled by the checkbox in the `### Hydra` subsection of DOGMA-PERMISSIONS.md:

```
- [x] clean up merged worktrees automatically
```

`[x]` removes merged+clean worktrees without asking, `[?]` (or no checkbox) lists them and asks, `[ ]` never. Every run covers all worktrees of the repo, so older ones are swept too.

## Safety Features

- Main worktree (project root) is NEVER touched - always excluded
- Only fully merged branches with no changes to tracked files are removed
- Locked worktrees and fresh worktrees without commits (an agent may be starting) are kept
- No force-delete (`git branch -d` not `-D`)
- Confirmation before deletion (except dry-run)
- Non-merged worktrees are always kept
