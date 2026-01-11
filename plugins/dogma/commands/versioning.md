---
description: Check and fix version mismatches across all version files
allowed-tools:
  - Bash
  - Read
  - Edit
---

# Dogma: Version Sync

Check all version files and fix any mismatches.

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
