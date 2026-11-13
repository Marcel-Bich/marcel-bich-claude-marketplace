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
  credo-cleanup.py own-rm <path>... [--dry-run]
  credo-cleanup.py keep <path> <name> --reason "<owner quote>" [--item N] [--licence "<note>"]
                   [--project NAME]
  credo-cleanup.py report [--all] [--json]
  credo-cleanup.py purge [--dry-run] [--now] [--except <path>]...  done-gate: own temp entries
  credo-cleanup.py item-close                                  list $TMPDIR entries (report only)
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
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import credo_cleanup_lib as L  # noqa: E402

IDLE_MINUTES_DEFAULT = 30
EXPLICIT_IDLE_S = 120          # explicit own-rm: nothing changed in the tree for 2 minutes
ITEM_CLOSE_BUDGET_S = 60       # item-close: overall time budget, then skip and log
DAY = 86400


def session_id():
    sid = os.environ.get("CLAUDE_CODE_SESSION_ID") or ""
    return sid if L.valid_sid(sid) else ""  # a UUID only: it can never name or escape a dir


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


def own_worktree_output(p, st):
    """(ok, since, reason) for ignored build output inside the linked (hydra) worktree the helper
    runs in: p lies inside that worktree (not the worktree itself), git ignores it and tracks
    nothing below it. since = the worktree's birth, so older (moved-in) content is refused."""
    top, linked = L.git_top(os.path.realpath(os.getcwd()))
    if not top or not linked or p == top or not L.is_under(p, top):
        return False, None, None
    rel = os.path.relpath(p, top)
    if rel == ".git" or rel.startswith(".git/") or rel == ".credo" or rel.startswith(".credo/"):
        return False, None, None
    try:
        r = subprocess.run(["git", "-C", top, "check-ignore", "-q", "--", rel], capture_output=True,
                           timeout=20)
    except (OSError, subprocess.SubprocessError):
        return False, None, "git check-ignore failed"
    if r.returncode != 0:
        return False, None, None
    return True, L.birth_time(top), None


def check_target(raw, sid, entries, cfg, keep_items):
    """Every check that decides whether raw may be removed without a prompt."""
    p = L.real_target(raw)
    if p is None:
        return Target(raw, None, "not a removable path")
    try:
        st = os.lstat(p)
    except OSError:
        return Target(p)
    t = Target(p, st)
    if cfg is None:
        t.reason = "the local config could not be read in time: keep list unknown, nothing deleted"
        return t
    reason = L.hard_refusal(p, cfg.get("keep_paths") or [])
    if reason:
        t.reason = reason
        return t
    kept = keep_entry_for(p, keep_items)
    if kept is not None:
        # the keep list only ever protects: a kept result is never deleted by an agent
        t.reason = ("kept on owner request (%s, item %s): report only - the owner may release it "
                    "(delete it by hand and drop the keep-list entry)" % (kept.get("reason"), kept.get("item")))
        return t
    if not sid:
        t.reason = "no session id ($CLAUDE_CODE_SESSION_ID) - cannot check the ledger"
        return t
    ok, entry, why, since = L.owned_entry(p, st, entries, sid)
    if not ok:
        wt_ok, wt_since, wt_why = own_worktree_output(p, st)
        if not wt_ok:
            t.reason = wt_why or why
            return t
        since = wt_since
    elif entry is not None and entry.get("evidence") == "window" and entry.get("ambiguous"):
        t.reason = "report only: born while other sessions ran tool calls"
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
    """Checks against deleting something still in use, for every delete (explicit own-rm with a
    2-minute idle time, purge and sweep with 30 minutes): no socket/fifo/device in the tree, no
    change anywhere in the tree within idle_s, no process with its cwd or an open file inside."""
    if t.info.special:
        return "holds a socket, fifo or device (%s): may belong to a running process" % t.info.special
    if time.time() - t.info.newest < idle_s:
        return "changed in the last %ds (deepest change counts): may be in use" % idle_s
    pid = L.held_open(t.p)
    if pid == "unknown":
        return "open-file check did not finish: may be in use"
    if pid:
        return "in use by process %s (cwd or open file inside)" % pid
    return None


def own_rm(paths, dry=False, quiet_refusals=False, idle_s=EXPLICIT_IDLE_S):
    """Remove the paths that pass check_target and auto_refusal (socket/fifo, open files, idle)."""
    sid = session_id()
    entries = L.load_ledger(sid) if sid else {}
    cfg = L.local_config()
    keep_items = load_keep()
    removed, refused, failed = [], [], []
    if idle_s == EXPLICIT_IDLE_S:
        idle_s = L.ov("explicit_idle_s", idle_s)
    for raw in paths:
        t = check_target(raw, sid, entries, cfg, keep_items)
        p = t.p
        if t.st is None and t.reason is None:
            out("gone %s" % p)
            continue
        reason = t.reason
        if not reason:
            reason = auto_refusal(t, idle_s)
            if reason:
                reason = "report only: " + reason
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
    t = check_target(args.path, sid, entries, cfg, load_keep())
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
    return float(L.ov("idle_minutes", IDLE_MINUTES_DEFAULT)) * 60


