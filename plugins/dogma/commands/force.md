---
description: Interactively collect and apply CLAUDE rules to the project
arguments:
  - name: path
    description: "Optional: specific path to apply rules to (default: entire project)"
    required: false
allowed-tools:
  - Bash
  - Read
  - Write
  - Edit
  - Glob
  - Grep
  - AskUserQuestion
---

# Dogma Force: Collect Rules, Summarize, Then Apply

You are executing the `/dogma:force` command. Your task is to:
1. **Collect** all CLAUDE rules and ask user about each
2. **Summarize** what will be done
3. **Execute** only after user confirmation

**No changes are made until the final confirmation!**

## Configuration

```
TARGET_PATH="$ARGUMENTS"  # Optional path (default: entire project)
```

## Phase 1: Discovery

### 1.1 Find CLAUDE Files

```bash
find . -name "CLAUDE.md" -o -name "CLAUDE.*.md" -o -path "./CLAUDE/*.md" 2>/dev/null | grep -v node_modules | sort
```

### 1.2 Present Overview

```
Found X CLAUDE instruction files.
Target: [entire project / specific path]

Phase 1: I'll go through each rule and ask if you want to include it.
Phase 2: I'll show a summary of all planned actions.
Phase 3: After your confirmation, I'll execute everything.

No changes will be made until you confirm in Phase 3.

Start?
1. Yes
2. Cancel
```

## Phase 2: Collect Rules (Interactive)

For each CLAUDE file, go through each rule and ask:

### 2.1 For Each Rule

```
---
File: CLAUDE/CLAUDE.language.md
Rule 1/4: "German umlauts - ALWAYS use a, o, u, ss. NEVER ae, oe, ue, ss."
Type: Enforceable (find & replace)
---

Include this rule in the execution plan?
1. Yes, include
2. No, skip
3. Stop collecting
```

### 2.2 If User Includes an Enforceable Rule

**Scan immediately to show what WOULD be changed (but don't change yet):**

```
Scanning for violations...

Found 5 potential fixes:
1. docs/guide.md:23 - "fuer" -> "fur"
2. README.md:45 - "koennen" -> "konnen"
3. src/messages.ts:12 - "Groesse" -> "Grosse"
4. src/ui.ts:34 - "aehnlich" -> "ahnlich"
5. docs/api.md:78 - "ueberpruefung" -> "Uberprufung"

These will be added to the execution plan.
```

### 2.3 Continue Through All Rules

```
---
File: CLAUDE/CLAUDE.git.md
Rule 1/3: "Typography - Use straight quotes, normal dashes, three dots"
Type: Enforceable
---

Include?
1. Yes
2. No
3. Stop
```

If yes:
```
Scanning...

Found 3 potential fixes:
1. src/utils.ts:15 - Curly quote "" -> ""
2. docs/readme.md:8 - Em-dash -- -> --
3. src/api.ts:23 - Ellipsis ... -> ...

Added to plan.
```

```
---
File: CLAUDE/CLAUDE.philosophy.md
Rule 1/7: "YAGNI - Prefer implementing only what's needed now"
Type: Guidance only (not enforceable)
---

This is a guidance rule. No automatic action possible.
1. Acknowledge (continue)
2. Skip
3. Stop
```

### 2.4 After All Rules Collected

```
Collection complete.

Moving to Phase 2: Summary...
```

## Phase 3: Summary (Before Execution)

Present a complete summary of everything that will be done:

```
===========================================
DOGMA FORCE - EXECUTION PLAN
===========================================

Target: [entire project / src/]

RULES TO APPLY:
---------------

1. CLAUDE.language.md - German umlauts
   5 fixes planned:
   - docs/guide.md:23 - "fuer" -> "fur"
   - README.md:45 - "koennen" -> "konnen"
   - src/messages.ts:12 - "Groesse" -> "Grosse"
   - src/ui.ts:34 - "aehnlich" -> "ahnlich"
   - docs/api.md:78 - "ueberpruefung" -> "Uberprufung"

2. CLAUDE.git.md - Typography
   3 fixes planned:
   - src/utils.ts:15 - Curly quote "" -> ""
   - docs/readme.md:8 - Em-dash -- -> --
   - src/api.ts:23 - Ellipsis ... -> ...

3. CLAUDE.git.md - Emojis in code
   1 fix planned:
   - src/logger.ts:45 - Remove emoji from comment

4. CLAUDE.formatting.md - Prettier
   4 files to format:
   - src/index.ts
   - src/utils.ts
   - src/api.ts
   - tests/test.ts

RULES SKIPPED:
--------------
- CLAUDE.git.md - AI phrases (user skipped)
- CLAUDE.security.md - All rules (user skipped)

GUIDANCE ACKNOWLEDGED:
----------------------
- CLAUDE.philosophy.md - YAGNI, KISS, etc. (7 rules)
- CLAUDE.honesty.md - All rules (5 rules)

===========================================
TOTAL: 13 fixes + 4 files to format
===========================================

Execute this plan?
1. Yes, execute all
2. Review individual items first
3. Cancel (no changes)
```

### 3.1 If User Chooses "Review Individual Items"

```
Review mode. For each planned action:

1/13: docs/guide.md:23
      "fuer" -> "fur"

      Execute this fix?
      1. Yes
      2. No (remove from plan)
      3. Yes to all remaining
      4. Back to summary
```

## Phase 4: Execution

Only after user confirms:

```
Executing plan...

[1/13] docs/guide.md:23 - Fixed "fuer" -> "fur"
[2/13] README.md:45 - Fixed "koennen" -> "konnen"
[3/13] src/messages.ts:12 - Fixed "Groesse" -> "Grosse"
...
[10/13] Running Prettier on src/index.ts... Done
[11/13] Running Prettier on src/utils.ts... Done
...

===========================================
EXECUTION COMPLETE
===========================================

Applied:
+ 9 text fixes
+ 4 files formatted

Files modified:
- docs/guide.md
- README.md
- src/messages.ts
- src/ui.ts
- docs/api.md
- src/utils.ts
- docs/readme.md
- src/api.ts
- src/logger.ts
- src/index.ts
- tests/test.ts

Stage all changes?
1. Yes (git add)
2. No, review with git diff first
```

## Rule Types

| Type | Phase 2 Action | Phase 4 Action |
|------|----------------|----------------|
| Enforceable | Scan, collect findings | Apply fixes |
| Tool-based (Prettier, ESLint) | Check if installed, list files | Run tool |
| Guidance | Acknowledge only | Nothing |
| Report-only (secrets) | Scan, show warnings | Nothing (manual) |

## Important Principles

1. **Collect first, execute later** - Never modify during Phase 2
2. **Full transparency** - Show exact changes before execution
3. **User controls everything** - Every rule needs explicit inclusion
4. **Batch execution** - All approved changes run together
5. **Reviewable plan** - User can review/modify plan before execution
6. **No partial runs** - Cancel aborts everything cleanly

## Error Handling

- Tool not installed: "Prettier not found. Skip formatting rules."
- No violations found: "No issues found for this rule. Nothing to add to plan."
- User cancels: "Cancelled. No changes were made."
- Execution error: "Error modifying [file]. Stopping. X changes were applied before error."
