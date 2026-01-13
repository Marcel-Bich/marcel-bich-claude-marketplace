---
name: gsd:setup
description: Install GSD resources to ~/.claude/get-shit-done/ (required before using other GSD commands)
allowed-tools:
  - Bash
  - AskUserQuestion
---

<objective>

Install the GSD workflow resources (templates, workflows, references) to ~/.claude/get-shit-done/.

This is required because the GSD commands reference resources at ~/.claude/get-shit-done/. Run this once after installing the plugin.

</objective>

<process>

<step name="check">

Check if resources already exist:

```bash
if [ -d ~/.claude/get-shit-done ]; then
    echo "EXISTS"
    ls -la ~/.claude/get-shit-done/
else
    echo "NOT_EXISTS"
fi
```

</step>

<step name="decide">

**If EXISTS:**

Use AskUserQuestion:
- header: "Update"
- question: "GSD resources already exist at ~/.claude/get-shit-done/. What would you like to do?"
- options:
  - "Update" - Replace with current version from plugin
  - "Keep existing" - Do not modify existing installation
  - "Backup and update" - Backup existing to ~/.claude/get-shit-done.backup/ then update

**If NOT_EXISTS:** Proceed to install step.

</step>

<step name="backup">

**If "Backup and update" selected:**

```bash
BACKUP_DIR=~/.claude/get-shit-done.backup.$(date +%Y%m%d_%H%M%S)
mv ~/.claude/get-shit-done "$BACKUP_DIR"
echo "Backed up to: $BACKUP_DIR"
```

</step>

<step name="install">

**If "Update", "Backup and update", or NOT_EXISTS:**

```bash
mkdir -p ~/.claude
cp -r "${CLAUDE_PLUGIN_ROOT}/get-shit-done" ~/.claude/
echo "Installed GSD resources to ~/.claude/get-shit-done/"
ls -la ~/.claude/get-shit-done/
```

</step>

<step name="done">

Present completion:

```
GSD Setup Complete

Resources installed to: ~/.claude/get-shit-done/
- templates/    (project templates)
- workflows/    (execution workflows)
- references/   (principles and formats)

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
- [ ] templates/, workflows/, references/ directories present
- [ ] User informed of next steps

</success_criteria>
