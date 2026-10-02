---
description: hydra - Create a new Git worktree for isolated work
arguments:
  - name: name
    description: Name/branch for the worktree
    required: true
allowed-tools:
  - Bash
  - Read
---

# Worktree Create

You are executing the `/hydra:create` command. Create a new Git worktree for isolated work.

## Arguments

- `$ARGUMENTS` - Name for the worktree (also becomes branch name)

## Process

### 1. Check Prerequisites

```bash
# Git repo?
git rev-parse --git-dir 2>/dev/null || { echo "Error: Not a Git repository"; exit 1; }

# Repo name for path
basename "$(git rev-parse --show-toplevel)"
```

### 2. Prepare Parameters

If `$ARGUMENTS` is empty, ask for the name.

Determine:
- **Branch name**: `hydra/$ARGUMENTS` (or just `$ARGUMENTS` if already path-like)
- **Worktree path**: `../{repo-name}-worktrees/$ARGUMENTS/`

### 3. Check if Already Exists

```bash
# Worktree with this name?
git worktree list | grep -q "$ARGUMENTS" && echo "Worktree already exists"

# Branch exists?
git show-ref --verify --quiet "refs/heads/hydra/$ARGUMENTS" && echo "Branch exists"
```

If worktree exists: Show path and exit with hint.

### 4. Create Worktree

```bash
# Determine path (always relative to repo root, not CWD)
REPO_ROOT=$(git rev-parse --show-toplevel)
REPO_NAME=$(basename "$REPO_ROOT")
WORKTREE_PATH="$(dirname "$REPO_ROOT")/${REPO_NAME}-worktrees/$ARGUMENTS"

# Create directory if needed
mkdir -p "$(dirname "$WORKTREE_PATH")"

# Create worktree with new branch
git worktree add -b "hydra/$ARGUMENTS" "$WORKTREE_PATH"

# Bring excluded files (CLAUDE.md, CLAUDE/, GUIDES/, DOGMA-PERMISSIONS.md, .credo/, ...)
# into the new worktree - a fresh worktree only has versioned files
"${CLAUDE_PLUGIN_ROOT}/scripts/worktree-setup.sh" "$WORKTREE_PATH"
```

`worktree-setup.sh` links (relative symlinks) or copies the paths of the worktree files list: the "Worktree files" list in the `### Hydra` subsection of DOGMA-PERMISSIONS.md (read via dogma's `worktree-files.sh` when dogma is installed), else the default list (link CLAUDE.md, CLAUDE/, GUIDES/, DOGMA-PERMISSIONS.md and everything unversioned under .credo/, each only if it exists). Versioned paths are skipped, existing paths are never overwritten, and untracked paths that are not ignored in the main checkout are skipped (`skipped <path> (untracked, not ignored ...)`; agents read them in the main checkout). Always run it right after `git worktree add`; report its `linked` / `copied` lines in the output.

### 5. Output

On success:

```
Worktree created:

  Path:   {absolute path}
  Branch: hydra/{name}
  Main:   {main checkout path}   (read-only lookups of anything missing in the worktree)
  Setup:  {linked / copied paths from worktree-setup.sh}

Next steps:
  - cd {path}                     # Switch manually
  - /hydra:spawn {name} "..."     # Start agent there
  - /hydra:status                 # Check status
```

On error:

```
Error creating worktree:

{git error message}

Possible causes:
- Worktree already exists
- Branch name already taken
- No write permission in target directory
```

## Notes

- Uncommitted changes in current directory do NOT block creation
- New worktree starts from current HEAD
- Branch prefix `hydra/` helps with organization
- Merged and clean worktrees are removed by `/hydra:cleanup` (or automatically by credo at item close, see `/hydra:cleanup`)
