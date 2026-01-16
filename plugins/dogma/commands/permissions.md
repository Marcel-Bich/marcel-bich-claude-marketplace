---
description: dogma - Create or update DOGMA-PERMISSIONS.md interactively
arguments: none
allowed-tools:
  - Read
  - Write
  - AskUserQuestion
  - Glob
---

# /dogma:permissions - Create Permissions File

Create or update DOGMA-PERMISSIONS.md to configure what Claude can do autonomously.

<instructions>
## Step 1: Check for existing permissions

1. Check if `DOGMA-PERMISSIONS.md` exists in project root
2. Check if `CLAUDE/CLAUDE.git.md` exists (fallback)
3. If either exists, show current permissions and ask if user wants to update

## Step 2: Interactive questions

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

## Step 3: Generate DOGMA-PERMISSIONS.md

Create the file with the user's choices:

```markdown
# Dogma Permissions

Configure what Claude is allowed to do autonomously.
Mark with `[x]` for auto, `[?]` for ask, `[ ]` for deny.

<permissions>
## Git Operations
- [x] May run `git add` autonomously
- [x] May run `git commit` autonomously
- [?] May run `git push` autonomously

## File Operations
- [?] May delete files autonomously (rm, unlink, git clean)
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

## Step 4: Confirm

Show the created file content and confirm with user.
</instructions>

<example>
User: /dogma:permissions

Claude: Let me check if you already have a permissions file...

No existing permissions found. I'll help you create DOGMA-PERMISSIONS.md.

[Uses AskUserQuestion with questions about each permission - 3 options each: auto/ask/deny]

Based on your choices, here's your permissions file:
[Shows content]

File created at DOGMA-PERMISSIONS.md. You can edit it anytime to change permissions.
</example>
