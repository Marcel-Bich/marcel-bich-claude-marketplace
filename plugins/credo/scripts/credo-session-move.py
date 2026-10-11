#!/usr/bin/env python3
"""credo-session-move.py - move Claude Code sessions from one profile
(CLAUDE_CONFIG_DIR, e.g. ~/.claude) to another (e.g. ~/.claude-other).

Backs the /credo:session-move command and skill (execution class C: only on the user's
explicit invocation). The move is: plan (dry run) -> copy + verify -> the user resumes
the session in the target profile -> only after the user's explicit OK a cleanup script
with literal paths is generated, which the USER runs. This helper never deletes session
data; the only file it ever removes is its own temporary <file>.part during a copy.

Subcommands (every one re-plans from scratch, nothing is cached between calls)
-------------------------------------------------------------------------------
  plan    --source DIR --target DIR [--profile DIR]... SESSION... [--json]
          Dry run. Resolves each SESSION (a caption / custom title such as
          "credo-bugs", or a full session id), detects the target profile layout
          (top-level symlinks = shared, real entries) and plans every artifact of the
          session: COPY, PRESENT (already identical in the target), SHARED (the target
          path resolves into the source profile through a symlink - already there,
          never copied, never cleaned up), CONFLICT (the target holds something
          different) or BLOCKED (symlink / special file in the source, a target
          symlink to somewhere else, an entry directly at the profile root, a name
          that holds a second full session id, or a leftover <file>.part from an
          interrupted copy in the target). Names that
          carry only the short id are listed for REVIEW and never copied. Changes
          nothing.
  copy    same arguments. Plans again (including the liveness check) and copies only
          when the plan is clean: per file, one source per explicit target path,
          written to <dst>.part (O_EXCL, O_NOFOLLOW), fsynced, then hard-linked to
          <dst> (fails when <dst> exists, so nothing is overwritten) and the own .part
          unlinked; mode and mtime kept. A target file therefore never exists half
          written. Files already identical in the target are skipped, so re-running
          copy after an interruption completes the copy. A leftover .part (crash
          between create and link) is never removed by the helper: the plan BLOCKS on
          it and the user removes it. Then runs verify.
  verify  same arguments. Size, sha256 and entry count for every copied or present
          item, each file read once on both sides (a file that changes while being
          read is a mismatch). Refused sessions (live, current, conflict, blocked)
          get no manifest and the exit code is 1. When everything matches it records
          a manifest (source AND target size + sha256 of every file) in
          <target>/credo/session-move/<id>.json. Run it BEFORE resuming in the target.
  cleanup-script same arguments plus --user-confirmed (the user tested the resume in
          the target and explicitly approved removing the source copies). Checks that
          the source is unchanged since the verify (manifest), that every manifest
          item is part of the fresh plan of this session, that no live holder exists
          in any profile other than the target (liveness that cannot be determined
          refuses), and that every path is inside the source profile and names THIS
          session's id. A source file is left out of the script (reported as KEPT)
          unless its target counterpart still exists as a regular file, not through a
          symlink, and is intact. Intact means, per file kind:
            - the session's main transcript projects/<slug>/<id>.jsonl (append-only):
              at least as large as at the verify and still starting with the verified
              content (sha256 of the first <verified size> bytes); it may have grown;
            - every other file: EXACTLY the verified size and sha256 (a state file that
              the resumed session rewrote or appended to is kept, even if the verified
              bytes are still a prefix).
          Writes a POSIX sh script with literal paths only (no variables except its own
          two counters) to a new mktemp dir (mode 0700, file 0600, written under a temp
          name and renamed; on a write failure only that own temp file is removed and
          the dir is reported) under /tmp. At run time a file is removed only while it
          is still a regular file with the recorded sha256, its target counterpart is a
          regular file that is not the same file ([ ! src -ef dst ]) and is intact by
          the same rule (transcript: the first <verified size> bytes (head -c) hash to
          the verified target sha256 and the size is at least the verified one; any
          other file: wc -c equals the verified size and the whole file hashes to the
          verified sha256), and both directories (source and target) still resolve
          (pwd -P) to the recorded physical directories; directories only with rmdir
          (empty only). At the end the script prints "removed N, kept M" (files left
          out at generation count as kept) and exits 1 when anything was kept. Needs
          sha256sum or shasum. Shared items are never in it. The script is not removed
          automatically.

          Known limits of the cleanup. A transcript that the resumed session rewrote in
          place while keeping the verified bytes as a prefix cannot be told from growth
          (append-only is assumed for that one file). One path with a control character
          in its name refuses the whole script (all or nothing, no partial script). The
          verify manifest must have target size/sha256 equal to the source size/sha256
          per file, otherwise it is rejected as malformed.

Refusals (exit 1, nothing copied): a session that is the current session
(CLAUDE_CODE_SESSION_ID); a live session: a Claude process whose argv names the id
(e.g. --resume <id>), or a pid file sessions/<pid>.json naming the id in the source,
the target or any sibling ~/.claude* profile dir with a sessions/ dir, whose pid is
alive (any process name; a dead pid is stale; pid reuse is decided only by the pid
file's "procStart", which equals /proc/<pid>/stat field 22 while the session runs: a
mismatch means the pid now belongs to another process and is ignored, a match, an
absent, unreadable, zero, negative or non-integer procStart means live; a process
claude_args() recognises as the Claude CLI is never ignored; in ps mode every alive pid
from a pid file counts as live; no clocks or mtimes are used); liveness that cannot be determined (no /proc and no
working `ps -axww`); ambiguous or unknown captions (also: custom-title.json and the
transcript disagree); target == source; a missing profile; control characters in a
profile path; any CONFLICT or BLOCKED item. Sessions whose files contain symlinks
(e.g. subagent files symlinked into another session's dir by an earlier manual move)
are BLOCKED and cannot be moved with this helper.

Liveness scope: the source, the target, every sibling .claude* dir with a sessions/ dir
and every dir passed with --profile (repeatable). Sessions started with another
profile location and Windows-side sessions are not seen unless their profile dir is
passed with --profile (a Claude process whose argv names the id is found anyway, as far
as the process table shows it). A transcript cwd with control characters is not shown or
put into the resume command (a warning replaces it).

Session artifacts are derived from what exists for the id in the source profile:
projects/<slug>/<id>.jsonl, projects/<slug>/<id>/ and every entry whose NAME holds the
full id up to SCAN_DEPTH levels below the profile root (tasks/, todos/, session-env/,
file-history/, credo/ and dogma/ per-session state, mode files, ...). Shared trees
(projects/ of other sessions, plugins/, sessions/, backups, caches) are never scanned;
shared logs and profile-global config never carry the id in their name and are never
copied.

Text output: every string that comes from the profile (custom titles, slugs, paths,
reasons, error texts) is printed with control, format (bidi) and surrogate characters
escaped as \\xNN / \\uNNNN, so nothing can inject terminal escapes or fake output
lines; a title or slug that needed this adds a WARNING line. --json output is
JSON-escaped and unchanged.

Exit codes: 0 ok, 1 refused / conflict / mismatch / error, 2 usage.
Env: CLAUDE_CODE_SESSION_ID (the caller's session), CREDO_SESSION_MOVE_TMPDIR (base
dir for the cleanup script, default /tmp), CREDO_SESSION_MOVE_RECENT (seconds; a
transcript written more recently gets a warning, default 120),
CREDO_SESSION_MOVE_PROC_ROOT (test seam: the /proc mount to read, default /proc; only
honoured together with CREDO_SESSION_MOVE_TEST=1).

Python 3 stdlib only.
"""

import argparse
import datetime
import hashlib
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import unicodedata

UUID_FULL = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
UUID_ANY = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")
SHA_HEX = re.compile(r"^[0-9a-f]{64}$")
PROC_ROOT = "/proc"
SCAN_DEPTH = 4
# Top-level entries never scanned for session artifacts.
PRUNE_TOP = {"projects", "plugins", "sessions", "backups", "cache", "paste-cache",
             "shell-snapshots", "statsig", "ide"}
MANIFEST_REL = os.path.join("credo", "session-move")
MANIFEST_VERSION = 2
INTERPRETERS = ("node", "bun", "deno")
CHUNK = 1 << 20
PART = ".part"


class Fail(Exception):
    pass


# --- small helpers -------------------------------------------------------------

def has_ctrl(p):
    return any(ord(c) < 32 or ord(c) == 0x7f for c in p)


