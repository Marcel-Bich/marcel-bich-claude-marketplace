"""credo_owner_type.py - deliver the owner's text, or an answer to an Ask box or a permission
prompt, into the owner's own Claude Code session pane (the tmux pane the session runs in).

A local connector (for example a phone app) runs credo-owner-type.py; this module does the
work. Every key or paste goes through the same checks:

  1. Target: the session must be live in the session registry (credo_session_registry:
     pid and start time, session descriptor, pane on its server, pane not dead, still owned
     by the session at record time). Stale, unknown or ambiguous sessions are refused.
  2. Authorization: the pane process must belong to this OS user, and the pane must still
     belong to the session right before every step (credo-self-restart pane_owner_error via
     registry.restart.session_owner_check). Copy or view mode is refused.
  3. Pane state (credo_pane_guard.classify_pane): an open Ask box, review page, permission
     prompt, slash menu, picker or unknown dialog is refused - nothing is typed into it. Dialogs
     are read from the capture with its scrollback (tmux capture-pane -S -N), so a box taller
     than the pane is read from its real top. A dialog whose top is not in view, or whose block
     holds an invisible or bidi (Unicode category Cf) character, is refused (dialog-does-not-fit,
     invisible-characters): the owner answers it at the PC.
  4. Answer binding: show prints the whole dialog block (every row from the box top rule to the
     footer, each prefixed with "| " so agent text cannot fake the end marker) and its digest:
     sha256 over those rows, whitespace normalized. Every answer needs --expect <digest>, and the
     prompt is read again before every key. The cursor, the checkbox and tab states, the typed text
     of the Type something row and the footer are not part of the digest.

Send (credo-owner-type.py send), simplified by owner decision Q56 and item 160:
  - normal mode: the input field must be empty. The whole text is loaded into a named tmux buffer
    and pasted into the pane in one bracketed paste (tmux paste-buffer -p, so a line break stays a
    line break inside one message). After a settle (0.5 s) the pane is checked up to 5 times, 0.5 s
    apart. A recognised dialog (Ask box, review page, permission prompt, menu or picker, a dialog
    that does not fit or holds invisible characters) on the last check holds back Enter; a pane stop
    (owner, copy mode, dead or missing pane) holds it at once. pane-changed, unknown-state and
    input-not-visible are retried; when the last check shows neither a recognised dialog nor a pane
    stop, Enter is sent. A held text is taken back out of the field only when the field was empty
    before and then shows exactly the text or one paste placeholder. No character-by-character or
    text confirmation: a paste placeholder ("[Pasted text #N ...]") or any other rendering of the
    field is accepted. The field is then checked once: empty again means delivered, else unconfirmed
    (exit 4).
  - force-append (--force-append): " " + text is pasted at the end of the existing text and Enter is
    sent. The field may hold a draft, which is never changed by this module; the cursor must be at its
    end. No digest is needed (--expect is accepted and not checked).
  - A busy session is fine: the text is queued by Claude Code (measured on Claude Code 2.1.316).

Answer (credo-owner-type.py answer): only when an Ask box or a permission prompt is open.
Ask box: a digit selects and sends; a label is mapped to its option (unique, case-insensitive;
options above 9 are reached with Down/Up, the highlight is read again right before the Enter or
Space, and only then the key is sent; a digit is never sent as text); "esc" declines;
"free:<text>" moves to the Type something row (Up/Down), types the text and sends it (the row must
be empty before; the highlight must stay on that row for every piece); "multi:<d,d>" toggles exactly
the boxes that differ from the wanted set, checks the checked set, presses Right (review page),
checks that the review page's first option is "Submit answers" and submits with Enter, bound to the
review page's own digest.
Permission prompt: a digit within the options, or esc. Only an option whose full label (the label
plus the rows under it) is exactly Yes or No (case-insensitive, trimmed) runs without --persist;
every other option needs --persist. Review page: digit 1 (Submit answers), only when every answer
row parsed and at least one answer was parsed. Anything else is refused.
A prompt that is answered and replaced by another prompt of the same kind is reported "answered"
(the digest changed), so a retry is not sent blindly; an identical prompt that comes back is
indistinguishable and reported "unconfirmed" (exit 4).

Every attempt is logged (one line each, see write_log): time, session id, mode, character
count, result, the chosen option label. The text is logged only with CREDO_OWNER_TYPE_LOG_TEXT=1.
If the log cannot be written (a FIFO, a symlink, a foreign or group-writable file), nothing is
typed.

Residual risks (documented, not closed): a dialog that opens between the last check and an Enter
can still receive that Enter (the window is one capture and one key press); a box whose top lies
beyond the scrollback window (500 rows, CREDO_OWNER_TYPE_SCROLLBACK_ROWS) is not readable and is
refused only when no row above the visible top is in view, so a crafted command with a fake box
structure inside a box taller than the window is not detected; the digest binds content, not the
session or the time (the connector binds each reply to both); the Enter after a paste is not
verified against the text (a placeholder hides it); the answer and send tools trust the OS user.

Timing overrides (tests and slow terminals): CREDO_OWNER_TYPE_SETTLE, CREDO_OWNER_TYPE_RECHECK,
CREDO_OWNER_TYPE_CONFIRM_WAIT, CREDO_OWNER_TYPE_KEY_PAUSE, CREDO_OWNER_TYPE_TYPE_PAUSE,
CREDO_OWNER_TYPE_SCROLLBACK_ROWS.

Python 3 stdlib only.
"""
import datetime
import hashlib
import json
import os
import re
import stat
import subprocess
import sys
import time
import unicodedata

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)
import credo_pane_guard as guard  # noqa: E402
import credo_pane_wake as wake  # noqa: E402
import credo_session_registry as registry  # noqa: E402

restart = registry.restart
LOG_NAME = "owner-type.log"
LINE_BREAK = "\\"
ENTER = "Enter"
MAX_TEXT_CHARS = 4000
DIGEST_RE = re.compile(r"[0-9a-f]{64}")
EXIT = {"delivered": 0, "answered": 0, "dry-run": 0, "shown": 0, "refused": 1, "failed": 1,
        "unconfirmed": 4, "unknown": 3, "ambiguous": 3, "usage": 2}
