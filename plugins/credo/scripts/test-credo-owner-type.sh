#!/bin/bash
# Tests for credo-owner-type.py (type a message or an Ask answer into the owner's own
# session pane) and the detectors it uses in credo_pane_guard.py.
#
# NOTHING real is ever typed into: tmux is a FAKE binary first on a restricted PATH. It
# renders a pane from a JSON state (input box, busy spinner, AskUserQuestion box, review
# page, permission prompt, slash menu, trust dialog) and records every key, literal text,
# submitted message and answer the CLI sends. The target is a FAKE Claude process this
# test starts (argv[0] "claude") that records itself through the real session registry
# hook, so the CLI resolves it through credo_session_registry exactly as for a session.
# The config dir is a temp dir, ntfy is off, and no real tmux server is ever contacted.
#
# It checks:
#   - pure detection on fixtures that reproduce layouts measured on a real Claude Code
#     2.1.316 pane (the owner probe of #145): the
#     AskUserQuestion box (single select, German text, multi-select with checkboxes), the
#     review page, a permission prompt, the input box (empty, typed, busy, multi-row), the
#     slash menu and the workspace trust dialog; the Ask detector refuses look-alikes
#   - input classification, the busy-allowed assess() variant, cursor-at-end, line break
#     and text piece planning, text validation, answer parsing and key planning
#   - send: empty input (also while busy), multi-line (backslash + Enter), force-append
#     (existing text kept, appended text confirmed before Enter), refusals (typed text
#     without force, cursor not at the end, Ask box, permission prompt, slash menu, trust
#     dialog, dead or copy-mode pane, pane of another process, stale or unknown session),
#     dry-run, confirm failure (nothing submitted, own text taken back only when it is
#     still there), unconfirmed Enter (exit 4), chunked long text, --stdin, control
#     characters, size limit
#   - answer: digit, label, esc, free text (Type something row), multi-select with the
#     exact checked set and the review page, digit refused on a multi-select box, review
#     page digit 1 only (and only with Submit answers first), idle pane refused
#   - security fix round: show prints the open prompt and its digest; a permission prompt
#     needs --expect with the digest that was read (a same-options prompt with another command
#     is refused); an Ask box may carry --expect; --persist for "don't ask again" options;
#     force mode never sends BSpace and reports an abort; a line break that submits early is
#     partly sent (exit 4); a prompt replaced by another of the same kind is answered; ASCII
#     digits only; options above 9 by navigation (never the text 10); dialogs count only as the
#     last block and never above a drawn input box; trailing backslash, control, separator and
#     bidi characters refused; leading ! and # sent as typed; the log is refused for a FIFO or
#     a symlink without a hang
#   - tabbed Ask box (several questions, measured live): one answer per question, Right moves
#     on in a tabbed multi select, the review page of all questions is submitted with 1, labels
#     compared as sets
#   - delivery log: one line per attempt, no message content unless
#     CREDO_OWNER_TYPE_LOG_TEXT=1, owner-only file mode, --json output
#
# Usage: bash test-credo-owner-type.sh
#
# The temp directory is NOT removed by this script: the credo safety rules forbid a delete
# whose path holds a shell variable, so the path is printed at the end for removal.

set -uo pipefail

unset TMUX TMUX_PANE

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLI="$SCRIPT_DIR/credo-owner-type.py"
MODULE="$SCRIPT_DIR/credo_owner_type.py"
GUARD="$SCRIPT_DIR/credo_pane_guard.py"
HOOK="$SCRIPT_DIR/../hooks/credo-session-registry.sh"
PY="$(command -v python3 || true)"
if [ -z "$PY" ]; then echo "SKIP: python3 not found"; exit 0; fi
for f in "$CLI" "$MODULE" "$GUARD" "$HOOK"; do
    [ -f "$f" ] || { echo "FAIL: $f missing"; echo "passed: 0, failed: 1"; exit 1; }
done

TMP="$(mktemp -d "${TMPDIR:-/tmp}/cot.XXXXXX")" || { echo "FAIL: mktemp"; exit 1; }
CFG="$TMP/cfg"
BASE="$TMP/base"
FT="$TMP/ftmux"
STATE="$TMP/pane-state.json"
PIDFILE="$TMP/target.pid"
SID="aaaaaaaa-7777-4888-9999-bbbbbbbbbbbb"
LOGF="$CFG/credo/owner-type.log"
mkdir -p "$CFG/credo" "$BASE" "$FT"

