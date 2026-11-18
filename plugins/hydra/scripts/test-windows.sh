#!/bin/bash
# Tests for hydra on native Windows (Git Bash), simulated on any POSIX system with stubs:
# the Python probe (python3 -> python -> py -3, Microsoft Store stub rejected, native nt
# Python output), the worktree guard without any Python (fails closed for what it cannot
# check, one-time message), MSYS/Windows path handling of worktree-guard.py (via ntpath),
# and worktree-setup.sh (native symlinks only, a clear skip instead of a silent copy,
# relpath without Python, ${BASH:-bash}, Windows installPath lookup). Temp dirs only
# (removed on exit). Usage: bash test-windows.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$HERE/../hooks/worktree-guard.sh"
SETUP="$HERE/worktree-setup.sh"
GUARD_PY="$HERE/worktree-guard.py"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/hydra-windows-test.XXXXXX")"
trap 'rm -rf -- "$TMP"' EXIT
SEC=$'\xc2\xa7'
REAL_PY="$(command -v python3)"
REAL_LN="$(command -v ln)"
REAL_OS="$("$REAL_PY" -c "import os; print(os.name)" | tr -d "\r")" # posix, or nt on native Windows
SH="${BASH:-bash}" # never a bare bash: on Windows it can be the System32 WSL launcher

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid
export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid

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
contains() { # name needle haystack
    case "$3" in *"$2"*) PASS=$((PASS + 1)) ;; *) FAIL=$((FAIL + 1)); printf 'FAIL %s\n  missing: %s\n  in:      %s\n' "$1" "$2" "$3" ;; esac
}

# --- stub dirs: each shadows python3/python (the Store stub) and adds what the case needs
STORE="$TMP/stub-store"
PYONLY="$TMP/stub-pyonly"
NTONLY="$TMP/stub-ntonly"
mkdir -p "$STORE" "$PYONLY" "$NTONLY"
for d in "$STORE" "$PYONLY" "$NTONLY"; do
    for n in python3 python py; do # py too: a real py launcher may be on PATH (native Windows)
        printf '#!/bin/sh\necho "Python was not found; run without arguments to install from the Microsoft Store" >&2\nexit 49\n' >"$d/$n"
        chmod +x "$d/$n"
    done
done
printf '#!/bin/sh\n[ "$1" = "-3" ] || exit 9\nshift\nexec "%s" "$@"\n' "$REAL_PY" >"$PYONLY/py"
printf '#!/bin/sh\ncat >/dev/null\nprintf "hydra-python 3 nt\\r\\n"\n' >"$NTONLY/python"
chmod +x "$PYONLY/py" "$NTONLY/python"

# 1. lib-python.sh probe
probe() { # PATH-prefix -> "<cmd words>|<os>|<rc>"
    PATH="$1:$PATH" "$SH" -c '. "$1"; hydra_find_python; rc=$?; echo "${HYDRA_PYTHON_CMD[*]}|$HYDRA_PYTHON_OS|$rc"' \
        _ "$HERE/lib-python.sh"
}
check "Store stubs only: no Python" "||1" "$(probe "$STORE")"
check "py -3 when python3 and python are Store stubs" "py -3|$REAL_OS|0" "$(probe "$PYONLY")"
check "native Windows python accepted" "python|nt|0" "$(probe "$NTONLY")"
check "real python3 first" "python3|$REAL_OS|0" "$("$SH" -c '. "$1"; hydra_find_python; echo "${HYDRA_PYTHON_CMD[*]}|$HYDRA_PYTHON_OS"' _ "$HERE/lib-python.sh")|0"
got="$(PATH="$NTONLY:$PATH" "$SH" -c '. "$1"; hydra_find_python; hydra_python -c x </dev/null' _ "$HERE/lib-python.sh" | od -c)"
case "$got" in *'\r'*) check "hydra_python strips CR of a native Python" no-cr cr ;; *) check "hydra_python strips CR of a native Python" no-cr no-cr ;; esac

# --- guard fixtures: repo with a hydra worktree folder
PROJ="$TMP/proj"
git init -q "$PROJ"
git -C "$PROJ" -c commit.gpgsign=false commit -q --allow-empty -m init
write_perms() { # hydra checkbox line
    printf '%s\n' "<permissions>" "### Hydra" "$1" "</permissions>" >"$PROJ/DOGMA-PERMISSIONS.md"
}
payload() { # tool command|path isolation session
    "$REAL_PY" - "$PROJ" "$@" <<'PY'
import json, sys
cwd, tool, arg, isolation, sid = sys.argv[1:6]
tin = {}
if tool == "Bash":
    tin["command"] = arg
elif arg:
    tin["path"] = arg
if isolation:
    tin["isolation"] = isolation
print(json.dumps({"session_id": sid, "cwd": cwd, "tool_name": tool, "tool_input": tin}))
PY
}
hook() { # PATH-prefix tool arg isolation session -> raw hook output (run in the repo, as Claude Code does)
    local pre="$1"
    shift
    (cd "${HOOK_DIR:-$PROJ}" && payload "$@" | PATH="$pre:$PATH" TMPDIR="$TMP/t" "$SH" "$HOOK")
}
verdict() { case "$(hook "$@")" in *'"permissionDecision": "deny"'*) echo deny ;; *) echo allow ;; esac; }
mkdir -p "$TMP/t"

