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
# Find ALL potential version files recursively
find . -type f \( \
  -name "package.json" -o \
  -name "plugin.json" -o \
  -name "plugin.yaml" -o \
  -name "plugin.yml" -o \
  -name "pyproject.toml" -o \
  -name "setup.py" -o \
  -name "setup.cfg" -o \
  -name "Cargo.toml" -o \
  -name "version.txt" -o \
  -name "VERSION" -o \
  -name "version.json" -o \
  -name "manifest.json" -o \
  -name "composer.json" -o \
  -name "build.gradle" -o \
  -name "pom.xml" -o \
  -name "*.gemspec" -o \
  -name "mix.exs" \
\) 2>/dev/null | grep -v node_modules | grep -v ".git/" | sort
```

List ALL files found. Do not filter or assume.

## Step 2: Group version files by component

Analyze the file paths to identify logical groups:

| Pattern | Grouping |
|---------|----------|
| `plugins/<name>/*` | All files under same plugin = one group |
| `packages/<name>/*` | All files under same package = one group |
| Root-level files | Project root = one group |
| `src/<name>/*` | Subproject = one group |

Example groups:
```
Group: plugins/hydra
  - plugins/hydra/plugin.yaml
  - plugins/hydra/.claude-plugin/plugin.json

Group: root
  - package.json
  - version.txt
```

## Step 3: Extract versions from each file

Use appropriate extraction for each file type:

| File Type | Extraction |
|-----------|------------|
| `*.yaml`, `*.yml` | `grep "^version:"` or parse YAML |
| `*.json` | `jq -r '.version'` or grep `"version":` |
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