PASS=0
FAIL=0
check() { # name expected actual
    if [ "$2" = "$3" ]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"
    fi
}
ok() { # name cond(0 = pass)
    if [ "$2" = "0" ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; fi
}

# --- A. pure detection and planning (modules imported directly) ----------------------
cat > "$TMP/unit.py" <<'PYEOF'
import importlib.util
import sys


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


g = load("credo_pane_guard", sys.argv[1])
o = load("credo_owner_type", sys.argv[2])
res = []


def t(name, cond):
    res.append(name if cond else "FAIL " + name)


def refused(fn):
    try:
        fn()
    except o.Refused:
        return True
    return False


def usage(spec):
    try:
        o.parse_answer(spec)
    except o.UsageError:
        return True
    return False


RULE = "─" * 78
FOOT = "Enter to select · ↑/↓ to navigate · Esc to cancel"
P = "❯"

# Real pane, Claude Code 2.1.316 (measured): single select, English.
ASK_EN = ["● Working on it.", "", RULE, " ☐ Color", "", "Pick a color?", "",
          P + " 1. Red", "     A warm, strong color.", "  2. Green", "     A calm, natural color.",
          "  3. Blue", "     A cool, neutral color.", "  4. Type something.", RULE,
          "  5. Chat about this", "", FOOT]
# Real pane: the same box in German, with a queue preview above the top rule.
ASK_DE = ["✻ Brewed for 13s", "", P + " owner queued note", RULE, " ☐ Nachricht", "",
          "Was soll ich tun?", "", P + " 1. Notiz erneut senden (Recommended)",
          "     Schick den Inhalt noch einmal als normale Nachricht.",
          "  2. sleep 30 selbst ausführen", "     Ich lasse den Wartevorgang weg.",
          "  3. Nichts, Session beenden", "     Es gibt keine offene Aufgabe.",
          "  4. Type something.", RULE, "  5. Chat about this", "", FOOT]
# Real pane: multi select, digits 1 and 3 toggled.
ASK_MULTI = [RULE, "←  ☒ Fruit  ✔ Submit  →", "", "Which fruits?", "",
             P + " 1. [✔] Apple", "         A crisp fruit with red, green or yellow skin.",
             "  2. [ ] Banana", "         A soft, sweet fruit with a yellow peel.",
             "  3. [✔] Cherry", "         A small round stone fruit, usually red.",
             "  4. [ ] Type something", "     Submit", RULE, "  5. Chat about this", "", FOOT]
# Real pane: review page after Right on the multi select (its footer is not required).
REVIEW = [RULE, "←  ☒ Fruit  ✔ Submit  →", "", "Review your answers", "",
          " ● Which fruits?", "   → Apple, Cherry", "",
          "Ready to submit your answers?", "", P + " 1. Submit answers", "  2. Cancel"]
# Permission prompt layout (Claude Code 2.1.x).
PERM = [RULE, " Bash command", "", "   ls /tmp/fixture-dir", "", " Do you want to proceed?",
        " " + P + " 1. Yes", "   2. Yes, and don't ask again for: ls",
        "   3. No, and tell Claude what to do differently (esc)", "",
        "Esc to cancel · Tab to amend"]
INPUT_IDLE = ["● Done.", "", "✻ Worked for 1m 5s", "", RULE, P + " ", RULE,
              "  ? for shortcuts"]
INPUT_BUSY = ["● Working.", "", "✻ Calculating\u2026 (13s · ↓ 90 tokens)", "",
              RULE, P + " ", RULE, "  cwd: /tmp/fixture"]
INPUT_TYPED = ["● Done.", "", RULE, P + " half written", RULE, "  ? for shortcuts"]
INPUT_MULTIROW = ["● Done.", "", RULE, P + " first line", "  second", RULE,
                  "  ? for shortcuts"]
SLASH = ["● Done.", "", RULE, P + " /comp", RULE,
         "  /compact   Clear history but keep a summary", "  /config    Open config panel"]
TRUST = ["Quick safety check: is this a project you trust?", "", P + " 1. No, exit",
         "  2. Yes, I trust this folder", "", "Enter to confirm · Esc to cancel"]
SHELL = ["user@box-1:~$ "]
QUOTED = ["● The doc says: Enter to select, Esc to cancel.", "", "● Done.", "",
          RULE, P + " ", RULE]

ask = g.ask_box(ASK_EN)
t("ask EN detected", ask is not None)
t("ask EN question", ask is not None and ask["question"] == "Pick a color?")
t("ask EN header", ask is not None and ask["header"] == "Color")
t("ask EN single select", ask is not None and ask["multi"] is False)
t("ask EN options", ask is not None and [x["label"] for x in ask["options"]] == ["Red", "Green", "Blue"])
t("ask EN type row", ask is not None and ask["type_n"] == 4 and ask["type_label"] == "Type something.")
t("ask EN chat row", ask is not None and ask["chat_n"] == 5)
t("ask EN cursor on 1", ask is not None and ask["cursor"] == 1)
ask_de = g.ask_box(ASK_DE)
t("ask DE detected", ask_de is not None and ask_de["question"] == "Was soll ich tun?")
t("ask DE options", ask_de is not None and [x["n"] for x in ask_de["options"]] == [1, 2, 3])
t("ask DE cursor on 1", ask_de is not None and ask_de["cursor"] == 1)
ask_m = g.ask_box(ASK_MULTI)
t("ask multi detected", ask_m is not None and ask_m["multi"] is True)
t("ask multi checked set", ask_m is not None and
  [x["checked"] for x in ask_m["options"]] == [True, False, True])
t("ask multi type row", ask_m is not None and ask_m["type_n"] == 4 and ask_m["type_label"] == "Type something")
rv = g.review_page(REVIEW)
t("review detected", rv is not None)
t("review answers", rv is not None and rv["answers"] == [("Which fruits?", ["Apple", "Cherry"])])
t("review options", rv is not None and rv["options"] == ["Submit answers", "Cancel"])
t("review cursor on 1", rv is not None and rv["cursor"] == 1)
perm = g.permission_prompt(PERM)
t("permission detected", perm is not None)
t("permission options", perm is not None and perm["options"] == [
    "Yes", "Yes, and don't ask again for: ls", "No, and tell Claude what to do differently (esc)"])
t("permission cursor on 1", perm is not None and perm["cursor"] == 1)
# look-alikes that must NOT be an Ask box
t("ask: idle input is not an Ask box", g.ask_box(INPUT_IDLE) is None)
t("ask: permission prompt is not an Ask box", g.ask_box(PERM) is None)
t("ask: trust dialog is not an Ask box", g.ask_box(TRUST) is None)
t("ask: slash menu is not an Ask box", g.ask_box(SLASH) is None)
t("ask: quoted footer words in a transcript are not an Ask box", g.ask_box(QUOTED) is None)
t("ask: footer without a chat row is not an Ask box",
  g.ask_box([x for x in ASK_EN if "Chat about" not in x]) is None)
t("ask: chat row without the footer is not an Ask box", g.ask_box(ASK_EN[:-1]) is None)
t("ask: review page is not an Ask box", g.ask_box(REVIEW) is None)
t("permission: Ask box is not a permission prompt", g.permission_prompt(ASK_EN) is None)
t("review: Ask box is not a review page", g.review_page(ASK_EN) is None)
# input and pane classification
t("classify ask", g.classify_pane("\n".join(ASK_EN))["kind"] == "ask")
t("classify multi ask", g.classify_pane("\n".join(ASK_MULTI))["kind"] == "ask")
t("classify review", g.classify_pane("\n".join(REVIEW))["kind"] == "review")
t("classify permission", g.classify_pane("\n".join(PERM))["kind"] == "permission")
t("classify idle input", g.classify_pane("\n".join(INPUT_IDLE))["kind"] == "input")
t("classify busy input", g.classify_pane("\n".join(INPUT_BUSY))["kind"] == "input"
  and g.classify_pane("\n".join(INPUT_BUSY))["busy"] is True)
t("classify typed input", g.classify_pane("\n".join(INPUT_TYPED))["kind"] == "input")
t("classify slash menu is a dialog", g.classify_pane("\n".join(SLASH))["kind"] == "dialog")
t("classify trust is unknown", g.classify_pane("\n".join(TRUST))["kind"] == "unknown")
t("classify shell is unknown", g.classify_pane("\n".join(SHELL))["kind"] == "unknown")
t("assess: busy is not safe by default", not g.assess("\n".join(INPUT_BUSY))[0])
t("assess: busy with allow_busy on an empty box is safe",
  g.assess("\n".join(INPUT_BUSY), allow_busy=True, block_on_background=False)[0])
t("assess: allow_busy keeps the typed-text rule",
  not g.assess("\n".join(INPUT_TYPED), allow_busy=True, block_on_background=False)[0])
t("assess: allow_busy keeps dialogs blocked",
  not g.assess("\n".join(SLASH), allow_busy=True, block_on_background=False)[0])
# cursor position in the input box (tmux cursor_x, cursor_y; -N capture keeps trailing spaces)
ONE = "\n".join(INPUT_TYPED)
t("cursor at end of one row", g.cursor_at_end(ONE, (2 + len("half written"), 3)))
t("cursor mid text is not at end", not g.cursor_at_end(ONE, (2 + 4, 3)))
t("cursor on another row is not at end", not g.cursor_at_end(ONE, (2 + 12, 4)))
t("cursor at end of the last continuation row",
  g.cursor_at_end("\n".join(INPUT_MULTIROW), (2 + len("second"), 4)))
t("cursor at the marker of a continuation row is not at end",
  not g.cursor_at_end("\n".join(INPUT_MULTIROW), (2, 4)))
# a -N capture pads the row to the pane width: the text ends where the padding starts
PADDED = [ln.ljust(110) for ln in INPUT_TYPED]
t("cursor at end of a padded row", g.cursor_at_end("\n".join(PADDED), (2 + len("half written"), 3)))
t("cursor mid text in a padded row is not at end",
  not g.cursor_at_end("\n".join(PADDED), (2 + 4, 3)))
t("cursor after the padding of an empty row is at end",
  g.cursor_at_end("\n".join([ln.ljust(110) for ln in INPUT_IDLE]), (2, 5)))
# real panes captured with the throwaway session (Claude Code 2.1.316), layouts kept as seen
ASK_IDE = [RULE, " ☐ Word", "", "Pick a word?", "", "  1. Alpha", "     The first word in the list.",
           "  2. Beta", "     The second word in the list.", P + " 3. Type something.", RULE,
           "  4. Chat about this", "Enter to select · ↑/↓ to navigate · "
           "ctrl+g to edit in VS Code · Esc to cancel"]
PERM_YES_NO = [RULE, " Bash command", "", "   python3 -c 'print(1)'", "",
               " Permission rule Bash(python3 *) requires confirmation for this command.",
               " /permissions to update rules", "", " Do you want to proceed?", " " + P + " 1. Yes",
               "   2. No", "", " Esc to cancel · Tab to amend"]
QUEUED = "\n".join(["● Working.", "", "✻ Calculating\u2026 (13s · ↓ 90 tokens)", "",
                    RULE, P + " \x1b[2m\x1b[39mPress up to edit queued messages\x1b[0m\x1b[39m"
                    "\x1b[49m", RULE, "  ? for shortcuts"])
ask_ide = g.ask_box(ASK_IDE)
t("real footer with a VS Code hint: Ask box found", ask_ide is not None)
t("real footer: highlight on the Type something row", ask_ide is not None and ask_ide["cursor"] == 3
  and ask_ide["type_n"] == 3)
t("real two-option permission prompt", (g.permission_prompt(PERM_YES_NO) or {}).get("options")
  == ["Yes", "No"] and g.permission_prompt(PERM_YES_NO)["cursor"] == 1)
t("real permission prompt: the title and the command are kept",
  g.permission_prompt(PERM_YES_NO)["title"] == "Bash command"
  and "python3 -c 'print(1)'" in g.permission_prompt(PERM_YES_NO)["body"])
t("real two-option permission prompt is classified", g.classify_pane("\n".join(PERM_YES_NO))["kind"]
  == "permission")
t("queued placeholder (dimmed) is an empty input", g.input_content(QUEUED) == "")
t("queued placeholder: busy and input, not a dialog", g.classify_pane(QUEUED)["kind"] == "input"
  and g.classify_pane(QUEUED)["busy"] is True)
t("same prompt: same question and options", o.same_prompt(g.classify_pane("\n".join(ASK_EN)),
                                                         g.classify_pane("\n".join(ASK_EN))))
t("same prompt: another question is not the same",
  not o.same_prompt(g.classify_pane("\n".join(ASK_EN)), g.classify_pane("\n".join(ASK_DE))))
t("same prompt: another kind is not the same",
  not o.same_prompt(g.classify_pane("\n".join(ASK_EN)), g.classify_pane("\n".join(PERM))))
t("same prompt: a permission prompt with other options is not the same",
  not o.same_prompt(g.classify_pane("\n".join(PERM_YES_NO)), g.classify_pane("\n".join(PERM))))
# owner module: validation, planning, parsing
t("validate: empty refused", o.validate_text("") is not None)
t("validate: tab refused", o.validate_text("a\tb") is not None)
t("validate: control character refused", o.validate_text("a\x01b") is not None)
t("validate: carriage return refused", o.validate_text("a\rb") is not None)
t("validate: too long refused", o.validate_text("x" * (o.MAX_TEXT_CHARS + 1)) is not None)
t("validate: multi-line accepted", o.validate_text("one\ntwo") is None)
t("validate: umlauts accepted", o.validate_text("überprüft äöß") is None)
t("keystrokes: line break is a backslash then Enter",
  o.keystrokes("a\nb") == [("text", "a"), ("text", "\\"), ("key", "Enter"), ("text", "b")])
t("keystrokes: 450 characters in pieces of 200, 200 and 50",
  [len(v) for k, v in o.keystrokes("x" * 450) if k == "text"] == [200, 200, 50])
t("keystrokes: no piece holds a newline",
  all("\n" not in v for k, v in o.keystrokes("a\n\nb\nc") if k == "text"))
t("keystrokes: empty line in the middle",
  o.keystrokes("a\n\nb")[2:5] == [("key", "Enter"), ("text", "\\"), ("key", "Enter")])
t("answer digit", o.parse_answer("2") == ("digit", 2))
t("answer esc", o.parse_answer("esc") == ("esc", None))
t("answer label", o.parse_answer("Green") == ("label", "Green"))
t("answer free keeps the text", o.parse_answer("free:zeta word") == ("free", "zeta word"))
t("answer multi list", o.parse_answer("multi:3,1") == ("multi", [1, 3]))
t("answer refused: zero", usage("0"))
t("answer refused: two digits", usage("10"))
t("answer refused: empty multi", usage("multi:"))
t("answer refused: duplicate in multi", usage("multi:1,1"))
t("answer refused: text in multi", usage("multi:x"))
t("answer refused: empty free text", usage("free:"))
t("answer refused: newline in free text", usage("free:a\nb"))
t("answer refused: empty spec", usage(""))
t("answer refused: blank spec", usage("   "))
t("answer label maps to its digit (case-insensitive)",
  o.answer_keys(ask, ("label", "green")) == ["2"])
t("answer digit in range", o.answer_keys(ask, ("digit", 3)) == ["3"])
t("answer digit on the type row is refused (use free:)",
  refused(lambda: o.answer_keys(ask, ("digit", 4))))
t("answer unknown label refused", refused(lambda: o.answer_keys(ask, ("label", "Purple"))))
t("answer type-something label refused",
  refused(lambda: o.answer_keys(ask, ("label", "Type something."))))
t("answer esc key", o.answer_keys(ask, ("esc", None)) == ["Escape"])
t("answer digit on a multi select is refused", refused(lambda: o.answer_keys(ask_m, ("digit", 1))))
t("free text navigation from 1 to the type row", o.free_nav_keys(ask) == ["Down", "Down", "Down"])
t("free text navigation: already on the type row", o.free_nav_keys(dict(ask, cursor=4)) == [])
t("multi toggles from none checked", o.multi_toggle_keys(
    dict(ask_m, options=[dict(x, checked=False) for x in ask_m["options"]]), {1, 3}) == ["1", "3"])
t("multi toggles are the symmetric difference", o.multi_toggle_keys(
    dict(ask_m, options=[dict(x, checked=(i == 1)) for i, x in enumerate(ask_m["options"])]),
    {1, 3}) == ["1", "2", "3"])
t("multi toggles to unselect cherry", o.multi_toggle_keys(ask_m, {3}) == ["1"])
t("multi: an empty selection is refused", refused(lambda: o.multi_toggle_keys(ask_m, set())))
t("multi: the type row is not an option", refused(lambda: o.multi_toggle_keys(ask_m, {4})))
t("permission digit in range", o.permission_keys(perm, ("digit", 1)) == ["1"])
t("permission digit out of range refused", refused(lambda: o.permission_keys(perm, ("digit", 4))))
t("permission label refused", refused(lambda: o.permission_keys(perm, ("label", "Yes"))))
t("permission esc", o.permission_keys(perm, ("esc", None)) == ["Escape"])
t("review digit 1 submits", o.review_keys(rv, ("digit", 1)) == ["1"])
t("review digit 2 refused", refused(lambda: o.review_keys(rv, ("digit", 2))))
t("review esc refused", refused(lambda: o.review_keys(rv, ("esc", None))))
# --- fix round (security review): red tests, written before the code ----------------
DASHES = "╌" * 60


def perm_lines(cmd):
    return [RULE, " Bash command", "", DASHES, " Run the listing", " " + cmd, DASHES, "",
            " Do you want to proceed?", " " + P + " 1. Yes",
            "   2. Yes, and don't ask again for: ls",
            "   3. No, and tell Claude what to do differently (esc)", "",
            "Esc to cancel · Tab to amend"]


TEN_NAMES = ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"]


def ten_lines(multi=False, cursor_row=1, checked=()):
    lines = [RULE, " ☐ Ten", "", "Pick one?", ""]
    for i, name in enumerate(TEN_NAMES, 1):
        mark = P + " " if i == cursor_row else "  "
        if multi:
            box = "[✔]" if i in checked else "[ ]"
            lines.append("%s%d. %s %s" % (mark, i, box, name))
        else:
            lines.append("%s%d. %s" % (mark, i, name))
        lines.append("     The %s option." % name)
    k = len(TEN_NAMES) + 1
    lines += ["%s%d. Type something." % ("  ", k) if not multi else "%s%d. [ ] Type something" % ("  ", k),
              RULE, "  %d. Chat about this" % (k + 1), "", FOOT]
    return lines


def digest_of(lines):
    return o.prompt_digest(g.classify_pane("\n".join(lines)))


# 3. digits: ASCII only
t("digit: fullwidth two is a label, not a digit", o.parse_answer("２") == ("label", "２"))
t("digit: superscript two is a label, not a digit", o.parse_answer("²") == ("label", "²"))
# 6. trailing backslash, control and bidi characters, allowed prefixes
t("validate: trailing backslash refused", o.validate_text("abc\\") is not None)
t("validate: backslash at the end of a line refused", o.validate_text("abc\\\ndef") is not None)
t("validate: backslash inside a line allowed", o.validate_text("a\\b") is None)
t("validate: C1 control refused", o.validate_text("a\u0085b") is not None)
t("validate: U+2028 refused", o.validate_text("a b") is not None)
t("validate: U+2029 refused", o.validate_text("a b") is not None)
t("validate: bidi override refused", o.validate_text("a‮b") is not None)
t("validate: bidi isolate refused", o.validate_text("a⁦b") is not None)
t("validate: leading exclamation mark allowed (sent as typed)", o.validate_text("! ls -la") is None)
t("validate: leading hash allowed", o.validate_text("# a note") is None)
# 5. a dialog counts only as the last block, and never above an input box
t("transcript dialog text above an input box is an input",
  g.classify_pane("\n".join(ASK_EN + INPUT_IDLE))["kind"] == "input")
t("permission text above an input box is an input",
  g.classify_pane("\n".join(PERM + INPUT_IDLE))["kind"] == "input")
t("ask footer followed by transcript text is not an Ask box",
  g.classify_pane("\n".join(ASK_EN + ["● more transcript"]))["kind"] != "ask")
t("permission footer followed by text is not a prompt",
  g.permission_prompt(PERM + ["● text"]) is None)
# 1. command text in the permission prompt, digest over the normalized prompt
PA = perm_lines("ls /tmp/fixture-dir")
PB = perm_lines("rm -rf /tmp/fixture-dir")
pa = g.permission_prompt(PA)
t("permission: the command text is captured", pa is not None and "ls /tmp/fixture-dir" in pa["body"])
t("permission: the title is captured", pa is not None and pa["title"] == "Bash command")
t("permission: same options, other command, other digest", digest_of(PA) != digest_of(PB))
t("permission: the same prompt has the same digest", digest_of(PA) == digest_of(PA))
t("digest is a sha256 hex string", len(digest_of(PA) or "") == 64
  and all(c in "0123456789abcdef" for c in digest_of(PA)))
t("ask: option description captured", ask is not None and ask["options"][0]["desc"] == "A warm, strong color.")
ASK_EN_MOVED = [x.replace(P + " 1. Red", "  1. Red").replace("  2. Green", P + " 2. Green") for x in ASK_EN]
t("ask digest ignores the cursor", digest_of(ASK_EN) == digest_of(ASK_EN_MOVED))
t("ask digest changes with the question", digest_of(ASK_EN) != digest_of(ASK_DE))
t("ask digest changes with an option description",
  digest_of(ASK_EN) != digest_of([x.replace("A warm, strong color.", "A warm, other color.") for x in ASK_EN]))
t("input has no digest", o.prompt_digest(g.classify_pane("\n".join(INPUT_IDLE))) is None)
# 7. persist options
t("persist: don't ask again detected", o.is_persist("Yes, and don't ask again for: ls"))
t("persist: curly apostrophe detected", o.is_persist("Yes, and don’t ask again for: ls"))
t("persist: plain Yes is not persist", not o.is_persist("Yes"))
t("persist: the No option is not persist", not o.is_persist("No, and tell Claude what to do differently (esc)"))
perm_ok = g.permission_prompt(PA)
t("persist option refused without the flag", refused(lambda: o.permission_keys(perm_ok, ("digit", 2))))
t("persist option allowed with the flag", o.permission_keys(perm_ok, ("digit", 2), persist=True) == ["2"])
t("plain permission option needs no flag", o.permission_keys(perm_ok, ("digit", 1)) == ["1"])
# 4. option numbers above 9
ask10 = g.ask_box(ten_lines())
t("ten options: the box is read", ask10 is not None and len(ask10["options"]) == 10)
t("ten options: label route navigates to option 10 and enters",
  o.answer_keys(ask10, ("label", "ten")) == ["Down"] * 9 + ["Enter"])
t("ten options: digit route for 10 navigates too", o.answer_keys(ask10, ("digit", 10)) == ["Down"] * 9 + ["Enter"])
t("ten options: option 9 keeps its digit", o.answer_keys(ask10, ("label", "nine")) == ["9"])
t("ten options: the text 10 is never sent",
  all(k != "10" for k in o.answer_keys(ask10, ("label", "ten"))))
ask10m = g.ask_box(ten_lines(multi=True, checked=()))
t("ten options multi: toggles 1 and 10 with a digit and Space",
  o.multi_toggle_keys(ask10m, {1, 10}) == ["1"] + ["Down"] * 9 + ["Space"])
t("navigation keys down", o.nav_keys(1, 4) == ["Down"] * 3)
t("navigation keys up", o.nav_keys(4, 1) == ["Up"] * 3)
t("navigation keys: already there", o.nav_keys(2, 2) == [])
# 8. review page: the first option must be Submit answers
t("review: the Submit answers label is required",
  refused(lambda: o.review_keys(dict(rv, options=["Send it", "Cancel"]), ("digit", 1))))
t("review: a review page without options refused", refused(lambda: o.review_keys(None, ("digit", 1))))
# live finding (Claude Code 2.1.316): a tabbed box with the footer "Tab/Arrow keys to navigate",
# a multi-select question with a "Next" row, and labels in selection order on the review page
ASK_TABS = [RULE, "←  ☐ Color  ☐ Fruit  ☐ Size  ✔ Submit  →", "",
            "Which fruits?", "", P + " 1. [ ] Apple", "         A crisp, sweet fruit with a firm skin",
            "  2. [ ] Banana", "         A soft, sweet fruit in a yellow peel", "  3. [ ] Cherry",
            "         A small, round stone fruit", "  4. [ ] Type something", "     Next", RULE,
            "  5. Chat about this", "",
            "Enter to select · Tab/Arrow keys to navigate · Esc to cancel"]
tabs_ask = g.ask_box(ASK_TABS)
t("tabbed box: the Tab/Arrow footer is an Ask box", tabs_ask is not None)
t("tabbed box: multi select with its question", tabs_ask is not None and tabs_ask["multi"] is True
  and tabs_ask["question"] == "Which fruits?")
t("tabbed box: the Next row is not an option", tabs_ask is not None and len(tabs_ask["options"]) == 3)
t("tabbed box classified as an Ask box", g.classify_pane("\n".join(ASK_TABS))["kind"] == "ask")
t("labels match as sets, in any order", o.labels_match(["Cherry", "Apple"], ["Apple", "Cherry"]))
t("labels differ when a label is missing", not o.labels_match(["Cherry"], ["Apple", "Cherry"]))
print("\n".join(res))
PYEOF
unit_out="$("$PY" "$TMP/unit.py" "$GUARD" "$MODULE" 2>&1)"; unit_rc=$?
if [ "$unit_rc" -ne 0 ]; then
    FAIL=$((FAIL + 1)); echo "FAIL pure section crashed (rc $unit_rc): $(printf '%s' "$unit_out" | tail -1)"
fi
while IFS= read -r line; do
    case "$line" in
        FAIL*) FAIL=$((FAIL + 1)); echo "$line" ;;
        "") ;;
        *) PASS=$((PASS + 1)) ;;
    esac
