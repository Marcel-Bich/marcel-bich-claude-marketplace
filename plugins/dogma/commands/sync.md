---
description: dogma - Intelligently sync Claude instructions from a source to the current project with interactive review
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
- `.gitignore` - Git ignore patterns (merge rule-by-rule like other config files)

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

### 4.1.3 Special: settings.json (Global vs Project)

Claude Code settings can be applied globally or per-project. When `.claude/settings.json` is found in source:

**Key principles:**
- **SCOPE CHOICE** - User decides global (~/.claude/settings.json) or project (.claude/settings.json)
- **MERGE, NOT REPLACE** - Combine settings intelligently
- **SHOW DIFF** - User sees exactly what will change

**When .claude/settings.json is found in source:**

```
Found: .claude/settings.json

Source settings:
- env.CLAUDE_MB_DOGMA_DEBUG: "true"
- env.CLAUDE_MB_LIMIT_COLORS: "true"
- permissions.allow-mcp-disk-access: true

Where should these settings be applied?

1. Global (~/.claude/settings.json)
   - Applies to ALL Claude Code projects
   - Recommended for: personal preferences, default tools

2. Project (.claude/settings.json)
   - Applies only to THIS project
   - Recommended for: project-specific env vars, team settings

3. Skip - Don't sync settings
4. Show full settings first
```

**Merge Logic:**

```bash
# Read existing settings
if [ "$SCOPE" = "global" ]; then
    TARGET="$HOME/.claude/settings.json"
else
    TARGET=".claude/settings.json"
    mkdir -p .claude
fi

# If target exists, merge; otherwise create
if [ -f "$TARGET" ]; then
    # Parse both JSON files
    # For each key in source:
    #   - If key exists in target with DIFFERENT value: ask user
    #   - If key exists in target with SAME value: skip
    #   - If key NOT in target: add (after confirmation)
fi
```

**For each conflicting setting, ask:**

```
CONFLICT in settings:

Target (global):  env.CLAUDE_MB_DOGMA_DEBUG = "false"
Source:           env.CLAUDE_MB_DOGMA_DEBUG = "true"

1. Keep current (false)
2. Use source (true)
3. Skip this setting
```

**For new settings, ask:**

```
NEW SETTING from source:

env.CLAUDE_MB_LIMIT_COLORS = "true"

Add to [global/project] settings?
1. Yes
2. No
```

**Preview before applying:**

```
PREVIEW: ~/.claude/settings.json after merge

{
  "env": {
    "CLAUDE_MB_DOGMA_DEBUG": "true",     <-- updated
    "CLAUDE_MB_LIMIT_COLORS": "true",    <-- NEW
    "EXISTING_VAR": "unchanged"          <-- kept
  },
  "permissions": {
    "allow-mcp-disk-access": true        <-- NEW
  }
}

Apply these changes?
1. Yes
2. No
3. Go back
```

**Key points:**
- Global settings affect all projects - warn user
- Project settings are local - safer default for team repos
- Always merge, never replace entire file
- Each setting change requires confirmation
- Existing settings not in source are preserved

### 4.1.4 Special: DOGMA-PERMISSIONS.md (Migration from CLAUDE.git.md)

When syncing, check if the project needs permission migration:

**Detection logic:**

```bash
# Check current state
HAS_DOGMA_PERMS=$([ -f "DOGMA-PERMISSIONS.md" ] && echo "true" || echo "false")
HAS_CLAUDE_GIT=$([ -f "CLAUDE/CLAUDE.git.md" ] || [ -f "CLAUDE.git.md" ] && echo "true" || echo "false")

# Check if CLAUDE.git.md has <permissions> section
if [ "$HAS_CLAUDE_GIT" = "true" ]; then
    CLAUDE_GIT_FILE=$([ -f "CLAUDE/CLAUDE.git.md" ] && echo "CLAUDE/CLAUDE.git.md" || echo "CLAUDE.git.md")
    HAS_PERMS_SECTION=$(grep -q "<permissions>" "$CLAUDE_GIT_FILE" && echo "true" || echo "false")
fi
```

**Scenario 1: No DOGMA-PERMISSIONS.md, but CLAUDE.git.md has permissions**

