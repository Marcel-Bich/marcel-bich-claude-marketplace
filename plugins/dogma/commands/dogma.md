---
description: Intelligently sync Claude instructions from a source to the current project with interactive review
arguments:
  - name: source
    description: "Source: repo URL (https://...) or local path (./path, ../path, ~/path, /absolute/path)"
    required: false
allowed-tools:
  - Bash
  - Read
  - Write
  - Glob
  - AskUserQuestion
---

# Claude-Dogma: Intelligent Sync of Claude Instructions

You are executing the `/claude-dogma` command. Your task is to **intelligently merge** Claude instruction files from a source into the current project with **user interaction** for every decision.

## Configuration

```
DEFAULT_SOURCE="https://github.com/Marcel-Bich/marcel-bich-claude-marketplace"
TARGET_FILES="CLAUDE.md CLAUDE.*.md"
TARGET_DIRS=".claude/"
```

## Step 1: Parse Source Argument

The user provided: `$ARGUMENTS`

**Source detection:**
- Starts with `http` = Remote Git repo
- Starts with `./`, `../`, `/`, `~` = Local path
- Empty = Use DEFAULT_SOURCE

**If DEFAULT_SOURCE is "TODO_CONFIGURE_DEFAULT_SOURCE" and no source provided:**
Stop and tell the user: "Default source not configured. Please provide a source URL or path."

## Step 2: Fetch Source to Temporary Directory

### For Remote Repos
```bash
TEMP_DIR=$(mktemp -d)
git clone --depth 1 --branch main <REPO_URL> "$TEMP_DIR" 2>&1
if [ $? -ne 0 ]; then
    rm -rf "$TEMP_DIR"
    # Report error and stop
fi
SOURCE_DIR="$TEMP_DIR"
```

### For Local Paths
```bash
SOURCE_PATH="${SOURCE_PATH/#\~/$HOME}"
if [ ! -d "$SOURCE_PATH" ]; then
    # Report error: path does not exist
fi
SOURCE_DIR="$SOURCE_PATH"
TEMP_DIR=""  # No cleanup needed
```

## Step 3: Discover Source Files

Find all Claude instruction files in the source:

```bash
cd "$SOURCE_DIR"
# Find CLAUDE.md and CLAUDE.*.md files
ls CLAUDE.md CLAUDE.*.md 2>/dev/null
# Check for .claude/ directory
ls -d .claude/ 2>/dev/null
```

Build a list of all files to potentially sync. For `.claude/` directory, list all files recursively.

## Step 4: Interactive Merge Process

For **each file** found in the source, follow this decision tree:

### 4.1 File Does NOT Exist in Project

Ask the user:
```
File missing in project: <filename>

Source content preview:
---
<first 20 lines of source file>
---

Add this file to the project?
- Yes, add it
- No, skip it
- Show full content first
```

If "Yes": Copy file to project (do NOT git add).
If "No": Skip and continue.
If "Show full": Display full content, then ask again.

### 4.2 File EXISTS in Project - Compare Contents

Read both files and compare:

**If identical:** Report "Identical: <filename> - no changes needed" and continue.

**If different:** Show the differences to the user:

```
File differs: <filename>

=== Current project version ===
<content or summary>

=== Source version ===
<content or summary>

=== Key differences ===
<describe what's different in plain language>

What would you like to do?
- Keep current (no changes)
- Replace with source version
- Merge manually (I'll help you combine them)
- Show detailed diff
```

**Important:** Be intelligent about the comparison:
- Don't just show raw diff - explain what's different
- Highlight additions, removals, and changes
- For large files, summarize sections

### 4.3 Directory: .claude/

For the `.claude/` directory, process **each file individually** using the same logic above.

If `.claude/` doesn't exist in project but exists in source, ask:
```
The source has a .claude/ directory with these files:
- commands/...
- settings.json
- ...

Create .claude/ directory and review each file?
- Yes, let's review each file
- No, skip entire directory
```

## Step 5: Cleanup

```bash
# Only if we cloned a remote repo
if [ -n "$TEMP_DIR" ]; then
    rm -rf "$TEMP_DIR"
fi
```

## Step 6: Summary Report

After all decisions are made, provide a summary:

```
Claude-Dogma Sync Complete

Source: <source-path-or-url>

Changes made:
  + Added: CLAUDE.git.md
  + Added: .claude/commands/mycommand.md
  ~ Updated: CLAUDE.md
  - Skipped: .claude/settings.json (user chose to keep current)
  = Identical: CLAUDE.local.md (no changes needed)

Note: Files are untracked. Run 'git status' to see them.
```

## Important Rules

1. **Never auto-overwrite** - Always ask the user
2. **Never git add** - Files stay untracked
3. **Never modify .gitignore** - User decides tracking
4. **Be helpful** - Explain differences clearly, suggest what makes sense
5. **Respect user decisions** - If they say skip, skip without arguing

## Error Handling

- Source not found: Clear error message with suggestions
- Git clone fails: Report error, check URL/permissions
- File read fails: Report which file and why
- User cancels: Clean up temp dir, report what was done so far

## Example Interaction Flow

```
User: /claude-dogma ./my-standards

Claude: Fetching source from ./my-standards...
Found 2 files to review:
- CLAUDE.md
- CLAUDE.git.md

---
File: CLAUDE.md

This file exists in both locations. Let me compare them...

Your current version has 3 rules.
Source version has 4 rules (adds: "Never commit secrets").

What would you like to do?
1. Keep current (no changes)
2. Replace with source version
3. Merge (add the new rule)

User: 3

Claude: Added the new rule to your CLAUDE.md.

---
File: CLAUDE.git.md

This file doesn't exist in your project yet.

[Shows preview of file content]

Add this file?
1. Yes
2. No

User: 1

Claude: Added CLAUDE.git.md to your project.

---
Sync complete. Files are untracked (not added to git).
```