done <<< "$unit_out"

# --- B. fake tmux, scenarios and a fake target ----------------------------------------
for t in python3 bash dirname cat mkdir mv cp sleep env kill rm printf tr sed grep head find date stat; do
    p="$(command -v "$t" 2>/dev/null)" && ln -s "$p" "$BASE/$t"
done
{
    printf '#!%s\n' "$PY"
    cat <<'PYEOF'
"""Fake tmux (test-credo-owner-type.sh): renders one pane from FAKE_PANE_STATE and records
every key and literal text it receives. Trailing spaces are dropped unless -N is given."""
import json
import os
import sys

RULE = "─" * 78
FOOTER = "Enter to select · ↑/↓ to navigate · Esc to cancel"
NBSP = " "
PROMPT = "❯"
PANE_WIDTH = 110


def load():
    with open(os.environ["FAKE_PANE_STATE"], encoding="utf-8") as fh:
        return json.load(fh)


def save(st):
    path = os.environ["FAKE_PANE_STATE"]
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(st, fh, ensure_ascii=False)
    os.replace(tmp, path)


def render_input(st):
    lines = ["● Working on it.", ""]
    if st.get("busy"):
        lines += ["✻ Calculating\u2026 (13s · ↓ 90 tokens)", ""]
    top = len(lines)
    lines.append(RULE)
    text = st.get("input", "")
    rows = text.split("\n")
    for i, row in enumerate(rows):
        lines.append((PROMPT + NBSP if i == 0 else "  ") + row)
    cursor = st.get("cursor")
    if cursor is None or cursor >= len(text):
        cy = top + len(rows)
        cx = len((PROMPT + NBSP if len(rows) == 1 else "  ") + rows[-1])
    else:
        before = text[:cursor]
        row = before.count("\n")
        cy = top + 1 + row
        cx = len((PROMPT + NBSP if row == 0 else "  ") + before.split("\n")[-1])
    lines.append(RULE)
    lines.append("  ? for shortcuts")
    return lines, (cx, cy)


TABS_FOOTER = "Enter to select · Tab/Arrow keys to navigate · Esc to cancel"


def tab_bar(st):
    done = {c["header"] for c in st["collected"]}
    parts = ["%s %s" % ("☒" if q["header"] in done else "☐", q["header"]) for q in st["questions"]]
    return "←  " + "  ".join(parts) + "  ✔ Submit  →"


def render_ask(st):
    a = st["ask"]
    n = len(a["options"])
    tabbed = bool(st.get("questions"))
    lines = ["● Working on it.", "", RULE]
    if tabbed:
        lines += [tab_bar(st), "", a["question"], ""]
    else:
        lines += [" %s %s " % ("☒" if a["multi"] else "☐", a["header"]), "", a["question"], ""]
    for i, opt in enumerate(a["options"]):
        mark = PROMPT + " " if a["cursor"] == i else "  "
        if a["multi"]:
            box = "[✔]" if a["checked"][i] else "[ ]"
            lines.append("%s%d. %s %s" % (mark, i + 1, box, opt["label"]))
        else:
            lines.append("%s%d. %s" % (mark, i + 1, opt["label"]))
        lines.append("     " + opt["desc"])
    typed = a.get("free")
    mark = PROMPT + " " if a["cursor"] == n else "  "
    if a["multi"]:
        box = "[✔]" if a["checked"][n] else "[ ]"
        lines.append("%s%d. %s %s" % (mark, n + 1, box, "Type something" if typed is None else typed))
        lines.append("     Next" if tabbed else "     Submit")
    else:
        lines.append("%s%d. %s" % (mark, n + 1, "Type something." if typed is None else typed))
    lines += [RULE, "  %d. Chat about this" % (n + 2), "", TABS_FOOTER if tabbed else FOOTER]
    return lines, (0, 0)


def render_review(st):
    if st.get("tab_review") is not None:
        lines = [RULE, tab_bar(st), "", "Review your answers", ""]
        for c in st["tab_review"]:
            value = ", ".join(c["labels"]) if "labels" in c else c["label"]
            lines += [" ● %s" % c["question"], "   → %s" % value, ""]
        lines += ["Ready to submit your answers?", "", PROMPT + " 1. Submit answers", "  2. Cancel"]
        return lines, (0, 0)
    r = st["review"]
    first = r.get("options", ["Submit answers", "Cancel"])
    lines = [RULE, "←  ☒ %s  ✔ Submit  →" % st["ask"]["header"], "",
             "Review your answers", "", " ● %s" % r["question"],
             "   → %s" % ", ".join(r["labels"]), "",
             "Ready to submit your answers?", "",
             PROMPT + " 1. %s" % first[0] if r["cursor"] == 0 else "  1. %s" % first[0],
             "  2. %s" % first[1]]
    return lines, (0, 0)


def render_perm(st):
    p = st["perm"]
    dashes = "╌" * 60
    lines = [RULE, " " + p.get("title", "Bash command"), "", dashes]
    lines += [" " + row for row in p.get("body", ["ls /tmp/fixture-dir"])]
    lines += [dashes, "", " Do you want to proceed?"]
    for i, label in enumerate(p["options"]):
        lines.append((" " + PROMPT + " " if p["cursor"] == i else "   ") + "%d. %s" % (i + 1, label))
    lines += ["", "Esc to cancel · Tab to amend"]
    return lines, (0, 0)


def render_other(st):
    if st["kind"] == "slash":
        lines = ["● Done.", "", RULE, PROMPT + " " + st.get("input", ""), RULE,
                 "  /compact   Clear history but keep a summary", "  /config    Open config panel"]
        return lines, (0, 0)
    lines = ["Quick safety check: is this a project you trust?", "",
             PROMPT + " 1. No, exit", "  2. Yes, I trust this folder", "",
             "Enter to confirm · Esc to cancel"]
    return lines, (0, 0)


def render(st):
    kind = st["kind"]
    if kind == "input":
        return render_input(st)
    if kind == "ask":
        return render_ask(st)
    if kind == "review":
        return render_review(st)
    if kind == "permission":
        return render_perm(st)
    return render_other(st)


def text_key(st, text):
    st.setdefault("typed", []).append(text)
    st["text_count"] = st.get("text_count", 0) + 1
    if st["kind"] == "input":
        cur = st.get("cursor")
        if cur is None or cur >= len(st["input"]):
            st["input"] = st["input"] + text
        else:
            st["input"] = st["input"][:cur] + text + st["input"][cur:]
            st["cursor"] = cur + len(text)
    elif st["kind"] == "ask" and st["ask"]["cursor"] == len(st["ask"]["options"]):
        st["ask"]["free"] = (st["ask"]["free"] or "") + text
    inject = st.get("inject_after_text")
    if inject and st["text_count"] >= inject:
        # something else happens while the text is typed: a dialog opens, or someone types
        st["inject_after_text"] = None
        if st.get("inject_kind") == "append":
            st["input"] = st["input"] + st.get("inject_text", "Z")
        else:
            st["kind"] = st.get("inject_kind", "ask")


def input_key(st, key):
    if key == "Enter":
        text = st["input"]
        if st.get("enter_noop"):
            return
        if text.endswith("\\") and st.get("break_submits"):
            # a terminal whose backslash + Enter submits instead of making a line break
            st.setdefault("submitted", []).append(text)
            st["input"] = ""
        elif text.endswith("\\"):
            st["input"] = text[:-1] + "\n"
        elif text:
            st.setdefault("submitted", []).append(text)
            st["input"] = ""
        st["cursor"] = None
    elif key == "BSpace":
        cur = st.get("cursor")
        if cur is None or cur >= len(st["input"]):
            st["input"] = st["input"][:-1]
        elif cur > 0:
            st["input"] = st["input"][:cur - 1] + st["input"][cur:]
            st["cursor"] = cur - 1
    elif key == "Left":
        cur = len(st["input"]) if st.get("cursor") is None else st["cursor"]
        st["cursor"] = max(0, cur - 1)
    elif key == "End":
        st["cursor"] = None


def tab_next(st, entry):
    """A tabbed box: record the answer of the current question and move on (or review)."""
    st["collected"].append(dict(entry, header=st["ask"]["header"]))
    st["qi"] += 1
    if st["qi"] < len(st["questions"]):
        st["ask"] = json.loads(json.dumps(st["questions"][st["qi"]]))
    else:
        st["kind"] = "review"
        st["tab_review"] = [{k: v for k, v in c.items() if k != "header"} for c in st["collected"]]


def checked_order(a):
    """The checked options in the order they were checked (the review lists them that way)."""
    n = len(a["options"])
    return a.setdefault("order", [i for i, c in enumerate(a["checked"][:n]) if c])


def ask_key(st, key):
    a = st["ask"]
    n = len(a["options"])
    tabbed = bool(st.get("questions"))
    if len(key) == 1 and key in "123456789":
        d = int(key)
        if a["multi"]:
            if d <= n:
                order = checked_order(a)
                a["checked"][d - 1] = not a["checked"][d - 1]
                if a["checked"][d - 1] and d - 1 not in order:
                    order.append(d - 1)
                elif not a["checked"][d - 1] and d - 1 in order:
                    order.remove(d - 1)
            return
        if d <= n:
            label = a["options"][d - 1]["label"]
            if tabbed:
                tab_next(st, {"question": a["question"], "label": label})
                return
            st.setdefault("answers", []).append({"question": a["question"], "label": label})
            st["kind"] = "input"
            a["free"] = None
        return
    if key == "Down":
        a["cursor"] = min(n, a["cursor"] + 1)
    elif key == "Up":
        a["cursor"] = max(0, a["cursor"] - 1)
    elif key == "Space" and a["multi"] and a["cursor"] < n:
        a["checked"][a["cursor"]] = not a["checked"][a["cursor"]]
    elif key == "Right" and a["multi"]:
        if tabbed:
            order = checked_order(a)
            labels = [a["options"][i]["label"] for i in order if a["checked"][i]]
            tab_next(st, {"question": a["question"], "labels": labels})
            return
        labels = [a["options"][i]["label"] for i in range(n) if a["checked"][i]]
        st["review"] = {"question": a["question"], "labels": labels, "cursor": 0}
        st["kind"] = "review"
    elif key == "Escape":
        st.setdefault("answers", []).append({"question": a["question"], "declined": True})
        st["kind"] = "input"
    elif key == "Enter":
        if a["cursor"] == n:
            if a.get("free") is not None:
                st.setdefault("answers", []).append({"question": a["question"], "free": a["free"]})
                st["kind"] = "input"
        elif not a["multi"]:
            label = a["options"][a["cursor"]]["label"]
            st.setdefault("answers", []).append({"question": a["question"], "label": label})
            st["kind"] = "input"


def review_key(st, key):
    if key in ("1", "Enter") and st.get("tab_review") is not None:
        st.setdefault("answers", []).append({"answers": st["tab_review"]})
        st["tab_review"] = None
        st["kind"] = "input"
    elif key in ("1", "Enter"):
        r = st["review"]
        st.setdefault("answers", []).append({"question": r["question"], "labels": r["labels"]})
        st["kind"] = "input"
    elif key == "Escape":
        st["kind"] = "ask"


def perm_key(st, key):
    if len(key) == 1 and key.isdigit():
        p = st["perm"]
        d = int(key)
        if 1 <= d <= len(p["options"]):
            st.setdefault("answers", []).append({"permission": p["options"][d - 1]})
            if p.get("replace_after_key"):
                # another prompt of the same kind takes the place of the answered one
                st["perm"] = p["replace_after_key"]
            else:
                st["kind"] = "input"
    elif key == "Escape":
        st.setdefault("answers", []).append({"permission": "declined"})
        st["kind"] = "input"


def named_key(st, key):
    st.setdefault("keys", []).append(key)
    kind = st["kind"]
    if kind == "input":
        input_key(st, key)
    elif kind == "ask":
        ask_key(st, key)
    elif kind == "review":
        review_key(st, key)
    elif kind == "permission":
        perm_key(st, key)


def main(argv):
    args = list(argv)
    if args[:1] == ["-S"]:
        args = args[2:]
    if not args:
        return 1
    st = load()
    cmd = args[0]
    if cmd == "display-message":
        pane = args[args.index("-t") + 1]
        if pane != st["pane"]:
            return 1
        fmt = args[-1]
        if fmt == "#{session_name}":
            print(st["session_name"])
        elif fmt == "#{cursor_x},#{cursor_y}":
            print("%d,%d" % render(st)[1])
        else:
            print("\t".join([st["pane"], str(st["pane_pid"]), str(st["in_mode"]), str(st["dead"])]))
        return 0
    if cmd == "capture-pane":
        # the open question changes after the given capture (a prompt replaced in between)
        st["captures"] = st.get("captures", 0) + 1
        if st.get("change_at_capture") == st["captures"]:
            st["ask"]["question"] = st["change_question"]
        save(st)
        lines, _ = render(st)
        if "-N" in args:
            # real tmux pads every row to the pane width (110 columns here) with -N
            lines = [ln.ljust(PANE_WIDTH) for ln in lines]
        else:
            lines = [ln.rstrip(" ") for ln in lines]
        sys.stdout.write("\n".join(lines) + "\n")
        return 0
    if cmd == "send-keys":
        pane = args[args.index("-t") + 1]
        if pane != st["pane"]:
            return 1
        rest = args[args.index("-t") + 2:]
        if rest[:1] == ["-l"]:
            rest = rest[1:]
            if rest[:1] == ["--"]:
                rest = rest[1:]
            for item in rest:
                text_key(st, item)
        else:
            for key in rest:
                named_key(st, key)
        save(st)
        return 0
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
PYEOF
} > "$FT/tmux"
chmod +x "$FT/tmux"

