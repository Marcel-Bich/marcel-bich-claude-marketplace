---
description: credo - Reload plugins and skills of this session (/reload-plugins, /reload-skills typed into its own tmux pane) and wake it with "."; the cheap first try after a plugin update, cc-up only as fallback
arguments:
  - name: action
    description: check | run (--auto | --user-confirmed) [--update] [--delay SECONDS] [--timeout SECONDS] [--nudge-wait SECONDS] [--max-nudges N] | cancel | status (default check)
    required: false
allowed-tools:
  - Bash(${CLAUDE_PLUGIN_ROOT}/scripts/credo-self-reload.py:*)
  - Bash(python3 ${CLAUDE_PLUGIN_ROOT}/scripts/credo-self-reload.py:*)
---

# Credo Self-Reload

After a plugin update a full restart (`cc-up`, `/credo:self-restart --update`) is not
always needed. Often `/reload-plugins` followed by `/reload-skills` is enough. An agent
cannot run slash commands itself, so a detached worker types them into the session's OWN
tmux pane after the turn ended - the same mechanism as `/credo:self-compact`. The reload
commands do not start a model turn, so the worker finally types `.` + Enter to wake the
session. On that woken turn the agent checks whether the reload was enough; only if not,
it falls back to `/credo:self-restart --update` (cc-up).

**Order after a plugin update: `/credo:self-reload` first, `/credo:self-restart --update`
(cc-up) only when the reload was not enough.**

Helper: `${CLAUDE_PLUGIN_ROOT}/scripts/credo-self-reload.py`

| Action | What it does |
|--------|--------------|
| `check` (default) | Dry run. Resolves the tmux pane of THIS Claude process and verifies it belongs to it (no other Claude process in between), prints the plan (steps, fallback, update allowlist with `--update`) and the current pane state. Types nothing. Exit 1 with the reason when a precondition fails (not in tmux, pane of another process, no session id). |
| `run (--auto \| --user-confirmed) [--update] [--delay S] [--timeout S] [--nudge-wait S] [--max-nudges N]` | Owner-rule guard first: refused -> exit 3, nothing started. Then validates like `check` (exit 1 + ntfy on failure). Otherwise spawns a fully detached worker and returns at once. **End your turn right after `run`.** Refuses while another self-reload or a `/credo:self-compact` of this session is pending (both type into the same pane and share the wake file). |
| `cancel` | Marks the pending self-reload of THIS session as cancelled, terminates its worker and removes a pending wake file. Another session's self-reload is never touched. |
| `status` | State line (`pending` / `typing /reload-...` / `waking` / `woken` / `cancelled` / `failed: ...`), the marker `<configdir>/credo/self-reload-<session-id>.json`, whether the wake file is still pending, and the log tail. |

## Owner rule

- **credo autonomous mode** - `run --auto`, no question. `--auto` is refused (exit 3) unless
  the credo session mode of THIS session is `autonomous`.
