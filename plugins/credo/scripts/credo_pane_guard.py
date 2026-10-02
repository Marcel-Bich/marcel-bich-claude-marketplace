"""credo_pane_guard.py - shared tmux pane guard for credo-self-compact.py and
credo-self-restart.py.

Decides from a `tmux capture-pane -p -e` snapshot whether the Claude Code TUI in a
pane is idle and safe to receive keys - no busy spinner, the prompt input field is
EMPTY (or holds exactly an expected line, for the check right before Enter), no
dialog / Ask question / permission prompt / menu is open, and (only with
block_on_background=True, the default, as credo-self-restart.py uses it) the footer
under the input box shows no background shells, monitors or background agents still
running. credo-self-compact.py passes block_on_background=False: background work
survives /compact, so the footer rows are ignored there (they never hide the input box,
which is found bottom-up as the last rule + marker row + rule). The rule is
conservative. Anything not positively recognised as "idle with an empty input" is
NOT safe. Callers wait and re-check; they never capture and retype user input.

Pure functions (no I/O) - strip_ansi, styled_chars, find_input_box, input_content,
assess, wait_until_safe. tmux helpers - tmux_base, pane_info, capture, probe_pane.

Recognised layout (Claude Code 2.1.x) - the input box is a full-width rule line of
"─", the input line starting with "❯" (U+276F, followed by a space or NBSP), any
wrapped continuation lines, and a closing rule line. The older bordered box
("╭─╮" / "│ > │" / "╰─╯") is recognised too. An empty input shows nothing after the
marker, or only the dimmed placeholder / prompt suggestion (SGR 2, optionally its
first character inverted as the cursor), which is not input.

Python 3 stdlib only.
"""

import re
import subprocess
import time

RULE_CHARS = set("─━╭╮╰╯")
MARKERS = ("❯", ">")
# Spinner frames of the Claude Code busy line ("✻ Brewing<U+2026> (12s · ↓ 300 tokens)").
# "●" is deliberately absent: it prefixes normal transcript messages.
SPINNER_LINE_RE = re.compile(
    r"^\s*[·✢✳✶✻✽*]\s+\S.*(\u2026|\.\.\.\s*\(|\(\s*\d+(?:\.\d+)?\s*[smh]\b|esc to interrupt"
    r"|tokens\s*\))")
BUSY_ANY_RE = re.compile(r"esc to interrupt|Compacting conversation|ctrl\+b to run in "
                         r"background", re.I)
# Hints and prompts that only exist while a dialog, picker or menu is open, or an
# exit is half confirmed. Checked from a few lines above the input box down to the
# bottom of the pane (the transcript further up is ignored so a message that merely
# quotes these words does not block forever).
DIALOG_RE = re.compile(
    r"Enter to (select|confirm|submit|continue|approve)|Esc to (cancel|close|exit|go back)"
    r"|to navigate|to switch|again to (exit|close)|Do you want to|Would you like to"
    r"|\(y/n\)|Press Enter|Ready to code\?|Type something\.?"
    r"|^\s*[❯>]\s*\d+\.\s", re.I)
# Background work shown in the footer under the input box while it runs: a shell
# count ("1 shell", "3 shells", also inside the status line) and the background agent
# list, one row per agent starting with "◯" (U+25EF) and the agent type. Only the
# footer is scanned, so a transcript message quoting "1 shell" does not block.
BACKGROUND_RE = re.compile(
    r"(^|[\s·|])\d+\s+(shells?|bash(es)?|background (tasks?|agents?|jobs?)|local agents?)\b"
    r"|^\s*◯\s+\S", re.I)
# Dim text that is real input, not a placeholder (paste and image references).
INPUT_TOKEN_RE = re.compile(r"\[(Pasted text|Image|Pasted)|\+\d+ lines")

CSI_RE = re.compile(r"\x1b\[([0-9;:?<>=]*)[ -/]*([@-~])")
OSC_RE = re.compile(r"\x1b\][^\x07\x1b]*(\x07|\x1b\\)")
ANSI_RE = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(\x07|\x1b\\)|\x1b[@-_]")

BUSY_SCAN_ABOVE = 25
DIALOG_SCAN_ABOVE = 6
MAX_BOX_LINES = 20


def strip_ansi(text):
    return ANSI_RE.sub("", text or "")


