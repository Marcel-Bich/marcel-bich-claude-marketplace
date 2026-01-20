<h1 align="center">marcel-bich-claude-marketplace</h1>

<p align="center">
  <img src="assets/repo-banner_sm1.jpg" alt="marcel-bich-claude-marketplace banner" width="800">
</p>

<p align="center">
  <a href="https://github.com/Marcel-Bich/marcel-bich-claude-marketplace"><img src="https://img.shields.io/badge/Claude_Code_Marketplace-da6c49?style=for-the-badge" alt="Claude Code Marketplace"></a>
  <a href="LICENSE"><img src="https://img.shields.io/github/license/Marcel-Bich/marcel-bich-claude-marketplace?style=for-the-badge" alt="License"></a>
  <a href="https://github.com/Marcel-Bich/marcel-bich-claude-marketplace/stargazers"><img src="https://img.shields.io/github/stars/Marcel-Bich/marcel-bich-claude-marketplace?style=for-the-badge&logo=github" alt="GitHub Stars"></a>
  <a href="https://www.paypal.me/marcelbich"><img src="https://img.shields.io/badge/Support_my_work-PayPal-blue?style=for-the-badge&logo=paypal" alt="Support my work"></a>
</p>

<p align="center">
  <strong>Your AI got promoted. Now it needs management.</strong>
</p>

<p align="center">
  Claude Code isn't just a tool. It's your personal employee.<br>
  A brilliant, tireless, and - more often than not - occasionally chaotic employee.
</p>

<p align="center">
  <em>Compliance Officer. Accountant. Project Manager. Receptionist. Mentor. Librarian. Taskmaster.<br>
  These plugins handle most of that - so you can focus on building.</em>
</p>

## Why?

You asked Claude to commit your changes. He force-pushed to main. On Friday. At 5pm.

You ran out of API tokens mid-task. No warning. Context gone.

Main agent working hard but starts degrading after 50% context window? Hooks with subagents and Hydra with parallel work save your day.

You needed parallel work. Git conflicts everywhere.

You left Claude alone for 5 minutes. He's been "thinking" ever since - and you only know if you check yourself (Schroedinger's Claude).

Claude is brilliant. Claude is also a golden retriever with a keyboard - enthusiastic, helpful, and completely unsupervised with root access.

**These plugins add the leash.**

(Yes, I know full well you're all bypassing permissions because it's FAST. But you should at least put in SOME form of guardrails and check in occasionally to guarantee quality - not just blindly let it run and hope for the best, only to end up with buggy or even insecure AI slop.)

Without guardrails:
- Context dies mid-task? Start over.
- API limit hit? Surprise!
- Need parallel work? Git conflicts incoming.
- Was that commit good? Who knows, Claude already pushed.

## The Solution

A growing collection of plugins, continuously developed to meet my extremely high expectations for AI-assisted development.

| Plugin | Role | What they do |
|--------|------|--------------|
| [**dogma**](https://github.com/Marcel-Bich/marcel-bich-claude-marketplace/wiki/Claude-Code-Dogma-Plugin) | The Compliance Officer | Provides rules to follow and hooks to enforce the important ones. |
| [**hydra**](https://github.com/Marcel-Bich/marcel-bich-claude-marketplace/wiki/Claude-Code-Hydra-Plugin) | The Project Manager | Parallel workstreams. Isolated branches. No stepping on toes. |
| [**signal**](https://github.com/Marcel-Bich/marcel-bich-claude-marketplace/wiki/Claude-Code-Signal-Plugin) | The Receptionist | "Claude needs you." Ding. Simple. |
| [**limit**](https://github.com/Marcel-Bich/marcel-bich-claude-marketplace/wiki/Claude-Code-Limit-Plugin) | The Accountant | Tracks every token. Shows the burn rate and limits. No surprises. |
| [**credo**](https://github.com/Marcel-Bich/marcel-bich-claude-marketplace/wiki/Claude-Code-Credo-Plugin) | The Mentor | Best practices. Workflows. "Here's how we do things." |
| [**import**](https://github.com/Marcel-Bich/marcel-bich-claude-marketplace/wiki/Claude-Code-Import-Plugin) | The Librarian | External docs, locally cached. No annoying "site blocked AI." |
| [**marketplace**](https://github.com/Marcel-Bich/marcel-bich-claude-marketplace/wiki/Claude-Code-Marketplace-Plugin) | The Intern | Development tools for local plugin testing. |

### Third-Party Plugins

| Plugin | Author | Role | What they do |
|--------|--------|------|--------------|
| [**get-shit-done**](https://github.com/Marcel-Bich/marcel-bich-claude-marketplace/wiki/Claude-Code-Get-Shit-Done-Plugin) | [TACHES](https://github.com/glittercowboy) | The Taskmaster | Specs first. Implementation second. Ship third. |

They don't replace Claude. They make Claude manageable.

---

**Each plugin works independently - pick what you need. But together, they form a solid framework for developers who want control, quality, and security over pure YOLO mode.**

---

Born from real pain points. Built for developers who learned the hard way - since Claude Code exists.

## Requirements

All plugins require:

- `jq` - JSON processor (install: `sudo apt install jq`)
- **Windows:** WSL2 required (native Windows/PowerShell not supported)

## Quick Start

```bash
claude plugin marketplace add Marcel-Bich/marcel-bich-claude-marketplace
claude plugin install credo@marcel-bich-claude-marketplace
claude plugin install dogma@marcel-bich-claude-marketplace
claude plugin install signal@marcel-bich-claude-marketplace
claude plugin install limit@marcel-bich-claude-marketplace
claude plugin install hydra@marcel-bich-claude-marketplace
claude plugin install import@marcel-bich-claude-marketplace
claude plugin install get-shit-done@marcel-bich-claude-marketplace
```

## Documentation

Full documentation, installation, configuration, and troubleshooting:

**[View Documentation on Wiki](https://github.com/Marcel-Bich/marcel-bich-claude-marketplace/wiki)**

## License

MIT - See [LICENSE](LICENSE) for full terms.

---

## Star History

<a href="https://www.star-history.com/#Marcel-Bich/marcel-bich-claude-marketplace&type=date&legend=top-left">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/svg?repos=Marcel-Bich/marcel-bich-claude-marketplace&type=date&theme=dark&legend=top-left" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/svg?repos=Marcel-Bich/marcel-bich-claude-marketplace&type=date&legend=top-left" />
   <img alt="Star History Chart" src="https://api.star-history.com/svg?repos=Marcel-Bich/marcel-bich-claude-marketplace&type=date&legend=top-left" />
 </picture>
</a>

---

<details>
<summary>Keywords / Tags</summary>

Claude Code, Claude Code Plugin, Claude Code Extension, Claude Code Marketplace, Claude Code Plugins Collection, Anthropic CLI, Anthropic Plugin, Anthropic Extension, Anthropic Claude, Anthropic AI, AI Agent Plugins, AI Code Assistant, AI Coding, AI Programming, AI Development, statusline, Statusline, Status Bar, API Usage, Desktop Notifications, Git Worktree, Parallel Agents, Documentation Import, Context7, Playwright, Rules Enforcement, Workflow Guides, Best Practices, Marcel Bich, marcel-bich-claude-marketplace, dogma plugin, signal plugin, limit plugin, hydra plugin, import plugin, credo plugin, get-shit-done plugin

</details>

<sub>*The preacher invites the curious to study the [Genesis](GENESIS.md).*</sub>
