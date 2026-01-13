---
description: dogma - Check and fix version mismatches across all version files
allowed-tools:
  - Bash
  - Read
  - Edit
---

# Dogma: Version Sync

Check all version files and fix any mismatches.

## Step 0: Bump versions for pending changes FIRST

**CRITICAL:** Before syncing, check if there are uncommitted changes that require a version bump.

```bash
git status --porcelain
```

**If changes exist in any plugin directory:**

1. **Load versioning rules** (try in order, use first that exists):
   - `CLAUDE/CLAUDE.versioning.md` - project-specific rules
   - `CLAUDE.versioning.md` - project-specific rules
   - `.claude/CLAUDE.versioning.md` - project-specific rules
   - **Fallback only if none exist:**
     - patch (default): bugfixes, small features, improvements, refactoring
     - minor: breaking changes, migration required, BIG new features
     - major: groundbreaking changes, relaunch, full rewrite

2. Identify which plugins have changes:
   ```bash
   git status --porcelain | grep "plugins/" | sed 's|.*plugins/\([^/]*\)/.*|\1|' | sort -u
   ```

3. For EACH affected plugin:
   - Read the current version from `plugins/<name>/plugin.yaml`
   - Apply the versioning rules loaded in step 1
   - Update the version in `plugins/<name>/plugin.yaml`

4. Report what was bumped:
   ```
   Bumped <plugin> from X.Y.Z to X.Y.(Z+1)
   ```

**If no pending changes:** Skip to Step 1.

## Step 1: Find version files

```bash
# Check plugin structure
find plugins -name "plugin.yaml" -o -name "plugin.json" 2>/dev/null | head -20

# Check common version files
ls -la package.json pyproject.toml Cargo.toml setup.py version.txt VERSION 2>/dev/null || true
```

## Step 2: Extract versions

For each file found, extract the version:

**YAML files (plugin.yaml):**
```bash
grep "^version:" plugins/*/plugin.yaml
```

**JSON files (plugin.json, package.json):**
```bash
grep '"version"' plugins/*/.claude-plugin/plugin.json package.json 2>/dev/null
```

## Step 3: Compare and fix

1. If all versions match: Report "All versions in sync: X.Y.Z"
2. If mismatch found:
   - Identify the highest version
   - Update all files to that version
   - Report which files were updated

## Step 4: Commit if changes made

```bash
git add -A && git commit -m "Sync plugin version to X.Y.Z"
```

Replace X.Y.Z with the actual version.
