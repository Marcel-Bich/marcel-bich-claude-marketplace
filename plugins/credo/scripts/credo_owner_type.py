"""credo_owner_type.py - deliver the owner's text, or an answer to an Ask box or a permission
prompt, into the owner's own Claude Code session pane (the tmux pane the session runs in).

A local connector (for example a phone app) runs credo-owner-type.py; this module does the
work. Every key goes through the same checks, in this order:

  1. Target: the session must be live in the session registry (credo_session_registry:
     pid and start time, session descriptor, pane on its server, pane not dead, still owned
     by the session at record time). Stale, unknown or ambiguous sessions are refused.
  2. Authorization: the pane process must belong to this OS user, and the pane must still
     belong to the session right before every step (credo-self-restart pane_owner_error via
     registry.restart.session_owner_check). Copy or view mode is refused.
  3. Pane state (credo_pane_guard.classify_pane): an open Ask box, review page, permission
     prompt, slash menu, picker or unknown dialog is refused - nothing is typed into it.

Send (credo-owner-type.py send): the input field must be empty, or with --force-append it
may hold text: then " " + text is appended at the end and the existing text is never
deleted or changed (the cursor must be at the end, tmux cursor_x and cursor_y are checked).
A busy session is fine: typed text + Enter goes into Claude Code's queue (measured on
Claude Code 2.1.316). The text is typed in pieces of at most 200 characters (credo_pane_wake
type_chunks), each line break is a typed backslash followed by Enter (Claude Code turns a
trailing backslash plus Enter into a line break; measured, works in every terminal). Before
the final Enter the input field must hold exactly the text that was typed (whitespace
ignored); a dialog that opens meanwhile, a changed field or a failed key stops it before
Enter, and the own typed text is taken back (BSpace) only when the field is still exactly
"what was there before" plus that text. Nothing the module did not type is ever submitted.

Answer (credo-owner-type.py answer): only when an Ask box or a permission prompt is open.
Ask box: a digit selects and sends; a label is mapped to its digit (unique, case-insensitive);
"esc" declines; "free:<text>" moves down to the Type something row (Up/Down), types the text
and sends it; "multi:<d,d>" toggles exactly the boxes that differ from the wanted set (digits
toggle), checks the checked set, presses Right (review page), checks the review page and
submits with Enter. Permission prompt: a digit within the options, or esc. Review page:
digit 1 (Submit answers). Anything else is refused.

Every attempt is logged (one line each, see write_log): time, session id, mode, character
count, result. The text is logged only with CREDO_OWNER_TYPE_LOG_TEXT=1. If the log cannot be
written, nothing is typed.

Timing overrides (tests and slow terminals): CREDO_OWNER_TYPE_TYPE_PAUSE,
CREDO_OWNER_TYPE_KEY_PAUSE, CREDO_OWNER_TYPE_SETTLE, CREDO_OWNER_TYPE_CONFIRM_WAIT.

Python 3 stdlib only.
"""
import datetime
import json
import os
import re
import stat
import sys
import time

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
EXIT = {"delivered": 0, "answered": 0, "dry-run": 0, "refused": 1, "failed": 1,
        "unconfirmed": 4, "unknown": 3, "ambiguous": 3, "usage": 2}


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


def norm_label(text):
    """Option label for matching: case-insensitive, single spaces, no "(Recommended)" tail."""
    s = re.sub(r"\s+", " ", (text or "").strip()).lower()
    return re.sub(r"\s*\(recommended\)$", "", s)


def _env_float(name, default):
    try:
        return float(os.environ.get(name, default))
    except (TypeError, ValueError):
        return float(default)


def timing():
    return {"type_pause": _env_float("CREDO_OWNER_TYPE_TYPE_PAUSE", wake.TYPE_PAUSE),
            "key_pause": _env_float("CREDO_OWNER_TYPE_KEY_PAUSE", 0.3),
            "settle": _env_float("CREDO_OWNER_TYPE_SETTLE", 0.4),
            "confirm_wait": _env_float("CREDO_OWNER_TYPE_CONFIRM_WAIT", 3.0)}


# --------------------------------------------------------------------------- text and keys

