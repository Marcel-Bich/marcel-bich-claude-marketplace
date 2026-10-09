#!/usr/bin/env python3
"""credo-self-reload.py - let a Claude Code session reload its plugins and skills
(/reload-plugins, then /reload-skills) by typing them into its OWN tmux pane after
its turn ended, and then wake itself with a "." prompt. The cheap first try after a
plugin update; the full restart (/credo:self-restart --update, "cc-up") is only the
fallback when the reload was not enough.

Subcommands
-----------
  check  (default) dry run. Resolves the own tmux pane of THIS Claude process, verifies
         the pane really belongs to it (no other Claude process between the pane's
         process and this one), prints the plan and the current pane state. Exit 1
         with the reason when a precondition fails (not in tmux, pane of another
         process, no session id, ...).
  run (--auto | --user-confirmed) [--update] [--delay S] [--timeout S]
      [--nudge-wait S] [--max-nudges N]
         OWNER RULE GUARD first (exit 3, nothing started):
           --auto            only when the credo session mode of THIS session is
                             "autonomous" (no question asked),
           --user-confirmed  only after the user said yes via the Ask tool in this
                             interactive session (never pass it without that answer).
         No background rule: running background subagents, background shells,
         scripts, monitors or any other background service do NOT block a
         self-reload (they survive it); the pane footer rows are ignored.
         Then validates like check (exit 1 on failure, ntfy). On success it spawns a
         fully detached worker and returns at once - the agent must END ITS TURN.
  cancel mark the pending self-reload of THIS session as cancelled and terminate its
         worker (another session's self-reload is never touched).
  status print the marker of THIS session and the log tail.

Worker - optionally runs the allowlisted plugin update first (--update, the same
allowlist and plugin CLI calls as credo-self-restart.py --update; it does not touch
the pane). Then for each of /reload-plugins and /reload-skills: waits until the pane
is idle and safe (credo_pane_guard: no busy spinner, input field empty, no dialog /
Ask / permission prompt / menu / copy mode, confirmed by a second probe, pane
ownership re-verified on every probe, background footer ignored), types the command
literally, runs the full check again expecting exactly that text, and only then sends
Enter; then it polls the pane for the command's "Reloaded" result line
(CREDO_SELF_RELOAD_RESULT_WAIT, a timeout only logs) before the next key, so nothing is
queued behind a running command. Finally (credo_pane_wake) it writes the wake file
<configdir>/credo/self-wake-<session-id>, waits for idle again and types "." + Enter,
because the reload commands do not start a model turn.

Fallback timer - the UserPromptSubmit hook credo-autonomy-clear.sh consumes the wake
file when the next prompt of this session arrives (the "." worked) and injects a note
asking the agent to check whether the reload was enough. The worker watches the file:
gone -> status "woken", nothing more is sent (the timer is cancelled). Still there
after --nudge-wait seconds (default 60) -> it sends the "." again (only Enter when the
"." is still in the input field; nothing while the pane is not safe), at most
--max-nudges times (default 3); then "failed: no new turn ..." + ntfy, and the wake
file stays so the next prompt still gets the note.

Files (per session id): <configdir>/credo/self-reload-<session-id>.json (marker),
self-reload-<session-id>.log, self-reload-plan-<session-id>.json and the wake file.

Env overrides (tests): CREDO_SELF_RELOAD_SESSION_ID, CREDO_SELF_RELOAD_TARGET_PID,
CREDO_SELF_RELOAD_NTFY_URL ("off" or a URL), CREDO_SELF_RELOAD_POLL,
CREDO_SELF_RELOAD_RECHECK, CREDO_SELF_RELOAD_KEY_PAUSE, CREDO_SELF_RELOAD_CONFIRM_WAIT,
CREDO_SELF_RELOAD_RESULT_WAIT (wait for the "Reloaded" line, default 30 s),
CREDO_SELF_RELOAD_STEP_TIMEOUT (idle wait after each reload
command, default 300 s), CREDO_SESSION_MODES_DIR.

Python 3 stdlib only.
"""

import argparse
import datetime
import importlib.util
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import time

