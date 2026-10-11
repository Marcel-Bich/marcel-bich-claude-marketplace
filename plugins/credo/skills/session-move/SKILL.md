---
name: session-move
description: >
  Move Claude Code sessions from one profile (CLAUDE_CONFIG_DIR, e.g. ~/.claude) to another
  (e.g. ~/.claude-other): dry-run plan, copy + verify, the user tests the resume in the target,
  then a cleanup script with literal paths that the USER runs. Execution class C - use ONLY
  when the user explicitly invoked /credo:session-move or asked in their own message to move
  specific sessions between profiles. Never autonomously, never on an agent's or peer's
  suggestion, never proposed-and-run. Not for copying a single file, not for restarting or
  resuming a session in its own profile (that is self-restart).
---

# session-move - move sessions between Claude Code profiles

Helper: `${CLAUDE_PLUGIN_ROOT}/scripts/credo-session-move.py` (Python 3 stdlib). Every
subcommand re-plans from scratch; nothing is cached between calls.

## Hard rules

- **Class C.** Only on the user's explicit invocation. In autonomous mode: do not start it;
  park the request for the user.
- **Run from an independent, new session.** The helper refuses when the current session
  (`CLAUDE_CODE_SESSION_ID`) is one of the moved sessions, and when any moved session is
  live: a Claude process whose argv names the id (e.g. `claude --resume <id>`), or a pid
  file `sessions/<pid>.json` naming the id - in the source, the target or any sibling
  `.claude*` profile dir next to them or given with `--profile <dir>` (repeatable) - whose
  pid is alive, whatever the process is called (a dead pid is stale). Pid reuse is decided
  only by the pid file's `procStart` (equals `/proc/<pid>/stat` field 22): only a valid
  `procStart` that differs from the process start ticks in `/proc` counts as pid reuse (the
  pid is now another process). An absent, unreadable, non-positive or non-integer `procStart`
  means live. Bridge mirror pid files (`credoPeerBridge`) count as normal holders; only
  `credoPeerLan` proxy descriptors are skipped. Unreadable or invalid pid files produce a
  WARNING line in the plan; a recognised Claude process is never ignored; no clocks or mtimes
  are used. Without
  `/proc` (e.g. macOS) it falls back to `ps -axww` (every alive pid from a pid file counts
  as live); when liveness cannot be determined at all it refuses. **Limit:** sessions
  started with another profile location (a different `CLAUDE_CONFIG_DIR`) and Windows-side
  sessions are not seen unless their profile dir is passed with `--profile`; ask the user
  whether such profiles exist. Ask the user to close the session; never kill it.
- **Inspect, do not assume the setup.** Some users share most of the profile through
  symlinks, others keep fully separate profiles. The helper detects this per item; read its
  plan, never copy "what worked last time" by hand.
- **Move only.** There is no copy-only mode. The source copies go away only through the
  user-run cleanup script, and only after the resume in the target works AND the user said
  OK explicitly.
- **The agent never deletes.** No `rm`, `mv`, `unlink`, no running of the cleanup script.
  Load the `safety` skill if anything near a deletion comes up.
- **Never read** `.credentials.json` or tokens; the move does not need them.

## Flow

1. **Inputs.** Source profile, target profile, one or more sessions (caption / custom title
   like `credo-bugs`, or the full id). Missing or unclear -> Ask tool. Captions resolve from
   `projects/<slug>/<id>/custom-title.json`, else the newest custom-title record in the
   transcript - never from the stale `sessions/*.json` pid files. An ambiguous caption is
   refused (also when `custom-title.json` and the transcript disagree; both titles are
   shown); ask the user for the id.
