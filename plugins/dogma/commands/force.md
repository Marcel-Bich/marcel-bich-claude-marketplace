---
description: dogma - Interactively collect and apply CLAUDE rules to the project
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
1. **Select** which CLAUDE files to process (multiple choice)
2. **Collect** rules from selected files, asking about each
3. **Summarize** what will be done
4. **Execute** only after user confirmation

**No changes are made until the final confirmation!**

## Configuration

```
TARGET_PATH="$ARGUMENTS"  # Optional path (default: entire project)
```

## Phase 1: File Selection (Multiple Choice)

### 1.1 Find All CLAUDE Files

```bash
find . -name "CLAUDE.md" -o -name "CLAUDE.*.md" -o -path "./CLAUDE/*.md" 2>/dev/null | grep -v node_modules | sort
```

### 1.2 Present File Selection with Explanations

Use AskUserQuestion with multiSelect: true to let user choose which rule categories to process.

**IMPORTANT: Use human-friendly names, NOT file names!**

```
Which rules do you want to apply to the project?

[ ] Language Rules
    German/English, umlaut correction (ae->a, oe->o, ue->u)
    Enforceable: Finds and fixes ASCII umlauts

[ ] Git & AI-Traces
    Typography (quotes, dashes), AI-typical phrases, emojis
    Enforceable: Finds and fixes AI-typical patterns

[ ] Code Formatting
    Prettier configuration and application
    Enforceable: Runs Prettier (if installed)

[ ] Code Linting
    ESLint configuration and application
    Enforceable: Runs ESLint with auto-fix (if installed)

[ ] Security Rules
    Secret detection, dependency checks
    Partially enforceable: Scans for secrets (report only)

[ ] Coding Philosophy
    YAGNI, KISS, Rule of Three, etc.
    NOT enforceable: Guidance principles only

[ ] Honesty Rules
    Admit uncertainty, don't fabricate
    NOT enforceable: Guidance principles only

[ ] Planning Rules
    When to plan, complexity assessment
    NOT enforceable: Guidance principles only

[ ] Versioning Rules
    Version bumping, commit prefixes
    Partially enforceable: Checks version sync

[ ] Testing Rules
    When and how to write tests
    Partially enforceable: Can run tests (if configured)

Select (Space to toggle, Enter to confirm):
```

### 1.3 Category to File Mapping

Internal reference - map user-friendly names to actual files:

| Category | File | Enforceable? |
|----------|------|--------------|
| Language Rules | CLAUDE.language.md | Yes - ae/oe/ue -> a/o/u |
| Git & AI-Traces | CLAUDE.git.md | Yes - typography, phrases, emojis |
| Code Formatting | CLAUDE.formatting.md | Yes - Prettier |
| Code Linting | CLAUDE.linting.md | Yes - ESLint --fix |
| Security Rules | CLAUDE.security.md | Partial - report only |
| Coding Philosophy | CLAUDE.philosophy.md | No - guidance only |
| Honesty Rules | CLAUDE.honesty.md | No - guidance only |
| Planning Rules | CLAUDE.planning.md | No - guidance only |
| Versioning Rules | CLAUDE.versioning.md | Partial - checks sync |
| Testing Rules | CLAUDE.testing.md | Partial - can run tests |
| Error Handling | CLAUDE.error-handling.md | No - guidance only |
| Documentation | CLAUDE.documentation.md | No - guidance only |
| Accessibility | CLAUDE.accessibility.md | Partial - can check |

### 1.4 After Selection

```
Selected:
- Language Rules
- Git & AI-Traces
- Code Formatting

Target path: [entire project / specific path]

NO changes will be made until you confirm at the end.

Continue to rule overview?
1. Yes
2. Change selection
3. Cancel
```

## Phase 2: Rule Collection (Interactive)

For each **selected** file, extract and present rules with explanations.

### 2.1 Announce Current Category

