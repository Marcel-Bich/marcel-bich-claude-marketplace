---
description: dogma - Check and install recommended plugins and MCP servers from a source
arguments:
  - name: source
    description: "Source URL or path containing RECOMMENDATIONS.md (optional, uses default from sync.md)"
    required: false
allowed-tools:
  - Bash
  - Read
  - AskUserQuestion
---

# Dogma: Recommended Setup

This command checks and installs recommended plugins and MCP servers from a source's `RECOMMENDATIONS.md` file.

## How It Works

This is a focused command that executes **only the recommendations step** from `/dogma:sync`.

**For the full implementation details, follow the instructions in:**
- **File:** `commands/sync.md`
- **Section:** Search for `Recommendations (check installation status, offer to install)`

## Quick Reference

### Step 1: Parse Source Argument

The user provided: `$ARGUMENTS`

**Source detection (same as sync.md "Parse Arguments" section):**
- Starts with `http://` or `https://` = Remote Git repo
- Starts with `~/`, `./`, `../`, `/` = Local path
- Empty = Use DEFAULT_SOURCE from sync.md

### Step 2: Fetch Source

**For the fetch logic, follow sync.md:**
- **Section:** Search for `Fetch Source to Temporary Directory`

### Step 3: Process Recommendations

**For the complete recommendations logic, follow sync.md:**
- **Section:** Search for `Recommendations (check installation status, offer to install)`

This includes:
- Parse RECOMMENDATIONS.md
- Check installation status
- Present missing recommendations
- Install if user agrees
- Handle MCP installations
- Skip already installed
- Summary

### Step 4: Cleanup

If a temp directory was created for remote repos, clean it up (same as sync.md "Cleanup" section).

## Key Points

- This command does NOT sync any files
- This command ONLY processes RECOMMENDATIONS.md
- User confirms each installation
- Restart Claude Code if MCP servers were installed