cat > "$TMP/scenario.py" <<'PYEOF'
"""Write the fake pane state of one scenario: scenario.py NAME TARGET_PID STATE [OTHER_PID]."""
import json
import sys

name, pid, path = sys.argv[1], int(sys.argv[2]), sys.argv[3]
other = int(sys.argv[4]) if len(sys.argv) > 4 else pid
ASK = {"header": "Color", "question": "Pick a color?", "multi": False, "cursor": 0,
       "checked": [False] * 4, "free": None,
       "options": [{"label": "Red", "desc": "A warm, strong color."},
                   {"label": "Green", "desc": "A calm, natural color."},
                   {"label": "Blue", "desc": "A cool, neutral color."}]}
FRUIT = {"header": "Fruit", "question": "Which fruits?", "multi": True, "cursor": 0,
         "checked": [False] * 4, "free": None,
         "options": [{"label": "Apple", "desc": "A crisp fruit."},
                     {"label": "Banana", "desc": "A soft, sweet fruit."},
                     {"label": "Cherry", "desc": "A small round stone fruit."}]}
PERM = {"title": "Bash command", "body": ["Run the listing", "ls /tmp/fixture-dir"],
        "options": ["Yes", "Yes, and don't ask again for: ls",
                    "No, and tell Claude what to do differently (esc)"], "cursor": 0}
