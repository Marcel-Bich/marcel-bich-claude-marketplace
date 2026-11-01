#!/usr/bin/env python3
"""credo_runtime.py - keep a session's working state alive across a Claude Code restart.

A restart ends the Claude Code process and everything it started. This helper covers the
four things that were lost in practice. Stdlib only. It starts or stops nothing except
the services that were registered explicitly with `service start`.

  keep     snapshot the session scratchpad (helper scripts, collection files, pending
           lists) into .credo/process/runtime/<session>/scratchpad/ plus manifest.json.
           Copies only, never deletes. Used by compact-plus and self-restart.
  service  restart list of background services (keep-alive loops, dev servers). Each
           service gets a durable script under .credo/process/runtime/services/. It runs
           in its own detached tmux session (credo-svc-<name>) when tmux is used, else
           under `systemd-run --user` when systemd is booted, else under nohup.
  pane     tmux pane references by name, written as session:window.pane (purpose, last
           %ID). The name is resolved before use; the stored %ID only tells whether the
           pane still matches. SSH panes are flagged - only the user reconnects them.
  check    the post-restart report (services not running, SSH panes to reconnect, the
           one-shot scratchpad pointer). Called by hooks/credo-session-start.sh.

The root is the git toplevel of the working directory (else the working directory) unless
--root is given. All files live under <root>/.credo/ (git-excluded). Environment, for tests
and unusual layouts: CREDO_RUNTIME_SD_BOOTED_DIR (default /run/systemd/system),
CREDO_RUNTIME_MAX_FILE_BYTES (default 20 MB per scratchpad file).
"""

import argparse
import datetime
import hashlib
import json
import os
import re
import shlex
import shutil
import subprocess
import sys

SCRIPT_PATH = os.path.abspath(__file__)
MAX_FILE_BYTES = 20 * 1024 * 1024
MAX_FILES = 500
MAX_TOTAL_BYTES = 200 * 1024 * 1024
SID_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}")
NAME_RE = re.compile(r"[a-z0-9][a-z0-9-]{0,39}")
TARGET_RE = re.compile(r"[A-Za-z0-9_.-]+:[A-Za-z0-9_.-]+\.[0-9]+")
RESERVED_SIDS = ("services",)
SERVICE_PREFIX = "credo-svc-"
SSH_NAMES = ("ssh", "ssh.exe")
SD_BOOTED_DEFAULT = "/run/systemd/system"


# --- small helpers -------------------------------------------------------------------

def now_iso():
    return datetime.datetime.now().astimezone().isoformat(timespec="seconds")


def valid_sid(sid):
    return bool(sid) and SID_RE.fullmatch(sid) is not None and sid not in RESERVED_SIDS


def valid_name(name):
    return bool(name) and NAME_RE.fullmatch(name) is not None


def find_root(start=None):
    start = os.path.abspath(start or os.getcwd())
    try:
        r = subprocess.run(["git", "-C", start, "rev-parse", "--show-toplevel"],
                           capture_output=True, text=True, timeout=10)
        top = r.stdout.strip() if r.returncode == 0 else ""
    except (OSError, subprocess.SubprocessError):
        top = ""
    return top or start


def runtime_dir(root):
    return os.path.join(root, ".credo", "process", "runtime")


def registry_path(root, kind):
    return os.path.join(runtime_dir(root), kind + ".json")


def session_dir(root, sid):
    return os.path.join(runtime_dir(root), sid)


def services_dir(root):
    return os.path.join(runtime_dir(root), "services")


def read_json(path, default):
    try:
        with open(path) as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return default


