---
description: hydra - List all Git worktrees of the repository
allowed-tools:
  - Bash
---

# Worktree List

You are executing the `/hydra:list` command. Show all Git worktrees of the current repository.

## Process

### 1. Check Git Repository

```bash
git rev-parse --git-dir 2>/dev/null || { echo "Error: Not a Git repository"; exit 1; }
```

### 2. List Worktrees

```bash
git worktree list
```

### 3. Format Output

Parse the output and display clearly:

```
Git Worktrees:

  Path                              Branch              Commit
  ----------------------------------------------------------------
  /home/user/project                main                a1b2c3d
  /home/user/project-worktrees/a    hydra/feature-a     d4e5f6g
  /home/user/project-worktrees/b    hydra/feature-b     h7i8j9k
```

### 4. Additional Info

For each worktree optionally show:
- Lock status (if locked)
- Prunable status (if orphaned)

```bash
# Check lock status
git worktree list --porcelain | grep -A3 "worktree"
```

### 5. If No Worktrees

If only the main worktree exists:

```
Only the main worktree exists (main/master).

Create a new one with:
  /hydra:create {name}
```

## Output Format

Compact table with all relevant info at a glance.
