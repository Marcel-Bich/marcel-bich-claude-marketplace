---
description: "dogma - Sanitize git history from Claude/AI traces and fix tracking issues"
arguments:
  - name: scope
    description: "Scope to check: 'all' (default), 'commits', 'files', 'tracked'"
    required: false
allowed-tools:
  - Bash
  - Read
  - Glob
  - Grep
  - AskUserQuestion
---

# Claude-Dogma: Sanitize Git History

You are executing the `/dogma:sanitize-git` command. Your task is to **find and remove AI/Claude traces from git history** and fix tracking issues where files that should be excluded are still being tracked.

**CRITICAL: This command modifies git history. Always create a backup first and warn the user about force-push implications.**

## Overview

This command performs these checks:
1. **Commit Messages**: Claude/Anthropic mentions, "Generated with Claude", etc.
2. **Co-Author Tags**: Claude/Anthropic co-author entries in commits
3. **Tracked Exclusions**: Files in `.git/info/exclude` that are still tracked
4. **Ignored but Tracked**: Files matching `.gitignore` patterns but still tracked
5. **Forbidden Content**: Files containing text patterns forbidden by CLAUDE.git.md

---

## Phase 0: Mandatory Risk Acknowledgment

**THIS STEP IS MANDATORY AND CANNOT BE SKIPPED.**

Before doing ANYTHING else, display this warning and require explicit confirmation:

```
================================================================================
                         CRITICAL WARNING - READ CAREFULLY
================================================================================

This command can PERMANENTLY and IRREVERSIBLY damage your git repository.

RISKS INCLUDE:
- Complete loss of git history
- Corrupted repository state requiring re-clone
- Force-push overwrites remote history for ALL collaborators
- Detached commits that cannot be recovered
- Broken references and tags
- Loss of merge history and branch relationships

WHAT THIS COMMAND DOES:
- Rewrites git commits using filter-branch or similar tools
- Removes files from history across ALL commits
- Modifies commit messages and author information
- Requires force-push to synchronize with remote

PREREQUISITES:
- Ensure all collaborators are informed before force-pushing
- Verify you have push permissions to the remote
- Confirm no critical work depends on current commit hashes

A backup will be created in /tmp/, but this is NOT a guarantee against data loss.
Git history rewriting is inherently dangerous and error-prone.

USE AT YOUR OWN RISK. THE AUTHOR TAKES NO RESPONSIBILITY FOR DATA LOSS.

================================================================================
```

Ask the user:

```
To proceed, you must acknowledge the risks.

Type 'I UNDERSTAND THE RISKS' to continue, or anything else to abort:
```

**Implementation:**
- Use AskUserQuestion with a text input option
- The user MUST type exactly "I UNDERSTAND THE RISKS" (case-insensitive)
- Any other input = abort immediately with message "Aborted. No changes made."
- Do NOT proceed to Phase 1 without this confirmation

```
Options:
1. Cancel (Recommended) - Abort without making any changes
2. I UNDERSTAND THE RISKS - Proceed with sanitization (DANGEROUS)
```

**DEFAULT IS CANCEL.** Only users who know exactly what they are doing should proceed.

If user selects Cancel, option 1, or provides any other response:
```
Aborted. No changes were made to your repository.
```

**Only after explicit confirmation, proceed to Phase 1.**

---

## Phase 1: Load Rules and Analyze Repository

### Step 1.1: Check for CLAUDE.git.md Rules

Look for forbidden patterns in these locations (in order):
1. `CLAUDE.git.md`
2. `CLAUDE/CLAUDE.git.md`
3. `.claude/CLAUDE.git.md`

Extract:
- **Verbotene Texte / Forbidden Texts** section
- Any patterns like "Co-Authored-By: Claude", "Generated with Claude", etc.
- Author restrictions (e.g., "niemals als Autor eintragen")

If found, report:
```
Found CLAUDE.git.md rules:
- Forbidden texts: [list]
- Author restrictions: [list]
```

### Step 1.2: Default Forbidden Patterns

Always check for these patterns regardless of CLAUDE.git.md:

**In Commits:**
- `Co-Authored-By: Claude` (any variation)
- `Co-Authored-By:.*Anthropic`
- `Co-Authored-By:.*noreply@anthropic.com`
- `Generated with Claude`
- `Generated with \[Claude`
- `Claude Code`
- Commit messages containing just "Claude" or "Anthropic" as author indicators