# A permission option runs without --persist only when its full label (the label plus the rows
# under it) is exactly one of these (case-insensitive, trimmed). Every other option, including
# "don't ask again" and any wording not listed, keeps approval for later prompts: --persist.
PLAIN_ANSWERS = ("yes", "no")
SUBMIT_LABEL = "Submit answers"
# A dialog whose block cannot be read whole from the visible pane (its top rule may have scrolled
# out of view) is refused by show and answer; it is answered at the PC.
NOT_FITTING = guard.REFUSAL_UNFIT
NOT_FITTING_TEXT = "dialog does not fit the pane, answer at the PC"
INVISIBLE = guard.REFUSAL_INVISIBLE
INVISIBLE_TEXT = "dialog contains invisible/bidi characters, answer at the PC"
CONFIRM_KEYS = ("Enter", "Space")
PASTE_BUFFER = "credo-owner-type"
SCROLLBACK_ENV = "CREDO_OWNER_TYPE_SCROLLBACK_ROWS"
# Checks of the pane after a paste (item 160, owner decision Q56): one after the settle time, then
# up to CHECKS_AFTER_PASTE - 1 more, timing()["recheck"] apart.
CHECKS_AFTER_PASTE = 5
# Pane stops hold back Enter at once and are never retried: the pane is not ours or cannot be used.
PANE_STOPS = ("owner", "owner-mismatch", "pane-missing", "pane-dead", "copy-mode")
DIALOG_KINDS = ("ask", "review", "permission", "dialog")
# A single paste placeholder in the input field (one BSpace removes it, measured on Claude Code).
PLACEHOLDER_RE = re.compile(r"\[Pasted text #\d+(?: \+\d+ lines)?\]")


class UsageError(ValueError):
    """The arguments are not a valid text or answer (nothing is looked up or typed)."""


class Refused(Exception):
    """A check failed before any key was sent. code is short and safe to log."""

    def __init__(self, code, message):
        Exception.__init__(self, message)
        self.code = code


class Abort(Exception):
    """A step failed after typing had begun. typed is what was sent so far."""

    def __init__(self, reason, typed):
        Exception.__init__(self, reason)
        self.reason = reason
        self.typed = typed


def norm(text):
    """Whitespace removed: the comparison used for the input field (row wraps and line breaks
    of the capture do not count)."""
    return "".join((text or "").split())


def canon(text):
    """Whitespace collapsed: the form used for digests."""
    return " ".join((text or "").split())


def norm_label(text):
    """Option label for matching: case-insensitive, single spaces, no "(Recommended)" tail."""
    s = re.sub(r"\s+", " ", (text or "").strip()).lower()
    return re.sub(r"\s*\(recommended\)$", "", s)


def needs_persist(full_label):
    """True for a permission option that needs --persist: anything whose full label (label plus
    the rows under it) is not exactly Yes or No (allow-list, see PLAIN_ANSWERS)."""
    return " ".join((full_label or "").split()).lower() not in PLAIN_ANSWERS


def _env_float(name, default):
    try:
        return float(os.environ.get(name, default))
    except (TypeError, ValueError):
        return float(default)


def timing():
    return {"type_pause": _env_float("CREDO_OWNER_TYPE_TYPE_PAUSE", wake.TYPE_PAUSE),
            "key_pause": _env_float("CREDO_OWNER_TYPE_KEY_PAUSE", 0.3),
            "settle": _env_float("CREDO_OWNER_TYPE_SETTLE", 0.5),
            "recheck": _env_float("CREDO_OWNER_TYPE_RECHECK", 0.5),
            "confirm_wait": _env_float("CREDO_OWNER_TYPE_CONFIRM_WAIT", 3.0)}


# --------------------------------------------------------------------------- text and keys

def _bad_char(ch):
    """Control characters (except the line break), C1 controls, U+2028/2029 line and paragraph
    separators, and every Unicode format character (category Cf: bidi overrides and isolates,
    zero-width and other invisible characters)."""
    if ch == "\n":
        return False
    return unicodedata.category(ch) in ("Cc", "Zl", "Zp", "Cf")


def validate_text(text):
    """None when the text may be typed, else the reason. Line breaks are allowed. Control,
    separator and bidi characters are not (Claude Code treats some as keys, others garble the
    display). A line that ends with a backslash is refused: Claude Code reads a backslash
    followed by Enter as a line break, so the final Enter would not send the message."""
    if not text or not text.strip():
        return "the text is empty"
    if len(text) > MAX_TEXT_CHARS:
        return "the text is longer than %d characters" % MAX_TEXT_CHARS
    if any(_bad_char(ch) for ch in text):
        return ("control, separator, bidi or invisible characters (category Cc, Zl, Zp, Cf) are not "
                "typed: tab, escape, carriage return, U+2028, U+2029, bidi overrides and isolates, "
                "zero-width characters")
    if any(line.endswith("\\") for line in text.split("\n")):
        return "a line ends with a backslash, which Claude Code reads as a line break; reword it"
    return None


def literal_args(piece):
    """The send-keys arguments that type `piece` literally, one argument per call. tmux 3.2 reads a
    trailing ";" of an argument as a command separator and drops it (measured), so every trailing ";"
    is sent as its own argument "\\;", which types ";" (measured). The text before them has no
    trailing ";" and is sent as it is."""
    head = piece.rstrip(";")
    return ([head] if head else []) + ["\\;"] * (len(piece) - len(head))


def parse_answer(spec):
    """(form, value): ("esc", None), ("digit", n), ("label", text), ("free", text) or
    ("multi", [n, ...]). Digits are ASCII 1 to 9 only. Raises UsageError for anything else."""
    s = (spec or "").strip()
    if not s:
        raise UsageError("the answer is empty")
    if s == "esc":
        return ("esc", None)
    if s.isascii() and s.isdigit():
        if len(s) != 1 or s == "0":
            raise UsageError("a digit answer is 1 to 9 (options above 9 are answered by label)")
        return ("digit", int(s))
    if s.startswith("free:"):
        text = s[len("free:"):]
        if not text.strip():
            raise UsageError("free: needs text")
        if "\n" in text or any(_bad_char(c) for c in text):
            raise UsageError("free text is one line without control or bidi characters")
        if len(text) > MAX_TEXT_CHARS:
            raise UsageError("free text is longer than %d characters" % MAX_TEXT_CHARS)
        return ("free", text)
    if s.startswith("multi:"):
        parts = [p.strip() for p in s[len("multi:"):].split(",")]
        if not all(p.isascii() and p.isdigit() and 1 <= int(p) <= 99 for p in parts):
            raise UsageError("multi: takes option numbers, e.g. multi:1,3 or multi:1,10")
        nums = [int(p) for p in parts]
        if len(set(nums)) != len(nums):
            raise UsageError("multi: a digit is given twice")
        return ("multi", sorted(nums))
    return ("label", s)


def nav_keys(cur, target):
    """Down or Up presses from option/row `cur` to `target` (never a digit)."""
    delta = target - cur
    return ["Down"] * delta if delta > 0 else ["Up"] * (-delta)