def validate_text(text):
    """None when the text may be typed, else the reason. Line breaks are allowed; control
    characters (tab, escape, carriage return, ...) are not, as Claude Code treats them as keys."""
    if not text or not text.strip():
        return "the text is empty"
    if len(text) > MAX_TEXT_CHARS:
        return "the text is longer than %d characters" % MAX_TEXT_CHARS
    for ch in text:
        if ch != "\n" and (ord(ch) < 32 or ord(ch) == 127):
            return "control characters are not typed (tab, escape, carriage return, ...)"
    return None


def keystrokes(text):
    """Steps that type `text`: ("text", piece) for literal pieces of at most
    wake.TYPE_CHUNK_CHARS characters, and a line break as ("text", backslash) followed by
    ("key", Enter)."""
    steps = []
    for i, line in enumerate(text.split("\n")):
        if i:
            steps.append(("text", LINE_BREAK))
            steps.append(("key", ENTER))
        steps.extend(("text", piece) for piece in wake.type_chunks(line))
    return steps


def parse_answer(spec):
    """(form, value): ("esc", None), ("digit", n), ("label", text), ("free", text) or
    ("multi", [n, ...]). Raises UsageError for anything else."""
    s = (spec or "").strip()
    if not s:
        raise UsageError("the answer is empty")
    if s == "esc":
        return ("esc", None)
    if s.isdigit():
        if len(s) != 1 or s == "0":
            raise UsageError("a digit answer is 1 to 9")
        return ("digit", int(s))
    if s.startswith("free:"):
        text = s[len("free:"):]
        if not text.strip():
            raise UsageError("free: needs text")
        if "\n" in text or any(ord(c) < 32 or ord(c) == 127 for c in text):
            raise UsageError("free text is one line without control characters")
        if len(text) > MAX_TEXT_CHARS:
            raise UsageError("free text is longer than %d characters" % MAX_TEXT_CHARS)
        return ("free", text)
    if s.startswith("multi:"):
        parts = [p.strip() for p in s[len("multi:"):].split(",")]
        if not all(len(p) == 1 and p in "123456789" for p in parts):
            raise UsageError("multi: takes digits, e.g. multi:1,3")
        nums = [int(p) for p in parts]
        if len(set(nums)) != len(nums):
            raise UsageError("multi: a digit is given twice")
        return ("multi", sorted(nums))
    return ("label", s)


def answer_keys(ask, parsed):
    """Key names for a single-select Ask box: a digit selects and sends, a label is mapped to
    its digit, esc declines. Refused for a multi select, the Type something row, unknown or
    ambiguous labels, and for free text and multi (they have their own routes)."""
    form, value = parsed
    if form == "esc":
        return ["Escape"]
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
        return [str(value)]
    if form == "label":
        want = norm_label(value)
        if want.startswith("type something") or want == "chat about this":
            raise Refused("type-row", "'%s' is not an option: use free:<text> for free text" % value)
        hits = [o["n"] for o in ask["options"] if norm_label(o["label"]) == want]
        if len(hits) != 1:
            labels = ", ".join(o["label"] for o in ask["options"])
            raise Refused("bad-answer", "no single option is labelled '%s' (options: %s)"
                          % (value, labels))
        return [str(hits[0])]
    raise Refused("bad-answer", "this question takes a digit, a label or esc; use free:<text> "
                  "for free text and multi:<d,d> for a multi select")


def free_nav_keys(ask):
    """Up or Down presses from the highlighted row to the Type something row."""
    delta = ask["type_n"] - ask["cursor"]
    return ["Down"] * delta if delta > 0 else ["Up"] * (-delta)


def multi_toggle_keys(ask, targets):
    """Digits that toggle exactly the boxes that differ from the wanted set."""
    if not ask["multi"]:
        raise Refused("single-select", "this is not a multi select")
    wanted = set(targets)
    if not wanted or any(n < 1 or n >= ask["type_n"] for n in wanted):
        raise Refused("bad-answer", "multi needs option numbers 1 to %d, at least one"
                      % (ask["type_n"] - 1))
    current = {o["n"] for o in ask["options"] if o["checked"]}
    return [str(n) for n in sorted(current ^ wanted)]


