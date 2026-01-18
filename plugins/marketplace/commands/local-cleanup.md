---
name: marketplace:local-cleanup
description: marketplace - Restore original plugin version from backup
allowed-tools:
  - Bash
  - Read
  - Glob
  - AskUserQuestion
---

# Local Cleanup - Restore original version

Restore the original plugin version from backup.

## Steps

### 1. Find existing backups

List all backups:

```bash
ls -d /tmp/marketplace-backup-* 2>/dev/null
```

**If no backups:**
- Inform user that no backups exist
- End the process

**If one backup:**
- Use it automatically

**If multiple backups:**
- Ask user with AskUserQuestion which one to restore

### 2. Find plugin installation path

Extract plugin name from backup path:

```bash
BACKUP_PATH="/tmp/marketplace-backup-<plugin-name>"
PLUGIN_NAME="<from-backup-path>"
```

Read the installed plugin info:

```bash
cat ~/.claude/plugins/installed_plugins.json
```

Find the `installPath` for the plugin.

### 3. Restore

Restore the original version:

```bash
INSTALL_PATH="<from-installed_plugins.json>"

# Remove current (local test) version
rm -rf "${INSTALL_PATH}"/*

# Restore backup
cp -r "${BACKUP_PATH}"/* "${INSTALL_PATH}/"
```

### 4. Remove backup

Ask user if backup should be deleted:

```
Restore completed.
Should the backup in /tmp/marketplace-backup-{plugin}/ be deleted?
```

If yes:

```bash
rm -rf "${BACKUP_PATH}"
```

### 5. Confirmation

Inform user:
- Original version was restored
- IMPORTANT: Restart Claude Code for changes to take effect

## Error handling

- If no backup: Inform user
- If plugin no longer installed: Inform user, keep backup
- If restore fails: Do not delete backup, inform user