**In Files:**
- `Generated with [Claude Code]`
- `Co-Authored-By: Claude`
- Author lines mentioning Claude/Anthropic

### Step 1.3: Analyze Git State

Run these checks:

```bash
# Script directory for token-safe helpers
SCRIPT_DIR="${CLAUDE_PLUGIN_ROOT:-$(dirname "$(dirname "$(realpath "$0")")")}/scripts"

# Check if we're in a git repository
git rev-parse --git-dir 2>/dev/null

# Check if there are uncommitted changes (warn user)
git status --porcelain

# Check if there's a remote (token-safe)
"$SCRIPT_DIR/git-remote-safe.sh" url

# Get current branch
git branch --show-current

# Count total commits
git rev-list --count HEAD
```

If uncommitted changes exist:
```
WARNING: You have uncommitted changes.
Please commit or stash them before running sanitize.
Proceeding may cause data loss.

Continue anyway?
1. Yes, I understand the risk
2. No, let me commit first
```

---

## Phase 2: Create Backup

**MANDATORY: Always create backup before any history modifications.**

### Step 2.1: Create Backup Directory

```bash
BACKUP_DIR="/tmp/dogma-sanitize-backup-$(date +%Y%m%d-%H%M%S)"
REPO_NAME=$(basename "$(git rev-parse --show-toplevel)")
```

### Step 2.2: Full Repository Backup

```bash
# Copy entire repository including .git
cp -r "$(git rev-parse --show-toplevel)" "$BACKUP_DIR/$REPO_NAME"
```

### Step 2.3: Report Backup Location

```
Backup created at: /tmp/dogma-sanitize-backup-YYYYMMDD-HHMMSS/[repo-name]

This backup contains:
- All local files (including untracked)
- Complete git history
- All branches and tags

If something goes wrong, you can restore from this backup.
```

---

## Phase 3: Scan for Issues

### Step 3.1: Scan Commit Messages and Authors

```bash
# Find commits with Claude/Anthropic in message or author
git log --all --format="%H|%an|%ae|%s" | grep -iE "(claude|anthropic)" || true

# Find commits with Co-Authored-By tags
git log --all --format="%H|%b" | grep -iE "Co-Authored-By:.*(claude|anthropic)" || true
```

For each matching commit, record:
- Commit hash (full and short)
- Author name and email
- Commit message (first line)
- Full body if contains Co-Authored-By

### Step 3.2: Scan .git/info/exclude

```bash
# Read exclusion patterns
if [ -f ".git/info/exclude" ]; then
    cat .git/info/exclude
fi
```

For each pattern in exclude:
```bash
# Check if any matching files are tracked
git ls-files | grep -E "pattern" || true
```

### Step 3.3: Scan .gitignore Violations

```bash
# Find tracked files that match gitignore patterns
git ls-files -i --exclude-standard
```

### Step 3.4: Scan Files for Forbidden Content

Search all tracked files for forbidden patterns:

```bash
# Search for Claude traces in tracked files
git grep -l "Generated with \[Claude" || true
git grep -l "Co-Authored-By: Claude" || true
git grep -l "noreply@anthropic.com" || true
```

Also check patterns from CLAUDE.git.md "Verbotene Texte" section.

---

## Phase 4: Present Findings

### Step 4.1: Summary Report

```
Git Repository Sanitization Report
==================================

Repository: [name]
Branch: [current branch]
Remote: [remote URL or "none"]
Total Commits: [count]

Issues Found:
-------------

COMMITS WITH AI TRACES:
  [count] commits with Claude/Anthropic references

TRACKING ISSUES:
  [count] files in .git/info/exclude but still tracked
  [count] files matching .gitignore but still tracked

FILE CONTENT ISSUES:
  [count] files containing forbidden text patterns

Backup Location: /tmp/dogma-sanitize-backup-YYYYMMDD-HHMMSS/
```

### Step 4.2: Detailed Listing

For each category, show details:

**Commits:**
```
COMMIT ISSUES (3 found):
------------------------

1. abc1234 - "Add feature X"
   Author: John Doe <john@example.com>
   Issue: Contains "Co-Authored-By: Claude <noreply@anthropic.com>"

2. def5678 - "Fix bug in Y"
   Author: John Doe <john@example.com>
   Issue: Message contains "Generated with Claude Code"

3. ghi9012 - "Update docs"
   Author: Claude <noreply@anthropic.com>
   Issue: Claude is listed as commit author
```

**Tracked Exclusions:**
```
TRACKED FILES THAT SHOULD BE EXCLUDED (2 found):
------------------------------------------------

1. CLAUDE.md (matches .git/info/exclude pattern)
2. whats-next.md (matches .git/info/exclude pattern)
```

**Forbidden Content:**
```
FILES WITH FORBIDDEN CONTENT (1 found):
---------------------------------------

1. README.md:45
   Content: "Generated with [Claude Code](https://claude.com/claude-code)"
```

---

## Phase 5: Interactive Remediation

### Step 5.1: Ask How to Proceed

```
How would you like to proceed?

1. Review each issue individually (recommended)
2. Show me the git commands I would need to run manually
3. Skip to specific category (commits/files/tracking)
4. Cancel (no changes made)
```

### Step 5.2: Handle Commit Issues

For EACH commit with issues, ask:

```
COMMIT: abc1234
Message: "Add feature X"
Issue: Contains Co-Authored-By: Claude <noreply@anthropic.com>

What should I do?

1. Remove AI traces from this commit (rewrite history)
   -> Removes Co-Authored-By line, keeps commit otherwise intact
   -> Requires force push to remote

2. Delete this commit entirely (rewrite history)
   -> Removes commit from history
   -> Requires force push to remote

3. Skip this commit (leave as-is)

4. Show full commit details first
```

**For option 1 (Remove traces):**
```bash
# Use git filter-branch or git-filter-repo to rewrite
# Remove Co-Authored-By lines
# Remove "Generated with Claude" from messages
```

**For option 2 (Delete commit):**
```bash
# Interactive rebase to drop the commit
# Or filter-branch to remove entirely
```

### Step 5.3: Handle Tracking Issues

For EACH file that should not be tracked:

```
FILE: CLAUDE.md
Status: Tracked but listed in .git/info/exclude
Location: /path/to/repo/CLAUDE.md

What should I do?

1. Remove from git only (keep local file)
   -> git rm --cached CLAUDE.md
   -> File stays on your disk but is untracked
   -> Remote will lose this file after push

2. Remove from git AND delete locally
   -> git rm CLAUDE.md
   -> File is deleted from disk and repository

3. Remove from history entirely (rewrite history)
   -> File removed from ALL commits
   -> Requires force push
   -> Local file restored from backup after push

4. Skip (leave tracked)

5. Edit .git/info/exclude instead (remove from exclusion list)
```

**For option 3 (Remove from history):**
After force push, automatically restore from backup:
```bash
# After git push --force-with-lease
cp "$BACKUP_DIR/$REPO_NAME/CLAUDE.md" ./CLAUDE.md
```

### Step 5.4: Handle Forbidden Content

For EACH file with forbidden content:

```
FILE: README.md
Line 45: Generated with [Claude Code](https://claude.com/claude-code)

What should I do?

1. Remove this line from the file
   -> Edits the file, you can commit later

2. Remove from file AND all git history
   -> Rewrites history to never contain this text
   -> Requires force push

3. Skip (leave as-is)

4. Show surrounding context
```

---

## Phase 6: Execute Changes

### Step 6.1: Confirm Before Execution

Before making ANY changes that modify history:

```
SUMMARY OF PLANNED CHANGES:
===========================

COMMITS TO REWRITE: [count]
- abc1234: Remove Co-Authored-By tag
- def5678: Remove "Generated with Claude" from message

FILES TO UNTRACK: [count]
- CLAUDE.md (keep local)
- whats-next.md (keep local)

HISTORY REWRITES NEEDED: [yes/no]
- This will require: git push --force-with-lease

IMPORTANT:
- Anyone who has cloned this repo will need to re-clone
- Force pushing rewrites remote history permanently
- Your backup is at: /tmp/dogma-sanitize-backup-YYYYMMDD-HHMMSS/

Type 'SANITIZE' to proceed, or anything else to cancel:
```

### Step 6.2: Execute Git Commands

