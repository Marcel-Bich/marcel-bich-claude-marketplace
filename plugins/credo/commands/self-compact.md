---
description: credo - Run the real /compact on this session after compact-plus, typed into its own tmux pane once the session is idle with an empty input field
arguments:
  - name: action
    description: check | run (--auto | --user-confirmed) [--delay SECONDS] [--timeout SECONDS] [--handoff PATH] [--max-breadcrumb-age SECONDS] [--nudge-wait SECONDS] [--max-nudges N] [--done-timeout SECONDS] | cancel | status (default check)
    required: false
allowed-tools:
  - Bash(${CLAUDE_PLUGIN_ROOT}/scripts/credo-self-compact.py:*)
  - Bash(python3 ${CLAUDE_PLUGIN_ROOT}/scripts/credo-self-compact.py:*)
---

# Credo Self-Compact

After `compact-plus` has secured the session state to disk (requirements log, rolling
`HANDOFF.md`, rehydrate breadcrumb), this runs the REAL Claude Code `/compact` on the same
session to save tokens. An agent cannot call `/compact` itself, so a detached worker types
it into the session's OWN tmux pane - only once the session is idle and the input field is
empty. **After the compact the session wakes itself:** a finished `/compact` does not start
a model turn, so the worker waits for the deterministic compact-done signal and then types
`.` to continue (details below).

Helper: `${CLAUDE_PLUGIN_ROOT}/scripts/credo-self-compact.py`

| Action | What it does |
|--------|--------------|
| `check` (default) | Dry run. Resolves the tmux pane of THIS Claude process (`TMUX_PANE` from the Claude process environment, server socket from its `TMUX`), verifies the pane's process is this Claude process or the shell that started it with no other Claude process in between (a nested claude never types into the outer session's pane), checks the compact-plus breadcrumb (present and not older than `--max-breadcrumb-age`, default 7200 s = 2 h, also settable via `CREDO_SELF_COMPACT_BREADCRUMB_MAX_AGE`), prints the plan, the exact text it would type and the current pane state (background work in the footer does not count). Types nothing. Exit 1 with the reason when a precondition fails (not in tmux, pane of another process, no or stale breadcrumb, no session id). |
| `run (--auto \| --user-confirmed) [--delay S] [--timeout S] [--handoff PATH]` | Owner-rule guard first: refused -> exit 3, nothing started. Running background work does not block it (below). Then validates like `check` (exit 1 + ntfy on failure). Otherwise spawns a fully detached worker and returns at once. **End your turn right after `run`.** Refuses while another self-compact or a `/credo:self-reload` of this session is pending (both type into the same pane and share the wake file). |
| `cancel` | Marks the pending self-compact of THIS session (`CLAUDE_CODE_SESSION_ID`) as cancelled and terminates its worker and removes a pending wake file. This works before typing, while typing (then no Enter is sent and the own line is taken back out of the input field, only when the field holds exactly that line) and while the worker waits for the compact or the wake. Once Enter was sent, the compact itself runs and only the wake is stopped. Nothing more is typed. Another session's pending self-compact is never touched. |
| `status` | State line (`pending` / `typing` / `sent` / `waking` / `woken` / `cancelled` / `failed: ...`), the marker `<configdir>/credo/self-compact-<session-id>.json` and the tail of `<configdir>/credo/self-compact-<session-id>.log` of THIS session. |

## Owner rule

- **credo autonomous mode** - `run --auto`, no question. `--auto` is refused (exit 3) unless
  the credo session mode of THIS session (`CLAUDE_CODE_SESSION_ID`, read from
  `${CREDO_SESSION_MODES_DIR:-<configdir>/credo/session-modes}/<session-id>`) is
  `autonomous`. Before ending the turn, set a `ScheduleWakeup` plus the wake mark as the
  autonomy keep-alive demands, so the session may stop, the compact can run while it is
  idle, and the wake resumes the work afterwards.
