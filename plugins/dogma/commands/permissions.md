---
description: Create or update DOGMA-PERMISSIONS.md interactively
arguments: none
allowed-tools:
  - Read
  - Write
  - AskUserQuestion
  - Glob
---

# /dogma:setup - Create Permissions File

Create or update DOGMA-PERMISSIONS.md to configure what Claude can do autonomously.

<instructions>
## Step 1: Check for existing permissions

1. Check if `DOGMA-PERMISSIONS.md` exists in project root
2. Check if `CLAUDE/CLAUDE.git.md` exists (fallback)
3. If either exists, show current permissions and ask if user wants to update

## Step 2: Interactive questions

Ask the user about each permission using AskUserQuestion. For each permission:
- Explain what it does
- Show what happens when blocked
- Get their choice

### Git Operations

**git add**
- Allowed: Claude can stage files for commits
- Blocked: User must run `git add` manually

**git commit**
- Allowed: Claude can create commits autonomously
- Blocked: User must create commits manually

**git push**
- Allowed: Claude can push to remote repositories
- Blocked: User must push manually (recommended for safety)

### File Operations

**Delete files autonomously**
- Allowed: Claude can run rm, unlink, git clean
- Blocked: Deletion commands are logged to TO-DELETE.md for manual deletion

**Ask before deleting**
- Only relevant if delete is blocked
- Enabled: Claude prompts for confirmation before delete
- Disabled: Delete is silently logged to TO-DELETE.md

## Step 3: Generate DOGMA-PERMISSIONS.md

Create the file with the user's choices:

```markdown
# Dogma Permissions

Configure what Claude is allowed to do autonomously.
Mark with `[x]` to allow, `[ ]` to block.

<permissions>
## Git Operations
- [X] May run `git add` autonomously
- [X] May run `git commit` autonomously
- [ ] May run `git push` autonomously

## File Operations
- [ ] May delete files autonomously (rm, unlink, git clean)
- [ ] Ask before deleting (instead of logging to TO-DELETE.md)
</permissions>

## Behavior When Blocked

| Permission | If [ ] (blocked) |
|------------|------------------|
| git add | Claude cannot stage files |
| git commit | Claude cannot create commits |
| git push | Claude cannot push to remote |
| delete files | Logged to TO-DELETE.md, delete manually |
| ask before deleting | Shows confirmation prompt before delete |
```

Replace [X] and [ ] based on user choices.

## Step 4: Confirm

Show the created file content and confirm with user.
</instructions>

<example>
User: /dogma:setup

Claude: Let me check if you already have a permissions file...

No existing permissions found. I'll help you create DOGMA-PERMISSIONS.md.

[Uses AskUserQuestion with questions about each permission]

Based on your choices, here's your permissions file:
[Shows content]

File created at DOGMA-PERMISSIONS.md. You can edit it anytime to change permissions.
</example>
