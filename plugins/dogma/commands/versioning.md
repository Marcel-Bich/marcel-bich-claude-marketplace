---
description: dogma - Check and fix version mismatches across all version files
allowed-tools:
  - Bash
  - Read
  - Edit
  - AskUserQuestion
---

# Dogma: Version Sync

Universal version file discovery and sync. Works with any project structure.

## Step 0: Check for pending changes requiring version bump

```bash
git status --porcelain
```

**If uncommitted changes exist:**

1. Load versioning rules (try in order, use first that exists):
   - `CLAUDE/CLAUDE.versioning.md`
   - `CLAUDE.versioning.md`
   - `.claude/CLAUDE.versioning.md`
   - Fallback: patch for bugfixes/features, minor for breaking changes, major for rewrites

2. Identify affected components and bump versions BEFORE syncing

**If no pending changes:** Continue to Step 1.

## Step 1: Discover ALL version files

**CRITICAL:** Find EVERY file that could contain a version. Do NOT skip files.

```bash
# Find ALL potential version files (respects .gitignore)
git ls-files --cached --others --exclude-standard 2>/dev/null | \
  grep -E '(package\.json|plugin\.json|plugin\.ya?ml|marketplace\.json|pyproject\.toml|setup\.(py|cfg)|Cargo\.toml|version\.(txt|json)|VERSION|manifest\.json|composer\.json|build\.gradle|pom\.xml|\.gemspec|mix\.exs)$' | \
  sort

# Fallback if not a git repo:
# find . -type f \( -name "package.json" ... \) | grep -v node_modules | sort
```

List ALL files found. Do not filter or assume.

## Step 1b: Discover ADDITIONAL files containing version strings

Search for files that might contain versions but don't match known filenames:

```bash
# Find files containing "version" that weren't caught by Step 1 (respects .gitignore)
git ls-files --cached --others --exclude-standard 2>/dev/null | \
  grep -E '\.(json|ya?ml|toml|xml|md)$' | \
  xargs grep -l -E '"version"|'\''version'\''|version:' 2>/dev/null | \
  sort
```

For each file found that wasn't in Step 1:

1. **Quick assessment:** Read the file and check if the version field is:
   - A project/package version (RELEVANT)
   - A dependency version (NOT relevant - managed separately)
   - A schema/spec version (NOT relevant)
   - An API version in documentation (NOT relevant)

2. **Present to user with recommendation:**

```
ADDITIONAL FILE: .claude-plugin/marketplace.json
Contains: "version": "1.0.0" (in metadata section)
Assessment: Project version - RELEVANT
Recommendation: Include in version sync

Include this file? [Y/n]
```

```
ADDITIONAL FILE: docs/api-spec.yaml
Contains: version: "2.0"
Assessment: API specification version - NOT a package version
Recommendation: Skip (different versioning scope)

Include this file? [y/N]
```

Only include files the user confirms. Add confirmed files to the list from Step 1.

## Step 2: Group version files by component

Analyze the file paths to identify logical groups:

| Pattern | Grouping |
|---------|----------|
| `plugins/<name>/*` | All files under same plugin = one group |
| `packages/<name>/*` | All files under same package = one group |
| `.claude-plugin/marketplace.json` | Marketplace root = separate group |
| Root-level files | Project root = one group |
| `src/<name>/*` | Subproject = one group |

Example groups:
```
Group: plugins/hydra
  - plugins/hydra/plugin.yaml
  - plugins/hydra/.claude-plugin/plugin.json

Group: marketplace
  - .claude-plugin/marketplace.json

Group: root
  - package.json
  - version.txt
```

**Note:** marketplace.json is a standalone group. When plugins are updated, ask user if marketplace version should also be bumped.

## Step 3: Extract versions from each file

Use appropriate extraction for each file type:

| File Type | Extraction |
|-----------|------------|
| `*.yaml`, `*.yml` | `grep "^version:"` or parse YAML |
| `*.json` | `jq -r '.version'` or grep `"version":` |
| `marketplace.json` | `jq -r '.metadata.version'` (version is nested!) |
| `*.toml` | grep `version =` |
| `Cargo.toml` | grep under `[package]` section |
| `setup.py` | grep `version=` |
| `version.txt`, `VERSION` | entire file content |

