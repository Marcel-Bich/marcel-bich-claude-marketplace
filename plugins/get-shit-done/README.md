# get-shit-done

Installer for the Get-Shit-Done workflow system - own secured & frozen fork, markdown skills only.

## What This Does

This plugin installs GSD by copying commands and resources to:

- `~/.claude/commands/gsd/` (slash commands)
- `~/.claude/get-shit-done/` (templates, workflows, references)

After setup, you use the GSD commands directly. Only markdown skills are installed - no executable code, hooks, or npm packages.

## Commands

| Command          | Description                |
| ---------------- | -------------------------- |
| `/gsd:setup`     | Install GSD to ~/.claude/  |
| `/gsd:uninstall` | Remove GSD from ~/.claude/ |

## Usage

1. Run `/gsd:setup` once after installing the plugin
2. **Restart Claude Code** to load the new commands
3. Use the GSD commands (e.g., `/gsd:new-project`, `/gsd:map-codebase`, `/gsd:help`)
4. Run `/gsd:uninstall` to remove

## Recommended Third-Party

The following plugins complement GSD workflows:

| Plugin | Description | Source |
|--------|-------------|--------|
| [taches-cc-resources](https://github.com/Marcel-Bich/taches-cc-resources) | Skills for creating plans, prompts, slash commands, agents. Debugging and todo management. Own secured & frozen fork, markdown skills only. | Marcel-Bich (secured fork) |

## Source

Installed from a secured, frozen fork: [Marcel-Bich/get-shit-done](https://github.com/Marcel-Bich/get-shit-done). Pinned snapshot, markdown skills only.

## License

MIT

---

<details>
<summary>Keywords / Tags</summary>

Claude Code, Claude Code Plugin, Claude Code Extension, Claude Code Slash Commands, Claude Code Project Management, Claude Code Workflow, Claude Code Context Engineering, Claude Code Meta-Prompting, Claude Code Spec-Driven Development, Claude Code Planning, Claude Code Roadmap, Claude Code Phases, Claude Code Tasks, Claude Code Milestones, Claude Code State Management, Claude Code Context Rot, Claude Code Subagents, Claude Code Parallel Execution, GSD, Get Shit Done, Project Initialization, Project Planning, Project Execution, Project Tracking, Software Development Workflow, Agile, Iterative Development, Requirements Management, Third Party Plugin, External Plugin, Community Plugin

</details>
