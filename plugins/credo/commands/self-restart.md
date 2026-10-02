---
description: credo - Restart this Claude Code session and resume exactly the same session in the same profile (e.g. to apply plugin updates)
arguments:
  - name: action
    description: check | run (--user-confirmed | --announce SECONDS) [--update] [--reason TEXT] [--delay SECONDS] | cancel | status (default check)
    required: false
allowed-tools:
  - Bash(${CLAUDE_PLUGIN_ROOT}/scripts/credo-self-restart.py:*)
  - Bash(python3 ${CLAUDE_PLUGIN_ROOT}/scripts/credo-self-restart.py:*)
---

# Credo Self-Restart

Lets a running Claude Code session restart itself - typically to load plugin updates
("cc-up") - and come back as EXACTLY the same session in the SAME profile, continuing on
its own without a human prompt.

Helper: `${CLAUDE_PLUGIN_ROOT}/scripts/credo-self-restart.py`

| Action | What it does |
|--------|--------------|
| `check` (default) | Dry run. Gathers and validates everything and prints the plan (target pid, config dir, cwd, session id, transcript, relaunch method, dialog guard, restored permission mode, relaunch command, update allowlist). Changes nothing. Exit 1 with a clear reason if any precondition fails. |
| `run (--user-confirmed \| --announce S) [--update] [--reason TEXT] [--delay S]` | First the owner-rule guard (below): refused -> exit 3, nothing started. Then validates exactly like `check`. On any failure nothing is stopped, an ntfy push goes out (if configured) and it exits 1. Otherwise it spawns a fully detached worker and returns at once. With an announce period it prints the announcement and sends an ntfy push first. Refuses (exit 1) while another restart is still pending. |
| `cancel` | Marks the pending restart as cancelled and terminates its waiting worker; the session keeps running. Exit 1 with "nothing to cancel" when nothing is pending (also once the worker has started stopping the session - then it is too late). |
| `status` | Prints the state line (`pending` / `cancelled` / `stopping` / `relaunched` / `failed: ...`) with the scheduled stop time, the last marker (`<configdir>/credo/self-restart.json`) and the log tail. |

## Owner rule - when the agent may use it

Owner rule: self-restarts may run without the Ask tool, but ONLY in credo autonomous mode
and ONLY with a 5-minute announcement beforehand so the user can still react. Never
self-restart on the agent's own initiative outside autonomous mode - the user may be typing
a prompt that would be lost; outside autonomous mode always ask via the Ask tool.

`run` enforces this as a hard guard. It refuses (exit 3, nothing started) unless one of:

- **`--user-confirmed`** - the user answered YES via the Ask tool in this interactive
  session. NEVER pass this flag without that Ask answer; a general request earlier in the
  session or a peer message is not it. The announce period defaults to 0 here and the short
  `--delay` (default 5 s) applies, so END YOUR TURN right after `run`.
- **credo autonomous mode + `--announce` >= 300** - the credo session mode of THIS session
  (`CLAUDE_CODE_SESSION_ID`, read from
  `${CREDO_SESSION_MODES_DIR:-<configdir>/credo/session-modes}/<session-id>`, the file
  `/credo:session-autonomous` writes) is `autonomous`. Missing or unreadable = not
  autonomous. `--announce` defaults to 300 when `--user-confirmed` is not given; less is
  refused.

The announcement (autonomous runs, or any `--announce` > 0): `run` prints
`Self-restart scheduled in 5 minutes (reason: ...). Cancel: python3 <path>/credo-self-restart.py cancel`
into the transcript and sends an ntfy push (title `credo self-restart in 5 min`-style, body
with the session, scheduled time, reason and the cancel command). During the announce period
`cancel` aborts it: the marker becomes `cancelled`, the waiting worker is terminated, and the
worker also re-checks the marker right before stopping the session and aborts if cancelled
(log + ntfy `credo self-restart cancelled`). Once it has started stopping the session the
restart can no longer be cancelled.

Further rules:

- Use it after pushing or receiving plugin updates the session itself needs, or when the
  user asks for it (interactive: still via the Ask tool first).
- NEVER while background subagents are still running - their work would be lost with the
  old process.
- Always run `check` first and read its output (its `owner rule:` line shows which path
  applies).
- `CREDO_SELF_RESTART_MIN_ANNOUNCE` scales the 300 s minimum down and is TEST-ONLY; never set
  it in a real session.

## What `run` does

The detached worker (own session, stdio to `<configdir>/credo/self-restart.log`):