```
---
Category 1/3: Language Rules

This category defines:
- Which language to use (German/English)
- How German umlauts are handled
- Language consistency within files
---
```

### 2.2 Present Each Rule with Explanation

**Always explain what the rule does and what happens if enforced:**

```
Rule 1/4: "Maintain existing language"

What it means:
  Never translate or switch languages mid-file.
  If a file starts in German, keep it German throughout.

Enforceable: No
  This is a guidance rule. I'll keep it in mind but can't auto-check.

1. Acknowledge (I understand this rule)
2. Skip
3. Stop processing this file
```

```
Rule 2/4: "Default German for new files"

What it means:
  New files should be in German, except README.md and public docs.

Enforceable: No
  This only applies when creating new files.

1. Acknowledge
2. Skip
3. Stop
```

```
Rule 3/4: "German umlauts - use a, o, u, ss. Never ae, oe, ue"

What it means:
  In German text, always use proper umlauts (a, o, u, ss).
  Never use ASCII replacements like "fuer" or "koennen".

Enforceable: YES
  I can scan all text files for ASCII umlaut patterns and fix them.

  Examples of what will be fixed:
  - "fuer" -> "fur"
  - "koennen" -> "konnen"
  - "Groesse" -> "Grosse"
  - "aehnlich" -> "ahnlich"

Include in execution plan?
1. Yes, scan and collect fixes
2. No, skip this rule
3. Stop
```

If user chooses "Yes":

```
Scanning for ASCII umlauts in [target path]...

Found 5 violations:

1. docs/guide.md:23
   Line: "Dies ist fuer den Benutzer"
   Fix:  "Dies ist fur den Benutzer"

2. README.md:45
   Line: "Sie koennen auch folgendes tun"
   Fix:  "Sie konnen auch folgendes tun"

3. src/messages.ts:12
   Line: const msg = "Dateigroesse"
   Fix:  const msg = "Dateigrosse"

...

5 fixes added to execution plan.
Continuing to next rule...
```

### 2.3 Example: Git & AI-Traces

```
---
Category 2/3: Git & AI-Traces

This category defines:
- Git permissions (add, commit, push)
- Typography rules against AI-typical patterns
- Forbidden phrases that reveal AI usage
- Emoji restrictions in code
---
```

```
Rule 1/5: "Typography - straight quotes, normal dashes, three dots"

What it means:
  AI models often produce "smart" typography that reveals AI usage:
  - Curly quotes " " instead of straight quotes " "
  - Em-dashes -- instead of normal dashes --
  - Ellipsis ... (single char) instead of three dots ...
  - Smart apostrophes ' ' instead of straight ' '

Enforceable: YES
  I can scan all files and replace these characters.

  What will be fixed:
  - " and " -> "
  - -- and -- -> --
  - ... -> ...
  - ' and ' -> '

Include in execution plan?
1. Yes, scan and collect fixes
2. No, skip
3. Stop
```

```
Rule 2/5: "Avoid AI phrases"

What it means:
  Certain phrases are typical AI responses and should be avoided:
  - "Let me..."
  - "I'll..."
  - "Sure!"
  - "Certainly!"
  - "Great question!"

Enforceable: YES (in comments/docs)
  I can scan for these phrases in comments. Removal needs manual review.

Include in execution plan?
1. Yes, scan and report findings
2. No, skip
3. Stop
```

```
Rule 3/5: "No emojis in code"

What it means:
  Emojis should never appear in:
  - Source code comments
  - Log messages
  - Variable names or identifiers

  (Emojis in UI/user-facing output are OK)

Enforceable: YES
  I can scan code files for emojis and flag/remove them.

Include in execution plan?
1. Yes, scan and collect fixes
2. No, skip
3. Stop
```

### 2.4 Example: Non-enforceable Category