TEN = ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"]


def base(**kw):
    st = {"pane": "%5", "pane_pid": pid, "in_mode": 0, "dead": 0, "session_name": "work",
          "kind": "input", "busy": False, "input": "", "cursor": None, "submitted": [],
          "typed": [], "keys": [], "answers": []}
    st.update(kw)
    return st


def tabs_state(preset=False, last_multi=False):
    color = {"header": "Color", "question": "Pick a color?", "multi": False, "cursor": 0,
             "checked": [False] * 4, "free": None,
             "options": [{"label": "Red", "desc": "A warm color."},
                         {"label": "Green", "desc": "A calm color."},
                         {"label": "Blue", "desc": "A cool color."}]}
    fruit_q = fruit([False, False, preset] if preset else None)
    size = {"header": "Size", "question": "Pick a size?", "multi": False, "cursor": 0,
            "checked": [False] * 3, "free": None,
            "options": [{"label": "Small", "desc": "The compact one."},
                        {"label": "Large", "desc": "The spacious one."}]}
    questions = [color, fruit_q, size]
    if last_multi:
        questions = [color, fruit_q]
    return {"kind": "ask", "ask": json.loads(json.dumps(questions[0])),
            "questions": questions, "qi": 0, "collected": []}


def fruit(checked=None):
    f = json.loads(json.dumps(FRUIT))
    if checked:
        f["checked"][:len(checked)] = checked
    return f


SCEN = {
    "idle": base(),
    "busy": base(busy=True),
    "typed": base(input="half written"),
    "multirow": base(input="first line\nsecond"),
    "midcursor": base(input="abc def", cursor=3),
    "ask": base(kind="ask", ask=json.loads(json.dumps(ASK))),
    "ask_multi": base(kind="ask", ask=fruit()),
    "ask_multi_preset": base(kind="ask", ask=fruit([False, True, False])),
    "review": base(kind="review", ask=fruit(),
                   review={"question": "Which fruits?", "labels": ["Apple", "Cherry"], "cursor": 0}),
    "permission": base(kind="permission", perm=json.loads(json.dumps(PERM))),
    "slash": base(kind="slash", input="/comp"),
    "trust": base(kind="trust"),
    "dead": base(dead=1),
    "copy": base(in_mode=1),
    "foreign": base(pane_pid=other),
    "inject_ask": base(inject_after_text=1, inject_kind="ask", ask=json.loads(json.dumps(ASK))),
    "inject_append": base(inject_after_text=1, inject_kind="append", inject_text="Z"),
    "enter_noop": base(enter_noop=True),
    "break_submits": base(input="", break_submits=True),
    "inject_ask_force": base(input="half written", inject_after_text=1, inject_kind="ask",
                             ask=json.loads(json.dumps(ASK))),
    "permission_cmd_b": base(kind="permission", perm=dict(json.loads(json.dumps(PERM)),
                             body=["Run the listing", "rm -rf /tmp/fixture-dir"])),
    "permission_replaced": base(kind="permission", perm=dict(json.loads(json.dumps(PERM)),
                                replace_after_key=dict(json.loads(json.dumps(PERM)),
                                                       body=["Run the listing",
                                                             "rm -rf /tmp/fixture-dir"]))),
    "ask10": base(kind="ask", ask=dict(json.loads(json.dumps(ASK)), cursor=0,
                  options=[{"label": n, "desc": "The %s option." % n} for n in TEN])),
    "ask10_multi": base(kind="ask", ask=dict(json.loads(json.dumps(FRUIT)), cursor=0,
                        checked=[False] * 11,
                        options=[{"label": n, "desc": "The %s option." % n} for n in TEN])),
    "ask_free_held": base(kind="ask", ask=dict(json.loads(json.dumps(ASK)), free="old")),
    "tabs": base(**tabs_state()),
    "tabs_preset": base(**tabs_state(preset=True)),
    "tabs_last_multi": base(**tabs_state(last_multi=True)),
    "review_labels": base(kind="review", ask=fruit(),
                          review={"question": "Which fruits?", "labels": ["Apple", "Cherry"],
                                  "cursor": 0, "options": ["Send it", "Cancel"]}),
    "ask_changed": base(kind="ask", ask=json.loads(json.dumps(ASK)), change_at_capture=2,
                        change_question="A different question?"),
}
with open(path, "w", encoding="utf-8") as fh:
    json.dump(SCEN[name], fh, ensure_ascii=False)
PYEOF

cat > "$TMP/target.py" <<'PYEOF'
"""Fake Claude process: writes its session descriptor, records itself through the real
session registry hook (the hook's process chain then holds this pid), and waits."""
import json
import os
import subprocess
import sys
import time

sid, cfg, hook, pidfile = sys.argv[1:5]
pid = os.getpid()
start = open("/proc/self/stat", encoding="utf-8").read().rsplit(")", 1)[1].split()[19]
os.makedirs(os.path.join(cfg, "sessions"), exist_ok=True)
with open(os.path.join(cfg, "sessions", "%d.json" % pid), "w", encoding="utf-8") as fh:
    json.dump({"pid": pid, "sessionId": sid, "name": "acme-task", "nameSource": "user",
               "procStart": start}, fh)
with open(pidfile, "w", encoding="utf-8") as fh:
    fh.write(str(pid))
# the fake pane must name this pid before the registry records the pane (the test writes it)
state = os.environ.get("FAKE_PANE_STATE", "")
for _ in range(100):
    if state and os.path.exists(state):
        break
    time.sleep(0.1)
payload = json.dumps({"session_id": sid, "hook_event_name": "SessionStart"})
subprocess.run(["bash", hook], input=payload.encode("utf-8"), env=os.environ, check=False)
time.sleep(3600)
PYEOF

