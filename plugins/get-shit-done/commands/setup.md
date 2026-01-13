---
name: gsd:setup
description: Install GSD resources to ~/.claude/get-shit-done/ (required before using other GSD commands)
allowed-tools:
    - Bash
    - AskUserQuestion
---

<objective>

Install GSD by cloning the repo to /tmp and copying resources to the correct locations:

- Commands to ~/.claude/commands/gsd/
- Resources to ~/.claude/get-shit-done/

</objective>

<process>

<step name="check">

Check if GSD is already installed:

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

<step name="decide">

**If EXISTS:**

Use AskUserQuestion:

- header: "Update"
- question: "GSD is already installed. What would you like to do?"
- options:
    - "Update" - Replace with latest version
    - "Keep existing" - Do not modify

**If NOT_EXISTS:** Proceed to install step.

</step>

<step name="install">

**If NOT_EXISTS or "Update" selected:**

```bash
# Clone to temp
rm -rf /tmp/gsd-install
git clone --depth 1 https://github.com/glittercowboy/get-shit-done.git /tmp/gsd-install

# Create directories
mkdir -p ~/.claude/commands/gsd
mkdir -p ~/.claude/get-shit-done

# Copy commands (excluding _archive)
cp /tmp/gsd-install/commands/gsd/*.md ~/.claude/commands/gsd/

# Copy resources
cp -r /tmp/gsd-install/get-shit-done/* ~/.claude/get-shit-done/

# Cleanup
rm -rf /tmp/gsd-install

# Verify
echo "Installed:"
echo "- Commands: $(ls ~/.claude/commands/gsd/*.md | wc -l) files"
echo "- Resources: $(ls -d ~/.claude/get-shit-done/*/ | wc -l) directories"
```

</step>

<step name="done">

Present completion:

```
GSD Setup Complete

Commands installed to: ~/.claude/commands/gsd/
Resources installed to: ~/.claude/get-shit-done/

IMPORTANT: Restart Claude Code to load the new commands.

After restart, you can use all /gsd:* commands.

---

Start a new project: /gsd:new-project
Map existing codebase: /gsd:map-codebase
Get help: /gsd:help

Update anytime: /gsd:setup -> "Update"

---
```

</step>

</process>

<success_criteria>

- [ ] Commands exist at ~/.claude/commands/gsd/
- [ ] Resources exist at ~/.claude/get-shit-done/
- [ ] User informed of next steps

</success_criteria>