```
---
Category 3/3: Coding Philosophy

This category defines coding principles:
- YAGNI, KISS, Rule of Three
- Function size and complexity guidelines
- When to abstract vs. keep simple

These are GUIDANCE PRINCIPLES ONLY - no automatic enforcement possible.
I'll present each rule for acknowledgment.
---
```

```
Rule 1/7: "YAGNI - You Ain't Gonna Need It"

What it means:
  Only implement what's needed NOW.
  Don't add features "just in case" or for hypothetical future needs.
  If you're not sure you need it today, don't build it.

Enforceable: No
  This is a judgment call during development.

1. Acknowledge (I'll keep this in mind)
2. Skip
3. Stop
```

### 2.5 After All Rules Collected

```
Rule collection complete.

From 3 selected categories:
- 4 enforceable rules with 12 planned fixes
- 8 guidance principles acknowledged

Continuing to summary...
```

## Phase 3: Summary (Before Execution)

```
===========================================
DOGMA FORCE - EXECUTION PLAN
===========================================

Target: [entire project / src/]

RULES TO APPLY:
---------------

1. Language Rules - German Umlauts
   What: Replace ASCII umlauts with real umlauts
   5 fixes planned:
   - docs/guide.md:23 - "fuer" -> "fur"
   - README.md:45 - "koennen" -> "konnen"
   - src/messages.ts:12 - "Groesse" -> "Grosse"
   - src/ui.ts:34 - "aehnlich" -> "ahnlich"
   - docs/api.md:78 - "ueberpruefung" -> "Uberprufung"

2. Git & AI-Traces - Typography
   What: Replace smart typography with normal ASCII
   3 fixes planned:
   - src/utils.ts:15 - curly quotes "" -> ""
   - docs/readme.md:8 - em-dash -- -> --
   - src/api.ts:23 - ellipsis ... -> ...

3. Git & AI-Traces - Emojis in Code
   What: Remove emojis from code comments
   1 fix planned:
   - src/logger.ts:45 - remove emoji from comment

4. Code Formatting - Prettier
   What: Auto-format code files
   4 files to format:
   - src/index.ts
   - src/utils.ts
   - src/api.ts
   - tests/test.ts

SKIPPED RULES:
--------------
- Git & AI-Traces - AI Phrases (user skipped)

GUIDANCE PRINCIPLES ACKNOWLEDGED:
---------------------------------
- Coding Philosophy (7 rules: YAGNI, KISS, etc.)

NOT SELECTED (categories):
--------------------------
- Security Rules
- Honesty Rules

===========================================
TOTAL: 13 fixes + 4 files to format
===========================================

Execute plan?
1. Yes, execute all
2. Review individual fixes first
3. Cancel (no changes)
```

### 3.1 Review Mode (if requested)

```
Review mode - each fix individually:

Fix 1/13:
  File: docs/guide.md:23
  Rule: German umlauts
  Current: "Dies ist fuer den Benutzer"
  After:   "Dies ist fur den Benutzer"

  Keep in plan?
  1. Yes
  2. No (remove)
  3. Yes to all remaining
  4. Back to summary
```

## Phase 4: Execution

```
Executing plan...

[1/13] docs/guide.md:23 - Fixed "fuer" -> "fur"
[2/13] README.md:45 - Fixed "koennen" -> "konnen"
...
[10/13] Running Prettier on src/index.ts... Done
...

===========================================
EXECUTION COMPLETE
===========================================

Applied:
+ 9 text fixes (umlauts, typography, emojis)
+ 4 files formatted

Files modified: 11

Stage changes?
1. Yes (git add all)
2. No, review with git diff first
```

## Important Principles

1. **File selection first** - User chooses relevant files upfront
2. **Explain everything** - Every rule gets a "What it means" explanation
3. **Classify clearly** - Always say if enforceable or guidance
4. **Show examples** - Demonstrate what will change
5. **Collect, don't execute** - No changes during collection
6. **Full summary** - Complete overview before any execution
7. **User controls all** - Cancel possible at any point
