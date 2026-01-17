---
description: "dogma - Sync documentation across README files and wiki articles"
arguments:
  - name: wiki-path
    description: "Path to wiki repo or GitHub wiki URL (optional, will search/ask if not provided)"
    required: false
allowed-tools:
  - Bash
  - Read
  - Write
  - Edit
  - Glob
  - Grep
  - AskUserQuestion
  - Task
---

# Claude-Dogma: Documentation Update

You are executing the `/dogma:docs-update` command. Your task is to **synchronize documentation** across README files and wiki articles, ensuring everything is up-to-date.

## Overview

This command:
1. Locates the wiki repository (parallel checkout, or clone from URL)
2. Analyzes changes in the main repo that affect documentation
3. Compares with wiki content to find gaps or outdated info
4. Interactively asks user about each update
5. Commits and pushes to both repos (respecting DOGMA-PERMISSIONS.md)

---

## Phase 1: Locate Wiki Repository

### Step 1.1: Check Argument

The user provided: `$ARGUMENTS`

If a path or URL was provided:
- If it's a local path: verify it exists and is a git repo
- If it's a GitHub URL: clone it to a temp location or find existing clone

### Step 1.2: Search for Existing Wiki Checkout

If no argument provided, search common locations:

```bash
# Get current repo name
REPO_NAME=$(basename "$(git rev-parse --show-toplevel)")

# Search parallel directories
ls -d "../${REPO_NAME}.wiki" 2>/dev/null || true
ls -d "../${REPO_NAME}-wiki" 2>/dev/null || true
ls -d "wiki" 2>/dev/null || true
ls -d ".wiki" 2>/dev/null || true

# Search parent directory for any .wiki repos
ls -d ../*.wiki 2>/dev/null || true
```

### Step 1.3: Ask User if Not Found

If wiki repo not found, ask:

```
Wiki repository not found automatically.

How would you like to provide the wiki location?

1. Enter local path (e.g., ../my-project.wiki)
2. Enter GitHub wiki URL (e.g., https://github.com/user/repo.wiki.git)
3. Skip wiki sync (only update README files in main repo)
4. Cancel
```

If user provides GitHub URL:
```bash
# Clone to parent directory
cd .. && git clone <URL>
```

### Step 1.4: Verify Wiki Repository

Once found/cloned:
```bash
cd <wiki-path>
git rev-parse --git-dir  # Verify it's a git repo
git remote -v            # Show remote URL
ls -la                   # List wiki files
```

Report:
```
Wiki repository found: <path>
Remote: <url>
Files: <count> markdown files
```

---

## Phase 2: Analyze Main Repository Documentation

### Step 2.1: Find All Documentation Sources

```bash
# Main README
ls README.md 2>/dev/null

# Plugin READMEs
find plugins -name "README.md" 2>/dev/null

# Other documentation (respects .gitignore)
git ls-files --cached --others --exclude-standard '*.md' 2>/dev/null | head -50

# Plugin metadata (descriptions, keywords)
find plugins -name "plugin.yaml" -o -name "plugin.json" 2>/dev/null
```

### Step 2.2: Extract Key Information from Main Repo

For each plugin, extract:
- **Version** from plugin.yaml
- **Description** from plugin.yaml
- **Commands** list from plugin.yaml
- **Features** from README.md
- **Keywords/Tags** from plugin.json or README.md

Build a documentation inventory:
```
MAIN REPO DOCUMENTATION:
========================

plugins/dogma:
  Version: 1.25.0
  Commands: sync, cleanup, lint, lint:setup, versioning, permissions, force, sanitize-git, docs-update
  Description: Intelligent sync of Claude instructions...
  README sections: Features, Installation, Documentation, License

plugins/limit:
  Version: X.Y.Z
  Commands: ...
  ...
```

### Step 2.3: Get Recent Changes

```bash
# Recent commits that might affect docs
git log --oneline -20 --all

# Changed files recently
git diff --name-only HEAD~10..HEAD 2>/dev/null || git diff --name-only HEAD~5..HEAD
```

Identify which plugins/features have changed since last wiki update.

---

## Phase 3: Analyze Wiki Content

### Step 3.1: Inventory Wiki Articles

```bash
cd <wiki-path>
ls -la *.md
```

For each wiki article, extract:
- Documented version (if mentioned)
- Documented commands/features
- Last updated (git log for that file)

### Step 3.2: Build Wiki Inventory