- **interactive modes (active, passive, no mode)** - ask ONCE via the Ask tool ("Reload
  plugins and skills now? /reload-plugins and /reload-skills are typed into this session,
  then it continues on its own."). Only after the user's explicit yes run
  `run --user-confirmed`. No answer or no -> do nothing.
- **Never another session.** Only the pane of the Claude process that runs the helper is
  ever addressed.
- **Only into an empty input field.** Never while the user is typing, a dialog / Ask
  question / permission prompt / menu is open, or the session is busy - the worker waits
  and re-checks. User input is never captured and retyped.
- **No background work of any kind blocks it.** Running background subagents, background
  shells, scripts, monitors and any other background service survive a reload; there is no
  background check and no `--no-background-work` flag. The footer rows under the input box
  are ignored. (Only `/credo:self-restart` keeps a background gate, because a restart kills
  that work.)
- tmux only. Outside tmux `check` says so; reload by hand or use `/credo:self-restart`.

## What the worker does

1. Waits `--delay` seconds (default 3) so the current turn can end.
2. `--update` (optional): runs the allowlisted plugin update first, exactly as
   `/credo:self-restart --update` does (`self_update.marketplaces`, default credo's own
   marketplace; `claude plugin marketplace update` + `claude plugin update`), and records
   versions before -> after. It does not touch the pane. Use it when the new version is not
   installed yet (e.g. right after pushing a plugin release).
3. For `/reload-plugins`, then `/reload-skills`: waits until the pane is idle and safe
   (two probes, pane ownership re-verified each time, same detection as self-compact),
   types the command literally, runs the full check again expecting exactly that text and
   only then sends Enter. Then it polls the pane for the command's `Reloaded` result line
   (default up to 30 s, `CREDO_SELF_RELOAD_RESULT_WAIT`) before the next key, so nothing is
   queued behind a running command. The result text is undocumented, so a missing line
   only logs; the idle guard before the next key still applies.
4. Wakes the session (shared with self-compact, `scripts/credo_pane_wake.py`): writes the
   wake file `<configdir>/credo/self-wake-<session-id>` (kind `reload`), waits for the idle
   prompt, types `.` and presses Enter after verifying it.
5. **Fallback timer.** The UserPromptSubmit hook `credo-autonomy-clear.sh` consumes the
   wake file when the next prompt of this session arrives - any prompt counts (the `.`, a
   user message, a peer message, a task notification). The worker sees the file gone ->
   status `woken`, the timer is cancelled, nothing more is sent. Still there after
   `--nudge-wait` seconds (default 60) -> the `.` is sent again, but only when the pane is
   idle with an empty input field (no turn running - a busy model may start the turn later
   than 60 s) and the wake file is still pending; a `.` still left in the input field only
   gets Enter again. At most `--max-nudges` re-sends (default 3); then `failed: no new
   turn ...` + ntfy, and the wake file stays so the next prompt still gets the note.

The worker's `.` is not a user message. When it consumes the wake file it does not pause
autonomous mode, and the note says the helper typed it. Any other prompt that consumes the
file is a real message. It behaves as usual, and the note tells the agent to handle it
normally and then do the reload check. A wake file older than 1 h is stale and dropped
without a note. If a turn starts while the `.` is being typed, the worker counts the
session as woken, sends no Enter and removes its own `.` (only when the input field holds
exactly `.`).

## The woken turn

The hook injects `[credo-self-reload] ...` into the woken turn. It carries the plugin update summary
(with `--update`), the loaded credo version (from the hook's own plugin root after the
reload) against the newest credo version in the plugin cache, and the instruction:

- check whether the reload was enough - loaded version = newest installed, and the command,
  skill or hook expected from the update is listed;
- enough -> continue where you left off;
- not enough -> fall back to the full restart `/credo:self-restart --update` (cc-up) under
  its owner rule (autonomous: `run --announce 300 --no-background-work --update`;
  interactive: ask once via the Ask tool, then `run --user-confirmed --no-background-work
  --update`).

## Known limits

- Detection reads the rendered TUI text (undocumented, English-only in Claude Code 2.1.x).
  A layout change makes the guard see "no input box" -> it waits and times out (safe
  direction), it never types blindly.
- Whether `/reload-plugins` picks up everything a new version brings (hooks, commands,
  skills) depends on Claude Code; the woken-turn check exists for exactly that reason.

## Typical flow

```bash
python3 ${CLAUDE_PLUGIN_ROOT}/scripts/credo-self-reload.py check --update

# autonomous mode (no question)
python3 ${CLAUDE_PLUGIN_ROOT}/scripts/credo-self-reload.py run --auto --update
# end the turn immediately

# interactive: ask once via the Ask tool; only after an explicit yes
python3 ${CLAUDE_PLUGIN_ROOT}/scripts/credo-self-reload.py run --user-confirmed --update
# end the turn immediately

python3 ${CLAUDE_PLUGIN_ROOT}/scripts/credo-self-reload.py status
python3 ${CLAUDE_PLUGIN_ROOT}/scripts/credo-self-reload.py cancel
```
