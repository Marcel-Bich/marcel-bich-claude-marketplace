---
name: gsd:uninstall
description: Remove GSD resources from ~/.claude/get-shit-done/
allowed-tools:
    - Bash
    - AskUserQuestion
---

<objective>

Remove the GSD workflow resources from ~/.claude/get-shit-done/.

</objective>

<process>

<step name="check">

Check if resources exist:

```bash
if [ -d ~/.claude/get-shit-done ]; then
    echo "EXISTS"
    du -sh ~/.claude/get-shit-done
else
    echo "NOT_EXISTS"
fi
```

</step>

<step name="confirm">

**If NOT_EXISTS:**

```
GSD is not installed at ~/.claude/get-shit-done/
Nothing to uninstall.
```

Exit.

**If EXISTS:**

Use AskUserQuestion:

- header: "Uninstall"
- question: "Remove GSD resources from ~/.claude/get-shit-done/?"
- options:
    - "Yes, remove" - Delete the directory
    - "Cancel" - Keep the installation

</step>

<step name="remove">

**If "Yes, remove" selected:**

```bash
rm -rf ~/.claude/get-shit-done
echo "Removed ~/.claude/get-shit-done/"
```

</step>

<step name="done">

**If removed:**

```
GSD Uninstalled

Resources removed from: ~/.claude/get-shit-done/

To reinstall: /gsd:setup
```

</step>

</process>

<success_criteria>

- [ ] Directory ~/.claude/get-shit-done/ no longer exists
- [ ] User informed of reinstall option

</success_criteria>