(
    export TMUX="/tmp/owner-type-test-fake.sock,1,0" TMUX_PANE="%5" CLAUDE_CONFIG_DIR="$CFG"
    export PATH="$FT:$BASE" FAKE_PANE_STATE="$STATE"
    exec -a claude "$PY" "$TMP/target.py" "$SID" "$CFG" "$HOOK" "$PIDFILE"
) &
for _ in $(seq 1 50); do [ -s "$PIDFILE" ] && break; sleep 0.1; done
TARGET_PID="$(cat "$PIDFILE" 2>/dev/null || echo 0)"
PIDS="$TARGET_PID"
cleanup() {
    for p in $PIDS; do kill -TERM "$p" 2>/dev/null || true; done
}
trap cleanup EXIT

scenario() { "$PY" "$TMP/scenario.py" "$1" "$TARGET_PID" "$STATE" "${2:-$$}"; }
# the fake target records its pane only once the pane state names it: wait for that entry
scenario idle
for _ in $(seq 1 50); do grep -q '"pane": "%5"' "$CFG/credo/session-registry/$SID.json" 2>/dev/null && break; sleep 0.1; done
st() { "$PY" -c 'import json,sys; s=json.load(open(sys.argv[1], encoding="utf-8")); print(repr(eval(sys.argv[2])))' "$STATE" "$1"; }
run_cli() { # CLI arguments; sets RC and OUT
    OUT="$(env PATH="$FT:$BASE" CLAUDE_CONFIG_DIR="$CFG" FAKE_PANE_STATE="$STATE" \
        CREDO_OWNER_TYPE_TYPE_PAUSE=0.01 CREDO_OWNER_TYPE_KEY_PAUSE=0.02 \
        CREDO_OWNER_TYPE_CONFIRM_WAIT=0.6 CREDO_OWNER_TYPE_SETTLE=0.05 \
        "$PY" "$CLI" "$@" 2>&1)"
    RC=$?
}

# --- B1. setup sanity: the registry resolves the fake target as live ----------------
check "target pid written" "1" "$([ "$TARGET_PID" -gt 1 ] 2>/dev/null && echo 1 || echo 0)"
run_cli_reg() { OUT="$(env PATH="$FT:$BASE" CLAUDE_CONFIG_DIR="$CFG" FAKE_PANE_STATE="$STATE" "$PY" "$SCRIPT_DIR/credo-session-registry.py" resolve "$SID" 2>&1)"; RC=$?; }
scenario idle
run_cli_reg
check "registry resolves the fake target live" "0" "$RC"
check "registry shows the pane" "1" "$(printf '%s' "$OUT" | grep -c 'pane %5')"

# --- B2. send: normal mode -----------------------------------------------------------
scenario idle
run_cli send --session "$SID" --text "hello owner"
check "send to an empty input: exit 0" "0" "$RC"
check "send to an empty input: delivered" "1" "$(printf '%s' "$OUT" | grep -c '^delivered')"
check "send to an empty input: submitted once" "['hello owner']" "$(st 's.get("submitted")')"
check "send to an empty input: no key left in the input" "''" "$(st 's["input"]')"
check "send: the Enter was the only key" "['Enter']" "$(st 's.get("keys")')"

scenario busy
run_cli send --session "$SID" --text "queued owner"
check "send while busy: exit 0 (queued by Claude Code)" "0" "$RC"
check "send while busy: submitted" "['queued owner']" "$(st 's.get("submitted")')"

scenario idle
run_cli send --session "$SID" --text "$(printf 'line one\nline two')"
check "multi-line: exit 0" "0" "$RC"
check "multi-line: one message with a line break" "['line one\\nline two']" "$(st 's.get("submitted")')"
check "multi-line: backslash then Enter, then the final Enter" \
    "['Enter', 'Enter']" "$(st 's.get("keys")')"
check "multi-line: the line break is typed as a backslash" "1" "$(st 'sum(1 for x in s.get("typed") if x == "\\")')"

scenario idle
long="$(printf 'x%.0s' $(seq 1 450))"
run_cli send --session "$SID" --text "$long"
check "long text: exit 0" "0" "$RC"
check "long text: typed in 200, 200 and 50 character pieces" "[200, 200, 50]" "$(st '[len(x) for x in s.get("typed")]')"
check "long text: submitted whole" "450" "$(st 'len(s.get("submitted")[0])')"

scenario idle
printf 'from stdin\n' | env PATH="$FT:$BASE" CLAUDE_CONFIG_DIR="$CFG" FAKE_PANE_STATE="$STATE" \
    CREDO_OWNER_TYPE_TYPE_PAUSE=0.01 CREDO_OWNER_TYPE_KEY_PAUSE=0.02 CREDO_OWNER_TYPE_CONFIRM_WAIT=0.6 \
    "$PY" "$CLI" send --session "$SID" --stdin > "$TMP/stdin.out" 2>&1
check "stdin: exit 0" "0" "$?"
check "stdin: the trailing newline is not sent" "['from stdin']" "$(st 's.get("submitted")')"

# --- B3. send: refusals (nothing typed) ----------------------------------------------
refusal_case() { # name scenario expected-substring extra-args...
    local name="$1" scen="$2" want="$3"; shift 3
    scenario "$scen"
    run_cli send --session "$SID" --text "refused owner text" "$@"
    check "$name: exit 1" "1" "$RC"
    check "$name: nothing typed" "[]" "$(st 's.get("typed")')"
    check "$name: nothing submitted" "[]" "$(st 's.get("submitted")')"
    check "$name: reason named" "1" "$(printf '%s' "$OUT" | grep -c "$want")"
}
refusal_case "typed text without --force-append" typed "force-append"
refusal_case "text in the input, cursor mid text, no force" midcursor "force-append"
refusal_case "Ask box open" ask "Ask box"
refusal_case "permission prompt open" permission "permission prompt"
refusal_case "slash menu open" slash "dialog or menu"
refusal_case "trust dialog open" trust "no input box"
refusal_case "pane dead" dead "stale"
refusal_case "pane in copy mode" copy "copy mode"
# a process that is not in the target's ancestor chain (the test shell is an ancestor)
"$PY" -c 'import time; time.sleep(600)' &
OTHER_PID=$!
PIDS="$PIDS $OTHER_PID"
scenario foreign "$OTHER_PID"
run_cli send --session "$SID" --text "refused owner text"
check "pane of another process: exit 1" "1" "$RC"
check "pane of another process: nothing typed" "[]" "$(st 's.get("typed")')"
check "pane of another process: named as a stale session" "1" "$(printf '%s' "$OUT" | grep -c '^refused: stale')"
run_cli send --session no-such-session --text "refused owner text"
check "unknown session: exit 3" "3" "$RC"

# --- B4. send: force-append ----------------------------------------------------------
scenario typed
run_cli send --session "$SID" --text "more" --force-append
check "force-append: exit 0" "0" "$RC"
check "force-append: appended with a space, existing text kept" "['half written more']" "$(st 's.get("submitted")')"

scenario multirow
run_cli send --session "$SID" --text "third" --force-append
check "force-append on a two-row input: exit 0" "0" "$RC"
check "force-append on a two-row input: whole input submitted" "['first line\\nsecond third']" "$(st 's.get("submitted")')"

scenario midcursor
run_cli send --session "$SID" --text "more" --force-append
check "force-append with the cursor mid text: exit 1" "1" "$RC"
check "force-append with the cursor mid text: nothing typed" "[]" "$(st 's.get("typed")')"
check "force-append with the cursor mid text: text unchanged" "'abc def'" "$(st 's["input"]')"

scenario typed
run_cli send --session "$SID" --text "more" --force-append --dry-run
check "force-append dry-run: exit 0" "0" "$RC"
check "force-append dry-run: nothing typed" "[]" "$(st 's.get("typed")')"

# --- B5. send: confirm failure, unconfirmed Enter, dry-run -----------------------------
scenario inject_ask
run_cli send --session "$SID" --text "abcdef"
check "dialog opens while typing: exit 1" "1" "$RC"
check "dialog opens while typing: nothing submitted" "[]" "$(st 's.get("submitted")')"
check "dialog opens while typing: no Enter sent" "[]" "$(st 's.get("keys")')"
check "dialog opens while typing: reason named" "1" "$(printf '%s' "$OUT" | grep -c 'a dialog opened while typing')"

scenario inject_ask
run_cli send --session "$SID" --text "$long"
check "dialog opens between two pieces: exit 1" "1" "$RC"
check "dialog opens between two pieces: no further piece typed" "1" "$(st 'len(s.get("typed"))')"
check "dialog opens between two pieces: no Enter sent" "[]" "$(st 's.get("keys")')"
check "dialog opens between two pieces: reason named" "1" "$(printf '%s' "$OUT" | grep -c 'a dialog opened while typing')"

scenario inject_append
run_cli send --session "$SID" --text "abcdef"
check "text changed while typing: exit 1" "1" "$RC"
check "text changed while typing: nothing submitted" "[]" "$(st 's.get("submitted")')"
check "text changed while typing: the foreign character is not deleted" "'abcdefZ'" "$(st 's["input"]')"
check "text changed while typing: reason named" "1" "$(printf '%s' "$OUT" | grep -c 'the input field changed while typing')"

scenario enter_noop
run_cli send --session "$SID" --text "maybe"
check "Enter without effect: exit 4" "4" "$RC"
check "Enter without effect: reported unconfirmed" "1" "$(printf '%s' "$OUT" | grep -c '^unconfirmed')"

scenario idle
run_cli send --session "$SID" --text "dry only" --dry-run
check "dry-run: exit 0" "0" "$RC"
check "dry-run: nothing typed" "[]" "$(st 's.get("typed")')"
check "dry-run: reported" "1" "$(printf '%s' "$OUT" | grep -c '^dry-run')"

# --- B6. send: input validation (usage errors) ---------------------------------------
scenario idle
run_cli send --session "$SID" --text "$(printf 'bad\001char')"
check "control character: exit 2" "2" "$RC"
check "control character: nothing typed" "[]" "$(st 's.get("typed")')"
run_cli send --session "$SID" --text "$(printf 'x%.0s' $(seq 1 4001))"
check "over the size limit: exit 2" "2" "$RC"
run_cli send --session "$SID" --text "$(printf 'tab\there')"
check "tab character: exit 2" "2" "$RC"

# --- B7. answer: Ask box ---------------------------------------------------------------
scenario ask_changed
run_cli answer --session "$SID" --ask 2
check "prompt replaced after it was read: refused" "1" "$RC"
check "prompt replaced after it was read: nothing sent" "[]" "$(st 's.get("keys")')"
check "prompt replaced after it was read: reported" "1" "$(printf '%s' "$OUT" | grep -c 'changed since it was read')"