def _option_by_label(ask, value):
    """The option number for a label (unique, case-insensitive); Refused otherwise."""
    want = norm_label(value)
    if want.startswith("type something") or want == "chat about this":
        raise Refused("type-row", "'%s' is not an option: use free:<text> for free text" % value)
    hits = [o["n"] for o in ask["options"] if norm_label(o["label"]) == want]
    if len(hits) != 1:
        labels = ", ".join(o["label"] for o in ask["options"])
        raise Refused("bad-answer", "no single option is labelled '%s' (options: %s)" % (value, labels))
    return hits[0]


def flat_keys(steps):
    """The key names of a step list (the highlight checks are not keys)."""
    return [key for kind, value in steps if kind == "keys" for key in value]


def select_steps(ask, n):
    """Steps that select option n of a single-select Ask box and send it: its digit; for option
    10 and above Down/Up to it, a check that the highlight is on n (the row is read again, Enter
    is not sent otherwise), then Enter."""
    if n <= 9:
        return [("keys", [str(n)])]
    return [("keys", nav_keys(ask["cursor"], n)), ("cursor", n), ("keys", ["Enter"])]


def answer_steps(ask, parsed):
    """Steps for a single-select Ask box: a digit (or navigation and Enter above 9) selects and
    sends, a label is mapped to its option, esc declines. Refused for a multi select, the Type
    something row, unknown or ambiguous labels, and for free text and multi (they have their own
    routes)."""
    form, value = parsed
    if form == "esc":
        return [("keys", ["Escape"])]
    if ask["multi"]:
        raise Refused("multi-select", "this is a multi select: answer with multi:<d,d> "
                      "(digits toggle the boxes, nothing is sent by a digit)")
    if form == "digit":
        if value == ask["type_n"]:
            raise Refused("type-row", "option %d is the Type something row: answer with "
                          "free:<text>" % value)
        if not 1 <= value < ask["type_n"]:
            raise Refused("bad-answer", "there is no option %d (1 to %d)"
                          % (value, ask["type_n"] - 1))
        return select_steps(ask, value)
    if form == "label":
        return select_steps(ask, _option_by_label(ask, value))
    raise Refused("bad-answer", "this question takes a digit, a label or esc; use free:<text> "
                  "for free text and multi:<d,d> for a multi select")


def answer_keys(ask, parsed):
    """The key names of answer_steps (see there)."""
    return flat_keys(answer_steps(ask, parsed))


def free_nav_keys(ask):
    """Up or Down presses from the highlighted row to the Type something row."""
    return nav_keys(ask["cursor"], ask["type_n"])


def multi_toggle_steps(ask, targets):
    """Steps that toggle exactly the boxes that differ from the wanted set. A digit toggles
    without moving the highlight; an option above 9 is reached by Down/Up, checked to be the
    highlighted row, and toggled with Space."""
    if not ask["multi"]:
        raise Refused("single-select", "this is not a multi select")
    wanted = set(targets)
    if not wanted or any(n < 1 or n >= ask["type_n"] for n in wanted):
        raise Refused("bad-answer", "multi needs option numbers 1 to %d, at least one"
                      % (ask["type_n"] - 1))
    current = {o["n"] for o in ask["options"] if o["checked"]}
    steps = []
    cur = ask["cursor"]
    for n in sorted(current ^ wanted):
        if n <= 9:
            steps.append(("keys", [str(n)]))
        else:
            steps += [("keys", nav_keys(cur, n)), ("cursor", n), ("keys", ["Space"])]
            cur = n
    return steps


def multi_toggle_keys(ask, targets):
    """The key names of multi_toggle_steps (see there)."""
    return flat_keys(multi_toggle_steps(ask, targets))


def permission_keys(perm, parsed, persist=False):
    """Keys for a permission prompt: a digit within the options, or esc. An option whose full
    label is not exactly Yes or No (the rows under it included) needs persist, since it keeps
    the approval for later prompts or says more than a plain answer."""
    form, value = parsed
    if form == "esc":
        return ["Escape"]
    if form == "digit" and 1 <= value <= len(perm["options"]):
        full = perm["full"][value - 1]
        if needs_persist(full) and not persist:
            raise Refused("persist-needed", "option %d ('%s') is not a plain Yes or No; repeat "
                          "with --persist to confirm it" % (value, full))
        return [str(value)]
    raise Refused("bad-answer", "a permission prompt takes a digit 1 to %d or esc"
                  % len(perm["options"]))


def review_keys(review, parsed):
    """The review page takes digit 1, and only when its first option is Submit answers."""
    form, value = parsed
    if (review is not None and form == "digit" and value == 1
            and (review.get("options") or [None])[0] == SUBMIT_LABEL):
        return ["1"]
    raise Refused("bad-answer", "the review page takes 1 (%s) only" % SUBMIT_LABEL)


def choice_label(state, parsed):
    """The label of the option the answer chooses, for the result and the log."""
    form, value = parsed
    kind = state["kind"]
    if form == "esc":
        return "declined"
    if form == "free":
        return "free text"
    if kind == "permission":
        return state["perm"]["full"][value - 1] if form == "digit" else "permission"
    if kind == "review":
        return SUBMIT_LABEL
    ask = state["ask"]
    if form == "multi":
        return ", ".join(o["label"] for o in ask["options"] if o["n"] in value)
    if form == "digit":
        return next((o["label"] for o in ask["options"] if o["n"] == value), str(value))
    return next((o["label"] for o in ask["options"] if o["n"] == _option_by_label(ask, value)), value)


# --------------------------------------------------------------------------- prompt identity

PROMPT_KEYS = {"ask": "ask", "permission": "perm", "review": "review"}


def dialog_refusal(state):
    """A Refused for a dialog that must not be read or answered (the top is not in view, or it holds
    invisible or bidi characters), else None. Checked before every read of a dialog."""
    code = state.get("refusal")
    if code == NOT_FITTING:
        return Refused(NOT_FITTING, NOT_FITTING_TEXT + "; nothing typed or answered")
    if code == INVISIBLE:
        return Refused(INVISIBLE, INVISIBLE_TEXT + "; nothing typed or answered")
    return None


def prompt_digest(state):
    """sha256 (hex) over the whole dialog block of the open prompt (every non-blank row from the
    box top rule to the footer, whitespace normalized), or None when no prompt is open. The
    cursor, the checkboxes, the tab states, the typed text of the Type something row and the
    footer are left out: the answer itself changes them, or the footer follows the highlight (see
    _digest_rows in credo_pane_guard)."""
    kind = state.get("kind")
    key = PROMPT_KEYS.get(kind)
    if key is None:
        return None
    rows = [canon(x) for x in state[key]["digest_rows"]]
    blob = json.dumps({"kind": kind, "rows": rows}, sort_keys=True, ensure_ascii=False).encode("utf-8")
    return hashlib.sha256(blob).hexdigest()


