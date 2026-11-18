# shellcheck shell=bash disable=SC2034  # DOGMA_PYTHON* are read by the sourcing script
# lib-python.sh - find a Python 3 that a dogma script can trust (sourced, not run).
#
# "command -v python3" is not enough on native Windows (Git Bash): python3 and python can be
# the Microsoft Store alias stub, which only prints "Python was not found" and exits 9009
# (seen as exit 49), and the python.org installer ships python.exe and py.exe but no
# python3.exe. Each candidate (python3, python, py -3) is therefore started once and must
# report a working Python 3; anything else counts as missing.
#
# A native Windows Python (os.name nt) uses Windows path semantics: /, ~, /tmp or /dev/null
# resolve to C:\ paths there, which bash-guard.py does not model (a harmless "2>/dev/null"
# became an overwrite of "C:\dev\null"). The guards therefore only take a POSIX Python and
# otherwise fall back to their text rules (fail closed for destructive commands). Helpers
# that only parse JSON or text (no path resolution) may pass --native-ok.
#
# dogma_find_python [--native-ok] sets DOGMA_PYTHON_CMD (the command words, e.g. "py" "-3"),
# DOGMA_PYTHON (its first word) and DOGMA_PYTHON_OS (posix or nt) and returns 0, or returns 1
# with all of them empty. Run the interpreter through dogma_python, never "$DOGMA_PYTHON".

DOGMA_PYTHON=""
DOGMA_PYTHON_OS=""
DOGMA_PYTHON_CMD=()

dogma_find_python() {
    local native_ok="" spec probe os
    local -a pycmd
    [ "${1:-}" = "--native-ok" ] && native_ok="true"
    DOGMA_PYTHON=""
    DOGMA_PYTHON_OS=""
    DOGMA_PYTHON_CMD=()
    for spec in python3 python "py -3"; do
        read -r -a pycmd <<<"$spec"
        command -v "${pycmd[0]}" >/dev/null 2>&1 || continue
        probe="$("${pycmd[@]}" -I -c 'import os, sys; print("dogma-python", sys.version_info[0], os.name)' \
            </dev/null 2>/dev/null)" || continue
        probe="${probe%$'\r'}"  # a native Windows Python ends its lines with CRLF
        case "$probe" in
            "dogma-python 3 posix") os="posix" ;;
            "dogma-python 3 nt") [ -n "$native_ok" ] || continue; os="nt" ;;
            *) continue ;;
        esac
        DOGMA_PYTHON_CMD=("${pycmd[@]}")
        DOGMA_PYTHON="${pycmd[0]}"
        DOGMA_PYTHON_OS="$os"
        return 0
    done
    return 1
}

# Run the interpreter found by dogma_find_python with the given arguments. A native Windows
# Python gets UTF-8 I/O (-X utf8, which -I does not switch off) and its CRLF output is turned
# into LF, so the shell callers read the same text as from a POSIX Python.
dogma_python() {
    if [ "${#DOGMA_PYTHON_CMD[@]}" -eq 0 ]; then
        echo "dogma: no Python 3 found (python3, python or py -3)" >&2
        return 127
    fi
    if [ "$DOGMA_PYTHON_OS" = "nt" ]; then
        "${DOGMA_PYTHON_CMD[@]}" -X utf8 "$@" | tr -d '\r'
        return "${PIPESTATUS[0]}"
    fi
    "${DOGMA_PYTHON_CMD[@]}" "$@"
}
