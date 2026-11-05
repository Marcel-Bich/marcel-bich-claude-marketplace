#!/usr/bin/env python3
"""credo-reminder.py - a periodic quality reminder that the session types into its OWN
tmux pane as a user prompt, so the agent re-reads its rules and verbatim requirements.

Settings: the credo config, key `reminder` (per credo session mode, see
templates/config.default.yaml). The builtin template holds the defaults, so the reminder is
ON without any user config:

    reminder:
      enabled: true                # false switches the whole reminder off
      active: {turns: 20}          # every 20 real user turns, active mode
      passive: {turns: 20}
      autonomous: {minutes: 60}    # every 60 min, autonomous mode (no turns while away)
      paused: {turns: 20}          # autonomous with keep-alive paused: every 20 turns, no time
      text: ""                     # optional one-line override of the built-in text

A mode with neither key (or set to off, or with both keys 0) is off. A mode may set turns
and minutes; whichever comes first triggers. Read with `credo-config.sh get reminder` for
the session (CREDO_SESSION_ID, so the session's project pin applies) and the session's
project dir. Switched off by enabled false, the shell hook exits before python runs, so
nothing is counted, written or started. With every mode off, the turns are still counted, but
no worker starts.

Arming - every real user turn of a session is counted (UserPromptSubmit, hook
hooks/credo-reminder.sh turn). The 10th one arms the session for good; the state is on
disk per session id, so it survives a compact and a resume (same session id). Arming sets
the reference point: the first reminder comes 20 turns or 60 minutes after it. In autonomous mode with the
keep-alive paused (the owner is present) only turns count (reminder.paused.turns), never minutes. Not counted:
injected reminders (prefix "[credo-reminder]"), a bare ".", the credo automated prompts
(self-wake dot, autonomy wake marker, task and system notifications, cross-session messages
and notices) and blank prompts.

Worker - one detached worker per armed session, its pid in the state file. It is started
by SessionStart (hooks/credo-reminder.sh start), at arming, and at a later user turn when it
is no longer running; a start on the same pane keeps the running worker. The worker
re-reads the config every minute (CREDO_REMINDER_REFRESH, test override), checks the trigger
of the current credo mode, and when it is due waits until the pane is idle and no dialog is
open (credo_pane_guard, confirmed twice). A field that holds text (two or more visible
characters, or a paste placeholder) is skipped at once and left as it is; a leftover of one
character is removed first. Otherwise the prompt is typed in one burst (one send-keys), the
pane settles for 0.5 s, the pane is checked once more for an input box without dialog or busy
turn (the text is not compared), and Enter is pressed. Claude Code shows the burst as a paste
placeholder or as text; both are accepted. The reference point (last reminder time and turn)
moves to every attempt. A reminder that could not be sent safely is skipped and counts as
sent. It stops when no mode is configured any more and when the Claude process of its session
is gone. Background work never blocks it.

Subcommands
-----------
  turn    UserPromptSubmit hook: count the turn, arm at the 10th, keep the worker running.
  start   SessionStart hook: start the worker of an armed session (nothing else).
  status  print the state of this session (CLAUDE_CODE_SESSION_ID) and the log tail.

Files (per session id, in <configdir>/credo/): reminder-<sid>.json (state),
reminder-<sid>.log (worker log), reminder-plan-<sid>.json (worker plan). The config dir is
CLAUDE_CONFIG_DIR, default ~/.claude.

Env (tests only, no settings): CREDO_REMINDER_TARGET_PID, CREDO_REMINDER_NTFY_URL ("off" or
a URL), CREDO_REMINDER_REFRESH, CREDO_REMINDER_POLL, CREDO_REMINDER_RECHECK,
CREDO_REMINDER_KEY_PAUSE (the settle before Enter), CREDO_REMINDER_BLOCKED_NOTIFY,
CREDO_CONFIG_SCRIPT (path of credo-config.sh, default the one next to this file).

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


csr = _load_restart()  # process helpers, credo mode, marker lock, ntfy

MARKER = "[credo-reminder]"
DEFAULT_TEXT = ("Check yourself against what we agreed: re-read the credo rules, the open items, "
                "the requirements logs and the handoff - did you keep every agreement so far, "
                "also those from before a compact or from earlier days, and did you declare a "
                "blocker or showstopper that our agreements say is none? A newer decision always "
                "overrides an older one on the same point (e.g. a limit raised from 3 to 6 means "
                "6 now applies), so drop superseded agreements instead of carrying them along. "
                "Make sure every standing agreement is carried into the current handoff so it "
                "survives compacts and does not go stale in an old requirements file. Check the "
                "open-codes footer and drop every code that is answered, verified, superseded, "
                "moved into an item or moot. "
                "Check every open veto code against its item: close it yourself, noted in the handoff, when the item is done or verified and nothing of the decision is still open, or when later work superseded it. Raise a veto only for a decision the owner notices in the product (behaviour, visible text, money, taste, data); internal process decisions go only into the log and the item History. "
                "Keep credo's output format unless something speaks against it: every test, question and veto code carries its emoji wherever it asks something of the user (🧪 T5, ❓ Q4, ✋ V2 in headings, Ask text and mentions), and the reply ends with the open-codes footer. Clean up merged worktrees and branches with credo-worktree-cleanup.sh; a worktree that may still be needed goes to the owner as a question. GO items never just wait on the owner, so classify each stalled one with credo-go-stall.sh and re-check handoff labels against the open DoD. Shortened questions repeat the full copyable command. If anything "
                "drifted, fix it now and continue as agreed.")
MODE_NAMES = ("active", "passive", "autonomous")
ARM_TURNS = 10
# autonomous mode with the keep-alive paused (owner present): turns only, this default when
# reminder.paused is not set (reminder.paused.turns: 0 switches the paused reminder off)
PAUSED_TURNS = 20
# appended, once per session, to the first reminder that is sent (one line, as typed)
NOTICE = ("Note (first reminder of this session): the periodic reminder is on by default. To "
          "switch it off, set reminder.enabled: false in your credo config, or set "
          "reminder.<mode>.turns: 0 and reminder.<mode>.minutes: 0 for one mode (mode: active, "
          "passive or autonomous). Mention this to the user in one line.")
REFRESH_SECONDS = 60.0
AUTOMATED_PREFIXES = (MARKER, "[CREDO-AUTONOMY-WAKE]", "<task-notification>",
                      "[SYSTEM NOTIFICATION - NOT USER INPUT]", "<cross-session-message",
                      "[Cross-session idle notice]", "[Cross-session delivery notice]")
ENV_KEYS = ("CLAUDE_CONFIG_DIR", "TMUX", "TMUX_PANE")
PANE_RE = re.compile(r"%[0-9]+")
SID_RE = re.compile(r"[A-Za-z0-9._-]+")


def now_iso():
    return datetime.datetime.now().astimezone().isoformat(timespec="seconds")


def log(msg):
    sys.stderr.write("[credo-reminder %s] %s\n" % (now_iso(), msg))
    sys.stderr.flush()


# --- settings and pure rules -----------------------------------------------------------

def _pos_int(value):
    if isinstance(value, bool):
        return None
    try:
        n = int(value)
    except (TypeError, ValueError):
        return None
    return n if n > 0 else None


def _pos_float(value):
    if isinstance(value, bool):
        return None
    try:
        x = float(value)
    except (TypeError, ValueError):
        return None
    return x if 0 < x < 1e6 else None


def switched_off(value):
    """True for an `enabled` value that switches the reminder off (false, "false", no, off, 0)."""
    if value is False:
        return True
    return value is not None and not isinstance(value, bool) and \
        str(value).strip().lower() in ("false", "no", "off", "0")


def parse_triggers(data):
    """{mode: {"turns": int or None, "minutes": float or None}} for every credo mode whose
    entry in the `reminder` map sets turns or minutes. Anything else is off, and so is every
    mode when `enabled` is false."""
    out = {}
    if not isinstance(data, dict) or switched_off(data.get("enabled")):
        return out
    for mode in MODE_NAMES:
        spec = data.get(mode)
        if not isinstance(spec, dict):
            continue
        turns, minutes = _pos_int(spec.get("turns")), _pos_float(spec.get("minutes"))
        if turns or minutes:
            out[mode] = {"turns": turns, "minutes": minutes}
    paused = data.get("paused")
    if out.get("autonomous") and isinstance(paused, dict) and "turns" in paused:
        # only next to an autonomous trigger (alone it would start an idle worker); kept even
        # when 0: an explicit 0 switches the paused reminder off
        out["paused"] = {"turns": _pos_int(paused.get("turns")), "minutes": None}
    return out


def effective_trigger(triggers, mode, paused):
    """The trigger for the current mode. In autonomous mode with the keep-alive paused (the
    owner is present) only turns count: reminder.paused.turns, else PAUSED_TURNS, as long as
    the autonomous mode is on at all. None = no reminder now."""
    trig = triggers.get(mode) if mode in MODE_NAMES else None
    if mode == "autonomous" and paused and trig:
        trig = triggers.get("paused") or {"turns": PAUSED_TURNS, "minutes": None}
        return trig if trig.get("turns") else None
    return trig


def reminder_prompt(raw_text):
    """The line typed into the pane: the marker plus the text (one line, built-in text when
    the configured text is empty)."""
    body = " ".join((raw_text or "").split())
    return "%s %s" % (MARKER, body or DEFAULT_TEXT)


def is_user_turn(prompt):
    """True for a prompt a person typed. Injected reminders, a bare "." (the credo wake
    dot), automated prompts and blank prompts are not user turns."""
    p = (prompt or "").strip()
    return bool(p) and p != "." and not p.startswith(AUTOMATED_PREFIXES)


def trigger_due(trig, turns, last_turn, now_ts, last_ts):
    """True when the trigger of a mode fires: `turns` real user turns since the reference
    turn, or `minutes` since the reference time - whichever comes first."""
    if trig.get("turns") and turns - last_turn >= trig["turns"]:
        return True
    if trig.get("minutes") and last_ts is not None and now_ts - last_ts >= trig["minutes"] * 60.0:
        return True
    return False


def refresh_seconds():
    try:
        return max(0.1, float(os.environ.get("CREDO_REMINDER_REFRESH", REFRESH_SECONDS)))
    except ValueError:
        return REFRESH_SECONDS


def config_script():
    return os.environ.get("CREDO_CONFIG_SCRIPT") or os.path.join(SCRIPT_DIR, "credo-config.sh")


def session_cwd():
    """The session's project dir (CLAUDE_PROJECT_DIR when set, else the hook's cwd)."""
    d = os.environ.get("CLAUDE_PROJECT_DIR") or ""
    return d if os.path.isdir(d) else os.getcwd()


def config_get(key, sid, cwd):
    """Raw output of `credo-config.sh get <key>` for this session, or None. The session id
    is passed on so the session's project pin applies; cwd is the session's project."""
    env = dict(os.environ)
    env["CREDO_SESSION_ID"] = sid
    try:
        r = subprocess.run(["bash", config_script(), "get", key], env=env,
                           cwd=cwd if os.path.isdir(cwd) else "/", capture_output=True,
                           text=True, timeout=20)
    except (OSError, subprocess.SubprocessError):
        return None
    return r.stdout if r.returncode == 0 else None


def settings(sid, cwd):
    """(triggers, text) of the `reminder` config of this session, or None when the config
    cannot be read."""
    raw = config_get("reminder", sid, cwd)
    if raw is None:
        return None
    try:
        data = json.loads(raw)
    except ValueError:
        return None
    if not isinstance(data, dict):
        return None
    text = data.get("text")
    return parse_triggers(data), reminder_prompt("" if text is None else str(text))


# --- files and state -------------------------------------------------------------------

def config_dir():
    cfg = os.environ.get("CLAUDE_CONFIG_DIR")
    return os.path.abspath(cfg) if cfg else os.path.join(os.path.expanduser("~"), ".claude")


def paths(cfg, sid):
    """(state, log, plan) files of one session."""
    base = os.path.join(cfg, "credo")
    return (os.path.join(base, "reminder-%s.json" % sid),
            os.path.join(base, "reminder-%s.log" % sid),
            os.path.join(base, "reminder-plan-%s.json" % sid))


def read_state(path):
    return csr.read_marker(path) or {}


def update_state(path, fn=None, **fields):
    """Read-modify-write of a state file under its lock (the hook and the worker both
    write it)."""
    with csr.MarkerLock(path):
        st = csr.read_marker(path) or {}
        if fn:
            fn(st)
        st.update(fields)
        st["updated"] = now_iso()
        csr.write_json(path, st)
        return st


def valid_sid(sid):
    return bool(sid) and bool(SID_RE.fullmatch(sid)) and sid not in (".", "..")


# --- own pane ----------------------------------------------------------------------------

def find_target():
    override = os.environ.get("CREDO_REMINDER_TARGET_PID")
    if override:
        if not override.isdigit():
            return None, "CREDO_REMINDER_TARGET_PID is not a pid"
        pids = [int(override)]
    else:
        pids = csr.ancestors(os.getppid())
    for pid in pids:
        if csr.claude_exe_end(csr.read_cmdline(pid), csr.read_exe(pid)) is not None \
                and csr.alive(pid):
            return pid, None
    return None, "no Claude Code process found in the parent chain"


def gather(sid):
    """(plan, errors) for the own pane of the Claude process above this hook. Read-only."""
    plan = {"session_id": sid, "config_dir": config_dir(),
            "config_explicit": bool(os.environ.get("CLAUDE_CONFIG_DIR"))}
    pid, err = find_target()
    if err:
        return plan, [err]
    link = csr.daemon_link(pid)
    if link.get("error"):
        return plan, [link["error"]]
    owner = link.get("client") or pid
    tenv = csr.pane_env(pid, link, ENV_KEYS)
    if tenv is None:
        return plan, ["cannot read the environment of the Claude process %d" % owner]
    plan.update(agent_pid=pid, agent_start=csr.proc_start(pid), target_pid=owner,
                target_start=csr.proc_start(owner), daemon=csr.daemon_note(link),
                state_sids=csr.state_sids(sid, link))
    errors = []
    pane = tenv.get("TMUX_PANE") or ""
    if not tenv.get("TMUX") or not pane:
        errors.append("not running inside tmux (the Claude process has no TMUX/TMUX_PANE); "
                      "the periodic reminder needs the session's own tmux pane")
    elif not PANE_RE.fullmatch(pane):
        errors.append("TMUX_PANE %r is not a pane id" % pane)
    elif not shutil.which("tmux"):
        errors.append("tmux is not on PATH")
    else:
        plan.update(pane=pane, socket=guard.socket_from_tmux_env(tenv.get("TMUX")))
        oerr = csr.pane_owner_error(pane, plan["socket"], owner, plan["target_start"])
        if oerr:
            errors.append(oerr)
    return plan, errors


def current_mode(plan):
    return csr.read_credo_mode_any(plan["config_dir"], plan.get("state_sids") or
                                   [plan["session_id"]])


def autonomy_paused(plan):
    """True when this session's autonomy keep-alive is paused (credo/autonomy/<sid>/paused)."""
    sids = plan.get("state_sids") or [plan["session_id"]]
    return any(os.path.exists(os.path.join(plan["config_dir"], "credo", "autonomy", s, "paused"))
               for s in sids)


