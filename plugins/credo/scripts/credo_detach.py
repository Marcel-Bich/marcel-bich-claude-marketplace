"""credo_detach.py - start a long-running credo daemon fully detached from its caller,
plus the log helpers that make its life and death traceable afterwards.

Shared by the LAN relay (credo-peer-lan.py, item #203) and the WSL <-> Windows peer
bridge (credo-win-bridge.py, item #206). Both used to be started from a Claude Code
hook; a child started that way lives in the systemd scope of the Claude Code session
(e.g. a claude-limit.slice run-*.scope with KillMode=control-group), so the end or stop
of that session took the daemon along with a SIGTERM and nothing in its log said why.

Spawn (spawn_detached):
  - Linux with a systemd user manager: its own transient user service via
    `systemd-run --user --collect` (app.slice), outside the caller's cgroup scope,
    process group and session. A transient unit does not inherit the caller's
    environment: it gets a lean allowlist (systemd_env).
  - otherwise (macOS, WSL without systemd, containers, systemd-run not usable): a double
    fork with setsid and SIGHUP ignored; the caller's environment minus the session-bound
    and secret-like CREDO_* names and a session's TMPDIR (fork_env).
  stdin is /dev/null and stdout/stderr are appended to the daemon log either way.

Logging: log_stamp() (ISO 8601 local time with milliseconds and offset),
process_context() / signal_reason() (ppid, pgid, sid, how it was spawned, cgroup) and
install_log_excepthooks(), so a shutdown always names its reason.

Python 3 stdlib only.
"""

import os
import re
import shutil
import signal
import subprocess
import sys
import threading
import time

SPAWN_MODES = ("auto", "systemd", "setsid")
SYSTEMD_RUN_TIMEOUT = 15.0
# environment handed to a systemd-run daemon: these names, every LC_* and every CREDO_*
# variable that env_dropped() keeps. Session-bound values (TMPDIR of a session,
# WSL_INTEROP of one terminal, session ids) are left out on purpose: the daemon outlives
# the session that started it. Windows interop works from a user service without
# WSL_INTEROP (checked with cmd.exe /c ver and a stdio powershell.exe, items #203/#206).
SPAWN_ENV_NAMES = (
    "PATH", "HOME", "USER", "LOGNAME", "LANG", "LANGUAGE", "TZ",
    "XDG_CONFIG_HOME", "XDG_STATE_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME",
    "XDG_RUNTIME_DIR", "CLAUDE_CONFIG_DIR", "CODEX_HOME", "WSL_DISTRO_NAME",
)
# session-bound values (one session's id, pid, scratchpad) never reach a daemon
SPAWN_ENV_SESSION_RE = re.compile(r"SESSION_ID|TARGET_PID|SCRATCHPAD", re.I)
# names that may carry a secret (a ntfy topic in a *_NTFY_URL, tokens, cookies, ...)
SPAWN_ENV_SECRET_RE = re.compile(
    r"TOKEN|SECRET|PASSW|CREDENTIAL|_KEY$|APIKEY|NTFY|URL|AUTH|COOKIE|PSK", re.I)


# ---------------------------------------------------------------------------
# environment
# ---------------------------------------------------------------------------
def env_dropped(k, skip=()):
    """True for a CREDO_* variable that must not reach a detached daemon: session-bound,
    secret-like, or one of `skip` (the caller's own launcher-only names)."""
    return (k in skip or bool(SPAWN_ENV_SESSION_RE.search(k))
            or bool(SPAWN_ENV_SECRET_RE.search(k)))


def spawn_mode(var):
    """The spawn mode from environment variable `var` (auto | systemd | setsid)."""
    mode = str(os.environ.get(var, "auto")).strip().lower()
    return mode if mode in SPAWN_MODES else "auto"


def systemd_env(skip=(), pinned=None):
    """The environment for a systemd-run daemon (allowlist, see SPAWN_ENV_NAMES), as a
    dict, plus `pinned` (name -> value) on top."""
    env = {}
    for k, v in os.environ.items():
        if "\n" in v or "\0" in v:
            continue
        if k in SPAWN_ENV_NAMES or k.startswith("LC_"):
            env[k] = v
        elif k.startswith("CREDO_") and not env_dropped(k, skip):
            env[k] = v
    env.update(pinned or {})
    return env