def permission_keys(perm, parsed):
    form, value = parsed
    if form == "esc":
        return ["Escape"]
    if form == "digit" and 1 <= value <= len(perm["options"]):
        return [str(value)]
    raise Refused("bad-answer", "a permission prompt takes a digit 1 to %d or esc"
                  % len(perm["options"]))


def review_keys(review, parsed):
    """The review page takes digit 1 (Submit answers); other answers are refused."""
    form, value = parsed
    if form == "digit" and value == 1 and review is not None:
        return ["1"]
    raise Refused("bad-answer", "the review page takes 1 (Submit answers) only")


# --------------------------------------------------------------------------- target and pane

def resolve(query, all_profiles=False):
    """(target, None) for a live, verified session with a recorded pane, else
    (None, (status, code, reason)) with status unknown, ambiguous or refused."""
    res = registry.resolve(registry.profiles_to_read(all_profiles), query)
    status = res["status"]
    if status in ("not-found", "ambiguous"):
        return None, (status if status == "ambiguous" else "unknown", status, res["reason"])
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


def read_pane(t):
    """(capture text, None) when the pane is usable, else (None, (code, reason))."""
    problem = pane_problem(t)
    if problem:
        return None, problem
    text = guard.capture_exact(t["pane"], t["socket"])
    if text is None:
        return None, ("pane-missing", "the capture of the pane failed")
    return text, None


def plan_of(t):
    return {"pane": t["pane"], "socket": t["socket"]}


def send_one(t, keys):
    """Press one named key in the own pane. True when tmux accepted it."""
    return wake.send_keys(plan_of(t), keys)


# --------------------------------------------------------------------------- delivery log

def log_line(t, mode, chars, status, code, text):
    stamp = datetime.datetime.now().astimezone().isoformat(timespec="seconds")
    parts = [stamp, "session=%s" % t["session_id"], "mode=%s" % mode, "chars=%d" % chars,
             "result=%s" % status]
    if code and code != status:
        parts.append("code=%s" % code)
    if text and os.environ.get("CREDO_OWNER_TYPE_LOG_TEXT") == "1":
        parts.append("text=%s" % json.dumps(text, ensure_ascii=False))
    return " ".join(parts)


def log_path(profile):
    return os.path.join(profile, "credo", LOG_NAME)


def write_log(profile, line):
    """Append one line to <profile>/credo/owner-type.log: owner-only, never through a symlink.
    Raises OSError when the file cannot be used."""
    directory = os.path.join(profile, "credo")
    os.makedirs(directory, mode=0o700, exist_ok=True)
    fd = os.open(log_path(profile), os.O_WRONLY | os.O_APPEND | os.O_CREAT
                 | getattr(os, "O_NOFOLLOW", 0), 0o600)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid():
            raise OSError("the delivery log is not a regular file of this user")
        os.write(fd, (line + "\n").encode("utf-8"))
    finally:
        os.close(fd)


def finish(t, mode, chars, status, code, reason, text=None, log=True):
    """The result of one call. Deliveries and refusals are logged (not dry runs)."""
    result = {"status": status, "code": code, "reason": reason, "exit": EXIT[status],
              "mode": mode, "chars": chars, "session": t["session_id"] if t else None}
    if t is not None and log and status != "dry-run":
        try:
            write_log(t["profile"], log_line(t, mode, chars, status, code, text))
        except OSError as exc:
            result["reason"] = reason + " (delivery log not written: %s)" % type(exc).__name__
    return result


def ensure_log(t):
    """Fail closed: the log must be writable before anything is typed."""
    probe = os.path.join(t["profile"], "credo")
    os.makedirs(probe, mode=0o700, exist_ok=True)
    fd = os.open(log_path(t["profile"]), os.O_WRONLY | os.O_APPEND | os.O_CREAT
                 | getattr(os, "O_NOFOLLOW", 0), 0o600)
    os.close(fd)


# --------------------------------------------------------------------------- send

