<h1 align="center">marcel-bich-claude-marketplace</h1>

<p align="center">
  <img src="assets/repo-banner_sm1.jpg" alt="marcel-bich-claude-marketplace banner" width="800">
</p>

<p align="center">
  <a href="https://github.com/Marcel-Bich/marcel-bich-claude-marketplace"><img src="https://img.shields.io/badge/Claude_Code_Marketplace-da6c49?style=for-the-badge" alt="Claude Code Marketplace"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-2ea44f?style=for-the-badge" alt="License"></a>
  <a href="https://github.com/Marcel-Bich/marcel-bich-claude-marketplace/stargazers"><img src="https://img.shields.io/github/stars/Marcel-Bich/marcel-bich-claude-marketplace?style=for-the-badge&logo=github" alt="GitHub Stars"></a>
  <a href="#"><img src="https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Fraw.githubusercontent.com%2FMarcel-Bich%2Fmarcel-bich-claude-marketplace%2Fmain%2F.github%2Fclone-stats.json&query=%24.total_clones&label=Clones/Installs&style=for-the-badge&logo=github" alt="Total Clones"></a>
</p>

<p align="center">
  <a href="https://www.paypal.me/marcelbich"><img src="https://img.shields.io/badge/Support_my_work-PayPal-fec740?style=for-the-badge&logo=paypal" alt="Support my work"></a>
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

Born from real pain points. Built for developers who learned the hard way - since Claude Code exists.

**Each plugin works independently - pick what you need. But together, they form a solid framework for developers who want control, quality, and security over pure YOLO mode.**

credo is the mentor - it governs how a whole session runs, and the other tools slot in around it.

They don't replace Claude. They make Claude manageable.

