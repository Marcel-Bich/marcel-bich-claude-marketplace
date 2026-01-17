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
# Check if this is the marketplace repo
MARKETPLACE_DETECTED="false"

# Method 1: Check git remote
if git remote -v 2>/dev/null | grep -q "marcel-bich-claude-marketplace"; then
    MARKETPLACE_DETECTED="true"
fi

# Method 2: Check for sync.md in plugins/dogma/commands/
if [ -f "plugins/dogma/commands/sync.md" ]; then
    MARKETPLACE_DETECTED="true"
fi
```

### 1.2 Error if Not in Marketplace

If MARKETPLACE_DETECTED is "false":

```
Fehler: /dogma:ignore:sync-all ist nur in der marketplace repo verfuegbar.
sync.md nicht gefunden.

Tipp: Nutze /dogma:ignore [patterns] um einzelne Patterns hinzuzufuegen.
```

**Stop execution here.**

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
Sync von X Patterns aus sync.md

Kategorien:
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
Auf welche Repos anwenden?

Gefundene Repos in ../:
1. ../marcel-bich-claude-ideas
2. ../web-selecta-7850
3. ../another-project

Optionen:
A. Alle oben aufgelisteten Repos
C. Aktuelles Repo (dieses hier)
P. Eigenen Pfad eingeben
S. Auswahl (kommagetrennte Nummern, z.B. "1,3")

Deine Wahl:
```

### 3.3 Handle Selection

- **A (All)**: Apply to all found sibling repos
- **C (Current)**: Apply to current repo only
- **P (Path)**: Ask for custom path, validate it's a git repo
- **S (Selection)**: Parse comma-separated numbers, validate

For custom path:
```
Pfad eingeben (absolut oder relativ):
> ~/projects/my-repo

Validiere...
```

```bash
# Validate custom path
CUSTOM_PATH="${CUSTOM_PATH/#\~/$HOME}"
if [ ! -d "$CUSTOM_PATH/.git" ]; then
    echo "Fehler: $CUSTOM_PATH ist kein Git-Repository"
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
  = 2 hinzugefuegt
```

Or if no changes needed:

```
../marcel-bich-claude-ideas:
  = Alle Patterns bereits vorhanden
```

## Step 5: Summary Report

```
Sync von 12 Patterns aus sync.md

../marcel-bich-claude-ideas:
  + .aider* (.gitignore)
  + .continue* (.gitignore)
  = 2 hinzugefuegt

../web-selecta-7850:
  + .aider* (.gitignore)
  + .codeium* (.gitignore)
  = 2 hinzugefuegt

../already-configured-repo:
  = Alle Patterns bereits vorhanden

Gesamt: 4 Patterns zu 2 Repos hinzugefuegt
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
- No repos found: Report "Keine Repos in ../ gefunden"
- User cancels: Report "Abgebrochen"

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
