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

### 3.4 Detect Structure Conflicts

Compare the structure of source and project to find **semantic duplicates** with different paths/names:

**Examples of structure conflicts:**
- Project: `CLAUDE.versioning.md` vs Source: `CLAUDE/CLAUDE.version.md`
- Project: `CLAUDE.git.md` vs Source: `.claude/git-rules.md`
- Project: `GUIDES/coding.md` vs Source: `docs/coding-standards.md`

**Detection strategy:**
1. Parse filenames and extract semantic meaning (versioning, git, coding, etc.)
2. Compare content similarity (same rules, different file?)
3. Flag potential duplicates for user decision

**When a structure conflict is detected, ask:**
```
Structure conflict detected:

Project has: CLAUDE.versioning.md
Source has:  CLAUDE/CLAUDE.version.md

These files appear to cover the same topic (version management).

How would you like to handle this?
1. Merge both into project location (CLAUDE.versioning.md)
2. Merge both into source location (CLAUDE/CLAUDE.version.md)
3. Keep both files separate
4. Show me both files first
```

### 3.5 Build Sync Proposal

Create a list of files/directories to potentially sync, categorized by:
- **Direct instructions**: CLAUDE.md, .claude/ config
- **Guidelines/Standards**: GUIDES/, rules, conventions
- **Supporting files**: Referenced documentation
- **Structure conflicts**: Files that need location/merge decisions

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

### 4.2 File EXISTS in Project - Granular Rule-by-Rule Merge

**CRITICAL: Never merge entire files at once. Always go rule-by-rule.**

Read both files and parse them into **sections/rules**:
- Markdown headers (##, ###) define sections
- List items (-) within sections are individual rules
- Code blocks are single units
- References (@filename) are tracked separately

**If identical:** Report "Identical: <filename> - no changes needed" and continue.

**If different:** Perform **granular comparison**:

#### Step 4.2.1: Identify all rules in both files

Parse each file into discrete rules/sections:
```
Project CLAUDE.md:
  [Section: Language]
    - Rule 1: "Always respond in German"
  [Section: Git Rules]
    - Rule 2: "Never commit CLAUDE.md files"
    - Rule 3: "No emojis in code"

Source CLAUDE.md:
  [Section: Language]
    - Rule 1: "Always respond in English"
  [Section: Git Rules]
    - Rule 2: "Never commit CLAUDE.md files"
  [Section: Code Style]
    - Rule 4: "Use 2-space indentation"
```

#### Step 4.2.2: Categorize differences

- **Identical rules**: Same in both (Rule 2)
- **Conflicting rules**: Same topic, different content (Rule 1: German vs English)
- **Project-only rules**: Only in project (Rule 3)
- **Source-only rules**: Only in source (Rule 4)

#### Step 4.2.3: Interactive rule-by-rule review

**For each conflicting rule, ask:**
```
CONFLICT in [Language] section:

Project rule: "Always respond in German"
Source rule:  "Always respond in English"

What would you like to do?
1. Keep project version (German)
2. Use source version (English)
3. Skip this rule entirely
```

**For each source-only rule (new rule), ask:**
```
NEW RULE from source:

Section: [Code Style]
Rule: "Use 2-space indentation"

Add this rule to your project?
1. Yes, add it
2. No, skip it
```

**For project-only rules:** Keep them (they are not in source, user added them intentionally).

#### Step 4.2.4: Show preview before applying

After all decisions, show a **preview** of the merged result:

```
PREVIEW: CLAUDE.md after merge

---
# Claude Guidelines

## Language
- Always respond in German    <-- kept project version

## Git Rules
- Never commit CLAUDE.md files    <-- unchanged
- No emojis in code    <-- kept (project-only)

## Code Style
- Use 2-space indentation    <-- NEW from source
---

Apply these changes?
1. Yes, apply
2. No, discard all changes
3. Go back and change decisions
```

**Important principles:**
- EVERY rule change requires explicit user confirmation
- Show exactly what will change before applying
- User can always go back and revise decisions
- Never silently add, remove, or modify rules

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
6. **Granular is mandatory** - Never merge files wholesale, always rule-by-rule
7. **Preview before apply** - Always show the final result before writing
8. **Structure-aware** - Detect semantic duplicates across different paths
9. **Preserve project rules** - Project-only rules stay unless user removes them
10. **Explain conflicts clearly** - User must understand what each choice means

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

**Structure conflict detected:**
  Project: CLAUDE.versioning.md
  Source:  CLAUDE/version-rules.md
  These appear to cover the same topic. Will ask how to handle.

**Files to review:**

Highest Priority:
- .gitconfig (git user, email settings)

High Priority:
- CLAUDE.md (exists in both - will merge rule-by-rule)
- CLAUDE.git.md (new file)
- CLAUDE/version-rules.md (structure conflict with CLAUDE.versioning.md)

Medium Priority:
- GUIDES/coding.md
- GUIDES/testing.md

Proceed with review?

User: Yes

---
## Git Configuration

Found: .gitconfig

Settings:
- user.name = "Marcel Bich"
- user.email = "marcel@work.com"

Apply to this project?
1. Yes, apply locally
2. No, skip

User: 1

Applied git config locally.

---
## Structure Conflict

Project has: CLAUDE.versioning.md
Source has:  CLAUDE/version-rules.md

Both files contain version management rules.

How to handle?
1. Merge into project location (CLAUDE.versioning.md)
2. Merge into source location (CLAUDE/version-rules.md)
3. Keep both separate
4. Show both files

User: 1

Will merge rules into CLAUDE.versioning.md...

---
## CLAUDE.md - Rule-by-Rule Merge

Parsing rules...

Project has 4 rules, Source has 6 rules.
- 2 identical (no action needed)
- 1 conflict
- 2 new rules from source

### CONFLICT 1/1:

Project: "Always respond in German"
Source:  "Always respond in English"

1. Keep German
2. Use English
3. Remove rule entirely

User: 1

Keeping German.

### NEW RULE 1/2:

Section: [Security]
Rule: "Never commit secrets or API keys"

Add this rule?
1. Yes
2. No

User: 1

### NEW RULE 2/2:

Section: [Testing]
Rule: "Run tests before every commit"

Add this rule?
1. Yes
2. No

User: 1

---
## PREVIEW: CLAUDE.md

# Claude Guidelines

## Language
- Always respond in German    <-- kept

## Git Rules
- Never commit CLAUDE.md    <-- unchanged
- No emojis in code    <-- unchanged

## Security
- Never commit secrets or API keys    <-- NEW

## Testing
- Run tests before every commit    <-- NEW

Apply these changes?
1. Yes, apply
2. No, discard
3. Go back

User: 1

CLAUDE.md updated.

---
## Summary

Source: ./my-standards

+ Applied: .gitconfig (user.name, user.email)
~ Merged: CLAUDE.md (2 new rules added)
~ Merged: CLAUDE.versioning.md (combined with source rules)
+ Added: CLAUDE.git.md
+ Added: GUIDES/coding.md
+ Added: GUIDES/testing.md

Files are untracked. Run 'git status' to review.
```