def is_worker(pid):
    argv = csr.read_cmdline(pid)
    return "_worker" in argv and any(a.endswith("credo-reminder.py") for a in argv)


def same_code(pid):
    """True when the worker `pid` runs this very script file (same credo version)."""
    scripts = [a for a in csr.read_cmdline(pid) if a.endswith("credo-reminder.py")]
    return any(os.path.realpath(a) == os.path.realpath(SCRIPT_PATH) for a in scripts)


def worker_running(state_path):
    """True when a worker of THIS credo version runs. A worker of an older version counts as
    not running, so the turn hook calls ensure_worker, which replaces it (#151)."""
    pid = read_state(state_path).get("worker_pid")
    return isinstance(pid, int) and csr.alive(pid) and is_worker(pid) and same_code(pid)


def stop_pid(pid):
    try:
        os.kill(pid, signal.SIGTERM)
    except OSError:
        return
    end = time.time() + 5.0
    while time.time() < end and csr.alive(pid):
        time.sleep(0.1)


# --- hook commands -----------------------------------------------------------------------

def arm_if_ready(sid, state_path):
    """Arm the session when it has a usable own pane; else say why and stay unarmed."""
    plan, errors = gather(sid)
    if errors:
        log("not armed: %s" % "; ".join(errors))
        return False
    now = time.time()

    def arm(st):
        st["armed"] = True
        st["armed_at"] = now_iso()
        st["last_reminder"] = now
        st["last_reminder_turn"] = int(st.get("turns", 0))
    update_state(state_path, arm, session_id=sid)
    log("armed after %d user turns" % ARM_TURNS)
    return True