def fork_env(skip=(), pinned=None):
    """The environment for a double-forked daemon: the caller's environment minus the
    CREDO_* names env_dropped() drops and a session's TMPDIR (purged when that session
    ends), plus `pinned`. WSL_INTEROP stays: without systemd it is the only way such a
    daemon reaches Windows tools."""
    env = {k: v for k, v in os.environ.items()
           if not (k.startswith("CREDO_") and env_dropped(k, skip)) and k != "TMPDIR"}
    env.update(pinned or {})
    return env


# ---------------------------------------------------------------------------
# spawn
# ---------------------------------------------------------------------------
def spawn_systemd(argv, log_path, unit, description, env, log=None):
    """Start argv as its own transient systemd user service (systemd-run --user
    --collect). The unit lives in the user manager's app.slice, outside the cgroup scope
    and the process group of the caller, so the end or stop of the Claude Code session
    (or its systemd scope, e.g. a CPU-limit slice) that started it never reaches it.
    Returns the daemon pid, or None when systemd-run is not usable here (the caller then
    falls back to the double fork). Raises RuntimeError when the unit started but its
    main process is already gone."""
    if not sys.platform.startswith("linux"):
        return None
    exe = shutil.which("systemd-run")
    sysctl = shutil.which("systemctl")
    if not exe or not sysctl:
        return None
    # StandardOutput=append: needs a path without whitespace (property value syntax)
    if any(c.isspace() for c in log_path):
        return None
    cmd = [exe, "--user", "--quiet", "--collect", "--unit=" + unit,
           "--description=" + description,
           "--property=StandardInput=null",
           "--property=StandardOutput=append:" + log_path,
           "--property=StandardError=append:" + log_path,
           "--property=WorkingDirectory=/",
           "--property=KillMode=control-group"]
    cmd += ["--setenv=%s=%s" % (k, v) for k, v in sorted(env.items())]
    cmd += ["--"] + list(argv)
    try:
        r = subprocess.run(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                           stderr=subprocess.PIPE, timeout=SYSTEMD_RUN_TIMEOUT, cwd="/")
    except (OSError, subprocess.SubprocessError):
        return None
    if r.returncode != 0:
        if log:
            log("systemd-run not usable (rc=%d: %s); falling back to a double fork"
                % (r.returncode, (r.stderr or b"").decode("utf-8", "replace").strip()[:200]))
        return None
    try:
        q = subprocess.run([sysctl, "--user", "show", "-p", "MainPID", "--value",
                            unit + ".service"], stdin=subprocess.DEVNULL,
                           stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                           timeout=SYSTEMD_RUN_TIMEOUT, cwd="/")
        pid = int((q.stdout or b"0").decode().strip() or "0")
    except (OSError, subprocess.SubprocessError, ValueError):
        pid = 0
    if pid <= 0:
        raise RuntimeError("unit %s.service started but has no main process" % unit)
    return pid


