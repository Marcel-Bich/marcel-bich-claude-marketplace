---
description: import - Search within cached documentation
arguments:
  - name: query
    description: Search term or pattern
    required: true
allowed-tools:
  - Bash
  - Grep
  - Read
  - Glob
---

# Search Cached Documentation

You are executing the `/import:search` command. Search within all cached documentation.

## Arguments

- `$ARGUMENTS` - Search term or regex pattern

## Process

### 1. Check if Docs Exist

```bash
find mabi-import -type f -name "*.md" 2>/dev/null | head -1 || echo "NO_DOCS"
```

If no docs, inform user to import first.

### 2. Search

Use Grep tool:
- Path: `mabi-import/`
- Pattern: `$ARGUMENTS`
- Output mode: `content` with context (-C 2)

### 3. Output

Format:
```
Search results for "{query}":

=== pimcore/v2025.4/data-importer.md ===
Line 45:   The Data Importer supports CSV, JSON, XML formats...
Line 112:  Configure the importer via the admin panel...

=== website/example.com/api-docs.md ===
Line 23:   Related configuration for imports...

Found {count} matches in {file_count} files.
```

If no matches:
```
No matches found for "{query}" in cached documentation.

Cached structure:
  mabi-import/
    pimcore/v2025.4/   (3 docs)
    website/example.com/   (1 doc)
    local/myproject/   (2 docs)

Tips:
- Try broader search terms
- Use regex patterns for flexible matching
- Check /import:list for available docs
```