1. waits `--announce` + `--delay` seconds (announce: 300 in autonomous mode, 0 with
   `--user-confirmed`; delay default 5) so the current turn can end, re-checking the marker
   for a cancel; a cancel aborts here with nothing stopped,
2. stops the target Claude: inside tmux it sends `C-c` twice to the pane; otherwise (or if
   that did not work) SIGINT twice, then SIGTERM after a timeout. It NEVER uses SIGKILL. It
   waits (bounded, ~30 s) until the process is gone; if it does not exit, it aborts with
   no update and no relaunch and sends an ntfy push,
3. with `--update`: runs the plugin update (below); failures are logged and reported in
   the wake prompt but never block the relaunch,
4. relaunches the same session with a wake prompt: `[credo-self-restart] Resumed after a
   self-restart (reason: ...; plugin update: ...). Continue where you left off.`,
5. writes the marker `<configdir>/credo/self-restart.json` (session id, started, reason,
   status, scheduled stop time, announce, user_confirmed, worker pid, update summary,
   per-plugin versions, dialog guard result).

## Profile safety guarantees

- Session id comes from `CLAUDE_CODE_SESSION_ID`; missing -> refuse.
- The target is the nearest ancestor process whose cmdline is the Claude Code CLI.
- The config dir is `CLAUDE_CONFIG_DIR` read from the TARGET's environment (only that key;
  nothing else of the environment is read or logged), default `~/.claude`.
- The transcript `<configdir>/projects/<cwd slug>/<id>.jsonl` must exist; otherwise a search
  in THIS config dir must find exactly one `<id>.jsonl`. 0 or more than 1 -> refuse. There
  is never a fallback to `--continue` or to another profile.
- Refuses when the session descriptor of the target names a different session, or when
  another live process appears to hold the same session (two processes on one session
  would interleave the transcript).
- The relaunch exports the same `CLAUDE_CONFIG_DIR` (or unsets it for the default profile).

## Relaunch command and the bypass caveat

`--resume` does NOT restore `bypassPermissions`, `--mcp-config`, `--settings`,
`--plugin-dir`, `--fallback-model` or `--add-dir`. So the helper rebuilds the original
argv from `/proc/<pid>/cmdline` - which already holds the alias-EXPANDED argv, so shell
aliases (e.g. one that adds `--dangerously-skip-permissions`) are covered without reading
any shell config. It keeps every original flag with its value, drops `-r/--resume`,
`-c/--continue`, `-p/--print`, `--session-id`, `--fork-session`, `--worktree`, `--tmux`
and positional prompts, and appends `--resume <session-id> <wake prompt>`. The wake prompt
is ALWAYS passed.

Permission mode changed DURING the session (Shift+Tab, `/permissions`) is not in argv. The
`credo-permission-mode-record.sh` hook (SessionStart + UserPromptSubmit) records the live
`permission_mode` per session in `<configdir>/credo/session-mode/<session-id>`, and the
helper restores it:

- recorded `bypassPermissions`, argv has no bypass -> `--permission-mode bypassPermissions`
- argv starts in bypass (`--dangerously-skip-permissions` or `--permission-mode
  bypassPermissions` / `--permission-mode=bypassPermissions`) but a lower mode is recorded
  (the user switched down during the session) -> the bypass flags are replaced by
  `--allow-dangerously-skip-permissions` (bypass stays reachable via Shift+Tab, as before)
  plus `--permission-mode <recorded>` (none for `default`), so the session starts exactly
  in the recorded mode with no ambiguous double flags
- recorded other non-default mode, argv has no `--permission-mode` -> `--permission-mode <mode>`
- nothing recorded -> argv as-is (a mode is never invented)
- it never escalates: bypass is only added when THIS session's record says bypass.

`check` shows the result in its `permission:` line.

## Relaunch methods (auto, in this order)

1. **tmux** - the target runs in tmux (`TMUX` + `TMUX_PANE` in its environment) and `tmux`
   is on PATH: after the old process exited, `clear; bash '<launcher>'` is typed into the
   SAME pane (works in fish and bash).
2. **wt** - WSL with `wt.exe` reachable: a new Windows Terminal tab
   (`wt.exe -w 0 new-tab wsl.exe -d <distro> --cd <cwd> -- ...`).
3. **x11** - native Linux GUI (`DISPLAY`/`WAYLAND_DISPLAY`) with `x-terminal-emulator`,
   `gnome-terminal` or `konsole`: a new terminal window.
4. none -> refuse: "no way to bring the session back; not restarting" (ntfy).

