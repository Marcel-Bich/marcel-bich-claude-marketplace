---
description: dogma - Add ignore patterns to multiple locations at once
arguments:
  - name: patterns
    description: "Pattern(s) to ignore (e.g., .aider* or '.aider* .continue* .codeium*')"
    required: false
allowed-tools:
  - Bash
  - Read
  - Write
  - Edit
  - Glob
  - AskUserQuestion
---

# Dogma: Ignore Pattern Manager

You are executing the `/dogma:ignore` command. Your task is to **add ignore patterns** to multiple locations at once (.git/info/exclude, .gitignore, and optionally sync.md).

## Step 1: Get Pattern(s) from User

The user provided: `$ARGUMENTS`

**If patterns provided:**
- Parse the input - patterns can be space-separated (e.g., `.aider* .continue* .codeium*`)
- Split into individual patterns
- Confirm understanding with user:
  ```
  I will add the following patterns:
  - .aider*
  - .continue*
  - .codeium*

  Is that correct? [Y/n]
  ```

**If no patterns provided:**
- Ask user: "Which pattern do you want to ignore? (e.g., .aider* or '.aider* .continue*' for multiple)"
- Wait for response
- Confirm understanding as above

## Step 2: Process Each Pattern

For each pattern, execute Steps 2.1 through 2.4 sequentially. Track results for the final summary.

Initialize tracking:
```
RESULTS=()  # Array to store results per pattern
```

### Step 2.1: .git/info/exclude (local, unversioned)

**Check if pattern already exists:**
```bash
grep -qxF "<pattern>" .git/info/exclude 2>/dev/null
```

**If pattern exists:**
```
Pattern "<pattern>" already exists in .git/info/exclude.
```
Add to results: `[OK] .git/info/exclude (already present)`

**If pattern does NOT exist:**
Ask user using AskUserQuestion:
```
Should I add "<pattern>" to .git/info/exclude?

.git/info/exclude is local and not versioned - ideal for personal ignore patterns.

[Y/n]
```

**If user confirms (Y or empty):**
```bash
echo "<pattern>" >> .git/info/exclude
```
Add to results: `[OK] .git/info/exclude`

**If user declines:**
Add to results: `[--] .git/info/exclude (skipped)`

### Step 2.2: .gitignore (versioned)

**Check if pattern already exists:**
```bash
grep -qxF "<pattern>" .gitignore 2>/dev/null
```

**If pattern exists:**
```
Pattern "<pattern>" already exists in .gitignore.
```
Add to results: `[OK] .gitignore (already present)`

**If pattern does NOT exist:**
Ask user using AskUserQuestion:
```
Should I add "<pattern>" to .gitignore?

.gitignore is versioned and applies to all team members.

[Y/n]
```

**If user confirms (Y or empty):**
```bash
echo "<pattern>" >> .gitignore
```
Add to results: `[OK] .gitignore`

**If user declines:**
Add to results: `[--] .gitignore (skipped)`

### Step 2.3: sync.md (SECRET - Marketplace Only)

**IMPORTANT:** This step is SECRET and should only be offered if we are in the marketplace repository.

**Detection chain (ALL must fail before skipping):**

```bash
# Script directory for token-safe git operations
SCRIPT_DIR="${CLAUDE_PLUGIN_ROOT:-$(dirname "$(dirname "$(realpath "$0")")")}/scripts"

# Check 1: Remote URL contains marketplace (token-safe)
"$SCRIPT_DIR/git-remote-safe.sh" url 2>/dev/null | grep -q "marcel-bich-claude-marketplace"
REMOTE_CHECK=$?

# Check 2: File exists
test -f plugins/dogma/sync.md
FILE_CHECK=$?

# Check 3: Current path contains marketplace
pwd | grep -q "marcel-bich-claude-marketplace"
PATH_CHECK=$?
```

