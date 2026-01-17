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

### 1. Find All Docs

```bash
# List docs directory
ls -la plugins/import/docs/ 2>/dev/null || echo "No docs cached yet"
```

### 2. Extract Metadata

For each file in `plugins/import/docs/`:
- Read the frontmatter (source, imported date)
- Get file size

### 3. Output

Format:
```
Cached Documentation:

  Name                      Source                                    Imported
  ------------------------  ----------------------------------------  ----------
  pimcore-data-importer.md  https://docs.pimcore.com/.../Data_Importer  2026-01-17
  local-config.md           /home/user/config/                        2026-01-15
  ...

Total: {count} documents

Commands:
  /import:search <query>     Search within docs
  /import:update [name]      Update specific or all docs
  /import:url-or-path <src>  Add new documentation
```

If empty:
```
No documentation cached yet.

Use /import:url-or-path <url|path> to import documentation.

Example:
  /import:url-or-path https://docs.pimcore.com/platform/Data_Importer/
  /import:url-or-path /path/to/local/docs/
```
