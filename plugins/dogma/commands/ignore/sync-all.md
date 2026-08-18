---
description: dogma - Sync patterns from sync.md to all repos
allowed-tools:
  - Bash
  - Read
  - Write
  - Edit
  - Glob
  - AskUserQuestion
---

# Claude-Dogma: Sync Ignore Patterns to All Repos

You are executing the `/dogma:ignore:sync-all` command. Your task is to **sync all AI/tool patterns from sync.md to selected local repositories**.

## Step 1: Verify Marketplace Repository

This command is ONLY available in the marketplace repository where sync.md exists.

### 1.1 Detection

```bash
# Script directory for token-safe utilities
SCRIPT_DIR="${CLAUDE_PLUGIN_ROOT:-$(dirname "$(dirname "$(realpath "$0")")")}/scripts"

# Check if this is the marketplace repo
MARKETPLACE_DETECTED="false"

# Method 1: Check git remote (token-safe)
if "$SCRIPT_DIR/git-remote-safe.sh" url 2>/dev/null | grep -q "marcel-bich-claude-marketplace"; then
    MARKETPLACE_DETECTED="true"
fi

# Method 2: Check for sync.md in plugins/dogma/commands/
if [ -f "plugins/dogma/commands/sync.md" ]; then
    MARKETPLACE_DETECTED="true"
fi
```

### 1.2 Not in Marketplace - Offer Help

If MARKETPLACE_DETECTED is "false":

**Do NOT just show an error. Instead, explain and offer to help:**

```
/dogma:ignore:sync-all is designed for central pattern management in the
marcel-bich-claude-marketplace repo. All AI-tool patterns are maintained
in sync.md there and distributed to other repos from that location.

For adding individual patterns to this repo, use:
  /dogma:ignore .aider* .continue*

This adds patterns to multiple locations at once:
  - .gitignore (versioned, shared with team)
  - .git/info/exclude (local only, not versioned)

To audit which patterns are missing where:
  /dogma:ignore:audit
```

Then use AskUserQuestion:

```
What were you trying to achieve?

1. Add patterns to .gitignore AND .git/info/exclude -> /dogma:ignore
2. Audit which patterns are missing where -> /dogma:ignore:audit
3. Something else (please describe)
```

Based on user response:
- Option 1: Guide them to use `/dogma:ignore [patterns]`
- Option 2: Run `/dogma:ignore:audit` for them
- Option 3: Read their description and help accordingly (maybe they want to sync from a different source, or have a custom use case)

**Only stop if user explicitly cancels.**

## Step 2: Load Patterns from sync.md

### 2.1 Read sync.md and Extract Patterns

Read the file `plugins/dogma/commands/sync.md` and extract all patterns from the section:
"Build comprehensive AI-file patterns list" (Step 4.5.3)

Look for the code block that contains patterns like:
- `[Dd][Oo][Gg][Mm][Aa]-[Pp][Ee][Rr][Mm][Ii][Ss][Ss][Ii][Oo][Nn][Ss].[Mm][Dd]`
- `.[Aa][Ii][Dd][Ee][Rr]*`
- etc.

### 2.2 Parse Patterns

Extract all patterns (lines that are not comments and not empty) from the patterns section.

Group patterns by category for better overview:
- Dogma-specific
- Claude Code
- Cursor
- Windsurf
- GitHub Copilot
- Google (Jules, Gemini)
- Cline / Roo Code / Kilo Code
- Aider
- Continue
- Amazon Q / CodeWhisperer
- Other AI Tools

### 2.3 Report Pattern Count

```
Sync of X patterns from sync.md

Categories:
- Dogma-specific: X patterns
- Claude Code: X patterns
- Cursor: X patterns
- ...
```

## Step 3: Select Target Repositories

### 3.1 Find Repositories

```bash
# Get current directory name
CURRENT_DIR=$(basename "$PWD")

# Find git repos in parent directory
PARENT_DIR=$(dirname "$PWD")
SIBLING_REPOS=""

for dir in "$PARENT_DIR"/*/; do
    if [ -d "${dir}.git" ] && [ "$(basename "$dir")" != "$CURRENT_DIR" ]; then
        SIBLING_REPOS="$SIBLING_REPOS$(basename "$dir")\n"
    fi
done
```

