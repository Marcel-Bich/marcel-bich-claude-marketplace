#!/usr/bin/env python3
"""credo-self-restart.py - let a running Claude Code session restart itself (e.g. to
apply plugin updates, "cc-up") and resume EXACTLY the same session in the SAME
profile, continuing without a human prompt.

Subcommands
-----------
  check  (default) dry run: gather and validate everything, print the plan, change
         nothing. Exit 1 with a clear reason when a precondition fails.
  run --no-background-work [--user-confirmed] [--announce SECONDS] [--update]
      [--reason TEXT] [--delay SECONDS] [--method M]
         BACKGROUND GUARD (exit 3, nothing started): --no-background-work is required;
         the agent passes it only after it checked itself that none of its own
         background subagents, background shells / monitors or pending task
         notifications are still running (a restart would kill them).
         OWNER RULE GUARD first: run refuses (exit 3, nothing started) unless
           a) --user-confirmed: the user said yes via the Ask tool in this
              interactive session (never pass it without that answer), or
           b) the credo session mode of THIS session is "autonomous" and
              --announce is >= 300 seconds (default 300 when not user-confirmed).
         An unannounced restart outside autonomous mode could discard a prompt the
         user is typing. Then it validates exactly like check. On failure: nothing
         is stopped, an ntfy push is sent (when configured) and the exit code is 1.
         On success: a fully detached worker (own session, stdio to the log file) is
         spawned and this call returns at once. With an announce period it first
         prints the announcement and sends an ntfy push (reason + cancel command).
         The worker waits --announce + --delay (re-checking the marker for a
         cancel), in tmux then waits until the pane is idle with an EMPTY input field,
         no dialog and no background work in the footer (credo_pane_guard on the
         session's own tmux socket, pane ownership re-checked on every probe; timeout
         CREDO_SELF_RESTART_IDLE_TIMEOUT, default 1800 s, then it gives up without
         stopping; the target exiting meanwhile aborts without relaunch), stops the target Claude (tmux C-c twice, else SIGINT twice then
         SIGTERM, NEVER SIGKILL), waits until it is gone, optionally runs the plugin
         update step, relaunches the same session with a wake prompt and writes a
         marker file.
  cancel mark a pending restart as cancelled and terminate its waiting worker. Too
         late once the worker started stopping the target (exit 1 then).
  status print the state (pending/cancelled/stopping/relaunched/failed) with the
         scheduled time, the last marker and the tail of the log.
  relaunch-pty -- ARGV...
         internal: run ARGV in a pty passthrough that answers the "Resume from
         summary" dialog once with Escape (used by the launcher when no tmux exists).

The relaunch always passes the wake prompt (which skips the stale-resume dialog),
restores the permission mode recorded by hooks/credo-permission-mode-record.sh
(never escalating), and with --update records every plugin version before -> after.

Profile safety
--------------
  - session id = CLAUDE_CODE_SESSION_ID (missing -> fail)
  - target = first ancestor whose cmdline is the Claude Code CLI
  - config dir = CLAUDE_CONFIG_DIR from the TARGET's environment (only that key)
  - the transcript <configdir>/projects/<slug(cwd)>/<id>.jsonl must exist; else a
    glob over <configdir>/projects/*/<id>.jsonl must give EXACTLY one match. There
    is never a fallback to --continue or to another profile.
  - another live process holding the same session -> fail.

Relaunch methods (auto, in this order): tmux (same pane), wt (WSL: new Windows
Terminal tab), x11 (native Linux GUI: new terminal window). None -> fail. Every
method runs one generated bash launcher script (cd + profile env + exec claude), so
the only thing typed into a shell (fish or bash) is "bash '<launcher>'".

Plugin update allowlist: credo config key self_update.marketplaces, a mapping
marketplace -> "*" or a list of plugin names. Unset -> only the marketplace credo was
installed from.

Reading another process's environment extracts ONLY the needed keys; the full
environment is never logged or printed.

Env overrides (tests): CREDO_SELF_RESTART_SESSION_ID, CREDO_SELF_RESTART_TARGET_PID,
CREDO_SELF_RESTART_NTFY_URL ("off" or a full URL), CREDO_SELF_RESTART_OWN_MARKETPLACE,
CREDO_SELF_RESTART_STOP_TIMEOUT, CREDO_SELF_RESTART_SIGNAL_PAUSE, CREDO_SELF_RESTART_KEY_PAUSE,
CREDO_SELF_RESTART_CMD_TIMEOUT, CREDO_SELF_RESTART_CONFIG_SH,
CREDO_SELF_RESTART_MIN_ANNOUNCE (TEST-ONLY: scales the 300 s autonomous minimum down;
never set it in a real session). The credo session mode is read from
${CREDO_SESSION_MODES_DIR:-<configdir>/credo/session-modes}/<session id>, the same file
hooks/session-mode-set.sh writes; missing/unreadable = not autonomous.

Python 3 stdlib only.
"""

import argparse
import datetime
import fcntl
import glob
import json
import os
import re
import shlex
import shutil
import signal
import subprocess
import sys
import time

SCRIPT_PATH = os.path.abspath(__file__)
SCRIPT_DIR = os.path.dirname(SCRIPT_PATH)
sys.path.insert(0, SCRIPT_DIR)
import credo_pane_guard as pane_guard  # noqa: E402
import credo_pane_wake as pane_wake  # noqa: E402
DEFAULT_MARKETPLACE = "marcel-bich-claude-marketplace"
PROMPT_TAG = "[credo-self-restart]"
# Owner rule: an autonomous self-restart is announced at least this long ahead.
MIN_ANNOUNCE = 300.0
EXIT_GUARD = 3
# Background rule: the agent's own knowledge is the primary gate (a restart kills its
# background subagents and shells); the pane footer check is only an extra guard.
BACKGROUND_REFUSAL = (
    "refused by the background rule: pass --no-background-work, and only after you "
    "checked yourself that none of your own background subagents, background shells / "
    "monitors or pending task notifications are still running (e.g. ListAgents shows no "
    "running subagent of this session, no own background Bash is still running). If some "
    "are, wait for them to finish (never stop them) and run again.")
ENV_KEYS = ("CLAUDE_CONFIG_DIR", "TMUX", "TMUX_PANE", "WSL_DISTRO_NAME",
            "DISPLAY", "WAYLAND_DISPLAY")
INTERPRETERS = ("node", "nodejs", "bun", "deno")
X11_TERMINALS = ("x-terminal-emulator", "gnome-terminal", "konsole")

# "Resume from summary" (stale resume) dialog. Claude Code 2.1.x only checks for it
# when there is NO initial message, so the primary fix is that the relaunch ALWAYS
# passes the wake prompt as positional argument after --resume <id>. Fallback: the relaunch watches the first DIALOG_WATCH seconds of output and, if
# the dialog still appears, answers it ONCE with Escape. The default-focused option
# is "Resume from summary (recommended)" - Enter would COMPACT the session, which is
# wrong. Escape dismisses the dialog and resumes the full session without
# compacting and without persisting anything. "Don't ask me again" is never chosen
# (it writes a global config flag). Text and keys come from the 2.1.294 binary and
# are undocumented, so this stays a best-effort fallback.
DIALOG_RE = re.compile(r"Resuming the full session will consume a substantial portion"
                       r"|Resume full session as-is", re.I)
DIALOG_ANSWER_TMUX_KEYS = ["Escape"]
DIALOG_ANSWER_PTY_BYTES = b"\x1b"
DIALOG_WATCH = 20.0
ANSI_RE = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(\x07|\x1b\\)|\x1b[@-_]")