# 2. the guard with py -3 only runs the full logic
write_perms "- [x] (${SEC}xw1i) use Hydra for 2+ independent tasks"
check "py -3 only: Agent isolation worktree denied" deny "$(verdict "$PYONLY" Agent "" worktree s1)"
check "py -3 only: sibling worktree add denied" deny "$(verdict "$PYONLY" Bash 'git worktree add ../x' "" s1)"
check "py -3 only: hydra path allowed" allow "$(verdict "$PYONLY" Bash 'git worktree add ../proj-worktrees/a' "" s1)"
check "py -3 only: no reduced-mode message" "" "$(hook "$PYONLY" Bash 'git status' "" s1)"

# 3. no Python at all (only Store stubs): never silently off
out="$(hook "$STORE" Agent "" worktree s2)"
contains "no Python: Agent isolation worktree denied" '"permissionDecision": "deny"' "$out"
contains "no Python: deny names the missing Python" "needs Python 3" "$out"
check "no Python: Task isolation worktree denied" deny "$(verdict "$STORE" Task "" worktree s2)"
check "no Python: Agent without isolation allowed" allow "$(verdict "$STORE" Agent "" "" s2)"
check "no Python: EnterWorktree without path denied" deny "$(verdict "$STORE" EnterWorktree "" "" s2)"
check "no Python: EnterWorktree with path allowed" allow "$(verdict "$STORE" EnterWorktree "$TMP/x" "" s2)"
check "no Python: worktree add outside hydra denied" deny "$(verdict "$STORE" Bash 'git worktree add ../other/x' "" s2)"
check "no Python: worktree add to hydra folder allowed" allow \
    "$(verdict "$STORE" Bash 'git worktree add -b hydra/a ../proj-worktrees/a' "" s2)"
check "no Python: git status allowed" allow "$(verdict "$STORE" Bash 'git status' "" s2)"
out1="$(hook "$STORE" Bash 'git status' "" s3)"
out2="$(hook "$STORE" Bash 'git status' "" s3)"
contains "no Python: first allowed call of a session shows the message" '"systemMessage"' "$out1"
check "no Python: message only once per session" "" "$out2"
contains "no Python: message is valid JSON" ok "$(printf '%s' "$out1" | "$REAL_PY" -c 'import json,sys; json.load(sys.stdin); print("ok")' 2>&1)"
contains "no Python: deny is valid JSON" ok "$(hook "$STORE" Agent "" worktree s2 | "$REAL_PY" -c 'import json,sys; json.load(sys.stdin); print("ok")' 2>&1)"
write_perms "- [ ] (${SEC}xw1i) use Hydra for 2+ independent tasks"
check "no Python, checkbox off: Agent isolation allowed" allow "$(verdict "$STORE" Agent "" worktree s4)"
check "no Python, checkbox off: worktree add anywhere allowed" allow "$(verdict "$STORE" Bash 'git worktree add ../other/x' "" s4)"
write_perms "- [?] use Hydra for 2+ independent tasks"
check "no Python, checkbox [?] by text: allowed" allow "$(verdict "$STORE" EnterWorktree "" "" s4)"
git init -q "$TMP/noperm"
check "no Python, no permissions file: on (denied)" deny "$(HOOK_DIR="$TMP/noperm" verdict "$STORE" Agent "" worktree s4)"