**If ALL checks fail (REMOTE_CHECK != 0 AND FILE_CHECK != 0 AND PATH_CHECK != 0):**
- Skip this step silently
- Do NOT mention sync.md to the user at all
- Continue to Step 2.4

**If ANY check succeeds:**
Ask user using AskUserQuestion:
```
Should I also add "<pattern>" to the sync.md exclude list?

This prevents the pattern from being transferred during /dogma:sync.

[Y/n]
```

**If user confirms:**
- Read plugins/dogma/sync.md
- Find the exclude patterns section (look for patterns like `.git/` etc.)
- Add the new pattern
- Write the file back
Add to results: `[OK] sync.md`

**If user declines:**
Add to results: `[--] sync.md (skipped)`

### Step 2.4: Parallel Repos

Ask user using AskUserQuestion:
```
Should I search neighboring paths for more Git repos?

1. Yes, search in the parent directory (..)
2. Yes, specify a different path
3. No, only this repo

[1/2/3]
```

**If user chooses 1 (parent directory):**
```bash
# Find repos in parent directory (max depth 2)
find .. -maxdepth 2 -name ".git" -type d 2>/dev/null | grep -v "^\.\./.git$" | sed 's|/.git$||' | sort
```

**If user chooses 2 (custom path):**
Ask for path, then:
```bash
find <custom_path> -maxdepth 2 -name ".git" -type d 2>/dev/null | sed 's|/.git$||' | sort
```

**If user chooses 3:**
- Skip to Step 3 (Summary)

**For found repos, present list:**
```
Found repos:
1. ../web-selecta-7850
2. ../api-backend
3. ../mobile-app

Which do you want to process? (e.g., 1,2 or 'all' or 'none')
```

**For each selected repo:**
- Change to that directory
- Repeat Steps 2.1 and 2.2 only (NOT 2.3)
- Track results with repo path prefix

## Step 3: Summary

After processing all patterns and all locations, show a summary:

```
Done! Pattern <pattern> added to:

  [OK] .git/info/exclude
  [OK] .gitignore
  [--] sync.md (skipped)
  [OK] ../web-selecta-7850/.git/info/exclude
  [OK] ../web-selecta-7850/.gitignore
  [--] ../api-backend (skipped)
```

**If multiple patterns were processed:**
```
Done! All patterns processed:

Pattern .aider*:
  [OK] .git/info/exclude
  [OK] .gitignore

Pattern .continue*:
  [OK] .git/info/exclude
  [--] .gitignore (skipped)

Pattern .codeium*:
  [OK] .git/info/exclude (already present)
  [OK] .gitignore (already present)
```

## Important Rules

1. **Sequential flow** - Ask each location one by one, not all at once
2. **English language** - All user-facing text in English
3. **Default to yes** - Y or empty input means confirm
4. **Silent marketplace detection** - Never mention sync.md if not in marketplace repo
5. **Preserve existing content** - Always append, never overwrite
6. **No duplicates** - Check before adding to avoid duplicate entries

## Error Handling

- `.git/info/exclude` does not exist: Create directory and file if needed
- `.gitignore` does not exist: Create it
- Permission denied: Report error and continue with next location
- Invalid pattern: Warn user but allow if they confirm

## Example Session

```
User: /dogma:ignore .aider*

Claude: I will add the following pattern:
- .aider*

Is that correct? [Y/n]

User: y

Claude: Should I add ".aider*" to .git/info/exclude?
.git/info/exclude is local and not versioned.
[Y/n]

User: y

Claude: Pattern added to .git/info/exclude.

Should I add ".aider*" to .gitignore?
.gitignore is versioned and applies to all team members.
[Y/n]

User: n

Claude: Should I search neighboring paths for more Git repos?
1. Yes, search in the parent directory (..)
2. Yes, specify a different path
3. No, only this repo
[1/2/3]

User: 3

Claude: Done! Pattern .aider* added to:

  [OK] .git/info/exclude
  [--] .gitignore (skipped)
```
