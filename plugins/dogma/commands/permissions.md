---
description: dogma - Create or update DOGMA-PERMISSIONS.md interactively (Git, File, and Workflow permissions)
arguments: none
allowed-tools:
  - Read
  - Write
  - Edit
  - AskUserQuestion
  - Glob
---

# /dogma:permissions - Create Permissions File

Create or update DOGMA-PERMISSIONS.md to configure what Claude can do autonomously.

<checkbox-legend>
| Symbol | Meaning |
|--------|---------|
| `[ ]` (blank) or `[0]` | Disabled |
| `[1]` | Only one (most relevant) |
| `[x]` | All relevant |
| `[a]` or `[A]` | ALL |
| `[?]` | On request |
</checkbox-legend>

<instructions>
## Step 1: Check for existing permissions

1. Check if `DOGMA-PERMISSIONS.md` exists in project root
2. If exists, show current permissions and ask if user wants to update
3. If not exists, will create new file

## Step 2: Git & File Permissions

Ask the user about each permission using AskUserQuestion. For each permission offer 3 choices:
- **auto** `[x]`: Claude does it automatically
- **ask** `[?]`: Claude asks for confirmation first
- **deny** `[ ]`: Claude cannot do it (blocked)

### Git Operations

**git add**
- auto: Claude can stage files for commits
- ask: Claude asks before staging
- deny: User must run `git add` manually

**git commit**
- auto: Claude can create commits autonomously
- ask: Claude asks before committing
- deny: User must create commits manually

**git push**
- auto: Claude can push to remote repositories
- ask: Claude asks before pushing (recommended)
- deny: User must push manually

### File Operations

**Delete files**
- auto: Claude can run rm, unlink, git clean
- ask: Claude prompts for confirmation before delete
- deny: Deletion commands are logged to TO-DELETE.md for manual deletion

## Step 3: Workflow Permissions

Ask about workflow automation settings.

### 3.1 Testing - When to run?

Ask: "When should tests be executed?"

Options (can select multiple):
- before commit (blank, 0, 1, x, a, ?)
- before push (blank, 0, 1, x, a, ?)
- on tasklist completion (blank, 0, 1, x, a, ?)

Default: `[x] before commit`, `[x] before push`, `[x] on tasklist completion`

### 3.2 Testing - What to test?

Ask: "What should be tested?"

Options:
- relevant tests (blank, 0, x)
- silent-failure check (blank, 0, x) - finds code that swallows errors (empty catch, ignored promises)

Default: `[x] relevant tests`, `[x] silent-failure check`

### 3.3 Review - When?

Ask: "When should code review happen?"

Options (can select multiple):
- after implementation (blank, 0, 1, x, a, ?)
- before commit (blank, 0, 1, x, a, ?)
- before push (blank, 0, 1, x, a, ?)

Default: `[x] after implementation`, `[x] before commit`, `[x] before push`

### 3.4 Review - What?

Ask: "What should be reviewed?"

Options:
- changed code (blank, 0, x)
- architecture (blank, 0, x)
- types (blank, 0, x)

Default: `[x] changed code`

### 3.5 Fallback

Ask: "What to do when no tests exist?"

Options:
- spawn subagent for verification (blank, 0, x)
- skip (blank, 0, x)

Default: `[x] spawn subagent for verification`

### 3.6 Hydra - Parallel Work

Ask: "How should parallel work be handled?"

Options:
- use Hydra for 2+ independent tasks (blank, 0, x) - only if Hydra available, otherwise sequential without asking

Default: `[x] use Hydra for 2+ independent tasks`

Note: If Hydra is not installed, work proceeds sequentially without asking.

### 3.7 TDD

Ask: "How should Test-Driven Development be handled?"

Options:
- TDD when tests exist (blank, 0, x)
- enforce TDD even without existing tests (blank, 0, x)

Default: `[x] TDD when tests exist`

### 3.8 Final Verification

Ask: "What to check after merge/review?"

Order: relevant tests -> build -> ALL tests (as final check before push)

Options:
- run relevant tests (blank, 0, x)
- check build (blank, 0, x)
- run ALL tests (blank, 0, x, a) - as final check before push

Default: `[x] run relevant tests`, `[x] check build`, `[a] run ALL tests`

## Step 4: Generate DOGMA-PERMISSIONS.md

Create the file with the user's choices:

```markdown
# Dogma Permissions

Configure what Claude is allowed to do autonomously.
Mark with `[x]` for auto, `[?]` for ask, `[ ]` for deny.

<permissions>
## Git Permissions
- [x] May run `git add` autonomously
- [x] May run `git commit` autonomously
- [?] May run `git push` autonomously

## File Operations
- [?] May delete files autonomously (rm, unlink, git clean)

## Workflow Permissions

Checkbox legend: `[ ]`/`[0]` = disabled, `[1]` = only one, `[x]` = all relevant, `[a]` = ALL, `[?]` = on request

### Testing

When to run tests?
- [x] before commit
- [x] before push
- [x] on tasklist completion

What to test?
- [x] relevant tests
- [x] silent-failure check

### Review

When to review?
- [x] after implementation
- [x] before commit
- [x] before push

What to review?
- [x] changed code
- [ ] architecture
- [ ] types

### Fallback

When no tests exist:
- [x] spawn subagent for verification
- [ ] skip

### Hydra

Parallel work (only if Hydra available, otherwise sequential):
- [x] use Hydra for 2+ independent tasks

### TDD

Test-Driven Development:
- [x] TDD when tests exist
- [ ] enforce TDD even without existing tests

### Final Verification

After merge/review (order: relevant tests -> build -> ALL tests):
- [x] run relevant tests
- [x] check build
- [a] run ALL tests
</permissions>

## Behavior

| Permission | [x] auto | [?] ask | [ ] deny |
|------------|----------|---------|----------|
| git add | Stages files | Asks first | Blocked |
| git commit | Creates commits | Asks first | Blocked |
| git push | Pushes to remote | Asks first | Blocked |
| delete files | Deletes files | Asks first | Logged to TO-DELETE.md |
```

Replace markers based on user choices.

## Step 5: Confirm

Show the created file content and confirm with user.
</instructions>

<example>
User: /dogma:permissions

Claude: Checking if DOGMA-PERMISSIONS.md exists...

No existing permissions file found. I'll help you create DOGMA-PERMISSIONS.md.

**Git & File Permissions:**
[Uses AskUserQuestion for git add, commit, push, delete - 3 options each: auto/ask/deny]

**Workflow Permissions:**
[Uses AskUserQuestion for each workflow category]

Based on your answers:
[Shows content]

File created: DOGMA-PERMISSIONS.md. You can edit it anytime to adjust permissions.
</example>