# Claude Code CLI flags (2.1.x) that take a value. Anything not listed here is
# treated as a boolean flag and kept as-is.
VALUE_FLAGS = {
    "--agent", "--agents", "--append-system-prompt", "--append-system-prompt-file",
    "--system-prompt", "--system-prompt-file", "--system-prompt-snapshot",
    "--autocompact", "--debug-file", "--effort", "--environment",
    "--fallback-model", "--input-format", "--output-format", "--json-schema",
    "--max-budget-usd", "--max-turns", "--model", "-n", "--name",
    "--permission-mode", "--permission-prompts", "--permission-prompt-tool",
    "--plugin-dir", "--plugin-url", "--remote-control-session-name-prefix",
    "--session-id", "--setting-sources", "--settings",
}
# Variadic flags consume every following token that does not start with "-".
VARIADIC_FLAGS = {
    "--add-dir", "--allowedTools", "--allowed-tools", "--disallowedTools",
    "--disallowed-tools", "--betas", "--file", "--mcp-config", "--tools",
}
# Optional-value flags consume the next token only when it does not start with "-".
OPTIONAL_VALUE_FLAGS = {
    "-r", "--resume", "-d", "--debug", "--cloud", "--from-pr",
    "--prompt-suggestions", "--remote-control", "--teleport", "-w", "--worktree",
}
# Flags that select or create a DIFFERENT session (or a non-interactive run) and so
# must never be carried into the relaunch. --worktree/--tmux would create a new
# worktree; the resumed process already starts in the original cwd.
DROP_FLAGS = {
    "-r", "--resume", "-c", "--continue", "-p", "--print", "--session-id",
    "--fork-session", "--from-pr", "--teleport", "--cloud", "--bg", "--background",
    "--desktop", "-w", "--worktree", "--tmux",
}


# --- small helpers -------------------------------------------------------------

def now_iso():
    return datetime.datetime.now().astimezone().isoformat(timespec="seconds")


def log(msg):
    sys.stderr.write("[credo-self-restart %s] %s\n" % (now_iso(), msg))
    sys.stderr.flush()


def env_float(name, default):
    try:
        return float(os.environ.get(name, default))
    except ValueError:
        return float(default)


def read_cmdline(pid):
    try:
        with open("/proc/%d/cmdline" % pid, "rb") as fh:
            raw = fh.read()
    except OSError:
        return []
    return [p.decode("utf-8", "replace") for p in raw.split(b"\0") if p != b""] \
        if raw else []


def read_exe(pid):
    try:
        return os.readlink("/proc/%d/exe" % pid)
    except OSError:
        return ""


def read_ppid(pid):
    st = read_stat(pid)
    return int(st[1]) if st else 0


def read_stat(pid):
    """Fields of /proc/<pid>/stat after the comm field: [state, ppid, ...]."""
    try:
        with open("/proc/%d/stat" % pid) as fh:
            data = fh.read()
    except OSError:
        return None
    return data.rsplit(")", 1)[-1].split()


def proc_start(pid):
    st = read_stat(pid)
    return st[19] if st and len(st) > 19 else ""


def read_environ_keys(pid, keys):
    """Return {key: value} for ONLY the requested keys from /proc/<pid>/environ.
    None when the environ is not readable. Nothing else is kept or logged."""
    try:
        with open("/proc/%d/environ" % pid, "rb") as fh:
            raw = fh.read()
    except OSError:
        return None
    wanted = {k.encode() for k in keys}
    out = {}
    for item in raw.split(b"\0"):
        k, sep, v = item.partition(b"=")
        if sep and k in wanted:
            out[k.decode()] = v.decode("utf-8", "replace")
    return out


def alive(pid, start=""):
    """True if pid exists, is not a zombie and (when given) has the same start time."""
    st = read_stat(pid)
    if not st or st[0] in ("Z", "X"):
        return False
    if start and len(st) > 19 and st[19] != start:
        return False
    return True


def claude_exe_end(argv, exe=""):
    """Index of the last token of the executable part when argv is the Claude Code
    CLI, else None. Native: argv[0] is "claude" (or the exe lives under
    .../claude/versions/). Script install: argv[0] is node/bun/deno and argv[1] is
    the claude script."""
    if not argv:
        return None
    base0 = os.path.basename(argv[0])
    if base0 == "claude" or "/claude/versions/" in exe:
        return 0
    if len(argv) > 1 and base0.split(".")[0] in INTERPRETERS:
        a1 = argv[1]
        if (os.path.basename(a1) == "claude" or "claude-code" in a1
                or "@anthropic-ai" in a1):
            return 1
    return None


def is_claude(pid):
    return claude_exe_end(read_cmdline(pid), read_exe(pid)) is not None


def ancestors(pid, limit=64):
    out, seen = [], set()
    while pid > 1 and pid not in seen and len(out) < limit:
        seen.add(pid)
        out.append(pid)
        pid = read_ppid(pid)
    return out


def pane_owner_error(pane, socket, target, start):
    """None when tmux `pane` (on the server `socket`) belongs to the target Claude:
    the pane's process is the target or an ancestor of it (the shell the pane
    started) AND no other Claude process runs between the two - a nested claude
    started from inside another session's pane must never type into (or stop) the
    outer session shown in that pane. Else the reason."""
    if not alive(target, start):
        return "the Claude process %d is gone" % target
    info = pane_guard.pane_info(pane, socket)
    if info is None:
        return "tmux pane %s not found on the server of this session" % pane
    chain = ancestors(target)
    if info["pid"] not in chain:
        return ("tmux pane %s belongs to pid %d, which is not this Claude process (pid %d) "
                "nor one of its ancestors - refusing to use it" % (pane, info["pid"], target))
    for pid in chain[1:chain.index(info["pid"]) + 1]:
        if is_claude(pid):
            return ("another Claude process (pid %d) runs between tmux pane %s and this "
                    "Claude process (pid %d); the pane shows that other session - refusing "
                    "to use it" % (pid, pane, target))
    return None


def slug(cwd):
    """Claude Code project dir name: every non-alphanumeric char -> "-". Names over
    200 chars get a hash suffix in Claude Code; the glob fallback covers those."""
    s = re.sub(r"[^A-Za-z0-9]", "-", cwd)
    return s[:200] if len(s) > 200 else s


def find_transcript(config_dir, cwd, sid):
    """(path, error). Exact slug first, then a unique glob in THIS config dir only."""
    exact = os.path.join(config_dir, "projects", slug(cwd), sid + ".jsonl")
    if os.path.isfile(exact):
        return exact, None
    matches = sorted(glob.glob(os.path.join(glob.escape(config_dir), "projects", "*",
                                            glob.escape(sid) + ".jsonl")))
    if len(matches) == 1:
        return matches[0], None
    if not matches:
        return None, "transcript %s.jsonl not found under %s/projects" % (sid, config_dir)
    return None, "transcript %s.jsonl is ambiguous (%d matches under %s/projects)" % (
        sid, len(matches), config_dir)


def read_recorded_mode(config_dir, sid):
    """Live permission mode recorded by hooks/credo-permission-mode-record.sh for
    THIS session id, or None when missing/unreadable/invalid."""
    try:
        with open(os.path.join(config_dir, "credo", "session-mode", sid)) as fh:
            mode = fh.read().strip()
    except OSError:
        return None
    return mode if re.fullmatch(r"[A-Za-z]+", mode or "") else None


def read_credo_mode(config_dir, sid):
    """credo session mode (active/passive/autonomous) of THIS session as written by
    hooks/session-mode-set.sh, or None when missing/unreadable/invalid."""
    if not sid or not re.fullmatch(r"[A-Za-z0-9._-]+", sid) or sid in (".", ".."):
        return None
    modes = os.environ.get("CREDO_SESSION_MODES_DIR") or \
        os.path.join(config_dir, "credo", "session-modes")
    try:
        with open(os.path.join(modes, sid)) as fh:
            mode = fh.readline().strip()
    except OSError:
        return None
    return mode if re.fullmatch(r"[a-z]+", mode or "") else None


def min_announce():
    """300 s; CREDO_SELF_RESTART_MIN_ANNOUNCE is a TEST-ONLY override."""
    return max(0.0, env_float("CREDO_SELF_RESTART_MIN_ANNOUNCE", MIN_ANNOUNCE))


def fmt_num(x):
    return ("%d" % x) if float(x) == int(x) else ("%g" % x)


