# hydra

Git Worktree Management fuer parallele Agent-Execution - isolierte Arbeitsverzeichnisse ohne Git-Konflikte.

## Features

### Slash Commands

- `/hydra:help` - Zeigt verfuegbare Commands und erklaert das Konzept
- `/hydra:create` - Erstellt neuen Worktree mit eigenem Branch
- `/hydra:list` - Zeigt alle Git Worktrees des Repositories
- `/hydra:status` - Detaillierter Status eines oder aller Worktrees
- `/hydra:delete` - Entfernt Worktree sicher mit Bestaetigung
- `/hydra:spawn` - Startet Agent in einem Worktree
- `/hydra:parallel` - Mehrere Agents parallel in verschiedenen Worktrees
- `/hydra:merge` - Merged Worktree-Branch zurueck (merge oder rebase)
- `/hydra:cleanup` - Entfernt bereits gemergte Worktrees automatisch

### Typischer Workflow

```bash
# 1. Worktrees erstellen
/hydra:create feature-a
/hydra:create feature-b

# 2. Agents parallel starten
/hydra:parallel feature-a:Implementiere Login | feature-b:Implementiere Logout

# 3. Status pruefen
/hydra:status

# 4. Zurueckmergen wenn fertig
/hydra:merge feature-a
/hydra:merge feature-b

# 5. Aufraeumen
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