```
Migration opportunity detected:

Your project has permissions in CLAUDE.git.md but no DOGMA-PERMISSIONS.md.
Dogma now uses DOGMA-PERMISSIONS.md as the dedicated permissions file.

Current permissions in CLAUDE.git.md:
- [x] May run `git add` autonomously
- [x] May run `git commit` autonomously
- [ ] May run `git push` autonomously
- [ ] May delete files autonomously

Would you like to migrate?
1. Yes, create DOGMA-PERMISSIONS.md and remove <permissions> from CLAUDE.git.md
2. No, keep permissions in CLAUDE.git.md (not recommended - will stop working)
3. Show me what will change
```

**If user chooses "Yes":**

1. Create DOGMA-PERMISSIONS.md with the extracted permissions
2. Remove the `<permissions>...</permissions>` section from CLAUDE.git.md
3. Add reference `@DOGMA-PERMISSIONS.md` to CLAUDE.git.md

```bash
# Extract permissions section
PERMS=$(sed -n '/<permissions>/,/<\/permissions>/p' "$CLAUDE_GIT_FILE")

# Create DOGMA-PERMISSIONS.md
cat > DOGMA-PERMISSIONS.md << 'EOF'
# Dogma Permissions

$PERMS
EOF

# Remove permissions from CLAUDE.git.md and add reference
# (use sed or similar to modify in place)
```

**Scenario 2: No DOGMA-PERMISSIONS.md and no permissions in CLAUDE.git.md**

```
No permissions file found.

Would you like to create DOGMA-PERMISSIONS.md?
1. Yes, with restrictive defaults (recommended for new projects)
2. Yes, with permissive defaults (allows git operations)
3. No, skip (all operations allowed by default)
```

**Restrictive defaults (all false):**
```markdown
# Dogma Permissions

<permissions>
- [ ] May run `git add` autonomously
- [ ] May run `git commit` autonomously
- [ ] May run `git push` autonomously
- [ ] May delete files autonomously (rm, unlink, git clean)
- [ ] Ask before deleting (instead of logging to TO-DELETE.md)
</permissions>
```

**Permissive defaults (git ops true, delete false):**
```markdown
# Dogma Permissions

<permissions>
- [x] May run `git add` autonomously
- [x] May run `git commit` autonomously
- [x] May run `git push` autonomously
- [ ] May delete files autonomously (rm, unlink, git clean)
- [ ] Ask before deleting (instead of logging to TO-DELETE.md)
</permissions>
```

**Key points:**
- Always check for migration opportunity at start of sync
- Preserve existing permission values during migration
- Remove permissions from CLAUDE.git.md after migration
- Add @DOGMA-PERMISSIONS.md reference to CLAUDE.git.md

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
# Check installed_plugins.json for plugin
cat ~/.claude/plugins/installed_plugins.json 2>/dev/null | grep -i "<plugin-name>"
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
DOGMA-PERMISSIONS.md
GUIDES/
whats-next.md
whats-next*.md
.planning/

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

### 6.2 Project Compatibility Check

**BEFORE suggesting any tool, check if it's compatible with the project:**

```bash
# Detect project type
HAS_PACKAGE_JSON=$([ -f "package.json" ] && echo "true" || echo "false")
HAS_PYPROJECT=$([ -f "pyproject.toml" ] && echo "true" || echo "false")
HAS_CARGO=$([ -f "Cargo.toml" ] && echo "true" || echo "false")
HAS_GO_MOD=$([ -f "go.mod" ] && echo "true" || echo "false")
HAS_COMPOSER=$([ -f "composer.json" ] && echo "true" || echo "false")

# Check if project has external dependencies (not just dev tools)
if [ "$HAS_PACKAGE_JSON" = "true" ]; then
    HAS_DEPENDENCIES=$(grep -q '"dependencies"' package.json && echo "true" || echo "false")
fi
```

| Tool | Compatible When |
|------|-----------------|
| socket.dev CLI | Node.js project with external dependencies |
| snyk CLI | Any project with external dependencies (npm, pip, cargo, etc.) |
| Prettier | Node.js project (any) |
| ESLint | Node.js project (any) |
| Vitest/Jest | Node.js project (any) |

**Skip tools that don't make sense:**
- No external dependencies -> Don't suggest security scanners
- Non-Node project -> Don't suggest Prettier/ESLint (suggest alternatives)
- Plugin/Marketplace repo -> Security scanners usually not needed

### 6.3 Detection Matrix (Global vs Local)

For each tool, check **BOTH global AND local** installation:

**Security Tools:**
| Tool | Global Detection | Local Detection | Scope |
|------|------------------|-----------------|-------|
| socket.dev CLI | `command -v socket` | package.json devDeps | Global recommended |
| snyk CLI | `command -v snyk` | package.json devDeps | Global recommended |

**JavaScript/TypeScript:**
| Tool | Global Detection | Local Detection | Scope |
|------|------------------|-----------------|-------|
| Prettier | (not recommended) | package.json + config | Local only |
| ESLint | (not recommended) | package.json + config | Local only |

**Python:**
| Tool | Global Detection | Local Detection | Scope |
|------|------------------|-----------------|-------|
| ruff | `command -v ruff` | pyproject.toml/requirements | Global or Local |
| black | `command -v black` | pyproject.toml/requirements | Global or Local |

**PHP:**
| Tool | Global Detection | Local Detection | Scope |
|------|------------------|-----------------|-------|
| php-cs-fixer | `command -v php-cs-fixer` | composer.json | Global or Local |
| PHPStan | `command -v phpstan` | composer.json | Global or Local |

**Rust (built-in with rustup):**
| Tool | Detection | Notes |
|------|-----------|-------|
| rustfmt | `rustfmt --version` | Included with Rust |
| clippy | `cargo clippy --version` | Included with Rust |

**Go (built-in or external):**
| Tool | Detection | Notes |
|------|-----------|-------|
| gofmt | `gofmt -h` | Included with Go |
| golangci-lint | `command -v golangci-lint` | External, global recommended |

### 6.4 Run Detection with Version Info

```bash
# Global CLI tools - check with version
check_global_cli() {
    local cmd=$1
    if command -v "$cmd" &> /dev/null; then
        VERSION=$("$cmd" --version 2>/dev/null | head -1)
        echo "GLOBAL_INSTALLED:$VERSION"
    else
        echo "NOT_FOUND"
    fi
}

# Security tools
SOCKET_STATUS=$(check_global_cli "socket")
SNYK_STATUS=$(check_global_cli "snyk")

# Python tools
RUFF_STATUS=$(check_global_cli "ruff")
BLACK_STATUS=$(check_global_cli "black")

# PHP tools
PHP_CS_FIXER_STATUS=$(check_global_cli "php-cs-fixer")
PHPSTAN_STATUS=$(check_global_cli "phpstan")

# Go tools
GOLANGCI_LINT_STATUS=$(check_global_cli "golangci-lint")

# Rust tools (check via cargo)
check_rust_tool() {
    local tool=$1
    if command -v "$tool" &> /dev/null; then
        VERSION=$("$tool" --version 2>/dev/null | head -1)
        echo "INSTALLED:$VERSION"
    else
        echo "NOT_FOUND"
    fi
}
RUSTFMT_STATUS=$(check_rust_tool "rustfmt")
CLIPPY_STATUS=$(cargo clippy --version 2>/dev/null && echo "INSTALLED" || echo "NOT_FOUND")

# Local tools - check package.json (Node.js)
check_local_dep() {
    local dep=$1
    if [ -f "package.json" ]; then
        if grep -q "\"$dep\"" package.json; then
            echo "LOCAL_INSTALLED"
        else
            echo "NOT_FOUND"
        fi
    else
        echo "NO_PACKAGE_JSON"
    fi
}

PRETTIER_STATUS=$(check_local_dep "prettier")
ESLINT_STATUS=$(check_local_dep "eslint")

# Local tools - check pyproject.toml (Python)
check_pyproject_dep() {
    local dep=$1
    if [ -f "pyproject.toml" ]; then
        if grep -q "$dep" pyproject.toml; then
            echo "LOCAL_INSTALLED"
        else
            echo "NOT_FOUND"
        fi
    else
        echo "NO_PYPROJECT"
    fi
}

# Local tools - check composer.json (PHP)
check_composer_dep() {
    local dep=$1
    if [ -f "composer.json" ]; then
        if grep -q "$dep" composer.json; then
            echo "LOCAL_INSTALLED"
        else
            echo "NOT_FOUND"
        fi
    else
        echo "NO_COMPOSER"
    fi
}
```

### 6.5 Present Items with Intelligent Status

**For Global CLI tools (socket, snyk):**

```
[CLAUDE.security.md] socket.dev CLI

Status: GLOBAL v1.2.3 installed
No action needed.
```

OR if not installed:

```
[CLAUDE.security.md] socket.dev CLI

Status: NOT INSTALLED

Purpose: Dependency security scanning before npm install
- Detects typosquatting attacks
- Identifies known vulnerabilities
- Checks package reputation

Installation options:
1. Install globally (recommended) - Available in all projects
   npm install -g @socketsecurity/cli

2. Install locally - Only this project, versioned in package.json
   npm install -D @socketsecurity/cli

3. Skip - Don't install

Which option?
```

**For Local-only tools (Prettier, ESLint):**

```
[CLAUDE.formatting.md] Prettier

Status: NOT CONFIGURED

Note: Prettier should be installed locally per project (not globally)
to ensure consistent versions across team members.

Install?
1. Yes, run /dogma:lint:setup (recommended - full setup)
2. Yes, quick install (npm install -D prettier)
3. Skip
```

### 6.6 Handle Incompatible Projects

**If project type doesn't match tool:**

```
[CLAUDE.formatting.md] Prettier

Status: NOT APPLICABLE

This is a [Python/Rust/Go] project. Prettier is for JavaScript/TypeScript.

Would you like me to suggest an alternative?
1. Yes, find best formatter for [Python/Rust/Go]
2. No, skip
```

**Alternatives by language:**

| Language | Formatter | Linter |
|----------|-----------|--------|
| JavaScript/TypeScript | Prettier | ESLint |
| Python | black, ruff format | ruff, pylint |
| Rust | rustfmt (built-in) | clippy (built-in) |
| Go | gofmt (built-in) | golangci-lint |
| PHP | php-cs-fixer, pint | PHPStan, Psalm |

If user chooses "Yes, find alternative":
- Use WebSearch to find current best practice
- Suggest installation
- Offer to set up config

### 6.7 Installation Actions

**Global CLI tools:**
```bash
# socket.dev - always global
npm install -g @socketsecurity/cli

# snyk - always global
npm install -g snyk
```

**Local project tools:**
```bash
# Prettier - always local
npm install -D prettier
# Then suggest /dogma:lint:setup for full config

# ESLint - always local
npm install -D eslint
npx eslint --init
```

### 6.8 Skip Irrelevant Tools

**Automatically skip (don't even ask) when:**
- Security scanners for repos without external dependencies
- Node.js tools for non-Node projects
- Tools already installed (just report status)

```
Skipping security scanners: No external dependencies to scan.
```

### 6.9 Setup-Tour Summary

```
Setup-Tour Complete

ALREADY INSTALLED (GLOBAL):
= socket.dev CLI v1.2.3
= snyk CLI v2.1.0

ALREADY INSTALLED (LOCAL):
= Prettier v3.2.5 (in package.json)

INSTALLED:
+ taches-cc-resources plugin

SKIPPED:
- ESLint (user declined)

NOT APPLICABLE:
- Security scanners (no external dependencies)
```

### 6.10 Skip Option

Allow user to skip the entire Setup-Tour:

```
dogma:sync complete. Would you like to run the Setup-Tour?

The Setup-Tour checks your project for missing tools referenced in the synced rules.

1. Yes, run Setup-Tour
2. No, skip and finish
```

**Key principles:**
- Setup-Tour is optional but recommended
- Check global installation FIRST before suggesting install
- Show version when globally installed
- Distinguish global vs local recommendations clearly
- Skip tools that don't make sense for the project
- Offer alternatives for incompatible project types
- Each installation requires user confirmation
- Summary shows what was done

## Step 7: Lint Setup Suggestion

After successful sync, check if linting is already set up:

### 7.1 Check for existing Prettier configuration

```bash
# Check for .prettierrc or similar
ls -la .prettierrc* prettier.config.* 2>/dev/null

# Check package.json for prettier
grep -q '"prettier"' package.json 2>/dev/null && echo "found"
```

### 7.2 Suggest lint setup if missing

**If BOTH checks fail (no Prettier configured):**

```
Linting/Formatting is not configured in this project.

Would you like to set it up?
1. Yes, run /dogma:lint:setup
2. No, skip for now
```

**If Prettier IS configured:** Skip silently (no message).

**Key principle:** Only suggest if truly missing. Don't nag users who already have Prettier.

## Step 8: Summary Report

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
3. **Never auto-modify project's .gitignore** - For AI-file patterns use .git/info/exclude (local-only, not versioned). But DO sync .gitignore from source if user wants it.
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