def plan_send(t, text, force):
    """(before, appended): the input field before typing and what will be typed. Raises
    Refused when nothing may be typed now."""
    cap, problem = read_pane(t)
    if problem:
        raise Refused(problem[0], problem[1])
    state = guard.classify_pane(cap)
    kind = state["kind"]
    if kind == "ask":
        raise Refused("ask-box", "an Ask box is open in this session; answer it with answer "
                      "--ask, or in the pane; nothing typed")
    if kind == "review":
        raise Refused("review-page", "the review page of an Ask box is open; answer it with "
                      "answer --ask 1, or in the pane; nothing typed")
    if kind == "permission":
        raise Refused("permission-prompt", "a permission prompt is open; answer it with answer "
                      "--ask <digit|esc>, or in the pane; nothing typed")
    if kind == "dialog":
        raise Refused("dialog-open", "a dialog or menu is open in the session (%s); nothing typed"
                      % state["reason"])
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


def still_typing(t, before, typed):
    """Raises Abort unless the pane is still an input box with exactly `before` + what was typed
    so far. Checked before every literal piece and every line-break Enter: a permission prompt
    or Ask box that opens mid-message would otherwise receive the characters as answers (a
    typed digit selects an option, an Enter confirms the default)."""
    text, problem = read_pane(t)
    if problem:
        raise Abort(problem[1], typed)
    state = guard.classify_pane(text)
    if state["kind"] != "input":
        raise Abort("a dialog opened while typing", typed)
    now = guard.input_content(text)
    if now is None or norm(now) != norm(before) + norm("".join(typed)):
        raise Abort("the input field changed while typing", typed)


def type_and_enter(t, before, appended, tm, typed):
    """Type `appended`, confirm the input field, then Enter. `typed` collects what was sent
    (a line break counts as "\\n" once Enter has converted the backslash). Returns the
    status "delivered" or "unconfirmed"; raises Abort before Enter on any failure."""
    plan = plan_of(t)
    for kind, value in keystrokes(appended):
        still_typing(t, before, typed)
        if kind == "text":
            typed.append(value)
            if not wake.send_keys(plan, value, literal=True):
                typed.pop()
                raise Abort("typing failed", typed)
            time.sleep(tm["type_pause"])
        else:
            if not wake.send_keys(plan, value):
                raise Abort("the line break failed", typed)
            typed[-1] = "\n"
            time.sleep(tm["key_pause"])
    time.sleep(tm["settle"])
    still_typing(t, before, typed)
    if not wake.send_keys(plan_of(t), ENTER):
        raise Abort("Enter could not be sent", typed)
    return wait_cleared(t, tm)


def _cleared(text, state):
    """True when the input field is empty again (a placeholder counts as empty)."""
    return state["kind"] == "input" and not norm(guard.input_content(text))


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


def input_now(state, text):
    if state["kind"] != "input":
        return None
    return guard.input_content(text)


def send(query, text, force=False, dry_run=False, all_profiles=False):
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
        return finish(t, mode, chars, "refused", "log", "delivery log not writable: %s"
                      % type(exc).__name__, text)
    except Refused as exc:
        return finish(t, mode, chars, "refused", exc.code, str(exc), text, log=not dry_run)
    if dry_run:
        steps = len(keystrokes(appended))
        return finish(t, mode, chars, "dry-run", "dry-run",
                      "would type %d character(s) in %d step(s); nothing typed" % (chars, steps),
                      log=False)
    return _type(t, mode, chars, text, before, appended)


def _type(t, mode, chars, text, before, appended):
    tm = timing()
    typed = []
    try:
        status = type_and_enter(t, before, appended, tm, typed)
    except Abort as exc:
        return _failed(t, mode, chars, text, before, exc.typed, exc.reason, tm)
    except Exception as exc:  # a tmux call that hangs or fails: never leave text behind
        return _failed(t, mode, chars, text, before, typed, "error (%s)" % type(exc).__name__, tm)
    if status == "delivered":
        return finish(t, mode, chars, "delivered", "delivered",
                      "text sent (%d character(s))" % chars, text)
    return finish(t, mode, chars, "unconfirmed", "unconfirmed",
                  "Enter sent, but the input field did not clear within %gs; check the pane "
                  "before sending again" % tm["confirm_wait"], text)


def _failed(t, mode, chars, text, before, typed, reason, tm):
    removed = take_back(t, "".join(typed), input_now, before, tm)
    note = "own text taken back" if removed else "own text left in the input field, not submitted"
    return finish(t, mode, chars, "failed", "typing-aborted", "%s; %s" % (reason, note), text)


