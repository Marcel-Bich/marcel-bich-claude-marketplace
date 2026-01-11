---
description: Check and fix version mismatches across all version files
allowed-tools:
  - Bash
  - Read
  - Edit
---

# Dogma: Version Sync

Run the version sync check and fix any mismatches found.

## Step 1: Run version check

```bash
{{pluginPath}}/scripts/version-sync-check.sh < /dev/null
```

## Step 2: Handle output

- If **VERSION MISMATCH DETECTED**: Update all listed files to the highest version found
- If **version-hint**: Ask user if they want to bump the version
- If no output: Versions are already in sync, report success

## Step 3: After fixing

If you made changes, commit with message: `Sync plugin version to X.Y.Z`