### 3.2 Ask User for Selection

```
Which repos to apply to?

Found repos in ../:
1. ../marcel-bich-claude-ideas
2. ../web-selecta-7850
3. ../another-project

Options:
A. All repos listed above
C. Current repo (this one)
P. Enter a custom path
S. Selection (comma-separated numbers, e.g., "1,3")

Your choice:
```

### 3.3 Handle Selection

- **A (All)**: Apply to all found sibling repos
- **C (Current)**: Apply to current repo only
- **P (Path)**: Ask for custom path, validate it's a git repo
- **S (Selection)**: Parse comma-separated numbers, validate

For custom path:
```
Enter path (absolute or relative):
> ~/projects/my-repo

Validating...
```

```bash
# Validate custom path
CUSTOM_PATH="${CUSTOM_PATH/#\~/$HOME}"
if [ ! -d "$CUSTOM_PATH/.git" ]; then
    echo "Error: $CUSTOM_PATH is not a Git repository"
    # Ask again or abort
fi
```

## Step 4: Apply Patterns to Each Repository

For each selected repository:

### 4.1 Read Existing .gitignore

```bash
cd "$REPO_PATH"
GITIGNORE_PATH=".gitignore"

if [ -f "$GITIGNORE_PATH" ]; then
    EXISTING_CONTENT=$(cat "$GITIGNORE_PATH")
else
    EXISTING_CONTENT=""
fi
```

### 4.2 Check Which Patterns Are Missing

For each pattern:
1. Check if pattern already exists in .gitignore (exact match)
2. Track missing patterns

```bash
# Check if pattern exists
pattern_exists() {
    grep -qF "$1" "$GITIGNORE_PATH" 2>/dev/null
}
```

### 4.3 Add Missing Patterns

Only add patterns that don't already exist.

**Important:** Add a section header if adding patterns for the first time:

```
# ======================================
# AI/Agent Files (managed by dogma:ignore:sync-all)
# ======================================
```

### 4.4 Report Changes for This Repo

```
../marcel-bich-claude-ideas:
  + .aider* (.gitignore)
  + .continue* (.gitignore)
  = 2 added
```

Or if no changes needed:

```
../marcel-bich-claude-ideas:
  = All patterns already present
```

## Step 5: Summary Report

```
Sync of 12 patterns from sync.md

../marcel-bich-claude-ideas:
  + .aider* (.gitignore)
  + .continue* (.gitignore)
  = 2 added

../web-selecta-7850:
  + .aider* (.gitignore)
  + .codeium* (.gitignore)
  = 2 added

../already-configured-repo:
  = All patterns already present

Total: 4 patterns added to 2 repos
```

## Important Rules

1. **Marketplace only** - Only run in marketplace repo with sync.md
2. **Never overwrite** - Only add missing patterns, never modify existing
3. **Preserve order** - Keep existing .gitignore content unchanged
4. **Section header** - Add AI-section header when adding first patterns
5. **Report clearly** - Show exactly what was added to each repo
6. **Validate paths** - Ensure target is a git repo before modifying

## Error Handling

- Not in marketplace: Show error and tip for /dogma:ignore
- Invalid repo path: Skip and report
- No write permission: Skip and report
- No repos found: Report "No repos found in ../"
- User cancels: Report "Aborted"

## Pattern Reference

The patterns to sync are maintained in `plugins/dogma/commands/sync.md` in the section "Build comprehensive AI-file patterns list".

These include patterns for:
- Dogma-specific files (DOGMA-PERMISSIONS.md, GUIDES/, etc.)
- Claude Code (.claude/, CLAUDE.md, etc.)
- Cursor (.cursor/, .cursorrules)
- Windsurf (.windsurfrules, .windsurf/)
- GitHub Copilot (.github/copilot-instructions.md)
- Google AI (jules.md, gemini.md)
- Cline/Roo/Kilo (.clinerules, .cline/, .roo/, .kilocode/)
- Aider (.aider/, .aiderignore)
- Continue (.continue/, .continuerules)
- Amazon Q / CodeWhisperer (.amazonq/, .aws/codewhisperer/)
- Other AI tools (.codeium/, .tabnine/, .sourcery/, etc.)