def write_json(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(data, fh, indent=2)
        fh.write("\n")
    os.replace(tmp, path)


def load_list(root, kind):
    data = read_json(registry_path(root, kind), {})
    items = data.get(kind) if isinstance(data, dict) else None
    return [i for i in items if isinstance(i, dict)] if isinstance(items, list) else []


def save_list(root, kind, items):
    write_json(registry_path(root, kind), {"version": 1, kind: items})


def run_rc(argv, timeout=10):
    """Exit code of argv, or None when it cannot be run at all."""
    try:
        return subprocess.run(argv, capture_output=True, text=True, timeout=timeout).returncode
    except (OSError, subprocess.SubprocessError):
        return None


def tmux_out(args):
    """Stdout of `tmux args`, stripped of newlines, or None on failure or empty output."""
    try:
        r = subprocess.run(["tmux"] + args, capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        return None
    out = r.stdout.strip("\n") if r.returncode == 0 else ""
    return out or None


# --- keep: scratchpad snapshot -------------------------------------------------------

def max_file_bytes():
    try:
        return int(os.environ.get("CREDO_RUNTIME_MAX_FILE_BYTES", MAX_FILE_BYTES))
    except ValueError:
        return MAX_FILE_BYTES


def sha256_of(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def collect_scratchpad(scratchpad, limit):
    """Returns (found, skipped). found holds (relative path, source path) pairs of regular
    files under the limit; skipped holds {"path", "reason"} dicts. Symlinks are never
    followed or copied."""
    found, skipped = [], []
    for dirpath, dirnames, filenames in os.walk(scratchpad):
        for d in sorted(dirnames):
            full = os.path.join(dirpath, d)
            if os.path.islink(full):
                skipped.append({"path": os.path.relpath(full, scratchpad), "reason": "symlink"})
        dirnames[:] = sorted(d for d in dirnames
                             if not os.path.islink(os.path.join(dirpath, d)))
        for fn in sorted(filenames):
            src = os.path.join(dirpath, fn)
            rel = os.path.relpath(src, scratchpad)
            if os.path.islink(src):
                skipped.append({"path": rel, "reason": "symlink"})
            elif not os.path.isfile(src):
                skipped.append({"path": rel, "reason": "not a regular file"})
            elif os.path.getsize(src) > limit:
                skipped.append({"path": rel, "reason": "larger than %d bytes" % limit})
            else:
                found.append((rel, src))
    return found, skipped


def copy_into(src, dst):
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    tmp = os.path.join(os.path.dirname(dst), "." + os.path.basename(dst) + ".credo-tmp")
    shutil.copy2(src, tmp)
    os.replace(tmp, dst)


def keep(root, sid, scratchpad):
    """Snapshot the scratchpad into the session's runtime dir. Copies only, never deletes.
    Returns {"ok": bool, "note": str}."""
    if not valid_sid(sid):
        return {"ok": False, "note": "invalid session id"}
    if not os.path.isdir(os.path.join(root, ".credo")):
        return {"ok": True, "note": "no .credo/ directory in %s; nothing saved" % root}
    scratchpad = os.path.abspath(scratchpad)
    if not os.path.isdir(scratchpad):
        return {"ok": True, "note": "no scratchpad at %s; nothing saved" % scratchpad}
    sdir = session_dir(root, sid)
    dest_root = os.path.join(sdir, "scratchpad")
    found, skipped = collect_scratchpad(scratchpad, max_file_bytes())
    files, total = [], 0
    for rel, src in found:
        size = os.path.getsize(src)
        if len(files) >= MAX_FILES:
            skipped.append({"path": rel, "reason": "file limit %d" % MAX_FILES})
            continue
        if total + size > MAX_TOTAL_BYTES:
            skipped.append({"path": rel, "reason": "total size limit"})
            continue
        dst = os.path.join(dest_root, rel)
        copy_into(src, dst)
        total += size
        files.append({"path": rel, "bytes": size, "sha256": sha256_of(dst)})
    manifest_path = os.path.join(sdir, "manifest.json")
    write_json(manifest_path, {"session_id": sid, "saved": now_iso(), "source": scratchpad,
                               "files": files, "skipped": skipped, "pending_restore": True})
    return {"ok": True, "note": "saved %d files (%d skipped) from %s to %s; manifest %s" % (
        len(files), len(skipped), scratchpad, dest_root, manifest_path)}


# --- service: restart list of background services -------------------------------------

def svc_session(name):
    return SERVICE_PREFIX + name


def svc_unit(name):
    return SERVICE_PREFIX + name + ".service"


def service_add(root, name, cmd, cwd):
    """(message, rc). Writes the durable script and the registry entry; starts nothing."""
    if not valid_name(name):
        return "invalid service name (a-z, 0-9, hyphens, max 40 characters): %s" % name, 1
    if not cmd or "\n" in cmd or "\r" in cmd:
        return "--cmd must be one non-empty line", 1
    cwd = os.path.abspath(cwd or os.getcwd())
    os.makedirs(services_dir(root), exist_ok=True)
    script = os.path.join(services_dir(root), name + ".sh")
    with open(script, "w") as fh:
        fh.write("#!/bin/bash\n# credo service %s (restart list, written by credo_runtime.py)\n"
                 "cd -- %s || exit 1\n%s\n" % (name, shlex.quote(cwd), cmd))
    os.chmod(script, 0o700)
    items = load_list(root, "services")
    entry = next((s for s in items if s.get("name") == name), None)
    if entry is None:
        entry = {"name": name}
        items.append(entry)
    entry.update({"cmd": cmd, "cwd": cwd, "script": script, "added": now_iso()})
    save_list(root, "services", items)
    return "service %s registered: %s" % (name, script), 0


def tmux_available():
    return run_rc(["tmux", "-V"], 5) == 0


def tmux_used():
    """tmux is installed and this session runs inside it or a tmux server exists."""
    if not tmux_available():
        return False
    if os.environ.get("TMUX"):
        return True
    return run_rc(["tmux", "list-sessions"], 5) == 0


def systemd_booted():
    sd_dir = os.environ.get("CREDO_RUNTIME_SD_BOOTED_DIR", SD_BOOTED_DEFAULT)
    return os.path.isdir(sd_dir) and shutil.which("systemd-run") is not None


def pick_method():
    if tmux_used():
        return "tmux"
    if systemd_booted():
        return "systemd"
    if shutil.which("nohup"):
        return "nohup"
    return None


def pid_alive(pid):
    if not isinstance(pid, int) or pid <= 1:
        return False
    try:
        with open("/proc/%d/stat" % pid) as fh:
            state = fh.read().rsplit(")", 1)[-1].split()[0]
    except (OSError, IndexError):
        return False
    return state not in ("Z", "X")


def is_running(entry):
    name, method = entry.get("name", ""), entry.get("method")
    if method == "tmux":
        return tmux_available() and run_rc(
            ["tmux", "has-session", "-t", "=" + svc_session(name)]) == 0
    if method == "systemd":
        return run_rc(["systemctl", "--user", "is-active", "--quiet", svc_unit(name)]) == 0
    if method == "nohup":
        return pid_alive(entry.get("pid"))
    return False


def launch(method, name, script, cwd, logfile):
    """Start script with method. Returns (ok, pid or None)."""
    if method == "tmux":
        argv = ["tmux", "new-session", "-d", "-s", svc_session(name), "-c", cwd, "bash", script]
        return run_rc(argv) == 0, None
    if method == "systemd":
        argv = ["systemd-run", "--user", "--unit=" + svc_session(name), "--collect",
                "--working-directory=" + cwd, "bash", script]
        return run_rc(argv) == 0, None
    with open(logfile, "a") as log:
        proc = subprocess.Popen(["nohup", "bash", script], cwd=cwd, stdin=subprocess.DEVNULL,
                                stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
    return True, proc.pid


def start_one(root, entry):
    """(message, ok). Updates method, started and pid in the entry (caller saves)."""
    name = entry["name"]
    if is_running(entry):
        return "%s: already running (%s)" % (name, entry.get("method")), True
    method = pick_method()
    if method is None:
        return "%s: no way to start it (no tmux, systemd-run or nohup)" % name, False
    cwd = entry.get("cwd") or root
    logfile = os.path.join(services_dir(root), name + ".log")
    try:
        ok, pid = launch(method, name, entry["script"], cwd, logfile)
    except OSError as exc:
        return "%s: start failed via %s (%s)" % (name, method, exc.strerror or exc), False
    if not ok:
        return "%s: start failed via %s" % (name, method), False
    entry.update({"method": method, "started": now_iso(), "pid": pid})
    return "%s: started (%s)" % (name, method), True


def service_start(root, names, missing):
    """(lines, rc) for `service start NAME... | --missing`."""
    items = load_list(root, "services")
    if not items:
        return ["no services registered"], 0
    if missing:
        chosen = [s for s in items if not is_running(s)]
    else:
        known = {s.get("name") for s in items}
        unknown = [n for n in names if n not in known]
        if unknown:
            return ["unknown service: %s" % ", ".join(unknown)], 1
        chosen = [s for s in items if s.get("name") in names]
    if not chosen:
        return ["all registered services are running"], 0
    lines, rc = [], 0
    for entry in chosen:
        msg, ok = start_one(root, entry)
        lines.append(msg)
        rc = rc or (0 if ok else 1)
    save_list(root, "services", items)
    return lines, rc


def service_status(root):
    lines = []
    for s in load_list(root, "services"):
        method = s.get("method")
        if not method:
            lines.append("%s: NOT running (never started)" % s.get("name"))
        else:
            lines.append("%s: %s (%s)" % (s.get("name"),
                                          "running" if is_running(s) else "NOT running", method))
    return lines or ["no services registered"]


# --- pane: tmux pane references by name -------------------------------------------------

def find_by_purpose(purpose):
    """(session:window.pane, %ID) of the first pane whose title equals purpose, or None."""
    if not purpose:
        return None
    out = tmux_out(["list-panes", "-a", "-F",
                    "#{session_name}:#{window_index}.#{pane_index}\t#{pane_id}\t#{pane_title}"])
    for line in (out or "").splitlines():
        parts = line.split("\t", 2)
        if len(parts) == 3 and parts[2] == purpose:
            return parts[0], parts[1]
    return None


def resolve_entry(entry):
    """Find the pane by its name first, then by purpose. The stored %ID is never used as a
    target; id_matches only says whether it still names the same pane."""
    target, last = entry["target"], entry.get("last_id") or ""
    res = {"found": False, "found_by": None, "current_target": None, "pane_id": None,
           "id_matches": False, "tty": None}
    pid = tmux_out(["display-message", "-p", "-t", target, "#{pane_id}"])
    if pid:
        cur, found_by = target, "name"
    else:
        hit = find_by_purpose(entry.get("purpose", ""))
        if not hit:
            return res
        cur, pid = hit
        found_by = "purpose"
    res.update({"found": True, "found_by": found_by, "current_target": cur, "pane_id": pid,
                "id_matches": pid == last,
                "tty": tmux_out(["display-message", "-p", "-t", cur, "#{pane_tty}"])})
    return res


def ssh_alive(tty):
    """True when a ssh client (ssh or ssh.exe) runs on the pane tty. ps -t is used, not
    pgrep -P, because an ssh.exe under WSL sits two process levels below the pane."""
    if not tty:
        return False
    short = tty[len("/dev/"):] if tty.startswith("/dev/") else tty
    try:
        r = subprocess.run(["ps", "-t", short, "-o", "comm="], capture_output=True,
                           text=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        return False
    return any(line.strip().lower() in SSH_NAMES for line in r.stdout.splitlines())


def describe_pane(entry):
    """(line, needs_reconnect, label) for one registered pane."""
    res = resolve_entry(entry)
    label = "%s (%s, last %s)" % (entry["target"], entry.get("purpose", ""),
                                  entry.get("last_id") or "-")
    if not res["found"]:
        return "%s: pane missing" % label, bool(entry.get("ssh")), label
    parts = ["pane ok"]
    if res["found_by"] == "purpose":
        parts.append("found by purpose at %s" % res["current_target"])
    if entry.get("last_id") and not res["id_matches"]:
        parts.append("id now %s" % res["pane_id"])
    line = "%s: %s" % (label, ", ".join(parts))
    if not entry.get("ssh"):
        return line, False, label
    alive = ssh_alive(res["tty"])
    line += "; ssh: %s" % ("running" if alive else "NOT running")
    return line, not alive, label


def pane_add(root, target, purpose, ssh):
    if not TARGET_RE.fullmatch(target):
        return "target must be session:window.pane, got: %s" % target, 1
    if not purpose or "\n" in purpose:
        return "--purpose must be one non-empty line", 1
    if not tmux_available():
        return "tmux is not available; panes are a tmux-only feature", 1
    probe = {"target": target, "purpose": purpose}
    res = resolve_entry(probe)
    last = res["pane_id"] or ""
    items = [p for p in load_list(root, "panes") if p.get("target") != target]
    items.append({"target": target, "purpose": purpose, "ssh": bool(ssh), "last_id": last,
                  "added": now_iso()})
    save_list(root, "panes", items)
    note = "" if res["found"] else " (not visible now, last %ID unknown)"
    return "pane registered: %s (%s, last %s)%s" % (target, purpose, last or "-", note), 0


def pane_status(root):
    if not tmux_available():
        return ["tmux is not available; no pane status"], 0
    items = load_list(root, "panes")
    if not items:
        return ["no panes registered"], 0
    return [describe_pane(p)[0] for p in items], 0


def pane_resolve(root, target):
    """JSON-able dict for one target (registered or not), and rc."""
    entry = next((p for p in load_list(root, "panes") if p.get("target") == target),
                 {"target": target, "purpose": ""})
    res = resolve_entry(entry)
    out = {"target": target, "purpose": entry.get("purpose") or None,
           "last_id": entry.get("last_id") or None}
    out.update({k: res[k] for k in ("found", "found_by", "current_target", "pane_id",
                                    "id_matches")})
    return out, (0 if res["found"] else 1)


# --- check: post-restart report ---------------------------------------------------------

def services_report(root):
    items = load_list(root, "services")
    down = [s for s in items if not is_running(s)]
    if not down:
        return []
    names = ", ".join("%s (%s)" % (s.get("name"), s.get("method") or "never started")
                      for s in down)
    return ["- Background services NOT running: %s. Restart them with: python3 %s service "
            "start --missing --root %s" % (names, shlex.quote(SCRIPT_PATH), shlex.quote(root))]


def panes_report(root):
    """Only when tmux is used: SSH panes that are gone or have no ssh client any more."""
    items = load_list(root, "panes")
    if not items or not tmux_used():
        return []
    gone = [label for p in items for _, needs, label in [describe_pane(p)] if needs]
    if not gone:
        return []
    return ["- SSH panes to reconnect (only the user can do this, the agent never reconnects "
            "them): %s. Tell the user." % ", ".join(gone)]


def scratchpad_pointer(root, sid):
    """One-shot: names the scratchpad snapshot of this session after a restart."""
    if not valid_sid(sid):
        return []
    path = os.path.join(session_dir(root, sid), "manifest.json")
    data = read_json(path, None)
    if not isinstance(data, dict) or not data.get("pending_restore"):
        return []
    data["pending_restore"] = False
    write_json(path, data)
    return ["- Scratchpad helpers saved before the restart: %s (%d files). Copy the ones you "
            "still need back into your scratchpad before using them; the snapshot is kept."
            % (path, len(data.get("files") or []))]


def check_report(root, sid):
    lines = services_report(root) + panes_report(root) + scratchpad_pointer(root, sid)
    if not lines:
        return ""
    return "\n".join(["[credo] Restart check (credo runtime, %s):" % root] + lines)


# --- CLI ----------------------------------------------------------------------------------

def build_parser():
    p = argparse.ArgumentParser(prog="credo_runtime.py", description=__doc__.split("\n")[0])
    sub = p.add_subparsers(dest="cmd", required=True)
    k = sub.add_parser("keep", help="snapshot the session scratchpad")
    k.add_argument("--session", required=True)
    k.add_argument("--scratchpad", required=True)
    k.add_argument("--root")
    s = sub.add_parser("service", help="restart list of background services")
    ssub = s.add_subparsers(dest="action", required=True)
    sa = ssub.add_parser("add")
    sa.add_argument("name")
    sa.add_argument("--cmd", dest="command", required=True)
    sa.add_argument("--cwd")
    sa.add_argument("--root")
    st = ssub.add_parser("start")
    st.add_argument("names", nargs="*")
    st.add_argument("--missing", action="store_true")
    st.add_argument("--root")
    sst = ssub.add_parser("status")
    sst.add_argument("--root")
    pn = sub.add_parser("pane", help="tmux pane references by name")
    psub = pn.add_subparsers(dest="action", required=True)
    pa = psub.add_parser("add")
    pa.add_argument("target")
    pa.add_argument("--purpose", required=True)
    pa.add_argument("--ssh", action="store_true")
    pa.add_argument("--root")
    pr = psub.add_parser("resolve")
    pr.add_argument("target")
    pr.add_argument("--root")
    pst = psub.add_parser("status")
    pst.add_argument("--root")
    c = sub.add_parser("check", help="post-restart report (silent when nothing to say)")
    c.add_argument("--session")
    c.add_argument("--root")
    return p


def dispatch(args):
    root = find_root(getattr(args, "root", None))
    if args.cmd == "keep":
        res = keep(root, args.session, args.scratchpad)
        print(res["note"])
        return 0 if res["ok"] else 1
    if args.cmd == "service":
        if args.action == "add":
            msg, rc = service_add(root, args.name, args.command, args.cwd)
            print(msg)
            return rc
        if args.action == "start":
            if not args.missing and not args.names:
                print("give one or more service names, or --missing")
                return 2
            lines, rc = service_start(root, args.names, args.missing)
        else:
            lines, rc = service_status(root), 0
        print("\n".join(lines))
        return rc
    if args.cmd == "pane":
        if args.action == "add":
            msg, rc = pane_add(root, args.target, args.purpose, args.ssh)
            print(msg)
            return rc
        if args.action == "resolve":
            out, rc = pane_resolve(root, args.target)
            print(json.dumps(out, indent=2))
            return rc
        lines, rc = pane_status(root)
        print("\n".join(lines))
        return rc
    report = check_report(root, args.session)
    if report:
        print(report)
    return 0


def main(argv=None):
    args = build_parser().parse_args(argv)
    return dispatch(args)


if __name__ == "__main__":
    sys.exit(main())
