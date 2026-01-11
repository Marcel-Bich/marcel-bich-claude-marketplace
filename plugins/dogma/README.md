# dogma

Intelligent sync of Claude instructions with enforcement hooks for security and consistency.

## Features

### Slash Commands

- `/dogma:sync` - Sync Claude instructions from any source with interactive review
- `/dogma:cleanup` - Find and fix AI-typical patterns in code

### Enforcement Hooks

- Git permissions, secrets detection, dependency verification
- File protection, prompt injection detection
- AI traces validation, language rules reminders
- All hooks toggleable via environment variables

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
