"""credo_session_name.py - the one fallback order for every peer / session name credo shows.

    caption -> kitty label -> tmux label -> short session id

caption       a USER-SET name only
              Claude: the session registry field "name", only when "nameSource" is "user"
                      (the cwd-based "derived" name never counts)
              Codex:  the newest row of $CODEX_HOME/session_index.jsonl for the thread id
                      (unnamed threads have no row)
kitty label   the title of the kitty tab that holds the session's terminal window
tmux label    the tmux session name of the pane the session runs in
short id      sid_short(): first character of each id group plus the id's last character

For a session that Claude Code moved into its background daemon the agent has no tmux
or kitty ancestry of its own; the labels then come from its client TUI (credo-self-restart.py
daemon_link, which verifies the link and fails closed).

Every name, whichever step it comes from, is sanitized (NFC, whitespace collapsed, only
letters, digits, space and . _ - kept) and capped at NAME_MAX (20) characters. The shown
name is display text only: it never grants trust and is never used for routing. The one
exception is the CAPTION itself: claude_caption() is also what the LAN relay sends as the
trust key from_caption (see credo-peer-lan.py, trusted peers); kitty / tmux labels and
short ids never take part in trust.

Process facts come from PROC_ROOT (a module attribute, only tests point it elsewhere).
"""
import glob
import importlib.util
import json
import os
import re
import stat
import subprocess
import time
import unicodedata

NAME_MAX = 20        # cap of every name: caption, kitty label, tmux label
NAME_PUNCT = " ._-"  # the only non-alphanumeric characters a name keeps
LABEL_MAX = NAME_MAX
INDEX_TAIL = 256 * 1024
PROC_ROOT = "/proc"
KITTY_GLOBS = ("/tmp/mykitty-*", "/tmp/mykitty")
# prefixes the signal plugin puts in front of a kitty tab title
_TAB_PREFIX_RE = re.compile(r"^(?:\[(?:AI\.\.\.|ASK|FIN)\]\s*)+", re.I)
_KITTY_CACHE = {}    # (binary, address) -> (monotonic time, tabs)
_TMUX_CACHE = {}     # (binary, "panes" | "clients") -> (monotonic time, data)
_MODULES = {}        # lazily loaded credo-self-restart.py


def _name_char(ch):
    """Letters (any script), decimal digits and space . _ - are name characters."""
    cat = unicodedata.category(ch)
    return cat[0] == "L" or cat == "Nd" or ch in NAME_PUNCT


def _clean_once(text, limit):
    out = []
    for ch in unicodedata.normalize("NFC", text):
        if ch.isspace():
            out.append(" ")
        elif _name_char(ch):
            out.append(ch)
    # NFC again: a removed character can leave decomposed parts side by side (e.g.
    # Hangul jamo around a zero-width space) that only now compose
    joined = unicodedata.normalize("NFC", " ".join("".join(out).split()))
    return joined[:limit].rstrip()


def clean(text, limit):
    """Display-safe name: NFC-normalized, whitespace collapsed, only letters, digits,
    space and . _ - kept (control, format, symbol, quote, bracket, emoji ... removed),
    cut to `limit` characters, NFC again after filtering. Idempotent:
    clean(clean(x)) == clean(x). "" for anything that is not text."""
    if not isinstance(text, str):
        return ""
    out = _clean_once(text, limit)
    for _ in range(3):   # converges at once in practice; bounded for safety
        again = _clean_once(out, limit)
        if again == out:
            break
        out = again
    return out


def is_caption(text):
    """True when text is exactly a clean name of 1..NAME_MAX characters (what the
    trust list and a from_caption must look like; never cleaned into shape)."""
    return isinstance(text, str) and bool(text) and clean(text, NAME_MAX) == text


def caption_key(text):
    """Comparison key for the duplicate-caption check (case-insensitive)."""
    return clean(text, NAME_MAX).casefold()


