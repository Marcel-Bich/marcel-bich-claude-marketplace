---
name: explain
description: Explain something on request, at three depths. Use when the user writes "???" (full: What, Why, Example, Consequences), "??" (medium: the same four parts, each short) or "?" (short: two or three bullets) - alone (the last discussed point) or at the end of any message ("the audit gate ??", "is xyz so bad?"). The longest ending wins ("???" before "??" before "?"), and a normal question ending with "?" gets the "?" depth and format. Also invoked by the /credo:explain command. Treat a pointed-at term or statement as the thing to explain, never as a literal question.
---

# Explain in Depth

Give a thorough, structured explanation of a subject the user wants to understand better. The
subject is whatever the user pointed at: a reference, a statement, or a term. This skill exists
because a short "?" or a raw pointer is not a literal question - it is a request to unpack the
thing properly.

## When to use

- The user writes `???` on its own - they did not understand the last thing and want it explained
  properly (full level).
- The user writes `??` on its own - the same at medium depth; `?` on its own gives the short level.
- The user writes `???`, `??` or `?` at the end of a message, right after a reference, a statement,
  or a term (for example `the audit gate ??`) - explain that specific thing, not the surrounding
  sentence.
- The user writes a normal question ending with `?` (for example `Is it done?`) - answer that
  question at the depth and format its mark sets (short for `?`).
- The `/credo:explain [subject] [level]` command is run - explain the given subject, or, if none is
  given, the thing the user was just pointing at. The level is full (default), medium or short.

## Recognising the shorthand

- `???`, `??` and `?` count alone or at the end of any message, with or without a space, and also
  when attached to a word (`why??`).
- The longest ending wins: `???` before `??` before `?`.
- A normal question ending with `?` gets the depth and format of its mark (`?` short, `??` medium,
  `???` full).
- A mark in the middle of a message is never the shorthand.

## Core principle: it is not a literal question

`???`, `??`, `?` and `/credo:explain` are a request to EXPLAIN the referenced thing, not a question
to answer verbatim. Do not reply "yes/no" or treat the marks as asking whether something is true.
Identify the subject, then explain it. If the subject is genuinely ambiguous (nothing recent to
point at, no argument given), ask one short clarifying question first, then explain.

The exception is a normal question ending with `?`: answer that question itself, at the depth and
format its mark sets, instead of explaining a term.

## Levels

- **Full (`???`)** - the reference length. The four labeled parts, in this order, each as deep as
  the subject needs:
  - **What** - what the subject means. State plainly what is being referred to.
  - **Why** - why it is that way, or why it matters. The reasoning or purpose behind it.
  - **Example** - one concrete, specific example that makes it tangible.
  - **Consequences** - what follows from it: effects, trade-offs, and what happens if it is
    ignored or done differently.
- **Medium (`??`)** - about 66 percent of the full length. The same four labeled parts in the same
  order, each short: one to three sentences, or two or three bullets.
- **Short (`?`)** - about 33 percent of the full length. Two or three bullets, each one short
  sentence: what it is, why it matters, and optionally the main consequence or an example. No
  four-part labels.

For full and medium, the four parts are mandatory: do not add, rename, drop, or reorder them, even
for a small subject (give a short answer under each rather than omitting one). Prefer a concrete
example over an abstract restatement.

## Formatting (all three levels)

- Each label on its own line in bold (**What**), with its content on the lines below it.
- Bullet points for lists, one point per line, and a blank line between parts.
- Parts and points are never crammed into a single line or one run-on paragraph. The result must
  read as a clean, structured answer at every level.

## Guardrails

- Match the language of the surrounding conversation for the explanation itself; the labels stay
  as What / Why / Example / Consequences.
- Explain the subject only - do not turn the explanation into unrelated advice or actions.
- Honesty applies: if part of the subject is genuinely unknown, say so under the relevant part
  rather than inventing detail.
