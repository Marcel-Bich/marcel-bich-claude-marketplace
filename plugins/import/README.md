# Import Plugin

Import external documentation locally for Claude Code. Bypasses AI-blocking sites using Playwright when needed.

## Problem

Some documentation sites (like Pimcore) block AI access via WebFetch. This plugin:

1. Tries WebFetch first (fast)
2. Falls back to Playwright if blocked (acts like normal browser)
3. Caches documentation locally in `docs/`

## Commands

| Command | Description |
|---------|-------------|
| `/import:url-or-path <url\|path>` | Import from URL or local path |
| `/import:list` | List all cached documentation |
| `/import:search <query>` | Search within cached docs |
| `/import:update [name]` | Re-fetch from original source |

## Usage

### Import from URL

```
/import:url-or-path https://docs.pimcore.com/platform/Data_Importer/
```

If the site blocks AI access, Playwright will be used automatically.

### Import local files

```
/import:url-or-path /path/to/local/docs/
```

You will be asked to confirm before copying.

### Search cached docs

```
/import:search CSV format
```

### Update cached docs

```
/import:update                    # List all, choose which to update
/import:update pimcore-data-importer  # Update specific doc
```

## Stored Format

Imported docs are saved in `plugins/import/docs/` with metadata:

```markdown
---
source: https://original-url.com/...
imported: 2026-01-17
---

# Document Title

Content...
```

## Requirements

- Playwright MCP plugin (for blocked sites)
- WebFetch tool (built-in)

## License

MIT
