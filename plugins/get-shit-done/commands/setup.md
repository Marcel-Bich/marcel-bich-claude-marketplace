---
name: gsd:setup
description: Install GSD resources to ~/.claude/get-shit-done/ (required before using other GSD commands)
allowed-tools:
    - Bash
    - AskUserQuestion
---

<objective>

Clone the GSD workflow resources (templates, workflows, references) to ~/.claude/get-shit-done/.

This is required because the GSD commands reference resources at ~/.claude/get-shit-done/. Run this once after installing the plugin.

</objective>

<process>

<step name="check">

Check if resources already exist:

```bash
if [ -d ~/.claude/get-shit-done ]; then
    echo "EXISTS"
    if [ -d ~/.claude/get-shit-done/.git ]; then
        echo "IS_GIT_REPO"
        git -C ~/.claude/get-shit-done remote -v
    else
        echo "NOT_GIT_REPO"
    fi
else
    echo "NOT_EXISTS"
fi
```

</step>

<step name="decide">

**If EXISTS and IS_GIT_REPO:**

Use AskUserQuestion:

- header: "Update"
- question: "GSD resources already exist at ~/.claude/get-shit-done/. What would you like to do?"
- options:
    - "Update (git pull)" - Pull latest changes from upstream
    - "Keep existing" - Do not modify existing installation
    - "Fresh install" - Remove and re-clone

**If EXISTS and NOT_GIT_REPO:**

Use AskUserQuestion:

- header: "Upgrade"
- question: "GSD resources exist but are not a git repo (old installation). What would you like to do?"
- options:
    - "Backup and fresh install" - Backup old, then clone fresh
    - "Keep existing" - Do not modify existing installation

**If NOT_EXISTS:** Proceed to install step.

</step>

<step name="backup">

**If "Backup and fresh install" selected:**

```bash
BACKUP_DIR=~/.claude/get-shit-done.backup.$(date +%Y%m%d_%H%M%S)
mv ~/.claude/get-shit-done "$BACKUP_DIR"
echo "Backed up to: $BACKUP_DIR"
```

</step>

<step name="update">

**If "Update (git pull)" selected:**

```bash
git -C ~/.claude/get-shit-done pull
echo "Updated GSD resources"
```

</step>

<step name="fresh_install">

**If "Fresh install" selected:**

```bash
rm -rf ~/.claude/get-shit-done
```

Then proceed to install step.

</step>

<step name="install">

**If NOT_EXISTS, "Backup and fresh install", or "Fresh install":**

```bash
mkdir -p ~/.claude
git clone https://github.com/glittercowboy/get-shit-done.git ~/.claude/get-shit-done
echo "Cloned GSD resources to ~/.claude/get-shit-done/"
ls -la ~/.claude/get-shit-done/
```

</step>

<step name="done">

Present completion:

```
GSD Setup Complete

Resources cloned to: ~/.claude/get-shit-done/
- templates/    (project templates)
- workflows/    (execution workflows)
- references/   (principles and formats)

Update anytime with: /gsd:setup -> "Update (git pull)"

You can now use all /gsd:* commands.

---

## Next Up

Start a new project:

`/gsd:new-project`

Or get help:

`/gsd:help`

---
```

</step>

</process>

<success_criteria>

- [ ] Resources exist at ~/.claude/get-shit-done/
- [ ] Directory is a git repo (can be updated)
- [ ] templates/, workflows/, references/ directories present
- [ ] User informed of next steps

</success_criteria>