Report in table format:
```
File                                    Version
----------------------------------------
plugins/hydra/plugin.yaml               0.1.4
plugins/hydra/.claude-plugin/plugin.json 0.1.2   <-- MISMATCH
plugins/dogma/plugin.yaml               1.29.1
plugins/dogma/.claude-plugin/plugin.json 1.29.1
package.json                            2.0.0
```

## Step 4: Detect and fix mismatches

For EACH group:
1. Compare all versions within the group
2. If mismatch found:
   - Identify the HIGHEST version (semantic version comparison)
   - Update ALL other files in the group to match
   - Report: `Fixed: <group> synced to <version>`

If versions already match: `OK: <group> = <version>`

## Step 4b: Check marketplace plugin registry (Marketplaces only)

**CRITICAL for marketplace development:** New plugins are often forgotten in marketplace.json!

If `.claude-plugin/marketplace.json` exists, verify ALL plugins are registered:

```bash
# Find all plugin directories
ls -d plugins/*/ 2>/dev/null | sed 's|plugins/||g' | sed 's|/||g' | sort

# Extract registered plugins from marketplace.json
jq -r '.plugins[].name' .claude-plugin/marketplace.json 2>/dev/null | sort
```

Compare the two lists. For each plugin directory NOT in marketplace.json, **automatically fix it** (no confirmation needed - unregistered plugins are always broken):

```
FIXING: Plugin not registered in marketplace!

Plugin directory exists: plugins/credo/
Adding to: .claude-plugin/marketplace.json
```

For each missing plugin:
1. Read the plugin's description from `plugins/<name>/plugin.yaml`
2. Add entry to the `plugins` array in marketplace.json
3. Bump marketplace version

This is mandatory - a plugin without registry entry will NOT appear in `/plugin` list.

## Step 4c: Check documentation consistency (Marketplaces only)

**Prevents forgotten plugins in docs.** If this is a marketplace repo with README.md and/or wiki:

### 4c.1: Find all plugin names

```bash
# Get list of all plugins from registry (source of truth)
jq -r '.plugins[].name' .claude-plugin/marketplace.json 2>/dev/null | sort
```

### 4c.2: Check main README.md

If `README.md` exists in root:

```bash
# Extract plugin names from Available Plugins table
grep -oP '\*\*\K[a-z-]+(?=\*\*)' README.md 2>/dev/null | sort

# Extract plugin names from Quick Start install commands
grep -oP 'plugin install \K[a-z-]+(?=@)' README.md 2>/dev/null | sort

# Extract plugin names from Tags section
grep -oP '(?<=plugin, )[a-z-]+(?= plugin)' README.md 2>/dev/null | sort
```

Compare each extraction with the plugin list. Report discrepancies:

```
README.md consistency check:
  Plugin table: Missing credo
  Quick Start: Missing credo
  Tags: Missing credo plugin
```

### 4c.3: Check wiki Home.md (if wiki exists)

Search for wiki in parallel directory:

```bash
REPO_NAME=$(basename "$(git rev-parse --show-toplevel)")
WIKI_PATH="../${REPO_NAME}.wiki"
if [ -d "$WIKI_PATH" ]; then
  echo "Wiki found: $WIKI_PATH"
fi
```

If wiki exists, check `Home.md`:

```bash
# Plugin table
grep -oP '\[.*?\]\(./Claude-Code-\K[A-Za-z-]+(?=-Plugin)' "$WIKI_PATH/Home.md" 2>/dev/null | tr '[:upper:]' '[:lower:]' | sort

# Install commands
grep -oP 'plugin install \K[a-z-]+(?=@)' "$WIKI_PATH/Home.md" 2>/dev/null | sort

# Tags line
grep "Tags:" "$WIKI_PATH/Home.md" 2>/dev/null
```

Report discrepancies.

