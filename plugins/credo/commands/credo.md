---
description: credo - Interactive guide to available topics and workflows
arguments:
  - name: question
    description: Optional question or topic to explore
    required: false
allowed-tools:
  - AskUserQuestion
  - Skill
---

# Credo - Main Entry Point

If the user runs `/credo` without arguments, help them discover available topics.

## Process

### If no arguments provided:

Use AskUserQuestion to ask:

```
What would you like to explore?

- Project Setup: Step-by-step workflow for new or existing projects (Recommended)
- Parallel Development: Run multiple features simultaneously with hydra
- Code Quality: Automatic linting and formatting
- Debugging: Systematic debugging methodology
- Decision Making: Mental frameworks for tough choices
- Something else: Ask your own question
```

### Based on selection:

- **Project Setup**: Run `/credo:help` via Skill tool
- **Other topics**: Run `/credo:help` and navigate to that topic section
- **Something else**: Answer based on credo's best practices and project context

### If arguments provided:

The user already has a question. Answer it directly using credo's opinionated best practices, or suggest the most relevant `/credo:*` command.

## Note

This is the main entry point. For the full workflow guide, use `/credo:help`.