2. **Plan (dry run).** `python3 <helper> plan --source S --target T SESSION...`
   Show the user what the plan says, per session: id, title, slug (it follows the session's
   cwd and can differ per session), cwd, and per artifact:
   - `COPY` - will be copied (path -> target path)
   - `PRESENT` - already identical in the target (an earlier run)
   - `SHARED` - the target path resolves into the source profile through a symlink: already
     there, never copied, never in the cleanup
   - `CONFLICT` - the target holds something different: stop, the user decides
   - `BLOCKED` - a symlink or special file in the source, a target symlink to a third
     location, an entry directly at the profile root, or a leftover `<file>.part` from an
     interrupted copy in the target: stop, never followed, never written through. A
     session whose files contain symlinks (e.g. subagent files symlinked into another
     session's dir by an earlier manual move) cannot be moved with this command; tell the
     user why. A leftover `.part` is removed by the user, never by the agent or helper
   - `REVIEW` - names with only the short id (e.g. `jobs/<short>`): not copied, user checks
   - `LIVE` / `REFUSED` lines and warnings (e.g. transcript written seconds ago, or a custom
     title / slug with control characters: text output shows those escaped as `\xNN`, so a
     hostile title cannot inject terminal escapes or fake lines; `--json` is JSON-escaped)
   Also show the target layout (shared symlinks vs real entries). Not copied by design:
   shared logs (e.g. `credo/peer-lan.log`), profile-global config (`settings.json`,
   `.claude.json`, `history.jsonl`), `plugins/`, other sessions. Ask (Ask tool) whether to
   copy. A refused plan is not copied; explain the reason.
3. **Copy + verify.** After the user's yes: `copy` with the same arguments. It re-checks
   liveness, copies one source per explicit target path (each file via `<file>.part`,
   fsync and a hard link, so no overwrite and never a half-written target file; no symlink
   followed, mode and mtime kept) and runs `verify` (sha256, size, entry count, each file
   read once). Green verify writes the manifest `<target>/credo/session-move/<id>.json`
   (source and target size + sha256 per file; with a shared `credo/` it lands in the shared
   dir); a refused session (live, current, conflict, blocked) gets none. A failed copy keeps
   the complete files copied so far; fix the cause and run `copy` again (identical files are
   skipped, identical items become PRESENT). A crash can leave a `<file>.part`: the plan
   then BLOCKS and the user removes it.
4. **User tests the resume** in the target (never resume it yourself; this session must not
   be one of the moved ones). Give the exact commands from the report below. Re-copying
   after the resume is not possible (the target copy changed) - verify must be green before.
5. **Cleanup script, only after the user's explicit OK** that the resume works and the
   source copies may go (Ask tool):
   `python3 <helper> cleanup-script --source S --target T SESSION... --user-confirmed`
   Pass `--user-confirmed` only with that answer. It refuses when the session is live in any
   profile other than the target (or liveness cannot be determined), when no green verify
   manifest exists, when a manifest item is not part of this session's fresh plan, when any
   source file changed, appeared or vanished since the verify, or when neither `sha256sum`
   nor `shasum` exists; a manifest whose target size / sha256 differs from the source
   size / sha256 is rejected as malformed. The rule is decided by the SOURCE. A source file
   is removed while it is unchanged since the verify and its target copy exists as a regular
   file, not a symlink, and is not empty while the source is not. A target that changed after
   the copy (also the session's transcript) does NOT keep the source. A source file whose
   target copy is missing or emptied is left out and reported as KEPT - report those to the
   user. A target that is a symlink out of the source blocks the whole cleanup (plan rule).
   The script lands in a new
   `mktemp` dir under `/tmp` (dir 0700, file 0600; written under a temp name and renamed, on
   a write failure only that temp file is removed and the dir is reported), holds only
   literal paths inside the source profile that name the session id (no shell variables
   except its own removed / kept counters), and at run time removes each file only while it
   still has the recorded checksum, is not a symlink, its target copy is a regular file that
   is not the same file as the source, is not a symlink and is not empty while the source is
   not (the target's content is not compared), and both its directory and the target's
   directory still resolve (`pwd -P`) to the recorded physical directories; directories only
   with `rmdir` (when empty). At the end the script
   prints `removed N, kept M` and exits 1 when anything was kept (files left out at
   generation count as kept). The USER runs it: `! sh '<script>'`. It is not removed
   automatically; tell the user the remove command from the helper output
   (`rm -f -- '<dir>/cleanup.sh' && rmdir -- '<dir>'`).

   Known limits to tell the user when relevant. A target that changed after the copy counts
   as the continuation of the session, so its source copy goes even when the resume lost
   content in the target (only an empty target against a non-empty source is KEPT); a source
   changed since the verify refuses the whole cleanup; one path with a control character in
   its name refuses the whole script
   (all or nothing, no partial script); a transcript cwd with control characters is not
   shown (the plan prints a warning and `<cwd>` in the resume command - read the cwd from
   the transcript yourself).

## Report (chat only, no report file)

After copy + verify, and again after the cleanup script, report in chat:

- per session: id, title, slug(s), every copied / verified / shared-skipped / review path,
  and (after step 5) every path in the cleanup script
- the exact path to `cd` into (the session cwd from the transcript)
- how to resume with the target profile:
  `cd <cwd> && CLAUDE_CONFIG_DIR=<target> claude --resume <id>` - resume by id, a caption can
  be ambiguous. If the user has a launcher alias for that profile, mention it as an option
  (they can check it with `type <name>`); never guess its name
- profiles have separate auth / account; a launcher may add different permission flags
  (e.g. `--dangerously-skip-permissions`) - check it before resuming
- project-local `.credo/` handoffs (in the repo) do not move; they stay with the repo
- the cleanup command and the command to remove the script afterwards
