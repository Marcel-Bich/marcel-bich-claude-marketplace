# hydra

Git Worktree management for parallel agent execution - isolated working directories without Git conflicts.

## Features

### Slash Commands

- `/hydra:help` - Show available commands and explain the concept
- `/hydra:create` - Create a new worktree with its own branch
- `/hydra:list` - List all Git worktrees of the repository
- `/hydra:status` - Detailed status of one or all worktrees
- `/hydra:delete` - Safely remove a worktree with confirmation
- `/hydra:spawn` - Start an agent in a worktree
- `/hydra:parallel` - Multiple agents in parallel across worktrees
- `/hydra:watch` - Live monitoring of background agents with status table
- `/hydra:merge` - Merge worktree branch back (merge or rebase)
- `/hydra:cleanup` - Automatically remove already merged worktrees

### Worktree Setup and Cleanup

- `scripts/worktree-setup.sh <worktree-path> [main-checkout]` runs right after `git worktree add` (in `/hydra:create` and `/hydra:parallel`). A fresh worktree only has versioned files; the setup links (relative symlinks) or copies the excluded ones agents need - the "Worktree files" list in the `### Hydra` subsection of DOGMA-PERMISSIONS.md (read via dogma when installed), else CLAUDE.md, CLAUDE/, GUIDES/, DOGMA-PERMISSIONS.md and everything unversioned under `.credo/`. Versioned paths are skipped, existing paths are never overwritten. It prints the main checkout path, which spawned agents get for read-only lookups.
- `/hydra:cleanup` removes only worktrees whose branch is fully merged and that have no changes to tracked files. With credo installed this happens automatically at item close, controlled by `[x] clean up merged worktrees automatically` in DOGMA-PERMISSIONS.md.

### Typical Workflow

```bash
# 1. Create worktrees
/hydra:create feature-a
/hydra:create feature-b

# 2. Start agents in parallel
/hydra:parallel feature-a:Implement login | feature-b:Implement logout

# 3. Monitor agents live
/hydra:watch

# 4. Check status
/hydra:status

# 5. Merge back when done
/hydra:merge feature-a
/hydra:merge feature-b

# 6. Clean up
/hydra:cleanup
```

## Installation

```bash
claude plugin marketplace add Marcel-Bich/marcel-bich-claude-marketplace
claude plugin install hydra@marcel-bich-claude-marketplace
```

## Documentation

Full documentation, usage examples, and troubleshooting:

**[View Documentation on Wiki](https://github.com/Marcel-Bich/marcel-bich-claude-marketplace/wiki/Claude-Code-Hydra-Plugin)**

## License

MIT - See [LICENSE](LICENSE) for full terms.

---

<details>
<summary>Keywords / Tags</summary>

Claude Code, Claude Code Plugin, Claude Code Extension, Claude Code Hydra, Claude Code Git Worktree, Claude Code Parallel, Claude Code Parallel Agents, Claude Code Multi Agent, Claude Code Isolation, Claude Code Concurrent, Claude Code Background, Claude Code Task, Claude Code Spawn, Claude Code Branch, Claude Code Merge, Claude Code Rebase, Anthropic CLI, Anthropic Plugin, Anthropic Extension, Anthropic Claude, Anthropic AI, AI Agent Parallel, AI Agent Concurrent, AI Agent Isolation, AI Agent Multi, AI Code Assistant, AI Coding, AI Programming, AI Development, Git Worktree, Git Worktree Add, Git Worktree List, Git Worktree Remove, Git Branch, Git Merge, Git Rebase, Git Isolation, Git Parallel, Git Concurrent, Parallel Development, Concurrent Development, Feature Branches, Branch Management, Worktree Management, Isolated Environment, Separate Working Directory, Multiple Branches, Simultaneous Work, Background Tasks, Autonomous Agents, Agent Coordination, Agent Spawning, Task Tool, Subagent, Marcel Bich, marcel-bich-claude-marketplace, hydra plugin, parallel plugin, isolation plugin

</details>