def same_prompt(before, now):
    """True when `now` is the same prompt (kind, question, command, options) as `before`."""
    digest = prompt_digest(before)
    return digest is not None and digest == prompt_digest(now)


def changed(before, now):
    """True when the prompt that was open is gone or replaced (by another kind, or by another
    prompt of the same kind)."""
    return not same_prompt(before, now)


def describe(state):
    """One short line on what the pane shows (no pane text beyond the classification)."""
    kind = state["kind"]
    if kind == "ask":
        return "Ask box open (%s)" % ("multi select" if state["ask"]["multi"] else "single select")
    if kind == "permission":
        return "permission prompt open"
    if kind == "review":
        return "review page open"
    if kind == "input":
        return "input box, no dialog open"
    if kind == "dialog":
        return "dialog or menu open"
    return "no known dialog (%s)" % state.get("reason", "unknown")


def details(state):
    """The prompt as the owner sees it, for show (JSON-able). block is the whole dialog block,
    verbatim (every non-blank row from the box top rule to the footer); the other fields are
    the parsed view of the same rows."""
    kind = state["kind"]
    if kind == "ask":
        a = state["ask"]
        return {"block": a["block"], "header": a["header"], "question": a["question"],
                "multi": a["multi"], "cursor": a["cursor"], "type_n": a["type_n"],
                "options": [{"n": o["n"], "label": o["label"], "desc": o["desc"],
                             "checked": o["checked"]} for o in a["options"]]}
    if kind == "permission":
        p = state["perm"]
        return {"block": p["block"], "title": p["title"], "body": p["body"],
                "question": p["question"], "cursor": p["cursor"],
                "options": [{"n": i + 1, "label": x, "full": full, "persist": needs_persist(full)}
                            for i, (x, full) in enumerate(zip(p["options"], p["full"]))]}
    if kind == "review":
        r = state["review"]
        return {"block": r["block"], "answers": [{"question": q, "labels": ls} for q, ls in r["answers"]],
                "cursor": r["cursor"], "options": r["options"]}
    return {}


# --------------------------------------------------------------------------- target and pane

def resolve(query, all_profiles=False):
    """(target, None) for a live, verified session with a recorded pane, else
    (None, (status, code, reason)) with status unknown, ambiguous or refused."""
    res = registry.resolve(registry.profiles_to_read(all_profiles), query)
    status = res["status"]
    if status in ("not-found", "ambiguous"):
        return None, ("ambiguous" if status == "ambiguous" else "unknown", status, res["reason"])
    if status != "live":
        return None, ("refused", "stale-session", "stale: " + res["reason"])
    entry = res["entry"]
    tmux = entry.get("tmux") or {}
    if not tmux.get("pane"):
        return None, ("refused", "no-pane", "the session has no tmux pane recorded")
    return {"session_id": entry["session_id"], "name": entry.get("name") or "-",
            "profile": entry["profile"], "pane": tmux["pane"], "socket": tmux["socket"],
            "owner_pid": tmux["owner_pid"], "owner_start": tmux["owner_start"],
            "agent_pid": entry["pid"], "agent_start": entry["pid_start"]}, None


def pane_problem(t):
    """(code, reason) when the pane must not be used right now, else None."""
    if restart.read_uid(t["owner_pid"]) != os.getuid():
        return "owner", "the pane process belongs to another user"
    check = restart.session_owner_check({"agent_pid": t["agent_pid"], "agent_start": t["agent_start"]})
    err = check(t["pane"], t["socket"], t["owner_pid"], t["owner_start"])
    if err:
        return "owner-mismatch", "the pane no longer belongs to this session: " + err
    info = guard.pane_info(t["pane"], t["socket"])
    if info is None:
        return "pane-missing", "tmux pane %s is not reachable" % t["pane"]
    if info["dead"]:
        return "pane-dead", "tmux pane %s is dead" % t["pane"]
    if info["in_mode"]:
        return "copy-mode", "tmux pane %s is in copy mode; leave it first" % t["pane"]
    return None


def scrollback_rows():
    raw = os.environ.get(SCROLLBACK_ENV)
    try:
        return max(1, int(raw)) if raw else guard.SCROLLBACK_ROWS
    except ValueError:
        return guard.SCROLLBACK_ROWS


def _same_visible(window, visible):
    """True when the window (scrollback plus visible area) ends with the visible capture. Compared
    without escape sequences: in the window capture tmux carries the colour state of the row above
    into the first visible row (an extra SGR reset), so the raw rows can differ while the text is
    the same."""
    w = [guard.strip_ansi(r).rstrip() for r in (window or "").rstrip("\n").split("\n")]
    v = [guard.strip_ansi(r).rstrip() for r in (visible or "").rstrip("\n").split("\n")]
    return len(v) <= len(w) and w[len(w) - len(v):] == v


def read_pane(t):
    """(capture, None) when the pane is usable, else (None, (code, reason)). The capture is the visible
    text, carrying its scrollback window (guard.Capture) for the dialog top search."""
    problem = pane_problem(t)
    if problem:
        return None, problem
    text = guard.capture_exact(t["pane"], t["socket"])
    if text is None:
        return None, ("pane-missing", "the capture of the pane failed")
    window = guard.capture_window(t["pane"], t["socket"], scrollback_rows())
    if window is None:
        return None, ("pane-missing", "the capture of the pane with its scrollback failed")
    if not _same_visible(window, text):
        return None, ("pane-changed", "the pane changed while it was read; nothing typed, read it again")
    return guard.with_window(text, window), None


def paste_text(t, text):
    """Load `text` into a named tmux buffer (stdin) and paste it into the own pane as one bracketed
    paste (-p; -d drops the buffer afterwards). True when tmux accepted both calls."""
    pane = t["pane"]
    if not wake.PANE_RE.fullmatch(pane or ""):
        return False
    name = "%s-%d" % (PASTE_BUFFER, os.getpid())
    base = guard.tmux_base(t.get("socket"))
    try:
        load = subprocess.run(base + ["load-buffer", "-b", name, "-"], input=text, encoding="utf-8",
                              capture_output=True, timeout=10)
        if load.returncode != 0:
            return False
        paste = subprocess.run(base + ["paste-buffer", "-p", "-d", "-b", name, "-t", pane],
                               capture_output=True, timeout=10)
        if paste.returncode == 0:
            return True
    except (OSError, subprocess.SubprocessError):
        pass
    # the buffer holds the owner's text: drop it when the paste did not take it (best effort)
    subprocess.run(base + ["delete-buffer", "-b", name], capture_output=True, timeout=10)
    return False


