#!/usr/bin/env bash
# state-io.sh - Shared state-file primitives for the limit plugin.
#
# Every read-modify-write of a plugin state file goes through these helpers:
#   - limit_with_lock <lockfile> <cmd...>   run cmd under an exclusive lock
#   - limit_hold_lock <lockfile>            hold an exclusive lock until the process exits
#   - limit_atomic_write <file>             write stdin to file via mktemp + mv
#   - limit_read_json <file>                print file only if it is valid JSON
#   - limit_debug_enabled                   one debug flag for all scripts
#   - limit_si <int>                        1500000 -> 1.5M (no bc needed)
#   - jq                                    LF-only output on native Windows
#
# Parallel statusline renders (one per open session, several per second) used to
# write state with `cat > file`, so a concurrent reader could see an empty or
# half-written file and treat it as "0". The rule is now:
#   1. writes are atomic (temp file in the same directory, then rename)
#   2. read-modify-write sequences hold an exclusive lock
#   3. a failed or empty read is an error for the caller, never a zero value
# shellcheck disable=SC2250

# Debug flag. CLAUDE_MB_LIMIT_DEBUG accepts true/1/yes/on (case-insensitive),
# so every script of the plugin agrees on whether debug logging is on.
limit_debug_enabled() {
    case "${CLAUDE_MB_LIMIT_DEBUG:-false}" in
        1|true|TRUE|True|yes|YES|on|ON) return 0 ;;
        *) return 1 ;;
    esac
}

# Run a command under an exclusive lock on <lockfile>.
# Waits up to LIMIT_LOCK_WAIT seconds (default 3). Returns 75 when the lock
# could not be acquired, otherwise the command's exit code.
# Uses flock when available, otherwise a mkdir-based lock (macOS has no flock).
limit_with_lock() {
    local lockfile="$1"
    shift
    local wait="${LIMIT_LOCK_WAIT:-3}"
    # Fresh profile: the data dir may not exist yet (e.g. a CLI scan first).
    local lockdir_parent="${lockfile%/*}"
    [[ "$lockdir_parent" == "$lockfile" ]] || [[ -d "$lockdir_parent" ]] || mkdir -p "$lockdir_parent" 2>/dev/null || return 75

    if command -v flock >/dev/null 2>&1; then
        (
            exec 8>>"$lockfile" 2>/dev/null || exit 75
            flock -w "$wait" 8 2>/dev/null || exit 75
            "$@"
        )
        return $?
    fi

    # mkdir fallback (no flock, e.g. macOS).
    local lockdir="${lockfile}.d"
    _limit_mkdir_acquire "$lockdir" "$((wait * 20))" || return 75
    local rc=0
    "$@" || rc=$?
    rmdir "$lockdir" 2>/dev/null || true
    return "$rc"
}

# mkdir lock: atomic directory creation is the lock primitive. A lock older than
# 30 s is treated as stale (its holder died) and broken. Args: lockdir tries.
# Returns 1 when the lock is still busy after <tries> polls.
_limit_mkdir_acquire() {
    local lockdir="$1" tries="$2" i=0
    while ! mkdir "$lockdir" 2>/dev/null; do
        local mtime now
        now=$(date +%s)
        # Each stat on its own: when GNU `stat -c` fails, `stat -f %m` prints
        # file-system lines ("File: ...") that are no number.
        mtime=$(stat -c %Y "$lockdir" 2>/dev/null) || mtime=$(stat -f %m "$lockdir" 2>/dev/null) || mtime=""
        if [[ ! "$mtime" =~ ^[0-9]+$ ]]; then
            # The holder released it between mkdir and stat (a wide window on
            # native Windows): try mkdir again. The old fallback age 0 made it
            # look stale, rmdir failed and the lock was given up as busy. Still
            # counted as a try: mkdir may fail for good (no write permission).
            if [[ ! -e "$lockdir" ]]; then
                i=$((i + 1))
                [[ "$i" -ge "$tries" ]] && return 1
                continue
            fi
            mtime="$now"
        fi
        if [[ $((now - mtime)) -gt 30 ]]; then
            # A stale lock that cannot be removed (not a dir, no permission) must
            # not spin forever: give up like a busy lock.
            rmdir "$lockdir" 2>/dev/null || return 1
            continue
        fi
        i=$((i + 1))
        [[ "$i" -ge "$tries" ]] && return 1
        sleep 0.05 2>/dev/null || sleep 1
    done
    return 0
}

