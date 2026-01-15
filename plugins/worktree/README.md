# worktree

Git Worktree Management fuer parallele Agent-Execution - isolierte Arbeitsverzeichnisse ohne Git-Konflikte.

## Features

### Slash Commands

- `/worktree:help` - Zeigt verfuegbare Commands und erklaert das Konzept
- `/worktree:create` - Erstellt neuen Worktree mit eigenem Branch
- `/worktree:list` - Zeigt alle Git Worktrees des Repositories
- `/worktree:status` - Detaillierter Status eines oder aller Worktrees
- `/worktree:delete` - Entfernt Worktree sicher mit Bestaetigung
- `/worktree:spawn` - Startet Agent in einem Worktree
- `/worktree:parallel` - Mehrere Agents parallel in verschiedenen Worktrees
- `/worktree:merge` - Merged Worktree-Branch zurueck (merge oder rebase)
- `/worktree:cleanup` - Entfernt bereits gemergte Worktrees automatisch

### Typischer Workflow

```bash
# 1. Worktrees erstellen
/worktree:create feature-a
/worktree:create feature-b

# 2. Agents parallel starten
/worktree:parallel feature-a:Implementiere Login | feature-b:Implementiere Logout

# 3. Status pruefen
/worktree:status

# 4. Zurueckmergen wenn fertig
/worktree:merge feature-a
/worktree:merge feature-b

# 5. Aufraeumen
/worktree:cleanup
```

## Installation

```bash
claude plugin marketplace add Marcel-Bich/marcel-bich-claude-marketplace
claude plugin install worktree@marcel-bich-claude-marketplace
```

## Documentation

Full documentation, usage examples, and troubleshooting:

**[View Documentation on Wiki](https://github.com/Marcel-Bich/marcel-bich-claude-marketplace/wiki/Claude-Code-Worktree-Plugin)**

## License

MIT - See [LICENSE](LICENSE) for full terms.

---

<details>
<summary>Keywords / Tags</summary>

Claude Code, Claude Code Plugin, Claude Code Extension, Claude Code Worktree, Claude Code Git Worktree, Claude Code Parallel, Claude Code Parallel Agents, Claude Code Multi Agent, Claude Code Isolation, Claude Code Concurrent, Claude Code Background, Claude Code Task, Claude Code Spawn, Claude Code Branch, Claude Code Merge, Claude Code Rebase, Anthropic CLI, Anthropic Plugin, Anthropic Extension, Anthropic Claude, Anthropic AI, AI Agent Parallel, AI Agent Concurrent, AI Agent Isolation, AI Agent Multi, AI Code Assistant, AI Coding, AI Programming, AI Development, Git Worktree, Git Worktree Add, Git Worktree List, Git Worktree Remove, Git Branch, Git Merge, Git Rebase, Git Isolation, Git Parallel, Git Concurrent, Parallel Development, Concurrent Development, Feature Branches, Branch Management, Worktree Management, Isolated Environment, Separate Working Directory, Multiple Branches, Simultaneous Work, Background Tasks, Autonomous Agents, Agent Coordination, Agent Spawning, Task Tool, Subagent, Marcel Bich, marcel-bich-claude-marketplace, worktree plugin, parallel plugin, isolation plugin

</details>