def check_text(what, p):
    if has_ctrl(p):
        raise Fail("%s contains control characters: %r" % (what, p))


def check_literal(p):
    """Raise ValueError unless p may be written literally into the cleanup script."""
    if has_ctrl(p) or "\\" in p:
        raise ValueError("path contains control characters or a backslash: %r" % p)


def real(p):
    if not p:
        raise Fail("empty path")
    return os.path.realpath(p)


def inside(path, root):
    rp, rr = real(path), real(root)
    return rp == rr or rp.startswith(rr.rstrip(os.sep) + os.sep)


def prefixes(root, rel):
    parts = rel.split(os.sep)
    for i in range(1, len(parts) + 1):
        yield os.path.join(root, *parts[:i])


def symlink_component(root, rel):
    """First path from root/<first part> down to root/rel that is a symlink, else None."""
    for p in prefixes(root, rel):
        if os.path.islink(p):
            return p
        if not os.path.lexists(p):
            return None
    return None


def same_bytes(a, b):
    try:
        if os.path.getsize(a) != os.path.getsize(b):
            return False
        with open(a, "rb") as fa, open(b, "rb") as fb:
            while True:
                x, y = fa.read(CHUNK), fb.read(CHUNK)
                if x != y:
                    return False
                if not x:
                    return True
    except OSError:
        return False


def read_hash(fd, limit=None):
    """(bytes read, sha256 hex) of an open fd, at most limit bytes."""
    h, n = hashlib.sha256(), 0
    while limit is None or n < limit:
        b = os.read(fd, CHUNK if limit is None else min(CHUNK, limit - n))
        if not b:
            break
        h.update(b)
        n += len(b)
    return n, h.hexdigest()