**For removing Co-Authored-By from commits:**
```bash
# Using git filter-branch (older method but reliable)
git filter-branch --msg-filter '
    sed "/Co-Authored-By:.*[Cc]laude/d" |
    sed "/Co-Authored-By:.*[Aa]nthropic/d" |
    sed "/Co-Authored-By:.*noreply@anthropic.com/d"
' --force -- --all

# Or using git-filter-repo (faster, if installed)
# git filter-repo --message-callback '...'
```

**For untracking files:**
```bash
git rm --cached <file>
```

**For removing files from history:**
```bash
git filter-branch --force --index-filter \
    'git rm --cached --ignore-unmatch <file>' \
    --prune-empty -- --all
```

### Step 6.3: Restore Local Files from Backup

After any history rewrite that removes files:

```bash
# List files that need restoration
# Copy from backup
cp "$BACKUP_DIR/$REPO_NAME/<file>" ./<file>
```

Report:
```
Restored from backup:
- CLAUDE.md
- whats-next.md
```

---

## Phase 7: Push Changes

### Step 7.1: Ask About Pushing

```
Changes have been made locally. The remote still has the old history.

Would you like to push now?

1. Yes, push with --force-with-lease (safer force push)
2. Yes, push with --force (if --force-with-lease fails)
3. No, I'll push manually later
4. Show me the commands to run
```

### Step 7.2: Execute Push

```bash
# Try safer force push first
git push --force-with-lease origin <branch>

# If that fails and user confirms:
git push --force origin <branch>
```

### Step 7.3: Cleanup

After successful push:

```
Do you want to keep the backup at /tmp/dogma-sanitize-backup-YYYYMMDD-HHMMSS/?

1. Yes, keep backup (recommended for a few days)
2. No, delete backup now
```

---

## Phase 8: Final Report

```
Sanitization Complete
=====================

COMMITS MODIFIED: [count]
- abc1234: Removed Co-Authored-By tag
- def5678: Removed "Generated with Claude" from message

FILES UNTRACKED: [count]
- CLAUDE.md (kept locally)
- whats-next.md (kept locally)

FILES RESTORED FROM BACKUP: [count]
- CLAUDE.md
- whats-next.md

REMOTE STATUS:
- Pushed with --force-with-lease to origin/main
- Old history is now replaced

BACKUP:
- Located at: /tmp/dogma-sanitize-backup-YYYYMMDD-HHMMSS/
- Keep for a few days in case you need to restore anything

NEXT STEPS:
- Inform collaborators to re-clone if they had the old history
- Verify the remote looks correct: git log --oneline -20
```

---

## Error Handling

### No Issues Found
```
No AI traces or tracking issues found in this repository.
Your git history is clean.
```

### Not a Git Repository
```
Error: Not a git repository.
Please run this command from within a git repository.
```

### Backup Failed
```
Error: Could not create backup at /tmp/
Please ensure you have write permissions to /tmp/ and enough disk space.
Cannot proceed without backup.
```

### Force Push Failed
```
Error: Force push failed.

This could mean:
1. Remote has branch protection rules
2. You don't have push permissions
3. Network issue

The changes are still local. You can:
1. Check remote permissions and try again
2. Push to a different branch
3. Restore from backup: cp -r /tmp/dogma-sanitize-backup-*/* ./
```

### Filter-branch Warnings
```
Note: git filter-branch has been run. You may see warnings about refs/original.

To clean up after verifying everything is correct:
git update-ref -d refs/original/refs/heads/<branch>
```

---

## Important Safety Rules

1. **ALWAYS create backup first** - Never skip this step
2. **ALWAYS confirm before force push** - History rewrites are permanent on remote
3. **ALWAYS restore local files** - If user wanted to keep files locally
4. **Never auto-execute** - Every destructive action needs explicit confirmation
5. **Explain implications** - User must understand force push affects collaborators
6. **Keep backup until confirmed** - Recommend keeping backup for several days
7. **Handle partial failures** - If something fails mid-process, report clearly

---

## Scope Argument

The user provided: `$ARGUMENTS`

- `all` or empty: Run all checks
- `commits`: Only check commit messages and authors
- `files`: Only check file content for forbidden patterns
- `tracked`: Only check tracking issues (.git/info/exclude, .gitignore)

Adjust the scan phases accordingly.
