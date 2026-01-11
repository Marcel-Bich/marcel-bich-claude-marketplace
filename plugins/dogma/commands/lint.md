---
name: lint
description: Run prettier check on project
allowed-tools:
  - Bash
  - Read
  - Glob
---

# Claude-Dogma: Lint Check

You are executing the `/dogma:lint` command. Your task is to **run Prettier formatting checks** on the current project.

## Step 1: Check Prettier Installation

### 1.1 Check if Prettier is available

```bash
# Check package.json for prettier
grep -q '"prettier"' package.json 2>/dev/null && echo "found"

# Check node_modules
[ -d "node_modules/prettier" ] && echo "installed"
```

**If Prettier is NOT found:**

```
Prettier is not installed in this project.

Run /dogma:lint:setup to set up linting/formatting.
```

**STOP** - Do not continue without Prettier.

### 1.2 Verify Prettier works

```bash
npx prettier --version 2>/dev/null
```

If this fails, report the error and stop.

## Step 2: Run Lint Check

### 2.1 Execute Prettier check

```bash
npx prettier --check . 2>&1
```

### 2.2 Interpret results

**If exit code 0 (all files formatted):**

```
All files are properly formatted.
```

**If exit code 1 (formatting issues found):**

Parse the output and report:

```
Formatting issues found in X files:

- src/components/Button.tsx
- src/utils/helper.ts
- config/settings.json
[... list all files]
```

## Step 3: Format Decision

### 3.1 Check auto-format setting

Read environment variable:
```bash
echo "${CLAUDE_MB_DOGMA_AUTO_FORMAT:-false}"
```

### 3.2 Handle based on setting

**IF ENV CLAUDE_MB_DOGMA_AUTO_FORMAT=true:**

```bash
npx prettier --write .
```

Report:
```
Auto-format enabled. Formatted X files:
[list changed files]
```

**ELSE (default - no auto-format):**

```
To fix formatting:
- Run: npm run format
- Or manually: npx prettier --write .

Auto-format is disabled to protect legacy code from unexpected changes.
Enable with: CLAUDE_MB_DOGMA_AUTO_FORMAT=true
```

**Do NOT automatically format** without explicit ENV setting.

## Important Rules

1. **Never auto-format by default** - Legacy code protection
2. **Skip gracefully** - If Prettier missing, suggest setup
3. **Respect ENV settings** - Only auto-format if explicitly enabled
4. **Clear reporting** - Show exactly which files have issues

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `CLAUDE_MB_DOGMA_AUTO_FORMAT` | `false` | Allow automatic formatting |

## Error Handling

- Prettier not installed: Suggest /dogma:lint:setup
- npx fails: Check node_modules, suggest npm install
- Permission denied: Report which files and why
- Config error: Show Prettier error message
