---
description: hydra - Show available commands and explain the concept
allowed-tools:
  - Bash
---

# Hydra Plugin Help

You are executing the `/hydra:help` command. Show the user available commands and explain the Git worktree concept.

## What are Git Worktrees?

Git worktrees allow having multiple branches checked out simultaneously in different directories. Each worktree has:

- Its own working directory
- Its own index (staging area)
- Its own HEAD

This means: Parallel work on different features without `git stash` or branch switching.

## Why for Claude Agents?

When multiple agents need to work in parallel, each needs its own directory. Otherwise:

- Git conflicts during simultaneous commits
- Overwriting changes
- Chaos in staging area

With worktrees, each agent gets its own isolated working directory.

## Available Commands

Show currently available commands:

```bash
grep -A2 "^  [a-z]" "${CLAUDE_PLUGIN_ROOT:-$(dirname $(dirname $0))}/plugin.yaml" 2>/dev/null || echo "Could not read plugin.yaml"
```

## Typical Workflow

```
1. /hydra:create feature-x       # Create worktree
2. /hydra:spawn feature-x "..."  # Agent works there
3. /hydra:status                 # Check progress
4. /hydra:merge feature-x        # Integrate changes
5. /hydra:cleanup                # Clean up
```

## More Information

- Git worktree documentation: `git worktree --help`
- Plugin wiki for detailed guide
