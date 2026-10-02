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

## Step 4b2: Assemble changelog fragments (only with a versioned `changelog.d/`)

Some repos collect one small changelog fragment per change in a `changelog.d/` directory at
the repo root and assemble them only at release. This step applies only when ALL of these hold:

- `changelog.d/` exists at the repo root AND is versioned: `git ls-files changelog.d` lists at
  least one fragment (an excluded or ignored `changelog.d/` does not count)
- this run is a release: it produces the bundling commit with a version bump (Step 0 bumped the
  version, or the user asked for the release now). A pure mismatch fix without a bump is NOT a
  release - leave the fragments alone

If `changelog.d/` does not exist (or is not versioned), skip this step - nothing changes. Works
the same for every language and project type; only the files below are read or written.

1. **Version and date:** `X.Y.Z` = the version just bumped for the component the changelog
   belongs to (the root group, or the group whose directory holds the CHANGELOG). When several
   groups were bumped and it is unclear which one the changelog tracks, ask. Date = today,
   `YYYY-MM-DD`.
2. **Fragments:** every versioned file directly in `changelog.d/`, sorted by name, except
   `README*`, `.gitkeep`, hidden files and templates (`template*`, `_template*`). The fragment
   content is the entry text (keep it as written; one fragment may hold several bullets). A type
   in the name (towncrier style `<id>.<type>.md`, e.g. `42.fixed.md`) or a first heading inside
   the fragment says which subsection it belongs to.
3. **Target file and format:** the existing changelog at the root (`CHANGELOG.md`, `CHANGELOG`,
   `CHANGES.md`, `HISTORY.md`, first match). Keep the repo's existing format: read the newest
   release section and reuse its heading style and subsection headings (for example Keep a
   Changelog `### Added` / `### Changed` / `### Fixed`). Without a deviating existing style the
   new section is `## [X.Y.Z] - YYYY-MM-DD`. When the format is unclear (mixed styles, unknown
   fragment types, no changelog file yet), ask via AskUserQuestion before writing.
4. **Insert:** prepend the new section above the newest existing release section - below the
   title/intro and below an `## [Unreleased]` heading if the file has one (an Unreleased section
   that already has entries: ask whether they belong to this release). Group the fragments under
   the matching subsections; fragments without a type go to the repo's default subsection or, if
   there is none, directly under the version heading.
5. **Consume:** remove the consumed fragments in the SAME commit as the version bump and the
   changelog (`git rm changelog.d/<fragment>`), keeping `README*`, `.gitkeep` and templates so
   the directory stays. Respect the delete setting of DOGMA-PERMISSIONS.md (`§0lgy`): `[?]` =
   confirm first, `[ ]` = leave the fragments and tell the user which ones to remove.
6. **Never tag:** the release is this normal commit. Do not create a git tag or a hosted
   release (that stays a separate, explicit user action).

Show the assembled section in the summary (Step 5) before committing.

## Step 4c: Documentation sync

After version sync, use AskUserQuestion to ask the user interactively:

**Question:** "Should the documentation (README, Wiki) also be synchronized?"
**Options:**
1. "Yes, run /dogma:docs-update (Recommended)" - Checks for missing plugins in docs, outdated descriptions, etc.
2. "No, skip" - Skip documentation sync

If user selects yes, run `/dogma:docs-update`.

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

If changes were made, commit (one commit: version bump, synced files and - at a release with
`changelog.d/` - the assembled changelog plus the removed fragments; no tag):
```bash
git add -A && git commit -m "Sync versions across all version files"
```

## Notes

- NEVER skip version files - find them ALL first, then analyze
- Different components can have different versions (that's OK)
- Files within the SAME component must be in sync
- When in doubt about grouping, ask the user
- `changelog.d/` fragments are assembled only at a release (bump commit), never tagged; without a versioned `changelog.d/` nothing changes