# --------------------------------------------------------------------------- answer

def changed(before, now):
    """True when the dialog that was open is gone or shows another question."""
    if now["kind"] != before["kind"]:
        return True
    if now["kind"] == "ask":
        return now["ask"]["question"] != before["ask"]["question"]
    return False


def same_prompt(before, now):
    """True when `now` is the same question, prompt or review page as `before` (the same
    options and answers, not just the same kind): an answer is only sent to the prompt that
    was read."""
    if now["kind"] != before["kind"]:
        return False
    if now["kind"] == "ask":
        return _ask_key(now["ask"]) == _ask_key(before["ask"])
    if now["kind"] == "permission":
        return now["perm"]["options"] == before["perm"]["options"]
    if now["kind"] == "review":
        return now["review"]["answers"] == before["review"]["answers"]
    return False


def _ask_key(ask):
    return (ask["question"], ask["multi"], [o["label"] for o in ask["options"]])


def reread_same(t, state):
    """None when the open prompt is still the one that was read, else the refusal."""
    text, problem = read_pane(t)
    if problem:
        return Refused(problem[0], problem[1])
    if not same_prompt(state, guard.classify_pane(text)):
        return Refused("prompt-changed", "the open prompt changed since it was read; nothing sent")
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
                  % state["reason"])


def keys_of(state, parsed):
    if state["kind"] == "ask":
        return answer_keys(state["ask"], parsed)
    if state["kind"] == "permission":
        return permission_keys(state["perm"], parsed)
    return review_keys(state["review"], parsed)


def answer(query, spec, dry_run=False, all_profiles=False):
    try:
        parsed = parse_answer(spec)
    except UsageError as exc:
        return finish(None, "answer", 0, "usage", "usage", str(exc), log=False)
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
        how = route(state, parsed)
        plan = _answer_plan(how, state, parsed)
    except OSError as exc:
        return finish(t, mode, chars, "refused", "log", "delivery log not writable: %s"
                      % type(exc).__name__, text)
    except Refused as exc:
        return finish(t, mode, chars, "refused", exc.code, str(exc), text, log=not dry_run)
    if dry_run:
        return finish(t, mode, chars, "dry-run", "dry-run",
                      "would answer %s; nothing sent" % _describe(how, plan), log=False)
    tm = timing()
    try:
        if how == "keys":
            return _answer_keys(t, mode, chars, text, state, plan, tm)
        if how == "free":
            return _answer_free(t, mode, chars, text, state, tm)
        return _answer_multi(t, mode, chars, state, plan, parsed[1], tm)
    except Exception as exc:  # a tmux call failing mid-way: report, never guess
        return finish(t, mode, chars, "failed", "answer-aborted",
                      "error (%s) while answering; check the pane" % type(exc).__name__, text)


def _answer_plan(how, state, parsed):
    """The keys of a plain answer, the toggle digits of a multi select, or None (free text).
    Validation happens here, before anything is sent."""
    if how == "keys":
        return keys_of(state, parsed)
    if how == "multi":
        return multi_toggle_keys(state["ask"], parsed[1])
    return None


def _describe(how, plan):
    if how == "keys":
        return "with key(s) %s" % " ".join(plan)
    if how == "multi":
        return "a multi select (toggles %s)" % " ".join(plan) if plan else "a multi select"
    return "by typing the free text"


def _press(t, keys, tm):
    for key in keys:
        if not send_one(t, key):
            return False
        time.sleep(tm["key_pause"])
    return True


def _answer_keys(t, mode, chars, text, state, keys, tm):
    stale = reread_same(t, state)
    if stale:
        return finish(t, mode, chars, "refused", stale.code, str(stale), text)
    if not _press(t, keys, tm):
        return finish(t, mode, chars, "failed", "key-failed", "a key could not be sent", text)
    status = wait_changed(t, state, tm)
    if status == "answered":
        return finish(t, mode, chars, "answered", "answered", "answer sent", text)
    return finish(t, mode, chars, "unconfirmed", "unconfirmed",
                  "keys sent, the Ask box or prompt is still open; check the pane", text)


