#!/bin/bash
# test-hooks-plugin-root - every hooks.json command of the own plugins (credo, dogma, hydra,
# limit, signal) still finds its script when the plugin root contains a space (for example
# a Windows profile like C:\Users\First Last\.claude\plugins\...).
#
# How Claude Code runs a shell-form hook command (checked in its bundled code): the command
# string goes to the shell unchanged and the shell expands ${CLAUDE_PLUGIN_ROOT} from the
# environment variable Claude Code sets (on Windows with forward slashes). Under Git Bash
# it also puts "bash " in front of the command when its first word, read with quotes
# removed, ends in .sh. Older releases and the plugin docs describe a plain text
# substitution of ${CLAUDE_PLUGIN_ROOT} before the shell. An unquoted placeholder splits at
# the space in all three cases, so every placeholder must be inside double quotes.
#
# The fixture builds a plugin root with a space in a fresh temp dir and puts a stub at
# every path a command references (the real hooks never run), then runs each command
# through bash in each of the three ways and checks that the first referenced script ran
# with its path arguments intact. Temp dirs only (removed on exit).
#
# Usage: scripts/test-hooks-plugin-root.sh [plugin ...]   (default: the own plugins)

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGINS="${*:-credo dogma hydra limit signal}"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/hooks-root-test.XXXXXX")"
trap 'rm -rf -- "$TMP"' EXIT
command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 missing"; exit 0; }

PASS=0
FAIL=0
fail() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; }

# one line per command: <placeholder count><TAB><command>
commands() { # hooks.json
    python3 -I - "$1" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
for groups in (data.get("hooks") or {}).values():
    for group in groups:
        for hook in group.get("hooks") or []:
            cmd = hook.get("command")
            if hook.get("type", "command") == "command" and isinstance(cmd, str) and "args" not in hook:
                print("%d\t%s" % (cmd.count("${CLAUDE_PLUGIN_ROOT}"), cmd))
PY
}

# the paths a command references below the plugin root, in order
refs() { # command
    python3 -I -c '
import re, sys
for m in re.finditer(r"\$\{CLAUDE_PLUGIN_ROOT\}/([^\s\"'"'"']+)", sys.argv[1]):
    print(m.group(1))' "$1"
}

# Claude Code on Windows (Git Bash): "bash " in front when the first word ends in .sh
git_bash_form() { # command
    python3 -I -c '
import re, sys
e = sys.argv[1]; n = e.strip(); r = ""; i = 0
while i < len(n):
    o = n[i]
    if o in "\"'"'"'":
        a = n.find(o, i + 1)
        if a == -1:
            r += n[i + 1:]; break
        r += n[i + 1:a]; i = a + 1
    elif o == "\\" and i + 1 < len(n):
        r += n[i + 1]; i += 2
    elif re.match(r"\s", o):
        break
    else:
        r += o; i += 1
print("bash " + e if r.endswith(".sh") else e)' "$1"
}

for plugin in $PLUGINS; do
    HJ="$ROOT/plugins/$plugin/hooks/hooks.json"
    [ -f "$HJ" ] || continue
    PR="$TMP/plugin root/$plugin 1.0"
    while IFS=$'\t' read -r n cmd; do
        [ "$n" -gt 0 ] || continue
        mapfile -t paths < <(refs "$cmd")
        for rel in "${paths[@]}"; do
            mkdir -p "$(dirname "$PR/$rel")"
            printf '#!/bin/bash\nIFS="|"; echo "RAN %s ARGS:$*"\n' "$rel" >"$PR/$rel"
            chmod +x "$PR/$rel"
        done
        # expected: the first referenced script runs; later references arrive as whole paths
        want="RAN ${paths[0]} ARGS:"
        for rel in "${paths[@]:1}"; do want="$want$PR/$rel|"; done
        literal="${cmd//\$\{CLAUDE_PLUGIN_ROOT\}/$PR}"
        for mode in env literal gitbash; do
            case "$mode" in
                env) out="$(cd "$TMP" && CLAUDE_PLUGIN_ROOT="$PR" bash -c "$cmd" </dev/null 2>&1)" ;;
                literal) out="$(cd "$TMP" && bash -c "$literal" </dev/null 2>&1)" ;;
                gitbash) out="$(cd "$TMP" && CLAUDE_PLUGIN_ROOT="$PR" bash -c "$(git_bash_form "$cmd")" </dev/null 2>&1)" ;;
            esac
            case "$out" in
                "$want"*) PASS=$((PASS + 1)) ;;
                *) fail "$plugin ($mode): $cmd"$'\n'"  expected: $want..."$'\n'"  actual:   ${out%%$'\n'*}" ;;
            esac
        done
    done < <(commands "$HJ")
    # static: no placeholder outside double quotes
    bad="$(commands "$HJ" | cut -f2- | python3 -I -c '
import re, sys
for line in sys.stdin:
    for m in re.finditer(r"\$\{CLAUDE_PLUGIN_ROOT\}", line):
        if line[:m.start()].count("\"") % 2 == 0:
            print(line.rstrip()); break')"
    if [ -n "$bad" ]; then fail "$plugin: unquoted \${CLAUDE_PLUGIN_ROOT}:"$'\n'"$bad"; else PASS=$((PASS + 1)); fi
done

echo "PASS: $PASS  FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
