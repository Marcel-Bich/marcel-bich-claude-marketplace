---
description: Run project-specific linting and formatting on staged files (non-interactive)
arguments:
  - name: path
    description: "Optional path to check (default: staged files only)"
    required: false
allowed-tools:
  - Bash
  - Read
  - Glob
  - Grep
---

# Claude-Dogma: Lint & Format

You are executing the `/dogma:lint` command. Your task is to **detect the project type and run appropriate linting and formatting tools** on staged files before commit.

**NON-INTERACTIVE:** This command runs silently. Skip anything not installed. No questions asked.

For interactive setup, use `/dogma:lint:setup` instead.

## Arguments

- `$ARGUMENTS` - Optional path to check. If empty, checks only staged files

## Step 1: Get Staged Files

**IMPORTANT:** Only process files that are staged for commit. This protects legacy code.

```bash
git diff --cached --name-only 2>/dev/null
```

If `$ARGUMENTS` is provided, use that path instead.

If no staged files, report "No staged files to lint" and exit successfully.

## Step 2: Detect Project Type & Available Tools

Check what tools are actually available (not just configured):

```bash
# Project files
ls package.json Cargo.toml go.mod pyproject.toml composer.json Gemfile mix.exs 2>/dev/null || true

# Check installed tools
[ -f "node_modules/.bin/eslint" ] && echo "eslint: installed"
[ -f "node_modules/.bin/prettier" ] && echo "prettier: installed"
command -v cargo &>/dev/null && echo "cargo: installed"
command -v go &>/dev/null && echo "go: installed"
command -v ruff &>/dev/null && echo "ruff: installed"
command -v black &>/dev/null && echo "black: installed"
[ -f "vendor/bin/phpstan" ] && echo "phpstan: installed"
[ -f "vendor/bin/php-cs-fixer" ] && echo "php-cs-fixer: installed"
```

## Step 3: Run Linting (find errors)

For each detected tool, run linting on staged files. **Skip if not installed.**

### JavaScript/TypeScript (ESLint)

```bash
if [ -f "node_modules/.bin/eslint" ]; then
    ESLINT_FILES=$(git diff --cached --name-only | grep -E '\.(js|jsx|ts|tsx|vue)$' || true)
    [ -n "$ESLINT_FILES" ] && echo "$ESLINT_FILES" | xargs npx eslint 2>&1
fi
```

### Rust (cargo clippy)

```bash
command -v cargo &>/dev/null && [ -f "Cargo.toml" ] && cargo clippy -- -D warnings 2>&1
```

### Go (go vet / golangci-lint)

```bash
if [ -f "go.mod" ]; then
    command -v golangci-lint &>/dev/null && golangci-lint run 2>&1
    # Fallback
    command -v go &>/dev/null && go vet ./... 2>&1
fi
```

### Python (ruff / flake8)

```bash
if [ -f "pyproject.toml" ] || [ -f "setup.py" ]; then
    PY_FILES=$(git diff --cached --name-only | grep -E '\.py$' || true)
    if [ -n "$PY_FILES" ]; then
        command -v ruff &>/dev/null && echo "$PY_FILES" | xargs ruff check 2>&1
    fi
fi
```

### PHP (PHPStan)

```bash
[ -f "vendor/bin/phpstan" ] && vendor/bin/phpstan analyse 2>&1
```

**If linting finds unfixable errors:** Report them and STOP. Do not proceed to formatting.

## Step 4: Run Formatting (fix style)

Check ENV before formatting:

```bash
echo "${CLAUDE_MB_DOGMA_AUTO_FORMAT:-true}"
```

**If `CLAUDE_MB_DOGMA_AUTO_FORMAT=false`:** Skip formatting entirely.

**If `true` (default):** Run formatters on staged files only.

### Prettier (JS/TS/JSON/CSS/HTML/PHP/MD)

```bash
if [ -f "node_modules/.bin/prettier" ]; then
    PRETTIER_FILES=$(git diff --cached --name-only | grep -E '\.(js|ts|jsx|tsx|json|md|css|scss|vue|php|html|yaml|yml)$' || true)
    [ -n "$PRETTIER_FILES" ] && echo "$PRETTIER_FILES" | xargs npx prettier --write 2>&1
fi
```

### ESLint --fix

```bash
if [ -f "node_modules/.bin/eslint" ]; then
    ESLINT_FILES=$(git diff --cached --name-only | grep -E '\.(js|jsx|ts|tsx|vue)$' || true)
    [ -n "$ESLINT_FILES" ] && echo "$ESLINT_FILES" | xargs npx eslint --fix 2>&1
fi
```

### Rust (cargo fmt)

```bash
command -v cargo &>/dev/null && [ -f "Cargo.toml" ] && cargo fmt 2>&1
```

### Go (gofmt / goimports)

```bash
if [ -f "go.mod" ]; then
    GO_FILES=$(git diff --cached --name-only | grep -E '\.go$' || true)
    if [ -n "$GO_FILES" ]; then
        command -v goimports &>/dev/null && echo "$GO_FILES" | xargs goimports -w 2>&1
        command -v gofmt &>/dev/null && echo "$GO_FILES" | xargs gofmt -w 2>&1
    fi
fi
```

### Python (ruff format / black)

```bash
if [ -f "pyproject.toml" ] || [ -f "setup.py" ]; then
    PY_FILES=$(git diff --cached --name-only | grep -E '\.py$' || true)
    if [ -n "$PY_FILES" ]; then
        command -v ruff &>/dev/null && echo "$PY_FILES" | xargs ruff format 2>&1
        # Fallback
        command -v black &>/dev/null && echo "$PY_FILES" | xargs black 2>&1
    fi
fi
```

### PHP (php-cs-fixer)

```bash
if [ -f "vendor/bin/php-cs-fixer" ]; then
    PHP_FILES=$(git diff --cached --name-only | grep -E '\.php$' || true)
    [ -n "$PHP_FILES" ] && echo "$PHP_FILES" | xargs vendor/bin/php-cs-fixer fix 2>&1
fi
```

## Step 5: Re-stage Formatted Files

After formatting, re-stage the files:

```bash
git diff --cached --name-only | xargs -r git add
```

## Step 6: Report Results

**Success:**

```
Lint & Format complete.

Tools used: [list what actually ran]
Files processed: X
Skipped (not installed): [list if any]

Ready to commit:
CLAUDE_MB_DOGMA_SKIP_LINT_CHECK=true git commit -m "your message"
```

**Lint errors:**

```
Linting failed:

[show errors]

Fix these issues before committing.
```

## Important Rules

1. **Non-interactive** - Never ask questions, never prompt for installation
2. **Skip gracefully** - Missing tools are skipped silently
3. **Staged files only** - Protect legacy code from unexpected changes
4. **Lint before format** - Find errors before fixing style
5. **Re-stage after format** - Keep git staging intact

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `CLAUDE_MB_DOGMA_AUTO_FORMAT` | `true` | Allow automatic formatting |
| `CLAUDE_MB_DOGMA_SKIP_LINT_CHECK` | `false` | Skip pre-commit lint check |