def plan_of(t):
    return {"pane": t["pane"], "socket": t["socket"]}


def send_one(t, keys):
    """Press one named key in the own pane. True when tmux accepted it."""
    return wake.send_keys(plan_of(t), keys)


# --------------------------------------------------------------------------- delivery log

def _log_value(value):
    """A log value of the delivery details: categories only (lists joined, booleans as yes or no)."""
    if isinstance(value, bool):
        return "yes" if value else "no"
    if isinstance(value, (list, tuple)):
        return ",".join(value)
    return str(value)


def log_line(t, mode, chars, status, code, text, label=None, extra=None):
    stamp = datetime.datetime.now().astimezone().isoformat(timespec="seconds")
    parts = [stamp, "session=%s" % t["session_id"], "mode=%s" % mode, "chars=%d" % chars,
             "result=%s" % status]
    if code and code != status:
        parts.append("code=%s" % code)
    if label:
        parts.append("option=%s" % json.dumps(label, ensure_ascii=False))
    for key, value in (extra or {}).items():
        parts.append("%s=%s" % (key, _log_value(value)))
    if text and os.environ.get("CREDO_OWNER_TYPE_LOG_TEXT") == "1":
        parts.append("text=%s" % json.dumps(text, ensure_ascii=False))
    return " ".join(parts)


def log_path(profile):
    return os.path.join(profile, "credo", LOG_NAME)


def _open_log(profile):
    """The log opened for appending: created owner-only, never through a symlink, never
    blocking on a FIFO, and only when it is a regular file of this user that no one else can
    write. Raises OSError otherwise (the same check for the check and for the write)."""
    os.makedirs(os.path.join(profile, "credo"), mode=0o700, exist_ok=True)
    flags = (os.O_WRONLY | os.O_APPEND | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0)
             | getattr(os, "O_NONBLOCK", 0))
    fd = os.open(log_path(profile), flags, 0o600)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode):
            raise OSError("the delivery log is not a regular file")
        if info.st_uid != os.getuid():
            raise OSError("the delivery log belongs to another user")
        if info.st_mode & 0o022:
            raise OSError("the delivery log is writable by group or others")
    except BaseException:
        os.close(fd)
        raise
    return fd


def write_log(profile, line):
    """Append one line to <profile>/credo/owner-type.log. Raises OSError when unusable."""
    fd = _open_log(profile)
    try:
        os.write(fd, (line + "\n").encode("utf-8"))
    finally:
        os.close(fd)


def ensure_log(t):
    """Fail closed: the log must be usable before anything is typed."""
    os.close(_open_log(t["profile"]))


def finish(t, mode, chars, status, code, reason, text=None, log=True, label=None, extra=None):
    """The result of one call. Deliveries and refusals are logged (not dry runs, not show). extra holds
    the delivery details (the checks after the paste, whether the text was taken back)."""
    result = {"status": status, "code": code, "reason": reason, "exit": EXIT[status],
              "mode": mode, "chars": chars, "label": label,
              "session": t["session_id"] if t else None}
    result.update(extra or {})
    if t is not None and log and status != "dry-run":
        try:
            write_log(t["profile"], log_line(t, mode, chars, status, code, text, label, extra))
        except OSError as exc:
            result["reason"] = reason + " (delivery log not written: %s)" % type(exc).__name__
    return result


# --------------------------------------------------------------------------- send

def plan_send(t, text, force):
    """(before, appended): the input field before pasting and what will be pasted. Raises Refused when
    nothing may be typed now: a dialog is open, the field holds text without --force-append, or with
    --force-append the cursor is not at the end of the field."""
    cap, problem = read_pane(t)
    if problem:
        raise Refused(problem[0], problem[1])
    state = guard.classify_pane(cap)
    ref = dialog_refusal(state)
    if ref:
        raise ref
    kind = state["kind"]
    if kind == "ask":
        raise Refused("ask-box", "an Ask box is open in this session; answer it with answer "
                      "--ask, or in the pane; nothing typed")
    if kind == "review":
        raise Refused("review-page", "the review page of an Ask box is open; answer it with "
                      "answer --ask 1, or in the pane; nothing typed")
    if kind == "permission":
        raise Refused("permission-prompt", "a permission prompt is open; answer it with answer "
                      "--ask <digit|esc> --expect <digest>, or in the pane; nothing typed")
    if kind == "dialog":
        raise Refused("dialog-open", "a dialog or menu is open in the session (%s); nothing typed"
                      % state["reason"])
    if kind == "unknown" and guard.find_input_box(cap.split("\n")) is not None:
        raise Refused("dialog-above-input", "dialog-shaped rows are drawn above the input box, so "
                      "the pane is not clear; nothing typed")
    if kind != "input":
        raise Refused("no-input-box", "no input box visible and no known dialog (%s); nothing typed"
                      % state["reason"])
    before = guard.input_content(cap)
    if before is None:
        raise Refused("no-input-box", "no input box visible; nothing typed")
    if before and not force:
        raise Refused("input-holds-text", "the input field holds text; send with --force-append to "
                      "append after it; nothing typed")
    if before and not guard.cursor_at_end(cap, guard.pane_cursor(t["pane"], t["socket"])):
        raise Refused("cursor-not-at-end", "the cursor is not at the end of the input field; move it "
                      "there in the pane; nothing typed")
    return before, (" " + text if before else text)


def _cleared(text, state):
    """True when an input box is drawn and its field is empty again (a placeholder counts as
    empty). A dialog-shaped row above the box does not count against it: the box is drawn, so no
    dialog is open, and the field is what the delivery is confirmed by."""
    if state["kind"] not in ("input", "unknown"):
        return False
    content = guard.input_content(text)
    return content is not None and not norm(content)


def wait_cleared(t, tm):
    """'delivered' once the input field is empty again, 'unconfirmed' after confirm_wait."""
    end = time.time() + tm["confirm_wait"]
    while True:
        text, problem = read_pane(t)
        if text is not None and _cleared(text, guard.classify_pane(text)):
            return "delivered"
        if time.time() >= end:
            return "unconfirmed"
        time.sleep(0.2)


def take_back(t, own, read_now, before, tm):
    """Remove `own` (the own typed text) from the field, only when the field reads exactly
    `before` followed by it. True when removed or nothing was typed."""
    if not own:
        return True
    text, problem = read_pane(t)
    if problem:
        return False
    state = guard.classify_pane(text)
    now = read_now(state, text)
    if now is None or norm(now) != norm(before) + norm(own):
        return False
    if not wake.send_key_list(plan_of(t), ["BSpace"] * len(own)):
        return False
    time.sleep(tm["key_pause"])
    text, problem = read_pane(t)
    if problem:
        return False
    now = read_now(guard.classify_pane(text), text)
    return now is not None and norm(now) == norm(before)