def ensure_worker(sid, cwd):
    """Start the worker of this armed session, unless one runs on the same pane. A worker
    on another pane (resume in a new pane) is stopped first."""
    plan, errors = gather(sid)
    if errors:
        log("reminder not running: %s" % "; ".join(errors))
        return 1
    state_path, log_path, plan_path = paths(plan["config_dir"], sid)
    pid = read_state(state_path).get("worker_pid")
    if isinstance(pid, int) and csr.alive(pid) and is_worker(pid):
        if read_state(state_path).get("pane") == plan["pane"] and same_code(pid):
            return 0
        # another pane, or a worker of an older credo version (a plugin reload does not
        # restart the detached worker, so it would keep running the old code)
        stop_pid(pid)
    plan.update(cwd=cwd, state=state_path, log=log_path)
    csr.write_json(plan_path, plan)
    os.makedirs(os.path.dirname(log_path), exist_ok=True)
    with open(log_path, "a") as logfh:
        proc = subprocess.Popen([sys.executable, SCRIPT_PATH, "_worker", plan_path],
                                stdin=subprocess.DEVNULL, stdout=logfh, stderr=logfh,
                                close_fds=True, start_new_session=True, cwd="/")
    update_state(state_path, worker_pid=proc.pid, pane=plan["pane"], status="starting")
    log("worker %d started for session %s" % (proc.pid, sid))
    return 0


