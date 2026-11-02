"""credo_pane_wake.py - shared worker steps of credo-self-reload.py and
credo-self-compact.py: wait until the session's OWN tmux pane is idle and safe, type
a line and press Enter only after verifying it, and wake the session with a "." prompt
plus a bounded fallback timer.

Why the "." - /reload-plugins, /reload-skills and a finished /compact do not start a
model turn, so the session would sit idle. The worker types "." + Enter to start one.

Wake file - <configdir>/credo/self-wake-<session-id> (JSON with "kind": "reload" or
"compact" and details). It is written FIRST, before the worker waits for the idle
pane: from then on ANY new turn counts as woken, and when a turn already started
(file consumed) no "." is typed at all. The UserPromptSubmit hook credo-autonomy-clear.sh consumes it when the next prompt of this
session arrives (any prompt: the ".", a user message, a peer message, a task
notification - every new turn counts as woken) and injects a short note for the agent.
The worker watches the file: gone -> woken, the fallback timer is cancelled. Still
there after `nudge_wait` seconds -> the "." is sent again, but only when the pane is
idle with an empty input field (no turn running: a busy model may start the turn later
than the timer) and the wake file is still pending; a "." still left in the input field
only gets Enter again. At most `max_nudges` re-sends, then the caller reports failure
and the wake file stays for the next prompt.

Pane safety comes from credo_pane_guard (block_on_background=False: background
subagents, shells, scripts, monitors and other background services never block - they
survive a reload and a compact). Every probe re-verifies that the pane belongs to the
target Claude process (credo-self-restart.py pane_owner_error).

Python 3 stdlib only.
"""

import datetime
import json
import os
import re
import subprocess
import time
import urllib.request

import credo_pane_guard as guard

WAKE_TEXT = "."
PANE_RE = re.compile(r"%[0-9]+")
# Claude Code collapses one burst of input (one send of about 800 to 1000 characters, measured
# on Claude Code 2.1.316) into a "[Pasted text #N]" placeholder, which type_and_enter cannot
# confirm against its text. Text for type_and_enter is therefore typed in pieces of at most
# TYPE_CHUNK_CHARS characters, TYPE_PAUSE seconds apart (read as typing, not as a paste). The
# periodic reminder uses send_whole instead: one burst, the placeholder is accepted.
TYPE_CHUNK_CHARS = 200
TYPE_PAUSE = 0.1


class Cancelled(Exception):
    pass


class StepFailed(Exception):
    def __init__(self, status, detail):
        Exception.__init__(self, status)
        self.status, self.detail = status, detail


class Woken(Exception):
    pass


def now_iso():
    return datetime.datetime.now().astimezone().isoformat(timespec="seconds")


def env_float(name, default):
    try:
        return float(os.environ.get(name, default))
    except (TypeError, ValueError):
        return float(default)


def timing(prefix):
    """Poll / recheck / key pause / confirm wait from <prefix>_POLL etc."""
    return {"poll": env_float(prefix + "_POLL", 2.0),
            "recheck": env_float(prefix + "_RECHECK", 1.5),
            "key_pause": env_float(prefix + "_KEY_PAUSE", 0.5),
            "confirm_wait": env_float(prefix + "_CONFIRM_WAIT", 10.0),
            "blocked_notify": env_float(prefix + "_BLOCKED_NOTIFY", 120.0),
            "type_pause": env_float(prefix + "_TYPE_PAUSE", TYPE_PAUSE)}


def wake_path(state, sid):
    return os.path.join(state, "self-wake-%s" % sid)


def norm(s):
    return "".join((s or "").split())


def send_keys(plan, keys, literal=False):
    """The ONLY place that sends keys. Always the resolved own pane."""
    pane = plan["pane"]
    if not PANE_RE.fullmatch(pane or ""):
        raise RuntimeError("refusing to send keys: no valid own pane")
    argv = guard.tmux_base(plan.get("socket")) + ["send-keys", "-t", pane]
    if literal:
        # end-of-options separator first, without it tmux reads a text starting with a dash as an option
        argv += ["-l"] + (["--"] if keys.startswith("-") else []) + [keys]
    else:
        argv += [keys]
    r = subprocess.run(argv, capture_output=True, text=True, timeout=10)
    return r.returncode == 0


