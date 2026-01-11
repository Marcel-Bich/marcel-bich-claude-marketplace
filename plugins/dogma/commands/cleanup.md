---
description: Find and fix AI-typical patterns in code (reactive cleanup)
arguments:
  - name: path
    description: "Path to scan (default: current directory)"
    required: false
allowed-tools:
  - Bash
  - Read
  - Edit
  - Glob
  - Grep
  - AskUserQuestion
---

# Claude-Dogma: Cleanup AI Traces

You are executing the `/dogma:cleanup` command. Your task is to **find and fix AI-typical patterns** in the codebase that reveal AI/agent usage.

## Step 1: Load Rules

### Check for Dogma Rules First

Look for AI trace rules in this order:
1. `GUIDES/ai-traces.md` - Dedicated AI traces documentation
2. `CLAUDE/CLAUDE.git.md` - Check for `<ai_traces>` section
3. `CLAUDE.git.md` - Check for `<ai_traces>` section
4. `.claude/CLAUDE.git.md` - Check for `<ai_traces>` section

If found, extract the rules:
```
Found AI trace rules in GUIDES/ai-traces.md:
- Typography: Use straight quotes " (U+0022), normal dashes - (U+002D), three dots (...)
- Avoid: Curly quotes (U+201C/U+201D), em-dashes (U+2014), smart apostrophes (U+2018/U+2019), ellipsis (U+2026)
- Phrases: Avoid "Let me...", "Sure!", etc.
- Emojis: Never in code comments or logs
```

### Fallback: Default Rules

If no Dogma rules found, use these defaults:

```
DEFAULT_RULES:

Typography:
- Curly quotes: " (U+201C) and " (U+201D) -> straight quotes " (U+0022)
- Em-dash: -- (U+2014) and en-dash -- (U+2013) -> normal dash - (U+002D)
- Ellipsis: ... (U+2026) -> three dots ...
- Smart apostrophes: ' (U+2018), ' (U+2019), ‚ (U+201A) -> straight ' (U+0027)

Emojis in Code:
- Remove emojis from: comments, variable names, log messages
- Keep emojis in: UI strings, user-facing output

Phrases (in comments/docs):
- "Let me..." -> remove or rephrase
- "I'll..." -> remove or rephrase
- "Sure!" -> remove
- "Certainly!" -> remove
- "Great question!" -> remove

German Umlauts (optional, ask user):
- In strings: ae->ä, oe->ö, ue->ü, ss->ß (where appropriate)
- In code identifiers: keep ASCII (ae, oe, ue, ss)
```

## Step 2: Determine Scan Path

The user provided: `$ARGUMENTS`

- If empty: scan current directory
- If path provided: scan that path

```bash
SCAN_PATH="${1:-.}"
```

## Step 3: Find Files to Scan

Exclude common non-code directories:

```bash
# Find source files, excluding:
# - node_modules, .git, dist, build, vendor, __pycache__
# - Binary files, images, etc.

EXCLUDE_DIRS="node_modules|\.git|dist|build|vendor|__pycache__|\.next|coverage"
INCLUDE_EXTENSIONS="js|ts|jsx|tsx|py|rb|go|java|php|md|txt|json|yaml|yml|sh|bash"
```

## Step 4: Scan for Patterns

For each file, check for:

### 4.1 Typography Issues

```bash
# Curly quotes: " (U+201C) and " (U+201D)
grep -P '[\x{201C}\x{201D}]' <file>

# Em-dash (U+2014) and en-dash (U+2013)
grep -P '[\x{2014}\x{2013}]' <file>

# Ellipsis character (U+2026)
grep -P '[\x{2026}]' <file>

# Smart apostrophes: ' (U+2018), ' (U+2019), ‚ (U+201A)
grep -P '[\x{2018}\x{2019}\x{201A}]' <file>
```

### 4.2 Emojis in Code

```bash
# Find emojis in comments (// or # or /* */)
# This is complex - look for common emoji ranges in non-UI contexts
```

### 4.3 AI Phrases

```bash
# In comments or documentation
grep -iP '(let me|i\'ll|sure!|certainly!|great question)' <file>
```

## Step 5: Present Findings

Show summary first:

```
Scan complete: ./src

Files scanned: 47
Files with issues: 12

Issues found:
- Typography (curly quotes, em-dashes): 23 occurrences in 8 files
- Emojis in code: 5 occurrences in 3 files
- AI phrases: 7 occurrences in 4 files

Would you like to:
1. Review and fix all issues interactively
2. Auto-fix typography only (safe)
3. Show detailed report first
4. Cancel
```

## Step 6: Interactive Fix

For each issue, show context and ask:

```
FILE: src/utils/helper.ts (line 42)

ISSUE: Curly quote found

Context:
  41 | // This function handles the "special" case
  42 | // where we need to process "quoted" strings
  43 | const process = (input) => {

Found: "special" and "quoted" (curly quotes)
Replace with: "special" and "quoted" (straight quotes)

Fix this?
1. Yes, fix
2. No, skip
3. Fix all typography in this file
4. Fix all typography everywhere
```

## Step 7: Apply Fixes

When user approves:
1. Read the file
2. Apply the replacement
3. Write the file back
4. Report success

```
Fixed: src/utils/helper.ts
- Line 42: Replaced curly quotes with straight quotes
```

## Step 8: Summary Report

```
Cleanup Complete

Fixed:
+ src/utils/helper.ts: 3 typography fixes
+ src/components/Button.tsx: 1 emoji removed
+ README.md: 2 phrase fixes

Skipped (user declined):
- src/config/messages.ts: emoji in UI string (intentional)

No issues found:
= 35 files clean

Total: 6 fixes applied, 1 skipped, 35 clean
```

## Important Rules

1. **Never auto-fix without asking** - Always get user confirmation
2. **Show context** - User needs to see surrounding code
3. **Respect intentional usage** - Emojis in UI strings are OK
4. **Use Dogma rules if available** - Project-specific rules take precedence
5. **Safe defaults** - Typography fixes are usually safe, phrases need review
6. **Don't break code** - Be careful with strings that might be tests or constants

## Error Handling

- File not readable: Skip and report
- Binary file: Skip automatically
- No issues found: Report "All clean!"
- User cancels: Report what was done so far

## Example Session

```
/dogma:cleanup ./src

Loading rules from CLAUDE/CLAUDE.git.md...
Found <ai_traces> section with custom rules.

Scanning ./src...

Scan complete: 47 files, 12 with issues

ISSUE 1/35: src/utils/helper.ts:42
Typography: Curly quote -> straight quote
Context: // where we need to process "quoted" strings
Fix? [Y/n/all] > y

ISSUE 2/35: src/utils/helper.ts:58
Typography: Em-dash -> normal dash
Context: // This handles edge cases --- including nulls
Fix? [Y/n/all] > all

Auto-fixing remaining typography issues...
Fixed 21 typography issues.

ISSUE 23/35: src/components/Alert.tsx:15
Emoji in code: console.log("Error occurred")
Context: console.log("Error occurred");
Fix? [Y/n] > y

...

Cleanup Complete
+ 28 fixes applied
- 3 skipped (user declined)
= 4 files already clean
```
