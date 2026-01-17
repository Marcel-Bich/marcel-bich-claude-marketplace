---
description: import - Fetch URL (via Playwright if blocked) or copy local path to docs/
arguments:
  - name: source
    description: URL or local path to import
    required: true
allowed-tools:
  - Bash
  - Read
  - Write
  - Glob
  - AskUserQuestion
  - WebFetch
  - mcp__plugin_playwright_playwright__browser_navigate
  - mcp__plugin_playwright_playwright__browser_snapshot
  - mcp__plugin_playwright_playwright__browser_click
  - mcp__plugin_playwright_playwright__browser_type
  - mcp__plugin_playwright_playwright__browser_close
---

# Import URL or Path

You are executing the `/import:url-or-path` command. Import documentation from a URL or local path.

## Arguments

- `$ARGUMENTS` - URL (https://...) or local file/directory path

## Process

### 1. Determine Source Type

Check if `$ARGUMENTS` is:
- **URL**: Starts with `http://` or `https://`
- **Local path**: Everything else (file or directory)

### 2a. Local Path Import

If local path:

1. **Confirm with user first**:
   ```
   You specified a local path: {path}

   This will copy the content to plugins/import/docs/

   Is this what you intended? (The path will be copied, not moved)
   ```

2. Use AskUserQuestion to confirm.

3. If confirmed:
   ```bash
   # Check if exists
   ls -la "$ARGUMENTS"

   # Determine target name (basename of path)
   TARGET_NAME=$(basename "$ARGUMENTS")

   # Copy to docs/
   cp -r "$ARGUMENTS" "plugins/import/docs/$TARGET_NAME"
   ```

4. Output success message with path.

### 2b. URL Import

If URL:

1. **First try WebFetch** (faster if not blocked):
   - Use WebFetch tool with the URL
   - If successful, save content to `plugins/import/docs/`

2. **If WebFetch fails or returns blocked/403/captcha**:
   - Inform user: "Site appears to block AI access. Using Playwright..."
   - Use Playwright MCP tools:
     - `browser_navigate` to the URL
     - `browser_snapshot` to get page content
     - Extract relevant documentation
     - Save to `plugins/import/docs/`
   - Close browser when done

3. **Naming convention**:
   - Extract meaningful name from URL path
   - Example: `https://docs.pimcore.com/platform/Data_Importer/` -> `pimcore-data-importer.md`

### 3. Save Documentation

Target location: `plugins/import/docs/{name}.md`

Format saved file:
```markdown
---
source: {original URL or path}
imported: {timestamp}
---

# {Title}

{Content}
```

### 4. Output

On success:
```
Documentation imported:

  Source: {url or path}
  Saved:  plugins/import/docs/{name}.md
  Size:   {file size}

Use /import:list to see all cached docs.
Use /import:search <query> to search within docs.
```

On error:
```
Failed to import documentation:

  Source: {url or path}
  Error:  {error message}

Suggestions:
- Check if URL is accessible
- For blocked sites, Playwright will be tried automatically
- Ensure local path exists
```

## Notes

- Playwright is only used when WebFetch fails (blocked sites)
- Local paths are copied, not moved
- Always ask for confirmation on local paths to prevent accidents
- Saved docs include metadata (source, import date) for tracking