def switched_on(sid, cwd):
    """True when the session's reminder config has at least one mode trigger. It is read only
    when a worker has to be started, so a turn in steady state costs no config read."""
    cfg = settings(sid, cwd)
    return bool(cfg and cfg[0])


def cmd_turn(sid, prompt):
    if not valid_sid(sid):
        return 0
    cwd = session_cwd()
    state_path = paths(config_dir(), sid)[0]
    if is_user_turn(prompt):
        update_state(state_path, lambda st: st.update(
            turns=int(st.get("turns", 0)) + 1, session_id=sid))
    st = read_state(state_path)
    if not st.get("armed"):
        if int(st.get("turns", 0)) < ARM_TURNS or not arm_if_ready(sid, state_path):
            return 0
    if not worker_running(state_path) and switched_on(sid, cwd):
        ensure_worker(sid, cwd)
    return 0


def cmd_start(sid):
    if not valid_sid(sid):
        return 0
    if not read_state(paths(config_dir(), sid)[0]).get("armed"):
        return 0
    cwd = session_cwd()
    cfg = settings(sid, cwd)
    if not cfg or not cfg[0]:
        return 0
    ensure_worker(sid, cwd)
    return 0


def cmd_status():
    sid = os.environ.get("CLAUDE_CODE_SESSION_ID", "")
    if not valid_sid(sid):
        print("cannot show status: no session id (CLAUDE_CODE_SESSION_ID)")
        return 1
    state_path, log_path, _ = paths(config_dir(), sid)
    st = read_state(state_path)
    if not st:
        print("no periodic reminder state for session %s" % sid)
        return 0
    print(json.dumps(st, indent=2))
    try:
        with open(log_path) as fh:
            print("--- log tail ---")
            sys.stdout.write("".join(fh.readlines()[-20:]))
    except OSError:
        pass
    return 0