scenario ask
run_cli answer --session "$SID" --ask 2
check "answer digit: exit 0" "0" "$RC"
check "answer digit: the second option was selected" \
    "[{'question': 'Pick a color?', 'label': 'Green'}]" "$(st 's.get("answers")')"
check "answer digit: the box is closed" "'input'" "$(st 's["kind"]')"

scenario ask
run_cli answer --session "$SID" --ask "green"
check "answer label (case-insensitive): exit 0" "0" "$RC"
check "answer label: selected by its digit" "['Green']" "$(st '[a.get("label") for a in s.get("answers")]')"

scenario ask
run_cli answer --session "$SID" --ask "Purple"
check "answer unknown label: exit 1" "1" "$RC"
check "answer unknown label: nothing sent" "[]" "$(st 's.get("keys")')"

scenario ask
run_cli answer --session "$SID" --ask esc
check "answer esc: exit 0" "0" "$RC"
check "answer esc: declined" "[{'question': 'Pick a color?', 'declined': True}]" "$(st 's.get("answers")')"
check "answer esc: the key is Escape" "['Escape']" "$(st 's.get("keys")')"

scenario ask
run_cli answer --session "$SID" --ask "free:zeta word"
check "answer free text: exit 0" "0" "$RC"
check "answer free text: typed into the Type something row" \
    "[{'question': 'Pick a color?', 'free': 'zeta word'}]" "$(st 's.get("answers")')"
check "answer free text: moved down to the Type something row first" \
    "['Down', 'Down', 'Down', 'Enter']" "$(st 's.get("keys")')"

scenario ask
run_cli answer --session "$SID" --ask 4
check "answer digit on the Type something row: exit 1" "1" "$RC"
check "answer digit on the Type something row: nothing sent" "[]" "$(st 's.get("keys")')"

scenario ask_multi
run_cli answer --session "$SID" --ask 2
check "answer digit on a multi select: exit 1" "1" "$RC"
check "answer digit on a multi select: nothing sent" "[]" "$(st 's.get("keys")')"

scenario ask_multi
run_cli answer --session "$SID" --ask "multi:1,3"
check "multi select: exit 0" "0" "$RC"
check "multi select: review and submit" \
    "[{'question': 'Which fruits?', 'labels': ['Apple', 'Cherry']}]" "$(st 's.get("answers")')"
check "multi select: toggles, Right, then the review is submitted with 1" \
    "['1', '3', 'Right', '1']" "$(st 's.get("keys")')"

scenario ask_multi_preset
run_cli answer --session "$SID" --ask "multi:1,3"
check "multi select with Banana checked: exit 0" "0" "$RC"
check "multi select with Banana checked: toggled to exactly 1 and 3" \
    "[{'question': 'Which fruits?', 'labels': ['Apple', 'Cherry']}]" "$(st 's.get("answers")')"
check "multi select with Banana checked: toggles 1, 2 and 3" "['1', '2', '3', 'Right', '1']" "$(st 's.get("keys")')"

scenario ask
run_cli answer --session "$SID" --ask 2 --dry-run
check "answer dry-run: exit 0" "0" "$RC"
check "answer dry-run: no key sent" "[]" "$(st 's.get("keys")')"

scenario idle
run_cli answer --session "$SID" --ask 2
check "answer on an idle input: exit 1" "1" "$RC"
check "answer on an idle input: no Ask box named" "1" "$(printf '%s' "$OUT" | grep -c 'no Ask box or permission prompt')"

# --- B8. answer: permission prompt and review page ---------------------------------------
scenario review
run_cli answer --session "$SID" --ask 1
check "review page digit 1 submits: exit 0" "0" "$RC"
check "review page digit 1: submitted the review" \
    "[{'question': 'Which fruits?', 'labels': ['Apple', 'Cherry']}]" "$(st 's.get("answers")')"

scenario review
run_cli answer --session "$SID" --ask 2
check "review page digit 2 (Cancel): refused" "1" "$RC"
check "review page digit 2: nothing sent" "[]" "$(st 's.get("keys")')"

scenario review
run_cli answer --session "$SID" --ask esc
check "review page esc: refused" "1" "$RC"

# --- B9. answer: a trust dialog or a stale session is refused ----------------------------
scenario trust
run_cli answer --session "$SID" --ask 1
check "unknown dialog: exit 1" "1" "$RC"
check "unknown dialog: nothing sent" "[]" "$(st 's.get("keys")')"

scenario dead
run_cli answer --session "$SID" --ask 1
check "dead pane: exit 1" "1" "$RC"

# --- B10. delivery log and --json ------------------------------------------------------
check "log: created" "1" "$([ -f "$LOGF" ] && echo 1 || echo 0)"
check "log: owner-only file mode" "600" "$(stat -c %a "$LOGF" 2>/dev/null)"
check "log: one line per attempt" "1" "$([ "$(grep -c 'session=' "$LOGF")" -gt 10 ] && echo 1 || echo 0)"
check "log: no message content by default" "0" "$(grep -c 'hello owner\|queued owner\|refused owner text' "$LOGF")"
check "log: refusals are logged with their result" "1" "$([ "$(grep -c 'result=refused' "$LOGF")" -gt 0 ] && echo 1 || echo 0)"
check "log: mode and character count are logged" "1" "$([ "$(grep -c 'mode=normal chars=12 result=delivered' "$LOGF")" -gt 0 ] && echo 1 || echo 0)"
scenario idle
env CREDO_OWNER_TYPE_LOG_TEXT=1 PATH="$FT:$BASE" CLAUDE_CONFIG_DIR="$CFG" FAKE_PANE_STATE="$STATE" \
    CREDO_OWNER_TYPE_TYPE_PAUSE=0.01 CREDO_OWNER_TYPE_KEY_PAUSE=0.02 CREDO_OWNER_TYPE_CONFIRM_WAIT=0.6 \
    "$PY" "$CLI" send --session "$SID" --text "logged text on request" > /dev/null 2>&1
check "log: text only with CREDO_OWNER_TYPE_LOG_TEXT=1" "1" "$(grep -c 'logged text on request' "$LOGF")"
scenario idle
run_cli send --session "$SID" --text "json owner" --dry-run --json
check "json: exit 0" "0" "$RC"
check "json: status field" "1" "$(printf '%s' "$OUT" | "$PY" -c 'import json,sys; d=json.load(sys.stdin); print(1 if d["status"]=="dry-run" else 0)')"

# --- B12. security fix round: prompt binding, persist, force mode, digits, log -----------
# red tests written before the code: show and --expect, --persist, no BSpace in force mode,
# partly sent, same-kind replacement, ASCII digits, options above 9, review label, FIFO log
show_digest() { # digest of the open prompt, read with show --json
    env PATH="$FT:$BASE" CLAUDE_CONFIG_DIR="$CFG" FAKE_PANE_STATE="$STATE" \
        "$PY" "$CLI" show --session "$SID" --json 2>/dev/null \
        | "$PY" -c 'import json,sys; print(json.load(sys.stdin).get("digest") or "")'
}
EXP_KEYS_10="['1'$(printf ", 'Down'%.0s" $(seq 1 9)), 'Space', 'Right', '1']"
EXP_KEYS_DOWN9="[$(printf "'Down', %.0s" $(seq 1 9))'Enter']"

scenario permission
run_cli show --session "$SID"
check "show: exit 0" "0" "$RC"
check "show: names the permission prompt" "1" "$(printf '%s' "$OUT" | grep -q 'kind: permission' && echo 1 || echo 0)"
check "show: shows the command line" "1" "$(printf '%s' "$OUT" | grep -c 'ls /tmp/fixture-dir')"
check "show: shows the options" "1" "$(printf '%s' "$OUT" | grep -c "don't ask again")"
check "show: prints a sha256 digest" "1" "$(printf '%s' "$OUT" | grep -cE '[0-9a-f]{64}')"
run_cli show --session "$SID" --json
check "show --json: exit 0" "0" "$RC"
check "show --json: digest is 64 hex" "1" "$(printf '%s' "$OUT" | "$PY" -c 'import json,re,sys; d=json.load(sys.stdin)["digest"]; print(1 if re.fullmatch(r"[0-9a-f]{64}", d or "") else 0)')"
check "show --json: kind permission" "'permission'" "$(printf '%s' "$OUT" | "$PY" -c 'import json,sys; print(repr(json.load(sys.stdin)["kind"]))')"
check "show --json: the command line is in body" "1" "$(printf '%s' "$OUT" | "$PY" -c 'import json,sys; print(1 if any("ls /tmp/fixture-dir" in x for x in json.load(sys.stdin)["body"]) else 0)')"
scenario idle
run_cli show --session "$SID" --json
check "show on an idle input: exit 0" "0" "$RC"
check "show on an idle input: kind input, no digest" "1" "$(printf '%s' "$OUT" | "$PY" -c 'import json,sys; d=json.load(sys.stdin); print(1 if d["kind"]=="input" and d["digest"] is None else 0)')"

# prompt binding: a permission prompt needs the digest of the prompt that was read
scenario permission
D_A="$(show_digest)"
check "digest of the permission prompt is read" "1" "$([ ${#D_A} -eq 64 ] && echo 1 || echo 0)"
scenario permission
run_cli answer --session "$SID" --ask 1
check "permission without --expect: refused" "1" "$RC"
check "permission without --expect: nothing sent" "[]" "$(st 's.get("keys")')"
check "permission without --expect: --expect named" "1" "$(printf '%s' "$OUT" | grep -c -- '--expect')"
scenario permission
run_cli answer --session "$SID" --ask 1 --expect "$D_A"
check "permission with the digest that was read: exit 0" "0" "$RC"
check "permission with the digest: answered with Yes" "[{'permission': 'Yes'}]" "$(st 's.get("answers")')"
scenario permission_cmd_b
run_cli answer --session "$SID" --ask 1 --expect "$D_A"
check "same options, other command, old digest: refused" "1" "$RC"
check "same options, other command: nothing sent" "[]" "$(st 's.get("keys")')"
check "same options, other command: nothing answered" "[]" "$(st 's.get("answers")')"
scenario ask
D_ASK="$(show_digest)"
scenario ask
run_cli answer --session "$SID" --ask 2 --expect "$D_ASK"
check "ask with the matching digest: exit 0" "0" "$RC"
check "ask with the matching digest: answered" "[{'question': 'Pick a color?', 'label': 'Green'}]" "$(st 's.get("answers")')"
scenario ask
run_cli answer --session "$SID" --ask 2 --expect "$(printf '0%.0s' $(seq 1 64))"
check "ask with a wrong digest: refused" "1" "$RC"
check "ask with a wrong digest: nothing sent" "[]" "$(st 's.get("keys")')"
scenario ask
run_cli answer --session "$SID" --ask 2
check "ask without --expect is still honoured: exit 0" "0" "$RC"