def spawn_double_fork(argv, log_path, env):
    """Classic daemonization: fork, setsid (new session, own process group, no
    controlling terminal), fork again (the daemon is no session leader and is reparented
    at once), SIGHUP ignored, stdin /dev/null, stdout/stderr appended to log_path, cwd /.
    Returns the daemon (grandchild) pid. Used where no systemd user manager answers
    (macOS, WSL without systemd, containers). Note: this leaves the process group and
    session of the caller, not a cgroup scope (only systemd-run does that)."""
    argv = list(argv)
    rfd, wfd = os.pipe()
    pid = os.fork()
    if pid == 0:  # first child
        try:
            os.close(rfd)
            os.setsid()
            gpid = os.fork()
            if gpid == 0:  # the daemon
                try:
                    os.close(wfd)
                    signal.signal(signal.SIGHUP, signal.SIG_IGN)
                    os.chdir("/")
                    nfd = os.open(os.devnull, os.O_RDONLY)
                    lfd = os.open(log_path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
                    os.dup2(nfd, 0)
                    os.dup2(lfd, 1)
                    os.dup2(lfd, 2)
                    os.closerange(3, 65536)
                    os.execve(argv[0], argv, env)
                finally:
                    os._exit(127)
            os.write(wfd, str(gpid).encode())
        finally:
            os._exit(0)
    os.close(wfd)
    data = b""
    try:
        while True:
            chunk = os.read(rfd, 64)
            if not chunk:
                break
            data += chunk
    finally:
        os.close(rfd)
        try:
            os.waitpid(pid, 0)
        except ChildProcessError:
            pass
    try:
        return int(data.decode() or "0") or None
    except ValueError:
        return None


def spawn_detached(argv, log_path, mode, unit, description, systemd_env_dict, fork_env_dict,
                   spawned_var, mode_var, log=None):
    """Start argv fully detached from the caller and return its pid. Mode "auto" or
    "systemd": its own transient user service (spawn_systemd); "systemd" fails instead
    of falling back. Otherwise, or when systemd-run is not usable, a double fork
    (spawn_double_fork). `spawned_var` is set in the daemon's environment to how it was
    spawned ("systemd:<unit>.service" or "double-fork"), which process_context() logs;
    `mode_var` names the mode variable in errors. The log directory is created first."""
    os.makedirs(os.path.dirname(log_path) or ".", exist_ok=True)
    if mode in ("auto", "systemd"):
        env = dict(systemd_env_dict)
        env[spawned_var] = "systemd:%s.service" % unit
        pid = spawn_systemd(argv, log_path, unit, description, env, log)
        if pid:
            return pid
        if mode == "systemd":
            raise RuntimeError("systemd-run --user is not usable here (%s=systemd)" % mode_var)
    env = dict(fork_env_dict)
    env[spawned_var] = "double-fork"
    pid = spawn_double_fork(argv, log_path, env)
    if not pid:
        raise RuntimeError("double fork did not report a daemon pid")
    return pid


# ---------------------------------------------------------------------------
# logging helpers
# ---------------------------------------------------------------------------
def log_stamp():
    """ISO 8601 local time with offset and milliseconds, e.g. 2026-01-02T03:04:05.678+01:00."""
    try:
        now = time.time()
        local = time.localtime(now)
        off = time.strftime("%z", local)
        if len(off) == 5:
            off = off[:3] + ":" + off[3:]
        return "%s.%03d%s" % (time.strftime("%Y-%m-%dT%H:%M:%S", local),
                              int((now % 1) * 1000), off)
    except Exception:
        return "?"


def install_log_excepthooks(log):
    """Route uncaught exceptions of the main thread and of worker threads through log(),
    so a crash lands in the daemon log with a timestamp instead of a bare traceback."""
    import traceback

    def _main_hook(etype, value, tb):
        log("uncaught exception:\n" + "".join(traceback.format_exception(etype, value, tb)))

    def _thread_hook(hook_args):
        if hook_args.exc_type is SystemExit:
            return
        name = getattr(hook_args.thread, "name", "?")
        log("uncaught exception in thread %s:\n%s" % (name, "".join(traceback.format_exception(
            hook_args.exc_type, hook_args.exc_value, hook_args.exc_traceback))))

    sys.excepthook = _main_hook
    if hasattr(threading, "excepthook"):
        threading.excepthook = _thread_hook


def cgroup_text():
    """This process's cgroup (Linux /proc/self/cgroup, the v2 line or the first one), or ""."""
    try:
        with open("/proc/self/cgroup") as fh:
            lines = [ln.strip() for ln in fh if ln.strip()]
    except OSError:
        return ""
    for ln in lines:
        if ln.startswith("0::"):
            return ln[3:]
    return lines[0] if lines else ""


def process_context(spawned_var, with_cgroup=False):
    """Where this process lives: parent pid, process group, session, how it was spawned
    (environment variable `spawned_var`) and (optionally) its cgroup. Logged at start and
    with every shutdown signal, so a kill that comes with a session's process group or
    systemd scope can be told apart from a targeted stop. Never raises."""
    parts = []
    try:
        parts.append("ppid %d" % os.getppid())
        if hasattr(os, "getpgrp"):
            parts.append("pgid %d" % os.getpgrp())
        if hasattr(os, "getsid"):
            parts.append("sid %d" % os.getsid(0))
    except OSError:
        pass
    parts.append("spawned %s" % (os.environ.get(spawned_var) or "in the foreground"))
    if with_cgroup:
        cg = cgroup_text()
        if cg:
            parts.append("cgroup %s" % cg)
    return ", ".join(parts)


def signal_reason(signo, spawned_var):
    """Shutdown reason for a signal: its name plus the process context. Python offers no
    SA_SIGINFO handler, so the sender pid is not available; the parent pid and the
    process group / session show whether the daemon still hung in a caller's tree."""
    try:
        name = signal.Signals(signo).name
    except (ValueError, AttributeError):
        name = "signal %s" % signo
    return "received %s (sender pid unknown; %s)" % (
        name, process_context(spawned_var, with_cgroup=True))
