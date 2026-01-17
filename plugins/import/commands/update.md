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
  - mcp__plugin_context7_context7__resolve-library-id
  - mcp__plugin_context7_context7__query-docs
  - mcp__plugin_playwright_playwright__browser_navigate
  - mcp__plugin_playwright_playwright__browser_snapshot
  - mcp__plugin_playwright_playwright__browser_click
  - mcp__plugin_playwright_playwright__browser_close
---

# Update Cached Documentation

You are executing the `/import:update` command. Re-fetch documentation from original sources.

## Arguments

- `$ARGUMENTS` - (Optional) Path pattern to update. If empty, lists all and asks which to update.

Examples:
- `/import:update` - List all, choose interactively
- `/import:update pimcore` - Update all pimcore docs
- `/import:update pimcore/v2025.4/data-importer.md` - Update specific file

## Process

### 1. Find Docs to Update

If `$ARGUMENTS` provided:
- Find matching docs in `mabi-import/` using pattern
- Read frontmatter for source URL/path

If `$ARGUMENTS` empty:
- List all docs grouped by category
- Ask user which to update (single, pattern, or all)

### 2. Read Source from Frontmatter

Each cached doc has frontmatter:
```yaml
---
source: https://original-url.com/...
imported: 2026-01-15
method: context7
version: v2025.4
---
```

Extract the `source` and `method` fields.

### 3. Re-fetch

Use priority chain (same as url-or-path):
1. **Context7** - If original method was context7, try this first
2. **WebFetch** - If not in Context7, try direct fetch
3. **Playwright** - If blocked, use headless browser

Inform user at each fallback step.

For local paths:
- Check if path still exists
- If yes, re-copy
- If no, warn user and ask what to do

### 4. Handle Version Changes

**CRITICAL**: Version handling depends on whether online version has changed.

#### Case A: Version unchanged (or no version exists)
For `website/` and `local/` categories, or when library version is the same:
- Update content in place
- Update `imported` timestamp
- Keep same file path

#### Case B: Version changed online (library docs only)
When the source has a new version (e.g., pimcore v2025.4 -> v2025.5):
1. **DO NOT modify the old file** - it remains as historical record
2. **Create NEW file in new version folder**:
   - Old: `mabi-import/pimcore/v2025.4/datahub.md` (unchanged)
   - New: `mabi-import/pimcore/v2025.5/datahub.md` (newly created)
3. Inform user about the version change

Why: The old version documentation is still valid for users on that version. We preserve historical versions while adding the new one.

#### Detecting Version Changes
Compare:
1. Current `version` in frontmatter (e.g., `v2025.4`)
2. Detected version from fresh fetch (e.g., `v2025.5`)

If different for library docs -> Case B (create new, keep old)
If same or no version -> Case A (update in place)

### 5. Output

On success (same version):
```
Documentation updated:

  Path:      mabi-import/pimcore/v2025.4/data-importer.md
  Source:    https://docs.pimcore.com/platform/Data_Importer/
  Method:    context7
  Updated:   2026-01-17
  Changes:   Content refreshed (was from 2026-01-15)
```

On success (version changed):
```
New version detected:

  Old:       mabi-import/pimcore/v2025.4/data-importer.md (kept)
  New:       mabi-import/pimcore/v2025.5/data-importer.md (created)
  Source:    https://docs.pimcore.com/platform/Data_Importer/
  Method:    context7

Note: Old version preserved. Both versions now available.
```

On partial success (some failed):
```
Update results:

  Updated (2):
    - pimcore/v2025.4/data-importer.md
    - pimcore/v2025.4/datahub.md

  New versions (1):
    - pimcore/v2025.5/graphql.md (v2025.4 kept)

  Failed (1):
    - local/myproject/config.md: Local path not found

Check failed sources and re-import if needed.
```

## Notes

- Source info is stored in frontmatter of each doc
- Local paths that no longer exist will warn but not delete cached version
- **Version changes create NEW files, old versions are preserved**
- For library docs: each version gets its own folder
- For website/local: no versioning, content updated in place
