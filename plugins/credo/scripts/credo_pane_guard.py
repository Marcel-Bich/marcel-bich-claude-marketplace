"""credo_pane_guard.py - shared tmux pane guard for credo-self-compact.py and
credo-self-restart.py.

Decides from a `tmux capture-pane -p -e` snapshot whether the Claude Code TUI in a
pane is idle and safe to receive keys - no busy spinner, the prompt input field is
EMPTY (fewer than EMPTY_BELOW visible characters, or holds exactly an expected line, for
the check right before Enter), no
dialog / Ask question / permission prompt / menu is open, and (only with
block_on_background=True, the default, as credo-self-restart.py uses it) the footer
under the input box shows no background shells, monitors or background agents still
running. credo-self-compact.py and credo-self-reload.py pass block_on_background=False: background work
survives /compact, so the footer rows are ignored there (they never hide the input box,
which is found bottom-up as the last rule + marker row + rule). The rule is
conservative. Anything not positively recognised as "idle with an empty input" is
NOT safe. Callers wait and re-check; they never capture and retype user input.

No input box visible -> the reason is classified from the bottom of the pane:
"permission prompt open, waiting for the user: ..." (also a background agent's
permission prompt, which Claude Code shows in the main pane in place of the input box
while the main agent keeps running turns underneath), "no input box, dialog or menu
open: ...", or the generic "no empty prompt input box visible ...". wait_until_safe()
calls on_blocked(reason) once per wait when a classified user-only state (permission
prompt, dialog or menu; not the generic reason) lasts `blocked_after` seconds (the
callers send one early ntfy push per blocked wait and keep waiting).

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
import unicodedata

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
# A permission prompt (also one raised by a background agent, which Claude Code shows
# in the main pane in place of the input box while the main agent keeps running turns
# underneath). Only used to name the reason when no input box is visible.
PERMISSION_RE = re.compile(
    r"Do you want to (proceed|make this edit|create|allow)|requires confirmation"
    r"|Yes, and don't ask again|to stop background agents", re.I)
NO_BOX_SCAN = 30
# Scrollback rows read above the visible pane (tmux capture-pane -S -N). Only the top search of a
# dialog reads them: a box taller than the pane has its top above the visible area.
SCROLLBACK_ROWS = 500
REFUSAL_UNFIT = "dialog-does-not-fit"
REFUSAL_INVISIBLE = "invisible-characters"
REVIEW_TABS_RE = re.compile(r"^\s*←.*✔ Submit")

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
# Most rows of text the box may hold between its rules. Claude Code shows the input field up
# to about half the pane height minus 5 rows and scrolls a longer text (measured on Claude Code
# 2.1.316 under tmux: 10 rows at 30 pane rows, 15 at 40, 21 at 53), so a long text at 53 rows
# is 23 lines high. 60 rows cover panes up to about 130 rows.
MAX_BOX_LINES = 60


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
    # the exact text, also a single character: nudge and take_back compare against it
    # (the two-character rule applies to the idle check in assess() only)
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


# Owner rule (all tmux inputs): fewer visible (non-whitespace) characters than this in the
# input field count as an empty field for the idle check. A stray character is never
# submitted together with a command (expect= stays exact).
EMPTY_BELOW = 2


def _empty(rows):
    """True when the input field counts as empty: fewer than EMPTY_BELOW visible
    characters in all, or one row that holds only a placeholder."""
    if sum(1 for r in rows for c, _, _ in r if not c.isspace()) < EMPTY_BELOW:
        return True
    return len(rows) == 1 and _is_placeholder(rows[0])


def _norm(s):
    return "".join((s or "").split())


def own_text_at_end(content, text):
    """True when the input `content` is `text` at its end, with at most one visible
    character in front of it (the empty-input rule). Used to take back the own typed text
    after an abort: only that text is removed, the stray character stays."""
    c, t = _norm(content), _norm(text)
    return bool(t) and c.endswith(t) and len(c) - len(t) < EMPTY_BELOW


def leftover(text):
    """Number of characters to delete from the input field when it holds a leftover: at
    least one character and fewer than EMPTY_BELOW visible ones (a stray character the
    tools remove before typing). None when no input box is visible, the field is empty, or
    it holds text. Whitespace at the edges of a row is not visible in a capture and is not
    counted."""
    lines = (text or "").split("\n")
    box = find_input_box(lines)
    if box is None:
        return None
    rows = [_body(r) for r in _content_chars(lines, box)]
    count = sum(len(r) for r in rows)
    visible = sum(1 for r in rows for c, _, _ in r if not c.isspace())
    if count == 0 or visible >= EMPTY_BELOW:
        return None
    return count


def _body(chars):
    """A row without its leading whitespace (the blank after the prompt marker)."""
    i = 0
    while i < len(chars) and chars[i][0].isspace():
        i += 1
    return chars[i:]


def _no_box_reason(lines):
    """Why no input box is visible, as specific as the bottom of the pane allows. A
    permission prompt is named as such (it waits for the user, so polling alone never
    clears it - typically a background agent's tool call asking for approval)."""
    plain = [strip_ansi(l).strip() for l in lines[-NO_BOX_SCAN:]]
    for line in plain:
        if PERMISSION_RE.search(line):
            return "permission prompt open, waiting for the user: %s" % line[:80]
    for line in plain:
        if DIALOG_RE.search(line):
            return "no input box, dialog or menu open: %s" % line[:80]
    return "no empty prompt input box visible (dialog, menu or not Claude Code)"


class Capture(str):
    """A visible-pane capture. window is the same capture with its scrollback above it (see
    with_window); classify_pane reads the dialogs from the window and the input field from the visible
    text only, so an old input box in the scrollback is never taken for the current one."""
    window = None


def with_window(text, window):
    cap = Capture(text)
    cap.window = window
    return cap


def window_of(text):
    return getattr(text, "window", None)


# --- AskUserQuestion box, review page and permission prompt -------------------------
# Layout measured on a real pane (Claude Code 2.1.316): a rule, a header row with a tab
# marker (box for an unanswered question, crossed box for multi select), the question,
# the numbered options (the highlighted one starts with the marker), a description row
# under each option, the "Type something" row (always the option before the rule), a rule,
# "Chat about this" and the footer. Multi select adds "[ ]" / "[✔]" boxes to the options.
# The detector needs the footer AND the chat row AND the numbered options 1..K, so
# DIALOG_RE hits alone (a picker, a permission prompt, a transcript quote) never count.
# A dialog counts only as the LAST block of the pane (nothing but blank rows below its
# footer), and only while no input box is drawn. Dialog-shaped rows above a visible input
# box make the pane unknown (fail closed, see classify_pane and _dialog_above).
# The box is read from its top rule to its footer, and that whole block is kept (block, the
# rows show prints verbatim) with the digest rows (digest_rows). The top rule is the topmost rule
# whose next row is the header or the title (see _dialog_top); a second rule row inside the block
# refuses the box (_rules_in), so a rule drawn inside the command cannot hide the rows above it.
# The footer may carry extra hints between the navigation and the cancel part (measured:
# "ctrl+g to edit in VS Code" in an IDE session), and tabbed boxes (several questions) say
# "Tab/Arrow keys to navigate" instead of "↑/↓ to navigate" (measured on 2.1.316).
ASK_FOOTER_RE = re.compile(
    r"^\s*Enter to select\s+·\s+(?:↑/↓|Tab/Arrow keys) to navigate\s+(?:·\s+.+?\s+)?·\s+Esc to cancel\s*$")
ASK_HEADER_RE = re.compile(r"[☐☒]\s+([^\s].*?)(?:\s{2,}|\s*$)")
# An option row: at most two spaces of indent, the marker on the highlighted row, the number,
# an optional checkbox (multi select). Description rows are indented five spaces and never
# match, so a description that starts with a digit does not count as an option.
ASK_OPTION_RE = re.compile(r"^\s{0,2}(❯?)\s?(\d{1,2})\. (?:\[([ ✔])\] )?(\S.*?)\s*$")
CHAT_RE = re.compile(r"^\s*(\d{1,2})\. Chat about this\s*$")
REVIEW_HEAD_RE = re.compile(r"^\s*Review your answers\s*$")
REVIEW_READY_RE = re.compile(r"^\s*Ready to submit your answers\?\s*$")
REVIEW_ANSWER_RE = re.compile(r"^\s*●\s+(\S.*?)\s*$")
REVIEW_VALUE_RE = re.compile(r"^\s*→\s+(\S.*?)\s*$")
REVIEW_FOOTER_RE = re.compile(r"^\s*(Enter to |Esc to )")
# A slash-command menu under the input box ("  /compact   Clear history ...").
MENU_ROW_RE = re.compile(r"^\s+/[A-Za-z][\w-]*\s{2,}\S")
# The dashed separator inside a permission prompt, around the command text.
SEPARATOR_RE = re.compile(r"^\s*[╌╍┄┈]+\s*$")


def _options(rows):
    """Numbered option rows of `rows`, in order: n, cursor (the marker is on the row),
    checked (None without a checkbox, else bool), label and desc (the text indented under the
    option, up to the next option)."""
    out = []
    for row in rows:
        m = ASK_OPTION_RE.match(row)
        if m:
            out.append({"n": int(m.group(2)), "cursor": m.group(1) == "❯",
                        "checked": None if m.group(3) is None else m.group(3) == "✔",
                        "label": m.group(4), "desc": []})
        elif out and row.strip():
            out[-1]["desc"].append(row.strip())
    for opt in out:
        opt["desc"] = " ".join(opt["desc"])
    return out


def _cursor_n(opts):
    """The n of the single highlighted option, else None."""
    marked = [o["n"] for o in opts if o["cursor"]]
    return marked[0] if len(marked) == 1 else None


def _prev_nonblank(rows, idx, limit=4):
    for j in range(idx - 1, max(-1, idx - 1 - limit), -1):
        if rows[j].strip():
            return j
    return None


def _next_nonblank(rows, idx, limit=4):
    for j in range(idx + 1, min(len(rows), idx + 1 + limit)):
        if rows[j].strip():
            return j
    return None


def _plain_rows(lines):
    return [strip_ansi(line).rstrip() for line in lines]


def _only_blank_after(rows, idx):
    """True when no row below idx holds text: the dialog is the last block of the pane."""
    return all(not rows[j].strip() for j in range(idx + 1, len(rows)))


def _block(rows, top, end):
    """Every non-blank row from top to end (inclusive), exactly as drawn (rstripped only)."""
    return [rows[i] for i in range(top, end + 1) if rows[i].strip()]


CURSOR_MARK_RE = re.compile(r"^(\s*)❯")
CHECK_RE = re.compile(r"\[[ ✔x]\]")
TAB_MARK_RE = re.compile(r"[☐☒]")


def _digest_rows(block, type_n=None):
    """The block rows for the digest: whitespace collapsed, and left out what the owner's
    answer itself changes - the cursor marker, the checkbox and tab states, and the text of the
    Type something row (typed free text). The footer (the last row, when it is a dialog footer) is
    left out as well: its key hints follow the highlight (measured live: the "ctrl+g to edit in
    VS Code" hint appears only while the Type something row is highlighted), so it is shown
    verbatim but is not prompt content. Everything else of the block, every description and
    question row included, is in the digest."""
    out = []
    for i, row in enumerate(block):
        if i == len(block) - 1 and (ASK_FOOTER_RE.match(row) or DIALOG_FOOT_RE.match(row)):
            out.append("<footer>")
            continue
        if type_n is not None:
            m = ASK_OPTION_RE.match(row)
            if m and int(m.group(2)) == type_n:
                out.append("%d. Type something" % type_n)
                continue
        s = CURSOR_MARK_RE.sub(r"\1 ", row)
        s = CHECK_RE.sub("[ ]", s)
        s = TAB_MARK_RE.sub("☐", s)
        out.append(" ".join(s.split()))
    return out


def _marker_row(row):
    return row.lstrip().startswith(MARKERS)


def _zone_start(rows, stop):
    """Index where the current turn starts above row stop: after the last dialog footer or the
    closing rule of an input box (rule, marker row, rule). Rows above it are older transcript."""
    start = 0
    for i in range(stop):
        if ASK_FOOTER_RE.match(rows[i]) or DIALOG_FOOT_RE.match(rows[i]):
            start = i + 1
        elif i >= 2 and is_rule(rows[i]) and is_rule(rows[i - 2]) and _marker_row(rows[i - 1]):
            start = i + 1
    return start


def _first_nonblank_after(rows, j, stop):
    for k in range(j + 1, stop):
        if rows[k].strip():
            return k
    return None


def _ask_head(row):
    return ASK_HEADER_RE.search(row) is not None


def _review_tabs(row):
    return REVIEW_TABS_RE.search(row) is not None


def _perm_title(row):
    """A permission box title: a text row, not a rule, option or dashed separator."""
    return (bool(row.strip()) and not is_rule(row) and not ASK_OPTION_RE.match(row)
            and not SEPARATOR_RE.match(row))


def _dialog_top(rows, stop, strong):
    """(top, unfit) of the dialog whose lower part (question, chat row or footer) is row stop. top is
    the topmost rule above stop, in the current turn, whose first non-blank row below satisfies strong
    (the box header or the title). unfit is True when no row at all lies above top in the capture: the
    top may have scrolled out of view, and the box is refused rather than read from its first row.
    Rule rows inside the command never become the top, because the topmost candidate wins; a box
    that holds a second rule row is refused by the callers (_rules_in)."""
    zone = _zone_start(rows, stop)
    for j in range(zone, stop):
        if not is_rule(rows[j]):
            continue
        k = _first_nonblank_after(rows, j, stop)
        if k is None or not strong(rows[k]):
            continue
        return j, not any(rows[x].strip() for x in range(j))
    return None, True


def _rules_in(block):
    return sum(1 for row in block if is_rule(row))


def _has_format(block):
    """True when a row of the block holds a Unicode format character (category Cf): bidi overrides
    and isolates, zero-width and other invisible characters. Such a dialog is refused."""
    return any(unicodedata.category(ch) == "Cf" for row in block for ch in row)


def ask_box(lines):
    """The AskUserQuestion box of a capture, or None. Returns a dict: question, header,
    multi, options (n, label, checked, desc; without the Type something row), type_n,
    type_label (the typed text once free text is entered), type_checked, chat_n, cursor (the n
    of the highlighted row), tabs (the questions in the tab bar: 1 for a single question), block
    (every non-blank row from the box top rule to the footer, verbatim), digest_rows (the block
    as the digest sees it), invisible (a format character in the block) and span. {"unfit": True}
    when the box is found but its top rule is not in view (see _dialog_top)."""
    rows = _plain_rows(lines)
    foot = next((i for i in range(len(rows) - 1, -1, -1) if ASK_FOOTER_RE.match(rows[i])), None)
    if foot is None or not _only_blank_after(rows, foot):
        return None
    chat = _prev_nonblank(rows, foot)
    if chat is None or not CHAT_RE.match(rows[chat]):
        return None
    chat_n = int(CHAT_RE.match(rows[chat]).group(1))
    mid = _prev_nonblank(rows, chat)
    if mid is None or not is_rule(rows[mid]):
        return None
    top, unfit = _dialog_top(rows, mid, _ask_head)
    if top is None:
        return {"unfit": True}
    block = _block(rows, top, foot)
    if _rules_in(block) != 2:
        return None
    if unfit:
        return {"unfit": True}
    region = rows[top + 1:mid]
    body = [r for r in region if r.strip()]
    if len(body) < 3:
        return None
    head = ASK_HEADER_RE.search(body[0])
    if head is None:
        return None
    opts = _options(region)
    k = chat_n - 1
    if k < 2 or [o["n"] for o in opts] != list(range(1, k + 1)):
        return None
    boxed = [o["checked"] is not None for o in opts]
    if any(boxed) and not all(boxed):
        return None
    cursor = _cursor_n(opts)
    if cursor is None:
        return None
    type_row = opts[-1]
    return {
        "question": body[1].strip(), "header": head.group(1), "multi": all(boxed),
        "options": [{"n": o["n"], "label": o["label"], "checked": o["checked"], "desc": o["desc"]}
                    for o in opts[:-1]],
        "type_n": k, "type_label": type_row["label"], "type_checked": type_row["checked"],
        "chat_n": chat_n, "cursor": cursor,
        "tabs": len(re.findall(r"[☐☒]", body[0])),
        "block": block, "digest_rows": _digest_rows(block, type_n=k), "span": (top, foot),
        "invisible": _has_format(block),
    }


def _review_answers(rows, start, stop):
    """(question, [labels]) for each answer row ("●" with its "→" value row) from start to stop,
    or None when a non-blank row there is not such a pair (an unknown row is never skipped)."""
    answers = []
    i = start
    while i < stop:
        if not rows[i].strip():
            i += 1
            continue
        m = REVIEW_ANSWER_RE.match(rows[i])
        j = _next_nonblank(rows, i)
        value = REVIEW_VALUE_RE.match(rows[j]) if (m and j is not None and j < stop) else None
        if value is None:
            return None
        answers.append((m.group(1), [part.strip() for part in value.group(1).split(",")]))
        i = j + 1
    return answers


def review_page(lines):
    """The review page of a multi-question or multi-select Ask box, or None. Returns
    answers (a list of (question, [labels])), options (labels), cursor (n), block, digest_rows,
    invisible and span. Refused (None) when it parsed no answer at all or when a row between the
    header and the "ready" line is not an answer with its value. The options are the last block of
    the pane (an optional footer may follow them). {"unfit": True} when the top rule is not in view."""
    rows = _plain_rows(lines)
    head = next((i for i in range(len(rows) - 1, -1, -1) if REVIEW_HEAD_RE.match(rows[i])), None)
    if head is None:
        return None
    ready = next((i for i in range(head, len(rows)) if REVIEW_READY_RE.match(rows[i])), None)
    if ready is None:
        return None
    top, unfit = _dialog_top(rows, head, _review_tabs)
    if top is None:
        return {"unfit": True}
    answers = _review_answers(rows, head + 1, ready)
    if not answers:
        return None
    opts = _options(rows[ready:])
    if len(opts) < 2 or [o["n"] for o in opts] != list(range(1, len(opts) + 1)):
        return None
    last = max(i for i in range(ready, len(rows)) if ASK_OPTION_RE.match(rows[i]))
    if any(rows[j].strip() and not REVIEW_FOOTER_RE.match(rows[j]) for j in range(last + 1, len(rows))):
        return None
    cursor = _cursor_n(opts)
    if cursor is None:
        return None
    block = _block(rows, top, len(rows) - 1)
    if _rules_in(block) != 1:
        return None
    if unfit:
        return {"unfit": True}
    end = max(i for i in range(top, len(rows)) if rows[i].strip())
    return {"answers": answers, "options": [o["label"] for o in opts], "cursor": cursor,
            "block": block, "digest_rows": _digest_rows(block), "span": (top, end),
            "invisible": _has_format(block)}


def permission_prompt(lines):
    """A permission prompt (also one a background agent raises), or None. Returns the title
    (first line of the box, e.g. "Bash command"), body (the command and description lines,
    dashed separators left out), question, option labels, full option labels (label plus the
    continuation rows under it, used for the --persist allow-list), the cursor (n), block (every
    non-blank row from the box top rule to the footer, verbatim), digest_rows, invisible and span.
    Needs the question line, the numbered options from 1 and the "Esc to cancel" footer as the last
    block. {"unfit": True} when the top rule is not in view (see _dialog_top)."""
    rows = _plain_rows(lines)
    start = max(0, len(rows) - 60)
    foot = next((i for i in range(len(rows) - 1, start - 1, -1) if "Esc to cancel" in rows[i]), None)
    if foot is None or not _only_blank_after(rows, foot):
        return None
    # the question line, not an option that repeats its words ("Yes, and don't ask again")
    p = next((i for i in range(foot - 1, start - 1, -1)
              if PERMISSION_RE.search(rows[i]) and not ASK_OPTION_RE.match(rows[i])), None)
    if p is None:
        return None
    top, unfit = _dialog_top(rows, p, _perm_title)
    if top is None:
        return {"unfit": True}
    lines_above = [r.strip() for r in rows[top + 1:p] if r.strip() and not SEPARATOR_RE.match(r)]
    if not lines_above:
        return None
    opts = _options(rows[p:foot])
    if len(opts) < 2 or [o["n"] for o in opts] != list(range(1, len(opts) + 1)):
        return None
    cursor = _cursor_n(opts)
    if cursor is None:
        return None
    block = _block(rows, top, foot)
    if _rules_in(block) != 1:
        return None
    if unfit:
        return {"unfit": True}
    return {"title": lines_above[0], "body": lines_above[1:], "question": rows[p].strip(),
            "options": [o["label"] for o in opts],
            "full": [" ".join((o["label"] + " " + o["desc"]).split()) for o in opts],
            "cursor": cursor, "block": block, "digest_rows": _digest_rows(block),
            "span": (top, foot), "invisible": _has_format(block)}


def _text_after_cell(row, x):
    """The part of `row` from display cell x on (a wide character counts 2 cells)."""
    pos = 0
    for i, ch in enumerate(row):
        if unicodedata.combining(ch):
            continue
        if pos >= x:
            return row[i:]
        pos += 2 if unicodedata.east_asian_width(ch) in ("W", "F") else 1
    return ""


def cursor_at_end(text, cursor):
    """True when the tmux cursor (x, y) sits on the last row of the input box with nothing but
    padding after it. A capture with -N pads each row to the pane width, so the row's length
    is not the end of the text: only the characters after the cursor count."""
    lines = (text or "").split("\n")
    box = find_input_box(lines)
    if box is None or cursor is None:
        return False
    last = box[1] - 1
    if cursor[1] != last:
        return False
    return not _text_after_cell(strip_ansi(lines[last]), cursor[0]).strip()


# A dialog footer: "Esc to cancel" with optional hints in front and behind it, separated by "·"
# ("Enter to confirm · Esc to cancel", "Esc to cancel · Tab to amend", the Ask footer). The "·"
# separators are required, so a prose line that happens to contain the words is no footer.
DIALOG_FOOT_RE = re.compile(r"^\s*(?:[^·]+·\s*)*Esc to cancel(?:\s*·\s*[^·]+?)*\s*$")




def _dialog_above(rows, top):
    """True when a dialog footer is drawn above the input box whose top rule is row top. A dialog
    is never drawn while the input box is, and every dialog ends with its footer, so a footer above
    the box is a stale or quoted dialog: nothing is typed into or answered in that pane (fix round
    2). Numbered rows alone do not count: an owner's own numbered message is drawn the same way
    above the box (measured live), and it is transcript."""
    return any(ASK_FOOTER_RE.match(rows[j]) or DIALOG_FOOT_RE.match(rows[j]) for j in range(top))


DIALOG_DETECTORS = (("review", review_page, "review"), ("ask", ask_box, "ask"),
                    ("permission", permission_prompt, "perm"))
DIALOG_REASON = {"review": "review page", "ask": "Ask box", "permission": "permission prompt"}


def classify_pane(text):
    """What the pane shows, from one capture. kind is one of: ask, review, permission (a dialog, read
    from the scrollback window when the capture carries one, see Capture; a dialog in a capture with no
    scrollback above its visible area is refused, its top cannot be verified), input (the input box is the
    last box of the visible pane, nothing dialog-shaped next to it; typed or empty, see the caller),
    dialog (a picker, menu or other dialog next to the input box), unknown (neither, dialog-shaped rows
    above a visible input box, another box below the input box, or a dialog whose top is not in view).
    A dialog state carries refusal (REFUSAL_UNFIT or REFUSAL_INVISIBLE) when it must not be read or
    answered. busy is True while a turn runs above the box."""
    lines = (text or "").rstrip("\n").split("\n")
    rows = _plain_rows(lines)
    window = window_of(text)
    wlines = (window or "").rstrip("\n").split("\n") if window is not None else lines
    # a capture with no rows above its visible area (no scrollback) cannot show where a dialog starts
    no_history = window is not None and len(wlines) <= len(lines)
    for kind, detect, key in DIALOG_DETECTORS:
        found = detect(wlines)
        if found is None:
            continue
        if no_history or found.get("unfit"):
            return {"kind": "unknown", "busy": False, "refusal": REFUSAL_UNFIT,
                    "reason": "dialog does not fit the pane (its top is not in view)"}
        refusal = REFUSAL_INVISIBLE if found.get("invisible") else None
        return {"kind": kind, "busy": False, "reason": DIALOG_REASON[kind], key: found,
                "refusal": refusal}
    box = find_input_box(lines)
    if box is None:
        return {"kind": "unknown", "busy": False, "reason": _no_box_reason(lines)}
    top, bottom = box
    busy = any(SPINNER_LINE_RE.search(rows[i]) or BUSY_ANY_RE.search(rows[i])
               for i in range(max(0, top - BUSY_SCAN_ABOVE), top))
    if _dialog_above(rows, top):
        return {"kind": "unknown", "busy": busy,
                "reason": "dialog-shaped rows above the input box"}
    if any(is_rule(rows[i]) for i in range(bottom + 1, len(rows))):
        return {"kind": "unknown", "busy": busy, "reason": "another box drawn below the input box"}
    # a dialog or menu is what is drawn BELOW the input box; text above it is transcript
    below = range(bottom + 1, len(rows))
    if any(MENU_ROW_RE.match(rows[i]) for i in below):
        return {"kind": "dialog", "busy": busy, "reason": "slash-command menu open"}
    if any(DIALOG_RE.search(rows[i]) for i in below):
        return {"kind": "dialog", "busy": busy, "reason": "dialog or menu open below the input box"}
    return {"kind": "input", "busy": busy, "reason": "input box visible"}


def assess(text, expect=None, block_on_background=True, allow_busy=False):
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
        return False, _no_box_reason(lines)
    top, bottom = box
    plain = [strip_ansi(l) for l in lines]
    for idx in range(max(0, top - BUSY_SCAN_ABOVE), top):
        if allow_busy:
            break  # owner delivery: a turn running is fine, typing only edits the input
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
    if _empty(rows):
        return True, "idle, input empty"
    if len(rows) != 1:
        return False, "input has %d rows (text typed)" % len(rows)
    return False, "input not empty (user text present)"


# Only CLASSIFIED dialogs and permission prompts count as blocked. The generic
# "no empty prompt input box visible (dialog, menu or not Claude Code)" reason does
# not: it also covers a pane that is not Claude Code at all, so it never triggers
# the early push.
BLOCKED_PREFIXES = ("permission prompt open", "no input box, dialog or menu open",
                    "dialog or menu open")


def is_blocked_reason(reason):
    """True for a classified not-safe reason that only the user can clear (a
    permission prompt, dialog, picker or menu in place of or next to the input box),
    as opposed to a busy turn or typed input that clears by itself or must never be
    touched, and to the unclassified generic no-input-box reason."""
    return (reason or "").startswith(BLOCKED_PREFIXES)


def wait_until_safe(probe, timeout, poll=2.0, recheck=1.5, sleep=time.sleep,
                    clock=time.monotonic, should_stop=None, on_state=None,
                    on_blocked=None, blocked_after=120.0):
    """Poll probe() -> (safe, reason) until two consecutive probes `recheck` seconds
    apart are both safe. Returns (True, reason) right after the second safe probe,
    (False, "cancelled") when should_stop() turns true, (False, "timeout ...") after
    `timeout` seconds. on_state(reason) is called whenever the reason changes.
    on_blocked(reason) is called ONCE when a blocking reason (is_blocked_reason: a
    dialog or permission prompt waits for the user) has lasted `blocked_after` seconds
    without interruption; waiting goes on and proceeds once the dialog is closed.
    blocked_after <= 0 disables it."""
    end = clock() + max(0.0, float(timeout))
    last = None
    blocked_since = None
    blocked_sent = False
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
        if is_blocked_reason(reason):
            if blocked_since is None:
                blocked_since = clock()
            if (on_blocked and not blocked_sent and blocked_after > 0
                    and clock() - blocked_since >= blocked_after):
                blocked_sent = True
                on_blocked(reason)
        else:
            blocked_since = None
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


def capture_exact(pane, socket=None):
    """As capture(), with -N: trailing spaces are kept, so a row's width matches the cursor."""
    return _run(tmux_base(socket) + ["capture-pane", "-p", "-e", "-N", "-t", pane])


def capture_window(pane, socket=None, rows=SCROLLBACK_ROWS):
    """The visible pane with up to `rows` rows of scrollback above it (capture-pane -p -e -N -S -rows),
    or None. The visible area is the last rows of the result."""
    return _run(tmux_base(socket) + ["capture-pane", "-p", "-e", "-N", "-S", "-%d" % int(rows),
                                     "-t", pane])


def pane_cursor(pane, socket=None):
    """(x, y) of the pane cursor (tmux cursor_x, cursor_y), or None."""
    out = _run(tmux_base(socket) + ["display-message", "-p", "-t", pane, "#{cursor_x},#{cursor_y}"])
    parts = (out or "").strip().split(",")
    if len(parts) != 2 or not all(p.isdigit() for p in parts):
        return None
    return int(parts[0]), int(parts[1])


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