# Take an exclusive lock on <lockfile> until the calling process exits. For a hook
# that reads, decides and writes in one run and exits at several points. Same wait
# (LIMIT_LOCK_WAIT) and flock / mkdir choice as limit_with_lock. Returns 75 when the
# lock stays busy; the caller then decides whether to go on unlocked.
limit_hold_lock() {
    local lockfile="$1"
    local wait="${LIMIT_LOCK_WAIT:-3}"
    local lockdir_parent="${lockfile%/*}"
    [[ "$lockdir_parent" == "$lockfile" ]] || [[ -d "$lockdir_parent" ]] || mkdir -p "$lockdir_parent" 2>/dev/null || return 75
    if command -v flock >/dev/null 2>&1; then
        # Probe first: a failing exec redirection would end a non-interactive shell.
        : >> "$lockfile" 2>/dev/null || return 75
        exec 8>>"$lockfile" || return 75
        flock -w "$wait" 8 2>/dev/null || return 75
        return 0
    fi
    local lockdir="${lockfile}.d"
    _limit_mkdir_acquire "$lockdir" "$((wait * 20))" || return 75
    # shellcheck disable=SC2064
    trap "rmdir '$lockdir' 2>/dev/null" EXIT
    return 0
}

# Write stdin to <file> atomically. The content must be non-empty valid JSON
# (or JSONL when LIMIT_ATOMIC_RAW=1); otherwise the target stays untouched and
# the function returns 1.
limit_atomic_write() {
    local file="$1"
    local dir tmp
    dir=$(dirname "$file")
    [[ -d "$dir" ]] || mkdir -p "$dir" 2>/dev/null || return 1
    tmp=$(mktemp "${file}.tmp.XXXXXX" 2>/dev/null) || return 1
    if ! cat > "$tmp" 2>/dev/null; then
        rm -f "$tmp" 2>/dev/null
        return 1
    fi
    if [[ ! -s "$tmp" ]]; then
        rm -f "$tmp" 2>/dev/null
        return 1
    fi
    if [[ "${LIMIT_ATOMIC_RAW:-0}" != "1" ]] && ! jq -e . "$tmp" >/dev/null 2>&1; then
        rm -f "$tmp" 2>/dev/null
        return 1
    fi
    chmod 644 "$tmp" 2>/dev/null || true
    if ! mv -f "$tmp" "$file" 2>/dev/null; then
        rm -f "$tmp" 2>/dev/null
        return 1
    fi
    return 0
}

# Print <file> if it exists and holds valid non-empty JSON. Returns 1 when the
# file is missing, empty or unparsable - callers must treat that as "unknown",
# never as zero.
limit_read_json() {
    local file="$1"
    [[ -s "$file" ]] || return 1
    local content
    content=$(cat "$file" 2>/dev/null) || return 1
    [[ -n "$content" ]] || return 1
    printf '%s' "$content" | jq -e 'type == "object"' >/dev/null 2>&1 || return 1
    printf '%s\n' "$content"
}

# Round to one decimal, half-up (2.25 -> 2.3). printf "%.1f" rounds exact halves
# to even and the old averages used floor; both made displayed values jump.
limit_round1() {
    awk -v v="${1:-0}" 'BEGIN { x = v * 10; r = (x >= 0) ? int(x + 0.5) : -int(-x + 0.5); printf "%.1f", r / 10 }'
}

# Seconds until the stored API backoff expires (0 when expired/absent).
# The retry time is computed ONCE when the 429 happens (retry_at in the backoff
# file), so every render shows the same countdown and refresh-usage.sh honours it.
# Args: backoff_file [now_epoch]
backoff_retry_in() {
    local file="$1" now="${2:-$(date +%s)}"
    local retry_at
    retry_at=$(jq -r '.retry_at // 0' "$file" 2>/dev/null) || retry_at=0
    [[ "$retry_at" =~ ^[0-9]+$ ]] || retry_at=0
    local left=$((retry_at - now))
    [[ "$left" -lt 0 ]] && left=0
    echo "$left"
}

