---
description: Intelligently sync Claude instructions from a source to the current project with interactive review
arguments:
  - name: args
    description: "Source and/or instructions in any order. Source: URL or path. Instructions: text in quotes."
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

## Step 1: Parse Arguments

The user provided: `$ARGUMENTS`

**Parse into SOURCE and INSTRUCTIONS (order does not matter, quotes optional):**

**Source detection (recognizable patterns):**
- Starts with `http://` or `https://` = Remote Git repo
- Starts with `~/`, `./`, `../`, `/` = Local path

**Instructions detection:**
- Everything else that is NOT a recognizable source pattern
- Quotes `"..."` are optional but recommended for clarity

**Valid combinations:**
```
/dogma:sync                                         -> DEFAULT_SOURCE, no instructions
/dogma:sync ~/source                                -> ~/source, no instructions
/dogma:sync focus on git rules                      -> DEFAULT_SOURCE, instructions
/dogma:sync "focus on git rules"                    -> DEFAULT_SOURCE, instructions
/dogma:sync ~/source focus on git rules             -> ~/source, instructions
/dogma:sync ~/source "focus on git rules"           -> ~/source, instructions
/dogma:sync "focus on git rules" ~/source           -> ~/source, instructions
/dogma:sync focus on git rules ~/source             -> ~/source, instructions
```

**If user provided instructions, display them and follow throughout:**
```
User instructions: "<instructions>"
Will follow these throughout the sync process.
```

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

