---
description: hydra - Show detailed status of one or all worktrees
arguments:
  - name: name
    description: Specific worktree (optional, otherwise all)
    required: false
allowed-tools:
  - Bash
---

# Worktree Status

You are executing the `/hydra:status` command. Show detailed status of one or all worktrees.

## Arguments

- `$ARGUMENTS` - Optional: Name of a specific worktree

## Process

### 1. Get Worktree List

```bash
git worktree list --porcelain
```

### 2. For Each Worktree (or Only Specified)

Switch to the worktree directory and gather info:

```bash
# Status
git -C {worktree-path} status --short

# Last commit
git -C {worktree-path} log -1 --oneline

# Ahead/behind main
git -C {worktree-path} rev-list --left-right --count main...HEAD 2>/dev/null
```

### 3. Format Output

**All worktrees:**

```
Worktree Status:

[main] /home/user/project
  Branch: main
  Status: clean
  Commit: a1b2c3d - Initial commit (2h ago)

[feature-a] /home/user/project-worktrees/feature-a
  Branch: hydra/feature-a
  Status: 2 modified, 1 untracked
  Commit: d4e5f6g - Add feature A (30m ago)
  Ahead: 3 commits | Behind: 0

[feature-b] /home/user/project-worktrees/feature-b
  Branch: hydra/feature-b
  Status: clean
  Commit: h7i8j9k - Implement B (1h ago)
  Ahead: 5 commits | Behind: 2
```

**Single worktree (detailed):**

```
Worktree: feature-a
Path: /home/user/project-worktrees/feature-a
Branch: hydra/feature-a

Status:
  M  src/feature.ts
  M  tests/feature.test.ts
  ?? src/new-file.ts

Last Commit:
  d4e5f6g - Add feature A
  Author: User <user@example.com>
  Date: 30 minutes ago

Comparison to main:
  Ahead: 3 commits
  Behind: 0 commits
```

### 4. Error Handling

If worktree not found:

```
Worktree '{name}' not found.

Available worktrees:
  - main (Main)
  - feature-a
  - feature-b

Show all with: /hydra:list
```

## Notes

- Without argument, all worktrees are shown
- With argument, only the specific one (more detailed)
- "Behind" shows if main has new commits not in the worktree