# --- worker ------------------------------------------------------------------------------

def ntfy(title, body, plan):
    csr.ntfy(title, body, plan["config_dir"], plan["config_explicit"],
             override_var="CREDO_REMINDER_NTFY_URL", logger=log)


def due_now(plan, trig):
    st = read_state(plan["state"])
    return trigger_due(trig, int(st.get("turns", 0)), int(st.get("last_reminder_turn", 0)),
                       time.time(), st.get("last_reminder"))


def field_holds_text(pane):
    """True when the input field visibly holds text: two or more visible characters, or a
    paste placeholder. An unreadable field is not text, so the wait goes on as before."""
    plan = pane.plan
    cap = guard.capture(plan["pane"], plan.get("socket"))
    content = guard.input_content(cap) if cap is not None else None
    return content is not None and len("".join(content.split())) >= guard.EMPTY_BELOW


def attempt(pane, plan, text, mode, trig):
    """One reminder, when the trigger is still due and the credo mode is unchanged. The pane
    must be idle with no dialog open (a busy turn or a dialog is waited for). A field that
    holds text is skipped at once: it is neither waited for nor touched. Afterwards the
    reference point (time and turn) moves to now, also for a skipped try."""
    status, sent, notice = "waiting", True, False
    try:
        pane.wait_safe(float("inf"), stop=lambda: field_holds_text(pane))
        if current_mode(plan) != mode or not due_now(plan, trig):
            return
        # the first reminder that is actually sent in a session also names the switch
        notice = not read_state(plan["state"]).get("notice_sent")
        wk.send_whole(pane, "%s %s" % (text, NOTICE) if notice else text)
        log("reminder sent")
    except wk.Woken:
        log("reminder skipped: the input field holds text, left as it is")
        status, sent = "skipped: the input field holds text", False
    except wk.StepFailed as exc:
        if exc.status == "failed: pane ownership":
            raise
        log("reminder skipped: %s" % exc.detail)
        status, sent = "skipped: %s" % exc.detail, False
    now = time.time()

    def reference(st):
        st["last_reminder"] = now
        st["last_reminder_turn"] = int(st.get("turns", 0))
        if sent:
            st["last_sent"] = now_iso()
            if notice:
                st["notice_sent"] = True
    update_state(plan["state"], reference, status=status)