```
WIKI DOCUMENTATION:
===================

Claude-Code-Dogma-Plugin.md:
  Last updated: <date>
  Documented version: 1.24.0 (OUTDATED - main repo has 1.25.0)
  Documented commands: sync, cleanup, lint, lint:setup, versioning, permissions, force
  Missing commands: sanitize-git, docs-update

Claude-Code-Limit-Plugin.md:
  Last updated: <date>
  Documented version: 1.5.11
  Status: UP TO DATE
```

---

## Phase 4: Compare and Identify Gaps

### Step 4.1: Version Mismatches

Compare versions between:
- `plugins/<name>/plugin.yaml` (source of truth)
- `plugins/<name>/README.md`
- Wiki article for that plugin

### Step 4.2: Missing Features/Commands

For each plugin:
- List commands in plugin.yaml
- Check if each command is documented in:
  - Plugin README.md
  - Wiki article

### Step 4.3: Outdated Descriptions

Compare descriptions between:
- plugin.yaml description
- plugin.json description
- README.md first paragraph
- Wiki article introduction

### Step 4.4: Check plugin list consistency (Marketplaces only)

**Prevents forgotten plugins in docs.** If `.claude-plugin/marketplace.json` exists:

#### 4.4.1: Get plugin list from registry (source of truth)

```bash
jq -r '.plugins[].name' .claude-plugin/marketplace.json 2>/dev/null | sort
```

#### 4.4.2: Check main README.md

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

#### 4.4.3: Check wiki Home.md

```bash
# Plugin table
grep -oP '\[.*?\]\(./Claude-Code-\K[A-Za-z-]+(?=-Plugin)' "$WIKI_PATH/Home.md" 2>/dev/null | tr '[:upper:]' '[:lower:]' | sort

# Install commands
grep -oP 'plugin install \K[a-z-]+(?=@)' "$WIKI_PATH/Home.md" 2>/dev/null | sort

# Tags line
grep "Tags:" "$WIKI_PATH/Home.md" 2>/dev/null
```

#### 4.4.4: Check wiki article existence

```bash
for plugin in $(jq -r '.plugins[].name' .claude-plugin/marketplace.json); do
  # Convert plugin name to wiki article name (e.g., dogma -> Claude-Code-Dogma-Plugin.md)
  article="Claude-Code-$(echo $plugin | sed 's/.*/\u&/' | sed 's/-./\U&/g')-Plugin.md"
  if [ ! -f "$WIKI_PATH/$article" ]; then
    echo "MISSING: $article"
  fi
done
```

### Step 4.5: Check wiki consistency (Non-marketplace projects)

**Fallback for projects with wiki but no marketplace.** If wiki exists but no `.claude-plugin/marketplace.json`:

#### 4.5.1: Compare versions (only if wiki already has versions)

**Important:** Do NOT add versions to wiki articles. Only sync if wiki already contains version references.

```bash
# Check if wiki has any version references
WIKI_HAS_VERSION=$(grep -lE '(?:version|Version|VERSION)[:\s]*v?[0-9]+\.[0-9]+' "$WIKI_PATH"/*.md 2>/dev/null)

if [ -n "$WIKI_HAS_VERSION" ]; then
  # Wiki has versions - compare with README
  grep -oP '(?:version|Version|VERSION)[:\s]*v?(\d+\.\d+\.\d+)' README.md 2>/dev/null | head -1
  grep -oP '(?:version|Version|VERSION)[:\s]*v?(\d+\.\d+\.\d+)' "$WIKI_PATH/Home.md" 2>/dev/null | head -1
fi
```

If wiki has no version references, skip version comparison entirely.

#### 4.5.2: Compare feature sections

```bash
# README sections
grep -E '^#{1,3}\s+(Features|Commands|Usage|Installation)' README.md 2>/dev/null

# Wiki sections
grep -E '^#{1,3}\s+(Features|Commands|Usage|Installation)' "$WIKI_PATH/Home.md" 2>/dev/null
```

#### 4.5.3: Check for orphaned wiki articles

```bash
ls "$WIKI_PATH"/*.md 2>/dev/null | xargs -I {} basename {} .md
```

Verify each article references existing components in main repo.

### Step 4.6: Check Credo Plugin References (marcel-bich-claude-marketplace only)

**IMPORTANT:** This step is MANDATORY when running in the `marcel-bich-claude-marketplace` repository. Skip this step for all other repositories.

