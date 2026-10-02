---
description: credo - Run the optimisation audit for this repo (opt-in, read-only scan, findings offered one by one)
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

# Credo - Optimisation Audit

Run the credo optimisation audit for the current repo: a freshness check, then a
read-only scan (conflict hotspots, changelog fragments, test-stage convention, dogma
settings, parallelism readiness), a report under `.credo/process/reports/`, and every
finding offered as Implement / Later / Never.

**Invoke the `optimize` skill via the Skill tool** and follow it end to end. It holds the
full procedure, the consent rules and the state helpers.

Running this command by hand is the user's consent for this one run; it does not change
the per-repo opt-in for automatic offers. Never run it in autonomous mode.