**Recommendations (check & install, don't sync as files):**
- `RECOMMENDATIONS.md` - Plugins and MCPs to check and optionally install (see 4.4)
- These are NOT synced as files
- Instead: Check if installed, offer to install missing ones

**Medium priority (analyze content):**
- `GUIDES/`, `guides/` - Often contain development guidelines
- `RULES.md`, `STANDARDS.md`, `CONVENTIONS.md`
- `CONTRIBUTING.md` - May contain relevant coding standards
- Any markdown file with keywords like "guidelines", "rules", "instructions", "standards"

**Special handling (legal implications):**
- `LICENSE`, `LICENSE.md`, `LICENSE.txt` - Requires extra careful handling (see 4.1.2)

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

### 4.1.2 Special: LICENSE Files (Critical - Legal Implications)

LICENSE files require **extra careful handling** because changing a project's license has serious legal implications.

**Key principles:**
- **NO MERGE** - Licenses cannot be merged, only replaced entirely
- **EXPLICIT WARNING** - User must understand legal consequences
- **CONFIRMATION REQUIRED** - Double-confirm before any change

**When LICENSE is found in source:**

```
CRITICAL: LICENSE file found in source

Source license: MIT License
Project license: [None / Apache 2.0 / GPL-3.0 / ...]

WARNING: Changing a project's license has legal implications!

- If you have contributors, you may need their consent
- If your project uses dependencies, check license compatibility
- Existing users may have rights under the current license
- This cannot be "merged" - it's all-or-nothing

What does this mean for your project?
- MIT: Very permissive, allows commercial use, requires attribution
- [Explain the source license briefly]

Options:
1. Skip - Keep current license (recommended if unsure)
2. Replace - Use source license (only if you understand implications)
3. Show both licenses side-by-side
```

**If user chooses "Replace":**

```
Are you absolutely sure?

You are about to change from [current license] to [source license].

Please confirm you understand:
- [ ] I am the sole copyright holder, OR I have consent from all contributors
- [ ] I have checked dependency license compatibility
- [ ] I understand the legal differences between these licenses

Type "I UNDERSTAND" to proceed, or anything else to cancel:
```

**Only proceed if user types exactly "I UNDERSTAND".**

**If project has NO LICENSE:**

```
LICENSE file found in source: MIT License

Your project currently has NO LICENSE file.

Note: Without a license, your code is "all rights reserved" by default.
Adding a license makes it clear how others can use your code.

Would you like to add this license?
1. Yes, add MIT License
2. No, skip (I'll handle licensing separately)
3. Show license content first
```

This is less critical than changing an existing license, but still ask for confirmation.

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

### 4.4 Recommendations (check installation status, offer to install)

If the source contains `RECOMMENDATIONS.md`:

**These are NOT copied as files.** Instead, check what's installed and offer to install missing items.

#### Step 4.4.1: Parse RECOMMENDATIONS.md

Extract each recommendation with:
- **Name** (e.g., "Safety Net", "context7")
- **Type** ("plugin" or "mcp") - determined by section heading (## Plugins vs ## MCP Servers)
- **Description** (the blockquote text starting with >)
- **URL** (from **Repo:** or **Docs:** line)
- **Install commands** (from ```bash code blocks, or text instructions if no code block)
- **Check method** (how to verify if installed)

#### Step 4.4.2: Check installation status

**For Plugins:**
```bash
# List installed plugins
claude plugin list 2>/dev/null | grep -i "<plugin-name>"
```

**For MCP Servers:**
```bash
# Check ~/.claude.json for mcpServers
cat ~/.claude.json 2>/dev/null | grep -o '"<mcp-name>"'
```

#### Step 4.4.3: Present missing recommendations

For each NOT installed item, show:

```
RECOMMENDATION: Safety Net (Plugin)

> Blocks dangerous commands before execution - even in skip permission mode!
> Reduces risk when running automated tasks.

Status: NOT INSTALLED

Would you like to install it?
1. Yes, install now
2. No, skip
3. Show me the repo first
```

#### Step 4.4.4: Install if user agrees

If user chooses "Yes, install now":

1. Extract the install commands from RECOMMENDATIONS.md
2. Show the commands that will be run:
   ```
   Will run:
   claude plugin marketplace add Marcel-Bich/marcel-bich-claude-marketplace
   claude plugin install signal@marcel-bich-claude-marketplace

   Proceed?
   1. Yes
   2. No, I'll do it manually
   ```
3. Execute the commands
4. Report success or failure

**If installation fails or user declines:**
```
You can install manually:

Repo: https://github.com/kenryu42/claude-code-safety-net

Follow the instructions in the repo README.
```

#### Step 4.4.5: Handle MCP installations

MCP servers require special handling:

```
RECOMMENDATION: context7 (MCP Server)

> Enables searching current technical documentation on the web.
> Helps avoid outdated suggestions and hallucinations.

Status: NOT INSTALLED

This MCP server will be added to ~/.claude.json

Would you like to install it?
1. Yes, install now
2. No, skip
3. Show install command first
```

If yes, run the install command from RECOMMENDATIONS.md:
```bash
# The one-liner from RECOMMENDATIONS.md
MCP_NAME="context7" MCP_CMD="npx" MCP_ARGS='["-y","@upstash/context7-mcp"]' node -e "..."
```

After MCP installation:
```
context7 MCP installed successfully.

NOTE: Restart Claude Code for the MCP server to become available.
```

#### Step 4.4.6: Skip already installed

For items that ARE installed:
```
RECOMMENDATION: Signal (Plugin)
Status: ALREADY INSTALLED - skipping
```

#### Step 4.4.7: Summary

At the end, show what was done:
```
Recommendations processed:

INSTALLED:
+ Safety Net (plugin)
+ context7 (mcp)

ALREADY INSTALLED:
= Signal (plugin)
= Limit (plugin)

SKIPPED:
- Playwright (mcp) - user declined
- taches-cc-resources (plugin) - user declined

NOTE: Restart Claude Code if any MCP servers were installed.
```

**Key points:**
- NEVER copy RECOMMENDATIONS.md as a file
- Check installation status before offering
- User confirms each installation
- Run install commands from the source file
- Provide manual install link if automated install fails
- Remind to restart if MCPs were installed

## Step 4.5: Update .git/info/exclude

**CRITICAL: This step ensures AI-related files remain hidden from git.**

After syncing files, update `.git/info/exclude` to protect all AI-files from accidental commits.

### 4.5.1 Check if git repository

```bash
if [ ! -d ".git" ]; then
    echo "Not a git repository - skipping .git/info/exclude update"
    # Skip this step, continue with cleanup
fi
```

### 4.5.2 Read existing exclude file

```bash
EXCLUDE_FILE=".git/info/exclude"
mkdir -p .git/info
touch "$EXCLUDE_FILE"
EXISTING_EXCLUDES=$(cat "$EXCLUDE_FILE")
```

### 4.5.3 Build comprehensive AI-file patterns list

Add ALL known AI-file patterns. This protects files even if they don't exist yet.

```
# ======================================
# AI/Agent Files (managed by dogma:sync)
# ======================================

# --- Synced by Dogma ---
<list all files that were just copied during this sync>

# --- Dogma-specific ---
GUIDES/
whats-next.md

# --- Unified Standard (2025) ---
AGENTS.md
AGENT.md

# --- Claude ---
CLAUDE.md
CLAUDE/
CLAUDE.*.md

# --- Cursor ---
.cursor/
.cursorrules
cursor.rules

# --- Windsurf ---
.windsurfrules
.windsurf/

# --- GitHub Copilot ---
.github/copilot-instructions.md
copilot-*

# --- Google ---
JULES.md
GEMINI.md
gemini.md

# --- Cline / Roo Code / Kilo Code ---
.clinerules
.cline/
.roo/
.kilocode/

# --- Aider ---
.aider/
.aider.conf.json
aider.conf.json
.aiderignore

# --- Continue ---
.continue/
.continuerules

# --- Amazon Q / CodeWhisperer ---
.amazonq/
.aws/codewhisperer/

# --- Other AI Tools ---
.codeium/
.tabnine/
.sourcery/
.codex/
.opencode/
.openhands/
.augment/
.firebender/
.junie/
.kiro/
.trae/
.goose/
```

### 4.5.4 Merge with existing excludes

**Important:** Don't overwrite user's existing excludes, merge intelligently:

1. Read existing `.git/info/exclude`
2. Check if our AI-section header already exists
3. If exists: Replace the AI-section with updated content
4. If not exists: Append the AI-section at the end

**Detection of existing AI-section:**
```bash
grep -q "# AI/Agent Files (managed by dogma:sync)" "$EXCLUDE_FILE"
```

**If section exists:** Remove everything from `# ======` to the next `# ======` or end of file, then add fresh section.

**If section doesn't exist:** Append to file with a blank line separator.

### 4.5.5 Write updated exclude file

```bash
# Show user what we're doing
echo "Updating .git/info/exclude with AI-file patterns..."

# Write the file
# (merge logic happens here)

echo "Added X patterns to .git/info/exclude"
```

### 4.5.6 Report added synced files

List specifically which synced files were added:

```
Updated .git/info/exclude:

Synced files protected:
- CLAUDE.md
- CLAUDE/CLAUDE.git.md
- CLAUDE/CLAUDE.language.md
- GUIDES/philosophy.md
- ... (list all synced files)

Standard AI-patterns added (45 patterns)

These files are now hidden from git but remain on disk.
To force-add a file: git add -f <filename>
```

**Key points:**
- NEVER modify .gitignore (would be visible in commits)
- .git/info/exclude is local-only, not versioned
- Protects synced files AND all common AI-tool files
- Existing exclude entries are preserved
- User can override with `git add -f` if needed
- Already-tracked files are NOT affected (git respects tracked status)

## Step 5: Cleanup

```bash
# Only if we cloned a remote repo
if [ -n "$TEMP_DIR" ]; then
    rm -rf "$TEMP_DIR"
fi
```

## Step 6: Interactive Setup-Tour

**After sync, help the user set up their project according to the synced rules.**

The Setup-Tour checks which tools/configs are referenced in the synced CLAUDE files and offers to install missing ones.

### 6.1 Announce Setup-Tour

```
dogma:sync complete. Starting Setup-Tour...

The Setup-Tour checks your project against the synced rules
and helps install any missing tools or configurations.
```

### 6.2 Detection Matrix

For each synced CLAUDE file, check if the referenced tools exist:

| CLAUDE File | Checks For | Detection Method |
|-------------|------------|------------------|
| CLAUDE.security.md | socket.dev CLI | `which socket` or `socket --version` |
| CLAUDE.security.md | snyk CLI | `which snyk` or `snyk --version` |
| CLAUDE.linting.md | ESLint config | `ls .eslintrc* eslint.config.*` or package.json eslintConfig |
| CLAUDE.formatting.md | Prettier config | `ls .prettierrc* prettier.config.*` or package.json prettier |
| CLAUDE.build.md | Vite | package.json devDependencies.vite |
| CLAUDE.build.md | Vitest | package.json devDependencies.vitest |
| CLAUDE.testing.md | Test framework | package.json scripts.test, jest.config.*, vitest.config.* |
| CLAUDE.planning.md | taches-cc-resources | `claude plugin list \| grep taches` |

### 6.3 Run Detection

For each synced CLAUDE file:

```bash
# Example: Check for CLAUDE.security.md requirements
if [ -f "CLAUDE/CLAUDE.security.md" ] || [ -f "CLAUDE.security.md" ]; then
    # Check socket.dev CLI
    if ! command -v socket &> /dev/null; then
        MISSING_SOCKET=true
    fi
    # Check snyk CLI
    if ! command -v snyk &> /dev/null; then
        MISSING_SNYK=true
    fi
fi
```

### 6.4 Present Missing Items

For each missing item, show:

```
[CLAUDE.security.md]

Missing: socket.dev CLI
Purpose: Dependency security scanning (typosquatting, vulnerabilities)
Install: npm install -g @socketsecurity/cli

Would you like to install it?
1. Yes, install now
2. No, skip
3. Show more info
```

**Important:**
- Only show items that are MISSING
- Explain WHY each tool is recommended
- Show the exact install command
- User confirms each installation

### 6.5 Installation Actions

**For CLI tools (socket, snyk):**
```bash
npm install -g @socketsecurity/cli
# or
npm install -g snyk
```

**For project configs (ESLint, Prettier):**
```bash
# ESLint
npm install -D eslint
npx eslint --init
# or create basic config

# Prettier
npm install -D prettier
echo '{}' > .prettierrc
```

**For Plugins (taches-cc-resources):**
```bash
claude plugin marketplace add Marcel-Bich/marcel-bich-claude-marketplace
claude plugin install taches-cc-resources@marcel-bich-claude-marketplace
```

### 6.6 Handle Non-Node Projects

If package.json doesn't exist:
- Skip npm-based recommendations
- Only offer global CLI tools (socket, snyk)
- Don't offer ESLint/Prettier setup

```
Note: No package.json found - skipping Node.js-specific recommendations.
Global CLI tools are still available.
```

### 6.7 Setup-Tour Summary

```
Setup-Tour Complete

INSTALLED:
+ socket.dev CLI (npm install -g @socketsecurity/cli)
+ taches-cc-resources plugin

ALREADY PRESENT:
= ESLint (found .eslintrc.js)
= Prettier (found in package.json)

SKIPPED:
- snyk CLI (user declined)
- Vitest (user declined)

NOT APPLICABLE:
- Vite (no package.json)
```

### 6.8 Skip Option

Allow user to skip the entire Setup-Tour:

```
dogma:sync complete. Would you like to run the Setup-Tour?

The Setup-Tour checks your project for missing tools referenced in the synced rules.

1. Yes, run Setup-Tour
2. No, skip and finish
```

**Key principles:**
- Setup-Tour is optional but recommended
- Each installation requires user confirmation
- Already-present items are skipped
- Non-applicable items (wrong project type) are noted
- User can decline individual items
- Summary shows what was done

## Step 7: Summary Report

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
3. **Never modify .gitignore** - Use .git/info/exclude instead (local-only, not versioned)
4. **Be helpful** - Explain differences clearly, suggest what makes sense
5. **Respect user decisions** - If they say skip, skip without arguing
6. **Granular is mandatory** - Never merge files wholesale, always rule-by-rule
7. **Preview before apply** - Always show the final result before writing
8. **Structure-aware** - Detect semantic duplicates across different paths
9. **Preserve project rules** - Project-only rules stay unless user removes them
10. **Explain conflicts clearly** - User must understand what each choice means
11. **Follow user instructions** - If additional instructions were provided, follow them throughout
12. **Setup-Tour is optional** - User can skip, but recommend running it
13. **Protect AI files** - Always update .git/info/exclude with comprehensive AI-file patterns

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

## Example with User Instructions

```
User: /dogma:sync ~/my-config nur git config und CLAUDE.md, ignoriere GUIDES

Claude: Fetching source from ~/my-config...

**User instructions:** nur git config und CLAUDE.md, ignoriere GUIDES
Will focus on git config and CLAUDE.md, skipping GUIDES directory.

Analyzing source...

Found:
- .gitconfig (will review)
- CLAUDE.md (will review)
- CLAUDE.git.md (will review)
- GUIDES/coding.md (skipping per user instruction)
- GUIDES/testing.md (skipping per user instruction)

Proceed?

User: Yes

[Reviews only git config and CLAUDE files...]
```
