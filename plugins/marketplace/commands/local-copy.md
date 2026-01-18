---
name: marketplace:local-copy
description: marketplace - Install local plugin version for testing (backup original)
allowed-tools:
  - Bash
  - Read
  - Glob
  - AskUserQuestion
---

# Local Copy - Test plugin locally without pushing

Copy the local development version of a plugin to the Claude plugin cache for testing without pushing.

## Steps

### 1. Detect plugin

Check the current working directory:

```bash
pwd
```

Search for `plugin.yaml` in current directory or in `plugins/*/`:

```bash
# Directly in cwd?
ls plugin.yaml 2>/dev/null

# Or are we in the marketplace root?
ls plugins/*/plugin.yaml 2>/dev/null
```

**If plugin.yaml found:**
- Extract plugin name from the file
- Confirm with user which plugin is meant

**If multiple or none found:**
- Ask user with AskUserQuestion which plugin to test
- List available plugins

### 2. Find installation path

Read the installed plugin info:

```bash
cat ~/.claude/plugins/installed_plugins.json
```

Search for the plugin with pattern `{plugin-name}@{marketplace-name}`.
The `installPath` shows where the plugin is installed.

**If plugin not installed:**
- Inform user that the plugin must be installed first
- End the process

### 3. Create backup

Create backup of current installation:

```bash
PLUGIN_NAME="<plugin-name>"
INSTALL_PATH="<from-installed_plugins.json>"
BACKUP_PATH="/tmp/marketplace-backup-${PLUGIN_NAME}"

# Remove old backup if exists
rm -rf "${BACKUP_PATH}"

# Create backup
cp -r "${INSTALL_PATH}" "${BACKUP_PATH}"
```

Confirm to user that backup was created.

### 4. Copy local version

Copy the local development version:

```bash
LOCAL_PATH="<path-to-local-plugin>"

# Replace installed version
rm -rf "${INSTALL_PATH}"/*
cp -r "${LOCAL_PATH}"/* "${INSTALL_PATH}/"
```

### 5. Confirmation

Inform user:
- Local version was installed
- Backup is in `/tmp/marketplace-backup-{plugin-name}/`
- To restore: `/marketplace:local-cleanup`
- IMPORTANT: Restart Claude Code for changes to take effect

## Error handling

- If plugin not found: Ask user
- If not installed: Inform user, suggest installation
- If backup fails: Abort and inform user
