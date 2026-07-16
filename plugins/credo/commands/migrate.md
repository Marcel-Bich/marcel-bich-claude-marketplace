---
description: credo - Migrate an existing repo into the .credo/ structure
arguments: none
allowed-tools:
  - Read
  - Bash
  - Write
  - Edit
  - Skill
  - AskUserQuestion
  - Task
---

# Migrate a repo into `.credo/`

Bring an existing repo into the credo target form: scaffold `.credo/`, classify and place
its process artifacts, turn open work into credo items, self-audit, and (only with the
user) tidy the originals.

1. Load the skill `migrate` and follow it end to end. It defines the full procedure and the
   safety model; do not improvise around it.
2. This is a long, multi-phase, subagent-heavy operation. Delegate the work (inventory,
   classification, item cutting, and especially the self-audit) to subagents per the
   credo `orchestration` rules, and keep the `safety` skill in force throughout.
3. The whole procedure is copy-only and additive: originals are never touched until the
   final step. Step 8 (moving originals into `.deleted/`) is ALWAYS user-gated - never move
   or remove any original autonomously; confirm with the user first.