def fmt_duration(seconds):
    s = float(seconds)
    if s >= 60 and s % 60 == 0:
        n = int(s // 60)
        return "%d minute%s" % (n, "" if n == 1 else "s")
    return "%s second%s" % (fmt_num(s), "" if s == 1 else "s")


def owner_guard(plan, user_confirmed, announce):
    """(announce_seconds, error). Owner rule: without the user's explicit Ask-tool yes
    (--user-confirmed) a self-restart is only allowed in credo autonomous mode and
    only with an announcement of at least min_announce() seconds."""
    if announce is not None and announce < 0:
        return None, "--announce must not be negative"
    if user_confirmed:
        return (announce if announce is not None else 0.0), None
    minimum = min_announce()
    announce = minimum if announce is None else announce
    mode = plan.get("credo_mode")
    if mode != "autonomous":
        return None, (
            "refused by the owner rule: the credo session mode of session %s is %s, not "
            "autonomous. Outside autonomous mode a self-restart needs the user's explicit "
            "yes via the Ask tool first (an unannounced restart could discard a prompt "
            "the user is typing); only after that yes run again with --user-confirmed."
            % (plan.get("session_id") or "?", "'%s'" % mode if mode else "not set"))
    if announce < minimum:
        return None, (
            "refused by the owner rule: an autonomous self-restart must be announced at "
            "least %s ahead (--announce %d or more, got %s)"
            % (fmt_duration(minimum), int(minimum), fmt_num(announce)))
    return announce, None


def apply_mode(flags, recorded):
    """(flags, note). Restore the recorded mode of this session; never escalate.
    - recorded bypassPermissions and no bypass in argv -> --permission-mode
      bypassPermissions (an existing --permission-mode value is replaced).
    - argv starts in bypass (--dangerously-skip-permissions or --permission-mode
      bypassPermissions) and a lower mode is recorded -> the bypass flags are replaced
      by --allow-dangerously-skip-permissions plus --permission-mode <recorded>
      (none for "default").
    - recorded other non-default mode and no --permission-mode -> append it.
    - nothing recorded -> argv as-is. Bypass is added ONLY when recorded."""
    flags = list(flags)
    pm_idx = None
    has_bypass = "--dangerously-skip-permissions" in flags
    for i, tok in enumerate(flags):
        if tok == "--permission-mode" and i + 1 < len(flags):
            pm_idx = i + 1
        elif tok.startswith("--permission-mode="):
            pm_idx = i
    if pm_idx is not None:
        val = flags[pm_idx].split("=", 1)[1] if flags[pm_idx].startswith("--") \
            else flags[pm_idx]
        has_bypass = has_bypass or val == "bypassPermissions"
    if not recorded:
        return flags, "none recorded (argv as-is)"
    if recorded == "bypassPermissions":
        if has_bypass:
            return flags, "bypassPermissions (already in argv)"
        if pm_idx is not None:
            if flags[pm_idx].startswith("--"):
                flags[pm_idx] = "--permission-mode=bypassPermissions"
            else:
                flags[pm_idx] = "bypassPermissions"
        else:
            flags += ["--permission-mode", "bypassPermissions"]
        return flags, "bypassPermissions (restored)"
    if has_bypass:
        # argv starts in bypass (--dangerously-skip-permissions or --permission-mode
        # bypassPermissions) but the user lowered the mode during the session. Start in
        # the recorded mode and keep bypass reachable (Shift+Tab) like before, with no
        # ambiguous double flags.
        allow = "--allow-dangerously-skip-permissions"
        out, i = [], 0
        while i < len(flags):
            f = flags[i]
            if f in ("--dangerously-skip-permissions", allow):
                i += 1
                continue
            if f == "--permission-mode" and i + 1 < len(flags):
                i += 2
                continue
            if f.startswith("--permission-mode="):
                i += 1
                continue
            out.append(f)
            i += 1
        out.append(allow)
        if recorded != "default":
            out += ["--permission-mode", recorded]
        return out, ("%s (restored; bypass in argv -> %s, bypass stays reachable)"
                     % (recorded, allow))
    if recorded == "default":
        return flags, "default (argv as-is)"
    if pm_idx is None:
        flags += ["--permission-mode", recorded]
        return flags, "%s (restored)" % recorded
    return flags, "%s recorded, argv already sets --permission-mode (as-is)" % recorded


def rebuild_argv(argv, exe_end, sid, prompt, recorded_mode=None):
    """Keep the executable part and all original flags (with their values), drop
    resume/continue/print and other session-selecting flags plus positional prompt
    arguments, restore the recorded permission mode, then append
    --resume <sid> <prompt>. Relies only on /proc cmdline (alias-expanded argv),
    never on shell config."""
    return rebuild_argv_note(argv, exe_end, sid, prompt, recorded_mode)[0]


def rebuild_argv_note(argv, exe_end, sid, prompt, recorded_mode=None):
    out = list(argv[:exe_end + 1])
    rest = argv[exe_end + 1:]
    i = 0
    while i < len(rest):
        tok = rest[i]
        i += 1
        if tok == "--":
            break  # everything after is positional
        if not tok.startswith("-") or tok == "-":
            continue  # positional prompt -> drop
        name, has_eq, _ = tok.partition("=")
        values = []
        if not has_eq:
            if name in VALUE_FLAGS:
                if i < len(rest):
                    values.append(rest[i])
                    i += 1
            elif name in VARIADIC_FLAGS:
                while i < len(rest) and not rest[i].startswith("-"):
                    values.append(rest[i])
                    i += 1
            elif name in OPTIONAL_VALUE_FLAGS:
                if i < len(rest) and not rest[i].startswith("-"):
                    values.append(rest[i])
                    i += 1
        if name in DROP_FLAGS:
            continue
        out.append(tok)
        out.extend(values)
    head = out[:exe_end + 1]
    flags, note = apply_mode(out[exe_end + 1:], recorded_mode)
    return head + flags + ["--resume", sid, prompt], note


def wake_prompt(reason, update_summary):
    return ("%s Resumed after a self-restart (reason: %s; plugin update: %s). "
            "Continue where you left off. If you asked a peer to wake you (peer safety net), "
            "send that peer one short '[info] resumed' message now so it stops waiting." %
            (PROMPT_TAG, reason, update_summary))


PEER_TEMPLATE = (
    "[urgent] I am restarting now for cc-up (self-restart). Please WAIT ABOUT 1 "
    "MINUTE, then send me one short wake message starting with [credo-wake] (e.g. "
    "'[credo-wake] wake up, continue') - only a message arriving after my resume wakes "
    "me. I confirm it with one short '[info] resumed' reply. If that confirmation does "
    "not arrive within 5 minutes after your wake message, notify the owner."
)


# --- target discovery ----------------------------------------------------------

def find_target():
    """(pid, argv, exe_end, error)."""
    override = os.environ.get("CREDO_SELF_RESTART_TARGET_PID")
    if override:
        try:
            pids = [int(override)]
        except ValueError:
            return None, None, None, "CREDO_SELF_RESTART_TARGET_PID is not a pid"
    else:
        pids = []
        pid = os.getppid()
        seen = set()
        while pid > 1 and pid not in seen and len(seen) < 64:
            seen.add(pid)
            pids.append(pid)
            pid = read_ppid(pid)
    for pid in pids:
        argv = read_cmdline(pid)
        end = claude_exe_end(argv, read_exe(pid))
        if end is not None and alive(pid):
            return pid, argv, end, None
    return None, None, None, "no Claude Code process found in the parent chain"


def other_holders(config_dir, sid, target):
    """Live pids other than target that appear to hold the same session."""
    found = set()
    for path in glob.glob(os.path.join(glob.escape(config_dir), "sessions", "*.json")):
        try:
            with open(path) as fh:
                d = json.load(fh)
        except (OSError, ValueError):
            continue
        if not isinstance(d, dict) or d.get("sessionId") != sid:
            continue
        if d.get("credoPeerLan") or d.get("credoPeerBridge"):
            continue  # mirrored peer descriptors, not a local holder
        pid = d.get("pid")
        if isinstance(pid, int) and pid != target and alive(pid):
            found.add(pid)
    for entry in os.listdir("/proc"):
        if not entry.isdigit():
            continue
        pid = int(entry)
        if pid in (target, os.getpid()):
            continue
        argv = read_cmdline(pid)
        if claude_exe_end(argv, read_exe(pid)) is None:
            continue
        if any(sid in a for a in argv) and alive(pid):
            found.add(pid)
    return sorted(found)


def descriptor_mismatch(config_dir, target, sid):
    """Error text when <configdir>/sessions/<target>.json names another session."""
    path = os.path.join(config_dir, "sessions", "%d.json" % target)
    try:
        with open(path) as fh:
            d = json.load(fh)
    except (OSError, ValueError):
        return None
    other = d.get("sessionId") if isinstance(d, dict) else None
    if other and other != sid:
        return "session descriptor %s names session %s, not %s" % (path, other, sid)
    return None


# --- relaunch method -----------------------------------------------------------

def is_wsl(tenv):
    if tenv.get("WSL_DISTRO_NAME") or os.environ.get("WSL_DISTRO_NAME"):
        return True
    try:
        with open(os.environ.get("CREDO_SELF_RESTART_PROC_VERSION", "/proc/version")) as fh:
            return "microsoft" in fh.read().lower()
    except OSError:
        return False


def choose_method(tenv, forced=None, guard_name="credo"):
    """(method, details, error). details carries what the invocation needs,
    including the dialog guard: "pane" (tmux pane), "tmux_session" (new window that
    runs the relaunch inside a fresh tmux session) or "pty" (no tmux at all)."""
    order = [forced] if forced else ["tmux", "wt", "x11"]
    reasons = []
    have_tmux = bool(shutil.which("tmux"))
    window_guard = {"tmux_session": guard_name} if have_tmux else {"pty": True}
    for m in order:
        if m == "tmux":
            if tenv.get("TMUX") and tenv.get("TMUX_PANE") and have_tmux:
                det = {"pane": tenv["TMUX_PANE"]}
                sock = pane_guard.socket_from_tmux_env(tenv.get("TMUX"))
                if sock:
                    det["socket"] = sock  # the server of THIS session, not the default
                return m, det, None
            reasons.append("tmux: target has no TMUX/TMUX_PANE or tmux not on PATH")
        elif m == "wt":
            distro = tenv.get("WSL_DISTRO_NAME") or os.environ.get("WSL_DISTRO_NAME", "")
            if is_wsl(tenv) and distro and shutil.which("wt.exe"):
                return m, dict(window_guard, distro=distro), None
            reasons.append("wt: not WSL, no WSL_DISTRO_NAME or wt.exe not reachable")
        elif m == "x11":
            if tenv.get("DISPLAY") or tenv.get("WAYLAND_DISPLAY"):
                for t in X11_TERMINALS:
                    if shutil.which(t):
                        return m, dict(window_guard, terminal=t), None
            reasons.append("x11: no DISPLAY/WAYLAND_DISPLAY or no terminal emulator")
        else:
            reasons.append("unknown method %s" % m)
    return None, None, ("no way to bring the session back; not restarting (%s)"
                        % "; ".join(reasons))


def guard_kind(details):
    if not details:
        return "-"
    if "pane" in details:
        return "tmux pane %s (capture-pane watch)" % details["pane"]
    if "tmux_session" in details:
        return "new tmux session %s (capture-pane watch)" % details["tmux_session"]
    return "pty passthrough (relaunch-pty)"


def capture_pane(target, socket=None):
    try:
        r = subprocess.run(pane_guard.tmux_base(socket) + ["capture-pane", "-p", "-t", target],
                           capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        return None
    return r.stdout if r.returncode == 0 else None


def dialog_guard_tmux(target, socket=None):
    """Poll the pane for the resume-from-summary dialog and answer it once.
    Returns "answered", "not seen" or "pane unavailable"."""
    end = time.time() + env_float("CREDO_SELF_RESTART_DIALOG_WATCH", DIALOG_WATCH)
    seen_pane = False
    while time.time() < end:
        text = capture_pane(target, socket)
        if text is not None:
            seen_pane = True
            if any(DIALOG_RE.search(line) for line in text.splitlines()):
                subprocess.run(pane_guard.tmux_base(socket) + ["send-keys", "-t", target]
                               + DIALOG_ANSWER_TMUX_KEYS, capture_output=True, timeout=10)
                log("resume-from-summary dialog detected in %s; answered %s"
                    % (target, DIALOG_ANSWER_TMUX_KEYS))
                return "answered"
        time.sleep(0.5)
    return "not seen" if seen_pane else "pane unavailable"


def relaunch_pty(argv):
    """Run argv in a pty and proxy stdin/stdout/winsize transparently. Watch only
    the first DIALOG_WATCH seconds of output for the resume-from-summary dialog and
    inject the answer once. Returns the child's exit code."""
    import fcntl
    import pty
    import select
    import termios
    import tty
    if not argv:
        return 2
    watch = env_float("CREDO_SELF_RESTART_DIALOG_WATCH", DIALOG_WATCH)
    stdin_fd, stdout_fd = sys.stdin.fileno(), sys.stdout.fileno()
    pid, master = pty.fork()
    if pid == 0:
        try:
            os.execvp(argv[0], argv)
        finally:
            os._exit(127)

    def sync_winsize(*_):
        try:
            ws = fcntl.ioctl(stdin_fd, termios.TIOCGWINSZ, b"\0" * 8)
            fcntl.ioctl(master, termios.TIOCSWINSZ, ws)
        except OSError:
            pass

    saved = None
    if os.isatty(stdin_fd):
        sync_winsize()
        signal.signal(signal.SIGWINCH, sync_winsize)
        try:
            saved = termios.tcgetattr(stdin_fd)
            tty.setraw(stdin_fd)
        except termios.error:
            saved = None
    deadline = time.time() + watch
    answered = False
    buf = ""
    fds = [master, stdin_fd]
    try:
        while True:
            try:
                ready, _, _ = select.select(fds, [], [], 0.5)
            except InterruptedError:
                continue
            if master in ready:
                try:
                    data = os.read(master, 65536)
                except OSError:
                    data = b""
                if not data:
                    break
                os.write(stdout_fd, data)
                if not answered and time.time() < deadline:
                    text = ANSI_RE.sub("", data.decode("utf-8", "replace"))
                    buf = (buf + text)[-8192:]
                    if any(DIALOG_RE.search(line) for line in buf.splitlines()):
                        os.write(master, DIALOG_ANSWER_PTY_BYTES)
                        answered = True
            if stdin_fd in ready:
                try:
                    data = os.read(stdin_fd, 65536)
                except OSError:
                    data = b""
                if data:
                    os.write(master, data)
                else:
                    fds = [master]  # stdin closed; keep proxying output
    finally:
        if saved is not None:
            termios.tcsetattr(stdin_fd, termios.TCSAFLUSH, saved)
    _, status = os.waitpid(pid, 0)
    if os.WIFEXITED(status):
        return os.WEXITSTATUS(status)
    return 128 + os.WTERMSIG(status) if os.WIFSIGNALED(status) else 1


def launcher_text(cwd, config_dir, config_explicit, argv, pty_wrap=False):
    lines = [
        "#!/bin/bash",
        "# credo self-restart launcher (generated, safe to delete)",
        'for __v in $(compgen -e); do case "$__v" in CLAUDECODE|CLAUDE_CODE_*) '
        'unset "$__v";; esac; done',
    ]
    if config_explicit:
        lines.append("export CLAUDE_CONFIG_DIR=%s" % shlex.quote(config_dir))
    else:
        lines.append("unset CLAUDE_CONFIG_DIR")
    lines.append("cd %s || exit 1" % shlex.quote(cwd))
    if pty_wrap:
        argv = [sys.executable, SCRIPT_PATH, "relaunch-pty", "--"] + list(argv)
    lines.append("exec " + " ".join(shlex.quote(a) for a in argv))
    return "\n".join(lines) + "\n"


def invocation(method, details, launcher, cwd):
    if method == "tmux":
        # "clear;" works in fish and bash and empties the pane, so the dialog watch
        # does not match text left over from the old session
        return pane_guard.tmux_base(details.get("socket")) + ["send-keys", "-t", details["pane"],
                "clear; bash '%s'" % launcher, "Enter"]
    inner = ["bash", launcher]
    if details.get("tmux_session"):
        inner = ["tmux", "new-session", "-s", details["tmux_session"], "bash", launcher]
    if method == "wt":
        return ["wt.exe", "-w", "0", "new-tab", "wsl.exe", "-d", details["distro"],
                "--cd", cwd, "--"] + inner
    term = details["terminal"]
    if term == "gnome-terminal":
        return [term, "--"] + inner
    return [term, "-e"] + inner


# --- config, update, ntfy ------------------------------------------------------

def config_get(key, config_dir, config_explicit):
    sh = os.environ.get("CREDO_SELF_RESTART_CONFIG_SH",
                        os.path.join(SCRIPT_DIR, "credo-config.sh"))
    env = dict(os.environ)
    if config_explicit:
        env["CLAUDE_CONFIG_DIR"] = config_dir  # pick the TARGET profile's layer
    else:
        env.pop("CLAUDE_CONFIG_DIR", None)
    try:
        r = subprocess.run(["bash", sh, "get", key], env=env, capture_output=True,
                           text=True, timeout=20)
    except (OSError, subprocess.SubprocessError):
        return None
    if r.returncode != 0:
        return None
    return r.stdout.strip() or None


def own_marketplace():
    o = os.environ.get("CREDO_SELF_RESTART_OWN_MARKETPLACE")
    if o:
        return o
    parts = SCRIPT_PATH.split(os.sep)
    # .../plugins/cache/<marketplace>/credo/<version>/scripts/<this file>
    for i in range(len(parts) - 3):
        if parts[i] == "cache" and i > 0 and parts[i - 1] == "plugins" \
                and parts[i + 2] == "credo":
            return parts[i + 1]
    return DEFAULT_MARKETPLACE


def parse_allowlist(raw):
    """(mapping, error). raw is the JSON text credo-config.sh prints for a map."""
    if not raw:
        return {own_marketplace(): "*"}, None
    try:
        data = json.loads(raw)
    except ValueError:
        return None, "self_update.marketplaces is not a mapping"
    if not isinstance(data, dict) or not data:
        return None, "self_update.marketplaces is not a non-empty mapping"
    out = {}
    for m, v in data.items():
        if v == "*":
            out[str(m)] = "*"
        elif isinstance(v, list) and all(isinstance(x, str) for x in v):
            out[str(m)] = list(v)
        else:
            return None, "self_update.marketplaces.%s must be \"*\" or a list" % m
    return out, None


def plugins_to_update(plugin_list, allow):
    ids = []
    for p in plugin_list if isinstance(plugin_list, list) else []:
        pid = p.get("id") if isinstance(p, dict) else None
        if not isinstance(pid, str) or "@" not in pid:
            continue
        name, _, market = pid.rpartition("@")
        rule = allow.get(market)
        if rule is None:
            continue
        if rule == "*" or name in rule:
            if pid not in ids:
                ids.append(pid)
    return ids


def stripped_env(config_dir, config_explicit):
    env = {k: v for k, v in os.environ.items()
           if k != "CLAUDECODE" and not k.startswith("CLAUDE_CODE_")}
    if config_explicit:
        env["CLAUDE_CONFIG_DIR"] = config_dir
    else:
        env.pop("CLAUDE_CONFIG_DIR", None)
    return env


def run_cli(args, env, cwd):
    timeout = env_float("CREDO_SELF_RESTART_CMD_TIMEOUT", 180)
    try:
        r = subprocess.run(["claude"] + args, env=env, cwd=cwd, capture_output=True,
                           text=True, timeout=timeout, stdin=subprocess.DEVNULL)
        return r.returncode, r.stdout, r.stderr
    except subprocess.TimeoutExpired:
        return 124, "", "timeout after %ss" % timeout
    except OSError as exc:
        return 127, "", str(exc)


def plugin_list(env, cwd):
    rc, out, err = run_cli(["plugin", "list", "--json"], env, cwd)
    try:
        data = json.loads(out) if rc == 0 else None
    except ValueError:
        data = None
    if not isinstance(data, list):
        log("plugin list failed rc %d %s" % (rc, err.strip()[:200]))
        return None
    return data


def version_map(plist):
    out = {}
    for p in plist or []:
        if isinstance(p, dict) and isinstance(p.get("id"), str):
            out.setdefault(p["id"], str(p.get("version") or "?"))
    return out


def version_summary(targets, before, after):
    """Compact "updated: credo 0.69.0 -> 0.70.0; unchanged: dogma" or
    "no plugin updates"."""
    changed, same = [], []
    for pid in targets:
        name = pid.rpartition("@")[0]
        b, a = before.get(pid, "?"), after.get(pid, "?")
        if b != a:
            changed.append("%s %s -> %s" % (name, b, a))
        else:
            same.append(name)
    if not changed:
        return "no plugin updates"
    text = "updated: " + ", ".join(changed)
    if same:
        text += "; unchanged: " + ", ".join(same)
    return text


def run_update(plan):
    """Run the allowlisted plugin update. Never touches autoUpdate settings or
    known_marketplaces.json - it only calls the plugin CLI. Returns
    (summary, versions) where versions maps plugin id -> {before, after}; never
    raises."""
    env = stripped_env(plan["config_dir"], plan["config_explicit"])
    cwd = plan["cwd"]
    allow = plan["allowlist"]
    failures = []
    before_list = plugin_list(env, cwd)
    if before_list is None:
        return "failed (plugin list unavailable)", {}
    before = version_map(before_list)
    targets = plugins_to_update(before_list, allow)
    for m in allow:
        rc, _, err = run_cli(["plugin", "marketplace", "update", m], env, cwd)
        log("marketplace update %s -> rc %d %s" % (m, rc, err.strip()[:200]))
        if rc != 0:
            failures.append("marketplace %s" % m)
    for pid in targets:
        rc, _, err = run_cli(["plugin", "update", pid, "-y"], env, cwd)
        log("plugin update %s -> rc %d %s" % (pid, rc, err.strip()[:200]))
        if rc != 0:
            failures.append(pid)
    after = version_map(plugin_list(env, cwd) or [])
    versions = {pid: {"before": before.get(pid, "?"), "after": after.get(pid, "?")}
                for pid in targets}
    for pid, v in versions.items():
        log("version %s: %s -> %s" % (pid, v["before"], v["after"]))
    summary = version_summary(targets, before, after)
    if failures:
        summary += "; failed: " + ", ".join(failures)
    return summary, versions


def ntfy(title, body, config_dir, config_explicit, override_var="CREDO_SELF_RESTART_NTFY_URL",
         logger=None):
    """ntfy push of the self-* helpers (shared implementation in credo_pane_wake)."""
    pane_wake.ntfy(title, body, override_var,
                   lambda key: config_get(key, config_dir, config_explicit), logger or log)


# --- plan ----------------------------------------------------------------------

def gather(args):
    """(plan, errors). Read-only."""
    errors = []
    plan = {"reason": args.reason, "update": bool(args.update), "delay": args.delay}
    sid = (os.environ.get("CREDO_SELF_RESTART_SESSION_ID")
           or os.environ.get("CLAUDE_CODE_SESSION_ID") or "")
    if not sid:
        errors.append("no session id (CLAUDE_CODE_SESSION_ID is not set)")
    elif not re.fullmatch(r"[A-Za-z0-9._-]+", sid):
        errors.append("session id has unexpected characters")
    plan["session_id"] = sid
    pid, argv, exe_end, err = find_target()
    if err:
        errors.append(err)
        plan["config_dir"] = os.environ.get("CLAUDE_CONFIG_DIR") or \
            os.path.join(os.path.expanduser("~"), ".claude")
        plan["config_explicit"] = bool(os.environ.get("CLAUDE_CONFIG_DIR"))
        plan["credo_mode"] = read_credo_mode(plan["config_dir"], sid)
        return plan, errors
    plan["target_pid"] = pid
    plan["target_start"] = proc_start(pid)
    argv = list(argv)
    if "/" not in argv[0] and shutil.which(argv[0]):
        # absolute path so a new window / tmux server with another PATH finds it
        argv[0] = shutil.which(argv[0])
    plan["original_argv"] = argv
    tenv = read_environ_keys(pid, ENV_KEYS)
    if tenv is None:
        tenv = {}
        cfg = os.environ.get("CLAUDE_CONFIG_DIR")
    else:
        cfg = tenv.get("CLAUDE_CONFIG_DIR")
    plan["config_explicit"] = bool(cfg)
    config_dir = os.path.abspath(cfg) if cfg else \
        os.path.join(os.path.expanduser("~"), ".claude")
    plan["config_dir"] = config_dir
    plan["credo_mode"] = read_credo_mode(config_dir, sid)
    try:
        cwd = os.readlink("/proc/%d/cwd" % pid)
    except OSError:
        cwd = ""
        errors.append("cannot read the target's cwd")
    plan["cwd"] = cwd
    if sid and cwd:
        path, terr = find_transcript(config_dir, cwd, sid)
        if terr:
            errors.append(terr)
        plan["transcript"] = path
        mism = descriptor_mismatch(config_dir, pid, sid)
        if mism:
            errors.append(mism)
        holders = other_holders(config_dir, sid, pid)
        if holders:
            errors.append("session %s also appears held by pid(s) %s" % (
                sid, ", ".join(map(str, holders))))
    guard_name = "credo-%s-%d" % (sid[:8] or "x", int(time.time()) % 100000)
    method, details, merr = choose_method(tenv, args.method, guard_name)
    if merr:
        errors.append(merr)
    plan["method"] = method
    plan["method_details"] = details
    if method == "tmux":
        # the same ownership check as self-compact: never probe, stop or retype into a
        # pane that does not show THIS Claude process
        oerr = pane_owner_error(details["pane"], details.get("socket"), pid,
                                plan["target_start"])
        if oerr:
            errors.append(oerr)
    if sid and not errors_for_sid(errors):
        plan["recorded_mode"] = read_recorded_mode(config_dir, sid)
        tmpl, note = rebuild_argv_note(argv, exe_end, sid, "<wake prompt>",
                                       plan["recorded_mode"])
        plan["relaunch_argv_template"] = tmpl
        plan["permission_note"] = note
        plan["exe_end"] = exe_end
    state = os.path.join(config_dir, "credo")
    plan["launcher"] = os.path.join(state, "self-restart-launch.sh")
    plan["log"] = os.path.join(state, "self-restart.log")
    plan["marker"] = os.path.join(state, "self-restart.json")
    if re.search(r"['\\]", plan["launcher"]):
        errors.append("config dir path contains a quote or backslash")
    if args.update:
        raw = config_get("self_update.marketplaces", config_dir, plan["config_explicit"])
        allow, aerr = parse_allowlist(raw)
        if aerr:
            errors.append(aerr)
        plan["allowlist"] = allow or {}
    return plan, errors


def errors_for_sid(errors):
    return any(e.startswith("session id has") for e in errors)


def print_plan(plan, errors):
    p = print
    p("credo self-restart plan (dry run, nothing changed)")
    p("  session id:   %s" % (plan.get("session_id") or "-"))
    p("  target pid:   %s" % plan.get("target_pid", "-"))
    p("  config dir:   %s%s" % (plan.get("config_dir"),
                                "" if plan.get("config_explicit") else " (default)"))
    p("  cwd:          %s" % plan.get("cwd", "-"))
    p("  transcript:   %s" % (plan.get("transcript") or "-"))
    p("  method:       %s %s" % (plan.get("method") or "-",
                                 json.dumps(plan.get("method_details") or {})))
    p("  dialog guard: %s" % guard_kind(plan.get("method_details")))
    p("  permission:   %s" % plan.get("permission_note", "-"))
    if plan.get("credo_mode") == "autonomous":
        p("  owner rule:   credo mode autonomous -> run allowed with --announce >= %d "
          "(ntfy + message, cancellable)" % int(min_announce()))
    else:
        p("  owner rule:   credo mode %s -> run only after the user's explicit yes via "
          "the Ask tool, with --user-confirmed" % (plan.get("credo_mode") or "not set"))
    if plan.get("relaunch_argv_template"):
        p("  relaunch:     %s" % " ".join(shlex.quote(a)
                                          for a in plan["relaunch_argv_template"]))
    if plan.get("method"):
        p("  invocation:   %s" % " ".join(shlex.quote(a) for a in invocation(
            plan["method"], plan["method_details"], plan["launcher"], plan["cwd"])))
    if plan.get("update"):
        p("  update:       %s" % json.dumps(plan.get("allowlist") or {}))
    else:
        p("  update:       no (pass --update to update allowlisted plugins)")
    p("")
    p("Peer safety net: if a peer session is reachable (ListAgents), send it BEFORE run:")
    p("  " + PEER_TEMPLATE)
    p("")
    if errors:
        for e in errors:
            p("FAIL: %s" % e)
    else:
        p("OK: all preconditions pass")


# --- worker --------------------------------------------------------------------

class Cancelled(Exception):
    pass


class MarkerLock(object):
    """Exclusive flock serializing the pending -> cancelled / pending -> stopping
    transitions between `cancel` and the worker."""

    def __init__(self, marker):
        self.path = marker + ".lock"
        self.fh = None

    def __enter__(self):
        os.makedirs(os.path.dirname(self.path), exist_ok=True)
        self.fh = open(self.path, "a")
        fcntl.flock(self.fh, fcntl.LOCK_EX)
        return self

    def __exit__(self, *_):
        try:
            fcntl.flock(self.fh, fcntl.LOCK_UN)
        finally:
            self.fh.close()
        return False


def read_marker(path):
    try:
        with open(path) as fh:
            d = json.load(fh)
    except (OSError, ValueError):
        return None
    return d if isinstance(d, dict) else None


def write_json(path, data):
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        tmp = path + ".tmp"
        with open(tmp, "w") as fh:
            json.dump(data, fh, indent=2)
        os.replace(tmp, path)
    except OSError as exc:
        log("marker write failed: %s" % exc)


def write_marker(plan, status, extra=None):
    data = {"session_id": plan.get("session_id"), "started": plan.get("started"),
            "reason": plan.get("reason"), "status": status, "updated": now_iso(),
            "scheduled": plan.get("scheduled"), "announce": plan.get("announce"),
            "user_confirmed": plan.get("user_confirmed"),
            "worker_pid": plan.get("worker_pid")}
    if extra:
        data.update(extra)
    write_json(plan["marker"], data)


def marker_cancelled(plan):
    m = read_marker(plan["marker"])
    return bool(m and m.get("status") == "cancelled"
                and m.get("started") == plan.get("started"))


def is_worker(pid):
    argv = read_cmdline(pid)
    return "_worker" in argv and any(a.endswith("credo-self-restart.py") for a in argv)


def wait_gone(pid, start, timeout):
    end = time.time() + timeout
    while time.time() < end:
        if not alive(pid, start):
            return True
        time.sleep(0.2)
    return not alive(pid, start)


def stop_target(plan):
    pid, start = plan["target_pid"], plan["target_start"]
    timeout = env_float("CREDO_SELF_RESTART_STOP_TIMEOUT", 30)
    pause = env_float("CREDO_SELF_RESTART_SIGNAL_PAUSE", 1.5)
    # The TUI only exits on a SECOND Ctrl+C within a short window; a 1.5s gap was
    # observed to miss it (live test), so the two key presses use their own short gap.
    key_pause = env_float("CREDO_SELF_RESTART_KEY_PAUSE", 0.4)
    if plan["method"] == "tmux":
        pane = plan["method_details"]["pane"]
        for _ in range(2):
            if not alive(pid, start):
                break
            subprocess.run(pane_guard.tmux_base(plan["method_details"].get("socket"))
                           + ["send-keys", "-t", pane, "C-c"], timeout=10,
                           capture_output=True)
            log("sent C-c to tmux pane %s" % pane)
            time.sleep(key_pause)
        if wait_gone(pid, start, min(10.0, timeout / 2)):
            return True
        log("still alive after tmux C-c, falling back to signals")
    for sig in (signal.SIGINT, signal.SIGINT):
        if not alive(pid, start):
            return True
        try:
            os.kill(pid, sig)
            log("sent SIGINT to %d" % pid)
        except OSError:
            return not alive(pid, start)
        time.sleep(pause)
    if wait_gone(pid, start, timeout / 2):
        return True
    try:
        os.kill(pid, signal.SIGTERM)
        log("sent SIGTERM to %d" % pid)
    except OSError:
        pass
    return wait_gone(pid, start, timeout / 2)


def relaunch(plan, prompt):
    argv = rebuild_argv(plan["original_argv"], plan["exe_end"], plan["session_id"], prompt,
                        plan.get("recorded_mode"))
    details = plan["method_details"]
    with open(plan["launcher"], "w") as fh:
        fh.write(launcher_text(plan["cwd"], plan["config_dir"], plan["config_explicit"],
                               argv, pty_wrap=bool(details.get("pty"))))
    os.chmod(plan["launcher"], 0o700)
    cmd = invocation(plan["method"], plan["method_details"], plan["launcher"], plan["cwd"])
    log("relaunch via %s: %s" % (plan["method"], " ".join(shlex.quote(a) for a in cmd)))
    env = stripped_env(plan["config_dir"], plan["config_explicit"])
    if plan["method"] == "tmux":
        r = subprocess.run(cmd, env=env, capture_output=True, text=True, timeout=15)
        return r.returncode == 0, r.stderr.strip()
    proc = subprocess.Popen(cmd, env=env, cwd=plan["cwd"], stdin=subprocess.DEVNULL,
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                            start_new_session=True)
    try:
        rc = proc.wait(timeout=5)
        return rc == 0, "exit %d" % rc
    except subprocess.TimeoutExpired:
        return True, "still running (terminal window)"


def blocked_notify(plan, pane, reason):
    """One early push while a dialog / permission prompt blocks the wait (the dialog
    text stays in the local log only)."""
    log("pane %s blocked by a dialog, user notified, still waiting: %s" % (pane, reason))
    ntfy("credo self-restart blocked", pane_wake.blocked_text("self-restart", pane),
         plan["config_dir"], plan["config_explicit"])


def wait_idle(plan):
    """tmux method only: wait until the pane is idle with an EMPTY input field and no
    dialog (credo_pane_guard, two probes), so stopping never discards a prompt the
    user is typing or an open question. None when safe (or no pane to check),
    "cancelled", "target gone" (the Claude process exited meanwhile - stop waiting),
    "pane ownership lost: ..." or the timeout reason. Every probe uses the session's
    own tmux server socket and re-checks the pane ownership. Other methods have no
    pane to inspect."""
    if plan.get("method") != "tmux":
        return None
    pane = plan["method_details"]["pane"]
    sock = plan["method_details"].get("socket")
    owner_fail = []

    def probe():
        oerr = pane_owner_error(pane, sock, plan["target_pid"], plan["target_start"])
        if oerr:
            owner_fail.append(oerr)
            return False, "pane ownership lost: " + oerr
        return pane_guard.probe_pane(pane, sock)

    ok, reason = pane_guard.wait_until_safe(
        probe,
        env_float("CREDO_SELF_RESTART_IDLE_TIMEOUT", 1800),
        poll=env_float("CREDO_SELF_RESTART_IDLE_POLL", 2.0),
        recheck=env_float("CREDO_SELF_RESTART_IDLE_RECHECK", 1.5),
        should_stop=lambda: bool(owner_fail) or marker_cancelled(plan),
        on_state=lambda r: log("pane %s: %s" % (pane, r)),
        on_blocked=lambda r: blocked_notify(plan, pane, r),
        blocked_after=env_float("CREDO_SELF_RESTART_IDLE_BLOCKED_NOTIFY", 120))
    if owner_fail:
        if not alive(plan["target_pid"], plan["target_start"]):
            return "target gone"
        return "pane ownership lost: " + owner_fail[0]
    if ok:
        log("pane %s idle with an empty input: %s" % (pane, reason))
        return None
    return reason


def worker(plan_file):
    with open(plan_file) as fh:
        plan = json.load(fh)
    cfg, explicit = plan["config_dir"], plan["config_explicit"]
    plan["worker_pid"] = os.getpid()
    log("worker started for session %s (target pid %d); announce %ss, delay %ss, "
        "stop scheduled at %s" % (plan["session_id"], plan["target_pid"],
                                  fmt_num(plan.get("announce") or 0),
                                  fmt_num(plan.get("delay") or 0), plan.get("scheduled")))

    def on_term(*_):
        raise Cancelled()

    signal.signal(signal.SIGTERM, on_term)
    try:
        end = time.time() + max(0.0, float(plan.get("announce") or 0)) \
            + max(0.0, float(plan.get("delay") or 0))
        while True:
            if marker_cancelled(plan):
                raise Cancelled()
            left = end - time.time()
            if left <= 0:
                break
            time.sleep(min(1.0, left))
        idle_err = wait_idle(plan)
        if idle_err == "cancelled":
            raise Cancelled()
        if idle_err == "target gone" or (idle_err or "").startswith("pane ownership lost"):
            # the session exited by itself (or the pane now shows something else) while
            # we waited: stop waiting, never type a relaunch into that pane
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            status = "failed: target gone" if idle_err == "target gone" \
                else "failed: pane ownership"
            log("%s while waiting for idle; nothing stopped, nothing relaunched" % idle_err)
            write_marker(plan, status, {"detail": idle_err})
            ntfy("credo self-restart aborted",
                 "Session %s: %s while waiting for an idle pane; nothing was relaunched. "
                 "Resume it by hand if needed: claude --resume %s"
                 % (plan["session_id"], idle_err, plan["session_id"]), cfg, explicit)
            return 1
        if idle_err:
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            log("session never became idle with an empty input; not stopping (%s)" % idle_err)
            write_marker(plan, "failed: session not idle", {"detail": idle_err})
            ntfy("credo self-restart gave up",
                 "Session %s was not stopped: it never became idle with an empty input "
                 "field (%s)." % (plan["session_id"], idle_err), cfg, explicit)
            return 1
        # past this point a cancel is too late: SIGTERM is ignored and the marker
        # leaves "pending" under the lock, so `cancel` refuses from now on
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        with MarkerLock(plan["marker"]):
            if marker_cancelled(plan):
                raise Cancelled()
            write_marker(plan, "stopping")
    except Cancelled:
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        log("self-restart cancelled before stopping the target; nothing stopped")
        ntfy("credo self-restart cancelled",
             "Self-restart of session %s was cancelled; the session keeps running."
             % plan["session_id"], cfg, explicit)
        return 0
    if not stop_target(plan):
        log("target did not exit; aborting (no update, no relaunch)")
        write_marker(plan, "failed: target did not exit")
        ntfy("credo self-restart failed",
             "Session %s did not exit; nothing relaunched." % plan["session_id"],
             cfg, explicit)
        return 1
    log("target %d is gone" % plan["target_pid"])
    summary, versions = "skipped", {}
    if plan.get("update"):
        write_marker(plan, "updating")
        try:
            summary, versions = run_update(plan)
        except Exception as exc:  # updates must never block the relaunch
            summary = "failed (%s)" % type(exc).__name__
        log("update: %s" % summary)
    ok, info = relaunch(plan, wake_prompt(plan.get("reason") or "unspecified", summary))
    if ok:
        extra = {"method": plan["method"], "update": summary, "versions": versions}
        write_marker(plan, "relaunched", extra)
        log("relaunched (%s)" % info)
        details = plan["method_details"]
        target = details.get("pane") or details.get("tmux_session")
        if target:
            # the own pane lives on the session's server; a new tmux_session window
            # runs on the default server
            sock = details.get("socket") if details.get("pane") else None
            extra["dialog_guard"] = dialog_guard_tmux(target, sock)
            log("dialog guard: %s" % extra["dialog_guard"])
            write_marker(plan, "relaunched", extra)
        return 0
    write_marker(plan, "failed: relaunch", {"method": plan["method"], "detail": info})
    log("relaunch failed: %s" % info)
    ntfy("credo self-restart failed",
         "Session %s stopped but relaunch via %s failed. Resume it by hand: "
         "claude --resume %s" % (plan["session_id"], plan["method"], plan["session_id"]),
         cfg, explicit)
    return 1


def spawn_worker(plan):
    state = os.path.dirname(plan["marker"])
    os.makedirs(state, exist_ok=True)
    plan_file = os.path.join(state, "self-restart-plan.json")
    with open(plan_file, "w") as fh:
        json.dump(plan, fh)
    logfh = open(plan["log"], "a")
    proc = subprocess.Popen([sys.executable, SCRIPT_PATH, "_worker", plan_file],
                            stdin=subprocess.DEVNULL, stdout=logfh, stderr=logfh,
                            close_fds=True, start_new_session=True, cwd="/")
    logfh.close()
    return proc.pid


# --- commands ------------------------------------------------------------------

def cmd_check(args):
    plan, errors = gather(args)
    print_plan(plan, errors)
    return 1 if errors else 0


def cancel_hint():
    return "python3 %s cancel" % shlex.quote(SCRIPT_PATH)


def pending_worker(marker):
    m = read_marker(marker)
    if not m or m.get("status") != "pending":
        return None
    pid = m.get("worker_pid")
    if isinstance(pid, int) and alive(pid) and is_worker(pid):
        return pid
    return None


def cmd_run(args):
    plan, errors = gather(args)
    announce, gerr = owner_guard(plan, args.user_confirmed, args.announce)
    if gerr:
        print("REFUSED: %s" % gerr)
        print("Nothing was started.")
        return EXIT_GUARD
    if not args.no_background_work:
        print("REFUSED: %s" % BACKGROUND_REFUSAL)
        print("Nothing was started.")
        return EXIT_GUARD
    if errors:
        print_plan(plan, errors)
        try:
            os.makedirs(os.path.dirname(plan.get("log") or ""), exist_ok=True)
        except OSError:
            pass
        ntfy("credo self-restart refused",
             "Not restarting session %s: %s" % (plan.get("session_id") or "?",
                                               "; ".join(errors)),
             plan["config_dir"], plan["config_explicit"])
        return 1
    other = pending_worker(plan["marker"])
    if other:
        print("REFUSED: a self-restart is already pending (worker %d); cancel it first: %s"
              % (other, cancel_hint()))
        return 1
    t0 = time.time()
    plan["started"] = now_iso()
    plan["announce"] = announce
    plan["user_confirmed"] = bool(args.user_confirmed)
    plan["scheduled"] = datetime.datetime.fromtimestamp(
        t0 + announce + max(0.0, plan["delay"] or 0)).astimezone().isoformat(
            timespec="seconds")
    with MarkerLock(plan["marker"]):
        write_marker(plan, "pending")
    wpid = spawn_worker(plan)
    plan["worker_pid"] = wpid
    with MarkerLock(plan["marker"]):
        m = read_marker(plan["marker"])
        if m and m.get("status") == "pending" and m.get("started") == plan["started"]:
            write_marker(plan, "pending")
    if announce > 0:
        when = fmt_duration(announce)
        print("Self-restart scheduled in %s (reason: %s). Cancel: %s"
              % (when, plan["reason"], cancel_hint()))
        ntfy("credo self-restart in %s" % when,
             "Session %s restarts at %s (reason: %s). Cancel: %s"
             % (plan["session_id"], plan["scheduled"], plan["reason"], cancel_hint()),
             plan["config_dir"], plan["config_explicit"])
    print("credo self-restart: worker %d detached; session %s will stop at %s (in ~%ss), "
          "then relaunch via %s. Log: %s" % (
              wpid, plan["session_id"], plan["scheduled"],
              fmt_num(announce + (plan["delay"] or 0)), plan["method"], plan["log"]))
    if announce > 0:
        print("Wrap up and end your turn before %s; the session stops then." %
              plan["scheduled"])
    else:
        print("End your turn now.")
    return 0


def state_dir():
    cfg = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(
        os.path.expanduser("~"), ".claude")
    pid, _, _, err = find_target()
    if not err:
        tenv = read_environ_keys(pid, ("CLAUDE_CONFIG_DIR",)) or {}
        if tenv.get("CLAUDE_CONFIG_DIR"):
            cfg = tenv["CLAUDE_CONFIG_DIR"]
    return os.path.join(cfg, "credo")


def cmd_cancel(args):
    state = state_dir()
    marker = os.path.join(state, "self-restart.json")
    with MarkerLock(marker):
        m = read_marker(marker)
        status = (m or {}).get("status") or "none"
        if status != "pending":
            print("nothing to cancel (self-restart status: %s)" % status)
            return 1
        m["status"] = "cancelled"
        m["cancelled"] = now_iso()
        m["updated"] = m["cancelled"]
        write_json(marker, m)
    pid = m.get("worker_pid")
    killed = False
    if isinstance(pid, int) and alive(pid) and is_worker(pid):
        try:
            os.kill(pid, signal.SIGTERM)
            killed = True
        except OSError:
            pass
    print("credo self-restart cancelled (session %s, was scheduled for %s)%s" % (
        m.get("session_id") or "?", m.get("scheduled") or "?",
        "; worker %d terminated" % pid if killed else "; no waiting worker found"))
    return 0


def cmd_status(args):
    state = state_dir()
    m = read_marker(os.path.join(state, "self-restart.json"))
    if m:
        print("state: %s; scheduled: %s; reason: %s" % (
            m.get("status") or "?", m.get("scheduled") or "-", m.get("reason") or "-"))
    try:
        with open(os.path.join(state, "self-restart.json")) as fh:
            print(fh.read().rstrip())
    except OSError:
        print("no self-restart marker in %s" % state)
    try:
        with open(os.path.join(state, "self-restart.log")) as fh:
            lines = fh.readlines()[-20:]
        print("--- log tail ---")
        sys.stdout.write("".join(lines))
    except OSError:
        pass
    return 0


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    if argv[:1] == ["_worker"] and len(argv) == 2:
        return worker(argv[1])
    if argv[:1] == ["relaunch-pty"]:
        rest = argv[1:]
        if rest[:1] == ["--"]:
            rest = rest[1:]
        return relaunch_pty(rest)
    ap = argparse.ArgumentParser(prog="credo-self-restart.py")
    ap.add_argument("action", nargs="?", default="check",
                    choices=("check", "run", "cancel", "status"))
    ap.add_argument("--user-confirmed", action="store_true",
                    help="the user said yes via the Ask tool in this interactive "
                         "session; never pass it without that answer")
    ap.add_argument("--announce", type=float, default=None,
                    help="seconds to announce before stopping (autonomous: >= 300, "
                         "default 300; with --user-confirmed default 0)")
    ap.add_argument("--no-background-work", action="store_true",
                    help="required for run: pass it only after you checked yourself that "
                         "none of your own background subagents, background shells / "
                         "monitors or pending task notifications are still running")
    ap.add_argument("--update", action="store_true")
    ap.add_argument("--reason", default="cc-up")
    ap.add_argument("--delay", type=float, default=5.0)
    ap.add_argument("--method", choices=("tmux", "wt", "x11"))
    args = ap.parse_args(argv)
    return {"check": cmd_check, "run": cmd_run, "cancel": cmd_cancel,
            "status": cmd_status}[args.action](args)


if __name__ == "__main__":
    sys.exit(main())
