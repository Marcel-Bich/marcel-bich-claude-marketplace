# shellcheck shell=bash disable=SC2034  # CREDO_PYTHON is read by the sourcing script
# credo-python-lib.sh - find a working Python 3 for the credo hooks (sourced, not run).
#
# "command -v python3" is not enough on native Windows (Git Bash): python3 and python can be
# the Microsoft Store App Execution Alias stub under ...\WindowsApps\, which only prints
# "Python was not found ..." and exits 9009 (seen as exit 49 by the shell). Each candidate is
# therefore started once and must print a fixed marker for Python 3; anything else (missing,
# stub, Python 2, a crash) counts as no Python. A native Windows Python (os.name nt) counts
# as present: scripts that need Linux features check that themselves and exit 0.
#
# credo_find_python      sets CREDO_PYTHON to the interpreter (python3, then python, then the
#                        interpreter that the Windows launcher "py -3" starts) and returns
#                        0, or returns 1 with CREDO_PYTHON empty. CREDO_PYTHON_OS is its
#                        os.name (posix, nt), for scripts that only work on POSIX.
# credo_python_ready     the same, but probes at most once per shell (cached), for scripts
#                        that need Python only on some paths.
# credo_python_cmd       for helper scripts that call Python on every run (credo-config.sh and
#                        others reached from hooks): sets CREDO_PYTHON without extra cost when
#                        python3 is on PATH outside WindowsApps (Linux, macOS, WSL: no
#                        change), else probes like credo_find_python (native Windows:
#                        python, py -3). Nothing found -> CREDO_PYTHON=python3, so the caller
#                        fails exactly as before. Always returns 0.
# credo_python_install_hint
#                        prints the install hint for this platform (one line, plain text
#                        without double quotes or backslashes, so it can go into JSON as is).
# credo_python_is_stub   returns 0 when python3 or python resolves to the WindowsApps alias.

# Native Windows: a Windows Python resolves a bare "bash" to System32\bash.exe (the WSL
# launcher). CREDO_BASH tells credo's Python scripts (credo_platform.bash_exe) which Git Bash
# runs the hooks. Set once, cheap ($OSTYPE is a bash variable, cygpath only on MSYS).
case "${OSTYPE:-}" in
    msys*|cygwin*)
        if [ -z "${CREDO_BASH:-}" ] && [ -n "${BASH:-}" ] && command -v cygpath >/dev/null 2>&1; then
            CREDO_BASH="$(cygpath -w "$BASH" 2>/dev/null)" && export CREDO_BASH
        fi ;;
esac

CREDO_PYTHON=""
CREDO_PYTHON_OS=""
CREDO_PYTHON_PROBED=""

credo_python_ready() {
    if [ -z "$CREDO_PYTHON_PROBED" ]; then
        CREDO_PYTHON_PROBED=1
        credo_find_python
        return
    fi
    [ -n "$CREDO_PYTHON" ]
}

credo_find_python() {
    local cand probe exe os
    CREDO_PYTHON=""
    CREDO_PYTHON_OS=""
    for cand in python3 python; do
        command -v "$cand" >/dev/null 2>&1 || continue
        probe="$("$cand" -I -c 'import os, sys; print("credo-python", sys.version_info[0], os.name)' \
            </dev/null 2>/dev/null)" || continue
        probe="${probe%$'\r'}"
        case "$probe" in
            "credo-python 3 "?*)
                CREDO_PYTHON="$cand"
                CREDO_PYTHON_OS="${probe#credo-python 3 }"
                return 0 ;;
        esac
    done
    # The Windows py launcher (python.org ships no python3.exe): CREDO_PYTHON becomes the
    # interpreter it starts, so callers can still run "$CREDO_PYTHON" as one word.
    command -v py >/dev/null 2>&1 || return 1
    probe="$(py -3 -I -c 'import os, sys; print("credo-python", sys.version_info[0], os.name); print(sys.executable)' \
        </dev/null 2>/dev/null | tr -d '\r')" || return 1
    case "${probe%%$'\n'*}" in "credo-python 3 "?*) ;; *) return 1 ;; esac
    exe="${probe#*$'\n'}"
    [ -n "$exe" ] && [ "$exe" != "$probe" ] || return 1
    command -v cygpath >/dev/null 2>&1 && exe="$(cygpath -u "$exe" 2>/dev/null)"
    [ -n "$exe" ] && [ -x "$exe" ] || return 1
    CREDO_PYTHON="$exe"
    os="${probe%%$'\n'*}"
    CREDO_PYTHON_OS="${os#credo-python 3 }"
    return 0
}

credo_python_cmd() {
    local p
    p="$(command -v python3 2>/dev/null)" || p=""
    case "$p" in
        "") ;;
        *[Ww]indows[Aa]pps*) ;;
        *) CREDO_PYTHON=python3; return 0 ;;
    esac
    credo_find_python || CREDO_PYTHON=python3
    return 0
}

credo_python_is_stub() {
    local cand p
    for cand in python3 python; do
        p="$(command -v "$cand" 2>/dev/null)" || continue
        case "$p" in *[Ww]indows[Aa]pps*) return 0 ;; esac
    done
    return 1
}

credo_python_install_hint() {
    local os pm
    os="$(uname -s 2>/dev/null)"
    [ "${OS:-}" = "Windows_NT" ] && case "$os" in Linux) ;; *) os="MINGW" ;; esac
    case "$os" in
        MINGW*|MSYS*|CYGWIN*)
            echo "winget install Python.Python.3.12, then turn off the python.exe and python3.exe App Execution Aliases (Windows Settings, Apps, Advanced app settings, App execution aliases) and restart Claude Code"
            return 0 ;;
        Darwin)
            echo "brew install python"
            return 0 ;;
    esac
    for pm in apt dnf pacman zypper apk; do
        command -v "$pm" >/dev/null 2>&1 || continue
        case "$pm" in
            apt) echo "sudo apt install python3" ;;
            dnf) echo "sudo dnf install python3" ;;
            pacman) echo "sudo pacman -S python" ;;
            zypper) echo "sudo zypper install python3" ;;
            apk) echo "sudo apk add python3" ;;
        esac
        return 0
    done
    echo "install python3 with the package manager of your system"
}