class Pane(object):
    """Probes of the own pane with the ownership re-check (background ignored).
    owner_error(pane, socket, pid, start) -> None or the reason; cancelled() -> bool;
    log(msg)."""

    def __init__(self, plan, owner_error, cancelled, log, tim, on_blocked=None):
        self.plan, self.owner_error, self.cancelled, self.log = plan, owner_error, cancelled, log
        self.tim = tim
        self.owner_fail = []
        # on_blocked(reason): called once per wait when a dialog / permission prompt
        # has blocked the pane for tim["blocked_notify"] seconds (early ntfy).
        self.on_blocked = on_blocked

    def owner(self):
        p = self.plan
        return self.owner_error(p["pane"], p.get("socket"), p["target_pid"], p["target_start"])

    def probe(self, expect=None):
        oerr = self.owner()
        if oerr:
            self.owner_fail.append(oerr)
            return False, "pane ownership lost: " + oerr
        return guard.probe_pane(self.plan["pane"], self.plan.get("socket"), expect=expect,
                                block_on_background=False)

    def wait_safe(self, timeout, stop=None):
        """Until idle + empty input + no dialog, confirmed twice. Raises StepFailed
        ("failed: pane ownership" / "failed: not idle"), Cancelled, or Woken when
        stop() turns true meanwhile."""
        ok, reason = guard.wait_until_safe(
            self.probe, timeout, poll=self.tim["poll"], recheck=self.tim["recheck"],
            should_stop=lambda: bool(self.owner_fail) or self.cancelled() or
            bool(stop and stop()),
            on_state=lambda r: self.log("pane state: %s" % r),
            on_blocked=self._blocked, blocked_after=self.tim.get("blocked_notify", 120.0))
        if stop and stop():
            raise Woken()
        if self.owner_fail:
            raise StepFailed("failed: pane ownership", self.owner_fail[0])
        if reason == "cancelled":
            raise Cancelled()
        if not ok:
            raise StepFailed("failed: not idle", reason)
        return reason

    def _blocked(self, reason):
        self.log("pane blocked by a dialog for %gs, user notified, still waiting: %s"
                 % (self.tim.get("blocked_notify", 120.0), reason))
        if self.on_blocked:
            self.on_blocked(reason)


def blocked_text(tool, pane):
    """ntfy body for a dialog that blocks a self-* worker. Never carries the dialog
    text (the push goes to a public topic)."""
    return ("A dialog or permission prompt in tmux pane %s blocks %s - please answer it. "
            "The worker keeps waiting and continues by itself once it is closed."
            % (pane, tool))


def send_key_list(plan, keys):
    """Several non-literal keys in one send-keys call. Always the resolved own pane."""
    pane = plan["pane"]
    if not PANE_RE.fullmatch(pane or "") or not keys:
        return False
    argv = guard.tmux_base(plan.get("socket")) + ["send-keys", "-t", pane] + list(keys)
    r = subprocess.run(argv, capture_output=True, text=True, timeout=10)
    return r.returncode == 0


def take_back(pane, text):
    """After an abort before Enter, remove the own typed `text` from the input field -
    only when the field ends with it (at most one stray character in front), the pane
    still belongs to the target, is not in copy mode and shows no dialog, picker or menu (keys would land there). A busy
    session is fine (typing only edits the input). Anything else stays untouched, so
    user input is never deleted. Returns True when removed."""
    plan = pane.plan
    if pane.owner():
        return False
    info = guard.pane_info(plan["pane"], plan.get("socket"))
    if info is None or info["in_mode"] or info["dead"]:
        return False
    cap = guard.capture(plan["pane"], plan.get("socket"))
    content = guard.input_content(cap)
    if content is None or not guard.own_text_at_end(content, text):
        pane.log("own text left as it is: the input field no longer ends with it")
        return False
    safe, why = guard.assess(cap, expect=content, block_on_background=False)
    if not safe and not why.startswith("busy"):
        return False
    if send_key_list(plan, ["BSpace"] * len(text)):
        pane.log("took the own text back out of the input field: %s" % text)
        return True
    return False