def wait_for_owner(pane):
    oerr = pane.owner()
    if oerr:
        raise wk.StepFailed("failed: pane ownership", oerr)


def finish(plan, status):
    """Record the end of the worker; the pid is cleared only when it is still ours."""
    def clear(st):
        if st.get("worker_pid") == os.getpid():
            st.pop("worker_pid", None)
    update_state(plan["state"], clear, status=status)


def worker(plan_path):
    with open(plan_path) as fh:
        plan = json.load(fh)
    update_state(plan["state"], worker_pid=os.getpid(), status="waiting")
    log("worker started for session %s, pane %s" % (plan["session_id"], plan["pane"]))

    def on_term(*_):
        raise wk.Cancelled()

    signal.signal(signal.SIGTERM, on_term)
    pane = wk.Pane(plan, csr.session_owner_check(plan), lambda: False, log,
                   wk.timing("CREDO_REMINDER"),
                   on_blocked=lambda r: ntfy("credo: reminder waiting",
                                             wk.blocked_text("the periodic reminder",
                                                             plan["pane"]), plan))
    cfg, next_refresh = None, 0.0
    try:
        while True:
            if time.time() >= next_refresh:
                fresh = settings(plan["session_id"], plan["cwd"])
                cfg = fresh if fresh is not None else cfg
                if cfg is None or not cfg[0]:
                    raise wk.StepFailed("stopped", "reminder off or config unreadable")
                next_refresh = time.time() + refresh_seconds()
            triggers, text = cfg
            wait_for_owner(pane)
            mode = current_mode(plan)
            trig = effective_trigger(triggers, mode,
                                     mode == "autonomous" and autonomy_paused(plan))
            if trig and due_now(plan, trig):
                attempt(pane, plan, text, mode, trig)
            time.sleep(pane.tim["poll"])
    except wk.Cancelled:
        log("reminder worker terminated")
        finish(plan, "stopped: terminated")
        return 0
    except wk.StepFailed as exc:
        log("reminder worker stopped: %s" % exc.detail)
        finish(plan, "stopped: %s" % exc.detail)
        return 0


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    if argv[:1] == ["_worker"] and len(argv) == 2:
        return worker(argv[1])
    ap = argparse.ArgumentParser(prog="credo-reminder.py")
    ap.add_argument("action", choices=("turn", "start", "status"))
    args = ap.parse_args(argv)
    if args.action == "status":
        return cmd_status()
    try:
        payload = json.loads(sys.stdin.read() or "{}")
    except ValueError:
        payload = {}
    if not isinstance(payload, dict):
        payload = {}
    sid = payload.get("session_id") or os.environ.get("CLAUDE_CODE_SESSION_ID") or ""
    try:
        if args.action == "turn":
            return cmd_turn(sid, payload.get("prompt") or "")
        return cmd_start(sid)
    except Exception as exc:  # a hook never blocks a prompt or a session start
        log("failed: %s" % exc)
        return 0


if __name__ == "__main__":
    sys.exit(main())