```bash
# Detection - run this check FIRST
REPO_NAME=$(basename "$(git rev-parse --show-toplevel)")
if [ "$REPO_NAME" != "marcel-bich-claude-marketplace" ]; then
    echo "Not in marketplace repo - skipping Credo checks"
    # Skip to Step 4.7
fi
```

The `credo` plugin is the **core plugin** that orchestrates all others. It contains workflow guides (`plugins/credo/commands/psalm.md`) that reference other plugins. These references MUST stay in sync.

#### 4.6.1: Find Credo's main content file

```bash
# The main workflow guide
ls plugins/credo/commands/*.md 2>/dev/null
```

#### 4.6.2: Extract all command references from Credo

```bash
# Find all /plugin:command references in credo
grep -ohP '/[a-z-]+:[a-z-:]+' plugins/credo/commands/*.md 2>/dev/null | sort -u
```

#### 4.6.3: Compare against actual plugin commands

For each plugin in the marketplace, extract its actual commands from plugin.yaml and compare:

```bash
# Get all actual commands from all plugins
for plugin_yaml in plugins/*/plugin.yaml; do
    plugin_name=$(basename $(dirname "$plugin_yaml"))
    echo "=== $plugin_name ==="
    grep -E "^  [a-z]" "$plugin_yaml" | sed 's/:$//'
done
```

#### 4.6.4: Identify discrepancies

Report any:
- **Missing in Credo**: Commands that exist in plugin.yaml but are not mentioned in Credo (if relevant to workflow)
- **Outdated in Credo**: Commands mentioned in Credo that no longer exist
- **New plugins**: Plugins in marketplace that Credo doesn't mention at all

#### 4.6.5: Interactive Credo updates

For each discrepancy found, ask:

```
CREDO UPDATE: Missing command reference

plugins/dogma now has: /dogma:recommended:setup
credo/commands/psalm.md does not mention it.

Should this be added to credo?
1. Yes, add to appropriate section
2. No, skip (not relevant for workflow guide)
3. Show me the context first
```

**Section mapping for new items:**

| Item Type | Credo Section |
|-----------|---------------|
| Core workflow commands | Main workflow steps |
| Setup/sync commands | Setup/Installation section |
| Optional tools | Optional Topics section |
| New plugins | Prerequisites + relevant topic |

### Step 4.7: Generate Findings Report

```
DOCUMENTATION SYNC REPORT
=========================

OUTDATED (action required):
---------------------------

1. Wiki: Claude-Code-Dogma-Plugin.md
   Issue: Missing commands: /dogma:sanitize-git, /dogma:docs-update
   Action: Add documentation for new commands

2. Wiki: Claude-Code-Dogma-Plugin.md
   Issue: Version shows 1.24.0, current is 1.25.0
   Action: Update version reference

3. README: plugins/dogma/README.md
   Issue: Missing /dogma:docs-update in command list
   Action: Add to slash commands section

UP TO DATE:
-----------
- plugins/limit/README.md
- Claude-Code-Limit-Plugin.md
- ...

TOTAL: 3 updates needed, 5 files up to date
```

---

## Phase 5: Interactive Update Process

### Step 5.1: Present Findings

Show the complete report from Phase 4.

Ask:
```
How would you like to proceed?

1. Review and approve each update individually (recommended)
2. Show me what changes would be made first
3. Skip to specific file
4. Cancel (no changes)
```

### Step 5.2: For Each Update

Present the specific change:

```
UPDATE 1 of 3: Wiki - Claude-Code-Dogma-Plugin.md
=================================================

CURRENT (lines 45-52):
----------------------
### Slash Commands

- `/dogma:sync` - Sync Claude instructions...
- `/dogma:cleanup` - Find and fix AI patterns...
- `/dogma:lint` - Run linting...
- `/dogma:force` - Apply CLAUDE rules...

PROPOSED ADDITION:
------------------
- `/dogma:sanitize-git` - Sanitize git history from Claude/AI traces and fix tracking issues
- `/dogma:docs-update` - Sync documentation across README files and wiki articles

Apply this update?
1. Yes, apply
2. No, skip
3. Edit manually (show me the file)
4. Show more context
```

### Step 5.3: Apply Approved Updates

For each approved update:
1. Read the file
2. Apply the edit
3. Confirm success

```
Updated: Claude-Code-Dogma-Plugin.md
- Added 2 new commands to Slash Commands section
```

---

## Phase 6: Commit and Push Changes

### Step 6.1: Check DOGMA-PERMISSIONS.md in Main Repo

