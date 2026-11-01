---
description: credo - Explain something in depth (what/why/example/consequences)
arguments:
    - name: subject
      description: Optional subject to explain (a reference, statement, or term). If omitted, explain the thing the user just pointed at.
      required: false
    - name: level
      description: Optional depth - full (default, the ??? length), medium (the ?? length, four short parts) or short (the ? length, two or three bullets).
      required: false
allowed-tools:
    - Skill
---

# Credo - Explain in Depth

Explain the subject in depth at the requested level: full (default) uses the four-part structure
What, Why, Example, Consequences; medium uses the same four parts, each short; short gives two or
three bullets. Treat the subject as the thing to be explained, not as a literal question.

This command is the explicit entry point for the same behavior that the shorthands `???`, `??` and
`?` trigger on their own (full, medium and short).

**Invoke the `explain` skill via the Skill tool.** Pass along the subject if one was provided;
otherwise explain whatever the user was just pointing at (the most recent reference, statement, or
term in the conversation). Pass the level as well (default full).

The skill holds the full logic and output contract.
