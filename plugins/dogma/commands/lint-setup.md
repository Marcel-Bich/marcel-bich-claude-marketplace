---
name: lint-setup
description: Interactive setup for linting/formatting with Prettier
allowed-tools:
  - Bash
  - Read
  - Write
  - Glob
  - Grep
  - AskUserQuestion
  - WebSearch
---

# Claude-Dogma: Lint/Prettier Setup

You are executing the `/dogma:lint:setup` command. Your task is to **interactively set up Prettier and related linting tools** for the current project.

## Step 1: NVM/Node Check

### 1.1 Check if nvm is installed

```bash
nvm -v 2>/dev/null
```

**If nvm is NOT installed:**

Detect OS and shell:
```bash
# OS detection
OSTYPE="$OSTYPE"
uname -s

# Shell detection
echo "$SHELL"
```

Ask the user:
```
nvm is not installed. It helps manage Node.js versions.

Would you like installation instructions?
1. Yes, show me how to install nvm
2. No, I already have Node.js managed differently
```

If yes, provide OS-specific instructions:
- **macOS/Linux (bash/zsh):**
  ```bash
  curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
  ```
- **Fish shell:**
  ```bash
  # Use fisher: fisher install jorgebucaran/nvm.fish
  ```
- **Windows:** Recommend nvm-windows from https://github.com/coreybutler/nvm-windows

### 1.2 Check Node.js version

```bash
node -v 2>/dev/null
```

**If Node.js version < 20:**
```
Node.js version is $(node -v), but v20+ is recommended for modern tooling.

Would you like to upgrade?
1. Yes, run: nvm install 20 && nvm use 20
2. No, keep current version
```

### 1.3 Create .nvmrc

If nvm is available and no .nvmrc exists:
```bash
echo "v20" > .nvmrc
```

Report:
```
Created .nvmrc with v20
Run 'nvm use' to switch to this version.
```

## Step 2: Project Analysis

### 2.1 Detect file types in project

```bash
# Find all source file extensions
find . -type f \
  -not -path '*/node_modules/*' \
  -not -path '*/.git/*' \
  -not -path '*/vendor/*' \
  -not -path '*/dist/*' \
  -not -path '*/build/*' \
  | sed 's/.*\.//' | sort | uniq -c | sort -rn | head -20
```

### 2.2 Map extensions to Prettier plugins

| Extension | Plugin | Notes |
|-----------|--------|-------|
| `.php` | `@prettier/plugin-php` | Requires phpVersion config |
| `.vue` | (built-in) | No extra plugin needed |
| `.twig` | `@shopify/prettier-plugin-liquid` | Uses liquid-html parser |
| `.astro` | `prettier-plugin-astro` | For Astro projects |
| `.ts/.tsx/.js/.jsx` | (built-in) | No extra plugin needed |
| `.json/.yaml/.yml` | (built-in) | No extra plugin needed |
| `.md` | (built-in) | No extra plugin needed |
| `.scss/.css` | (built-in) | No extra plugin needed |

### 2.3 Check existing configuration

```bash
# Check for existing Prettier config
ls -la .prettierrc* prettier.config.* 2>/dev/null

# Check package.json for prettier config
grep -l '"prettier"' package.json 2>/dev/null

# Check for .editorconfig
ls -la .editorconfig 2>/dev/null

# Check for existing package.json
ls -la package.json 2>/dev/null
```

### 2.4 Report findings

```
Project Analysis Complete

File types detected:
- TypeScript/JavaScript: 42 files
- PHP: 15 files
- Vue: 8 files
- SCSS: 12 files

Existing configuration:
- package.json: [Found/Missing]
- .prettierrc: [Found/Missing]
- .editorconfig: [Found/Missing]

Recommended plugins:
- @prettier/plugin-php (for .php files)
```

## Step 3: Dependencies

### 3.1 Create package.json if missing

If no package.json exists:
```
No package.json found.

Would you like to create one?
1. Yes, create minimal package.json
2. No, skip (Prettier setup requires package.json)
```

If yes:
```bash
npm init -y
```

### 3.2 Determine required packages

Build list of packages to install:
- `prettier` (always required)
- Plugins based on detected file types (Step 2)

### 3.3 Security check for EACH package

**CRITICAL: Follow @CLAUDE/CLAUDE.security.md**

For each package, before installation:

1. Check package on socket.dev or npm:
```bash
# Check socket.dev (preferred)
curl -s "https://socket.dev/api/npm/package/@prettier/plugin-php/0.22.2" 2>/dev/null | head -5

# Fallback: npm view
npm view @prettier/plugin-php@0.22.2 --json 2>/dev/null | head -20
```

2. Present to user:
```
Package: @prettier/plugin-php@0.22.2

Security status: Checking...
- Downloads: 180k/week
- Maintainers: prettier
- Last updated: 2024-01-15
- Known vulnerabilities: None

Install this package?
1. Yes, install
2. No, skip
3. Show more details
```

**Red flags to check (from CLAUDE.security.md):**
- Package < 30 days old
- < 1000 downloads/week
- No maintainers listed
- Known vulnerabilities
- Typosquatting (check spelling!)

