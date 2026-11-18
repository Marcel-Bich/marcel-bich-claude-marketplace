#!/bin/bash
# Native Windows (Git Bash) behaviour of credo-worktree-setup.sh, simulated on any POSIX
# system with stubs (same cases as hydra's test-windows.sh for its worktree-setup.sh, the
# twin script): native symlinks only (MSYS winsymlinks:nativestrict), a clear skip with a
# Developer Mode hint instead of a silent copy, relpath without Python, ${BASH:-bash} for
# the dogma list, a Windows installPath (C:\...) from installed_plugins.json, and no silent
# abort when the newest dogma dir has no worktree-files.sh. Temp dirs only (removed on exit).
#
# Usage: bash test-credo-worktree-setup-windows.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP="$HERE/credo-worktree-setup.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/credo-wt-win-test.XXXXXX")"
trap 'rm -rf -- "$TMP"' EXIT
REAL_LN="$(command -v ln)"
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

# the Microsoft Store stub for python3/python/py: relpath must not need Python
STORE="$TMP/stub-store"
mkdir -p "$STORE"
for n in python3 python py; do
    printf '#!/bin/sh\necho "Python was not found" >&2\nexit 49\n' >"$STORE/$n"
    chmod +x "$STORE/$n"
done

make_main() { # dir: repo with ignored CLAUDE.md, CLAUDE (a symlink to elsewhere) and .credo/
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

# 1. Linux: unchanged behaviour, relpath without Python, a symlinked source is not resolved
make_main "$TMP/lin"
out="$(PATH="$STORE:$PATH" WORKTREE_FILES_SCRIPT=none "$SH" "$SETUP" "$TMP/lin-worktrees/w" 2>&1)"
contains "linux: CLAUDE.md linked" "linked CLAUDE.md" "$out"
check "linux: relative link without Python" "../../lin/CLAUDE.md" "$(readlink "$TMP/lin-worktrees/w/CLAUDE.md")"
check "linux: symlinked source dir linked to its path, not its target" "../../lin/CLAUDE" "$(readlink "$TMP/lin-worktrees/w/CLAUDE")"
check "linux: link resolves" rules "$(cat "$TMP/lin-worktrees/w/CLAUDE.md")"

# 2. Windows simulation: uname says MINGW, ln honours MSYS=winsymlinks:nativestrict
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
check "windows, symlinks refused: setup still finishes" 0 "$(PATH="$WIN_NO:$PATH" WORKTREE_FILES_SCRIPT=none "$SH" "$SETUP" "$TMP/wno-worktrees/w" >/dev/null 2>&1; echo $?)"

# 3. ${BASH:-bash}: a bare "bash" on PATH (the System32 WSL launcher on Windows) is not used
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
bare="$(grep -nE '(^|[$(][[:space:]]*|[;&|][[:space:]]*)bash [^-]' "$SETUP" | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true)"
check "no bare bash in the setup script" "" "$bare"

# 4. Windows installPath (C:\...) from installed_plugins.json is turned into a Git Bash path
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

# 5. a last plugin dir without worktree-files.sh no longer ends the setup silently (set -e, pipefail)
make_main "$TMP/old"
out="$(WORKTREE_FILES_SCRIPT= CLAUDE_CONFIG_DIR="$TMP/cfg-old" "$SH" "$SETUP" "$TMP/old-worktrees/w" 2>&1)"
contains "no dogma script found: default list, no silent exit" "source=default" "$out"
mkdir -p "$TMP/cfg-old/plugins/cache/m/dogma/0.0.1"
make_main "$TMP/old2"
out="$(WORKTREE_FILES_SCRIPT= CLAUDE_CONFIG_DIR="$TMP/cfg-old" "$SH" "$SETUP" "$TMP/old2-worktrees/w" 2>&1)"
contains "old dogma without the script: default list, no silent exit" "source=default" "$out"
contains "old dogma without the script: files still linked" "linked CLAUDE.md" "$out"

echo "PASS: $PASS  FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