# Latin lookalikes from other scripts (Cyrillic, Greek, Armenian, Cherokee) and a few
# Latin-extended letters that render like plain ASCII. Only used for a WARNING when
# the user grants or lists trust; nothing is ever rejected because of it.
_LATIN_LOOKALIKES = frozenset(
    "\u0430\u0432\u0435\u043a\u043c\u043d\u043e\u0440\u0441\u0442\u0443\u0445"
    "\u0455\u0456\u0458\u04bb\u04cf\u0501\u051b\u051d"
    "\u0410\u0412\u0415\u041a\u041c\u041d\u041e\u0420\u0421\u0422\u0423\u0425"
    "\u0405\u0406\u0408\u04ae\u04c0\u050c\u051a\u051c"
    "\u03b1\u03b9\u03ba\u03bd\u03bf\u03c1\u03c4\u03c5\u03c7"
    "\u0391\u0392\u0395\u0396\u0397\u0399\u039a\u039c\u039d\u039f\u03a1\u03a4"
    "\u03a5\u03a7"
    "\u0570\u0578\u057d\u0585\u0581"
    "\u13a0\u13a1\u13a2\u13a5\u13a9\u13aa\u13ab\u13b3\u13b7\u13bb\u13bc\u13c0"
    "\u13c2\u13c3\u13c4\u13cf\u13d2\u13da\u13de\u13df\u13e2\u13f4"
    "\u0131\u0237\u0251\u0261\u0269\u026a\u0274\u0280\u028f\u1d00\u1d04\u1d05"
    "\u1d07\u1d0a\u1d0b\u1d0d\u1d0f\u1d18\u1d1b\u1d1c\u1d20\u1d21\u1d22")


def confusables(text):
    """Characters of text that can be mistaken for plain Latin letters, as
    "U+XXXX NAME (why)" strings: lookalikes from other scripts (Cyrillic, Greek, ...)
    and characters that NFKC folds to something else (fullwidth letters, ligatures,
    letter-like compatibility forms). Accented Latin letters (a with umlaut, e with
    acute) and scripts without Latin lookalikes (CJK, ...) are not listed. [] for
    anything that is not text."""
    if not isinstance(text, str):
        return []
    out = []
    for ch in text:
        why = ""
        if ch in _LATIN_LOOKALIKES:
            why = "looks like a Latin letter"
        elif unicodedata.normalize("NFKC", ch) != ch:
            why = "changes under NFKC to %r" % unicodedata.normalize("NFKC", ch)
        if why:
            item = "U+%04X %s (%s)" % (ord(ch), unicodedata.name(ch, "?"), why)
            if item not in out:
                out.append(item)
    return out


def confusable_warning(caption):
    """One WARNING line for a caption with confusable characters, else ""."""
    found = confusables(caption)
    if not found:
        return ""
    return ("WARNING: caption %r contains characters that look like plain Latin letters "
            "but are not: %s. A session on that machine could show a name that looks "
            "the same with different characters; check that this is exactly the caption "
            "you mean (warning only, nothing was rejected)." % (caption, "; ".join(found)))


def sid_short(sid):
    """First char of each dash group joined by "-", plus the last char of the id:
    a1b2c3d4-e5f6-... -> a-e-4-8-d8. Keeps two sessions of the same name apart."""
    sid = sid if isinstance(sid, str) and sid else "?"
    return "-".join(g[:1] for g in sid.split("-") if g) + sid[-1:]


def pick(caption=None, kitty=None, tmux=None, sid=None):
    """The first non-blank of caption, kitty label, tmux label; else sid_short(sid)."""
    for value, cap in ((caption, NAME_MAX), (kitty, LABEL_MAX), (tmux, LABEL_MAX)):
        text = clean(value, cap)
        if text:
            return text
    return sid_short(sid)


# --------------------------------------------------------------------------- files

class UnsafeFile(ValueError):
    """open_own_file refused a file: not a regular file, foreign owner, or (private)
    writable by group or others."""


def open_own_file(path, uid=None, private=False):
    """Read-only fd of path: opened without following a symlink and without blocking
    (O_NOFOLLOW | O_NONBLOCK, so a FIFO cannot hang the caller), then checked to be a
    regular file owned by uid (default: the effective uid) and, with private, not
    writable by group or others. Raises OSError from open (FileNotFoundError when
    missing) or UnsafeFile when a check fails; the caller closes the fd."""
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0))
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode):
            raise UnsafeFile("not a regular file")
        if info.st_uid != (os.geteuid() if uid is None else uid):
            raise UnsafeFile("owned by uid %d, not by this user" % info.st_uid)
        if private and info.st_mode & 0o022:
            raise UnsafeFile("writable by group or others (mode %o)" % stat.S_IMODE(info.st_mode))
    except BaseException:
        os.close(fd)
        raise
    return fd


