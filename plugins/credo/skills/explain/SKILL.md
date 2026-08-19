---
name: explain
description: Explain something in depth on request. Use when the user writes "???" - alone, or placed directly after a reference, statement, or term - which means "explain that in more detail, with a concrete example AND consequences". Also invoked by the /credo:explain command. Treat the pointed-at subject as the thing to explain, never as a literal question, and always answer in the fixed four-part structure: What, Why, Example, Consequences.
---

# Explain in Depth

Give a thorough, structured explanation of a subject the user wants to understand better. The
subject is whatever the user pointed at: a reference, a statement, or a term. This skill exists
because a short "?" or a raw pointer is not a literal question - it is a request to unpack the
thing properly.

## When to use

- The user writes `???` on its own - they did not understand the last thing and want it explained
  properly.
- The user writes `???` directly after a reference, a statement, or a term (for example
  `the audit gate ???`) - explain that specific thing, not the surrounding sentence.
- The `/credo:explain [subject]` command is run - explain the given subject, or, if none is given,
  the thing the user was just pointing at.

## Core principle: it is not a literal question

`???` and `/credo:explain` are a request to EXPLAIN the referenced thing, not a question to answer
verbatim. Do not reply "yes/no" or treat the `?` marks as asking whether something is true.
Identify the subject, then explain it. If the subject is genuinely ambiguous (nothing recent to
point at, no argument given), ask one short clarifying question first, then explain.

## Output structure (fixed - always all four parts)

Answer in exactly these four labeled parts, in this order, every time:

- **What** - what the subject means. State plainly what is being referred to.
- **Why** - why it is that way, or why it matters. The reasoning or purpose behind it.
- **Example** - one concrete, specific example that makes it tangible.
- **Consequences** - what follows from it: effects, trade-offs, and what happens if it is
  ignored or done differently.

Keep each part focused. Prefer a concrete example over an abstract restatement. Do not add,
rename, drop, or reorder the parts - all four are mandatory, even for a small subject (give a
short answer under each rather than omitting one).

## Guardrails

- Match the language of the surrounding conversation for the explanation itself; the four labels
  stay as What / Why / Example / Consequences.
- Explain the subject only - do not turn the explanation into unrelated advice or actions.
- Honesty applies: if part of the subject is genuinely unknown, say so under the relevant part
  rather than inventing detail.
