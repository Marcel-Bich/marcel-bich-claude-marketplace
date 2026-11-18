# shellcheck shell=bash disable=SC2034  # DOGMA_PYTHON is read by the sourcing script
# lib-python.sh - find a Python 3 that the dogma guards can trust (sourced, not run).
#
# "command -v python3" is not enough on native Windows (Git Bash): python3 and python can be
# the Microsoft Store alias stub, which only prints "Python was not found" and exits 9009
# (seen as exit 49), and a native Windows Python uses Windows path semantics that
# bash-guard.py does not model (/, ~ and /tmp would resolve to C:\ paths). Each candidate is
# therefore started once and must report a POSIX Python 3; anything else counts as missing,
# so the callers fall back to their text rules (fail closed for destructive commands).
#
# dogma_find_python sets DOGMA_PYTHON to the interpreter (python3 first, then python) and
# returns 0, or returns 1 with DOGMA_PYTHON empty.

DOGMA_PYTHON=""

dogma_find_python() {
    local cand probe
    DOGMA_PYTHON=""
    for cand in python3 python; do
        command -v "$cand" >/dev/null 2>&1 || continue
        probe="$("$cand" -I -c 'import os, sys; print("dogma-python", sys.version_info[0], os.name)' \
            </dev/null 2>/dev/null)" || continue
        if [ "$probe" = "dogma-python 3 posix" ]; then
            DOGMA_PYTHON="$cand"
            return 0
        fi
    done
    return 1
}
