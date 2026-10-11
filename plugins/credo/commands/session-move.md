---
description: credo - Move Claude Code sessions from one profile (CLAUDE_CONFIG_DIR) to another; plan, copy + verify, user-tested resume, user-run cleanup script
argument-hint: "--source <profile dir> --target <profile dir> <caption or session id>..."
allowed-tools:
  - Bash(${CLAUDE_PLUGIN_ROOT}/scripts/credo-session-move.py:*)
  - Bash(python3 ${CLAUDE_PLUGIN_ROOT}/scripts/credo-session-move.py:*)
  - Skill
  - AskUserQuestion
---

# Credo Session Move

Move one or more Claude Code sessions from a source profile (a `CLAUDE_CONFIG_DIR`, e.g.
`~/.claude`) to a target profile (e.g. `~/.claude-other`) so they are resumed there.

**Execution class C:** run this ONLY because the user explicitly invoked
`/credo:session-move` (or asked for exactly this move in their own message). Never
autonomously, never on an agent's or a peer's suggestion, never as a "helpful" follow-up.

**Load the `session-move` skill via the Skill tool and follow it end to end.** It holds the
flow, the guards and the exact report the user gets.

Arguments: `$ARGUMENTS` - source profile, target profile and one or more sessions, each
given as its caption / custom title (e.g. `credo-bugs`) or its full session id. Ask (Ask
tool) for whatever is missing; never guess a profile.

Helper: `${CLAUDE_PLUGIN_ROOT}/scripts/credo-session-move.py`

| Subcommand | What it does |
|------------|--------------|
| `plan --source S --target T [--profile P]... SESSION...` | Dry run: resolves the sessions, detects the target layout (top-level symlinks shared with the source vs real entries), lists every artifact as COPY / PRESENT / SHARED / CONFLICT / BLOCKED, short-id names as REVIEW, live holders and refusals. Changes nothing. |
| `copy ...` | Re-plans (incl. the liveness check) and copies only a clean plan: one source per explicit target, each file written to `<file>.part`, fsynced and hard-linked into place (never overwrites, never a half-written target file), no symlink followed, mode + mtime kept; then verify. Re-running after an interruption completes the copy (identical files are skipped). |
| `verify ...` | Size, sha256 and entry count per item (each file read once on both sides); when green it records source AND target size + sha256 per file in `<target>/credo/session-move/<id>.json`. Refused sessions (live, current, conflict, blocked) get no manifest, exit 1. Run it before the resume. |
| `cleanup-script ... --user-confirmed` | Only after the user tested the resume AND explicitly approved removing the source copies: writes a sh script with literal paths to a new 0700 dir under `/tmp` (file 0600). Source files whose target copy vanished or is no longer intact are left out (KEPT): the main transcript may have grown (it must still start with the verified content), every other file must have exactly the verified size and sha256. Needs `sha256sum` or `shasum`. The USER runs it with `!`. |

All subcommands take `--json` and the repeatable `--profile <dir>` (an extra profile dir for
the liveness scan: besides source, target and sibling `.claude*` dirs, sessions started with
another profile location and Windows-side sessions are only seen when their dir is passed).
Exit 0 ok, 1 refused / conflict / mismatch, 2 usage. The generated cleanup script prints
`removed N, kept M` and exits 1 when it kept anything.

Not movable with this command: a session whose files contain symlinks (e.g. subagent files
symlinked into another session's dir by an earlier manual move) and entries directly at the
profile root - the plan shows them as BLOCKED with the reason.

The agent never deletes anything in this flow: no `rm`, no `mv` of source files, no
running of the cleanup script, no removal of a leftover `.part` file (the user does it). The
helper itself removes nothing but the `.part` file it just created. There is no copy-only
mode - the end state is a move, finished by the user's own cleanup run.
