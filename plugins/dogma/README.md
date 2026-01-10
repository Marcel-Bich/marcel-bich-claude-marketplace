# Claude-Dogma

Intelligent sync of Claude instructions (CLAUDE.md, .claude/) from a central source to any project - with interactive review and merge.

## Problem

- Claude instructions (CLAUDE.md, .claude/) need to be consistent across many projects
- These files should NOT be version controlled (they reveal AI agent usage)
- Manual copying is error-prone and time-consuming
- Blindly overwriting loses project-specific customizations

## Solution

An intelligent slash command that:

1. Fetches Claude instructions from a source (Git repo or local path)
2. Compares each file with your current project
3. **Asks you interactively** what to do with each difference
4. Merges intelligently - no blind overwrites

```
/claude-dogma                              # Sync from default source
/claude-dogma https://github.com/user/repo # Sync from GitHub repo
/claude-dogma ./my-standards               # Sync from local path
```

## How It Works

### Interactive Review Process

For each file in the source:

**If file doesn't exist in your project:**
- Shows preview of the file
- Asks: Add it? Skip it? Show full content?

**If file exists but differs:**
- Shows both versions
- Explains the differences in plain language
- Asks: Keep current? Replace? Merge manually?

**If file is identical:**
- Reports "no changes needed" and continues

### Example Session

```
/claude-dogma ./my-standards

Fetching source from ./my-standards...
Found 2 files to review: CLAUDE.md, CLAUDE.git.md

---
File: CLAUDE.md
Exists in both. Source adds 1 new rule.
-> Keep / Replace / Merge? > Merge
Done.

---
File: CLAUDE.git.md
Missing in your project.
-> Add? > Yes
Done.

---
Sync complete. Files are untracked.
```

## Usage

### From GitHub Repo

```
/claude-dogma https://github.com/your-org/claude-standards
```

### From Local Path

```
/claude-dogma ./my-standards           # Relative path
/claude-dogma ../shared/claude-config  # Parent directory
/claude-dogma ~/dotfiles/claude        # Home directory
/claude-dogma /absolute/path/to/source # Absolute path
```

## What Gets Synced

The following files are reviewed:

- `CLAUDE.md` - Main Claude instructions
- `CLAUDE.*.md` - Additional instruction files (e.g., CLAUDE.git.md)
- `.claude/` - Claude configuration directory (commands, settings, etc.)

## Important: Files Stay Untracked

This plugin intentionally does NOT:

- Run `git add` on any files
- Modify `.gitignore`
- Commit any changes
- Overwrite without asking

Files remain untracked so they don't reveal AI agent usage. You decide what to track.

## Configuration

The default source is configured in the slash command. To set it, edit:

```
plugins/dogma/commands/dogma.md
```

And update `DEFAULT_SOURCE` (line 22).

## Security

Only sync from sources you trust. The synced files contain instructions that affect Claude's behavior.

## License

MIT
