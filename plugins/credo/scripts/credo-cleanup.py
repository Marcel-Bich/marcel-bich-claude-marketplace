#!/usr/bin/env python3
"""credo-cleanup.py - the sanctioned way for an agent to remove what its own session created (#174).

Why this exists: agents must clean up their temp output (the WSL disk image never gives freed
space back), but the delete protections (dogma delete guard, a third-party rm guard that blocks
`rm -rf` outside the cwd, the owner's "never delete without confirmation" rule) stay in force for
everything else. This helper is NOT a bypass: it removes a path only when the session's
provenance ledger proves the session (or one of its subagents, same session id) created it,
with the same device+inode as recorded. The ledger is written by credo hooks only; tool calls
that try to write it are denied. A hard denylist wins over the ledger. It deletes in Python
(no shell rm), never follows a symlink (a link is unlinked, its target stays), never crosses
into another file system, and never removes a linked worktree or a repository outside the
temp roots. Every removal, refusal and failure is logged; nothing ever asks or blocks: a
refused path is reported and the agent carries on.

Usage (the session id comes from $CLAUDE_CODE_SESSION_ID):
  credo-cleanup.py own-rm <path>... [--dry-run] [--superseded "<newer owner decision>"]
  credo-cleanup.py keep <path> <name> --reason "<owner quote>" [--item N] [--licence "<note>"]
                   [--project NAME]
  credo-cleanup.py report [--all] [--json]
  credo-cleanup.py purge [--dry-run] [--now] [--except <path>]...  done-gate: own temp entries
  credo-cleanup.py item-close                                  clear idle entries of $TMPDIR
  credo-cleanup.py sweep                                       sessions that no longer run
  credo-cleanup.py worktrees [dir]                             merged removed, unmerged reported
  credo-cleanup.py caches                                      size caps from the local config
  credo-cleanup.py playwright-prune [--dry-run] [--cache DIR] [--search DIR]... [--time-limit S]
  credo-cleanup.py rescue-credo <worktree> [--dry-run]         stray .credo files -> main checkout
  credo-cleanup.py maintenance --cwd DIR                       SessionStart job (detached)

Output: one line per path ("removed <p>", "refused <p>: <reason>", "failed <p>: <error>",
"gone <p>"). Exit 0 also when something was refused (refusals are reports, never blockers);
exit 2 on a usage error.
"""
import argparse
import glob
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import credo_cleanup_lib as L  # noqa: E402

IDLE_MINUTES_DEFAULT = 30
DAY = 86400


def session_id():
    sid = os.environ.get("CLAUDE_CODE_SESSION_ID") or os.environ.get("CREDO_SESSION_ID") or ""
    return sid if L.valid_sid(sid) else ""


def out(line):
    sys.stdout.write(line + "\n")
    sys.stdout.flush()


# --------------------------------------------------------------------------- keep list


def load_keep():
    try:
        with open(L.keep_list_path(), encoding="utf-8") as fh:
            data = json.load(fh)
        return data if isinstance(data, list) else []
    except (OSError, ValueError):
        return []


def save_keep(items):
    L.ensure_dir(L.keep_root())
    tmp = L.keep_list_path() + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(items, fh, indent=2, sort_keys=True)
        fh.write("\n")
    os.replace(tmp, L.keep_list_path())


def keep_entry_for(p, items):
    for it in items:
        kp = it.get("path")
        if isinstance(kp, str) and L.is_under(p, kp):
            return it
    return None


def item_archived(it):
    item, main = it.get("item"), it.get("repo")
    if not item or not main:
        return False
    return bool(glob.glob(os.path.join(main, ".credo", "items", "4_archived", "%s-*.md" % item)))


# --------------------------------------------------------------------------- own-rm


class Target:
    """Result of check_target: the real path, its lstat (None = gone), the refusal reason (None =
    may go), the provenance start for the delete-time re-check, and the tree facts."""

    def __init__(self, p, st=None, reason=None, since=False, info=None):
        self.p, self.st, self.reason, self.since = p, st, reason, since
        self.info = info or L.TreeInfo()