def send(query, text, force=False, dry_run=False, all_profiles=False, expect=None):
    """Pastes the text into the session's input field and presses Enter (see the module docstring).
    expect is accepted for compatibility and not checked (owner decision Q56)."""
    mode = "force-append" if force else "normal"
    chars = len(text or "")
    usage = validate_text(text)
    if usage:
        return finish(None, mode, chars, "usage", "usage", usage, log=False)
    t, err = resolve(query, all_profiles)
    if err:
        status, code, reason = err
        return finish(None, mode, chars, status, code, reason, log=False)
    try:
        if not dry_run:
            ensure_log(t)
        before, appended = plan_send(t, text, force)
    except OSError as exc:
        return finish(t, mode, chars, "refused", "log", "delivery log not usable: %s"
                      % type(exc).__name__, text, log=False)
    except Refused as exc:
        return finish(t, mode, chars, "refused", exc.code, str(exc), text, log=not dry_run)
    if dry_run:
        return finish(t, mode, chars, "dry-run", "dry-run",
                      "would paste %d character(s) and press Enter; nothing typed" % len(appended),
                      log=False)
    return _deliver(t, mode, chars, text, appended, before, timing())


def _check_after_paste(t):
    """One check of the pane after the paste: (code, reason). The code is clear (an input box with no
    dialog drawn), dialog-after-paste (a recognised dialog), a pane stop (PANE_STOPS), pane-changed (the
    capture was not stable), input-not-visible (no input box drawn) or unknown-state (an input box with
    something unrecognised around it). The reason never carries pane text."""
    text, problem = read_pane(t)
    if problem:
        return problem
    state = guard.classify_pane(text)
    if state.get("refusal") or state["kind"] in DIALOG_KINDS:
        return "dialog-after-paste", "dialog open (%s)" % state.get("reason", "unknown")
    if state["kind"] == "input":
        return "clear", ""
    if guard.input_content(text) is None:
        return "input-not-visible", "no input box is drawn"
    return "unknown-state", state.get("reason", "unknown")


def _after_paste(t, tm):
    """The checks after the paste: (hold, code, reason, checks). A pane stop holds Enter at once. The
    last check decides otherwise: only a recognised dialog holds Enter back. pane-changed, unknown-state
    and input-not-visible are retried (a clear check ends the checks early)."""
    time.sleep(tm["settle"])
    checks, code, reason = [], "clear", ""
    for i in range(CHECKS_AFTER_PASTE):
        if i:
            time.sleep(tm["recheck"])
        code, reason = _check_after_paste(t)
        checks.append(code)
        if code in PANE_STOPS:
            return True, code, reason, checks
        if code == "clear":
            break
    return code == "dialog-after-paste", code, reason, checks


def _own_keys(content, own):
    """BSpace presses that remove the pasted text `own` from a field that reads `content`: one per
    character of the text when the field shows exactly it, one for a single paste placeholder. None when
    the field shows anything else."""
    if norm(content) and norm(content) == norm(own):
        return len(own)
    if PLACEHOLDER_RE.fullmatch(content or ""):
        return 1
    return None


def take_back_paste(t, own, before, tm):
    """After a held Enter, remove the own pasted text from the input field so the field is not left
    blocked. Only when the field was empty before the paste, the pane is readable and shows an input box
    with no dialog, and the field reads exactly the own text or one paste placeholder. Nothing else is
    removed. Returns (taken back, note for the result)."""
    if before:
        return False, "the field held text before the paste; it is left as it is"
    text, problem = read_pane(t)
    if problem:
        return False, "the pane could not be read; the text stays in the input field"
    content = guard.input_content(text)
    if guard.classify_pane(text)["kind"] != "input" or content is None:
        return False, "a dialog is open or no input box is drawn; the text stays in the input field"
    if not norm(content):
        return True, "the input field is empty; nothing to take back"
    count = _own_keys(content, own)
    if count is None:
        return False, "the input field shows other text; it is left as it is"
    if not wake.send_key_list(plan_of(t), ["BSpace"] * count):
        return False, "the removal keys could not be sent; check the pane"
    if wait_cleared(t, tm) == "delivered":
        return True, "the text was taken back out of the input field"
    return False, "the input field still holds text; check the pane"


def _deliver(t, mode, chars, text, appended, before, tm):
    """Paste, the checks after the paste, Enter, then check the field is empty."""
    if not paste_text(t, appended):
        return finish(t, mode, chars, "failed", "paste-failed",
                      "the text could not be pasted; nothing submitted", text)
    hold, code, reason, checks = _after_paste(t, tm)
    if hold:
        taken, note = take_back_paste(t, appended, before, tm)
        return finish(t, mode, chars, "failed", code,
                      "%s after the paste; Enter not sent; %s" % (reason, note), text,
                      extra={"checks": checks, "taken_back": taken})
    if not send_one(t, ENTER):
        return finish(t, mode, chars, "failed", "enter-failed",
                      "Enter could not be sent; the text is in the input field; check the pane", text,
                      extra={"checks": checks})
    if wait_cleared(t, tm) == "delivered":
        return finish(t, mode, chars, "delivered", "delivered",
                      "text sent (%d character(s))" % chars, text, extra={"checks": checks})
    return finish(t, mode, chars, "unconfirmed", "unconfirmed",
                  "Enter sent, but the input field did not clear within %gs; check the pane "
                  "before sending again" % tm["confirm_wait"], text, extra={"checks": checks})


# --------------------------------------------------------------------------- show

def show(query, all_profiles=False):
    """The open prompt of the session with its digest. Read only; nothing is typed."""
    t, err = resolve(query, all_profiles)
    if err:
        status, code, reason = err
        return finish(None, "show", 0, status, code, reason, log=False)
    cap, problem = read_pane(t)
    if problem:
        return finish(None, "show", 0, "refused", problem[0], problem[1], log=False)
    state = guard.classify_pane(cap)
    ref = dialog_refusal(state)
    if ref:
        return finish(t, "show", 0, "refused", ref.code, str(ref), log=False)
    result = finish(None, "show", 0, "shown", "shown", describe(state), log=False)
    result.update(session=t["session_id"], kind=state["kind"], digest=prompt_digest(state))
    result.update(details(state))
    return result


# --------------------------------------------------------------------------- answer

