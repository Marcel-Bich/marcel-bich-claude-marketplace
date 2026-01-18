# marketplace

Development tools for Claude Code plugins - local testing without pushing.

## Commands

| Command | Description |
|---------|-------------|
| `/marketplace:local-copy` | Install local plugin version for testing (backup original) |
| `/marketplace:local-cleanup` | Restore original plugin version from backup |

## Usage

### Test a plugin locally

```
/marketplace:local-copy
```

This will:
1. Detect which plugin you are developing (or ask)
2. Backup the currently installed version to `/tmp/`
3. Copy your local development version to the plugin cache

After running, restart Claude Code to see your changes.

### Restore original version

```
/marketplace:local-cleanup
```

This will restore the original plugin version from backup.

## License

MIT