# 4. worktree-guard.py path handling on Windows (ntpath, nt=True) - pure functions
check "native() and inside_hydra() for Windows" ok "$("$REAL_PY" - "$GUARD_PY" <<'PY'
import ntpath, runpy, sys
g = runpy.run_path(sys.argv[1], run_name="hydra_guard")
native, inside, shown = g["native"], g["inside_hydra"], g["shown"]
cases = [
    (native("/c/Users/a/x", nt=True), "C:/Users/a/x"),
    (native("/cygdrive/d/w", nt=True), "D:/w"),
    (native("/c", nt=True), "C:/"),
    (native("C:/Users/a", nt=True), "C:/Users/a"),
    (native("../proj-worktrees/a", nt=True), "../proj-worktrees/a"),
    (native("/c/Users/a", nt=False), "/c/Users/a"),
    (shown("C:\\a\\b", nt=True), "C:/a/b"),
    (shown("/a/b", nt=False), "/a/b"),
    (inside("C:/u/proj-worktrees/a", "C:/u/proj", ntpath), True),
    (inside("c:/U/PROJ-WORKTREES/a", "C:/u/proj", ntpath), True),
    (inside("C:\\u\\proj-worktrees\\a\\b", "C:/u/proj", ntpath), True),
    (inside("D:/u/proj-worktrees/a", "C:/u/proj", ntpath), False),
    (inside("C:/u/proj-worktrees", "C:/u/proj", ntpath), False),
    (inside("C:/u/other/a", "C:/u/proj", ntpath), False),
    (inside("C:/u/proj-worktrees/../evil", "C:/u/proj", ntpath), False),
]
bad = [i for i, (a, b) in enumerate(cases) if a != b]
print("ok" if not bad else "bad %s" % [(i, cases[i][0]) for i in bad])
PY
)"

# 5. hooks and scripts never call python3 by name or a bare bash for a script
by_name="$(grep -nE '(^|[^[:alnum:]_./-])python3([[:space:]]|$)' "$HERE"/*.sh "$HERE"/../hooks/*.sh |
    grep -v '/test-' | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' | grep -v 'for spec in python3' || true)"
check "no python3 by name in hydra scripts" "" "$by_name"
bare="$(grep -nE '(^|[$(][[:space:]]*|[;&|][[:space:]]*)bash [^-]' "$SETUP" "$HOOK" | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true)"
check "no bare bash in setup and hook" "" "$bare"

# --- setup fixtures
make_main() { # dir: repo with ignored CLAUDE.md, CLAUDE/ (a symlink to elsewhere) and .credo/
    local r="$1"
    git init -q "$r"
    git -C "$r" -c commit.gpgsign=false commit -q --allow-empty -m init
    printf 'CLAUDE.md\nCLAUDE\n.credo/\n' >>"$r/.git/info/exclude"
    echo rules >"$r/CLAUDE.md"
    mkdir -p "$r/.credo" "$TMP/backup-$(basename "$r")/CLAUDE"
    echo keep >"$r/.credo/sentinel"
    echo sub >"$TMP/backup-$(basename "$r")/CLAUDE/x.md"
    ln -s "$TMP/backup-$(basename "$r")/CLAUDE" "$r/CLAUDE"
    mkdir -p "$r-worktrees"
    git -C "$r" worktree add -q -b "hydra/w" "$r-worktrees/w"
}

# 6. Linux: unchanged behaviour, relpath without Python, a symlinked source is not resolved
make_main "$TMP/lin"
out="$(PATH="$STORE:$PATH" WORKTREE_FILES_SCRIPT=none "$SH" "$SETUP" "$TMP/lin-worktrees/w" 2>&1)"
contains "linux: CLAUDE.md linked" "linked CLAUDE.md" "$out"
check "linux: relative link without Python" "../../lin/CLAUDE.md" "$(readlink "$TMP/lin-worktrees/w/CLAUDE.md")"
check "linux: symlinked source dir linked to its path, not its target" "../../lin/CLAUDE" "$(readlink "$TMP/lin-worktrees/w/CLAUDE")"
check "linux: link resolves" rules "$(cat "$TMP/lin-worktrees/w/CLAUDE.md")"

# 7. Windows simulation: uname says MINGW, ln honours MSYS=winsymlinks:nativestrict
WIN_OK="$TMP/stub-win-ok"
WIN_NO="$TMP/stub-win-no"
mkdir -p "$WIN_OK" "$WIN_NO"
for d in "$WIN_OK" "$WIN_NO"; do
    printf '#!/bin/sh\necho MINGW64_NT-10.0-19045\n' >"$d/uname"
done
# symlinks allowed (Developer Mode): a native symlink only when nativestrict is requested
printf '#!/bin/sh\necho "$MSYS" >>"%s/msys.log"\ncase "$MSYS" in *winsymlinks:nativestrict*) exec "%s" "$@" ;; esac\nexit 7\n' \
    "$TMP" "$REAL_LN" >"$WIN_OK/ln"
# symlinks refused: nativestrict fails, the MSYS default would have made a silent deep copy
printf '#!/bin/sh\ncase "$MSYS" in *winsymlinks:nativestrict*) echo "ln: Operation not permitted" >&2; exit 1 ;; esac\nexec cp -a "$3" "$4"\n' \
    >"$WIN_NO/ln"