```bash
# Check main repo permissions
cat DOGMA-PERMISSIONS.md 2>/dev/null | grep -E "(git commit|git push)" || true
```

If permissions file exists, respect the settings.
If git commit/push not permitted, inform user:
```
Changes applied locally but NOT committed.
DOGMA-PERMISSIONS.md does not allow git commit/push.

To commit manually:
  git add -A && git commit -m "Update documentation"
  git push
```

### Step 6.2: Check DOGMA-PERMISSIONS.md in Wiki Repo

```bash
cd <wiki-path>
cat DOGMA-PERMISSIONS.md 2>/dev/null | grep -E "(git commit|git push)" || true
```

Same logic as above.

### Step 6.3: Commit Main Repo Changes

If permitted:
```bash
# Stage documentation changes only
git add README.md plugins/*/README.md

# Check if there are changes to commit
git diff --cached --quiet || git commit -m "docs: Update documentation"
```

### Step 6.4: Commit Wiki Changes

If permitted:
```bash
cd <wiki-path>
git add -A
git diff --cached --quiet || git commit -m "docs: Sync with main repo v<version>"
```

### Step 6.5: Push Both Repos

If permitted:
```bash
# Main repo
git push origin $(git branch --show-current)

# Wiki repo
cd <wiki-path>
git push origin $(git branch --show-current)
```

---

## Phase 7: Final Report

```
DOCUMENTATION UPDATE COMPLETE
=============================

MAIN REPOSITORY:
  Changed files: 2
  - README.md (updated)
  - plugins/dogma/README.md (updated)
  Commit: abc1234 "docs: Update documentation"
  Pushed: Yes

WIKI REPOSITORY:
  Changed files: 1
  - Claude-Code-Dogma-Plugin.md (updated)
  Commit: def5678 "docs: Sync with main repo v1.25.0"
  Pushed: Yes

SUMMARY:
  Total updates: 3
  Applied: 3
  Skipped: 0

All documentation is now synchronized.
```

---

## Error Handling

### Wiki Not Found and User Cancels
```
No wiki repository provided. Skipping wiki sync.
Only checking README files in main repository.
```

### No Changes Needed
```
All documentation is up to date.
No changes required.
```

### Permission Denied for Push
```
Changes committed locally but push was blocked.

Main repo: Committed locally, push blocked by DOGMA-PERMISSIONS.md
Wiki repo: Committed locally, push blocked by DOGMA-PERMISSIONS.md

Push manually when ready:
  git push  # in main repo
  cd <wiki-path> && git push  # in wiki repo
```

### Git Conflicts
```
Warning: Could not push due to conflicts.

Please resolve manually:
  cd <path>
  git pull --rebase
  git push
```

---

## Important Rules

1. **Never auto-update without asking** - Always get user confirmation for each change
2. **Respect DOGMA-PERMISSIONS.md** - Check permissions in BOTH repos before commit/push
3. **Show context** - User needs to see what's being changed
4. **Preserve formatting** - Match existing wiki/README style
5. **Version accuracy** - Always use version from plugin.yaml as source of truth
6. **Complete the job** - Don't leave uncommitted changes, either commit or report clearly
7. **Both repos** - Remember to handle both main repo AND wiki repo

---

## Example Session

```
/dogma:docs-update ../my-project.wiki

Phase 1: Locating wiki repository...
Wiki found: ../my-project.wiki
Remote: https://github.com/user/my-project.wiki.git

Phase 2: Analyzing main repository...
Found 4 plugins with documentation
Found 6 README files

Phase 3: Analyzing wiki content...
Found 5 wiki articles

Phase 4: Comparing documentation...

DOCUMENTATION SYNC REPORT
=========================

OUTDATED:
1. Wiki: Claude-Code-Dogma-Plugin.md - Missing 2 commands
2. Wiki: Claude-Code-Dogma-Plugin.md - Version outdated (1.24.0 -> 1.25.0)

UP TO DATE: 4 files

Proceed with updates? [1] Review individually

UPDATE 1/2: Add missing commands
[shows diff]
Apply? [1] Yes

UPDATE 2/2: Update version
[shows diff]
Apply? [1] Yes

Phase 6: Committing changes...
Main repo: No changes
Wiki repo: Committed "docs: Sync with main repo v1.25.0"

Phase 7: Pushing changes...
Wiki repo: Pushed successfully

COMPLETE: 2 updates applied, all documentation synchronized.
```