SCRIPT_PATH = os.path.abspath(__file__)
SCRIPT_DIR = os.path.dirname(SCRIPT_PATH)
sys.path.insert(0, SCRIPT_DIR)
import credo_pane_guard as guard  # noqa: E402
import credo_pane_wake as wk  # noqa: E402


def _load_restart():
    spec = importlib.util.spec_from_file_location(
        "credo_self_restart", os.path.join(SCRIPT_DIR, "credo-self-restart.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


csr = _load_restart()  # process helpers, credo mode, config, marker lock, plugin update

EXIT_GUARD = 3
COMMANDS = ("/reload-plugins", "/reload-skills")
PANE_RE = re.compile(r"%[0-9]+")
ENV_KEYS = ("CLAUDE_CONFIG_DIR", "TMUX", "TMUX_PANE")


def now_iso():
    return datetime.datetime.now().astimezone().isoformat(timespec="seconds")


def log(msg):
    sys.stderr.write("[credo-self-reload %s] %s\n" % (now_iso(), msg))
    sys.stderr.flush()


def envf(name, default):
    return csr.env_float(name, default)


def owner_guard(mode, auto, user_confirmed):
    """None when allowed, else the refusal text. Exactly one flag is required."""
    if auto == user_confirmed:
        return "pass exactly one of --auto or --user-confirmed"
    if user_confirmed:
        return None
    if mode != "autonomous":
        return ("refused by the owner rule: --auto is only allowed when the credo session "
                "mode of this session is autonomous (it is %s). In interactive modes ask "
                "the user once via the Ask tool and, only after an explicit yes, run again "
                "with --user-confirmed." % ("'%s'" % mode if mode else "not set"))
    return None


# --- target, session, pane -------------------------------------------------------

def find_target():
    """(pid, error): the nearest Claude Code ancestor of this process."""
    override = os.environ.get("CREDO_SELF_RELOAD_TARGET_PID")
    if override:
        if not override.isdigit():
            return None, "CREDO_SELF_RELOAD_TARGET_PID is not a pid"
        pids = [int(override)]
    else:
        pids = csr.ancestors(os.getppid())
    for pid in pids:
        if csr.claude_exe_end(csr.read_cmdline(pid), csr.read_exe(pid)) is not None \
                and csr.alive(pid):
            return pid, None
    return None, "no Claude Code process found in the parent chain"


def session_id():
    sid = (os.environ.get("CREDO_SELF_RELOAD_SESSION_ID")
           or os.environ.get("CLAUDE_CODE_SESSION_ID") or "")
    if not sid:
        return "", "no session id (CLAUDE_CODE_SESSION_ID is not set)"
    if not re.fullmatch(r"[A-Za-z0-9._-]+", sid) or sid in (".", ".."):
        return "", "session id has unexpected characters"
    return sid, None


def state_files(state, sid):
    """(marker, log, plan file, wake file) of one session."""
    return (os.path.join(state, "self-reload-%s.json" % sid),
            os.path.join(state, "self-reload-%s.log" % sid),
            os.path.join(state, "self-reload-plan-%s.json" % sid),
            wk.wake_path(state, sid))


def gather(args):
    """(plan, errors). Read-only."""
    errors = []
    plan = {"delay": args.delay, "timeout": args.timeout, "update": bool(args.update),
            "nudge_wait": args.nudge_wait, "max_nudges": args.max_nudges}
    sid, serr = session_id()
    if serr:
        errors.append(serr)
    plan["session_id"] = sid
    cfg_env = os.environ.get("CLAUDE_CONFIG_DIR")
    pid, err = find_target()
    tenv = {}
    cwd = ""
    link = {"daemon": False}
    if err:
        errors.append(err)
    else:
        # a daemon-hosted session is shown and typed into by its client TUI: the pane,
        # TMUX / TMUX_PANE and the ownership check belong to that client
        link = csr.daemon_link(pid)
        if link.get("error"):
            errors.append(link["error"])
            err = link["error"]
        owner = link.get("client") or pid
        plan["agent_pid"] = pid
        plan["agent_start"] = csr.proc_start(pid)
        plan["target_pid"] = owner
        plan["target_start"] = csr.proc_start(owner)
        plan["daemon"] = csr.daemon_note(link)
        tenv = csr.pane_env(pid, link, ENV_KEYS)
        if tenv is None:
            errors.append("cannot read the environment of the Claude process %d" % owner)
            tenv = {}
        else:
            cfg_env = tenv.get("CLAUDE_CONFIG_DIR")
        try:
            cwd = os.readlink("/proc/%d/cwd" % pid)
        except OSError:
            cwd = ""
    config_dir = os.path.abspath(cfg_env) if cfg_env else \
        os.path.join(os.path.expanduser("~"), ".claude")
    plan["config_dir"] = config_dir
    plan["config_explicit"] = bool(cfg_env)
    plan["cwd"] = cwd or "/"
    plan["state_sids"] = csr.state_sids(sid, link)
    plan["credo_mode"] = csr.read_credo_mode_any(config_dir, plan["state_sids"])
    state = os.path.join(config_dir, "credo")
    plan["marker"], plan["log"], plan["plan_file"], plan["wake_file"] = \
        state_files(state, sid or "none")
    pane = tenv.get("TMUX_PANE") or ""
    if not err:
        if not tenv.get("TMUX") or not pane:
            errors.append("not running inside tmux (the %s has no TMUX/TMUX_PANE); "
                          "self-reload needs its own tmux pane - reload by hand or use "
                          "/credo:self-restart"
                          % ("client TUI of this daemon-hosted session" if link.get("daemon")
                             else "Claude process"))
        elif not PANE_RE.fullmatch(pane):
            errors.append("TMUX_PANE %r is not a pane id" % pane)
        elif not shutil.which("tmux"):
            errors.append("tmux is not on PATH")
        else:
            plan["pane"] = pane
            plan["socket"] = guard.socket_from_tmux_env(tenv.get("TMUX"))
            oerr = csr.pane_owner_error(pane, plan["socket"], plan["target_pid"],
                                        plan["target_start"])
            if oerr:
                errors.append(oerr)
    if args.update:
        raw = csr.config_get("self_update.marketplaces", config_dir, plan["config_explicit"])
        allow, aerr = csr.parse_allowlist(raw)
        if aerr:
            errors.append(aerr)
        plan["allowlist"] = allow or {}
    return plan, errors


def print_plan(plan, errors, live_state=None):
    p = print
    p("credo self-reload plan (dry run, nothing typed)")
    p("  session id:   %s" % (plan.get("session_id") or "-"))
    p("  target pid:   %s" % plan.get("target_pid", "-"))
    if plan.get("daemon"):
        p("  hosted by:    %s; pane checked via the client TUI" % plan["daemon"])
    if len(plan.get("state_sids") or []) > 1:
        p("  state ids:    %s (daemon fork: credo state of the pre-fork session carries over)"
          % ", ".join(plan["state_sids"]))
    p("  config dir:   %s" % plan.get("config_dir"))
    p("  own pane:     %s (tmux socket %s)" % (plan.get("pane") or "-",
                                               plan.get("socket") or "default"))
    p("  credo mode:   %s" % (plan.get("credo_mode") or "not set"))
    if plan.get("credo_mode") == "autonomous":
        p("  owner rule:   autonomous -> run --auto (no question)")
    else:
        p("  owner rule:   interactive -> ask once via the Ask tool; only after an "
          "explicit yes: run --user-confirmed")
    if plan.get("update"):
        p("  update:       %s (plugin CLI, before the reload)"
          % ", ".join(sorted(plan.get("allowlist") or {})))
    p("  steps:        %s, then %s, then \".\" + Enter to start a new turn (each typed "
      "only into an idle pane with an empty input field, verified before Enter)"
      % COMMANDS)
    p("  fallback:     no new turn within %ss -> \".\" again, at most %d times"
      % (csr.fmt_num(plan.get("nudge_wait") or 0), plan.get("max_nudges") or 0))
    p("  background:   never blocks (background subagents, shells, scripts, monitors "
      "and other background services survive the reload)")
    if live_state:
        p("  pane now:     %s" % live_state)
    p("")
    if errors:
        for e in errors:
            p("FAIL: %s" % e)
    else:
        p("OK: all preconditions pass")


# --- ntfy and marker -------------------------------------------------------------

def ntfy(title, body, plan):
    csr.ntfy(title, body, plan["config_dir"], plan["config_explicit"],
             override_var="CREDO_SELF_RELOAD_NTFY_URL", logger=log)


def write_marker(plan, status, extra=None):
    data = {"session_id": plan.get("session_id"), "pane": plan.get("pane"),
            "started": plan.get("started"), "status": status, "updated": now_iso(),
            "mode": plan.get("run_mode"), "worker_pid": plan.get("worker_pid"),
            "update": plan.get("update_summary"), "nudges": plan.get("nudges", 0)}
    if extra:
        data.update(extra)
    csr.write_json(plan["marker"], data)


def marker_cancelled(plan):
    m = csr.read_marker(plan["marker"])
    return bool(m and m.get("status") == "cancelled" and m.get("started") == plan.get("started"))


def is_worker(pid):
    argv = csr.read_cmdline(pid)
    return "_worker" in argv and any(a.endswith("credo-self-reload.py") for a in argv)


# --- worker ----------------------------------------------------------------------

RESULT_RE = re.compile(r"\breloaded\b", re.I)


def result_seen(text, cmd):
    """True when the transcript part of a capture (above the input box) shows a
    "Reloaded ..." result line below the last echo of `cmd`. Pure function."""
    lines = (text or "").split("\n")
    box = guard.find_input_box(lines)
    plain = [guard.strip_ansi(l) for l in (lines[:box[0]] if box else lines)]
    echo = [i for i, l in enumerate(plain) if cmd in l and not RESULT_RE.search(l)]
    if not echo:
        return False
    return any(RESULT_RE.search(l) for l in plain[echo[-1] + 1:])


def wait_result(plan, cmd, seconds):
    """After Enter of a reload command, poll the pane until its "Reloaded" result
    line shows (slash commands typed while something still runs would be queued).
    The text is undocumented, so a timeout only logs; the idle guard before the next
    key still applies."""
    end = time.time() + max(0.0, seconds)
    while True:
        if marker_cancelled(plan):
            raise wk.Cancelled()
        if result_seen(guard.capture(plan["pane"], plan.get("socket")), cmd):
            log("result line seen after %s" % cmd)
            return True
        if time.time() >= end:
            log("no result line after %s within %ss; continuing on the idle guard"
                % (cmd, csr.fmt_num(seconds)))
            return False
        time.sleep(min(0.3, max(0.0, end - time.time())))


def worker(plan_file):
    with open(plan_file) as fh:
        plan = json.load(fh)
    plan["worker_pid"] = os.getpid()
    log("worker started for session %s, pane %s" % (plan["session_id"], plan["pane"]))

    def on_term(*_):
        raise wk.Cancelled()

    signal.signal(signal.SIGTERM, on_term)
    pane = wk.Pane(plan, csr.session_owner_check(plan), lambda: marker_cancelled(plan), log,
                   wk.timing("CREDO_SELF_RELOAD"),
                   on_blocked=lambda r: ntfy("credo self-reload blocked",
                                             wk.blocked_text("self-reload", plan["pane"]), plan))
    step_timeout = envf("CREDO_SELF_RELOAD_STEP_TIMEOUT", 300.0)
    result_wait = envf("CREDO_SELF_RELOAD_RESULT_WAIT", 30.0)

    def on_nudge(n):
        plan["nudges"] = n
        write_marker(plan, "waiting for the new turn")

    try:
        end = time.time() + max(0.0, float(plan.get("delay") or 0))
        while time.time() < end:
            if marker_cancelled(plan):
                raise wk.Cancelled()
            time.sleep(min(0.5, max(0.0, end - time.time())))
        if plan.get("update"):
            summary, _ = csr.run_update(plan)
            plan["update_summary"] = summary
            log("plugin update: %s" % summary)
            with csr.MarkerLock(plan["marker"]):
                if marker_cancelled(plan):
                    raise wk.Cancelled()
                write_marker(plan, "pending")
        timeout = plan["timeout"]
        for cmd in COMMANDS:
            pane.wait_safe(timeout)
            with csr.MarkerLock(plan["marker"]):
                if marker_cancelled(plan):
                    raise wk.Cancelled()
                write_marker(plan, "typing %s" % cmd)
            wk.type_and_enter(pane, cmd)
            wait_result(plan, cmd, result_wait)
            timeout = step_timeout
        write_marker(plan, "waking")
        wk.wake(pane, plan["wake_file"],
                {"kind": "reload", "session_id": plan["session_id"],
                 "started": plan["started"], "update": plan.get("update_summary")},
                step_timeout, float(plan["nudge_wait"]), int(plan["max_nudges"]),
                on_nudge=on_nudge)
        write_marker(plan, "woken")
        return 0
    except wk.Cancelled:
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        log("self-reload cancelled")
        return 0
    except wk.StepFailed as exc:
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        write_marker(plan, exc.status, {"detail": exc.detail})
        log("%s: %s" % (exc.status, exc.detail))
        ntfy("credo self-reload stopped",
             "Session %s: %s (%s). Check the prompt of that session; reload by hand or "
             "use /credo:self-restart." % (plan["session_id"], exc.status, exc.detail), plan)
        return 1


def spawn_worker(plan):
    state = os.path.dirname(plan["marker"])
    os.makedirs(state, exist_ok=True)
    with open(plan["plan_file"], "w") as fh:
        json.dump(plan, fh)
    logfh = open(plan["log"], "a")
    proc = subprocess.Popen([sys.executable, SCRIPT_PATH, "_worker", plan["plan_file"]],
                            stdin=subprocess.DEVNULL, stdout=logfh, stderr=logfh,
                            close_fds=True, start_new_session=True, cwd="/")
    logfh.close()
    return proc.pid


def pending_worker(marker):
    m = csr.read_marker(marker)
    if not m or m.get("status") in ("woken", "cancelled") or \
            str(m.get("status") or "").startswith("failed"):
        return None
    pid = m.get("worker_pid")
    if isinstance(pid, int) and csr.alive(pid) and is_worker(pid):
        return pid
    return None


# --- commands --------------------------------------------------------------------

def cmd_check(args):
    plan, errors = gather(args)
    live = None
    if plan.get("pane") and not errors:
        live = "%s (informational; while you are still in a turn it is busy)" % (
            guard.probe_pane(plan["pane"], plan.get("socket"), block_on_background=False)[1])
    print_plan(plan, errors, live)
    return 1 if errors else 0


def cmd_run(args):
    plan, errors = gather(args)
    gerr = owner_guard(plan.get("credo_mode"), args.auto, args.user_confirmed)
    if gerr:
        print("REFUSED: %s" % gerr)
        print("Nothing was started.")
        return EXIT_GUARD
    if errors:
        print_plan(plan, errors)
        ntfy("credo self-reload refused",
             "Not reloading session %s: %s" % (plan.get("session_id") or "?",
                                               "; ".join(errors)), plan)
        return 1
    other = pending_worker(plan["marker"])
    if other:
        print("REFUSED: a self-reload is already pending (worker %d); cancel it first" % other)
        return 1
    busy = wk.other_pending(os.path.dirname(plan["marker"]), plan["session_id"], "reload")
    if busy:
        print("REFUSED: a %s of this session is still pending (worker %d); both type into "
              "the same pane, so wait for it or cancel it first" % busy)
        return 1
    plan["started"] = now_iso()
    plan["run_mode"] = "auto" if args.auto else "user-confirmed"
    with csr.MarkerLock(plan["marker"]):
        write_marker(plan, "pending")
    plan["worker_pid"] = spawn_worker(plan)
    with csr.MarkerLock(plan["marker"]):
        m = csr.read_marker(plan["marker"])
        if m and m.get("status") == "pending" and m.get("started") == plan["started"]:
            write_marker(plan, "pending")
    print("credo self-reload: worker %d detached for pane %s; once the session is idle "
          "with an empty input field it types %s, then \".\" to start a new turn "
          "(fallback: \".\" again after %ss, at most %d times). Log: %s"
          % (plan["worker_pid"], plan["pane"], " and ".join(COMMANDS),
             csr.fmt_num(plan["nudge_wait"]), plan["max_nudges"], plan["log"]))
    print("On the woken turn check whether the reload was enough; only if not, fall back "
          "to /credo:self-restart --update (cc-up).")
    print("Cancel: python3 %s cancel" % SCRIPT_PATH)
    print("End your turn now.")
    return 0


def state_dir():
    cfg = os.environ.get("CLAUDE_CONFIG_DIR")
    pid, err = find_target()
    if not err:
        tenv = csr.read_environ_keys(pid, ("CLAUDE_CONFIG_DIR",)) or {}
        cfg = tenv.get("CLAUDE_CONFIG_DIR") or cfg
    cfg = cfg or os.path.join(os.path.expanduser("~"), ".claude")
    return os.path.join(cfg, "credo")


def cmd_cancel(args):
    sid, serr = session_id()
    if serr:
        print("cannot cancel: %s" % serr)
        return 1
    files = state_files(state_dir(), sid)
    marker = files[0]
    with csr.MarkerLock(marker):
        m = csr.read_marker(marker)
        status = (m or {}).get("status") or "none"
        pid = (m or {}).get("worker_pid")
        live = isinstance(pid, int) and csr.alive(pid) and is_worker(pid)
        if not m or not live or status in ("woken", "cancelled") or status.startswith("failed"):
            print("nothing to cancel for session %s (self-reload status: %s)" % (sid, status))
            return 1
        if m.get("session_id") != sid:
            print("nothing to cancel: the marker belongs to session %s, not %s"
                  % (m.get("session_id") or "?", sid))
            return 1
        m["status"] = "cancelled"
        m["cancelled"] = m["updated"] = now_iso()
        csr.write_json(marker, m)
    try:
        os.kill(pid, signal.SIGTERM)
        killed = True
    except OSError:
        killed = False
    dropped = wk.drop_wake(files[3])
    print("credo self-reload cancelled (session %s)%s%s" % (
        sid, "; worker %d terminated" % pid if killed else "; worker already gone",
        "; pending wake file removed" if dropped else ""))
    return 0


def cmd_status(args):
    sid, serr = session_id()
    if serr:
        print("cannot show status: %s" % serr)
        return 1
    state = state_dir()
    marker, logf, _, wake = state_files(state, sid)
    m = csr.read_marker(marker)
    if not m:
        print("no self-reload marker for session %s in %s" % (sid, state))
    else:
        print("state: %s; pane: %s; started: %s" % (m.get("status") or "?",
                                                   m.get("pane") or "-",
                                                   m.get("started") or "-"))
        print(json.dumps(m, indent=2))
    print("wake file: %s" % ("present (no new turn yet)" if os.path.exists(wake) else "none"))
    try:
        with open(logf) as fh:
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
    ap = argparse.ArgumentParser(prog="credo-self-reload.py")
    ap.add_argument("action", nargs="?", default="check",
                    choices=("check", "run", "cancel", "status"))
    ap.add_argument("--auto", action="store_true",
                    help="credo autonomous mode only: no question asked")
    ap.add_argument("--user-confirmed", action="store_true",
                    help="the user said yes via the Ask tool in this interactive session; "
                         "never pass it without that answer")
    ap.add_argument("--update", action="store_true",
                    help="run the allowlisted plugin update (self_update.marketplaces, as "
                         "self-restart --update) before the reload")
    ap.add_argument("--delay", type=float, default=3.0,
                    help="seconds before the first pane probe (default 3)")
    ap.add_argument("--timeout", type=float, default=1800.0,
                    help="give up when the session is not idle within this many seconds "
                         "(default 1800)")
    ap.add_argument("--nudge-wait", type=float, default=60.0,
                    help="fallback timer: send the \".\" again when no new turn started "
                         "within this many seconds (default 60)")
    ap.add_argument("--max-nudges", type=int, default=3,
                    help="at most this many re-sends of the \".\" (default 3)")
    args = ap.parse_args(argv)
    if args.timeout <= 0 or args.delay < 0 or args.nudge_wait <= 0 or args.max_nudges < 0:
        ap.error("--timeout and --nudge-wait must be > 0, --delay and --max-nudges >= 0")
    return {"check": cmd_check, "run": cmd_run, "cancel": cmd_cancel,
            "status": cmd_status}[args.action](args)


if __name__ == "__main__":
    sys.exit(main())