def excepted(p, excepts):
    return any(L.is_under(p, x) or L.is_under(x, p) for x in excepts)


def purge(args):
    """Done-gate. Removes only entries the Write/Edit tool created in a temp root, each with every
    check of own-rm and an idle time of 30 minutes (--now: the 2 minutes of own-rm). Everything
    else is listed: Bash-recorded entries (report only), entries outside the temp roots, and the
    children of the session TMPDIR (shared with parallel subagents; own-rm them by name, or the
    sweep removes them once the session has ended)."""
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
        why = L.not_deletable_entry(p, e, sid)
        if why:
            listed.append((p, why))
            continue
        targets.append(p)
    stmp = L.session_tmp(sid)
    if L.private_dir(stmp):
        for n in sorted(os.listdir(stmp)):
            q = os.path.join(stmp, n)
            listed.append((q, "excepted (result)" if excepted(q, excepts) else
                           "session TMPDIR, shared with parallel subagents: own-rm it by name if it is "
                           "yours, else the sweep removes it after the session ended"))
    own_rm(targets, dry=args.dry_run, idle_s=EXPLICIT_IDLE_S if args.now else idle_seconds())
    for p, why in listed:
        out("listed %s: %s" % (p, why))


def item_close(args):
    """Report only. Parallel subagents of the session share its TMPDIR, so closing one item may
    not delete there; this lists the children that would qualify, and the sweep removes them once
    the session no longer runs. One overall time budget; over it the rest is skipped and logged."""
    sid = session_id()
    if not sid:
        return
    stmp = L.session_tmp(sid)
    if not L.private_dir(stmp):
        return
    t_end = time.time() + L.ov("item_close_budget_s", ITEM_CLOSE_BUDGET_S)
    try:
        names = sorted(os.listdir(stmp))
    except OSError:
        return
    for i, n in enumerate(names):
        if time.time() > t_end:
            L.log("item-close: time budget used up, %d entries not checked" % (len(names) - i))
            out("skipped %d entries: time budget used up" % (len(names) - i))
            return
        q = os.path.join(stmp, n)
        out("listed %s: session TMPDIR, removed by the sweep after the session ended (or own-rm it "
            "by name)" % q)


# --------------------------------------------------------------------------- sweep


UUID_RE = L.SID_RE


def private_base():
    """The session tmp base when it is safe to sweep: not a symlink (checked unresolved), a
    directory owned by this user with mode 0700. Else None (reported)."""
    raw = L.tmp_base()
    if not os.path.lexists(raw):
        return None
    if not L.private_dir(raw):
        out("refused sweep: %s is not a private dir of this user (symlink, owner or mode)" % raw)
        L.log("sweep refused: %s is not a private dir of this user" % raw)
        return None
    if L.hard_refusal(raw):
        out("refused sweep: %s: %s" % (raw, L.hard_refusal(raw)))
        return None
    return raw


def sweep_session_dir(d, idle_s, keep_paths):
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
        reason = L.hard_refusal(c, keep_paths)
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
    cfg = L.local_config()
    base = private_base() if cfg is not None else None
    if cfg is None:
        out("refused sweep: the local config could not be read in time (keep list unknown)")
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
            sweep_session_dir(p, idle_seconds(), cfg.get("keep_paths") or [])
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
        except OSError as exc:
            out("conflict %s: copy failed: %s" % (rel, exc))
            conflicts += 1
    return 3 if conflicts else 0


# --------------------------------------------------------------------------- caches


def caches(args):
    caps = ((L.local_config() or {}).get("cache_caps") or {})
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
    """The browser cache: --cache, else PLAYWRIGHT_BROWSERS_PATH only when it looks like a
    Playwright cache (has the .links marker dir), else ~/.cache/ms-playwright. None = unclear."""
    if args.cache:
        return os.path.realpath(args.cache)
    env = os.environ.get("PLAYWRIGHT_BROWSERS_PATH")
    if env and env != "0":
        d = os.path.realpath(os.path.expanduser(env))
        return d if os.path.isdir(os.path.join(d, ".links")) else None
    return os.path.join(L.home(), ".cache", "ms-playwright")


def default_search_roots():
    roots = [L.home()]
    for pat in ("/usr/lib/node_modules", "/usr/local/lib/node_modules", "/opt/homebrew/lib/node_modules",
                "/usr/lib/python3*", "/usr/local/lib/python3*", "/opt/*/lib/python3*"):
        roots += glob.glob(pat)
    return roots


class Unclear(Exception):
    """Something about the installations is not certain: prune nothing."""


def parse_browsers(data, where):
    """Revision dir names of one browsers.json document; Unclear when it is malformed."""
    names = set()
    browsers = data.get("browsers") if isinstance(data, dict) else None
    if not isinstance(browsers, list):
        raise Unclear("%s has no browsers list" % where)
    for b in browsers:
        if not isinstance(b, dict) or not b.get("name") or not b.get("revision"):
            raise Unclear("%s has a malformed browser entry" % where)
        name = str(b["name"]).replace("-", "_")
        revs = [b.get("revision")] + list((b.get("revisionOverrides") or {}).values())
        for r in revs:
            if r:
                names.add("%s-%s" % (name, r))
    return names