def _apply_sgr(params, dim, inv):
    parts = params.split(";") if params else ["0"]
    k = 0
    while k < len(parts):
        head = parts[k].split(":")[0]
        n = int(head) if head.isdigit() else (0 if head == "" else -1)
        if n == 0:
            dim = inv = False
        elif n == 2:
            dim = True
        elif n == 22:
            dim = False
        elif n == 7:
            inv = True
        elif n == 27:
            inv = False
        elif n in (38, 48, 58) and ":" not in parts[k]:
            # extended colour: skip its arguments so "38;2;..." is never read as dim
            if k + 1 < len(parts) and parts[k + 1] == "5":
                k += 2
            elif k + 1 < len(parts) and parts[k + 1] == "2":
                k += 4
        k += 1
    return dim, inv


def styled_chars(line):
    """[(char, dim, inverse)] for one captured line with SGR escapes."""
    out = []
    dim = inv = False
    i = 0
    while i < len(line):
        c = line[i]
        if c == "\x1b":
            m = CSI_RE.match(line, i)
            if m:
                if m.group(2) == "m":
                    dim, inv = _apply_sgr(m.group(1), dim, inv)
                i = m.end()
                continue
            m = OSC_RE.match(line, i)
            i = m.end() if m else i + 2
            continue
        out.append((c, dim, inv))
        i += 1
    return out


def is_rule(plain):
    """A box rule: starts with >= 10 rule chars and ends with one. The top rule may
    embed a label such as the session name ("──── my-session ─")."""
    s = plain.strip()
    head = len(s) - len(s.lstrip("".join(RULE_CHARS)))
    return head >= 10 and s[-1] in RULE_CHARS


def _strip_border(chars):
    """Drop a leading/trailing "│" border (old bordered box) plus whitespace."""
    while chars and chars[0][0].isspace():
        chars = chars[1:]
    if chars and chars[0][0] == "│":
        chars = chars[1:]
        while chars and chars[0][0].isspace():
            chars = chars[1:]
    while chars and chars[-1][0].isspace():
        chars = chars[:-1]
    if chars and chars[-1][0] == "│":
        chars = chars[:-1]
    return chars


def find_input_box(lines):
    """(top, bottom) indices of the bottom-most input box, or None.
    Takes the captured lines (may contain escapes)."""
    plain = [strip_ansi(l) for l in lines]
    for top in range(len(plain) - 2, -1, -1):
        if not is_rule(plain[top]):
            continue
        first = _strip_border(styled_chars(lines[top + 1]))
        if not first or first[0][0] not in MARKERS:
            continue
        for bottom in range(top + 2, min(len(plain), top + 2 + MAX_BOX_LINES)):
            if is_rule(plain[bottom]):
                return top, bottom
    return None


def _content_chars(lines, box):
    top, bottom = box
    rows = []
    for idx in range(top + 1, bottom):
        chars = _strip_border(styled_chars(lines[idx]))
        if idx == top + 1:
            chars = chars[1:]  # the prompt marker
        rows.append(chars)
    return rows


def input_content(text):
    """Text typed into the input box (rows joined, whitespace collapsed), "" when
    empty or only a placeholder, None when no input box is visible."""
    lines = (text or "").split("\n")
    box = find_input_box(lines)
    if box is None:
        return None
    rows = _content_chars(lines, box)
    if len(rows) == 1 and _is_placeholder(rows[0]):
        return ""
    joined = " ".join("".join(c for c, _, _ in r) for r in rows)
    return " ".join(joined.split())


def _is_placeholder(chars):
    """True when the row holds no input: only whitespace, or only dimmed placeholder
    text (at most its first character inverted as the cursor)."""
    vis = [(i, c, d, v) for i, (c, d, v) in enumerate(chars) if not c.isspace()]
    if not vis:
        return True
    text = "".join(c for _, c, _, _ in vis)
    if INPUT_TOKEN_RE.search(text):
        return False
    inverted = [x for x in vis if x[3]]
    plain = [x for x in vis if not x[2] and not x[3]]
    dimmed = [x for x in vis if x[2] and not x[3]]
    if plain or not dimmed or len(inverted) > 1:
        return False
    return not inverted or inverted[0] is vis[0]


def _norm(s):
    return "".join((s or "").split())


