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
  - mcp__plugin_context7_context7__resolve-library-id
  - mcp__plugin_context7_context7__query-docs
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

## Dynamic Folder Structure

All imports go to `mabi-import/` with intelligent substructure:

### Documentation Sites (detected by Context7 or docs.* domain)
```
mabi-import/{library}/{version}/
  datahub.md
  data-importer.md
```
Example: `https://docs.pimcore.com/platform/Data_Importer/` (version 2025.4)
-> `mabi-import/pimcore/v2025.4/data-importer.md`

### Regular Websites
```
mabi-import/website/{domain}/
  {page-name}.md
```
Example: `https://example.com/api/docs`
-> `mabi-import/website/example.com/api-docs.md`

### Local Files
```
mabi-import/local/{project-or-context}/
  {filename}
```
Determine context from:
- Parent directory name (if meaningful, not generic like "Downloads")
- File content (check for project name in headers)
- Ask user if unclear

Example: `/home/user/projects/myapp/docs/config.md`
-> `mabi-import/local/myapp/config.md`

## Process

### 1. Determine Source Type

Check if `$ARGUMENTS` is:
- **URL**: Starts with `http://` or `https://`
- **Local path**: Everything else (file or directory)

### 2a. Local Path Import

If local path:

1. **Check if exists**:
   ```bash
   ls -la "$ARGUMENTS"
   ```

2. **Determine context** for folder structure:
   - Extract project name from path (e.g., `/projects/myapp/` -> `myapp`)
   - If path is generic (Downloads, tmp, home), ask user for context name
   - Read file header if available to detect project/tool name

3. **Confirm with user**:
   ```
   You specified a local path: {path}

   Suggested location: mabi-import/local/{context}/{filename}

   Is this correct? (The path will be copied, not moved)
   ```

4. Use AskUserQuestion to confirm or let user provide different context.

5. If confirmed:
   ```bash
   mkdir -p "mabi-import/local/{context}"
   cp -r "$ARGUMENTS" "mabi-import/local/{context}/"
   ```

### 2b. URL Import - Priority Chain

If URL, try methods in this order. Inform user at each step:

#### Step 1: Context7 (fastest, structured)

1. Extract library name from URL (e.g., "pimcore" from docs.pimcore.com)
2. Use `mcp__plugin_context7_context7__resolve-library-id` to check if library exists
3. If found:
   - Inform user: "Found in Context7! Fetching structured documentation..."
   - Use `mcp__plugin_context7_context7__query-docs` to get relevant content
   - **Detect version** from Context7 response or URL
   - Save to `mabi-import/{library}/{version}/`
   - Done!
4. If NOT found or query fails:
   - Inform user: "Not found in Context7. Trying WebFetch..."
   - Continue to Step 2

#### Step 2: WebFetch (fast, direct)

1. Use WebFetch tool with the URL
2. If successful (status 200, content returned):
   - **Detect if documentation site** (domain contains "docs", "developer", "api")
   - If docs: Try to extract library name and version -> `mabi-import/{library}/{version}/`
   - If website: Use domain -> `mabi-import/website/{domain}/`
   - Done!
3. If fails (403, blocked, captcha, timeout):
   - Inform user: "WebFetch blocked (403/captcha). Trying Playwright..."
   - Continue to Step 3

#### Step 3: Playwright (slow, but bypasses blocks)

1. Inform user: "Using Playwright browser (headless)..."
2. Use Playwright MCP tools:
   - `browser_navigate` to the URL
   - `browser_snapshot` to get page content
   - **Extract version from page** if visible (look for version selectors, breadcrumbs)
   - Extract relevant documentation
3. Determine folder structure same as WebFetch
4. Close browser when done
5. If Playwright also fails:
   - Inform user: "All methods failed. Cannot fetch this URL."
   - Suggest: Check if URL is correct, try manual copy, check network

**Note:** Playwright runs headless by default (no visible window).

### 3. Version Detection

Try to detect version from:
1. **URL path**: `/v2/`, `/v2025.4/`, `/version/19/`
2. **Page content**: Version selector, breadcrumb, title
3. **Context7 metadata**: Version info in response
4. **Default**: `latest` if no version found

### 4. Save Documentation

Target location based on type:
- Docs: `mabi-import/{library}/{version}/{page-name}.md`
- Website: `mabi-import/website/{domain}/{page-name}.md`
- Local: `mabi-import/local/{context}/{filename}`

Format saved file:
```markdown
---
source: {original URL or path}
imported: {timestamp}
method: {context7|webfetch|playwright|local}
version: {detected version or "latest"}
---

# {Title}

{Content}
```

### 5. Output

On success:
```
Documentation imported:

  Source:  {url or path}
  Method:  {context7|webfetch|playwright|local}
  Version: {version}
  Saved:   mabi-import/{structure}/{name}.md
  Size:    {file size}

Use /import:list to see all cached docs.
Use /import:search <query> to search within docs.
```

On complete failure:
```
Failed to import documentation:

  Source: {url or path}

  Tried:
    1. Context7:   {not found / error}
    2. WebFetch:   {403 blocked / error}
    3. Playwright: {error}

Cannot fetch this URL automatically.

Suggestions:
- Check if URL is correct and accessible
- Copy content manually and use /import:url-or-path /local/path
- Check if Context7/Playwright plugins are installed
```

## Notes

- Priority: Context7 -> WebFetch -> Playwright
- User is informed at each fallback step
- Playwright runs headless (no visible browser window)
- Local paths are copied, not moved
- Always ask for confirmation on local paths
- Saved docs include metadata (source, method, version, import date)
- Folder structure keeps imports organized by source type and version
