"""credo_linger.py - detect systemd "linger" for the user and PROPOSE enabling it when
credo's daemons run as systemd user services (item #209).

Since #203/#206 the LAN relay (credo-peer-lan.py) and the WSL <-> Windows bridge
(credo-win-bridge.py) start as transient systemd user services (credo_detach.py). Those
belong to the user's systemd manager, which stops at the user's last logout unless
linger is enabled (`loginctl enable-linger <user>`). credo only shows the state and the
proposal; it never runs loginctl enable-linger itself and changes no system state.

Everything here fails silent: no Linux, no loginctl / systemctl, systemd not running, a
timeout or any unexpected output -> "unknown" (None), and callers then print nothing.

Python 3 stdlib only.
"""

import os
import re
import shlex
import shutil
import subprocess
import sys

QUERY_TIMEOUT = 3.0
# transient unit names credo_detach gives the relay and the bridge
UNIT_PATTERNS = ("credo-peer-lan-*.service", "credo-win-bridge-*.service")
RELAY_UNIT_PREFIX = "credo-peer-lan-"
STAMP_NAME = "linger-hint.stamp"
_SAFE_USER_RE = re.compile(r"^[A-Za-z0-9._][A-Za-z0-9._-]*$")


def _run(argv):
    """stdout of argv as text, or None on any error, a non-zero exit or a timeout."""
    exe = shutil.which(argv[0])
    if not exe:
        return None
    try:
        r = subprocess.run([exe] + list(argv[1:]), stdin=subprocess.DEVNULL,
                           stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                           timeout=QUERY_TIMEOUT, cwd="/")
    except (OSError, subprocess.SubprocessError, ValueError):
        return None
    if r.returncode != 0:
        return None
    return (r.stdout or b"").decode("utf-8", "replace")


def current_user():
    """The login name of this process (USER, else the passwd entry), or ""."""
    user = os.environ.get("USER") or os.environ.get("LOGNAME") or ""
    if not user:
        try:
            import pwd
            user = pwd.getpwuid(os.getuid()).pw_name
        except Exception:
            user = ""
    return user


def linger_state(user=None):
    """ "yes" or "no" from `loginctl show-user <user> -p Linger --value`; None when it
    cannot be told (not Linux, no loginctl, no systemd, user unknown, odd output)."""
    if not sys.platform.startswith("linux"):
        return None
    user = user or current_user()
    if not user:
        return None
    out = _run(["loginctl", "show-user", user, "-p", "Linger", "--value"])
    if out is None:
        return None
    val = out.strip().lower()
    return val if val in ("yes", "no") else None


def credo_units():
    """Names of the active credo relay/bridge systemd user services (sorted list), [] when
    none runs that way, None when the systemd user manager cannot be asked."""
    if not sys.platform.startswith("linux"):
        return None
    out = _run(["systemctl", "--user", "list-units", "--no-legend", "--plain",
                "--state=active"] + list(UNIT_PATTERNS))
    if out is None:
        return None
    units = set()
    for line in out.splitlines():
        parts = line.split()
        if parts and parts[0].endswith(".service") and (
                parts[0].startswith(RELAY_UNIT_PREFIX)
                or parts[0].startswith("credo-win-bridge-")):
            units.add(parts[0])
    return sorted(units)


def enable_command(user):
    """The proposal command, shell-quoted when the name needs it."""
    return "loginctl enable-linger %s" % (user if _SAFE_USER_RE.match(user) else shlex.quote(user))


def assess(user=None):
    """(state, units, user) when credo's daemons run as systemd user services and the
    linger state is known; None otherwise (callers then print nothing)."""
    units = credo_units()
    if not units:
        return None
    user = user or current_user()
    state = linger_state(user)
    if state is None:
        return None
    return state, units, user


def risk_lines(units, port=None, token_set=None):
    """The short risk note for enabling linger (list of lines, no indentation)."""
    relay = any(u.startswith(RELAY_UNIT_PREFIX) for u in units)
    lines = ["risk: with linger the user services keep running after logout."]
    if relay:
        where = ("on port %s" % port) if port else "on its port"
        lines.append("the LAN relay then stays reachable %s while nobody is logged in, so "
                     "the shared token and the network allow-list matter more." % where)
    if relay and token_set is False:
        lines.append("no shared token is set: frames are unsigned and the allow-list of the "
                     "bound network is the only boundary (optional: `credo-peer-lan.py token "
                     "--generate`, the same token on every peer, see /credo:peer-lan Token).")
    return lines


def status_lines(port=None, token_set=None, user=None):
    """Lines for `credo-peer-lan.py status` / `check` (empty list when nothing applies)."""
    res = assess(user)
    if res is None:
        return []
    state, units, user = res
    if state == "yes":
        return ["linger: yes for %s (the credo systemd user services keep running after "
                "logout)" % user]
    out = ["linger: no for %s - the credo systemd user services (%s) stop at the last "
           "logout and only come back with the next Claude Code session"
           % (user, ", ".join(units)),
           "  proposal (the owner decides; credo never runs it): %s" % enable_command(user)]
    out += ["  " + ln for ln in risk_lines(units, port, token_set)]
    return out


def hint_text(state, units, user, port=None, token_set=None):
    """The one-time SessionStart hint for the agent (one line), or "" for Linger=yes."""
    if state != "no":
        return ""
    return (
        "[credo-linger] credo's daemons run as systemd user services (%s), but linger is off "
        "for user %s (Linger=no): they stop at the user's last logout and only come back with "
        "the next Claude Code session. Mention it to the user once as a PROPOSAL: `%s` (the "
        "user runs it in their own terminal if they want it; never run it yourself, it "
        "changes system state). %s `credo-peer-lan.py status` shows the state again. In "
        "autonomous mode do not ask, only mention it in the next report. This hint is shown "
        "once per profile. Explain in the user's language (the language of the "
        "conversation); fall back to English if unknown or unsure."
        % (", ".join(units), user, enable_command(user),
           " ".join(s[:1].upper() + s[1:] for s in risk_lines(units, port, token_set))))


def stamp_path(profile_dir=None):
    """The per-profile stamp that keeps the SessionStart hint one-time."""
    base = profile_dir or os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(
        os.path.expanduser("~"), ".claude")
    return os.path.join(base.rstrip("/") or "/", "credo", STAMP_NAME)


def session_hint(port=None, token_set=None, profile_dir=None):
    """The one-time hint: printed text when it applies and the stamp could be written
    first (so it never repeats), else "". Never raises."""
    try:
        stamp = stamp_path(profile_dir)
        if os.path.exists(stamp) or not os.path.isdir(os.path.dirname(stamp)):
            return ""
        res = assess()
        if res is None:
            return ""
        text = hint_text(res[0], res[1], res[2], port, token_set)
        if not text:
            return ""
        with open(stamp, "w") as fh:
            fh.write("shown\n")
        return text
    except Exception:
        return ""
