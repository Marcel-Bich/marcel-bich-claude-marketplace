---
name: gsd:setup
description: Install GSD resources into the active Claude config dir (${CLAUDE_CONFIG_DIR:-$HOME/.claude}/get-shit-done/) (required before using other GSD commands)
allowed-tools:
    - Bash
    - AskUserQuestion
---

<objective>

Install GSD by cloning the repo to /tmp and copying resources to the correct locations under the active Claude config dir (`${CLAUDE_CONFIG_DIR:-$HOME/.claude}`):

- Commands to `$GSD_BASE/commands/gsd/`
- Resources to `$GSD_BASE/get-shit-done/`

</objective>

<process>

<step name="check">

Check if GSD is already installed:

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
GSD_BASE="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

# Clone to temp (own secured, frozen fork - markdown skills only)
rm -rf /tmp/gsd-install
git clone --depth 1 https://github.com/Marcel-Bich/get-shit-done.git /tmp/gsd-install

# Create directories
mkdir -p "$GSD_BASE/commands/gsd"
mkdir -p "$GSD_BASE/get-shit-done"

# Copy commands (excluding _archive)
cp /tmp/gsd-install/commands/gsd/*.md "$GSD_BASE/commands/gsd/"

# Copy resources
cp -r /tmp/gsd-install/get-shit-done/* "$GSD_BASE/get-shit-done/"

# Cleanup
rm -rf /tmp/gsd-install

# Verify
echo "Installed:"
echo "- Commands: $(ls "$GSD_BASE"/commands/gsd/*.md | wc -l) files"
echo "- Resources: $(ls -d "$GSD_BASE"/get-shit-done/*/ | wc -l) directories"
```

</step>

<step name="done">

Present completion:

```
GSD Setup Complete

Commands installed to: $GSD_BASE/commands/gsd/
Resources installed to: $GSD_BASE/get-shit-done/
(GSD_BASE is the active Claude config dir: ${CLAUDE_CONFIG_DIR:-$HOME/.claude})

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

- [ ] Commands exist at $GSD_BASE/commands/gsd/
- [ ] Resources exist at $GSD_BASE/get-shit-done/
- [ ] User informed of next steps

</success_criteria>
