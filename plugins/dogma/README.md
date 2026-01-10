# Claude-Dogma

Intelligent sync of Claude instructions with enforcement hooks for security and consistency.

## Features

### Slash Commands

| Command | Description |
|---------|-------------|
| `/dogma:sync` | Sync Claude instructions from a source with interactive review |
| `/dogma:cleanup` | Find and fix AI-typical patterns in code (reactive cleanup) |

### Enforcement Hooks

The plugin includes hooks that enforce rules at the technical level:

| Hook | Trigger | Action | Toggleable |
|------|---------|--------|------------|
| User Prompt Reminder | Every prompt | Reminds of non-enforceable rules | `DOGMA_PROMPT_REMINDER` |
| Git Add Protection | `git add` | Blocks adding AI files and secrets | `DOGMA_GIT_ADD_PROTECTION` |
| Git Permissions | `git commit/push` | Checks permissions in CLAUDE.git.md | `DOGMA_GIT_PERMISSIONS` |
| File Protection | `rm`, `rmdir` | Blocks destructive file operations | `DOGMA_FILE_PROTECTION` |
| Dependency Verification | `npm/pip install` | Blocks until package verified | `DOGMA_DEPENDENCY_VERIFICATION` |
| Secrets Detection | Write/Edit | Blocks writing secrets to files | `DOGMA_SECRETS_DETECTION` |
| Write/Edit Reminder | Write/Edit | Shows @-references to relevant rules | `DOGMA_WRITE_EDIT_REMINDER` |
| Post-Write Validation | After Write/Edit | Warns about AI traces in content | `DOGMA_POST_WRITE_VALIDATE` |
| Prompt Injection | WebFetch/WebSearch | Warns about injection attempts | `DOGMA_PROMPT_INJECTION` |

## Sync Command

Fetches Claude instructions from a source and merges them interactively.

```bash
/dogma:sync                                  # Sync from default source
/dogma:sync https://github.com/user/repo     # Sync from GitHub repo
/dogma:sync ./my-standards                   # Sync from local path
```

### What Gets Synced

- `CLAUDE.md` - Main Claude instructions
- `CLAUDE.*.md` - Additional instruction files
- `.claude/` - Claude configuration (each file reviewed individually, including settings.json)

### Interactive Review

For each file, you decide what happens:
- **New file**: Add it? Skip? Show full content?
- **Different file**: Keep current? Replace? Merge?
- **Identical**: Automatically skipped

Files stay untracked - they won't reveal AI usage.

## Cleanup Command

Finds and fixes AI-typical patterns in your code.

```bash
/dogma:cleanup           # Scan working directory
/dogma:cleanup src/      # Scan specific directory
```

### Detected Patterns

- **Typography**: Curly quotes (""), em-dashes (--), ellipsis characters (...)
- **Emojis**: In code files where they don't belong
- **AI Phrases**: "Let me...", "I'll...", "Sure!", "Certainly!"
- **German**: ASCII umlauts instead of proper ones (fuer -> für)

## Hook Details

### User Prompt Reminder

Runs at the START of every prompt. Reminds Claude of:
- Git permissions (from CLAUDE.git.md)
- Language rules (@CLAUDE/CLAUDE.language.md)
- Security rules (@CLAUDE/CLAUDE.security.md)
- Non-enforceable rules (Honesty, Planning, Philosophy)

### Git Add Protection

Blocks `git add` for:
- AI instruction files: `CLAUDE.md`, `CLAUDE.*.md`, `.claude/`
- Secret files: `.env*`, `*.pem`, `*.key`, `*credentials*`, `id_rsa`

### Git Permissions

Checks the permissions section in `CLAUDE.git.md`:
```markdown
<permissions>
- [ ] May run `git add` autonomously
- [ ] May run `git commit` autonomously
- [ ] May run `git push` autonomously
</permissions>
```

If a checkbox is unchecked, the operation is blocked.

### Dependency Verification

BLOCKS package installation until verified:
```
npm install some-package

BLOCKED by dogma: dependency verification required

REQUIRED: Verify packages BEFORE installation!
1. WebFetch: https://socket.dev/npm/package/some-package
2. WebFetch: https://snyk.io/advisor/npm-package/some-package
```

### Secrets Detection

Blocks writing secrets to files:
- OpenAI API keys (`sk-...`)
- Anthropic API keys (`sk-ant-...`)
- AWS keys (`AKIA...`)
- JWT tokens
- Private keys
- Database connection strings
- GitHub tokens, Slack tokens, Stripe keys

### Post-Write Validation

After Write/Edit, warns about AI traces:
- Curly quotes ("")
- Em-dashes (--)
- Ellipsis characters (...)
- Smart apostrophes
- Emojis in code
- AI phrases in comments

### Prompt Injection Detection

After WebFetch/WebSearch, warns about:
- "Ignore previous instructions" patterns
- "You are now..." role changes
- Fake system messages
- Override/jailbreak attempts
- Hidden/zero-width characters

## Configuration

### Environment Variables

All hooks can be disabled via environment variables. Default is `true` (enabled).

```bash
# Disable specific hooks
export DOGMA_PROMPT_REMINDER=false
export DOGMA_GIT_ADD_PROTECTION=false
export DOGMA_GIT_PERMISSIONS=false
export DOGMA_FILE_PROTECTION=false
export DOGMA_DEPENDENCY_VERIFICATION=false
export DOGMA_SECRETS_DETECTION=false
export DOGMA_WRITE_EDIT_REMINDER=false
export DOGMA_POST_WRITE_VALIDATE=false
export DOGMA_PROMPT_INJECTION=false
```

### Default Sync Source

Edit `commands/sync.md` and update `DEFAULT_SOURCE` to set your default repository.

## Strategy

The plugin uses a differentiated enforcement strategy:

| Rule Type | Enforcement | Hook Type |
|-----------|-------------|-----------|
| Technically enforceable (git, secrets) | BLOCK | PreToolUse |
| Partially enforceable (language, AI traces) | REMIND + VALIDATE | PreToolUse + PostToolUse |
| Not enforceable (honesty, planning) | REMIND only | UserPromptSubmit |

## Installation

1. Clone the marketplace repo
2. Install the dogma plugin to your project
3. Run `/dogma:sync` to pull instructions
4. Hooks are automatically active

## Requirements

- `jq` for JSON parsing in hooks
- `bash` for hook scripts
- Git repository (for git-related hooks)

## License

MIT
