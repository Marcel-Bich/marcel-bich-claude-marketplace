# dogma

Intelligent sync of Claude instructions with enforcement hooks for security and consistency.

## Features

### Slash Commands

- `/dogma:sync` - Sync Claude instructions from any source with interactive review
- `/dogma:cleanup` - Find and fix AI-typical patterns in code
- `/dogma:lint` - Project-agnostic linting and formatting on staged files (non-interactive)
- `/dogma:lint:setup` - Interactive setup for linting/formatting tools
- `/dogma:versioning` - Check and sync version numbers across all config files
- `/dogma:permissions` - Create or update DOGMA-PERMISSIONS.md interactively
- `/dogma:force` - Interactively collect and apply CLAUDE rules to the project
- `/dogma:sanitize-git` - Sanitize git history from Claude/AI traces and fix tracking issues
- `/dogma:docs-update` - Sync documentation across README files and wiki articles

### Permissions System

Control Claude's autonomy with `DOGMA-PERMISSIONS.md` in your project root:

```markdown
<permissions>
- [x] May run `git add` autonomously      # auto
- [x] May run `git commit` autonomously   # auto
- [?] May run `git push` autonomously     # ask first
- [?] May delete files autonomously       # ask first
</permissions>
```

| Marker | Mode | Behavior |
|--------|------|----------|
| `[x]` | auto | Claude does it automatically |
| `[?]` | ask | Claude asks for confirmation |
| `[ ]` | deny | Blocked (manual only) |

Run `/dogma:permissions` to configure interactively.

### Enforcement Hooks

- Git permissions, secrets detection
- File protection, prompt injection detection
- AI traces validation, language rules reminders
- Dependency verification (asks before package installs)
- All hooks toggleable via environment variables

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `CLAUDE_MB_DOGMA_ENABLED` | `true` | Master switch for all hooks |
| `CLAUDE_MB_DOGMA_PRE_COMMIT_LINT` | `true` | Block git commit until /dogma:lint is run |
| `CLAUDE_MB_DOGMA_SKIP_LINT_CHECK` | `false` | Skip pre-commit lint check (set by Claude after lint) |
| `CLAUDE_MB_DOGMA_AUTO_FORMAT` | `true` | Allow automatic formatting of staged files |
| `CLAUDE_MB_DOGMA_LINT_ON_STOP` | `true` | Run lint check when task completes (fallback) |

### Usage Warning

The enforcement hooks increase token consumption significantly. Recommended for Claude Max 20x (or minimum Max 5x). For sync-only usage without hooks, any plan works.

## Installation

```bash
claude plugin marketplace add Marcel-Bich/marcel-bich-claude-marketplace
claude plugin install dogma@marcel-bich-claude-marketplace
```

## Documentation

Full documentation, hook details, configuration, and customization options:

**[View Documentation on Wiki](https://github.com/Marcel-Bich/marcel-bich-claude-marketplace/wiki/Claude-Code-Dogma-Plugin)**

## License

MIT - See [LICENSE](LICENSE) for full terms.

---

<details>
<summary>Keywords / Tags</summary>

Claude Code, Claude Code Plugin, Claude Code Extension, Claude Code Hooks, Claude Code Rules, Claude Code Enforcement, Claude Code Security, Claude Code Git, Claude Code Secrets, Claude Code Dependencies, Claude Code AI Traces, Claude Code Prompt Injection, Claude Code Instructions, Claude Code CLAUDE.md, Claude Code Configuration, Claude Code Settings, Claude Code Customization, Claude Code Workflow, Claude Code Automation, Claude Code Best Practices, Claude Code Guidelines, Claude Code Standards, Claude Code Conventions, Claude Code Linting, Claude Code Validation, Claude Code Protection, Claude Code Safety, Claude Code Guard, Claude Code Filter, Claude Code Block, Claude Code Warn, Claude Code Remind, Claude Code Sync, Claude Code Merge, Claude Code Import, Claude Code Export, Anthropic CLI, Anthropic Plugin, Anthropic Extension, Anthropic Claude, Anthropic AI, AI Agent Rules, AI Agent Guidelines, AI Agent Instructions, AI Agent Configuration, AI Agent Customization, AI Code Assistant, AI Coding, AI Programming, AI Development, LLM Rules, LLM Guidelines, LLM Instructions, LLM Configuration, Git Hooks, Git Protection, Git Security, Git Secrets, Git Credentials, Git Add Protection, Git Commit Protection, Git Push Protection, Secret Detection, Credential Detection, API Key Protection, Environment Variables, Prompt Injection Detection, Prompt Injection Protection, Prompt Injection Guard, AI Traces Detection, AI Traces Removal, Git History Sanitization, Git History Cleanup, Force Push, Filter Branch, Curly Quotes, Em Dashes, Smart Quotes, Typography Cleanup, German Umlauts, Language Rules, Code Quality, Code Standards, Code Conventions, Code Review, Pre-commit Hooks, Post-commit Hooks, UserPromptSubmit, PreToolUse, PostToolUse, Stop Hook, Marcel Bich, marcel-bich-claude-marketplace, dogma plugin, rules enforcement plugin

</details>