def clear_leftover(pane):
    """Owner rule: fewer than 2 visible characters count as an empty input field, but such
    a leftover is removed before anything is typed: End (to the end of the field), then one
    BSpace per character of the leftover. The field is captured again. True when it is empty
    and idle now (nothing to remove, or removed), False when text is still there, in which
    case the caller stops and types nothing."""
    plan = pane.plan
    cap = guard.capture(plan["pane"], plan.get("socket"))
    count = guard.leftover(cap)
    if count is None:
        return guard.assess(cap, block_on_background=False)[0]
    if not (send_key_list(plan, ["End"]) and send_key_list(plan, ["BSpace"] * count)):
        return False
    pane.log("removed a leftover of %d character(s) from the input field" % count)
    cap = guard.capture(plan["pane"], plan.get("socket"))
    return guard.assess(cap, block_on_background=False)[0]


def type_chunks(text, size=TYPE_CHUNK_CHARS):
    """Split `text` into runs of `size` characters, never splitting a character."""
    return [text[i:i + size] for i in range(0, len(text), size)]


def type_text(pane, text, done):
    """Type `text` literally, piece by piece (type_chunks), TYPE_PAUSE apart. A piece is
    appended to `done` BEFORE it is sent. An abort inside the send (SIGTERM while tmux runs)
    may already have typed it, and take_back only removes what the field really ends with.
    A send that tmux reports as failed is taken off again. Raises StepFailed when a piece
    could not be sent, Cancelled when the worker is cancelled between two pieces."""
    for i, piece in enumerate(type_chunks(text)):
        if i:
            time.sleep(pane.tim.get("type_pause", TYPE_PAUSE))
        if pane.cancelled():
            raise Cancelled()
        done.append(piece)
        if not send_keys(pane.plan, piece, literal=True):
            done.pop()
            raise StepFailed("failed: send-keys", "typing failed after %d piece(s)" % len(done))


def type_and_enter(pane, text, before_enter=None):
    """Type `text` literally in pieces (type_text), run the full check again expecting
    exactly it, then Enter. A leftover in the field is removed first (clear_leftover);
    if text is still there, StepFailed before anything is typed. before_enter() runs
    right before Enter.
    Returns True when the input visibly changed after Enter within the confirm wait,
    False when unconfirmed. Raises StepFailed (no Enter sent), Cancelled or Woken; on any
    abort between typing and Enter the own text is taken back (take_back: only when the
    field ends with it), so it never stays in the input field."""
    plan, log = pane.plan, pane.log
    if pane.cancelled():
        raise Cancelled()
    if not clear_leftover(pane):
        raise StepFailed("failed: not idle", "the input field still holds text after "
                         "removing the leftover")
    done = []  # pieces sent so far (an abort may leave exactly these behind)
    try:
        type_text(pane, text, done)
        log("typed: %s" % text)
        time.sleep(pane.tim["key_pause"])
        safe, why = pane.probe(expect=text)
        if not safe:
            # someone typed in between, a dialog opened, ...: never press Enter
            raise StepFailed("failed: typed text not confirmed", why)
        if pane.cancelled():
            raise Cancelled()
        if before_enter:
            before_enter()
        entered = send_keys(plan, "Enter")
    except (StepFailed, Cancelled, Woken):
        if done:
            take_back(pane, "".join(done))
        raise
    if not entered:
        take_back(pane, text)
        raise StepFailed("failed: send-keys Enter", "Enter after %s failed" % text)
    log("Enter sent after %s" % text)
    end = time.time() + pane.tim["confirm_wait"]
    while time.time() < end:
        seen = guard.input_content(guard.capture(plan["pane"], plan.get("socket")))
        if seen is not None and norm(seen) != norm(text):
            return True
        time.sleep(0.2)
    log("input did not visibly change after Enter (%s)" % text)
    return False