### 4c.4: Check wiki article existence

For each registered plugin, verify wiki article exists:

```bash
for plugin in $(jq -r '.plugins[].name' .claude-plugin/marketplace.json); do
  # Convert plugin name to wiki article name (e.g., dogma -> Claude-Code-Dogma-Plugin.md)
  article="Claude-Code-$(echo $plugin | sed 's/.*/\u&/' | sed 's/-./\U&/g')-Plugin.md"
  if [ ! -f "$WIKI_PATH/$article" ]; then
    echo "MISSING: $article"
  fi
done
```

### 4c.5: Fix or report

For each discrepancy found:

**If auto-fixable** (adding to existing list/table):
- Ask user: `Fix README.md plugin table? [Y/n]`
- Apply edit if confirmed

**If not auto-fixable** (missing wiki article, complex structure):
- Report clearly: `ACTION REQUIRED: Create wiki article for credo plugin`
- Suggest creating a TODO file if multiple items need attention

## Step 4d: Check documentation consistency (Non-marketplace projects)

**Fallback for any project with a wiki.** If NOT a marketplace (no `.claude-plugin/marketplace.json`) but wiki exists:

### 4d.1: Detect wiki

```bash
REPO_NAME=$(basename "$(git rev-parse --show-toplevel)")
WIKI_PATH="../${REPO_NAME}.wiki"
if [ -d "$WIKI_PATH" ] && [ ! -f ".claude-plugin/marketplace.json" ]; then
  echo "Wiki found (non-marketplace): $WIKI_PATH"
fi
```

### 4d.2: Compare versions between README and wiki

Extract version from main `README.md` (if present):

```bash
# Common version patterns in README
grep -oP '(?:version|Version|VERSION)[:\s]*v?(\d+\.\d+\.\d+)' README.md 2>/dev/null | head -1
grep -oP '(?:Current version|Latest)[:\s]*v?(\d+\.\d+\.\d+)' README.md 2>/dev/null | head -1
```

Compare with wiki `Home.md` or main wiki article:

```bash
# Check wiki for version references
grep -oP '(?:version|Version|VERSION)[:\s]*v?(\d+\.\d+\.\d+)' "$WIKI_PATH/Home.md" 2>/dev/null | head -1
```

Report if versions differ between README and wiki.

### 4d.3: Compare feature lists

If README has a "Features" or "Commands" section, check if wiki has equivalent content:

```bash
# Extract section headers from README
grep -E '^#{1,3}\s+(Features|Commands|Usage|Installation)' README.md 2>/dev/null

# Compare with wiki
grep -E '^#{1,3}\s+(Features|Commands|Usage|Installation)' "$WIKI_PATH/Home.md" 2>/dev/null
```

Flag if README has sections that wiki is missing (or vice versa).

### 4d.4: Check for orphaned wiki articles

List all wiki articles and verify they reference existing components:

```bash
ls "$WIKI_PATH"/*.md 2>/dev/null | xargs -I {} basename {} .md
```

For each article, check if the referenced component/feature still exists in the main repo.

### 4d.5: Report discrepancies

Present findings to user:

```
Wiki consistency check (non-marketplace):

  Version mismatch:
    - README.md: 2.1.0
    - Wiki Home.md: 2.0.0

  Missing in wiki:
    - "CLI Options" section (exists in README)

  Potentially orphaned wiki articles:
    - Old-Feature-Guide.md (feature removed in v2.0)
```

Ask user which items to fix or add to TODO.

## Step 5: Summary and commit

Show summary:
```
Version Sync Complete:

  Fixed:
    - plugins/hydra: 0.1.2 -> 0.1.4 (1 file updated)

  Already in sync:
    - plugins/dogma: 1.29.1 (2 files)
    - root: 2.0.0 (1 file)
```

If changes were made, commit:
```bash
git add -A && git commit -m "Sync versions across all version files"
```

## Notes

- NEVER skip version files - find them ALL first, then analyze
- Different components can have different versions (that's OK)
- Files within the SAME component must be in sync
- When in doubt about grouping, ask the user
