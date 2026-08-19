---
name: gsd:uninstall
description: Remove GSD resources from the active Claude config dir (${CLAUDE_CONFIG_DIR:-$HOME/.claude})
allowed-tools:
    - Bash
    - AskUserQuestion
---

<objective>

Remove GSD installation from the active Claude config dir (`${CLAUDE_CONFIG_DIR:-$HOME/.claude}`):

- Commands from `$GSD_BASE/commands/gsd/`
- Resources from `$GSD_BASE/get-shit-done/`

</objective>

<process>

<step name="check">

Check if GSD is installed:

```bash
GSD_BASE="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

if [ -d "$GSD_BASE/commands/gsd" ] || [ -d "$GSD_BASE/get-shit-done" ]; then
    echo "EXISTS"
    [ -d "$GSD_BASE/commands/gsd" ] && echo "commands: $(ls "$GSD_BASE"/commands/gsd/*.md 2>/dev/null | wc -l) files"
    [ -d "$GSD_BASE/get-shit-done" ] && echo "resources: present"
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
- question: "Remove GSD from the active Claude config dir (${CLAUDE_CONFIG_DIR:-$HOME/.claude})?"
- options:
    - "Yes, remove" - Delete commands and resources
    - "Cancel" - Keep the installation

</step>

<step name="remove">

**If "Yes, remove" selected:**

```bash
GSD_BASE="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

rm -rf "$GSD_BASE/commands/gsd"
rm -rf "$GSD_BASE/get-shit-done"
echo "Removed GSD installation"
```

</step>

<step name="done">

**If removed:**

```
GSD Uninstalled

Removed:
- $GSD_BASE/commands/gsd/
- $GSD_BASE/get-shit-done/
(GSD_BASE is the active Claude config dir: ${CLAUDE_CONFIG_DIR:-$HOME/.claude})

To reinstall: /gsd:setup
```

</step>

</process>

<success_criteria>

- [ ] $GSD_BASE/commands/gsd/ no longer exists
- [ ] $GSD_BASE/get-shit-done/ no longer exists
- [ ] User informed of reinstall option

</success_criteria>