def route(state, parsed):
    """'keys' for the plain key answers, 'free' or 'multi' for the two Ask box routes."""
    kind, form = state["kind"], parsed[0]
    if kind == "ask":
        if form == "free":
            if state["ask"]["multi"]:
                raise Refused("multi-select", "free text is for a single select; use multi:<d,d>")
            return "free"
        if form == "multi":
            if not state["ask"]["multi"]:
                raise Refused("single-select", "this is a single select: answer with a digit "
                              "or a label")
            return "multi"
        return "keys"
    if kind in ("permission", "review"):
        return "keys"
    raise Refused("no-ask", "no Ask box or permission prompt is open (%s); nothing to answer"
                  % describe(state))


def steps_of(state, parsed, persist):
    """The steps of a plain key answer: an Ask box (see answer_steps), a permission prompt or a
    review page."""
    if state["kind"] == "ask":
        return answer_steps(state["ask"], parsed)
    if state["kind"] == "permission":
        return [("keys", permission_keys(state["perm"], parsed, persist))]
    return [("keys", review_keys(state["review"], parsed))]


def _answer_plan(how, state, parsed, persist):
    """The steps of a plain answer, the toggle steps of a multi select, or None (free text).
    Validation happens here, before anything is sent."""
    if how == "keys":
        return steps_of(state, parsed, persist)
    if how == "multi":
        return multi_toggle_steps(state["ask"], parsed[1])
    return None


def _describe(how, plan, parsed):
    if how == "keys":
        return "with key(s) %s" % " ".join(flat_keys(plan))
    if how == "multi":
        return "a multi select (keys %s)" % " ".join(flat_keys(plan))
    return "by typing the free text"


def answer(query, spec, dry_run=False, all_profiles=False, expect=None, persist=False):
    """Answers the open Ask box, review page or permission prompt. --expect (the digest that
    show printed) is required for every answer, dry runs included."""
    try:
        parsed = parse_answer(spec)
        if expect is not None and not DIGEST_RE.fullmatch(expect or ""):
            raise UsageError("--expect takes the 64-character digest that show prints")
    except UsageError as exc:
        return finish(None, "answer", 0, "usage", "usage", str(exc), log=False)
    if expect is None:
        return finish(None, "answer", 0, "refused", "expect-required",
                      "--expect <digest> is required for every answer: read the digest with show "
                      "and repeat; nothing sent", log=False)
    t, err = resolve(query, all_profiles)
    if err:
        status, code, reason = err
        return finish(None, "answer", 0, status, code, reason, log=False)
    mode = "answer-" + parsed[0]
    text = parsed[1] if parsed[0] == "free" else None
    chars = len(text) if text else 0
    try:
        if not dry_run:
            ensure_log(t)
        cap, problem = read_pane(t)
        if problem:
            raise Refused(problem[0], problem[1])
        state = guard.classify_pane(cap)
        ref = dialog_refusal(state)
        if ref:
            raise ref
        how = route(state, parsed)
        if prompt_digest(state) != expect:
            raise Refused("prompt-mismatch", "the open prompt is not the one with digest --expect "
                          "(it changed since show, or the digest is wrong); nothing sent")
        plan = _answer_plan(how, state, parsed, persist)
        label = choice_label(state, parsed)
    except OSError as exc:
        return finish(t, mode, chars, "refused", "log", "delivery log not usable: %s"
                      % type(exc).__name__, text, log=False)
    except Refused as exc:
        return finish(t, mode, chars, "refused", exc.code, str(exc), text, log=not dry_run)
    if dry_run:
        return finish(t, mode, chars, "dry-run", "dry-run",
                      "would answer %s; nothing sent" % _describe(how, plan, parsed), log=False)
    ctx = {"t": t, "mode": mode, "chars": chars, "text": text, "label": label, "expect": expect}
    tm = timing()
    try:
        if how == "keys":
            return _answer_steps(ctx, state, plan, tm)
        if how == "free":
            return _answer_free(ctx, state, tm)
        return _answer_multi(ctx, state, plan, parsed[1], tm)
    except Exception as exc:  # a tmux call failing mid-way: report, never guess
        return _done(ctx, "failed", "answer-aborted",
                     "error (%s) while answering; check the pane" % type(exc).__name__)


def _done(ctx, status, code, reason):
    return finish(ctx["t"], ctx["mode"], ctx["chars"], status, code, reason, ctx["text"],
                  label=ctx["label"])


def _answered(ctx):
    return _done(ctx, "answered", "answered", "answer sent: %s" % ctx["label"])


def reread_same(t, state, expect=None):
    """None when the open prompt is still the bound one (same digest, the digest given with
    --expect for the first prompt), else the Refused. Called right before every key."""
    text, problem = read_pane(t)
    if problem:
        return Refused(problem[0], problem[1])
    now = guard.classify_pane(text)
    ref = dialog_refusal(now)
    if ref:
        return ref
    if not same_prompt(state, now):
        return Refused("prompt-changed", "the open prompt changed since it was read")
    if expect is not None and prompt_digest(now) != expect:
        return Refused("prompt-mismatch", "the open prompt is not the one with digest --expect")
    return None


def _same_question(a, b):
    """True when two Ask box states show the same question and option labels (checkboxes and
    the highlight may differ: a multi select changes them while it is answered)."""
    return (a["question"] == b["question"]
            and [o["label"] for o in a["options"]] == [o["label"] for o in b["options"]])


def highlight_problem(t, bound, n):
    """None when the highlight of the bound Ask box is on option n, else the reason. Read again
    after the navigation, before the key that selects or toggles option n."""
    text, problem = read_pane(t)
    if problem:
        return "%s; nothing more sent, check the pane" % problem[1]
    now = guard.classify_pane(text)
    if (now["kind"] != "ask" or now["ask"]["cursor"] != n
            or not _same_question(bound["ask"], now["ask"])):
        return "the highlight is not on option %d; the key for it was not sent, check the pane" % n
    return None


def run_steps(ctx, bound, steps, tm, expect=None):
    """Presses the steps in order. Before EVERY key the open prompt is read again and must still
    be the bound one (and the digest given with --expect, for the first prompt). After a navigation
    step the next Enter or Space is sent only when the highlight is on the target row, read right
    before that key. Returns None when every step went out, else the finished result: refused before
    the first key, failed after it."""
    t = ctx["t"]
    sent = 0
    target = None
    for kind, value in steps:
        if kind == "cursor":
            target = value
            continue
        for key in value:
            stale = reread_same(t, bound, expect)
            if stale:
                if sent:
                    return _done(ctx, "failed", stale.code, "%s after %d key(s); nothing more sent, "
                                 "check the pane" % (stale, sent))
                return _done(ctx, "refused", stale.code, "%s; nothing sent" % stale)
            if target is not None and key in CONFIRM_KEYS:
                problem = highlight_problem(t, bound, target)
                if problem:
                    return _done(ctx, "failed", "highlight-mismatch", problem)
                target = None
            if not send_one(t, key):
                return _done(ctx, "failed", "key-failed", "a key could not be sent")
            sent += 1
            time.sleep(tm["key_pause"])
    return None