# persist options need --persist; the result and the log name the label
scenario permission
D_P="$(show_digest)"
run_cli answer --session "$SID" --ask 2 --expect "$D_P"
check "persist option without --persist: refused" "1" "$RC"
check "persist option without --persist: nothing sent" "[]" "$(st 's.get("keys")')"
check "persist option without --persist: says --persist" "1" "$(printf '%s' "$OUT" | grep -c -- '--persist')"
scenario permission
D_P="$(show_digest)"
run_cli answer --session "$SID" --ask 2 --expect "$D_P" --persist
check "persist option with --persist: exit 0" "0" "$RC"
check "persist option with --persist: answer recorded" \
    "[{'permission': \"Yes, and don't ask again for: ls\"}]" "$(st 's.get("answers")')"
check "persist option: the result names the label" "1" "$(printf '%s' "$OUT" | grep -c "ask again for: ls")"
check "persist option: the log names the label" "1" "$(grep -c "option=.*ask again for: ls" "$LOGF")"

# force mode never removes text: an abort leaves the draft and the appended text, reported
scenario inject_ask_force
run_cli send --session "$SID" --text "abcdef" --force-append
check "force-append abort: exit 1" "1" "$RC"
check "force-append abort: no BSpace sent" "0" "$(st 'sum(1 for k in s.get("keys") if k == "BSpace")')"
check "force-append abort: the draft and the appended text stay" "'half written abcdef'" "$(st 's["input"]')"
check "force-append abort: reported as left in the input field" "1" "$(printf '%s' "$OUT" | grep -c 'left in the input field')"
check "force-append abort: nothing submitted" "[]" "$(st 's.get("submitted")')"

# a line break that submits early: partly sent, exit 4, no further key
scenario break_submits
run_cli send --session "$SID" --text "$(printf 'line one\nline two')"
check "line break submitted the first part: exit 4" "4" "$RC"
check "line break submitted the first part: reported partly sent" "1" "$(printf '%s' "$OUT" | grep -c 'partly sent')"
check "line break submitted the first part: only the first part went out" "['line one\\\\']" "$(st 's.get("submitted")')"
check "line break submitted the first part: no further key" "['Enter']" "$(st 's.get("keys")')"

# a prompt answered and replaced by another of the same kind is answered, not unconfirmed
scenario permission_replaced
D_R="$(show_digest)"
run_cli answer --session "$SID" --ask 1 --expect "$D_R"
check "replaced by another prompt of the same kind: exit 0" "0" "$RC"
check "replaced by another prompt of the same kind: reported answered" "1" "$(printf '%s' "$OUT" | grep -c '^answered')"

# review page: the first option must be Submit answers
scenario review_labels
run_cli answer --session "$SID" --ask 1
check "review page without Submit answers first: refused" "1" "$RC"
check "review page without Submit answers first: nothing sent" "[]" "$(st 's.get("keys")')"

# free text: the Type something row must be empty before typing
scenario ask_free_held
run_cli answer --session "$SID" --ask "free:new text"
check "Type something row already holds text: refused" "1" "$RC"
check "Type something row already holds text: nothing sent" "[]" "$(st 's.get("keys")')"

# digits: ASCII only, options above 9 are navigated, the text 10 is never sent
scenario ask
run_cli answer --session "$SID" --ask "$(printf '\302\262')"
check "superscript two is not a digit: refused" "1" "$RC"
check "superscript two: nothing sent" "[]" "$(st 's.get("keys")')"
run_cli answer --session "$SID" --ask 10
check "answer 10 as a digit is a usage error: exit 2" "2" "$RC"
scenario ask10
run_cli answer --session "$SID" --ask ten
check "option 10 by label: exit 0" "0" "$RC"
check "option 10 by label: navigated down nine times and entered" "$EXP_KEYS_DOWN9" "$(st 's.get("keys")')"
check "option 10 by label: answer recorded" "[{'question': 'Pick a color?', 'label': 'ten'}]" "$(st 's.get("answers")')"
scenario ask10_multi
run_cli answer --session "$SID" --ask "multi:1,10"
check "multi with option 10: exit 0" "0" "$RC"
check "multi with option 10: digit, navigation, Space, Right, review 1" "$EXP_KEYS_10" "$(st 's.get("keys")')"
check "multi with option 10: answered one and ten" \
    "[{'question': 'Which fruits?', 'labels': ['one', 'ten']}]" "$(st 's.get("answers")')"

# commands: a trailing backslash and a leading exclamation mark
scenario idle
run_cli send --session "$SID" --text 'trailing\'
check "trailing backslash: exit 2" "2" "$RC"
check "trailing backslash: nothing typed" "[]" "$(st 's.get("typed")')"
scenario idle
run_cli send --session "$SID" --text "! echo owner"
check "leading exclamation mark is sent as typed: exit 0" "0" "$RC"
check "leading exclamation mark: submitted as typed" "['! echo owner']" "$(st 's.get("submitted")')"

# the log: a FIFO or a symlink is refused without a hang (ensure_log checks like write)
mv "$LOGF" "$LOGF.saved"
mkfifo "$LOGF"
scenario idle
OUT="$(timeout 20 env PATH="$FT:$BASE" CLAUDE_CONFIG_DIR="$CFG" FAKE_PANE_STATE="$STATE" \
    CREDO_OWNER_TYPE_CONFIRM_WAIT=0.6 "$PY" "$CLI" send --session "$SID" --text "fifo owner" 2>&1)"
RC=$?
check "log is a FIFO: refused without a hang (exit 1)" "1" "$RC"
check "log is a FIFO: nothing typed" "[]" "$(st 's.get("typed")')"
mv -f "$LOGF.saved" "$LOGF"
mv "$LOGF" "$LOGF.saved"
ln -s "$TMP/elsewhere.log" "$LOGF"
scenario idle
run_cli send --session "$SID" --text "link owner"
check "log is a symlink: refused (exit 1)" "1" "$RC"
check "log is a symlink: nothing typed" "[]" "$(st 's.get("typed")')"
check "log is a symlink: the target was not created" "0" "$([ -e "$TMP/elsewhere.log" ] && echo 1 || echo 0)"
mv -f "$LOGF.saved" "$LOGF"

# --- B13. live finding: tabbed multi-question Ask box (Right = next question) -----------
# the review page lists a multi answer in selection order; the labels match as sets
scenario tabs
run_cli answer --session "$SID" --ask 2
check "tabs: question 1 answered by digit: exit 0" "0" "$RC"
check "tabs: the next question is open" "'Which fruits?'" "$(st 's["ask"]["question"]')"
run_cli answer --session "$SID" --ask "multi:1,3"
check "tabs: multi question answered with Right to the next question: exit 0" "0" "$RC"
check "tabs: multi keys are toggles then Right" "['2', '1', '3', 'Right']" "$(st 's.get("keys")')"
check "tabs: the size question is open" "'Pick a size?'" "$(st 's["ask"]["question"]')"
run_cli answer --session "$SID" --ask 1
check "tabs: the last question by digit leads to the review page: exit 0" "0" "$RC"
check "tabs: the review page is open" "'review'" "$(st 's["kind"]')"
run_cli answer --session "$SID" --ask 1
check "tabs: the review is submitted with 1: exit 0" "0" "$RC"
check "tabs: all three answers submitted" \
    "[{'answers': [{'question': 'Pick a color?', 'label': 'Green'}, {'question': 'Which fruits?', 'labels': ['Apple', 'Cherry']}, {'question': 'Pick a size?', 'label': 'Small'}]}]" \
    "$(st 's.get("answers")')"

# preset selection and the review in selection order (Cherry was checked first)
scenario tabs_preset
run_cli answer --session "$SID" --ask 2
run_cli answer --session "$SID" --ask "multi:1,3"
check "tabs preset: only option 1 is toggled (3 was already checked), then Right" \
    "['2', '1', 'Right']" "$(st 's.get("keys")')"
run_cli answer --session "$SID" --ask 1
run_cli answer --session "$SID" --ask 1
check "tabs preset: the review lists Cherry, Apple and is submitted" \
    "[{'answers': [{'question': 'Pick a color?', 'label': 'Green'}, {'question': 'Which fruits?', 'labels': ['Cherry', 'Apple']}, {'question': 'Pick a size?', 'label': 'Small'}]}]" \
    "$(st 's.get("answers")')"

# the last question is the multi select: Right leads to the review page, which then submits
scenario tabs_last_multi
run_cli answer --session "$SID" --ask 2
run_cli answer --session "$SID" --ask "multi:1,3"
check "tabs, multi last: Right leads to the review: exit 0" "0" "$RC"
check "tabs, multi last: the review page is open" "'review'" "$(st 's["kind"]')"
run_cli answer --session "$SID" --ask 1
check "tabs, multi last: review submitted: exit 0" "0" "$RC"
check "tabs, multi last: answers submitted" \
    "[{'answers': [{'question': 'Pick a color?', 'label': 'Green'}, {'question': 'Which fruits?', 'labels': ['Apple', 'Cherry']}]}]" \
    "$(st 's.get("answers")')"

# --- B11. the target goes away: stale, nothing typed -------------------------------------
kill -TERM "$TARGET_PID" 2>/dev/null
for _ in $(seq 1 30); do kill -0 "$TARGET_PID" 2>/dev/null || break; sleep 0.1; done
scenario idle
run_cli send --session "$SID" --text "after exit"
check "target gone: exit 1" "1" "$RC"
check "target gone: nothing typed" "[]" "$(st 's.get("typed")')"

echo "passed: $PASS, failed: $FAIL"
echo "temp dir (not removed, see header): $TMP"
[ "$FAIL" -eq 0 ]