def sha256(path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        return read_hash(fd)[1]
    finally:
        os.close(fd)


def prefix_sha256(path, size):
    """sha256 of the first size bytes (None when shorter), never through a final symlink."""
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        n, h = read_hash(fd, size)
    finally:
        os.close(fd)
    return h if n == size else None


def safe_title(t):
    return re.sub(r"[^A-Za-z0-9 ._-]", "", t or "")[:60]


# Unicode categories shown escaped in text output: control, format (bidi overrides etc.),
# surrogates (undecodable file names), line / paragraph separators.
UNSAFE_CATS = ("Cc", "Cf", "Cs", "Zl", "Zp")


def show(t):
    """t for the terminal: control and other invisible / spoofing characters as \\xNN,
    \\uNNNN or \\UNNNNNNNN, everything else unchanged."""
    out = []
    for c in t:
        if unicodedata.category(c) in UNSAFE_CATS:
            o = ord(c)
            out.append("\\x%02x" % o if o < 0x100 else "\\u%04x" % o if o < 0x10000
                       else "\\U%08x" % o)
        else:
            out.append(c)
    return "".join(out)


def unsafe(t):
    return show(t) != t


def scrub(o):
    """Copy of a plan / report structure with every string passed through show()."""
    if isinstance(o, str):
        return show(o)
    if isinstance(o, list):
        return [scrub(x) for x in o]
    if isinstance(o, dict):
        return {(show(k) if isinstance(k, str) else k): scrub(v) for k, v in o.items()}
    return o


def is_transcript(rel, sid):
    """True only for the session's main transcript projects/<slug>/<sid>.jsonl, the one
    append-only file a resumed session grows; every other file must stay byte-identical."""
    parts = rel.split(os.sep)
    return len(parts) == 3 and parts[0] == "projects" and parts[2] == sid + ".jsonl"


def sq(p):
    return "'" + p.replace("'", "'\"'\"'") + "'"


# --- process table (liveness) --------------------------------------------------
# Liveness fails closed: when neither /proc nor `ps` can be read, every session is
# refused ("liveness cannot be determined"), never treated as closed.

def proc_root():
    """The /proc mount to read. CREDO_SESSION_MOVE_PROC_ROOT is a test seam and is honoured
    only together with CREDO_SESSION_MOVE_TEST=1; otherwise the real /proc is read."""
    if os.environ.get("CREDO_SESSION_MOVE_TEST") == "1":
        return os.environ.get("CREDO_SESSION_MOVE_PROC_ROOT") or PROC_ROOT
    return PROC_ROOT


def read_cmdline(root, pid):
    try:
        with open(os.path.join(root, str(pid), "cmdline"), "rb") as fh:
            raw = fh.read()
    except OSError:
        return []
    return [p.decode("utf-8", "replace") for p in raw.split(b"\0") if p != b""]


def read_exe(root, pid):
    try:
        return os.readlink(os.path.join(root, str(pid), "exe"))
    except OSError:
        return ""


def proc_stat(root, pid):
    """(state, start ticks or None) from <root>/<pid>/stat, None when unreadable."""
    try:
        with open(os.path.join(root, str(pid), "stat")) as fh:
            rest = fh.read().rsplit(")", 1)[-1].split()
    except OSError:
        return None
    if not rest:
        return None
    ticks = rest[19] if len(rest) > 19 else ""
    return rest[0], int(ticks) if ticks.isdigit() else None


def table_from_proc(root):
    """{pid: {argv, exe}} of the non-zombie processes in /proc, None if unusable."""
    try:
        pids = [int(e) for e in os.listdir(root) if e.isdigit()]
    except OSError:
        return None
    if not pids:
        return None
    tab = {}
    for pid in pids:
        s = proc_stat(root, pid)
        if s is None or s[0] in ("Z", "X"):
            continue
        tab[pid] = {"argv": read_cmdline(root, pid), "exe": read_exe(root, pid)}
    return tab


def table_from_ps():
    """{pid: {argv, exe}} from `ps -axww -o pid=,command=`, None if unusable.
    -ww: command lines are not truncated at the terminal width. argv is the command split
    on whitespace (good enough to find an id)."""
    ps = shutil.which("ps")
    if not ps:
        return None
    try:
        r = subprocess.run([ps, "-axww", "-o", "pid=,command="], stdout=subprocess.PIPE,
                           stderr=subprocess.DEVNULL, timeout=30)
    except (OSError, subprocess.SubprocessError):
        return None
    if r.returncode != 0:
        return None
    tab = {}
    for line in r.stdout.decode("utf-8", "replace").splitlines():
        parts = line.split(None, 1)
        if not parts or not parts[0].isdigit():
            continue
        tab[int(parts[0])] = {"argv": parts[1].split() if len(parts) > 1 else [], "exe": ""}
    return tab or None


def process_table():
    """(table, mode) with mode "proc" or "ps"; raises Fail when neither works."""
    root = proc_root()
    tab = table_from_proc(root)
    if tab is not None:
        return tab, "proc"
    tab = table_from_ps()
    if tab is not None:
        return tab, "ps"
    raise Fail("liveness cannot be determined: %s is not readable and `ps -axww "
               "-o pid=,command=` did not work - refusing (a session that cannot be "
               "checked is never treated as closed)" % root)


def alive(pid, tab, mode):
    if pid in tab:
        return True
    if mode == "proc":
        s = proc_stat(proc_root(), pid)
        if s is not None:
            return s[0] not in ("Z", "X")
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except OSError:
        return True  # exists but not ours, or unknown: the safe side
    return True


def claude_args(entry):
    """argv after the executable when the process is the Claude Code CLI, else None."""
    argv, exe = entry.get("argv") or [], entry.get("exe") or ""
    if not argv:
        return None
    base0 = os.path.basename(argv[0])
    if base0 == "claude" or "/claude/versions/" in exe or "/claude/versions/" in argv[0] \
            or argv[0].startswith("claude "):
        return argv[1:]
    if len(argv) > 1 and base0.split(".")[0] in INTERPRETERS:
        a1 = argv[1]
        if os.path.basename(a1) == "claude" or "claude-code" in a1 or "@anthropic-ai" in a1:
            return argv[2:]
    return None


def config_dir_of(pid):
    """CLAUDE_CONFIG_DIR of a process (ONLY that key is read), default ~/.claude;
    None when the environment is unreadable."""
    try:
        with open(os.path.join(proc_root(), str(pid), "environ"), "rb") as fh:
            raw = fh.read()
    except OSError:
        return None
    for item in raw.split(b"\0"):
        k, sep, v = item.partition(b"=")
        if sep and k == b"CLAUDE_CONFIG_DIR" and v:
            return v.decode("utf-8", "replace")
    return os.path.expanduser("~/.claude")


def profile_dirs(source, target, extra=()):
    """source, target, the given extra profile dirs (--profile) and every sibling .claude*
    dir (next to either) with a sessions/ dir. Other CLAUDE_CONFIG_DIR locations and
    Windows-side sessions are not seen unless they are passed as extra profiles."""
    out, seen = [], set()
    cands = [source, target] + list(extra)
    for base in (os.path.dirname(source), os.path.dirname(target)):
        try:
            names = sorted(os.listdir(base))
        except OSError:
            continue
        cands += [os.path.join(base, n) for n in names if n.startswith(".claude")]
    for p in cands:
        if p not in (source, target) and p not in extra \
                and not os.path.isdir(os.path.join(p, "sessions")):
            continue
        key = os.path.realpath(p)
        if key not in seen:
            seen.add(key)
            out.append(p)
    return out


def pid_reused(pid, proc_start, tab, mode):
    """True only when the pid file proves the pid now belongs to another process: its
    "procStart" (start ticks, equal to /proc/<pid>/stat field 22 while the session runs)
    differs from the process's current start ticks. No clocks or mtimes are involved.
    Everything else counts as live: procStart absent, not a positive integer or unreadable,
    ticks unreadable, ps mode (no /proc), and any process claude_args() recognises as the
    Claude CLI."""
    if mode != "proc":
        return False
    if isinstance(proc_start, str) and proc_start.isdigit():
        proc_start = int(proc_start)
    if isinstance(proc_start, bool) or not isinstance(proc_start, int) or proc_start <= 0:
        return False  # not a start time: unknown, so live
    entry = tab.get(pid)
    if entry is not None and claude_args(entry) is not None:
        return False
    s = proc_stat(proc_root(), pid)
    if s is None or s[1] is None:
        return False
    return s[1] != proc_start


def pid_file_warnings(profiles):
    """Paths of the pid files in the scanned sessions/ dirs that are unreadable, not a JSON
    object or have no usable pid. The liveness check ignores them; they are listed as a
    WARNING, they never refuse a plan."""
    out = []
    for prof in profiles:
        sdir = os.path.join(prof, "sessions")
        try:
            names = sorted(os.listdir(sdir))
        except OSError:
            continue
        for n in names:
            if not n.endswith(".json"):
                continue
            path = os.path.join(sdir, n)
            try:
                with open(path) as fh:
                    d = json.load(fh)
            except (OSError, ValueError):
                out.append(path)
                continue
            pid = d.get("pid") if isinstance(d, dict) else None
            if not isinstance(pid, int) or isinstance(pid, bool) or pid <= 1:
                out.append(path)
    return out


def live_holders(sid, profiles, tab, mode):
    """Live processes holding sid: [{pid, how, profile}] (profile None = unknown)."""
    found = {}
    for prof in profiles:
        sdir = os.path.join(prof, "sessions")
        try:
            names = sorted(os.listdir(sdir))
        except OSError:
            names = []
        for n in names:
            if not n.endswith(".json"):
                continue
            path = os.path.join(sdir, n)
            try:
                with open(path) as fh:
                    d = json.load(fh)
            except (OSError, ValueError):
                continue
            if not isinstance(d, dict) or d.get("sessionId") != sid:
                continue
            if d.get("credoPeerLan"):
                continue  # our relay mirrors, not local holders (bridge mirrors keep the pid)
            pid = d.get("pid")
            if not isinstance(pid, int) or isinstance(pid, bool) or pid <= 1 \
                    or not alive(pid, tab, mode):
                continue
            if pid_reused(pid, d.get("procStart"), tab, mode):
                continue
            found.setdefault(pid, {"pid": pid, "how": [], "profile": prof})
            found[pid]["how"].append("pid file " + path)
    for pid, entry in sorted(tab.items()):
        if pid == os.getpid():
            continue
        args = claude_args(entry)
        if args is None or not any(sid in a for a in args):
            continue
        h = found.setdefault(pid, {"pid": pid, "how": [],
                                   "profile": config_dir_of(pid) if mode == "proc" else None})
        h["how"].append("claude argv names the id")
    return [dict(v, how="; ".join(v["how"])) for _, v in sorted(found.items())]


# --- session resolution --------------------------------------------------------

def transcripts(source):
    proj = os.path.join(source, "projects")
    if not os.path.isdir(proj):
        raise Fail("no projects/ directory in the source profile %s" % source)
    out = []
    for slug in sorted(os.listdir(proj)):
        d = os.path.join(proj, slug)
        if not os.path.isdir(d):
            continue
        for f in sorted(os.listdir(d)):
            if f.endswith(".jsonl") and UUID_FULL.match(f[:-6]):
                out.append((slug, f[:-6], os.path.join(d, f)))
    return out


def transcript_info(path, want_title=True):
    """(last custom title, first cwd) from a transcript."""
    title, cwd = None, None
    try:
        with open(path, "rb") as fh:
            for line in fh:
                if want_title and b'"custom-title"' in line:
                    try:
                        d = json.loads(line)
                    except ValueError:
                        d = None
                    if isinstance(d, dict) and d.get("type") == "custom-title" \
                            and isinstance(d.get("customTitle"), str):
                        title = d["customTitle"]
                if cwd is None and b'"cwd"' in line:
                    try:
                        d = json.loads(line)
                    except ValueError:
                        d = None
                    if isinstance(d, dict) and isinstance(d.get("cwd"), str):
                        cwd = d["cwd"]
                        if not want_title:
                            break
    except OSError:
        pass
    return title, cwd


def title_json(source, slug, sid):
    path = os.path.join(source, "projects", slug, sid, "custom-title.json")
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
        with os.fdopen(fd) as fh:
            d = json.load(fh)
    except (OSError, ValueError):
        return None
    t = d.get("customTitle") if isinstance(d, dict) else None
    return t if isinstance(t, str) else None


def session_titles(source, slug, sid, path):
    """Distinct titles: [custom-title.json title, newest transcript title] (either may be
    missing). Two entries = the sources disagree."""
    out = []
    for t in (title_json(source, slug, sid), transcript_info(path)[0]):
        if t is not None and t not in out:
            out.append(t)
    return out


def resolve(source, tokens):
    """[{id, slug, transcript}] in token order (deduplicated), raises Fail."""
    all_t = transcripts(source)
    titles = None
    out, errors = [], []
    for tok in tokens:
        if UUID_FULL.match(tok.lower()):
            sid = tok.lower()
            hits = [t for t in all_t if t[1] == sid]
            if len(hits) != 1:
                errors.append("session id %s: %s" % (
                    sid, "no transcript in %s/projects" % source if not hits else
                    "%d transcripts (%s)" % (len(hits), ", ".join(h[0] for h in hits))))
                continue
        else:
            if titles is None:
                titles = [(t, session_titles(source, t[0], t[1], t[2])) for t in all_t]
            found = [(t, ts) for t, ts in titles if tok in ts]
            if not found:
                found = [(t, ts) for t, ts in titles if tok.lower() in [x.lower() for x in ts]]
            if len(found) != 1:
                errors.append('caption "%s": %s' % (
                    tok, "no session with this title in %s" % source if not found else
                    "ambiguous, %d sessions: %s - pass the id instead" % (
                        len(found), ", ".join(h[0][1] for h in found))))
                continue
            if len(found[0][1]) > 1:
                errors.append('caption "%s": session %s has two different titles ("%s" in '
                              'custom-title.json, "%s" in the transcript) - ambiguous, pass '
                              'the id instead' % (tok, found[0][0][1], found[0][1][0],
                                                  found[0][1][1]))
                continue
            hits = [found[0][0]]
        slug, sid, path = hits[0]
        if sid not in [s["id"] for s in out]:
            out.append({"id": sid, "slug": slug, "transcript": path})
    if errors:
        raise Fail("; ".join(errors))
    return out


# --- artifact discovery and planning ---------------------------------------------

def scan(source, sid):
    """(candidate rel paths, review rel paths) whose names carry the id / short id."""
    short = sid[:8]
    cand, review = [], []

    def walk(rel, depth):
        try:
            entries = sorted(os.scandir(os.path.join(source, rel) if rel else source),
                             key=lambda e: e.name)
        except OSError:
            return
        for e in entries:
            r = os.path.join(rel, e.name) if rel else e.name
            low = e.name.lower()
            if (not rel and e.name in PRUNE_TOP) or ".bak" in low or "backup" in low \
                    or r == MANIFEST_REL or e.name.startswith(".credentials"):
                continue
            if sid in e.name:
                cand.append(r)
            elif short in e.name and not UUID_ANY.search(e.name):
                review.append(r)
            elif depth < SCAN_DEPTH and e.is_dir(follow_symlinks=False):
                walk(r, depth + 1)

    walk("", 1)
    return cand, review


def tree(root):
    """(dirs, files, bad) of a real directory, rel to root; never follows symlinks."""
    dirs, files, bad = [""], [], []
    for cur, dnames, fnames in os.walk(root, followlinks=False):
        relcur = os.path.relpath(cur, root)
        relcur = "" if relcur == "." else relcur
        for n in sorted(dnames + fnames):
            p = os.path.join(cur, n)
            r = os.path.join(relcur, n) if relcur else n
            st = os.lstat(p)
            if stat.S_ISLNK(st.st_mode):
                bad.append(r + " (symlink)")
            elif stat.S_ISDIR(st.st_mode):
                dirs.append(r)
            elif stat.S_ISREG(st.st_mode):
                files.append((r, st.st_size))
            else:
                bad.append(r + " (special file)")
        dnames[:] = [d for d in dnames if not os.path.islink(os.path.join(cur, d))]
    return dirs, files, bad


def part_reason(parts):
    return ("leftover partial copy from an interrupted copy: %s - never touched by this "
            "helper; check it, remove it yourself (rm -f -- <path>) and run copy again"
            % ", ".join(parts[:5]))


def plan_item(source, target, rel, sid):
    src, dst = os.path.join(source, rel), os.path.join(target, rel)
    it = {"rel": rel, "src": src, "dst": dst, "kind": "?", "action": "copy",
          "reason": "", "files": 0, "bytes": 0, "entries": 0, "missing": 0}
    try:
        st0 = os.lstat(src)
        it["kind"] = "file" if stat.S_ISREG(st0.st_mode) else \
            "dir" if stat.S_ISDIR(st0.st_mode) else "symlink" if stat.S_ISLNK(st0.st_mode) else "other"
    except OSError:
        pass
    if os.sep not in rel:
        it.update(action="blocked", reason="top-level profile entry; never moved (the cleanup "
                  "never removes top-level entries) - move it by hand if it is needed")
        return it
    if any(x != sid for x in UUID_ANY.findall(os.path.basename(rel))):
        it.update(action="blocked", reason="names another session too (a second full session "
                  "id in the name); never copied or cleaned up")
        return it
    tlink = symlink_component(target, rel)
    if tlink:
        dest = os.readlink(tlink)
        if os.path.lexists(src) and real(dst) == real(src):
            it.update(action="shared", reason="target path runs through the symlink %s -> %s "
                      "into the source profile; already there" % (tlink, dest))
        else:
            it.update(action="blocked", reason="target path runs through the symlink %s -> %s, "
                      "which is not this item in the source profile; never written through" % (
                          tlink, dest))
        return it
    slink = symlink_component(source, rel)
    if slink:
        it.update(action="blocked", reason="source path is or runs through a symlink (%s); "
                  "never followed" % slink)
        return it
    st = os.lstat(src)
    if stat.S_ISREG(st.st_mode):
        it.update(kind="file", files=1, bytes=st.st_size, entries=1)
        if os.path.lexists(dst + PART):
            it.update(action="blocked", reason=part_reason([dst + PART]))
        elif not os.path.lexists(dst):
            it["missing"] = 1
        elif os.path.islink(dst) or not os.path.isfile(dst):
            it.update(action="conflict", reason="target exists and is not a regular file")
        elif same_bytes(src, dst):
            it.update(action="present", reason="identical file already in the target")
        else:
            it.update(action="conflict", reason="target has a different file")
        return it
    if not stat.S_ISDIR(st.st_mode):
        it.update(action="blocked", reason="not a regular file or directory")
        return it
    dirs, files, bad = tree(src)
    it.update(kind="dir", files=len(files), bytes=sum(s for _, s in files),
              entries=len(dirs) + len(files))
    if bad:
        it.update(action="blocked", reason="contains %s; never followed - a session with "
                  "symlinked files cannot be moved with this command" % ", ".join(bad[:5]))
        return it
    if not os.path.lexists(dst):
        it["missing"] = len(files) + len(dirs)
        return it
    parts = [os.path.join(dst, r) + PART for r, _ in files
             if os.path.lexists(os.path.join(dst, r) + PART)]
    if parts:
        it.update(action="blocked", reason=part_reason(parts))
        return it
    conflicts, missing = [], 0
    for d in dirs:
        p = os.path.join(dst, d) if d else dst
        if os.path.islink(p) or (os.path.lexists(p) and not os.path.isdir(p)):
            conflicts.append((d or ".") + " is not a directory in the target")
        elif not os.path.lexists(p):
            missing += 1
    for r, _ in files:
        p = os.path.join(dst, r)
        if not os.path.lexists(p):
            missing += 1
        elif os.path.islink(p) or not os.path.isfile(p) or not same_bytes(os.path.join(src, r), p):
            conflicts.append(r + " differs in the target")
    it["missing"] = missing
    if conflicts:
        it.update(action="conflict", reason="; ".join(conflicts[:5]))
    elif missing == 0:
        it.update(action="present", reason="identical tree already in the target")
    else:
        it["reason"] = "%d of %d entries missing in the target" % (missing, it["entries"])
    return it


def target_layout(source, target):
    links, reals = {}, []
    for n in sorted(os.listdir(target)):
        if n.startswith(".credentials"):
            continue
        p = os.path.join(target, n)
        if os.path.islink(p):
            links[n] = {"link": os.readlink(p), "into_source": inside(p, source)}
        else:
            reals.append(n)
    return {"symlinks": links, "real": reals}


def check_profiles(source, target):
    for name, p in (("source", source), ("target", target)):
        if not os.path.isdir(p):
            raise Fail("%s profile %s does not exist or is not a directory" % (name, p))
    if real(source) == real(target):
        raise Fail("source and target are the same profile (%s)" % real(source))
    if inside(source, target) or inside(target, source):
        raise Fail("one profile lies inside the other (%s, %s)" % (source, target))


def build_plan(source, target, tokens, extra=()):
    res = {"ok": False, "source": source, "target": target, "sessions": [], "errors": [],
           "warnings": [], "target_layout": {"symlinks": {}, "real": []}}
    try:
        check_profiles(source, target)
        res["target_layout"] = target_layout(source, target)
        sessions = resolve(source, tokens)
    except Fail as e:
        res["errors"].append(str(e))
        return res
    current = os.environ.get("CLAUDE_CODE_SESSION_ID", "")
    try:
        recent = float(os.environ.get("CREDO_SESSION_MOVE_RECENT", "120") or 120)
    except ValueError:
        recent = 120.0
    profiles = profile_dirs(source, target, extra)
    for p in pid_file_warnings(profiles):
        res["warnings"].append("pid file %s is unreadable, not a JSON object or has no usable "
                               "pid; the liveness check ignores it - check it by hand" % p)
    try:
        tab, mode = process_table()
        live_err = None
    except Fail as e:
        tab, mode, live_err = {}, None, str(e)
    for s in sessions:
        sid = s["id"]
        titles = session_titles(source, s["slug"], sid, s["transcript"])
        _, cwd = transcript_info(s["transcript"], want_title=False)
        bad_cwd = bool(cwd) and unsafe(cwd)
        if bad_cwd:
            res["warnings"].append("cwd of %s in its transcript contains control characters "
                                   "and is not shown (it would go raw into the terminal and "
                                   "the resume command); read it from the transcript "
                                   "yourself" % sid)
            cwd = None
        rels = [os.path.join("projects", s["slug"], sid + ".jsonl")]
        if os.path.lexists(os.path.join(source, "projects", s["slug"], sid)):
            rels.append(os.path.join("projects", s["slug"], sid))
        cand, review = scan(source, sid)
        rels += cand
        ent = {"id": sid, "title": titles[0] if titles else None, "titles": titles,
               "slug": s["slug"], "cwd": cwd,
               "items": [plan_item(source, target, r, sid) for r in rels], "review": review,
               "live": [] if live_err else live_holders(sid, profiles, tab, mode),
               "liveness_error": live_err, "profiles_checked": profiles, "refusals": []}
        if sid == current:
            ent["refusals"].append("%s is the current session; run /credo:session-move from "
                                   "a new, independent session" % sid)
        if live_err:
            ent["refusals"].append(live_err)
        for h in ent["live"]:
            ent["refusals"].append("session is live: pid %d (%s)" % (h["pid"], h["how"]))
        for it in ent["items"]:
            if it["action"] in ("conflict", "blocked"):
                ent["refusals"].append("%s %s: %s" % (it["action"].upper(), it["rel"], it["reason"]))
        if any(unsafe(t) for t in titles):
            res["warnings"].append("custom title of %s contains control characters; it is "
                                   "shown escaped in the text output" % sid)
        if unsafe(s["slug"]):
            res["warnings"].append("slug of %s contains control characters; it is shown "
                                   "escaped in the text output" % sid)
        if len(titles) > 1:
            res["warnings"].append('%s has two different titles: "%s" (custom-title.json) and '
                                   '"%s" (transcript)' % (sid, titles[0], titles[1]))
        try:
            age = time.time() - os.lstat(s["transcript"]).st_mtime
            if age < recent:
                res["warnings"].append("transcript of %s was written %d s ago - make sure the "
                                       "session is closed" % (sid, age))
        except OSError:
            pass
        if not cwd and not bad_cwd:
            res["warnings"].append("no cwd found in the transcript of %s" % sid)
        res["sessions"].append(ent)
    res["ok"] = not res["errors"] and all(not s["refusals"] for s in res["sessions"])
    return res


# --- copy ------------------------------------------------------------------------

def ensure_parents(source, target, rel):
    parts = rel.split(os.sep)[:-1]
    for i in range(1, len(parts) + 1):
        d = os.path.join(target, *parts[:i])
        if os.path.islink(d):
            raise Fail("refusing to write through the symlink %s" % d)
        if not os.path.lexists(d):
            try:
                mode = stat.S_IMODE(os.lstat(os.path.join(source, *parts[:i])).st_mode)
            except OSError:
                mode = 0o700
            os.mkdir(d, 0o700)
            os.chmod(d, mode)
        elif not os.path.isdir(d):
            raise Fail("%s exists in the target and is not a directory" % d)


def copy_file(src, dst):
    """One source, one explicit target, via <dst>.part + hard link. Never overwrites,
    never follows a symlink, never leaves a half-written dst. True when copied, False
    when an identical dst was already there."""
    if os.path.lexists(dst):
        if os.path.islink(dst) or not os.path.isfile(dst) or not same_bytes(src, dst):
            raise Fail("%s exists in the target with different content" % dst)
        return False
    part = dst + PART
    fin = os.open(src, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        st = os.fstat(fin)
        if not stat.S_ISREG(st.st_mode):
            raise Fail("%s is not a regular file" % src)
        try:
            fout = os.open(part, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        except FileExistsError:
            raise Fail("%s exists (an interrupted copy?); not touched - check it, remove it "
                       "yourself and run copy again" % part)
        own = os.fstat(fout)
        linked = False
        try:
            try:
                while True:
                    b = os.read(fin, CHUNK)
                    if not b:
                        break
                    view = memoryview(b)
                    while view:
                        n = os.write(fout, view)
                        view = view[n:]
                os.fchmod(fout, stat.S_IMODE(st.st_mode))
                os.fsync(fout)
            finally:
                os.close(fout)
            os.utime(part, ns=(st.st_atime_ns, st.st_mtime_ns), follow_symlinks=False)
            try:
                os.link(part, dst, follow_symlinks=False)
                linked = True
            except FileExistsError:
                pass
        finally:
            # remove only the .part this call created (same inode), nothing else
            try:
                cur = os.lstat(part)
                if (cur.st_dev, cur.st_ino) == (own.st_dev, own.st_ino):
                    os.unlink(part)
            except OSError:
                pass
        if not linked:
            if not same_bytes(src, dst):
                raise Fail("%s appeared in the target with different content" % dst)
            return False
        return True
    finally:
        os.close(fin)


def copy_item(source, target, it):
    ensure_parents(source, target, it["rel"])
    src, dst = it["src"], it["dst"]
    if it["kind"] == "file":
        copy_file(src, dst)
        return
    dirs, files, bad = tree(src)
    if bad:
        raise Fail("%s changed: contains %s" % (src, ", ".join(bad)))
    created = []
    for d in dirs:  # top-down (os.walk order)
        s, t = (os.path.join(src, d), os.path.join(dst, d)) if d else (src, dst)
        if os.path.islink(t):
            raise Fail("refusing to write through the symlink %s" % t)
        if not os.path.lexists(t):
            os.mkdir(t, 0o700)
            created.append((s, t))
        elif not os.path.isdir(t):
            raise Fail("%s exists in the target and is not a directory" % t)
    for r, _ in files:
        copy_file(os.path.join(src, r), os.path.join(dst, r))
    for s, t in reversed(created):  # bottom-up: mode and times of created dirs only
        st = os.lstat(s)
        os.chmod(t, stat.S_IMODE(st.st_mode))
        os.utime(t, ns=(st.st_atime_ns, st.st_mtime_ns), follow_symlinks=False)


# --- verify ------------------------------------------------------------------------

def hash_pair(src, dst):
    """Read each file exactly once: (mismatch text or None, record or None). A file that
    changes while it is read (size or mtime moves) is a mismatch."""
    fs = os.open(src, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        fd = os.open(dst, os.O_RDONLY | os.O_NOFOLLOW)
        try:
            s0, d0 = os.fstat(fs), os.fstat(fd)
            if not (stat.S_ISREG(s0.st_mode) and stat.S_ISREG(d0.st_mode)):
                return "not a regular file", None
            ns, hs = read_hash(fs)
            nd, hd = read_hash(fd)
            s1, d1 = os.fstat(fs), os.fstat(fd)
        finally:
            os.close(fd)
    finally:
        os.close(fs)
    if s1.st_size != ns or d1.st_size != nd or s1.st_mtime_ns != s0.st_mtime_ns \
            or d1.st_mtime_ns != d0.st_mtime_ns:
        return "changed while verifying (still being written?)", None
    rec = {"path": src, "size": ns, "sha256": hs, "dst_size": nd, "dst_sha256": hd}
    if ns != nd:
        return "size %d != %d" % (ns, nd), rec
    if hs != hd:
        return "content differs", rec
    return None, rec


def verify_item(it):
    """(mismatch strings, file records, source dirs) for one copied / present item."""
    src, dst, rel = it["src"], it["dst"], it["rel"]
    if not os.path.lexists(dst):
        return ["%s: missing in the target" % rel], [], []
    if os.path.islink(dst):
        return ["%s: is a symlink in the target" % rel], [], []
    if it["kind"] == "file":
        if not os.path.isfile(dst):
            return ["%s: not a regular file in the target" % rel], [], []
        try:
            m, rec = hash_pair(src, dst)
        except OSError as e:
            return ["%s: cannot read (%s)" % (rel, e)], [], []
        return (["%s: %s" % (rel, m)] if m else []), ([rec] if rec and not m else []), []
    sd, sf, _ = tree(src)
    td, tf, tbad = tree(dst)
    out, recs = [], []
    if tbad:
        out.append("%s: target contains %s" % (rel, ", ".join(tbad[:5])))
    if len(sd) + len(sf) != len(td) + len(tf):
        out.append("%s: %d entries in the source, %d in the target" % (
            rel, len(sd) + len(sf), len(td) + len(tf)))
    sb, tb = sum(s for _, s in sf), sum(s for _, s in tf)
    if sb != tb:
        out.append("%s: %d bytes in the source, %d in the target" % (rel, sb, tb))
    tset = dict(tf)
    for r, _ in sf:
        if r not in tset:
            out.append("%s/%s: missing in the target" % (rel, r))
            continue
        try:
            m, rec = hash_pair(os.path.join(src, r), os.path.join(dst, r))
        except OSError as e:
            m, rec = "cannot read (%s)" % e, None
        if m:
            out.append("%s/%s: %s" % (rel, r, m))
        else:
            recs.append(rec)
    dirs = [os.path.join(src, x) if x else src for x in sd]
    return out, recs, dirs


def manifest_path(target, sid):
    return os.path.join(target, MANIFEST_REL, sid + ".json")


def write_manifest(source, target, sess, files, dirs):
    items = [it["rel"] for it in sess["items"] if it["action"] in ("copy", "present")]
    data = {"version": MANIFEST_VERSION, "session": sess["id"], "title": sess["title"],
            "source": source, "target": target, "items": items, "files": files,
            "dirs": dirs, "verified_at": datetime.datetime.now().isoformat(timespec="seconds")}
    path = manifest_path(target, sess["id"])
    os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
    tmp = path + ".tmp"
    try:
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    except FileExistsError:
        raise Fail("%s exists (an interrupted verify?); not touched - check it, remove it "
                   "yourself and run verify again" % tmp)
    with os.fdopen(fd, "w") as fh:
        json.dump(data, fh, indent=1)
    os.replace(tmp, path)
    return path


def run_verify(source, target, plan):
    res = {"ok": True, "mismatches": [], "checked": [], "manifests": [], "refusals": []}
    for s in plan["sessions"]:
        bad, recs, dirs = [], [], []
        for it in s["items"]:
            if it["action"] in ("shared",):
                continue
            if it["action"] in ("blocked",):
                bad.append("%s: blocked (%s)" % (it["rel"], it["reason"]))
                continue
            m, r, d = verify_item(it)
            bad += m
            recs += r
            dirs += d
            res["checked"].append({"rel": it["rel"], "kind": it["kind"], "files": it["files"],
                                   "bytes": it["bytes"], "entries": it["entries"],
                                   "ok": not m})
        res["mismatches"] += bad
        if s["refusals"]:  # live / current / conflict / blocked: never a manifest
            res["refusals"] += ["%s: %s" % (s["id"], r) for r in s["refusals"]]
            continue
        if not bad and not plan["errors"]:
            try:
                res["manifests"].append(write_manifest(source, target, s, recs, dirs))
            except Fail as e:
                res["refusals"].append("%s: %s" % (s["id"], e))
    res["ok"] = not res["mismatches"] and not res["refusals"] and not plan["errors"]
    return res


# --- cleanup script ------------------------------------------------------------------

def check_deletable(source, path, sid):
    """Raise ValueError unless path may appear in a cleanup script: a normalized absolute
    path strictly inside the source profile (at least two levels down), no symlink on the
    way, a component that names THIS session id, no control characters or backslashes."""
    check_literal(path)
    if not os.path.isabs(path) or os.path.normpath(path) != path:
        raise ValueError("not a normalized absolute path: %s" % path)
    rel = os.path.relpath(path, source)
    parts = rel.split(os.sep)
    if rel == "." or parts[0] == ".." or len(parts) < 2:
        raise ValueError("not inside the source profile (or a top-level entry): %s" % path)
    if not os.path.lexists(path):
        raise ValueError("does not exist: %s" % path)
    link = symlink_component(source, rel)
    if link:
        raise ValueError("runs through a symlink (%s): %s" % (link, path))
    if not inside(path, source):
        raise ValueError("resolves outside the source profile: %s" % path)
    if not sid or not any(sid in p for p in parts):
        raise ValueError("names no component with the session id %s: %s" % (sid, path))


def load_manifest(target, sid):
    path = manifest_path(target, sid)
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
        with os.fdopen(fd) as fh:
            d = json.load(fh)
    except (OSError, ValueError):
        raise Fail("no verify manifest %s - run verify (before resuming) first" % path)
    if not isinstance(d, dict) or d.get("session") != sid:
        raise Fail("manifest %s is not valid for %s" % (path, sid))
    if d.get("version") != MANIFEST_VERSION:
        raise Fail("manifest %s has an older format - run verify again" % path)
    ok = isinstance(d.get("items"), list) and all(isinstance(x, str) for x in d["items"]) \
        and isinstance(d.get("dirs"), list) and all(isinstance(x, str) for x in d["dirs"]) \
        and isinstance(d.get("files"), list) and all(
            isinstance(f, dict) and isinstance(f.get("path"), str)
            and isinstance(f.get("size"), int) and isinstance(f.get("dst_size"), int)
            and isinstance(f.get("sha256"), str) and SHA_HEX.match(f["sha256"])
            and isinstance(f.get("dst_sha256"), str) and SHA_HEX.match(f["dst_sha256"])
            and f["dst_size"] == f["size"] and f["dst_sha256"] == f["sha256"]
            for f in d["files"])
    if not ok:
        raise Fail("manifest %s is malformed" % path)
    return d


def under_items(source, path, items):
    rel = os.path.relpath(path, source)
    return any(rel == i or rel.startswith(i + os.sep) for i in items)


def target_problem(source, target, f, sid):
    """Why the source file must be kept (its target counterpart is not what was
    verified), or None. The session's main transcript (append-only) may have grown but
    must still start with the verified bytes; every other file must have exactly the
    verified size and sha256."""
    rel = os.path.relpath(f["path"], source)
    dst = os.path.join(target, rel)
    link = symlink_component(target, rel)
    if link:
        return "the target path runs through the symlink %s" % link
    try:
        st = os.lstat(dst)
    except OSError:
        return "the target copy %s is missing" % dst
    if not stat.S_ISREG(st.st_mode):
        return "the target copy %s is not a regular file" % dst
    if is_transcript(rel, sid):
        if st.st_size < f["dst_size"]:
            return "the target copy is smaller than at the verify (%d < %d bytes)" % (
                st.st_size, f["dst_size"])
        try:
            h = prefix_sha256(dst, f["dst_size"])
        except OSError as e:
            return "the target copy cannot be read (%s)" % e
        if h != f["dst_sha256"]:
            return "the target copy no longer starts with the verified content"
        return None
    if st.st_size != f["dst_size"]:
        return ("the target copy has another size than at the verify (%d != %d bytes); "
                "only the transcript may grow" % (st.st_size, f["dst_size"]))
    try:
        h = sha256(dst)
    except OSError as e:
        return "the target copy cannot be read (%s)" % e
    if h != f["dst_sha256"]:
        return "the target copy is no longer identical to the verified content"
    return None


def sha_tool():
    """(name, plain command, check command) of the checksum tool the script uses; raises
    Fail."""
    if shutil.which("sha256sum"):
        return "sha256sum", "sha256sum", "sha256sum -c --status"
    if shutil.which("shasum"):
        return "shasum", "shasum -a 256", "shasum -a 256 -c --status"
    raise Fail("neither sha256sum nor shasum is available - the cleanup script must verify "
               "checksums before removing anything, so no script is generated")


def cleanup_lines(source, target, pairs):
    lines = []
    for sess, man, files in pairs:
        sid = sess["id"]
        lines.append("")
        lines.append("# session %s \"%s\"" % (sid, safe_title(sess["title"])))
        for f in files:
            check_deletable(source, f["path"], sid)
            dst = os.path.join(target, os.path.relpath(f["path"], source))
            pdir = os.path.dirname(f["path"])
            rdir = os.path.realpath(pdir)
            tdir = os.path.dirname(dst)
            rtdir = os.path.realpath(tdir)
            for x in (dst, rdir, rtdir):
                check_literal(x)
            n = f["dst_size"]
            p, t = sq(f["path"]), sq(dst)
            # Every check below is re-done when the script runs: source and target are
            # regular files, not symlinks, not the same file, both directories still
            # resolve to the recorded physical directories, the source still has its
            # verified checksum and the target still starts with the verified content
            # (at least dst_size bytes whose first dst_size bytes hash to dst_sha256) for
            # the append-only transcript; EXACTLY dst_size bytes with sha256 dst_sha256
            # for every other file.
            if is_transcript(os.path.relpath(f["path"], source), sid):
                tgt_conds = [
                    "head -c %d %s | wc -c | grep -qxE '[ ]*%d'" % (n, t, n),
                    "head -c %d %s | csm_sum | grep -qxF '%s  -'" % (n, t, f["dst_sha256"]),
                ]
            else:
                tgt_conds = [
                    "wc -c < %s | grep -qxE '[ ]*%d'" % (t, n),
                    "printf '%%s  %%s\\n' '%s' %s | csm_sum_ok" % (f["dst_sha256"], t),
                ]
            conds = [
                "[ -f %s ]" % p, "[ ! -L %s ]" % p,
                "[ -f %s ]" % t, "[ ! -L %s ]" % t,
                "[ ! %s -ef %s ]" % (p, t),
                "( cd %s 2>/dev/null && pwd -P ) | grep -qxF %s" % (sq(pdir), sq(rdir)),
                "( cd %s 2>/dev/null && pwd -P ) | grep -qxF %s" % (sq(tdir), sq(rtdir)),
                "printf '%%s  %%s\\n' '%s' %s | csm_sum_ok" % (f["sha256"], p),
            ] + tgt_conds
            lines.append(
                "if %s; then if rm -f -- %s; then csm_removed=$((csm_removed + 1)); "
                "else echo %s >&2; csm_kept=$((csm_kept + 1)); fi; "
                "else echo %s >&2; csm_kept=$((csm_kept + 1)); fi" % (
                    " && ".join(conds), p,
                    sq("kept (rm failed): " + f["path"]),
                    sq("kept (changed, missing, a symlink, moved directory or no intact "
                       "target copy): " + f["path"])))
        for d in sorted(man["dirs"], key=lambda x: x.count(os.sep), reverse=True):
            check_deletable(source, d, sid)
            parent = os.path.dirname(d)
            rparent = os.path.realpath(parent)
            check_literal(rparent)
            lines.append(
                "if ( cd %s 2>/dev/null && pwd -P ) | grep -qxF %s; then "
                "if rmdir -- %s 2>/dev/null; then csm_removed=$((csm_removed + 1)); "
                "else echo %s >&2; csm_kept=$((csm_kept + 1)); fi; "
                "else echo %s >&2; csm_kept=$((csm_kept + 1)); fi" % (
                    sq(parent), sq(rparent), sq(d),
                    sq("kept directory (not empty or missing): " + d),
                    sq("kept directory (its parent moved): " + d)))
    return lines


def write_script(path, text):
    """Write the cleanup script to a temp name next to it (O_EXCL, 0600, fsynced), then
    rename it into place. On failure only that own temp file is removed (same inode) and
    the directory is reported, never removed. Returns path."""
    d = os.path.dirname(path)
    tmp = os.path.join(d, ".cleanup.sh.tmp")
    check_text("cleanup script path", path)
    own = None
    try:
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        own = os.fstat(fd)
        with os.fdopen(fd, "w") as fh:
            fh.write(text)
            fh.flush()
            os.fsync(fh.fileno())
        os.rename(tmp, path)
    except (OSError, ValueError) as e:  # ValueError: UnicodeEncodeError (unencodable text)
        if own is not None:
            try:
                cur = os.lstat(tmp)
                if (cur.st_dev, cur.st_ino) == (own.st_dev, own.st_ino):
                    os.unlink(tmp)
            except OSError:
                pass
        raise Fail("could not write the cleanup script (%s); no script was produced. The "
                   "directory %s was left in place (no script in it) - remove it yourself "
                   "when you do not need it" % (e, d))
    return path


def make_cleanup(source, target, plan):
    tool, plain_cmd, check_cmd = sha_tool()
    base = os.environ.get("CREDO_SESSION_MOVE_TMPDIR") or "/tmp"
    check_text("CREDO_SESSION_MOVE_TMPDIR", base)
    pairs, problems, kept = [], [], []
    for s in plan["sessions"]:
        try:
            man = load_manifest(target, s["id"])
        except Fail as e:
            problems.append(str(e))
            continue
        msrc, mtgt = man.get("source"), man.get("target")
        if not isinstance(msrc, str) or not msrc or not isinstance(mtgt, str) or not mtgt \
                or real(msrc) != real(source) or real(mtgt) != real(target):
            problems.append("manifest of %s was made for other profiles" % s["id"])
            continue
        # every manifest item must still be a planned, non-shared item of THIS session
        allowed = {it["rel"] for it in s["items"]
                   if it["action"] in ("copy", "present", "conflict")}
        stray = [r for r in man["items"] if r not in allowed]
        if stray:
            problems.append("%s: manifest item(s) not in the fresh plan of this session (or "
                            "now shared / blocked): %s" % (s["id"], ", ".join(stray)))
            continue
        outside = [f["path"] for f in man["files"] if not under_items(source, f["path"], man["items"])] \
            + [d for d in man["dirs"] if not under_items(source, d, man["items"])]
        if outside:
            problems.append("%s: manifest paths outside its items: %s" % (
                s["id"], ", ".join(outside[:5])))
            continue
        # the source must be exactly what was verified
        now = {}
        for rel in man["items"]:
            p = os.path.join(source, rel)
            if not os.path.lexists(p):
                problems.append("%s: gone from the source since the verify" % rel)
                continue
            if os.path.isdir(p) and not os.path.islink(p):
                _, f, bad = tree(p)
                if bad:
                    problems.append("%s: now contains %s" % (rel, ", ".join(bad[:3])))
                for r, size in f:
                    now[os.path.join(p, r)] = size
            else:
                now[p] = os.path.getsize(p)
        recorded = {f["path"]: f for f in man["files"]}
        for p in sorted(set(now) | set(recorded)):
            rel = os.path.relpath(p, source)
            if p not in recorded:
                problems.append("%s: new in the source since the verify" % rel)
            elif p not in now:
                problems.append("%s: gone from the source since the verify" % rel)
            elif now[p] != recorded[p]["size"] or sha256(p) != recorded[p]["sha256"]:
                problems.append("%s: changed in the source since the verify" % rel)
        # a source file goes into the script only while its target copy is intact
        files = []
        for f in man["files"]:
            why = target_problem(source, target, f, s["id"])
            if why:
                kept.append({"session": s["id"], "path": f["path"], "reason": why})
            else:
                files.append(f)
        pairs.append((s, man, files))
    if problems:
        raise Fail("; ".join(problems))
    lines = cleanup_lines(source, target, pairs)
    d = tempfile.mkdtemp(prefix="credo-session-move-", dir=base)
    os.chmod(d, 0o700)
    path = os.path.join(d, "cleanup.sh")
    check_text("cleanup script path", path)
    head = [
        "#!/bin/sh",
        "# credo session-move cleanup: removes the SOURCE copies of the moved session(s).",
        "# Run it yourself, only after the resume in the target profile works:",
        "#   sh %s" % sq(path),
        "# Source profile: %s" % sq(source),
        "# Target profile: %s" % sq(target),
        "# A file is removed only while it is a regular file (not a symlink) with the",
        "# checksum recorded by the verify, its target copy is a different regular file",
        "# that is still intact and both directories still resolve to the recorded",
        "# physical directories. Intact means: exactly the verified size and sha256 for",
        "# every file except the session transcript (projects/<slug>/<id>.jsonl), which",
        "# may have grown but must still start with the verified content. A directory",
        "# is removed only with rmdir (when",
        "# empty). Items shared with the target through a symlink are not listed; source",
        "# files whose target copy changed or vanished before the script was written are",
        "# not listed, they count as kept. At the end it prints how many items were",
        "# removed and kept and exits 1 when anything was kept.",
        "set -u",
        "command -v %s >/dev/null 2>&1 || { echo 'credo session-move cleanup: %s not "
        "found - nothing removed' >&2; exit 1; }" % (tool, tool),
        "csm_sum() { %s; }" % plain_cmd,
        "csm_sum_ok() { %s >/dev/null 2>&1; }" % check_cmd,
        "csm_removed=0",
        "csm_kept=%d" % len(kept),
    ]
    tail = [
        "",
        "echo \"credo session-move cleanup finished: removed $csm_removed, kept $csm_kept.\"",
        "if [ \"$csm_kept\" -ne 0 ]; then",
        "  echo 'credo session-move cleanup: some items were kept (see above); nothing "
        "else was touched.' >&2",
        "  exit 1",
        "fi",
        "exit 0",
        "",
    ]
    write_script(path, "\n".join(head + lines + tail))
    nfiles = sum(len(x[2]) for x in pairs)
    ndirs = sum(len(x[1]["dirs"]) for x in pairs)
    return path, d, nfiles, ndirs, kept


# --- output ------------------------------------------------------------------------

def resume_cmd(sess, target):
    return "cd %s && CLAUDE_CONFIG_DIR=%s claude --resume %s" % (
        sq(sess["cwd"]) if sess["cwd"] else "<cwd>", sq(target), sess["id"])


def print_plan(plan, header):
    print(header)
    print("source: %s" % plan["source"])
    print("target: %s" % plan["target"])
    lay = plan["target_layout"]
    if lay["symlinks"]:
        print("target layout: shared via symlink:")
        for n, v in sorted(lay["symlinks"].items()):
            print("  %s -> %s%s" % (n, v["link"], " (into the source)" if v["into_source"] else ""))
    else:
        print("target layout: no top-level symlinks (fully separate profile)")
    if lay["real"]:
        print("target real entries: %s" % ", ".join(lay["real"]))
    for e in plan["errors"]:
        print("ERROR: %s" % e)
    for w in plan["warnings"]:
        print("WARNING: %s" % w)
    for s in plan["sessions"]:
        print("")
        print('session %s  title "%s"  slug %s' % (s["id"], " / ".join(s["titles"]), s["slug"]))
        print("  cwd: %s" % (s["cwd"] or "?"))
        for it in s["items"]:
            size = "%s, %d files, %d bytes" % (it["kind"], it["files"], it["bytes"])
            print("  %-8s %s  (%s)%s" % (it["action"].upper(), it["src"], size,
                                         ("  " + it["reason"]) if it["reason"] else ""))
            if it["action"] in ("copy", "present"):
                print("           -> %s" % it["dst"])
        for r in s["review"]:
            print("  REVIEW   %s  (name carries only the short id; not copied, check by hand)"
                  % os.path.join(plan["source"], r))
        for h in s["live"]:
            print("  LIVE     pid %d (%s, profile %s)" % (h["pid"], h["how"], h["profile"] or "unknown"))
        for r in s["refusals"]:
            print("  REFUSED: %s" % r)
        print("  resume after the move: %s" % resume_cmd(s, plan["target"]))
    print("")


def emit(data, as_json, printer):
    if as_json:
        print(json.dumps(data, indent=1))
    else:
        printer(scrub(data))  # nothing from the profile reaches the terminal raw


def cmd_plan(args):
    plan = build_plan(args.source, args.target, args.sessions, args.profile)
    plan["command"] = "plan"

    def pr(p):
        print_plan(p, "credo session-move plan (dry run, nothing changed)")
        print("result: %s" % ("OK - ready to copy" if p["ok"] else "REFUSED - nothing will be copied"))
    emit(plan, args.json, pr)
    return 0 if plan["ok"] else 1


def print_verify(v):
    for c in v["checked"]:
        print("  %-8s %s  (%s, %d files, %d entries, %d bytes)" % (
            "OK" if c["ok"] else "MISMATCH", c["rel"], c["kind"], c["files"], c["entries"],
            c["bytes"]))
    for m in v["mismatches"]:
        print("  MISMATCH: %s" % m)
    for r in v.get("refusals", []):
        print("  REFUSED (no manifest): %s" % r)
    for m in v["manifests"]:
        print("  manifest: %s" % m)
    print("verify: %s" % ("OK" if v["ok"] else "FAILED"))


def cmd_copy(args):
    plan = build_plan(args.source, args.target, args.sessions, args.profile)
    plan["command"] = "copy"
    if not plan["ok"]:
        def pr(p):
            print_plan(p, "credo session-move copy: REFUSED, nothing copied")
            print("result: REFUSED - nothing copied")
        emit(plan, args.json, pr)
        return 1
    copied, error = [], None
    try:
        for s in plan["sessions"]:
            for it in s["items"]:
                if it["action"] == "copy":
                    copy_item(args.source, args.target, it)
                    it["copied"] = True
                    copied.append(it["dst"])
    except (Fail, OSError) as e:
        error = ("copy stopped: %s (complete files copied so far stay; fix the cause and run "
                 "copy again - identical files are skipped)" % e)
    plan["copied"] = copied
    if error:
        plan["ok"] = False
        plan["errors"].append(error)
    else:
        plan["verify"] = run_verify(args.source, args.target, plan)
        plan["ok"] = plan["verify"]["ok"]

    def pr(p):
        print_plan(p, "credo session-move copy")
        print("copied %d item(s)" % len(p["copied"]))
        if "verify" in p:
            print_verify(p["verify"])
        print("result: %s" % ("OK - copied and verified; now test the resume in the target"
                              if p["ok"] else "FAILED"))
    emit(plan, args.json, pr)
    return 0 if plan["ok"] else 1


def cmd_verify(args):
    plan = build_plan(args.source, args.target, args.sessions, args.profile)
    v = run_verify(args.source, args.target, plan)
    v["ok"] = v["ok"] and plan["ok"]
    out = dict(v, command="verify", errors=plan["errors"],
               sessions=[{"id": s["id"], "title": s["title"], "cwd": s["cwd"],
                          "resume": resume_cmd(s, args.target)} for s in plan["sessions"]])

    def pr(d):
        print("credo session-move verify")
        for e in d["errors"]:
            print("ERROR: %s" % e)
        print_verify(d)
    emit(out, args.json, pr)
    return 0 if out["ok"] else 1


def cmd_cleanup(args):
    if not args.user_confirmed:
        print("cleanup-script needs --user-confirmed: pass it only after the user tested the "
              "resume in the target profile and explicitly approved removing the source copies",
              file=sys.stderr)
        return 1
    plan = build_plan(args.source, args.target, args.sessions, args.profile)
    problems = list(plan["errors"])
    current = os.environ.get("CLAUDE_CODE_SESSION_ID", "")
    for s in plan["sessions"]:
        if s["id"] == current:
            problems.append("%s is the current session" % s["id"])
        if s.get("liveness_error"):
            problems.append(s["liveness_error"])
        for h in s["live"]:
            if h["profile"] is None or real(h["profile"]) != real(args.target):
                problems.append("session %s is live outside the target profile: pid %d (%s, "
                                "profile %s)" % (s["id"], h["pid"], h["how"],
                                                 h["profile"] or "unknown"))
    out = {"command": "cleanup-script", "ok": False, "errors": problems, "kept": []}
    if not problems:
        try:
            path, d, nfiles, ndirs, kept = make_cleanup(args.source, args.target, plan)
            out.update(ok=True, script=path, script_dir=d, files=nfiles, dirs=ndirs, kept=kept,
                       run="sh %s" % sq(path),
                       remove="rm -f -- %s && rmdir -- %s" % (sq(path), sq(d)))
        except (Fail, ValueError, OSError) as e:
            out["errors"].append(str(e))

    def pr(o):
        print("credo session-move cleanup-script")
        for e in o["errors"]:
            print("REFUSED: %s" % e)
        for k in o["kept"]:
            print("KEPT (not in the script): %s - %s" % (k["path"], k["reason"]))
        if o["ok"]:
            print("script: %s  (%d file(s), %d dir(s))" % (o["script"], o["files"], o["dirs"]))
            print("the user runs it:  ! %s" % o["run"])
            print("remove the script afterwards (optional):  ! %s" % o["remove"])
    emit(out, args.json, pr)
    return 0 if out["ok"] else 1


def main(argv=None):
    ap = argparse.ArgumentParser(description="Move Claude Code sessions between profiles "
                                 "(plan / copy / verify / cleanup-script). Never deletes "
                                 "session data.")
    sub = ap.add_subparsers(dest="cmd")
    for name in ("plan", "copy", "verify", "cleanup-script"):
        p = sub.add_parser(name)
        p.add_argument("--source", required=True, help="source profile dir (e.g. ~/.claude)")
        p.add_argument("--target", required=True, help="target profile dir (e.g. ~/.claude-other)")
        p.add_argument("sessions", nargs="+", help="caption / custom title or full session id")
        p.add_argument("--profile", action="append", default=[], metavar="DIR",
                       help="extra profile dir to include in the liveness scan (repeatable); "
                       "other CLAUDE_CONFIG_DIR locations and Windows-side sessions are not "
                       "seen unless passed here")
        p.add_argument("--json", action="store_true", help="machine-readable output")
        if name == "cleanup-script":
            p.add_argument("--user-confirmed", action="store_true",
                           help="the user tested the resume and approved the cleanup")
    args = ap.parse_args(argv)
    if not args.cmd:
        ap.print_help()
        return 2
    try:
        check_text("--source", args.source)
        check_text("--target", args.target)
        args.source = os.path.abspath(os.path.expanduser(args.source))
        args.target = os.path.abspath(os.path.expanduser(args.target))
        extra = []
        for p in args.profile:
            check_text("--profile", p)
            p = os.path.abspath(os.path.expanduser(p))
            if not os.path.isdir(p):
                raise Fail("--profile %s does not exist or is not a directory" % p)
            extra.append(p)
        args.profile = extra
        return {"plan": cmd_plan, "copy": cmd_copy, "verify": cmd_verify,
                "cleanup-script": cmd_cleanup}[args.cmd](args)
    except (Fail, OSError, ValueError) as e:  # fail closed, never a half-printed plan
        print(show("credo session-move %s: ERROR: %s" % (args.cmd, e)), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