chmod +x "$WIN_OK"/* "$WIN_NO"/*

make_main "$TMP/wok"
out="$(PATH="$WIN_OK:$PATH" WORKTREE_FILES_SCRIPT=none MSYS=enable_pcon "$SH" "$SETUP" "$TMP/wok-worktrees/w" 2>&1)"
contains "windows, symlinks allowed: linked" "linked .credo" "$out"
check "windows, symlinks allowed: native symlink" link "$([ -L "$TMP/wok-worktrees/w/.credo" ] && echo link || echo none)"
check "windows: nativestrict appended to the existing MSYS value" "enable_pcon winsymlinks:nativestrict" "$(head -n1 "$TMP/msys.log")"

make_main "$TMP/wno"
out="$(PATH="$WIN_NO:$PATH" WORKTREE_FILES_SCRIPT=none "$SH" "$SETUP" "$TMP/wno-worktrees/w" 2>&1)"
contains "windows, symlinks refused: clear skip" "skipped .credo (no symlink possible" "$out"
contains "windows, symlinks refused: Developer Mode hint" "Developer Mode" "$out"
check "windows, symlinks refused: no copy of .credo" none "$([ -e "$TMP/wno-worktrees/w/.credo" ] || [ -L "$TMP/wno-worktrees/w/.credo" ] && echo exists || echo none)"
check "windows, symlinks refused: no copy of CLAUDE.md" none "$([ -e "$TMP/wno-worktrees/w/CLAUDE.md" ] && echo exists || echo none)"
check "windows, symlinks refused: main checkout untouched" keep "$(cat "$TMP/wno/.credo/sentinel")"

# 8. ${BASH:-bash}: a bare "bash" on PATH (the System32 WSL launcher on Windows) is not used
FAKEBASH="$TMP/stub-bash"
mkdir -p "$FAKEBASH"
printf '#!/bin/sh\ntouch "%s/bare-bash-used"\nexit 1\n' "$TMP" >"$FAKEBASH/bash"
chmod +x "$FAKEBASH/bash"
printf '#!/bin/bash\necho "link CLAUDE.md"\n' >"$TMP/wf.sh"
make_main "$TMP/bb"
REAL_BASH="$(command -v bash)"
out="$(PATH="$FAKEBASH:$PATH" WORKTREE_FILES_SCRIPT="$TMP/wf.sh" "$REAL_BASH" "$SETUP" "$TMP/bb-worktrees/w" 2>&1)"
contains "dogma list read through \$BASH" "source=dogma" "$out"
check "bare bash not used" none "$([ -e "$TMP/bare-bash-used" ] && echo used || echo none)"

# 9. Windows installPath (C:\...) from installed_plugins.json is turned into a Git Bash path
CFG="$TMP/cfg"
PLUG="$TMP/plugdir/dogma/9.9.9"
mkdir -p "$CFG/plugins" "$PLUG/scripts"
printf '#!/bin/bash\necho "link CLAUDE.md"\n' >"$PLUG/scripts/worktree-files.sh"
printf '{"plugins": {"dogma@m": [{"installPath": "C:\\\\plug\\\\dogma\\\\9.9.9"}]}}\n' >"$CFG/plugins/installed_plugins.json"
printf '#!/bin/sh\n[ "$1" = "-u" ] && [ "$2" = "--" ] && [ "$3" = "C:\\\\plug\\\\dogma\\\\9.9.9" ] && { echo "%s"; exit 0; }\nexit 1\n' \
    "$PLUG" >"$WIN_OK/cygpath"
chmod +x "$WIN_OK/cygpath"
make_main "$TMP/ip"
out="$(PATH="$WIN_OK:$PATH" CLAUDE_CONFIG_DIR="$CFG" "$SH" "$SETUP" "$TMP/ip-worktrees/w" 2>&1)"
contains "windows installPath found through cygpath" "source=dogma" "$out"
# a last plugin dir without worktree-files.sh no longer ends the setup silently (set -e, pipefail)
mkdir -p "$CFG/plugins/cache/m/dogma/0.0.1"
make_main "$TMP/old"
out="$(WORKTREE_FILES_SCRIPT= CLAUDE_CONFIG_DIR="$TMP/cfg-old" "$SH" "$SETUP" "$TMP/old-worktrees/w" 2>&1)"
contains "no dogma script found: default list, no silent exit" "source=default" "$out"
mkdir -p "$TMP/cfg-old/plugins/cache/m/dogma/0.0.1"
make_main "$TMP/old2"
out="$(WORKTREE_FILES_SCRIPT= CLAUDE_CONFIG_DIR="$TMP/cfg-old" "$SH" "$SETUP" "$TMP/old2-worktrees/w" 2>&1)"
contains "old dogma without the script: default list, no silent exit" "source=default" "$out"

echo "PASS: $PASS  FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
