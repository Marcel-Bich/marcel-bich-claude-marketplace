---
description: import - Update cached documentation
arguments:
  - name: name
    description: Name of doc to update (optional, updates all if omitted)
    required: false
allowed-tools:
  - Bash
  - Read
  - Write
  - Glob
  - WebFetch
  - AskUserQuestion
  - mcp__plugin_playwright_playwright__browser_navigate
  - mcp__plugin_playwright_playwright__browser_snapshot
  - mcp__plugin_playwright_playwright__browser_click
  - mcp__plugin_playwright_playwright__browser_close
---

# Update Cached Documentation

You are executing the `/import:update` command. Re-fetch documentation from original sources.

## Arguments

- `$ARGUMENTS` - (Optional) Name of specific doc to update. If empty, lists all and asks which to update.

## Process

### 1. Find Docs to Update

If `$ARGUMENTS` provided:
- Find matching doc in `plugins/import/docs/`
- Read its frontmatter for source URL/path

If `$ARGUMENTS` empty:
- List all docs with their sources
- Ask user which to update (single, multiple, or all)

### 2. Read Source from Frontmatter

Each cached doc has frontmatter:
```yaml
---
source: https://original-url.com/...
imported: 2026-01-15
---
```

Extract the `source` field.

### 3. Re-fetch

For URLs:
- Try WebFetch first
- Fall back to Playwright if blocked

For local paths:
- Check if path still exists
- If yes, re-copy
- If no, warn user and ask what to do

### 4. Update File

- Preserve filename
- Update content
- Update `imported` timestamp in frontmatter

### 5. Output

On success:
```
Documentation updated:

  Name:     {filename}
  Source:   {source}
  Updated:  {timestamp}
  Changes:  {diff summary if possible}
```

On partial success (some failed):
```
Update results:

  Updated:
    - doc1.md
    - doc2.md

  Failed:
    - doc3.md: Source URL no longer accessible
    - doc4.md: Local path not found

Check failed sources and re-import if needed.
```

## Notes

- Source info is stored in frontmatter of each doc
- Local paths that no longer exist will warn but not delete cached version
- Updates preserve the original filename
