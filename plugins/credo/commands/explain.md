---
description: credo - Explain something in depth (what/why/example/consequences)
arguments:
    - name: subject
      description: Optional subject to explain (a reference, statement, or term). If omitted, explain the thing the user just pointed at.
      required: false
allowed-tools:
    - Skill
---

# Credo - Explain in Depth

Explain the subject in depth using the fixed four-part structure: What, Why, Example,
Consequences. Treat the subject as the thing to be explained, not as a literal question.

This command is the explicit entry point for the same behavior that the shorthand `???` triggers
on its own.

**Invoke the `explain` skill via the Skill tool.** Pass along the subject if one was provided;
otherwise explain whatever the user was just pointing at (the most recent reference, statement, or
term in the conversation).

The skill holds the full logic and output contract.
