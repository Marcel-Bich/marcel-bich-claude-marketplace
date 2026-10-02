#!/usr/bin/env python3
"""credo-self-compact.py - let a Claude Code session run the real /compact on itself
after compact-plus secured its state to disk, by typing it into its OWN tmux pane
once the session is idle and the input field is empty.

Subcommands
-----------
  check  (default) dry run. Resolves the own tmux pane of THIS Claude process, verifies
         the pane really belongs to it (no other Claude process between the pane's
         process and this one), checks the compact-plus breadcrumb (present and not
         older than --max-breadcrumb-age), prints the plan and the current pane state.
         Exit 1 with the reason when a precondition fails (not in tmux, pane of another
         process, no or stale breadcrumb, ...).
  run (--auto | --user-confirmed) [--delay S] [--timeout S] [--handoff PATH]
      [--max-breadcrumb-age S]
         OWNER RULE GUARD first (exit 3, nothing started):
           --auto            only when the credo session mode of THIS session is
                             "autonomous" (no question asked),
           --user-confirmed  only after the user said yes via the Ask tool in this
                             interactive session (never pass it without that answer).
         No background rule: running background subagents, background shells and
         monitors do NOT block a self-compact - they survive /compact (it can even be
         good that they keep working meanwhile). --no-background-work is still accepted
         as a no-op for compatibility; only credo-self-restart.py requires it.
         Then validates like check (exit 1 on failure, ntfy). On success it spawns a
         fully detached worker and returns at once - the agent must END ITS TURN.
  cancel mark the pending self-compact of THIS session as cancelled and terminate its
         worker (another session's self-compact is never touched).
  status print the marker of THIS session and the log tail.

Worker - waits --delay, then polls the pane (credo_pane_guard) until it is idle and
safe - no busy spinner, input field empty, no dialog / Ask / permission prompt /
menu / copy mode - confirmed by a second probe ~1.5 s later, re-verifying each time
that the pane still belongs to this Claude process. Background shells / monitors /
agents shown in the footer under the input box are ignored (block_on_background=False).
Then it types "/compact <instructions>" literally (send-keys -l), runs the full check
again (owner, copy mode, busy, dialog, and the input must hold exactly that text) and
only then sends Enter. Anything else (someone typed meanwhile, a dialog opened, ...)
sends NO Enter. --timeout (default 1800 s) -> give up, log, ntfy. Never targets any
pane other than the resolved own pane; user input is never captured and retyped.

Files (per session id): <configdir>/credo/self-compact-<session-id>.json (marker),
self-compact-<session-id>.log and self-compact-plan-<session-id>.json.

Env overrides (tests): CREDO_SELF_COMPACT_SESSION_ID, CREDO_SELF_COMPACT_TARGET_PID,
CREDO_SELF_COMPACT_NTFY_URL ("off" or a URL), CREDO_SELF_COMPACT_POLL,
CREDO_SELF_COMPACT_RECHECK, CREDO_SELF_COMPACT_KEY_PAUSE,
CREDO_SELF_COMPACT_CONFIRM_WAIT, CREDO_SESSION_MODES_DIR, CREDO_REHYDRATE_DIR.
CREDO_SELF_COMPACT_BREADCRUMB_MAX_AGE (seconds, default 7200) is the default of
--max-breadcrumb-age.

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
import urllib.request

SCRIPT_PATH = os.path.abspath(__file__)
SCRIPT_DIR = os.path.dirname(SCRIPT_PATH)
sys.path.insert(0, SCRIPT_DIR)
import credo_pane_guard as guard  # noqa: E402


def _load_restart():
    spec = importlib.util.spec_from_file_location(
        "credo_self_restart", os.path.join(SCRIPT_DIR, "credo-self-restart.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


csr = _load_restart()  # process helpers, credo mode, config, marker lock

EXIT_GUARD = 3
DEFAULT_BREADCRUMB_MAX_AGE = 7200.0
DEFAULT_HANDOFF = ".credo/process/handoffs/HANDOFF.md"
SAFE_PATH_RE = re.compile(r"[A-Za-z0-9._/~-]{1,200}")
PANE_RE = re.compile(r"%[0-9]+")
ENV_KEYS = ("CLAUDE_CONFIG_DIR", "TMUX", "TMUX_PANE")


def now_iso():
    return datetime.datetime.now().astimezone().isoformat(timespec="seconds")


def log(msg):
    sys.stderr.write("[credo-self-compact %s] %s\n" % (now_iso(), msg))
    sys.stderr.flush()


def envf(name, default):
    return csr.env_float(name, default)


def compact_text(handoff):
    """The exact line typed into the prompt. Short, single line, safe chars only."""
    if not handoff or not SAFE_PATH_RE.fullmatch(handoff):
        handoff = DEFAULT_HANDOFF
    return ("/compact Afterwards reload %s (secured by compact-plus) and continue from it."
            % handoff)


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


# --- target and pane -------------------------------------------------------------

def find_target():
    """(pid, error): the nearest Claude Code ancestor of this process."""
    override = os.environ.get("CREDO_SELF_COMPACT_TARGET_PID")
    if override:
        if not override.isdigit():
            return None, "CREDO_SELF_COMPACT_TARGET_PID is not a pid"
        pids = [int(override)]
    else:
        pids, pid, seen = [], os.getppid(), set()
        while pid > 1 and pid not in seen and len(seen) < 64:
            seen.add(pid)
            pids.append(pid)
            pid = csr.read_ppid(pid)
    for pid in pids:
        if csr.claude_exe_end(csr.read_cmdline(pid), csr.read_exe(pid)) is not None \
                and csr.alive(pid):
            return pid, None
    return None, "no Claude Code process found in the parent chain"


def owner_error(pane, socket, target, start):
    """None when `pane` belongs to the target Claude (csr.pane_owner_error)."""
    return csr.pane_owner_error(pane, socket, target, start)


def session_id():
    """(sid, error) of THIS session."""
    sid = (os.environ.get("CREDO_SELF_COMPACT_SESSION_ID")
           or os.environ.get("CLAUDE_CODE_SESSION_ID") or "")
    if not sid:
        return "", "no session id (CLAUDE_CODE_SESSION_ID is not set)"
    if not re.fullmatch(r"[A-Za-z0-9._-]+", sid) or sid in (".", ".."):
        return "", "session id has unexpected characters"
    return sid, None


def state_files(state, sid):
    """(marker, log, plan file) of one session."""
    return (os.path.join(state, "self-compact-%s.json" % sid),
            os.path.join(state, "self-compact-%s.log" % sid),
            os.path.join(state, "self-compact-plan-%s.json" % sid))


def fmt_age(seconds):
    s = int(seconds)
    if s >= 3600 and s % 3600 == 0:
        return "%dh" % (s // 3600)
    if s >= 60:
        return "%dm" % (s // 60)
    return "%ds" % s


def breadcrumb(config_dir, sid):
    """(handoff path or None, age in seconds or None)."""
    d = os.environ.get("CREDO_REHYDRATE_DIR") or os.path.join(config_dir, "credo", "rehydrate")
    path = os.path.join(d, sid)
    try:
        age = time.time() - os.stat(path).st_mtime
        with open(path) as fh:
            return (fh.readline().strip() or DEFAULT_HANDOFF), age
    except OSError:
        return None, None


def gather(args):
    """(plan, errors). Read-only."""
    errors = []
    plan = {"delay": args.delay, "timeout": args.timeout}
    sid, serr = session_id()
    if serr:
        errors.append(serr)
    plan["session_id"] = sid
    cfg_env = os.environ.get("CLAUDE_CONFIG_DIR")
    pid, err = find_target()
    tenv = {}
    if err:
        errors.append(err)
    else:
        plan["target_pid"] = pid
        plan["target_start"] = csr.proc_start(pid)
        tenv = csr.read_environ_keys(pid, ENV_KEYS)
        if tenv is None:
            errors.append("cannot read the environment of the Claude process %d" % pid)
            tenv = {}
        else:
            cfg_env = tenv.get("CLAUDE_CONFIG_DIR")
    config_dir = os.path.abspath(cfg_env) if cfg_env else \
        os.path.join(os.path.expanduser("~"), ".claude")
    plan["config_dir"] = config_dir
    plan["config_explicit"] = bool(cfg_env)
    plan["credo_mode"] = csr.read_credo_mode(config_dir, sid) if sid else None
    state = os.path.join(config_dir, "credo")
    plan["marker"], plan["log"], plan["plan_file"] = state_files(state, sid or "none")
    pane = tenv.get("TMUX_PANE") or ""
    if not err:
        if not tenv.get("TMUX") or not pane:
            errors.append("not running inside tmux (the Claude process has no "
                          "TMUX/TMUX_PANE); self-compact needs its own tmux pane")
        elif not PANE_RE.fullmatch(pane):
            errors.append("TMUX_PANE %r is not a pane id" % pane)
        elif not shutil.which("tmux"):
            errors.append("tmux is not on PATH")
        else:
            plan["pane"] = pane
            plan["socket"] = guard.socket_from_tmux_env(tenv.get("TMUX"))
            oerr = owner_error(pane, plan["socket"], pid, plan["target_start"])
            if oerr:
                errors.append(oerr)
    if args.handoff and not SAFE_PATH_RE.fullmatch(args.handoff):
        errors.append("--handoff must be a plain path (letters, digits, . _ / ~ -)")
    crumb, age = breadcrumb(config_dir, sid) if sid else (None, None)
    # --handoff only replaces the path typed into /compact; a fresh breadcrumb (proof
    # that compact-plus secured this session) is required either way
    handoff = args.handoff or crumb
    if sid and crumb is None:
        errors.append("no compact-plus breadcrumb for session %s - run compact-plus first "
                      "(it secures the state and drops the rehydrate breadcrumb)" % sid)
    elif sid and age > args.max_breadcrumb_age:
        errors.append("the compact-plus breadcrumb for session %s is older than %s (%s old) "
                      "- run compact-plus again so the secured state is current "
                      "(--max-breadcrumb-age changes the limit)"
                      % (sid, fmt_age(args.max_breadcrumb_age), fmt_age(age)))
    plan["handoff"] = handoff or DEFAULT_HANDOFF
    plan["text"] = compact_text(plan["handoff"])
    return plan, errors


def print_plan(plan, errors, live_state=None):
    p = print
    p("credo self-compact plan (dry run, nothing typed)")
    p("  session id:   %s" % (plan.get("session_id") or "-"))
    p("  target pid:   %s" % plan.get("target_pid", "-"))
    p("  config dir:   %s" % plan.get("config_dir"))
    p("  own pane:     %s (tmux socket %s)" % (plan.get("pane") or "-",
                                               plan.get("socket") or "default"))
    p("  credo mode:   %s" % (plan.get("credo_mode") or "not set"))
    if plan.get("credo_mode") == "autonomous":
        p("  owner rule:   autonomous -> run --auto (no question)")
    else:
        p("  owner rule:   interactive -> ask once via the Ask tool; only after an "
          "explicit yes: run --user-confirmed")
    p("  typed text:   %s" % plan.get("text"))
    p("  wait:         until idle + empty input + no dialog (2 probes), timeout %ss"
      % csr.fmt_num(plan.get("timeout") or 0))
    p("  background:   running background subagents / shells / monitors do not block "
      "(they survive /compact)")
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
    url = os.environ.get("CREDO_SELF_COMPACT_NTFY_URL")
    if url == "off":
        log("ntfy disabled: %s - %s" % (title, body))
        return
    if not url:
        topic = csr.config_get("personal.ntfy_topic", plan["config_dir"],
                               plan["config_explicit"])
        if not topic:
            log("ntfy not configured: %s - %s" % (title, body))
            return
        server = csr.config_get("personal.ntfy_server", plan["config_dir"],
                                plan["config_explicit"]) or "https://ntfy.sh"
        url = server.rstrip("/") + "/" + topic
    req = urllib.request.Request(url, data=body.encode("utf-8"), method="POST",
                                 headers={"Title": title, "Priority": "high"})
    try:
        urllib.request.urlopen(req, timeout=15).read()
        log("ntfy sent: %s" % title)  # never log the url (topic is a secret)
    except Exception as exc:
        log("ntfy failed: %s" % type(exc).__name__)


def write_marker(plan, status, extra=None):
    data = {"session_id": plan.get("session_id"), "pane": plan.get("pane"),
            "started": plan.get("started"), "status": status, "updated": now_iso(),
            "mode": plan.get("run_mode"), "worker_pid": plan.get("worker_pid"),
            "text": plan.get("text")}
    if extra:
        data.update(extra)
    csr.write_json(plan["marker"], data)


def marker_cancelled(plan):
    m = csr.read_marker(plan["marker"])
    return bool(m and m.get("status") == "cancelled" and m.get("started") == plan.get("started"))


def is_worker(pid):
    argv = csr.read_cmdline(pid)
    return "_worker" in argv and any(a.endswith("credo-self-compact.py") for a in argv)


# --- worker ----------------------------------------------------------------------

class Cancelled(Exception):
    pass


def send_keys(plan, keys, literal=False):
    """The ONLY place that sends keys. Always the resolved own pane."""
    pane = plan["pane"]
    if not PANE_RE.fullmatch(pane or ""):
        raise RuntimeError("refusing to send keys: no valid own pane")
    argv = guard.tmux_base(plan.get("socket")) + ["send-keys", "-t", pane]
    argv += (["-l", keys] if literal else [keys])
    r = subprocess.run(argv, capture_output=True, text=True, timeout=10)
    return r.returncode == 0


def norm(s):
    return "".join((s or "").split())


def worker(plan_file):
    with open(plan_file) as fh:
        plan = json.load(fh)
    plan["worker_pid"] = os.getpid()
    pane, sock = plan["pane"], plan.get("socket")
    log("worker started for session %s, pane %s, timeout %ss"
        % (plan["session_id"], pane, csr.fmt_num(plan["timeout"])))

    def on_term(*_):
        raise Cancelled()

    signal.signal(signal.SIGTERM, on_term)

    owner_fail = []

    def probe():
        oerr = owner_error(pane, sock, plan["target_pid"], plan["target_start"])
        if oerr:
            owner_fail.append(oerr)
            return False, "pane ownership lost: " + oerr
        return guard.probe_pane(pane, sock, block_on_background=False)

    def stop():
        return bool(owner_fail) or marker_cancelled(plan)

    try:
        end = time.time() + max(0.0, float(plan.get("delay") or 0))
        while time.time() < end:
            if marker_cancelled(plan):
                raise Cancelled()
            time.sleep(min(0.5, max(0.0, end - time.time())))
        ok, reason = guard.wait_until_safe(
            probe, plan["timeout"], poll=envf("CREDO_SELF_COMPACT_POLL", 2.0),
            recheck=envf("CREDO_SELF_COMPACT_RECHECK", 1.5),
            should_stop=stop, on_state=lambda r: log("pane state: %s" % r))
        if owner_fail:
            ok, reason = False, "pane ownership lost: " + owner_fail[0]
        elif reason == "cancelled":
            raise Cancelled()
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        with csr.MarkerLock(plan["marker"]):
            if marker_cancelled(plan):
                raise Cancelled()
            if ok:
                write_marker(plan, "typing")
            else:
                write_marker(plan, "failed: %s" % ("pane ownership" if owner_fail
                                                   else "not idle"), {"detail": reason})
    except Cancelled:
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        log("self-compact cancelled; nothing typed")
        return 0
    if not ok:
        log("gave up: %s" % reason)
        ntfy("credo self-compact gave up",
             "Session %s: /compact was not typed (%s). Run /compact by hand when ready."
             % (plan["session_id"], reason), plan)
        return 1
    text = plan["text"]
    if not send_keys(plan, text, literal=True):
        write_marker(plan, "failed: send-keys")
        log("send-keys (text) failed")
        ntfy("credo self-compact failed", "Session %s: typing /compact failed."
             % plan["session_id"], plan)
        return 1
    log("typed: %s" % text)
    time.sleep(envf("CREDO_SELF_COMPACT_KEY_PAUSE", 0.5))
    # the full check again, now expecting exactly the typed line: owner, copy mode,
    # busy, dialog / menu and the input content (background work never blocks)
    oerr = owner_error(pane, sock, plan["target_pid"], plan["target_start"])
    safe, why = (False, "pane ownership lost: " + oerr) if oerr else \
        guard.probe_pane(pane, sock, expect=text, block_on_background=False)
    if not safe:
        # someone typed in between, a dialog opened, ...: never press Enter
        write_marker(plan, "failed: typed text not confirmed", {"detail": why})
        log("pre-Enter check failed (%s); NOT pressing Enter" % why)
        ntfy("credo self-compact stopped",
             "Session %s: the pane was not safe after typing the /compact line (%s), so "
             "Enter was not pressed. Check the prompt of that session."
             % (plan["session_id"], why), plan)
        return 1
    if not send_keys(plan, "Enter"):
        write_marker(plan, "failed: send-keys Enter")
        log("send-keys Enter failed")
        return 1
    log("Enter sent")
    result = "sent (unconfirmed)"
    end = time.time() + envf("CREDO_SELF_COMPACT_CONFIRM_WAIT", 10.0)
    while time.time() < end:
        seen = guard.input_content(guard.capture(pane, sock))
        if seen is not None and norm(seen) != norm(text):
            result = "sent"
            break
        time.sleep(0.5)
    write_marker(plan, result)
    log("/compact %s" % result)
    return 0


def spawn_worker(plan):
    state = os.path.dirname(plan["marker"])
    os.makedirs(state, exist_ok=True)
    plan_file = plan["plan_file"]
    with open(plan_file, "w") as fh:
        json.dump(plan, fh)
    logfh = open(plan["log"], "a")
    proc = subprocess.Popen([sys.executable, SCRIPT_PATH, "_worker", plan_file],
                            stdin=subprocess.DEVNULL, stdout=logfh, stderr=logfh,
                            close_fds=True, start_new_session=True, cwd="/")
    logfh.close()
    return proc.pid


def pending_worker(marker):
    m = csr.read_marker(marker)
    if not m or m.get("status") != "pending":
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
        ntfy("credo self-compact refused",
             "Not compacting session %s: %s" % (plan.get("session_id") or "?",
                                                "; ".join(errors)), plan)
        return 1
    other = pending_worker(plan["marker"])
    if other:
        print("REFUSED: a self-compact is already pending (worker %d); cancel it first" % other)
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
    print("credo self-compact: worker %d detached for pane %s; it types '%s' once the "
          "session is idle with an empty input field (timeout %ss). Log: %s"
          % (plan["worker_pid"], plan["pane"], plan["text"], csr.fmt_num(plan["timeout"]),
             plan["log"]))
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
    marker = state_files(state_dir(), sid)[0]
    with csr.MarkerLock(marker):
        m = csr.read_marker(marker)
        status = (m or {}).get("status") or "none"
        if status != "pending":
            print("nothing to cancel for session %s (self-compact status: %s)" % (sid, status))
            return 1
        if m.get("session_id") != sid:
            print("nothing to cancel: the marker belongs to session %s, not %s"
                  % (m.get("session_id") or "?", sid))
            return 1
        m["status"] = "cancelled"
        m["cancelled"] = m["updated"] = now_iso()
        csr.write_json(marker, m)
    pid = m.get("worker_pid")
    killed = False
    if isinstance(pid, int) and csr.alive(pid) and is_worker(pid):
        try:
            os.kill(pid, signal.SIGTERM)
            killed = True
        except OSError:
            pass
    print("credo self-compact cancelled (session %s)%s" % (
        m.get("session_id") or "?",
        "; worker %d terminated" % pid if killed else "; no waiting worker found"))
    return 0


def cmd_status(args):
    sid, serr = session_id()
    if serr:
        print("cannot show status: %s" % serr)
        return 1
    state = state_dir()
    marker, logf, _ = state_files(state, sid)
    m = csr.read_marker(marker)
    if not m:
        print("no self-compact marker for session %s in %s" % (sid, state))
    else:
        print("state: %s; pane: %s; started: %s" % (m.get("status") or "?",
                                                   m.get("pane") or "-",
                                                   m.get("started") or "-"))
        print(json.dumps(m, indent=2))
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
    ap = argparse.ArgumentParser(prog="credo-self-compact.py")
    ap.add_argument("action", nargs="?", default="check",
                    choices=("check", "run", "cancel", "status"))
    ap.add_argument("--auto", action="store_true",
                    help="credo autonomous mode only: no question asked")
    ap.add_argument("--user-confirmed", action="store_true",
                    help="the user said yes via the Ask tool in this interactive session; "
                         "never pass it without that answer")
    ap.add_argument("--delay", type=float, default=3.0,
                    help="seconds before the first pane probe (default 3)")
    ap.add_argument("--timeout", type=float, default=1800.0,
                    help="give up when the session is not idle within this many seconds "
                         "(default 1800)")
    ap.add_argument("--handoff", default=None,
                    help="handoff path named in the /compact instructions (default: the "
                         "path in the compact-plus breadcrumb); only the typed path, a fresh "
                         "breadcrumb is still required")
    ap.add_argument("--no-background-work", action="store_true",
                    help=argparse.SUPPRESS)  # accepted no-op: background work survives /compact
    ap.add_argument("--max-breadcrumb-age", type=float,
                    default=envf("CREDO_SELF_COMPACT_BREADCRUMB_MAX_AGE",
                                 DEFAULT_BREADCRUMB_MAX_AGE),
                    help="refuse when the compact-plus breadcrumb is older than this many "
                         "seconds (default 7200 = 2 h, env "
                         "CREDO_SELF_COMPACT_BREADCRUMB_MAX_AGE)")
    args = ap.parse_args(argv)
    if args.timeout <= 0 or args.delay < 0 or args.max_breadcrumb_age <= 0:
        ap.error("--timeout and --max-breadcrumb-age must be > 0 and --delay >= 0")
    return {"check": cmd_check, "run": cmd_run, "cancel": cmd_cancel,
            "status": cmd_status}[args.action](args)


if __name__ == "__main__":
    sys.exit(main())