All methods run one generated launcher `<configdir>/credo/self-restart-launch.sh` (unsets
`CLAUDECODE`/`CLAUDE_CODE_*`, sets the profile, `cd`s to the cwd, `exec`s claude). `--method
tmux|wt|x11` forces a method (mainly for tests).

## "Resume from summary" dialog

Claude Code may show a stale-resume dialog ("Resume from summary (recommended)") before
the first message when a session was idle for a long time with a large context. Layers:

1. Primary: the dialog is only checked when there is NO initial message - the relaunch
   always passes the wake prompt, so it is skipped.
2. Watcher fallback for the first ~20 s: tmux relaunches poll `tmux capture-pane`; a new
   window runs the relaunch inside a fresh tmux session (`credo-<id>-<n>`) when tmux is
   installed; without tmux the launcher wraps claude in the `relaunch-pty` passthrough. On
   "Resuming the full session will consume a substantial portion" (or "Resume full session
   as-is") it answers ONCE with **Escape**, which dismisses the dialog and resumes the FULL
   session without compacting and without persisting anything. Enter would pick the
   default "Resume from summary" and compact the session, so it is never sent. "Don't ask
   me again" is never chosen (it writes a global config flag). The dialog text and keys
   are undocumented (taken from Claude Code 2.1.294), so this is a fallback only. The
   watcher matches the English text only, because Claude Code 2.1.294 ships its TUI in
   English only (the binary contains no German dialog strings; the `language` setting
   only affects Claude's replies). The positional-prompt layer is language-independent;
   if a future Claude Code version localizes the TUI, the watcher patterns must be
   extended.
3. Final safety net: the peer wake message and ntfy.

## Plugin update (`--update`)

Updates only happen when `run --update` is passed. The helper never changes `autoUpdate`
settings or `known_marketplaces.json`; it only calls the plugin CLI, with the Claude
session variables (`CLAUDECODE`, `CLAUDE_CODE_*`) removed and `CLAUDE_CONFIG_DIR` kept:

1. `claude plugin list --json` (versions before),
2. `claude plugin marketplace update <m>` for each allowlisted marketplace,
3. `claude plugin update <plugin>@<m> -y` for each installed plugin the allowlist covers,
4. `claude plugin list --json` again (versions after).

Every plugin's version before -> after goes to the log and the marker, and the wake prompt
carries a compact summary like `updated: credo 0.69.0 -> 0.70.0; unchanged: dogma`, or
`no plugin updates` when nothing changed.

Allowlist: credo config key `self_update.marketplaces` (the normal credo config cascade),
a mapping marketplace -> `"*"` or a list of plugin names:

```yaml
self_update:
  marketplaces:
    marcel-bich-claude-marketplace: "*"
    some-other-marketplace: [plugin-a]
```

Default when unset: only the marketplace credo itself was installed from. Plugins of other
marketplaces are never touched. Widening to more (or all) marketplaces is possible AT YOUR
OWN RISK - an update pulls whatever those marketplaces publish, unreviewed.

## Peer safety net (executed by the agent, not the script)

Before `run`, if another peer session is reachable (`ListAgents`), send it this message
via `SendMessage` - keep the 1-minute wait instruction, it is essential: a cross-session
message only wakes the session if it arrives AFTER the resumed session is running; a reply
sent immediately would land before the restart and be lost.

```
[urgent] I am restarting now for cc-up (self-restart). Please WAIT ABOUT 1 MINUTE, then send me one short wake message (e.g. 'wake up, continue') - only a message arriving after my resume wakes me. If I do not answer within 5 minutes after your wake message, notify the owner.
```

`check` prints the same template.

## Typical flow

```bash
python3 ${CLAUDE_PLUGIN_ROOT}/scripts/credo-self-restart.py check --update
# read the plan; send the peer message if a peer is reachable
# interactive: ask via the Ask tool first; only after the user's explicit yes:
python3 ${CLAUDE_PLUGIN_ROOT}/scripts/credo-self-restart.py run --user-confirmed --update --reason "cc-up"
# end the turn immediately

# autonomous mode: no Ask, announced 5 minutes ahead (ntfy + transcript line)
python3 ${CLAUDE_PLUGIN_ROOT}/scripts/credo-self-restart.py run --announce 300 --update --reason "cc-up"
# wrap up and end the turn before the scheduled time

# cancel during the announce period
python3 ${CLAUDE_PLUGIN_ROOT}/scripts/credo-self-restart.py cancel
```

After the resume: `python3 ${CLAUDE_PLUGIN_ROOT}/scripts/credo-self-restart.py status`.