### 3.4 Install approved packages

```bash
npm install --save-dev prettier @prettier/plugin-php @shopify/prettier-plugin-liquid
```

Report each installation:
```
Installing prettier@3.2.5... OK
Installing @prettier/plugin-php@0.22.2... OK
```

## Step 4: Configuration Files

### 4.1 Create .editorconfig

<templates>
Use this as base template for .editorconfig:

@editorconfig.txt
</templates>

Ask user:
```
Create .editorconfig for consistent editor settings?

Preview:
- charset: utf-8
- indent: 4 spaces
- line ending: LF
- max line length: 120

1. Yes, create with these settings
2. No, skip
3. Customize settings first
```

### 4.2 Create .prettierrc

<templates>
Use this as base template, adapt to detected languages:

@prettierrc.txt
</templates>

Build config based on detected file types:
- Include only plugins for detected languages
- Set appropriate overrides
- Configure phpVersion if PHP detected

Ask user:
```
Create .prettierrc?

Settings:
- printWidth: 120
- semi: false
- singleQuote: true
- trailingComma: es5
- Plugins: [list detected plugins]

1. Yes, create
2. No, skip
3. Customize settings
```

### 4.3 Create .prettierignore

<templates>
Use this as base template:

@prettierignore.txt
</templates>

Ask user:
```
Create .prettierignore?

Will ignore:
- node_modules, vendor, dist, build
- .git, .idea, .vscode
- Lock files, binary files
- [any additional project-specific paths]

1. Yes, create
2. No, skip
3. Customize paths
```

### 4.4 Add npm scripts to package.json

Read current package.json and add scripts:

```json
{
  "scripts": {
    "format": "prettier --write .",
    "format:check": "prettier --check .",
    "format:staged": "prettier --write $(git diff --cached --name-only --diff-filter=ACMR | grep -E '\\.(js|ts|jsx|tsx|json|md|css|scss|vue|php)$' | xargs)"
  }
}
```

Ask user:
```
Add Prettier scripts to package.json?

Scripts to add:
- format: Format all files
- format:check: Check formatting without changes
- format:staged: Format only staged files

1. Yes, add scripts
2. No, skip
```

## Step 5: IDE Configuration

### 5.1 Ask which IDE

```
Which IDE do you use?

1. PhpStorm/WebStorm/IntelliJ
2. VS Code
3. Other/None
```

### 5.2 PhpStorm/WebStorm/IntelliJ

Create `.idea/prettier.xml`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<project version="4">
  <component name="PrettierConfiguration">
    <option name="myConfigurationMode" value="AUTOMATIC" />
    <option name="myRunOnSave" value="true" />
    <option name="myRunOnReformat" value="true" />
  </component>
</project>
```

Report:
```
Created .idea/prettier.xml
Prettier will run on save and on reformat (Ctrl+Alt+L / Cmd+Alt+L)
```

### 5.3 VS Code

Create or update `.vscode/settings.json`:

```json
{
  "editor.formatOnSave": true,
  "editor.defaultFormatter": "esbenp.prettier-vscode",
  "[javascript]": { "editor.defaultFormatter": "esbenp.prettier-vscode" },
  "[typescript]": { "editor.defaultFormatter": "esbenp.prettier-vscode" },
  "[json]": { "editor.defaultFormatter": "esbenp.prettier-vscode" },
  "[vue]": { "editor.defaultFormatter": "esbenp.prettier-vscode" },
  "[php]": { "editor.defaultFormatter": "esbenp.prettier-vscode" }
}
```

Report:
```
Updated .vscode/settings.json
Install the 'Prettier - Code formatter' extension if not already installed.
```

### 5.4 Other IDEs

If user selects "Other":
```
Would you like me to search for Prettier integration instructions for your IDE?

Enter your IDE name, or skip:
1. Search for [IDE name]
2. Skip IDE configuration
```

If searching, use WebSearch to find instructions.

## Step 6: Summary

```
Lint/Prettier Setup Complete

Created:
+ .nvmrc (v20)
+ .editorconfig
+ .prettierrc
+ .prettierignore
+ .vscode/settings.json (or .idea/prettier.xml)

Installed:
+ prettier@3.2.5
+ @prettier/plugin-php@0.22.2
+ @shopify/prettier-plugin-liquid@1.4.1

Scripts added:
+ npm run format
+ npm run format:check
+ npm run format:staged

Next steps:
1. Run 'npm run format' to format all files
2. Review changes with 'git diff'
3. Consider enabling /dogma:lint stop hook (ENV: CLAUDE_MB_DOGMA_LINT_ON_STOP=true)
```

## Important Rules

1. **Security first** - ALWAYS check packages before installing
2. **Ask before creating** - Never create files without user confirmation
3. **Adapt to project** - Only include plugins for detected file types
4. **Preserve existing** - Merge with existing configs, don't overwrite blindly
5. **Explain choices** - User should understand why each setting is recommended

## Error Handling

- npm not installed: Suggest installing Node.js/nvm first
- Write permission denied: Report and suggest manual creation
- Package install fails: Show error, suggest alternatives
- Config parsing fails: Report which file and why