def assess(text, expect=None, block_on_background=True):
    """(safe, reason) for one capture-pane snapshot. safe only when an input box is
    visible, no busy indicator is shown, no dialog, picker or menu hint is visible near
    the box, the footer under the box shows no background shells / agents (only when
    block_on_background, the self-restart case; self-compact passes False because
    background work survives /compact), and the input is empty (one row, nothing or a
    placeholder). With `expect` the input must
    instead hold exactly that text (whitespace and row wraps ignored) - the full check
    right before pressing Enter."""
    lines = (text or "").rstrip("\n").split("\n")
    box = find_input_box(lines)
    if box is None:
        return False, "no empty prompt input box visible (dialog, menu or not Claude Code)"
    top, bottom = box
    plain = [strip_ansi(l) for l in lines]
    for idx in range(max(0, top - BUSY_SCAN_ABOVE), top):
        if SPINNER_LINE_RE.search(plain[idx]) or BUSY_ANY_RE.search(plain[idx]):
            return False, "busy: %s" % plain[idx].strip()[:80]
    for idx in range(max(0, top - DIALOG_SCAN_ABOVE), len(plain)):
        if top < idx < bottom:
            continue  # the input rows themselves are judged below
        if DIALOG_RE.search(plain[idx]):
            return False, "dialog or menu open: %s" % plain[idx].strip()[:80]
    if block_on_background:
        for idx in range(bottom + 1, len(plain)):
            if BACKGROUND_RE.search(plain[idx]):
                return False, "background work running: %s" % plain[idx].strip()[:80]
    rows = _content_chars(lines, box)
    if expect is not None:
        seen = " ".join("".join(c for c, _, _ in r) for r in rows)
        if _norm(seen) != _norm(expect):
            return False, "input does not hold exactly the expected text"
        return True, "idle, input holds the expected text"
    if len(rows) != 1:
        return False, "input has %d rows (text typed)" % len(rows)
    if not _is_placeholder(rows[0]):
        return False, "input not empty (user text present)"
    return True, "idle, input empty"


def wait_until_safe(probe, timeout, poll=2.0, recheck=1.5, sleep=time.sleep,
                    clock=time.monotonic, should_stop=None, on_state=None):
    """Poll probe() -> (safe, reason) until two consecutive probes `recheck` seconds
    apart are both safe. Returns (True, reason) right after the second safe probe,
    (False, "cancelled") when should_stop() turns true, (False, "timeout ...") after
    `timeout` seconds. on_state(reason) is called whenever the reason changes."""
    end = clock() + max(0.0, float(timeout))
    last = None
    while True:
        if should_stop and should_stop():
            return False, "cancelled"
        safe, reason = probe()
        if safe:
            sleep(recheck)
            if should_stop and should_stop():
                return False, "cancelled"
            safe, reason = probe()
            if safe:
                return True, reason + " (confirmed twice)"
        if on_state and reason != last:
            on_state(reason)
        last = reason
        if clock() >= end:
            return False, "timeout after %gs (last state: %s)" % (float(timeout), reason)
        sleep(poll)


# --- tmux helpers ---------------------------------------------------------------

def socket_from_tmux_env(value):
    """Server socket path from a TMUX value ("<socket>,<pid>,<session>"), or None."""
    sock = (value or "").split(",")[0]
    return sock if sock.startswith("/") else None


def tmux_base(socket=None):
    return ["tmux"] + (["-S", socket] if socket else [])


def _run(argv, timeout=10):
    try:
        r = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.SubprocessError):
        return None
    return r.stdout if r.returncode == 0 else None


def pane_info(pane, socket=None):
    """{"pane": id, "pid": int, "in_mode": bool, "dead": bool} or None."""
    out = _run(tmux_base(socket) + ["display-message", "-p", "-t", pane,
                                    "#{pane_id}\t#{pane_pid}\t#{pane_in_mode}\t#{pane_dead}"])
    if not out:
        return None
    parts = out.strip("\n").split("\t")
    if len(parts) != 4 or parts[0] != pane or not parts[1].isdigit():
        return None
    return {"pane": parts[0], "pid": int(parts[1]), "in_mode": parts[2] not in ("0", ""),
            "dead": parts[3] not in ("0", "")}


def capture(pane, socket=None):
    """Visible pane text with SGR attributes (capture-pane -p -e), or None."""
    return _run(tmux_base(socket) + ["capture-pane", "-p", "-e", "-t", pane])


def probe_pane(pane, socket=None, expect=None, block_on_background=True):
    """(safe, reason) for the live pane: not in copy mode, not dead, and assess()
    (with `expect`: the input must hold exactly that text; block_on_background as in
    assess())."""
    info = pane_info(pane, socket)
    if info is None:
        return False, "pane %s unavailable" % pane
    if info["dead"]:
        return False, "pane %s is dead" % pane
    if info["in_mode"]:
        return False, "pane %s is in tmux copy/view mode" % pane
    text = capture(pane, socket)
    if text is None:
        return False, "capture of pane %s failed" % pane
    return assess(text, expect, block_on_background)
