# Import Plugin

Import external documentation locally for Claude Code. Uses smart fallback chain to bypass AI-blocking sites.

## Problem

Some documentation sites (like Pimcore) block AI access via WebFetch. This plugin uses a priority chain:

1. **Context7** - Check if library exists in Context7 database (fastest, structured)
2. **WebFetch** - Direct fetch if not in Context7 (fast)
3. **Playwright** - Browser automation if blocked (bypasses bot detection)

User is informed at each fallback step.

## Dynamic Folder Structure

Imports are organized intelligently in `mabi-import/`:

```
mabi-import/
  pimcore/                    # Library documentation
    v2025.4/
      datahub.md
      data-importer.md
  react/
    v19/
      hooks.md
  website/                    # Regular websites
    example.com/
      api-docs.md
  local/                      # Local file imports
    myproject/
      config.md
```

## Commands

| Command | Description |
|---------|-------------|
| `/import:url-or-path <url\|path>` | Import from URL or local path |
| `/import:list` | List all cached documentation |
| `/import:search <query>` | Search within cached docs |
| `/import:update [pattern]` | Re-fetch from original source |

## Usage

### Import from URL

```
/import:url-or-path https://docs.pimcore.com/platform/Data_Importer/
```

The plugin will:
1. Check Context7 for "pimcore" documentation
2. Detect version (e.g., v2025.4)
3. Save to `mabi-import/pimcore/v2025.4/data-importer.md`

### Import local files

```
/import:url-or-path /path/to/local/docs/config.md
```

You will be asked to confirm and provide context for organization.

### Search cached docs

```
/import:search CSV format
```

### Update cached docs

```
/import:update                 # List all, choose interactively
/import:update pimcore         # Update all pimcore docs
/import:update pimcore/v2025.4 # Update specific version
```

When a library has a new version online, the old version is preserved and a new folder is created. This keeps historical documentation available for users on older versions.

## Stored Format

Imported docs include metadata:

```markdown
---
source: https://docs.pimcore.com/platform/Data_Importer/
imported: 2026-01-17
method: context7
version: v2025.4
---

# Document Title

Content...
```

## Requirements

- Context7 MCP plugin (recommended, for structured docs)
- Playwright MCP plugin (for blocked sites, runs visible - NOT headless to bypass bot detection)
- WebFetch tool (built-in)

## License

MIT