def find_installations(roots, limit_s, cache):
    """Revision dir names every Playwright installation below the roots names: any browsers.json
    (Node playwright-core, the Python and .NET driver package, ...) and browsers.json inside
    Playwright jars (Java driver bundle). Raises Unclear on a timeout, an unreadable directory, a
    browsers.json in a Playwright path that does not parse, or a jar that cannot be read."""
    refs, files = set(), []
    t_end = time.time() + limit_s
    for root in roots:
        try:
            rst = os.lstat(root)
        except OSError:
            continue
        stack = [root]
        while stack:
            if time.time() > t_end:
                raise Unclear("the search did not finish in %ss" % limit_s)
            d = stack.pop()
            try:
                it = list(os.scandir(d))
            except OSError as exc:
                raise Unclear("%s unreadable (%s)" % (d, exc.strerror or exc))
            for de in it:
                if de.name in SKIP_NAMES:
                    continue
                try:
                    st = de.stat(follow_symlinks=False)
                except OSError as exc:
                    raise Unclear("%s unreadable (%s)" % (de.path, exc.strerror or exc))
                if stat.S_ISDIR(st.st_mode):
                    if st.st_dev != rst.st_dev or de.path in L.mount_points() or de.path == cache:
                        continue
                    if de.name == "projects" and os.path.basename(d).startswith(".claude"):
                        continue
                    stack.append(de.path)
                elif not stat.S_ISREG(st.st_mode):
                    continue
                elif de.name == "browsers.json":
                    try:
                        with open(de.path, encoding="utf-8") as fh:
                            data = json.load(fh)
                        refs |= parse_browsers(data, de.path)
                        files.append(de.path)
                    except (OSError, ValueError, Unclear) as exc:
                        if "playwright" in de.path.lower():
                            raise Unclear("%s: %s" % (de.path, exc))
                elif de.name.endswith(".jar") and ("playwright" in de.name.lower() or "driver-bundle" in de.name.lower()):
                    try:
                        with zipfile.ZipFile(de.path) as z:
                            for zn in z.namelist():
                                if zn.endswith("browsers.json"):
                                    refs |= parse_browsers(json.loads(z.read(zn).decode("utf-8")),
                                                           de.path + "!" + zn)
                                    files.append(de.path + "!" + zn)
                    except (OSError, ValueError, zipfile.BadZipFile, Unclear) as exc:
                        raise Unclear("%s: %s" % (de.path, exc))
    return refs, files


def revisions_in_use(cache):
    """Revision dir names a running process uses (its executable or a command-line argument lies
    below cache/<rev>). Raises Unclear when /proc cannot be listed."""
    used = set()
    try:
        pids = [n for n in os.listdir("/proc") if n.isdigit()]
    except OSError as exc:
        raise Unclear("/proc unreadable (%s)" % exc)
    prefix = cache.rstrip("/") + "/"
    for pid in pids:
        texts = []
        try:
            with open("/proc/%s/cmdline" % pid, "rb") as fh:
                texts += fh.read().decode("utf-8", "replace").split("\0")
        except OSError:
            pass
        try:
            texts.append(os.readlink("/proc/%s/exe" % pid))
        except OSError:
            pass
        for t in texts:
            i = t.find(prefix)
            if i >= 0:
                used.add(t[i + len(prefix):].split("/")[0])
    return used


def playwright_prune(args):
    """Delete browser revision dirs that no installation names and no process uses. Never
    installs or downloads anything; anything unclear prunes nothing."""
    cache = pw_cache_dir(args)
    if cache is None:
        out("playwright prune skipped: PLAYWRIGHT_BROWSERS_PATH does not look like a Playwright cache")
        return
    if not os.path.isdir(cache):
        out("playwright cache %s: none" % cache)
        return
    roots = args.search or default_search_roots()
    try:
        refs, files = find_installations([os.path.realpath(r) for r in roots], args.time_limit, cache)
        # playwright's own install markers: .links/<hash> holds a package dir path
        for lf in glob.glob(os.path.join(cache, ".links", "*")):
            with open(lf, encoding="utf-8") as fh:
                pkg = fh.read().strip()
            bj = os.path.join(pkg, "browsers.json")
            if pkg and os.path.isfile(bj):
                with open(bj, encoding="utf-8") as fh:
                    refs |= parse_browsers(json.load(fh), bj)
                files.append(bj)
        used = revisions_in_use(cache)
    except (Unclear, OSError, ValueError) as exc:
        out("playwright prune skipped: %s; nothing is pruned when anything is unclear" % exc)
        L.log("playwright prune skipped: %s" % exc)
        return
    if not files:
        out("playwright prune skipped: no Playwright installation found (nothing is pruned blind)")
        return
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
        if n in used:
            out("in-use %s (a running process uses it, kept)" % n)
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
            own_rm(args.paths, args.dry_run)
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
