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

- `scripts/worktree-setup.sh <worktree-path> [main-checkout]` runs right after `git worktree add` (in `/hydra:create` and `/hydra:parallel`). A fresh worktree only has versioned files; the setup links (relative symlinks) or copies the excluded ones agents need - the "Worktree files" list in the `### Hydra` subsection of DOGMA-PERMISSIONS.md (read via dogma when installed), else CLAUDE.md, CLAUDE/, GUIDES/, DOGMA-PERMISSIONS.md and everything unversioned under `.credo/`. Versioned paths are skipped, existing paths are never overwritten, and untracked paths that are not ignored (e.g. a new uncommitted item file) are skipped with a hint instead of linked or copied - a `git add -A` in the worktree would commit the link. It prints the main checkout path, which spawned agents get for read-only lookups. On native Windows (Git Bash) links are native Windows symlinks; when Windows refuses them (no Developer Mode, no admin) the path is skipped with a hint instead of silently copied. Directory junctions are not used: Git for Windows treats a junction as a plain directory, so a forced worktree removal would delete the main checkout's files through it. No Python is needed for the links.
- `/hydra:cleanup` removes only worktrees whose branch is fully merged and that have no changes to tracked files. Setup symlinks into the main checkout do not count as changes, and a merged worktree whose only leftovers are `.credo/` changes already present in the main checkout (lossless) is removed too. With credo installed this happens automatically at item close, controlled by `[x] clean up merged worktrees automatically` in DOGMA-PERMISSIONS.md.

### Worktree Guard

A PreToolUse hook (`hooks/hooks.json`, logic in `scripts/worktree-guard.py`) keeps every worktree on hydra's flow while hydra is installed and the `Hydra` checkbox `use Hydra for 2+ independent tasks` in DOGMA-PERMISSIONS.md is on. A missing checkbox or file counts as on. With `[ ]` or `[0]` the guard is off; with `[?]` (ask) it lets the calls through as well.

- The Agent (or Task) tool with `isolation: "worktree"` is denied.
- `EnterWorktree` without a `path` is denied (it creates a worktree). With a `path` it enters an existing worktree and creates nothing, so it is allowed.
- `git worktree add` in command position (also after `cd`, with `git -C`, after `NAME=value` assignments or in a `&&`, `;` or `|` chain) is denied unless the destination is `../<repo>-worktrees/<name>` next to the main checkout. Shell variables and globs in the destination are denied too; write the path literally. Redirects around the destination are skipped, and a command that cannot be parsed (unbalanced quotes) is allowed.
- Only `git` in command position counts. Text in comments, in `echo` arguments and in a `git commit -F -` heredoc message is not checked, so `echo "git worktree add ..."` and a `# git worktree add ...` comment are allowed.

The deny message names the flow to use: `/hydra:create <name>`, or `git worktree add -b hydra/<name> ../<repo>-worktrees/<name>` followed by `scripts/worktree-setup.sh`. The guard fails open (an internal error allows the call) and makes no network calls. It looks for Python 3 as `python3`, then `python`, then `py -3` (native Windows ships no `python3.exe`; the Microsoft Store stub is rejected). On native Windows, MSYS paths (`/c/...`), `C:/...` and `C:\...` are compared case-insensitively, and a destination on another drive counts as outside the hydra folder. Without any Python 3 the guard is not silently off: it denies the Agent/Task isolation and `EnterWorktree` calls above and any `git worktree add` without a `../<repo>-worktrees/` destination (unless the checkbox is off), and the first call of a session shows a one-time message.

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

## Windows limitations

On native Windows (Claude Code native, hooks run by Git Bash) the worktree guard and `worktree-setup.sh` work, with two limits:

- **Symlinks need Developer Mode** (Settings > System > For developers) or admin rights. Without them Windows refuses the native symlinks `worktree-setup.sh` creates; the path is skipped with a hint and read in the main checkout. It is never copied (a copy would silently diverge) and never linked as a directory junction (a forced worktree removal would delete the main checkout's files through a junction).
- **The guard needs Python 3** (`python`, `python3` or `py -3` from python.org; the Microsoft Store stub does not count). Without it the guard denies the worktree creations it cannot check and shows a one-time message.

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