def _answer_free(t, mode, chars, text, state, tm):
    ask = state["ask"]
    stale = reread_same(t, state)
    if stale:
        return finish(t, mode, chars, "refused", stale.code, str(stale), text)
    if not _press(t, free_nav_keys(ask), tm):
        return finish(t, mode, chars, "failed", "key-failed", "navigation key failed", text)
    cap, problem = read_pane(t)
    moved = guard.classify_pane(cap) if problem is None else {"kind": "unknown"}
    if moved["kind"] != "ask" or moved["ask"]["cursor"] != ask["type_n"]:
        return finish(t, mode, chars, "refused", "type-row-not-reached",
                      "the highlight did not reach the Type something row; nothing typed", text)
    typed = []
    try:
        for piece in wake.type_chunks(text):
            still_free(t, typed)
            typed.append(piece)
            if not wake.send_keys(plan_of(t), piece, literal=True):
                typed.pop()
                raise Abort("typing failed", typed)
            time.sleep(tm["type_pause"])
        time.sleep(tm["settle"])
        still_free(t, typed)
        if not send_one(t, ENTER):
            raise Abort("Enter could not be sent", typed)
    except Abort as exc:
        removed = take_back(t, "".join(typed), _free_now, "", tm)
        note = "own text taken back" if removed else "own text left in the Type something row"
        return finish(t, mode, chars, "failed", "typing-aborted", "%s; %s" % (exc.reason, note), text)
    status = wait_changed(t, state, tm)
    if status == "answered":
        return finish(t, mode, chars, "answered", "answered", "free text sent", text)
    return finish(t, mode, chars, "unconfirmed", "unconfirmed",
                  "Enter sent, the Ask box is still open; check the pane", text)


def still_free(t, typed):
    """Raises Abort unless the Ask box is still open with the Type something row holding exactly
    what was typed so far (checked before every piece, as still_typing does for the input)."""
    text, problem = read_pane(t)
    if problem:
        raise Abort(problem[1], typed)
    state = guard.classify_pane(text)
    if state["kind"] != "ask" or norm(_free_now(state, text)) != norm("".join(typed)):
        raise Abort("the Ask box changed while typing", typed)


def _free_now(state, text):
    if state["kind"] != "ask":
        return None
    label = state["ask"]["type_label"]
    return "" if norm_label(label) in ("type something", "type something.") else label


def _answer_multi(t, mode, chars, state, toggles, targets, tm):
    ask = state["ask"]
    stale = reread_same(t, state)
    if stale:
        return finish(t, mode, chars, "refused", stale.code, str(stale), None)
    if not _press(t, toggles, tm):
        return finish(t, mode, chars, "failed", "key-failed", "a toggle key could not be sent", None)
    cap, problem = read_pane(t)
    now = guard.classify_pane(cap) if problem is None else {"kind": "unknown"}
    checked = {o["n"] for o in now["ask"]["options"] if o["checked"]} if now["kind"] == "ask" else None
    if checked != set(targets):
        return finish(t, mode, chars, "failed", "multi-mismatch",
                      "the checked boxes are not the wanted set; nothing submitted, box left open", None)
    if not _press(t, ["Right"], tm):
        return finish(t, mode, chars, "failed", "key-failed", "Right could not be sent", None)
    cap, problem = read_pane(t)
    review = guard.classify_pane(cap) if problem is None else {"kind": "unknown"}
    wanted = [o["label"] for o in ask["options"] if o["n"] in targets]
    if review["kind"] != "review" or not review["review"]["answers"] \
            or review["review"]["answers"][-1][1] != wanted or review["review"]["cursor"] != 1:
        return finish(t, mode, chars, "failed", "review-mismatch",
                      "the review page does not show the wanted answer; nothing submitted, left open", None)
    if not _press(t, [ENTER], tm):
        return finish(t, mode, chars, "failed", "key-failed", "Enter could not be sent", None)
    status = wait_changed(t, review, tm)
    if status == "answered":
        return finish(t, mode, chars, "answered", "answered", "multi select submitted", None)
    return finish(t, mode, chars, "unconfirmed", "unconfirmed",
                  "Enter sent, the review is still open; check the pane", None)
