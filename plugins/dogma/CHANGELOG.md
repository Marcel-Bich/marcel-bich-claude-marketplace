Changelog of the dogma plugin. Newest first. Months group releases; no day dates. Releases up to v1.43 are summarized by minor version.

# 2026-10

## v1

### v1.44

#### v1.44.4

##### Fixed

- German-only language rules now fire on German text only: the write reminder's "Keep it in
  German" note and the post-write ASCII umlaut check (fuer -> für) use a stricter shared
  detection (`lib-german.sh`) instead of substring matches that also hit English or other
  languages. Quoted text and code are ignored, and German function words must be a
  meaningful share of all words and clearly outweigh English ones
- An English file that quotes German examples is no longer reported as German, and a
  bilingual file gets no language note instead of a wrong one
- A German file is no longer reported as English because German prose contains "in" / "is"
- `/dogma:force` examples show the real umlauts again (they had been stripped to "fur",
  "konnen"); `/dogma:cleanup` and the prompt reminder state the umlaut rule is German text only
- New `scripts/test-german-detection.sh` checks German, English, French, Spanish, Dutch and
  Portuguese samples, English text with German quotes and code, and a bilingual document
  against the detection and both hooks

#### v1.44.3

##### Fixed

- dogma band no longer shows a "blocked" line forever: the notice is time-stamped and hidden after 15 s even when a plugin reload cut its timer short, and a new session starts without it

#### v1.44.2

##### Fixed

- Delete guard only analyzes a segment whose command word can delete, move or link; a verb inside an argument (a file name, a grep pattern with <...>) no longer blocks harmless commands

#### v1.44.1

##### Changed

- Notice tests use an invented project name instead of a real one

#### v1.44.0

##### Added

- Always-on delete guard: blocks deleting, moving or symlinking onto protected paths (/, first-level dirs, /home depth 0-2, the home and its children); targets are resolved first (~, $HOME, cwd and cd, symlinks, glob base), unresolvable targets are blocked, fails closed without python3

##### Security

- A symlink under /tmp pointing at a protected directory can no longer route a recursive delete past the /tmp allowance

### v1.43

#### Added

- DOGMA-PERMISSIONS.md is picked by action target, pinned project, then session folder, with per-id inheritance (default on)
- Notices also show in non-git folders and for pinned projects that inherit permissions

### v1.42

#### Added

- Source broadcasts via NOTICES.md
- `CLAUDE_MB_DOGMA_SOURCE` for sync and recommended setup
- Per-folder git identity for the source fetch

### v1.41

#### Added

- Stable setting ids (`§xxxx`) matched first with a text fallback, plus an id registry
- changelog.d assembly in `/dogma:versioning`

### v1.40

#### Added

- Worktree files list (link or copy, `.credo/` included by default) and a cleanup-merged-worktrees checkbox

#### Changed

- Subagents may commit in their own worktree, never push or merge

### v1.39

#### Added

- One-time per-repo update notices for updates that need user action (Run/Later/Never), with an optional band toast

### v1.38

#### Added

- Final Verification option to run all tests only at release

### v1.37

#### Added

- Optional per-stage test commands (commit, push, relevant, build, all) with branch filters

### v1.36

#### Added

- Optional Claude Code band showing restricting permissions with change highlights

### v1.35

#### Added

- `permissions-summary.sh` listing only the restricting DOGMA-PERMISSIONS entries

# 2026-08

## v1

### v1.34

#### Added

- `FORCE_PARENT_MODEL` setting to enforce the parent model for all plugins
- Configurable reset interval for subagent enforcement
- Allowlist for path-based token-protection checks

#### Changed

- Command UI strings are English
- Profile config dir is respected for model-policy and plan-mode checks

#### Security

- Credential protection extended to all tools and file types, including a Grep hook

# 2026-01

## v1

### v1.33

#### Changed

- git-add-protection hook about 15x faster

### v1.32

#### Added

- Review-trigger hook for PostToolUse Write/Edit

#### Changed

- Model override uses the higher of the agent default and the parent model, also for built-in agents

### v1.31

#### Added

- Working model override hook for Anthropic agents

### v1.30

#### Added

- MIT-licensed agents and a model override hook
- Read-only Bash whitelist for subagent enforcement

### v1.29

#### Added

- `/dogma:ignore` commands (add, audit, sync-all)
- `/dogma:recommended:setup` command
- Universal version file discovery in versioning, including marketplace registries
- git-pull-before-push hook to prevent data loss
- Subagent enforcement and orchestration hooks with subagent context rules and section-specific permissions

### v1.28

#### Added

- Three-state permissions (auto/ask/deny)

#### Security

- Token protection scans files before Read operations
- Chained command, subshell and backtick detection in all hooks
- Dependency verification denies instead of asking

### v1.27

#### Added

- Token-protection hook blocking commands that expose credentials

### v1.26

#### Added

- `/dogma:docs-update` command for documentation sync

### v1.25

#### Added

- `/dogma:sanitize-git` command for git history cleanup

### v1.23

#### Added

- `/dogma:force` for interactive rule enforcement

#### Changed

- `/dogma:setup` renamed to `/dogma:permissions`

### v1.22

#### Added

- `/dogma:sync` migrates permissions from CLAUDE.git.md to DOGMA-PERMISSIONS.md

### v1.21

#### Added

- `/dogma:sync` option for global or project settings.json

### v1.20

#### Added

- DOGMA-PERMISSIONS.md support with a setup command

### v1.19

#### Added

- Pre-commit lint hook and project-agnostic `/dogma:lint`

### v1.18

#### Added

- `/dogma:lint` and `/dogma:lint:setup` commands
- `/dogma:versioning` command

### v1.17

#### Changed

- Environment variables renamed to the `CLAUDE_MB_DOGMA_*` prefix

### v1.16

#### Added

- Prompt-intervention reminder and version-sync check hooks

### v1.14

#### Changed

- File protection logs and asks before deleting instead of blocking; TO-DELETE.md uses checklist format

### v1.13

#### Added

- Log mode for file deletion protection

### v1.12

#### Added

- `DOGMA_ENABLED` master switch for all hooks

#### Changed

- Hooks differentiate deny and ask; AI and secret files are blocked without bypass
- Hook output is English

### v1.11

#### Changed

- Hooks ask for confirmation instead of denying

### v1.9

#### Added

- LICENSE file handling with legal warnings

### v1.8

#### Added

- Checklist tracking

### v1.7

#### Added

- Enforcement hooks for security and consistency

### v1.6

#### Added

- Recommendations shown during sync as informational tips

### v1.5

#### Changed

- Flexible argument parsing for sync: source and instructions in any order

### v1.4

#### Added

- Rule-by-rule merging with structure conflict detection and preview before apply

### v1.3

#### Added

- git config sync (user, email)

### v1.2

#### Added

- Source analysis that scans the project structure, finds GUIDES and follows @references

### v1.1

#### Changed

- Command renamed to `/dogma:sync`

### v1.0

#### Added

- dogma plugin: sync of Claude instructions with interactive merge