def wait_changed(t, before, tm):
    end = time.time() + tm["confirm_wait"]
    while True:
        text, problem = read_pane(t)
        if text is not None and changed(before, guard.classify_pane(text)):
            return "answered"
        if time.time() >= end:
            return "unconfirmed"
        time.sleep(0.2)


def _answer_steps(ctx, state, steps, tm):
    stopped = run_steps(ctx, state, steps, tm, ctx["expect"])
    if stopped:
        return stopped
    if wait_changed(ctx["t"], state, tm) == "answered":
        return _answered(ctx)
    return _done(ctx, "unconfirmed", "unconfirmed",
                 "keys sent, the Ask box or prompt is still open; check the pane")


def _free_now(state, text):
    """The text in the Type something row ("" for the placeholder), None when not an Ask box."""
    if state["kind"] != "ask":
        return None
    label = state["ask"]["type_label"]
    return "" if norm_label(label) in ("type something", "type something.") else label


def still_free(t, bound, typed):
    """Raises Abort unless the bound Ask box is still open, the highlight is on its Type something row
    and that row holds exactly what was typed so far. Checked before every piece and before the Enter.
    The digest ignores the Type something text, so typing does not count as a change of the prompt."""
    text, problem = read_pane(t)
    if problem:
        raise Abort(problem[1], typed)
    state = guard.classify_pane(text)
    ref = dialog_refusal(state)
    if ref:
        raise Abort(str(ref), typed)
    if not same_prompt(bound, state):
        raise Abort("the Ask box changed while typing", typed)
    if state["ask"]["cursor"] != bound["ask"]["type_n"]:
        raise Abort("the highlight left the Type something row while typing", typed)
    if norm(_free_now(state, text)) != norm("".join(typed)):
        raise Abort("the Ask box changed while typing", typed)


def _answer_free(ctx, state, tm):
    t, text = ctx["t"], ctx["text"]
    ask = state["ask"]
    stale = reread_same(t, state, ctx["expect"])
    if stale:
        return _done(ctx, "refused", stale.code, "%s; nothing sent" % stale)
    if _free_now(state, None):
        return _done(ctx, "refused", "type-row-held",
                     "the Type something row already holds text; nothing typed")
    stopped = run_steps(ctx, state, [("keys", free_nav_keys(ask))], tm, ctx["expect"])
    if stopped:
        return stopped
    cap, problem = read_pane(t)
    moved = guard.classify_pane(cap) if problem is None else {"kind": "unknown"}
    if moved["kind"] != "ask" or moved["ask"]["cursor"] != ask["type_n"]:
        return _done(ctx, "refused", "type-row-not-reached",
                     "the highlight did not reach the Type something row; nothing typed")
    typed = []
    try:
        for piece in wake.type_chunks(text):
            still_free(t, state, typed)
            typed.append(piece)
            if not all(wake.send_keys(plan_of(t), arg, literal=True) for arg in literal_args(piece)):
                typed.pop()
                raise Abort("typing failed", typed)
            time.sleep(tm["type_pause"])
        time.sleep(tm["settle"])
        still_free(t, state, typed)
        if not send_one(t, ENTER):
            raise Abort("Enter could not be sent", typed)
    except Abort as exc:
        removed = take_back(t, "".join(typed), _free_now, "", tm)
        note = "own text taken back" if removed else "own text left in the Type something row"
        return _done(ctx, "failed", "typing-aborted", "%s; %s" % (exc.reason, note))
    if wait_changed(t, state, tm) == "answered":
        return _answered(ctx)
    return _done(ctx, "unconfirmed", "unconfirmed",
                 "Enter sent, the Ask box is still open; check the pane")


def labels_match(a, b):
    """True when two label lists hold the same labels. The review page lists a multi select in
    the order the boxes were checked, not in option order, so the order does not count."""
    return sorted(a) == sorted(b)


def wait_state(t, before, tm):
    """The first pane state that is no longer `before` (another question, the review page, a
    different prompt), or None after confirm_wait."""
    end = time.time() + tm["confirm_wait"]
    while True:
        text, problem = read_pane(t)
        if text is not None:
            now = guard.classify_pane(text)
            if changed(before, now):
                return now
        if time.time() >= end:
            return None
        time.sleep(0.2)


def _answer_multi(ctx, state, steps, targets, tm):
    t, ask = ctx["t"], state["ask"]
    stopped = run_steps(ctx, state, steps, tm, ctx["expect"])
    if stopped:
        return stopped
    cap, problem = read_pane(t)
    now = guard.classify_pane(cap) if problem is None else {"kind": "unknown"}
    checked = ({o["n"] for o in now["ask"]["options"] if o["checked"]}
               if now["kind"] == "ask" else None)
    if checked != set(targets):
        return _done(ctx, "failed", "multi-mismatch",
                     "the checked boxes are not the wanted set; nothing submitted, box left open")
    # Right: in a single-question box it opens the review page; in a tabbed box (several
    # questions) it moves to the next question, which records this answer (measured).
    stopped = run_steps(ctx, state, [("keys", ["Right"])], tm, ctx["expect"])
    if stopped:
        return stopped
    nxt = wait_state(t, now, tm)
    if nxt is None:
        return _done(ctx, "failed", "right-no-move",
                     "Right did not move on; nothing submitted, box left open")
    if nxt["kind"] == "ask" and nxt["ask"]["question"] != ask["question"]:
        return _answered(ctx)
    if nxt["kind"] != "review":
        return _done(ctx, "failed", "right-unexpected",
                     "Right led to an unexpected prompt; nothing submitted, left open")
    wanted = [o["label"] for o in ask["options"] if o["n"] in targets]
    mine = [labels for q, labels in nxt["review"]["answers"] if q == ask["question"]]
    review = nxt["review"]
    if (not mine or not labels_match(mine[-1], wanted) or review["cursor"] != 1
            or (review["options"] or [None])[0] != SUBMIT_LABEL):
        return _done(ctx, "failed", "review-mismatch",
                     "the review page does not show the wanted answer and %s first; nothing "
                     "submitted, left open" % SUBMIT_LABEL)
    if ask.get("tabs", 1) > 1:
        # a tabbed box: the review page of all questions is submitted with its own call
        return _answered(ctx)
    stopped = run_steps(ctx, nxt, [("keys", ["1"])], tm, prompt_digest(nxt))
    if stopped:
        return stopped
    if wait_changed(t, nxt, tm) == "answered":
        return _answered(ctx)
    return _done(ctx, "unconfirmed", "unconfirmed",
                 "1 sent, the review is still open; check the pane")