# --------------------------------------------------------------------------- caption

def claude_caption(desc):
    """The user-set name of a Claude session descriptor, else None. Only
    nameSource == "user" counts: derived names and relay mirror names do not."""
    if not isinstance(desc, dict) or desc.get("nameSource") != "user":
        return None
    return clean(desc.get("name"), NAME_MAX) or None


def codex_caption(thread_id, codex_home=None, uid=None):
    """thread_name of the newest session_index.jsonl row whose id is thread_id, else
    None. The file is opened without following a symlink, must be a regular file owned
    by the current user, and only its last INDEX_TAIL bytes are scanned (backwards)."""
    if not isinstance(thread_id, str) or not thread_id:
        return None
    home = codex_home or os.environ.get("CODEX_HOME") or os.path.join(
        os.path.expanduser("~"), ".codex")
    path = os.path.join(home, "session_index.jsonl")
    try:
        fd = open_own_file(path, uid)
    except (OSError, UnsafeFile):
        return None
    try:
        info = os.fstat(fd)
        start = max(0, info.st_size - INDEX_TAIL)
        os.lseek(fd, start, os.SEEK_SET)
        chunks, left = [], info.st_size - start
        while left > 0:
            part = os.read(fd, min(left, 65536))
            if not part:
                break
            chunks.append(part)
            left -= len(part)
    except OSError:
        return None
    finally:
        os.close(fd)
    raw = b"".join(chunks)
    if start > 0:
        raw = raw.partition(b"\n")[2]   # the first line is cut by the window
    for line in reversed(raw.decode("utf-8", "replace").splitlines()):
        if thread_id not in line:
            continue
        try:
            row = json.loads(line)
        except ValueError:
            continue
        if isinstance(row, dict) and row.get("id") == thread_id:
            return clean(row.get("thread_name"), NAME_MAX) or None
    return None


# --------------------------------------------------------------------------- processes

def _ppid(pid):
    try:
        with open("%s/%d/stat" % (PROC_ROOT, pid)) as fh:
            return int(fh.read().rsplit(")", 1)[-1].split()[1])
    except (OSError, ValueError, IndexError):
        return 0


def ancestors(pid, limit=64):
    """[pid, parent, grandparent, ...] below pid 1."""
    out = []
    while isinstance(pid, int) and not isinstance(pid, bool) and pid > 1 \
            and pid not in out and len(out) < limit:
        out.append(pid)
        pid = _ppid(pid)
    return out


def _is_kitty(pid):
    try:
        with open("%s/%d/comm" % (PROC_ROOT, pid)) as fh:
            if fh.read().strip() == "kitty":
                return True
    except OSError:
        pass
    try:
        return os.path.basename(os.readlink("%s/%d/exe" % (PROC_ROOT, pid))) == "kitty"
    except OSError:
        return False


def _kitty_window_pid(chain):
    """The chain member whose parent is kitty (the window's own process), else None."""
    for child, parent in zip(chain, chain[1:]):
        if _is_kitty(parent):
            return child
    return None


def _environ_value(pid, key):
    try:
        with open("%s/%d/environ" % (PROC_ROOT, pid), "rb") as fh:
            for item in fh.read().split(b"\0"):
                k, sep, v = item.partition(b"=")
                if sep and k == key.encode():
                    return v.decode("utf-8", "replace")
    except OSError:
        pass
    return None


def _daemon_client(pid):
    """Client TUI pid of a daemon-hosted session (credo-self-restart.py daemon_link,
    which verifies the link), else None. Any problem -> None."""
    try:
        if "restart" not in _MODULES:
            path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "credo-self-restart.py")
            spec = importlib.util.spec_from_file_location("credo_self_restart", path)
            mod = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(mod)
            _MODULES["restart"] = mod
        link = _MODULES["restart"].daemon_link(pid)
        if link.get("daemon") and not link.get("error"):
            return link.get("client")
    except Exception:
        pass
    return None


