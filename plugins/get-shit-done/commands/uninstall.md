---
name: gsd:uninstall
description: Remove GSD resources from ~/.claude/
allowed-tools:
    - Bash
    - AskUserQuestion
---

<objective>

Remove GSD installation:

- Commands from ~/.claude/commands/gsd/
- Resources from ~/.claude/get-shit-done/

</objective>

<process>

<step name="check">

Check if GSD is installed:

```bash
if [ -d ~/.claude/commands/gsd ] || [ -d ~/.claude/get-shit-done ]; then
    echo "EXISTS"
    [ -d ~/.claude/commands/gsd ] && echo "commands: $(ls ~/.claude/commands/gsd/*.md 2>/dev/null | wc -l) files"
    [ -d ~/.claude/get-shit-done ] && echo "resources: present"
else
    echo "NOT_EXISTS"
fi
```

</step>

<step name="confirm">

**If NOT_EXISTS:**

```
GSD is not installed.
Nothing to uninstall.
```

Exit.

**If EXISTS:**

Use AskUserQuestion:

- header: "Uninstall"
- question: "Remove GSD from ~/.claude/?"
- options:
    - "Yes, remove" - Delete commands and resources
    - "Cancel" - Keep the installation

</step>

<step name="remove">

**If "Yes, remove" selected:**

```bash
rm -rf ~/.claude/commands/gsd
rm -rf ~/.claude/get-shit-done
echo "Removed GSD installation"
```

</step>

<step name="done">

**If removed:**

```
GSD Uninstalled

Removed:
- ~/.claude/commands/gsd/
- ~/.claude/get-shit-done/

To reinstall: /gsd:setup
```

</step>

</process>

<success_criteria>

- [ ] ~/.claude/commands/gsd/ no longer exists
- [ ] ~/.claude/get-shit-done/ no longer exists
- [ ] User informed of reinstall option

</success_criteria>