def check_target(raw, sid, entries, cfg_keep, keep_items, superseded):
    """Every check that decides whether raw may be removed (explicit own-rm level)."""
    p = L.real_target(raw)
    if p is None:
        return Target(raw, None, "not a removable path")
    try:
        st = os.lstat(p)
    except OSError:
        return Target(p)
    t = Target(p, st)
    reason = L.hard_refusal(p, cfg_keep)
    if reason:
        t.reason = reason
        return t
    kept = keep_entry_for(p, keep_items)
    if kept is not None:
        if not superseded and not item_archived(kept):
            t.reason = ("kept on owner request (%s); remove only with --superseded \"<newer owner "
                        "decision>\" or after item %s is archived" % (kept.get("reason"), kept.get("item")))
            return t
        t.since = False  # the owner-approved keep entry: no provenance re-check of its content
        reason, t.info = L.inspect_tree_structure(p, st)
    else:
        if not sid:
            t.reason = "no session id ($CLAUDE_CODE_SESSION_ID) - cannot check the ledger"
            return t
        ok, entry, why, since = L.owned_entry(p, st, entries, sid)
        if not ok:
            t.reason = why
            return t
        if entry is not None and entry.get("evidence") == "window" and entry.get("ambiguous"):
            t.reason = ("born while other sessions were running tool calls (%s); not provably "
                        "this session's" % ", ".join(entry["ambiguous"]))
            return t
        t.since = since
        # the whole tree must be this session's work: born after the entry, never older content
        reason, t.info = L.inspect_tree(p, st, since)
    if reason:
        t.reason = reason
        return t
    if L.git_tracked(p):
        t.reason = "tracked by git (use git rm, not the cleanup helper)"
    return t