# SI short form of a non-negative integer: k, M, G, T, P, E with one decimal,
# truncated like `bc` with scale=1 (7560000 -> 7.5M). Pure bash integer math, so
# it also works where bc is missing (Git Bash on native Windows). Below 1000 the
# number is printed as is. Bash integers end at 9.2E18, so E is the largest unit.
limit_si() {
    local n="$1" div=1000 unit t
    if (( n < 1000 )); then
        printf '%d' "$n"
        return
    fi
    for unit in k M G T P E; do
        if [[ "$unit" == E ]] || (( n < div * 1000 )); then
            t=$(( n / (div / 10) ))
            printf '%d.%d%s' $((t / 10)) $((t % 10)) "$unit"
            return
        fi
        div=$((div * 1000))
    done
}

# Native Windows jq (jq.exe from winget, run from Git Bash) needs two fixes,
# applied only under MSYS/Cygwin; on Linux and macOS jq is never wrapped:
# 1. It writes CRLF line ends. Bash keeps the \r in `read`, here-strings and
#    multi-line $(...), so "true\r" is not "true", "1\r" is no number and every
#    TSV row from jq carries a stray \r into keys and awk fields. jq runs with -b (binary
#    stdout, plain LF); a build without -b gets its \r stripped.
# 2. The MSYS runtime rewrites every argument of a native program that looks
#    like a POSIX path, --arg values included: `--arg p /tmp/x` reaches jq as
#    "C:/Users/me/AppData/Local/Temp/x" and never matches the ledger keys,
#    which keep bash's spelling. --arg values are exempted through
#    MSYS2_ARG_CONV_EXCL (a list of prefixes), so file operands are still
#    translated. A value that is a prefix of another argument is left alone,
#    otherwise that file operand would not be translated either.
# The output probe runs once per process tree (LIMIT_JQ_MODE is exported).
case "${OSTYPE:-}" in
    msys* | cygwin*)
        if [[ -z "${LIMIT_JQ_MODE:-}" ]]; then
            LIMIT_JQ_MODE="plain"
            if [[ "$(printf '1' | command jq -b . 2>/dev/null)" == "1" ]]; then
                LIMIT_JQ_MODE="binary"
            # tr: Git Bash drops a trailing \r in $(...) by itself (but not in
            # `read` or inside multi-line output), so make it visible first.
            elif [[ "$(printf '1' | command jq . 2>/dev/null | tr '\r' 'R')" == *R* ]]; then
                LIMIT_JQ_MODE="strip"
            fi
            export LIMIT_JQ_MODE
        fi
        jq() {
            local -a args=("$@")
            local n="${#args[@]}" i j v excl="" clash
            for ((i = 0; i + 2 < n; i++)); do
                [[ "${args[i]}" == "--arg" ]] || continue
                v="${args[i + 2]}"
                i=$((i + 2))
                [[ "$v" == */* && "$v" != *";"* ]] || continue
                clash=0
                for ((j = 0; j < n; j++)); do
                    [[ "$j" -ne "$i" && "${args[j]}" == "$v"* ]] && { clash=1; break; }
                done
                [[ "$clash" -eq 0 ]] && excl+="${excl:+;}${v}"
            done
            [[ -n "${MSYS2_ARG_CONV_EXCL:-}" ]] && excl+="${excl:+;}${MSYS2_ARG_CONV_EXCL}"
            case "$LIMIT_JQ_MODE" in
                binary) MSYS2_ARG_CONV_EXCL="$excl" command jq -b "$@" ;;
                strip)
                    MSYS2_ARG_CONV_EXCL="$excl" command jq "$@" | tr -d '\r'
                    return "${PIPESTATUS[0]}"
                    ;;
                *) MSYS2_ARG_CONV_EXCL="$excl" command jq "$@" ;;
            esac
        }
        ;;
esac
