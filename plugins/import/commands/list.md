---
description: import - List all cached documentation
allowed-tools:
  - Bash
  - Glob
  - Read
---

# List Cached Documentation

You are executing the `/import:list` command. Show all locally cached documentation.

## Process

### 1. Check if mabi-import exists

```bash
ls -la mabi-import/ 2>/dev/null || echo "NO_IMPORTS"
```

If not exists, show empty message.

### 2. List Structure

Show the organized structure:

```bash
# Show tree structure
find mabi-import -type f -name "*.md" 2>/dev/null | sort
```

### 3. Extract Metadata

For each file found:
- Read the frontmatter (source, imported date, method, version)
- Get file size

### 4. Output

Format (grouped by category):
```
Cached Documentation:

=== Libraries ===
  pimcore/v2025.4/
    - data-importer.md    (context7, 2026-01-17)
    - datahub.md          (playwright, 2026-01-17)
    - graphql.md          (context7, 2026-01-17)

  react/v19/
    - hooks.md            (context7, 2026-01-16)

=== Websites ===
  example.com/
    - api-docs.md         (webfetch, 2026-01-15)

=== Local ===
  myproject/
    - config.md           (local, 2026-01-14)

Total: {count} documents in {categories} categories

Commands:
  /import:search <query>     Search within docs
  /import:update [name]      Update specific or all docs
  /import:url-or-path <src>  Add new documentation
```

If empty:
```
No documentation cached yet.

Use /import:url-or-path <url|path> to import documentation.

Examples:
  /import:url-or-path https://docs.pimcore.com/platform/Data_Importer/
  /import:url-or-path /path/to/local/docs/

Structure will be organized automatically:
  - Library docs:  mabi-import/{library}/{version}/
  - Websites:      mabi-import/website/{domain}/
  - Local files:   mabi-import/local/{context}/
```