def send_whole(pane, text):
    """Periodic reminder delivery: `text` in ONE burst (one literal send-keys), then the
    pane settles for the key pause, then Enter. Claude Code shows a fast burst as a paste
    placeholder ("[Pasted text #1]" or "[Pasted text #1 +11 lines]") or as text; either
    rendering is accepted, the text itself is not compared. The caller has waited for an idle
    pane. The field must be empty (clear_leftover, as in type_and_enter). Before Enter the
    pane must still show an input box without dialog, busy turn or background prompt, so
    Enter never answers a dialog.
    Failures: before the burst nothing is typed; after it the text stays in the field and is
    neither removed nor submitted (the next attempt skips a field that holds text). A stop
    during the settle still sends Enter, so the line is not left behind by a stop alone.
    Raises StepFailed (Enter not sent) or Cancelled (raised after Enter, if at all)."""
    plan, log = pane.plan, pane.log
    if pane.cancelled():
        raise Cancelled()
    if not clear_leftover(pane):
        raise StepFailed("failed: not idle", "the input field still holds text")
    if not send_keys(plan, text, literal=True):
        raise StepFailed("failed: send-keys", "typing the reminder failed, nothing typed")
    log("typed %d characters in one burst" % len(text))
    stopped = None
    try:
        time.sleep(pane.tim["key_pause"])
    except Cancelled as exc:
        stopped = exc
    # Best effort (owner Q56): the input field is NOT read back after the burst. Reading it
    # depends on the screen layout (box lines, height, pane size) and a failed read left the
    # text stuck. Only a visible dialog withholds Enter, so Enter never answers a dialog.
    cap = guard.capture(plan["pane"], plan.get("socket")) or ""
    tail = [guard.strip_ansi(l) for l in cap.rstrip("\n").split("\n")[-guard.NO_BOX_SCAN:]]
    own = "".join(text.split())
    for line in tail:
        row = "".join(line.split()).lstrip("❯>")
        if row and row in own:
            continue  # a row of the typed text itself (it may quote dialog words)
        if guard.PERMISSION_RE.search(line) or guard.DIALOG_RE.search(line):
            raise StepFailed("failed: dialog open", "a dialog opened, Enter withheld: %s"
                             % line.strip()[:80])
    if not send_keys(plan, "Enter"):
        raise StepFailed("failed: send-keys Enter", "Enter after the reminder failed")
    log("Enter sent after the reminder burst")
    if stopped:
        raise stopped
    return True


