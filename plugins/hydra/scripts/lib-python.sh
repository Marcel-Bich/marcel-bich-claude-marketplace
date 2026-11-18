# shellcheck shell=bash disable=SC2034  # HYDRA_PYTHON* are read by the sourcing script
# lib-python.sh - find a Python 3 that hydra can run (sourced, not run).
#
# "command -v python3" is not enough on native Windows (Git Bash): python3 and python can be
# the Microsoft Store alias stub, which only prints "Python was not found" and exits 9009
# (seen as exit 49), and the python.org installer ships python.exe and py.exe but no
# python3.exe. Each candidate (python3, python, py -3) is therefore started once and must
# report a working Python 3; anything else counts as missing.
#
# Plugins install independently, so this is hydra's own copy of the approach in dogma's
# scripts/lib-python.sh (same probe), not a cross-plugin import.
#
# hydra_find_python sets HYDRA_PYTHON_CMD (the command words, e.g. "py" "-3") and
# HYDRA_PYTHON_OS (posix or nt) and returns 0, or returns 1 with both empty. A native
# Windows Python (nt) is accepted: hydra's Python code handles Windows paths itself. Run the
# interpreter through hydra_python, never through the command words directly.

HYDRA_PYTHON_OS=""
HYDRA_PYTHON_CMD=()

hydra_find_python() {
    local spec probe
    local -a pycmd
    HYDRA_PYTHON_OS=""
    HYDRA_PYTHON_CMD=()
    for spec in python3 python "py -3"; do
        read -r -a pycmd <<<"$spec"
        command -v "${pycmd[0]}" >/dev/null 2>&1 || continue
        probe="$("${pycmd[@]}" -I -c 'import os, sys; print("hydra-python", sys.version_info[0], os.name)' \
            </dev/null 2>/dev/null)" || continue
        probe="${probe%$'\r'}"  # a native Windows Python ends its lines with CRLF
        case "$probe" in
            "hydra-python 3 posix") HYDRA_PYTHON_OS="posix" ;;
            "hydra-python 3 nt") HYDRA_PYTHON_OS="nt" ;;
            *) continue ;;
        esac
        HYDRA_PYTHON_CMD=("${pycmd[@]}")
        return 0
    done
    return 1
}

# Run the interpreter found by hydra_find_python with the given arguments. A native Windows
# Python gets UTF-8 I/O (-X utf8) and its CRLF output is turned into LF, so the shell callers
# read the same text as from a POSIX Python.
hydra_python() {
    if [ "${#HYDRA_PYTHON_CMD[@]}" -eq 0 ]; then
        echo "hydra: no Python 3 found (python3, python or py -3)" >&2
        return 127
    fi
    if [ "$HYDRA_PYTHON_OS" = "nt" ]; then
        "${HYDRA_PYTHON_CMD[@]}" -X utf8 "$@" | tr -d '\r'
        return "${PIPESTATUS[0]}"
    fi
    "${HYDRA_PYTHON_CMD[@]}" "$@"
}
