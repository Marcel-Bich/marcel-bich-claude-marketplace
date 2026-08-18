---
description: dogma - Show which patterns are missing where
allowed-tools:
  - Bash
  - Read
  - Glob
---

# Dogma Ignore Audit: Show Missing Patterns Overview

You are executing the `/dogma:ignore:audit` command. Your task is to **audit which AI patterns are missing** from `.git/info/exclude`, `.gitignore`, and optionally `sync.md`.

## Step 1: Load Known AI Patterns

### 1.1 Check for sync.md Patterns

First, check if sync.md exists and extract patterns from it:

```bash
SYNC_FILE=""
if [ -f "plugins/dogma/commands/sync.md" ]; then
    SYNC_FILE="plugins/dogma/commands/sync.md"
fi
```

If sync.md exists, extract patterns from the `# --- Other AI Tools ---` section and similar AI tool sections.

### 1.2 Fallback Pattern List

If sync.md is not available or does not contain patterns, use this fallback list:

```
FALLBACK_PATTERNS=(
    ".aider*"
    ".continue*"
    ".codeium*"
    ".cursor*"
    ".copilot*"
    ".tabnine*"
    ".kite*"
    ".sourcery*"
)
```

### 1.3 Determine Patterns to Audit

Collect patterns from sync.md if available, otherwise use fallback list:

```bash
# Core AI tool patterns to check (simplified glob patterns)
AUDIT_PATTERNS=(
    ".aider*"
    ".continue*"
    ".codeium*"
    ".cursor*"
    ".copilot*"
    ".tabnine*"
    ".kite*"
    ".sourcery*"
    ".claude/"
    "CLAUDE.md"
    "CLAUDE.*.md"
    ".windsurf*"
    ".cline*"
    ".roo/"
    ".kilocode/"
)
```

## Step 2: Detect Marketplace Repo

Check if we are in the marketplace repository (same detection as /dogma:sync):

```bash
# Check if this is the marketplace repo
IS_MARKETPLACE_REPO="false"
if [ -f "marketplace.json" ] && [ -d "plugins/dogma" ]; then
    IS_MARKETPLACE_REPO="true"
fi
```

If in marketplace repo, sync.md will be checked as a third location.

## Step 3: Check Pattern Presence

For each pattern, check its presence in:

### 3.1 Check .git/info/exclude

```bash
EXCLUDE_FILE=".git/info/exclude"
if [ -f "$EXCLUDE_FILE" ]; then
    # Check if pattern exists (accounting for case-insensitive bracket notation)
    # Pattern like .aider* might be stored as [Aa][Ii][Dd][Ee][Rr]*
    grep -q "<pattern>" "$EXCLUDE_FILE"
fi
```

### 3.2 Check .gitignore

```bash
if [ -f ".gitignore" ]; then
    grep -q "<pattern>" ".gitignore"
fi
```

### 3.3 Check sync.md (only if marketplace repo)

```bash
if [ "$IS_MARKETPLACE_REPO" = "true" ] && [ -n "$SYNC_FILE" ]; then
    grep -q "<pattern>" "$SYNC_FILE"
fi
```

### 3.4 Pattern Matching Logic

When checking patterns, consider:
- Case-insensitive bracket notation: `[Aa][Ii][Dd][Ee][Rr]` matches `.aider`
- Wildcard patterns: `.aider*` might be stored as `.[Aa][Ii][Dd][Ee][Rr]*`
- Exact matches and partial matches

```bash
check_pattern_in_file() {
    local pattern="$1"
    local file="$2"

    if [ ! -f "$file" ]; then
        echo "FILE_NOT_FOUND"
        return
    fi

    # Extract base name (e.g., "aider" from ".aider*")
    local base=$(echo "$pattern" | sed 's/^\.//' | sed 's/\*$//' | sed 's/\/$//')

    # Check for exact pattern
    if grep -q "$pattern" "$file" 2>/dev/null; then
        echo "FOUND"
        return
    fi

    # Check for case-insensitive bracket notation
    if grep -qi "$base" "$file" 2>/dev/null; then
        echo "FOUND"
        return
    fi

    echo "MISSING"
}
```

## Step 4: Build Audit Report

### 4.1 Collect Results

For each pattern, collect status for each location:

```
RESULTS=()
MISSING_COUNT=0

for pattern in "${AUDIT_PATTERNS[@]}"; do
    exclude_status=$(check_pattern_in_file "$pattern" ".git/info/exclude")
    gitignore_status=$(check_pattern_in_file "$pattern" ".gitignore")

    if [ "$IS_MARKETPLACE_REPO" = "true" ]; then
        sync_status=$(check_pattern_in_file "$pattern" "$SYNC_FILE")
    fi

    # Count missing entries
    if [ "$exclude_status" = "MISSING" ]; then
        ((MISSING_COUNT++))
    fi
    if [ "$gitignore_status" = "MISSING" ]; then
        ((MISSING_COUNT++))
    fi
done
```

### 4.2 Format Output

Present the audit results in this format:

```
Pattern Audit:

.aider*
  [OK] .git/info/exclude
  [!!] .gitignore (MISSING)
  [OK] sync.md

.continue*
  [!!] .git/info/exclude (MISSING)
  [!!] .gitignore (MISSING)
  [OK] sync.md

.codeium*
  [OK] .git/info/exclude
  [OK] .gitignore
  [OK] sync.md

...

Summary: X missing entries

Tip: /dogma:ignore .aider* .continue* to add them
```

### 4.3 Status Indicators

Use these indicators:
- `[OK]` - Pattern is present
- `[!!]` - Pattern is MISSING (with "(MISSING)" suffix)
- `[--]` - File does not exist (with "(file missing)" suffix)

### 4.4 Output Formatting

```
echo "Pattern Audit:"
echo ""

for pattern in "${AUDIT_PATTERNS[@]}"; do
    echo "$pattern"

    # .git/info/exclude status
    case "$exclude_status" in
        "FOUND")
            echo "  [OK] .git/info/exclude"
            ;;
        "MISSING")
            echo "  [!!] .git/info/exclude (MISSING)"
            ;;
        "FILE_NOT_FOUND")
            echo "  [--] .git/info/exclude (file missing)"
            ;;
    esac

    # .gitignore status
    case "$gitignore_status" in
        "FOUND")
            echo "  [OK] .gitignore"
            ;;
        "MISSING")
            echo "  [!!] .gitignore (MISSING)"
            ;;
        "FILE_NOT_FOUND")
            echo "  [--] .gitignore (file missing)"
            ;;
    esac

    # sync.md status (only if marketplace repo)
    if [ "$IS_MARKETPLACE_REPO" = "true" ]; then
        case "$sync_status" in
            "FOUND")
                echo "  [OK] sync.md"
                ;;
            "MISSING")
                echo "  [!!] sync.md (MISSING)"
                ;;
        esac
    fi

    echo ""
done
```

## Step 5: Summary and Recommendations

### 5.1 Show Summary

```
echo "Summary: $MISSING_COUNT missing entries"
```

### 5.2 Generate Tip

If there are missing patterns, collect them and show a tip:

```bash
MISSING_PATTERNS=()
for pattern in "${AUDIT_PATTERNS[@]}"; do
    if [ "$exclude_status" = "MISSING" ] || [ "$gitignore_status" = "MISSING" ]; then
        MISSING_PATTERNS+=("$pattern")
    fi
done

if [ ${#MISSING_PATTERNS[@]} -gt 0 ]; then
    echo ""
    echo "Tip: /dogma:ignore ${MISSING_PATTERNS[*]} to add them"
fi
```

## Step 6: Optional Parallel Repos Scan

### 6.1 Ask About Parallel Repos

After showing the audit for the current repo:

```
Should I also scan parallel repos?
1. Yes, all in this directory
2. No, only this repo
```

### 6.2 Scan Parallel Repos

If user wants to scan parallel repos:

```bash
PARENT_DIR=$(dirname "$(pwd)")
for repo in "$PARENT_DIR"/*; do
    if [ -d "$repo/.git" ] && [ "$repo" != "$(pwd)" ]; then
        echo ""
        echo "=== $repo ==="
        # Run same audit in that directory
    fi
done
```

## Error Handling

### Not a Git Repository

```
if [ ! -d ".git" ]; then
    echo "Error: No Git repository found."
    echo "This command must be run inside a Git repository."
    exit 1
fi
```

### No Issues Found

```
if [ "$MISSING_COUNT" -eq 0 ]; then
    echo ""
    echo "All patterns are correctly configured."
fi
```

## Important Rules

1. **Read-only operation** - This command only checks and reports, never modifies files
2. **Clear status indicators** - Use [OK], [!!], [--] consistently
3. **English output** - Summary and tips in English as per project convention
4. **Helpful tips** - Always show how to fix missing patterns
5. **Optional parallel scan** - Only scan other repos if user requests it