def write_json(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = "%s.tmp.%d" % (path, os.getpid())
    with open(tmp, "w") as fh:
        json.dump(data, fh, indent=2)
    os.replace(tmp, path)


def wait_for_turn(path, seconds, cancelled):
    """True when the wake file `path` is consumed (a new turn started) in time."""
    end = time.time() + max(0.0, seconds)
    while True:
        if not os.path.exists(path):
            return True
        if cancelled():
            raise Cancelled()
        if time.time() >= end:
            return False
        time.sleep(min(0.2, max(0.0, end - time.time())))


def nudge(pane, path):
    """Send the "." again when the pane allows it. Returns a short result text."""
    plan = pane.plan
    content = guard.input_content(guard.capture(plan["pane"], plan.get("socket")))
    if content is not None and norm(content) == norm(WAKE_TEXT):
        safe, why = pane.probe(expect=WAKE_TEXT)
        if safe and os.path.exists(path):
            send_keys(plan, "Enter")
            return "Enter sent again (the \".\" was still in the input field)"
        return "not re-sent (%s)" % why
    # idle twice (no turn running) and the wake file still pending
    safe, why = pane.probe()
    if not safe:
        return "not re-sent (%s)" % why
    time.sleep(pane.tim["recheck"])
    safe, why = pane.probe()
    if not safe or not os.path.exists(path):
        return "not re-sent (%s)" % (why if not safe else "the turn started meanwhile")

    try:
        type_dot(pane, path)
    except Woken:
        return "not re-sent (the turn started meanwhile)"
    return "\".\" re-sent"


def type_dot(pane, path):
    """Type "." + Enter while the wake file is pending. The file is checked again as
    the very last step before Enter. When a turn started meanwhile (file consumed,
    e.g. during the typing window or the pre-Enter check), the "." is taken back
    (only when the input holds exactly it) and Woken is raised instead of any
    failure; with the file still pending a failed step stays a failure."""
    def still_pending():
        if not os.path.exists(path):
            raise Woken()

    try:
        type_and_enter(pane, WAKE_TEXT, before_enter=still_pending)
    except (StepFailed, Woken):
        if os.path.exists(path):
            raise
        take_back(pane, WAKE_TEXT)
        raise Woken()


def wake(pane, path, data, timeout, nudge_wait, max_nudges, on_nudge=None):
    """Write the wake file `path` (data + "written") first - from now on ANY new turn
    of the session counts as woken -, wait for idle, type "." + Enter, then the
    fallback loop. No "." at all when a turn started before (wake file consumed).
    Returns the number of re-sends when a new turn started; raises
    StepFailed("failed: no new turn after N re-sends") otherwise (the wake file stays
    for the next prompt), StepFailed from the pane steps, or Cancelled."""
    payload = dict(data)
    payload["written"] = now_iso()
    write_json(path, payload)

    def consumed():
        return not os.path.exists(path)

    try:
        pane.wait_safe(timeout, stop=consumed)
        type_dot(pane, path)
    except Woken:
        pane.log("a new turn started before the \".\" was needed; nothing sent")
        return 0
    nudges = 0
    while True:
        if wait_for_turn(path, nudge_wait, pane.cancelled):
            pane.log("new turn started; fallback timer cancelled")
            return nudges
        if nudges >= max_nudges:
            raise StepFailed("failed: no new turn after %d re-sends" % nudges,
                             "the wake file was never consumed")
        nudges += 1
        result = nudge(pane, path)
        pane.log("no new turn within %gs: %s (re-send %d of %d)"
                 % (nudge_wait, result, nudges, max_nudges))
        if on_nudge:
            on_nudge(nudges)


SELF_TOOLS = ("reload", "compact")


def finished(status):
    return status in ("woken", "cancelled") or str(status or "").startswith("failed")


def other_pending(state, sid, me):
    """(name, pid) of a live, unfinished worker of the OTHER self tool (self-reload vs
    self-compact) of this session, else None. Both type into the same pane and share
    the wake file, so they never run at the same time."""
    for other in SELF_TOOLS:
        if other == me:
            continue
        try:
            with open(os.path.join(state, "self-%s-%s.json" % (other, sid))) as fh:
                m = json.load(fh)
        except (OSError, ValueError):
            continue
        if not isinstance(m, dict) or finished(m.get("status")):
            continue
        pid = m.get("worker_pid")
        if not isinstance(pid, int) or pid <= 1:
            continue
        try:
            with open("/proc/%d/cmdline" % pid, "rb") as fh:
                argv = [a.decode("utf-8", "replace") for a in fh.read().split(b"\0") if a]
        except OSError:
            continue
        if "_worker" in argv and any(a.endswith("credo-self-%s.py" % other) for a in argv):
            return "self-" + other, pid
    return None


def drop_wake(path):
    """Remove a pending wake file (on cancel). True when one was removed."""
    try:
        os.remove(path)
        return True
    except OSError:
        return False


def ntfy(title, body, override_var, config_get, log):
    """The one ntfy push of the self-* helpers. The variable `override_var` ("off" or
    a full URL) overrides; else personal.ntfy_topic (+ personal.ntfy_server, default
    ntfy.sh) via config_get(key). The url is never logged (the topic is a secret)."""
    url = os.environ.get(override_var)
    if url == "off":
        log("ntfy disabled: %s - %s" % (title, body))
        return
    if not url:
        topic = config_get("personal.ntfy_topic")
        if not topic:
            log("ntfy not configured: %s - %s" % (title, body))
            return
        server = config_get("personal.ntfy_server") or "https://ntfy.sh"
        url = server.rstrip("/") + "/" + topic
    req = urllib.request.Request(url, data=body.encode("utf-8"), method="POST",
                                 headers={"Title": title, "Priority": "high"})
    try:
        urllib.request.urlopen(req, timeout=15).read()
        log("ntfy sent: %s" % title)
    except Exception as exc:
        log("ntfy failed: %s" % type(exc).__name__)