| Plugin | Role | What they do |
|--------|------|--------------|
| [**credo**](https://github.com/Marcel-Bich/marcel-bich-claude-marketplace/wiki/Claude-Code-Credo-Plugin) | The Mentor | "Here is how we run a session." Modes, work-items with a hard Definition of Done, budgeted autonomy, verify, and safety everywhere. |
| [**dogma**](https://github.com/Marcel-Bich/marcel-bich-claude-marketplace/wiki/Claude-Code-Dogma-Plugin) | The Compliance Officer | Intelligent rule sync from any source, with enforcement hooks. Opinionated defaults included. |
| [**hydra**](https://github.com/Marcel-Bich/marcel-bich-claude-marketplace/wiki/Claude-Code-Hydra-Plugin) | The Project Manager | Parallel workstreams. Isolated branches. No stepping on toes. |
| [**signal**](https://github.com/Marcel-Bich/marcel-bich-claude-marketplace/wiki/Claude-Code-Signal-Plugin) | The Receptionist | "Claude needs you." Ding. Simple. |
| [**limit**](https://github.com/Marcel-Bich/marcel-bich-claude-marketplace/wiki/Claude-Code-Limit-Plugin) | The Accountant | Tracks every token. Shows the burn rate and limits. No surprises. |
| [**import**](https://github.com/Marcel-Bich/marcel-bich-claude-marketplace/wiki/Claude-Code-Import-Plugin) | The Librarian | External docs, locally cached. No annoying "site blocked AI." |
| [**marketplace**](https://github.com/Marcel-Bich/marcel-bich-claude-marketplace/wiki/Claude-Code-Marketplace-Plugin) | The Intern | Development tools for local plugin testing. |

### Third-Party Plugins

| Plugin | Author | Role | What they do |
|--------|--------|------|--------------|
| [**get-shit-done**](https://github.com/Marcel-Bich/marcel-bich-claude-marketplace/wiki/Claude-Code-Get-Shit-Done-Plugin) | Marcel-Bich (secured fork) | The Taskmaster | Specs first. Implementation second. Ship third. An optional alternative to credo's item workflow for spec-driven planning. |

## credo - the mentor

credo is the mentor - a self-contained process framework that governs how a whole session runs. Where the other plugins each solve one problem, credo sets the working discipline for the whole session and the rest slot in around it:

- **Session modes** - `active`, `passive`, and `autonomous`. Each mode changes how much Claude does on its own and whether it keeps itself alive for unattended work. The current mode is re-injected on every prompt, so it is never silently forgotten.
- **Work-item lifecycle with a hard Definition of Done** - items live under `.credo/`, where the folder is the status (clarify -> go -> done -> verified). Nothing reaches "done" until an independent audit subagent signs off and, for UI work, a real browser verify captured screenshot evidence.
- **Budget and limit awareness** - credo reads the 5-hour and weekly usage caps, sizes tasks to fit, and pauses or hands off before a wall is hit.
- **Verify and wiring checks** - "done" means the code is actually wired in and observably works, not just "the test passed".
- **Safety that travels** - filesystem protection and no-autonomous-installs rules are re-injected into every subagent, so delegation cannot dilute them.
- **Autonomy handling** - approved GO items are worked unattended with best-effort self-scheduled wake-ups, budget caps, and ntfy notifications per task and question.
- **Subagent priming** - every subagent starts with the load-bearing security, quality, and honesty rules already in context.
- **WSL environment awareness** - reach Windows-side services and launchers from WSL, self-detecting.
- **Opt-in versioning** - keep `.credo/` local by default, or version items and process in the repo with a single flag.

Start here: install credo, run `/credo:setup`, then pick a session mode. The rest of the marketplace slots in around it.

## credo vs Get-Shit-Done

credo has two layers, and only one of them is a task system:

- **Operating layer (always on)** - session modes, WSL environment awareness, budget and limit awareness, subagent orchestration and priming, safety that travels into every subagent, and the session-mode switch. This layer is orthogonal: it sits on top of whatever task system you use.
- **Task model** (`.credo/items/` plus a hard Definition of Done) - this is an ALTERNATIVE to GSD, not a layer on top of it. Use one task system per project.

**credo is the recommended default and is self-contained for day-to-day work** - items, bug fixes, incremental features, each gated by an observable Definition of Done. credo deliberately has NO large up-front project bootstrap or roadmap; it stays flat and reactive.

**GSD is optional** for heavy up-front planning (PROJECT -> ROADMAP -> milestones -> phases -> plans), or if you already know and prefer the original GSD flow. Pick ONE task system per project, never both at once.

If you run GSD as your task system, set `CREDO_TASK_BACKEND=gsd` so credo's own item features stand down - that avoids two competing sources of truth (`.credo/` items vs GSD's `.planning/`). The default `CREDO_TASK_BACKEND=credo` keeps credo's items active; the operating layer above stays on regardless of the value.

Technically the two do not collide: their hooks are disjoint, and their commands and directories are separate. The one point of friction is the status line - it is a single slot - so in a combined credo + GSD + `limit` setup keep the `limit` status line (let GSD skip installing its own) so credo's budget and auto-compact features keep their data source.

## Requirements

All plugins require:

- `jq` - JSON processor (install: `sudo apt install jq` / `brew install jq`)
- **Supported:** Linux, macOS, WSL2
- **Not supported:** Native Windows / PowerShell (use WSL2 instead)

## Quick Start

```bash
claude plugin marketplace add Marcel-Bich/marcel-bich-claude-marketplace
claude plugin install credo@marcel-bich-claude-marketplace
claude plugin install dogma@marcel-bich-claude-marketplace
claude plugin install hydra@marcel-bich-claude-marketplace
claude plugin install signal@marcel-bich-claude-marketplace
claude plugin install limit@marcel-bich-claude-marketplace
claude plugin install import@marcel-bich-claude-marketplace
claude plugin install get-shit-done@marcel-bich-claude-marketplace
```

## Documentation

Full documentation, installation, configuration, and troubleshooting:

**[View Documentation on Wiki](https://github.com/Marcel-Bich/marcel-bich-claude-marketplace/wiki)**

## License

MIT - See [LICENSE](LICENSE) for full terms.

## Name, Logo, Trademarks (No endorsement)

The source code is licensed under MIT. However, the project name "marcel-bich-claude-marketplace", logos, and branding assets are not covered by the MIT License.

Trademark rights are not granted by the MIT License. Using the project name or branding in ways that suggest endorsement, official affiliation, or sponsorship is not permitted.

Forks and derivative works must use a different name and their own branding. A clear statement that your project is not official and not affiliated is required.

See [TRADEMARK.md](TRADEMARK.md) for the full trademark policy.

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
