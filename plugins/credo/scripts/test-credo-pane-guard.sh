#!/bin/bash
# Tests for credo_pane_guard.py - pure checks on invented capture text, no tmux:
#   - the input box finder accepts a box of up to MAX_BOX_LINES rows between its rules.
#     Claude Code shows a long input field up to about half the pane height minus 5 rows,
#     so at 53 pane rows the field fills 21 rows, which the old limit of 20 rejected (the
#     box was then not found and the field was never recognised as empty or own text)
#   - a box one row beyond the limit is still rejected (the limit is a bound, not removed)
#   - the exact comparison of assess() and own_text_at_end() are unchanged
#
# Usage: bash test-credo-pane-guard.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY="$(command -v python3 || true)"
if [ -z "$PY" ]; then echo "SKIP: python3 not found"; exit 0; fi
[ -f "$SCRIPT_DIR/credo_pane_guard.py" ] || { echo "FAIL: credo_pane_guard.py missing"; exit 1; }

PASS=0
FAIL=0
ok() { # name cond(0=pass)
    if [ "$2" = "0" ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; fi
}

"$PY" -I - "$SCRIPT_DIR" <<'PYEOF'
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, sys.argv[1])
import credo_pane_guard as g  # noqa: E402

RULE = "─" * 60


def box(rows, first="❯ "):
    """A capture with an input box of `rows` text rows, drawn the way Claude Code draws it."""
    lines = ["transcript line", RULE, first + "start"]
    for i in range(1, rows):
        lines.append("  row %d" % i)
    lines += [RULE, "  cwd: /tmp/invented", "  status line"]
    return "\n".join(lines)


def check(name, cond):
    print(("PASS " if cond else "FAIL ") + name)
    return 0 if cond else 1


def found(rows):
    return g.find_input_box(box(rows).split("\n")) is not None


fails = 0
fails += check("box of 20 rows is found", found(20))
fails += check("box of 21 rows is found (a 53-row pane fills 21 rows of input)", found(21))
fails += check("box of MAX_BOX_LINES rows is found", found(g.MAX_BOX_LINES))
fails += check("box one row beyond MAX_BOX_LINES is not found", not found(g.MAX_BOX_LINES + 1))
fails += check("the box limit is at least 21 rows", g.MAX_BOX_LINES >= 21)
empty21 = "\n".join(["transcript line", RULE, "❯ "] + ["  "] * 20 + [RULE, "  cwd: /tmp/invented"])
fails += check("empty box of 21 rows is idle",
               g.assess(empty21) == (True, "idle, input empty"))
fails += check("exact comparison unchanged: other text is not the expected text",
               g.assess(box(3), expect="something else")[0] is False)
fails += check("own_text_at_end unchanged: /compact at the end",
               g.own_text_at_end("x/compact", "/compact") and g.own_text_at_end("/compact", "/compact"))
fails += check("own_text_at_end unchanged: two stray characters are not own",
               not g.own_text_at_end("xy/compact", "/compact"))
fails += check("own_text_at_end unchanged: /compact not at the end",
               not g.own_text_at_end("/compact x", "/compact"))

sys.exit(1 if fails else 0)
PYEOF
ok "pane guard: input box limit, exact comparison and own_text_at_end unchanged" "$?"

echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]
