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
DEFAULT_SOURCE="https://github.com/Marcel-Bich/marcel-bich-claude-dogma"
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

## Step 3: Intelligent Source Analysis

**Your task is to intelligently analyze the source project** - not just look for fixed filenames.

### 3.1 Scan the Source Project

Explore the source directory structure:
```bash
cd "$SOURCE_DIR"
# Get overview of project structure
ls -la
# Find all markdown files
find . -name "*.md" -type f | head -50
# Check for .claude/ directory
ls -la .claude/ 2>/dev/null
```

### 3.2 Identify Relevant Files

Look for files that contain **Claude/AI instructions, guidelines, or configuration**:

**Highest priority (personal/project config):**
- `.gitconfig`, `gitconfig` - Git user, email, aliases (apply with `git config`)
- `.editorconfig` - Editor settings for consistent formatting

**High priority (always check):**
- `CLAUDE.md`, `CLAUDE.*.md` - Direct Claude instructions
- `.claude/` directory - Claude Code configuration
- Files referenced via `@filename` syntax in any CLAUDE file

**Medium priority (analyze content):**
- `GUIDES/`, `guides/` - Often contain development guidelines
- `RULES.md`, `STANDARDS.md`, `CONVENTIONS.md`
- `CONTRIBUTING.md` - May contain relevant coding standards
- Any markdown file with keywords like "guidelines", "rules", "instructions", "standards"

**Contextual (check if referenced):**
- Files linked or referenced from high-priority files
- README sections about coding standards or AI assistance

### 3.3 Read and Understand References

For each CLAUDE.md or similar file found:
1. Read the content
2. Look for `@filename` references (these indicate linked files)
3. Add referenced files to the sync list
4. Understand the purpose of each file

### 3.4 Build Sync Proposal

Create a list of files/directories to potentially sync, categorized by:
- **Direct instructions**: CLAUDE.md, .claude/ config
- **Guidelines/Standards**: GUIDES/, rules, conventions
- **Supporting files**: Referenced documentation

Present this analysis to the user before proceeding.

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

### 4.1.1 Special: Git Configuration (.gitconfig)

Git config files require special handling - they should be **applied**, not just copied:

```
Found: .gitconfig

Source contains:
- user.name = "Marcel Bich"
- user.email = "marcel@example.com"
- core.autocrlf = input
- ...

Apply these settings to this project?
- Yes, apply to local project (.git/config)
- Yes, apply globally (~/.gitconfig)
- No, skip
- Show full config
```

If applying, use `git config` commands:
```bash
git config --local user.name "Marcel Bich"
git config --local user.email "marcel@example.com"
# etc.
```

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

### 4.3 Directories (e.g., .claude/, GUIDES/)

For directories, process **each file individually** using the same logic above.

If a directory doesn't exist in project but exists in source, ask:
```
The source has a <directory>/ directory with these files:
- file1.md
- file2.md
- ...

<Brief explanation of what this directory contains>

Create <directory>/ and review each file?
- Yes, let's review each file
- No, skip entire directory
```

**Be intelligent about directories:**
- Explain what the directory contains and why it might be useful
- For large directories, group similar files and ask about groups
- Respect the project structure - suggest appropriate locations

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
User: /dogma:sync ./my-standards

Claude: Fetching source from ./my-standards...

Analyzing source project structure...

Found the following relevant files:

**Direct Instructions (High Priority):**
- CLAUDE.md (references @CLAUDE.git.md, @GUIDES/coding.md)
- CLAUDE.git.md
- .claude/settings.json

**Guidelines (Medium Priority):**
- GUIDES/coding.md - Coding standards and best practices
- GUIDES/testing.md - Testing guidelines
- CONTRIBUTING.md - Contains AI assistance section

Shall I proceed with reviewing these files?

User: Yes

---
File: CLAUDE.md

This file exists in both locations. Let me compare them...

Your current version has 3 rules.
Source version has 5 rules and references 2 additional files.

Key differences:
- Source adds: "Never commit secrets"
- Source adds: "Always run tests before commit"
- Source references GUIDES/coding.md (you don't have this)

What would you like to do?
1. Keep current (no changes)
2. Replace with source version
3. Merge intelligently

User: 3

Claude: I'll merge the new rules into your CLAUDE.md and add the @GUIDES reference.

---
Directory: GUIDES/

This directory doesn't exist in your project.
Source contains 2 guideline files:
- coding.md - Code style, naming conventions, error handling
- testing.md - Test structure, coverage requirements

These are referenced from CLAUDE.md. Add this directory?
1. Yes, review each file
2. No, skip

User: 1

[Reviews each file...]

---
Sync complete. Files are untracked (not added to git).
```