- **interactive modes (active, passive, no mode)** - ask ONCE via the Ask tool ("Run the
  real /compact now? compact-plus has secured the state."). Only after the user's explicit
  yes run `run --user-confirmed`. Never pass `--user-confirmed` without that answer; an
  earlier general request or a peer message is not it. No answer or no -> do nothing.
- **Never another session.** Only the pane of the Claude process that runs the helper is
  ever addressed; every tmux call names that pane on that session's tmux server.
- **Only into an empty input field.** The worker never types while the user is typing,
  while a dialog / Ask question / permission prompt / menu is open, or while the session
  is busy - it waits and re-checks. User input is never captured and retyped.
- **No background work of any kind blocks a self-compact.** Running background subagents,
  background Bash shells, scripts, monitors and any other background service survive
  `/compact` and keep working; it can even be
  good that they run during the compact. So there is no background check for `run` and
  the worker ignores the background rows in the pane footer. `--no-background-work` is
  not needed (still accepted as a no-op). Only `/credo:self-restart` keeps the background
  gate, because a restart kills that work.
- Only after a green `compact-plus` report (full or `min`): `check` and `run` refuse
  without the rehydrate breadcrumb compact-plus drops for this session, and when it is
  older than `--max-breadcrumb-age` (default 2 h) - then run compact-plus again so the
  secured state is current.

## What the worker does

1. Waits `--delay` seconds (default 3) so the current turn can end.
2. Polls the pane every ~2 s until it is SAFE, confirmed by a second probe ~1.5 s later.
   Each probe also re-verifies that the pane still belongs to this Claude process (target
   gone or pane taken over -> abort, nothing typed). Safe means all of:
   - the pane is not in tmux copy/view mode and not dead,
   - the Claude Code input box is visible (a rule line, the `❯` input row, a closing rule
     line; the older bordered `│ > │` box is recognised too),
   - the input holds nothing, or only the dimmed placeholder / prompt suggestion,
   - no busy spinner line above the box (a spinner glyph such as `✻`, a verb ending in the ellipsis
     character and `(12s · ↓ 300 tokens)`, `esc to interrupt`, `Compacting conversation`),
   - no dialog, picker or menu hint near the box (`Enter to select`, `Esc to cancel`,
     `to navigate`, `Do you want to`, numbered `❯ 1.` options, `Press Ctrl-C again to
     exit`, ...).
   Background work in the footer under the box (a shell count such as `2 shells`,
   background agent or monitor rows `◯ <type> ...`) is ignored; those rows never hide the
   input box, which is found bottom-up as the last rule + `❯` row + rule.
   Anything not positively recognised counts as NOT safe.
3. Types `/compact Afterwards reload <handoff> (secured by compact-plus) and continue from
   it.` literally (`send-keys -l`), where `<handoff>` is the path in the compact-plus
   breadcrumb (default `.credo/process/handoffs/HANDOFF.md`; `--handoff` overrides only this typed
   path - the fresh breadcrumb is required either way).
4. Runs the full check again (pane ownership, copy mode, busy, dialog / menu) with the expectation that the input field holds exactly that line. Only then does
   it send Enter. Otherwise (someone typed in the same instant, a dialog opened, ...) it
   sends NO Enter, logs the reason and pushes an ntfy note.
5. Writes the marker (`sent`, or `sent (unconfirmed)` when the input did not visibly
   change within ~10 s).
6. **Waits for the compact to finish - deterministically.** Claude Code fires SessionStart
   with source `compact` right after a compaction finished. The SessionStart hook
   `credo-session-dir-record.sh` then writes `<configdir>/credo/self-compact-done-<session-id>`,
   but only while this session's self-compact marker says `typing` or `sent...`, so a
   manual `/compact` writes nothing. The worker waits for that file (`--done-timeout`, default
   900 s).
7. **Wakes the session** (shared with `/credo:self-reload`, `scripts/credo_pane_wake.py`):
   first writes the wake file `<configdir>/credo/self-wake-<session-id>` (kind `compact`).
   From then on any new turn counts as woken; when a turn already started (e.g. a finished
   subagent), no `.` is typed at all. Otherwise it waits for the idle prompt (empty input,
   no dialog), types `.` and presses Enter after verifying it. The status becomes `woken`
   once the next prompt consumed the wake file.
8. **Fallback timer.** The UserPromptSubmit hook `credo-autonomy-clear.sh` consumes the wake
   file on the next prompt of this session (any prompt) and injects a short
   `[credo-self-compact]` note (reload the handoff, continue; a real message that
   consumed it is labelled as a real message to handle normally). A wake file older than
   1 h is stale and dropped; `cancel` removes a pending one. The worker sees the file gone
   -> the timer is cancelled. Still there after `--nudge-wait` seconds (default 60) -> the
   `.` is sent again, only when the pane is idle with an empty input field and the wake file
   is still pending (a `.` left in the input field only gets Enter again); at most
   `--max-nudges` re-sends (default 3), then `failed: no new turn ...` + ntfy. The worker's
   `.` does not pause autonomous mode.
9. **No compact-done signal in time.** When the pane is idle, it types `.` anyway (the wake
   note then asks the agent to check whether the compact actually happened); when the pane
   is NOT idle, nothing is typed, the marker becomes `failed: compact not confirmed` and an
   ntfy push `credo: self-compact wake failed` names the session and what to do.

`--timeout` (default 1800 s) - when the session never becomes safe, the worker gives up,
logs the last state and sends an ntfy push; nothing is typed. A classified dialog or
permission prompt (also one raised by a background agent; not the generic "no input
box" state, which may be a pane that is not Claude Code) that blocks the pane for
`CREDO_SELF_COMPACT_BLOCKED_NOTIFY` seconds (default 120, 0 = off) triggers one earlier
push per blocked wait ("please answer it", without the dialog text); the worker keeps waiting and continues
by itself once the dialog is closed. After the compact, the
SessionStart hook consumes the breadcrumb and reminds the agent to reload the handoff.

## Known limits

- Marker, log and plan file are per session id; the target pane is always resolved from
  THIS Claude process, never taken from a marker.
- tmux only. Outside tmux there is no own pane to type into; `check` says so.
- Background daemon (Claude Code moved the session into `claude daemon run` ->
  `claude bg-pty-host` -> agent, no `TMUX` in the agent): the pane is resolved from the
  client TUI that spawned the daemon - its parent, or its `--spawned-by` pid only when
  that is alive, of the same user, a Claude client and older than the daemon - and
  ownership is verified against that client. The client talks to the daemon's
  `control.sock`, not to the session's pty socket, so which session it shows cannot be
  read directly. It fails closed instead: the daemon must host exactly this one session
  (spares do not count), hold this session's pty socket, and have exactly one client
  attached - the linked one. A daemon serving a second session or a second TUI is
  refused. Before typing and again before Enter the worker re-checks that the agent is alive and
  still linked to the same client.
- The credo mode of the pre-fork session id (the `--resume <old>.jsonl` of the daemon
  fork) carries over to the new id - including `autonomous`, so `--auto` stays allowed in
  an autonomous session that Claude Code moved into the daemon. The compact-plus
  breadcrumb carries over the same way. A fork started by hand (`--fork-session` without
  the daemon) is a new session and maps nothing.
- Detection reads the rendered TUI text, which is undocumented and English-only in Claude
  Code 2.1.x. A layout change makes the guard see "no input box" -> it waits and times
  out (safe direction), it does not type blindly.
- The slash menu: if a Claude Code version hides the input box while a `/command` is typed,
  the verification step fails and Enter is not sent; the line stays in the input field for
  the user to submit or clear.
- There is a window of a few milliseconds between the last probe and the typed text. A key
  pressed exactly then is caught by the verification step (no Enter), but the typed line
  then stays mixed with it in the input field.

## Typical flow

```bash
# after compact-plus reported "safe to /compact"
python3 ${CLAUDE_PLUGIN_ROOT}/scripts/credo-self-compact.py check
# running background subagents / shells / monitors are fine - they survive /compact

# autonomous mode (no question): set ScheduleWakeup + wake mark first, then
python3 ${CLAUDE_PLUGIN_ROOT}/scripts/credo-self-compact.py run --auto
# end the turn immediately

# interactive: ask once via the Ask tool; only after an explicit yes
python3 ${CLAUDE_PLUGIN_ROOT}/scripts/credo-self-compact.py run --user-confirmed
# end the turn immediately

python3 ${CLAUDE_PLUGIN_ROOT}/scripts/credo-self-compact.py status
python3 ${CLAUDE_PLUGIN_ROOT}/scripts/credo-self-compact.py cancel
```