def _run(argv, timeout=3):
    try:
        r = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.SubprocessError):
        return ""
    return r.stdout if r.returncode == 0 else ""


# --------------------------------------------------------------------------- labels

class Snapshot:
    """Lazy, per-use view of tmux panes / clients and kitty tabs, so that many sessions
    cost one tmux and at most one kitty call. Create one per roster / listing.

    tmux_bin     tmux binary; None disables tmux labels
    panes        optional [(session, [pane pids], ...)] the caller already listed
    kitty_bin    kitty binary (default env CREDO_KITTY_BIN or "kitty")
    kitty_socket remote-control address (default: env CREDO_KITTY_SOCKET, KITTY_LISTEN_ON
                 of the window or of this process, then kitty_glob sockets owned by us)
    kitty_ttl    seconds a `kitty @ ls` answer is reused across snapshots (0 = never)
    kitty_budget total seconds this snapshot may spend in `kitty @ ls` calls; when it is
                 used up the remaining addresses are skipped (no label, nothing cached)
    pane_ttl     seconds the tmux pane / client lists are reused across snapshots (0 = never);
                 a roster tick makes a new Snapshot every few seconds. Panes handed in by
                 the caller are never cached
    client_of    pid -> client TUI pid of a daemon-hosted session (default daemon_link)
    """

    def __init__(self, tmux_bin="tmux", panes=None, kitty_bin=None, kitty_socket=None,
                 kitty_glob=KITTY_GLOBS, kitty_ttl=15, client_of=None, pane_ttl=15,
                 kitty_budget=2.0):
        self.tmux_bin = tmux_bin
        self._panes = panes
        self.kitty_bin = kitty_bin or os.environ.get("CREDO_KITTY_BIN") or "kitty"
        self.kitty_socket = kitty_socket or os.environ.get("CREDO_KITTY_SOCKET") or ""
        self.kitty_glob = kitty_glob
        self.kitty_ttl = kitty_ttl
        self.kitty_budget = kitty_budget
        self._kitty_spent = 0.0
        self.pane_ttl = pane_ttl
        self.client_of = client_of or _daemon_client
        self._pane_map_cache = None
        self._clients_cache = None
        self._clients_of = {}
        self._tabs = {}

    # tmux
    def _tmux_cached(self, kind, fetch):
        """fetch() result, reused across snapshots for pane_ttl seconds."""
        key = (self.tmux_bin, kind)
        hit = _TMUX_CACHE.get(key)
        if self.pane_ttl > 0 and hit and time.monotonic() - hit[0] < self.pane_ttl:
            return hit[1]
        data = fetch()
        if self.pane_ttl > 0:
            _TMUX_CACHE[key] = (time.monotonic(), data)
        return data

    def _list_panes(self):
        rows = []
        if self.tmux_bin:
            for line in _run([self.tmux_bin, "list-panes", "-a", "-F",
                              "#{session_name}\t#{pane_pid}"]).splitlines():
                sess, _, pid = line.rpartition("\t")
                if pid.isdigit():
                    rows.append((sess, [int(pid)]))
        return rows

    def _list_clients(self):
        out = {}
        if self.tmux_bin:
            for line in _run([self.tmux_bin, "list-clients", "-F",
                              "#{client_session}\t#{client_pid}"]).splitlines():
                sess, _, pid = line.rpartition("\t")
                if pid.isdigit():
                    out.setdefault(sess, []).append(int(pid))
        return out

    def _pane_map(self):
        if self._pane_map_cache is None:
            rows = self._panes if self._panes is not None else \
                self._tmux_cached("panes", self._list_panes)
            self._pane_map_cache = {p: row[0] for row in rows for p in row[1]}
        return self._pane_map_cache

    def _clients(self):
        if self._clients_cache is None:
            self._clients_cache = self._tmux_cached("clients", self._list_clients)
        return self._clients_cache

    def _client_chain(self, pid):
        if pid not in self._clients_of:
            try:
                client = self.client_of(pid)
            except Exception:
                client = None
            self._clients_of[pid] = ancestors(client) if isinstance(client, int) else []
        return self._clients_of[pid]

    def tmux_label(self, pid):
        """tmux session name of the pane the process runs in, else None. A
        daemon-hosted session is looked up through its client TUI."""
        panes = self._pane_map()
        if not panes:
            return None
        for p in ancestors(pid):
            if p in panes:
                return panes[p]
        for p in self._client_chain(pid):
            if p in panes:
                return panes[p]
        return None

    # kitty
    def _addresses(self, window_pid):
        found = [self.kitty_socket,
                 _environ_value(window_pid, "KITTY_LISTEN_ON") if window_pid else None,
                 os.environ.get("KITTY_LISTEN_ON")]
        for pattern in self.kitty_glob or ():
            for path in sorted(glob.glob(pattern)):
                try:
                    info = os.lstat(path)
                except OSError:
                    continue
                if stat.S_ISSOCK(info.st_mode) and info.st_uid == os.geteuid():
                    found.append("unix:" + path)
        seen = []
        for addr in found:
            if addr and addr not in seen:
                seen.append(addr)
        return seen

    def _tabs_at(self, addr):
        key = (self.kitty_bin, addr)
        if key in self._tabs:
            return self._tabs[key]
        hit = _KITTY_CACHE.get(key)
        if self.kitty_ttl > 0 and hit and time.monotonic() - hit[0] < self.kitty_ttl:
            self._tabs[key] = hit[1]
            return hit[1]
        left = self.kitty_budget - self._kitty_spent
        if left < 0.05:
            return []   # budget used up: skip, and do not cache the skip
        tabs = []
        started = time.monotonic()
        try:
            data = json.loads(_run([self.kitty_bin, "@", "--to", addr, "ls"],
                                   timeout=min(2, left)) or "[]")
            for os_win in data if isinstance(data, list) else []:
                for tab in os_win.get("tabs", []) if isinstance(os_win, dict) else []:
                    wins = [w.get("pid") for w in tab.get("windows", []) if isinstance(w, dict)]
                    tabs.append((tab.get("title"), wins))
        except (ValueError, AttributeError, TypeError):
            tabs = []
        self._kitty_spent += time.monotonic() - started
        self._tabs[key] = tabs
        if self.kitty_ttl > 0:
            _KITTY_CACHE[key] = (time.monotonic(), tabs)
        return tabs

    def _tab_title(self, window_pid):
        for addr in self._addresses(window_pid):
            for title, wins in self._tabs_at(addr):
                if window_pid in wins:
                    return clean(_TAB_PREFIX_RE.sub("", title or ""), LABEL_MAX) or None
        return None

    def kitty_label(self, pid, tmux_session=None):
        """Title of the kitty tab holding the session's window, else None. Found through
        the process chain of pid (and of its client TUI when daemon-hosted), and for a
        tmux session through the tmux clients attached to it."""
        chains = []
        if pid:
            chains.append(ancestors(pid))
            chains.append(self._client_chain(pid))
        for client in self._clients().get(tmux_session, []) if tmux_session else []:
            chains.append(ancestors(client))
        for chain in chains:
            window = _kitty_window_pid(chain)
            if window is not None:
                title = self._tab_title(window)
                if title:
                    return title
        return None


# --------------------------------------------------------------------------- names

def claude_name(desc, snap=None, tmux=None, sid=None):
    """Name for a Claude session descriptor. `tmux` is a label the caller already
    resolved; without a Snapshot only caption and short id are available."""
    d = desc if isinstance(desc, dict) else {}
    sid = sid or d.get("sessionId")
    cap = claude_caption(d)
    if cap:
        return cap
    pid = d.get("pid") if isinstance(d.get("pid"), int) and not isinstance(d.get("pid"), bool) else None
    kitty = None
    if snap is not None:
        tmux = tmux or (snap.tmux_label(pid) if pid else None)
        kitty = snap.kitty_label(pid, tmux)
    return pick(None, kitty, tmux, sid)


def codex_name(thread_id, snap=None, tmux=None, codex_home=None):
    """Name for a Codex thread (fallback id: sid_short of the thread id)."""
    cap = codex_caption(thread_id, codex_home)
    if cap:
        return cap
    kitty = snap.kitty_label(None, tmux) if snap is not None and tmux else None
    return pick(None, kitty, tmux, thread_id)