def auto_refusal(t, idle_s):
    """Extra checks of the automatic paths (item-close, purge, sweep): they are strictly more
    conservative than an explicit own-rm and only report when in doubt."""
    if t.info.special:
        return "holds a socket, fifo or device (%s): may belong to a running process" % t.info.special
    if time.time() - t.info.newest < idle_s:
        return "changed in the last %d minutes (deepest change counts): may be in use" % (idle_s // 60)
    pid = L.held_open(t.p)
    if pid == "unknown":
        return "open-file check did not finish: may be in use"
    if pid:
        return "in use by process %s (cwd or open file inside)" % pid
    return None


def own_rm(paths, dry=False, superseded=None, quiet_refusals=False, auto_idle_s=None):
    """Remove the paths that pass check_target (and auto_refusal when auto_idle_s is given)."""
    sid = session_id()
    entries = L.load_ledger(sid) if sid else {}
    cfg = L.local_config()
    cfg_keep = cfg.get("keep_paths") or []
    keep_items = load_keep()
    removed, refused, failed = [], [], []
    for raw in paths:
        t = check_target(raw, sid, entries, cfg_keep, keep_items, superseded)
        p = t.p
        if t.st is None and t.reason is None:
            out("gone %s" % p)
            if sid and p in entries:
                L.append_ledger(sid, [{"event": "removed", "path": p, "ts": L.iso()}])
            continue
        reason = t.reason
        if not reason and auto_idle_s is not None:
            reason = auto_refusal(t, auto_idle_s)
            if reason:
                reason = "reported, not deleted: " + reason
        if reason:
            refused.append(p)
            L.log("refused %s (session %s): %s" % (p, sid or "-", reason))
            if not quiet_refusals:
                out("refused %s: %s" % (p, reason))
            continue
        if dry:
            out("would-remove %s" % p)
            continue
        errs = L.delete_path(p, t.st, t.since)
        if errs:
            failed.append(p)
            L.log("failed %s (session %s): %s" % (p, sid or "-", "; ".join(errs[:5])))
            out("failed %s: %s" % (p, "; ".join(errs[:3])))
            continue
        removed.append(p)
        L.log("removed %s (session %s)" % (p, sid or "-"))
        out("removed %s" % p)
        if sid:
            L.append_ledger(sid, [{"event": "removed", "path": p, "ts": L.iso()}])
        kept = keep_entry_for(p, keep_items)
        if kept is not None and kept.get("path") == p:
            keep_items = [k for k in keep_items if k is not kept]
            save_keep(keep_items)
            L.log("keep entry dropped %s: %s" % (p, superseded or "item archived"))
    return removed, refused, failed


# --------------------------------------------------------------------------- keep


def project_of(path):
    top, linked = L.git_top(os.path.realpath(path))
    if top and linked:
        top = L.main_checkout_of(top) or top
    return top


def keep(args):
    sid = session_id()
    name = re.sub(r"[^A-Za-z0-9._-]", "-", args.name).strip(".-") or "kept"
    entries = L.load_ledger(sid) if sid else {}
    cfg = L.local_config()
    t = check_target(args.path, sid, entries, cfg.get("keep_paths") or [], load_keep(), None)
    p, st, reason = t.p, t.st, t.reason
    if st is None:
        out("refused %s: does not exist" % p)
        return
    if reason:
        out("refused %s: %s" % (p, reason))
        return
    repo = project_of(os.getcwd())
    project = re.sub(r"[^A-Za-z0-9._-]", "-", args.project or (os.path.basename(repo) if repo else "misc"))
    dest_dir = os.path.join(L.keep_root(), project, name)
    if os.path.lexists(dest_dir):
        out("refused %s: keep name %s/%s exists already" % (p, project, name))
        return
    L.ensure_dir(os.path.dirname(dest_dir))
    dest = dest_dir if stat.S_ISDIR(st.st_mode) else os.path.join(dest_dir, os.path.basename(p))
    if not stat.S_ISDIR(st.st_mode):
        L.ensure_dir(dest_dir)
    try:
        os.rename(p, dest)
    except OSError:
        try:
            if stat.S_ISDIR(st.st_mode):
                shutil.copytree(p, dest, symlinks=True)
            else:
                shutil.copy2(p, dest, follow_symlinks=False)
        except OSError as exc:
            out("failed %s: %s" % (p, exc))
            return
        errs = L.delete_path(p, st, t.since)
        if errs:
            out("copied %s -> %s, source not removed: %s" % (p, dest, "; ".join(errs[:3])))
    nst = os.lstat(dest_dir)
    if sid:
        L.append_ledger(sid, [{"event": "moved", "path": p, "to": dest_dir, "dev": nst.st_dev,
                               "ino": nst.st_ino, "ts": L.iso()}])
    items = load_keep()
    items.append({"path": dest_dir, "origin": p, "project": project, "repo": repo, "item": args.item,
                  "reason": args.reason, "licence": args.licence, "created": L.iso(), "session": sid})
    save_keep(items)
    L.log("kept %s -> %s (%s)" % (p, dest_dir, args.reason))
    out("kept %s -> %s" % (p, dest_dir))


# --------------------------------------------------------------------------- report / purge


def entry_status(p, e):
    try:
        st = os.lstat(p)
    except OSError:
        return "gone"
    if st.st_dev != e.get("dev") or st.st_ino != e.get("ino"):
        return "replaced"
    return "present"


def report(args):
    sids = [session_id()] if not args.all else [os.path.basename(f)[:-6] for f in
                                                glob.glob(os.path.join(L.state_dir(), "ledger", "*.jsonl"))]
    rows = []
    for sid in sids:
        if not sid:
            continue
        for p, e in sorted(L.load_ledger(sid).items()):
            status = entry_status(p, e)
            if status == "gone":
                continue
            rows.append({"session": sid, "path": p, "status": status, "type": e.get("type"),
                         "evidence": e.get("evidence"), "kind": e.get("root_kind"),
                         "ambiguous": e.get("ambiguous") or [], "agent_id": e.get("agent_id")})
    stmp = L.session_tmp(session_id()) if session_id() else None
    kept = load_keep()
    if args.json:
        out(json.dumps({"entries": rows, "session_tmp": stmp, "kept": kept}))
        return
    if stmp:
        out("session_tmp %s" % stmp)
    for r in rows:
        extra = " ambiguous=%s" % ",".join(r["ambiguous"]) if r["ambiguous"] else ""
        out("%s %s type=%s evidence=%s kind=%s%s%s" % (r["status"], r["path"], r["type"], r["evidence"], r["kind"],
                                                    extra, " session=" + r["session"] if args.all else ""))
    for k in kept:
        out("kept %s item=%s reason=%s" % (k.get("path"), k.get("item"), k.get("reason")))


def idle_seconds():
    return float(os.environ.get("CREDO_CLEANUP_IDLE_MINUTES", IDLE_MINUTES_DEFAULT)) * 60


def excepted(p, excepts):
    return any(L.is_under(p, x) or L.is_under(x, p) for x in excepts)


def purge(args):
    """Done-gate. Automatic, so stricter than own-rm: only entries the Write/Edit tool created in a
    temp root and the children of the session TMPDIR are removed, each only when its whole tree
    is provably this session's (birth checks), idle for 30 minutes (deepest change; --now drops
    only this idle rule), free of sockets/fifos and not in use by a process. Everything else is
    listed for an explicit own-rm or the owner."""
    sid = session_id()
    if not sid:
        out("refused purge: no session id ($CLAUDE_CODE_SESSION_ID)")
        return
    excepts = [L.real_target(e) or e for e in args.excepts or []]
    targets, listed = [], []
    for p, e in sorted(L.load_ledger(sid).items()):
        if entry_status(p, e) != "present" or e.get("kept"):
            continue
        if excepted(p, excepts):
            listed.append((p, "excepted (result)"))
            continue
        if not L.in_temp_root(p):
            listed.append((p, "outside the temp roots: own-rm if it is not a result"))
            continue
        if e.get("evidence") != "write":
            listed.append((p, "recorded from a Bash call (%s evidence): own-rm if it is yours"
                           % e.get("evidence")))
            continue
        targets.append(p)
    stmp = L.session_tmp(sid)
    if os.path.isdir(stmp) and not os.path.islink(stmp):
        for n in sorted(os.listdir(stmp)):
            q = os.path.join(stmp, n)
            if excepted(q, excepts):
                listed.append((q, "excepted (result)"))
                continue
            targets.append(q)
    own_rm(targets, dry=args.dry_run, auto_idle_s=0 if args.now else idle_seconds())
    for p, why in listed:
        out("listed %s: %s" % (p, why))


def item_close(args):
    """Clear children of the session TMPDIR that pass every automatic check (whole tree own,
    deepest change older than 30 minutes, no socket/fifo, not in use). The dir itself stays: the
    session and its parallel subagents go on. Refusals are only logged."""
    sid = session_id()
    if not sid:
        return
    stmp = L.session_tmp(sid)
    if os.path.islink(stmp):
        return
    try:
        names = os.listdir(stmp)
    except OSError:
        return
    targets = [os.path.join(stmp, n) for n in names]
    if targets:
        own_rm(targets, quiet_refusals=True, auto_idle_s=idle_seconds())


# --------------------------------------------------------------------------- sweep


UUID_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")


def private_base():
    """The session tmp base when it is safe to sweep: not a symlink (checked unresolved), a
    directory owned by this user with mode 0700. Else None (reported)."""
    raw = os.path.abspath(os.environ.get("CREDO_TMP_BASE") or "/tmp/credo-tmp-%d" % os.getuid())
    try:
        st = os.lstat(raw)
    except OSError:
        return None
    if (stat.S_ISLNK(st.st_mode) or not stat.S_ISDIR(st.st_mode) or st.st_uid != os.getuid()
            or stat.S_IMODE(st.st_mode) != 0o700):
        out("refused sweep: %s is not a private dir of this user (symlink, owner or mode)" % raw)
        L.log("sweep refused: %s is not a private dir of this user" % raw)
        return None
    if L.hard_refusal(raw):
        out("refused sweep: %s: %s" % (raw, L.hard_refusal(raw)))
        return None
    return raw


def sweep_session_dir(d, idle_s):
    """Remove the children of a dead session's tmp dir that are provably its own (born after the
    dir, no older content, no repository/worktree/mount, nothing in use, idle), then the dir
    itself when it is empty. Anything else stays and is reported."""
    since = L.birth_time(d)
    for n in sorted(os.listdir(d)):
        c = os.path.join(d, n)
        try:
            st = os.lstat(c)
        except OSError:
            continue
        reason = L.hard_refusal(c)
        info = L.TreeInfo()
        if not reason:
            reason, info = L.inspect_tree(c, st, since)
        if not reason and L.git_tracked(c):
            reason = "tracked by git"
        if not reason:
            reason = auto_refusal(Target(c, st, None, since, info), idle_s)
        if reason:
            out("kept %s: %s" % (c, reason))
            L.log("sweep kept %s: %s" % (c, reason))
            continue
        errs = L.delete_path(c, st, since)
        out(("removed %s" % c) if not errs else ("failed %s: %s" % (c, "; ".join(errs[:3]))))
        L.log(("swept %s" % c) if not errs else ("sweep failed %s: %s" % (c, "; ".join(errs[:3]))))
    try:
        if not os.listdir(d):
            os.rmdir(d)
            out("removed %s" % d)
            L.log("swept session tmp %s" % d)
    except OSError:
        pass


def sweep(args):
    live = L.running_sessions()
    now = time.time()
    base = private_base()
    names = []
    if base:
        try:
            names = os.listdir(base)
        except OSError:
            names = []
    for n in names:
        p = os.path.join(base, n)
        if not UUID_RE.match(n) or n in live:
            continue  # only session-id-shaped names of sessions that no longer run
        try:
            st = os.lstat(p)
        except OSError:
            continue
        if not stat.S_ISDIR(st.st_mode) or st.st_uid != os.getuid() or now - st.st_mtime < 600:
            continue
        if L.hard_refusal(p):
            continue
        try:
            sweep_session_dir(p, idle_seconds())
        except OSError as exc:
            L.log("sweep failed %s: %s" % (p, exc))
    # stale marks and jobs of sessions that no longer run
    for d in glob.glob(os.path.join(L.state_dir(), "marks", "*")):
        sid = os.path.basename(d)
        if sid in live:
            continue
        for f in glob.glob(os.path.join(d, "*")):
            try:
                if now - os.lstat(f).st_mtime > DAY:
                    os.unlink(f)
            except OSError:
                pass
        try:
            os.rmdir(d)
        except OSError:
            pass
    for f in glob.glob(os.path.join(L.state_dir(), "jobs", "*.json")):
        try:
            if now - os.lstat(f).st_mtime > DAY:
                os.unlink(f)
        except OSError:
            pass
    # ledgers of dead sessions: dropped after 30 days when nothing they name is left
    for f in glob.glob(os.path.join(L.state_dir(), "ledger", "*.jsonl")):
        sid = os.path.basename(f)[:-6]
        try:
            if sid in live or now - os.lstat(f).st_mtime < 30 * DAY:
                continue
        except OSError:
            continue
        if all(entry_status(p, e) == "gone" for p, e in L.load_ledger(sid).items()):
            for g in (f, f + ".lock"):
                try:
                    os.unlink(g)
                except OSError:
                    pass


# --------------------------------------------------------------------------- worktrees


def worktrees(args):
    d = args.dir or os.getcwd()
    script = os.path.join(HERE, "credo-worktree-cleanup.sh")
    mode = "deny"
    try:
        r = subprocess.run([os.path.join(HERE, "credo-dogma-mode.sh"), "--id", "36ch", "Hydra",
                            "clean up merged worktrees automatically", d], capture_output=True, text=True,
                           timeout=30)
        mode = (r.stdout or "").strip() or "deny"
    except (OSError, subprocess.SubprocessError):
        pass
    argv = [script, "--details"]
    if mode != "auto":
        argv.append("--dry-run")  # only the owner setting [x] removes; otherwise report
    try:
        r = subprocess.run(argv + [d], capture_output=True, text=True, timeout=600)
        sys.stdout.write(r.stdout)
        if r.returncode != 0 and r.stderr:
            out("failed worktrees: %s" % r.stderr.strip().splitlines()[-1])
    except (OSError, subprocess.SubprocessError) as exc:
        out("failed worktrees: %s" % exc)


def rescue_credo(args):
    """Copy stray real .credo files of a linked worktree into the main checkout (never
    overwrite). Exit 3 when a conflict (or no main .credo) remains: the worktree must be kept."""
    wt = os.path.realpath(args.worktree)
    wc = os.path.join(wt, ".credo")
    if os.path.islink(wc) or not os.path.isdir(wc):
        return 0
    main = L.main_checkout_of(wt)
    if not main or not os.path.isdir(os.path.join(main, ".credo")) or os.path.realpath(main) == wt:
        out("conflict %s: no main checkout .credo to rescue into" % wc)
        return 3
    try:
        r = subprocess.run(["git", "-C", wt, "ls-files", "--others", "-z", "--", ".credo"],
                           capture_output=True, timeout=60)
        rels = [x.decode("utf-8", "surrogateescape") for x in r.stdout.split(b"\0") if x]
    except (OSError, subprocess.SubprocessError) as exc:
        out("conflict %s: git failed: %s" % (wc, exc))
        return 3
    conflicts = 0
    main_items = {}
    for f in glob.glob(os.path.join(main, ".credo", "items", "**", "*.md"), recursive=True):
        main_items.setdefault(os.path.basename(f), []).append(os.path.relpath(f, main))
    for rel in rels:
        src = os.path.join(wt, rel)
        dst = os.path.join(main, rel)
        if rel.startswith(".credo/items/") and not os.path.lexists(dst):
            elsewhere = [m for m in main_items.get(os.path.basename(rel), []) if m != rel]
            if elsewhere:
                out("conflict %s: the item lives under another status folder in main (%s), not copied"
                    % (rel, ", ".join(elsewhere)))
                conflicts += 1
                continue
        if os.path.islink(src) or not os.path.isfile(src):
            out("conflict %s: not a regular file" % rel)
            conflicts += 1
            continue
        if os.path.lexists(dst):
            same = False
            try:
                with open(src, "rb") as a, open(dst, "rb") as b:
                    same = a.read() == b.read()
            except OSError:
                pass
            if same:
                out("same %s" % rel)
            else:
                out("conflict %s: differs from the main checkout" % rel)
                conflicts += 1
            continue
        if args.dry_run:
            out("would-rescue %s" % rel)
            continue
        try:
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            shutil.copy2(src, dst)
            out("rescued %s" % rel)
            L.log("rescued stray worktree file %s -> %s" % (src, dst))
        except OSError as exc:
            out("conflict %s: copy failed: %s" % (rel, exc))
            conflicts += 1
    return 3 if conflicts else 0


# --------------------------------------------------------------------------- caches


def caches(args):
    caps = (L.local_config().get("cache_caps") or {})
    if not isinstance(caps, dict):
        return
    for path, cap_mb in sorted(caps.items()):
        p = os.path.realpath(os.path.expanduser(str(path)))
        try:
            cap = float(cap_mb)
        except (TypeError, ValueError):
            continue
        if not os.path.isdir(p):
            continue
        size = L.dir_size(p, limit_s=60)
        if size is None:
            out("cache %s size=unknown cap=%dMB" % (p, cap))
            continue
        mb = size / 1048576.0
        status = "over-cap" if mb > cap else "ok"
        out("cache %s size=%dMB cap=%dMB %s" % (p, mb, cap, status))
        if status == "over-cap":
            L.log("cache over cap: %s %dMB > %dMB (report only, caches are shared)" % (p, mb, cap))


# --------------------------------------------------------------------------- playwright

PW_DIR_RE = re.compile(r"^(chromium|chromium_headless_shell|chromium_tip_of_tree|"
                       r"chromium_tip_of_tree_headless_shell|firefox|firefox_beta|webkit|ffmpeg|"
                       r"winldd|android)-\d+$")
SKIP_NAMES = {".git", "_cacache", "proc"}


def pw_cache_dir(args):
    if args.cache:
        return os.path.realpath(args.cache)
    env = os.environ.get("PLAYWRIGHT_BROWSERS_PATH")
    if env and env != "0":
        return os.path.realpath(os.path.expanduser(env))
    return os.path.join(L.home(), ".cache", "ms-playwright")


def find_browsers_json(roots, limit_s):
    """(set of browsers.json paths, complete?) below the roots (no symlink follow, one file system
    per root, ~/.claude*/projects and git internals skipped)."""
    found = set()
    t_end = time.time() + limit_s
    for root in roots:
        try:
            rst = os.lstat(root)
        except OSError:
            continue
        stack = [root]
        while stack:
            if time.time() > t_end:
                return found, False
            d = stack.pop()
            try:
                it = list(os.scandir(d))
            except OSError as exc:
                L.log("playwright search: %s unreadable (%s), search incomplete" % (d, exc.strerror or exc))
                return found, False
            for de in it:
                if de.name in SKIP_NAMES:
                    continue
                try:
                    st = de.stat(follow_symlinks=False)
                except OSError as exc:
                    L.log("playwright search: %s unreadable (%s), search incomplete" % (de.path, exc.strerror or exc))
                    return found, False
                if stat.S_ISDIR(st.st_mode):
                    if st.st_dev != rst.st_dev or de.path in L.mount_points():
                        continue
                    if de.name == "projects" and os.path.basename(d).startswith(".claude"):
                        continue
                    if de.name == "ms-playwright" and os.path.basename(d) == ".cache":
                        continue
                    stack.append(de.path)
                elif de.name == "browsers.json" and os.path.basename(d) == "playwright-core":
                    found.add(de.path)
    return found, True


def referenced_dirs(files):
    names = set()
    for f in files:
        try:
            with open(f, encoding="utf-8") as fh:
                data = json.load(fh)
        except (OSError, ValueError):
            continue
        for b in data.get("browsers") or []:
            name = str(b.get("name") or "").replace("-", "_")
            if not name:
                continue
            revs = [b.get("revision")] + list((b.get("revisionOverrides") or {}).values())
            for r in revs:
                if r:
                    names.add("%s-%s" % (name, r))
    return names


def playwright_prune(args):
    cache = pw_cache_dir(args)
    if not os.path.isdir(cache):
        out("playwright cache %s: none" % cache)
        return
    roots = args.search or [L.home(), "/usr/lib/node_modules", "/usr/local/lib/node_modules",
                            "/opt/homebrew/lib/node_modules"]
    files, complete = find_browsers_json([os.path.realpath(r) for r in roots], args.time_limit)
    # playwright's own install markers: .links/<hash> holds a package dir path
    for lf in glob.glob(os.path.join(cache, ".links", "*")):
        try:
            with open(lf, encoding="utf-8") as fh:
                pkg = fh.read().strip()
        except OSError:
            continue
        bj = os.path.join(pkg, "browsers.json")
        if pkg and os.path.isfile(bj):
            files.add(bj)
    if not complete:
        out("playwright prune skipped: the search for installations did not finish (time limit %ss or an "
            "unreadable directory); nothing is pruned on an incomplete search" % args.time_limit)
        L.log("playwright prune skipped: search incomplete")
        return
    if not files:
        out("playwright prune skipped: no playwright-core installation found (nothing is pruned blind)")
        return
    refs = referenced_dirs(files)
    for f in sorted(files):
        out("installation %s" % f)
    now = time.time()
    for n in sorted(os.listdir(cache)):
        p = os.path.join(cache, n)
        if not PW_DIR_RE.match(n):
            continue  # mcp-chrome-*, .links and anything unknown are never touched
        try:
            st = os.lstat(p)
        except OSError:
            continue
        if not stat.S_ISDIR(st.st_mode):
            continue
        if n in refs:
            out("referenced %s" % n)
            continue
        if now - st.st_mtime < 2 * 3600:
            out("young %s (installed less than 2h ago, kept)" % n)
            continue
        if args.dry_run:
            out("would-remove %s" % p)
            continue
        errs = L.delete_path(p, st)
        if errs:
            out("failed %s: %s" % (p, "; ".join(errs[:3])))
            L.log("playwright prune failed %s: %s" % (p, "; ".join(errs[:3])))
        else:
            out("removed %s" % p)
            L.log("playwright prune removed %s" % p)


# --------------------------------------------------------------------------- maintenance


def stamp_due(name, every_s):
    sd = os.path.join(L.state_dir(), "stamps")
    L.ensure_dir(sd)
    f = os.path.join(sd, re.sub(r"[^A-Za-z0-9._-]", "_", name))
    try:
        if time.time() - os.lstat(f).st_mtime < every_s:
            return False
    except OSError:
        pass
    with open(f, "w") as fh:
        fh.write(L.iso())
    return True


def maintenance(args):
    out("maintenance %s cwd=%s" % (L.iso(), args.cwd))
    for name, fn in (("sweep", lambda: sweep(args)),):
        try:
            fn()
        except Exception as exc:  # noqa: BLE001 - background: log and continue
            L.log("maintenance %s failed: %r" % (name, exc))
    repo = project_of(args.cwd) if args.cwd and os.path.isdir(args.cwd) else None
    if repo and stamp_due("worktrees-" + repo, 3600):
        try:
            args.dir = repo
            worktrees(args)
        except Exception as exc:  # noqa: BLE001
            L.log("maintenance worktrees failed: %r" % exc)
    if stamp_due("playwright-prune", DAY):
        try:
            args.cache, args.search, args.dry_run, args.time_limit = None, None, False, 600
            playwright_prune(args)
        except Exception as exc:  # noqa: BLE001
            L.log("maintenance playwright-prune failed: %r" % exc)
    if stamp_due("caches", DAY):
        try:
            caches(args)
        except Exception as exc:  # noqa: BLE001
            L.log("maintenance caches failed: %r" % exc)


# --------------------------------------------------------------------------- cli


def main():
    ap = argparse.ArgumentParser(prog="credo-cleanup.py", description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("own-rm")
    s.add_argument("paths", nargs="+")
    s.add_argument("--dry-run", action="store_true")
    s.add_argument("--superseded")
    s = sub.add_parser("keep")
    s.add_argument("path")
    s.add_argument("name")
    s.add_argument("--reason", required=True)
    s.add_argument("--item")
    s.add_argument("--licence")
    s.add_argument("--project")
    s = sub.add_parser("report")
    s.add_argument("--all", action="store_true")
    s.add_argument("--json", action="store_true")
    s = sub.add_parser("purge")
    s.add_argument("--dry-run", action="store_true")
    s.add_argument("--except", dest="excepts", action="append")
    s.add_argument("--now", action="store_true", help="also entries changed in the last 30 minutes")
    sub.add_parser("item-close")
    sub.add_parser("sweep")
    s = sub.add_parser("worktrees")
    s.add_argument("dir", nargs="?")
    sub.add_parser("caches")
    s = sub.add_parser("playwright-prune")
    s.add_argument("--dry-run", action="store_true")
    s.add_argument("--cache")
    s.add_argument("--search", action="append")
    s.add_argument("--time-limit", type=float, default=600)
    s = sub.add_parser("rescue-credo")
    s.add_argument("worktree")
    s.add_argument("--dry-run", action="store_true")
    s = sub.add_parser("maintenance")
    s.add_argument("--cwd", default=os.getcwd())
    args = ap.parse_args()
    try:
        if args.cmd == "own-rm":
            if args.superseded is not None and not args.superseded.strip():
                out("refused: --superseded needs the newer owner decision as text")
                return 0
            own_rm(args.paths, args.dry_run, args.superseded)
        elif args.cmd == "keep":
            keep(args)
        elif args.cmd == "report":
            report(args)
        elif args.cmd == "purge":
            purge(args)
        elif args.cmd == "item-close":
            item_close(args)
        elif args.cmd == "sweep":
            sweep(args)
        elif args.cmd == "worktrees":
            worktrees(args)
        elif args.cmd == "caches":
            caches(args)
        elif args.cmd == "playwright-prune":
            playwright_prune(args)
        elif args.cmd == "rescue-credo":
            return rescue_credo(args)
        elif args.cmd == "maintenance":
            maintenance(args)
    except Exception as exc:  # noqa: BLE001 - never a blocker: report and exit 0
        L.log("%s failed: %r" % (args.cmd, exc))
        out("failed %s: %r" % (args.cmd, exc))
    return 0


if __name__ == "__main__":
    sys.exit(main())
