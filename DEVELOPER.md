# Developer Setup

Instructions for developers working on this marketplace.

## Activate Git Hooks

**Automatic:** Hooks are activated automatically when running `npm install`.

**Manual:** If not using npm, run once after cloning:

```bash
git config core.hooksPath .githooks
```

### Available Hooks

| Hook | Function |
|------|----------|
| `pre-commit` | Checks version mismatches between `plugin.yaml` and `.claude-plugin/plugin.json` |

### Deactivate Hooks

```bash
git config --unset core.hooksPath
```

## Git Configuration

Run once after cloning to suppress warnings about ignored files (prevents accidental `-f` adds):

```bash
git config advice.addIgnoredFile false
```

## Workflow

1. **Make changes**
2. **Bump version** - Update both files:
   - `plugins/<name>/plugin.yaml`
   - `plugins/<name>/.claude-plugin/plugin.json`
3. **Commit** - Hook automatically checks for mismatches

On mismatch: Run `/dogma:versioning` to fix.
