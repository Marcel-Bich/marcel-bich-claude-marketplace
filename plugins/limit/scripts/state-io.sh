#!/usr/bin/env bash
# state-io.sh - Shared state-file primitives for the limit plugin.
#
# Every read-modify-write of a plugin state file goes through these helpers:
#   - limit_with_lock <lockfile> <cmd...>   run cmd under an exclusive lock
#   - limit_atomic_write <file>             write stdin to file via mktemp + mv
#   - limit_read_json <file>                print file only if it is valid JSON
#   - limit_debug_enabled                   one debug flag for all scripts
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

    # mkdir fallback: atomic directory creation as the lock primitive.
    local lockdir="${lockfile}.d"
    local tries=$((wait * 20))
    local i=0
    while ! mkdir "$lockdir" 2>/dev/null; do
        # Break a stale lock (holder died) after 30 s.
        local mtime now
        mtime=$(stat -c %Y "$lockdir" 2>/dev/null || stat -f %m "$lockdir" 2>/dev/null || echo 0)
        now=$(date +%s)
        if [[ $((now - mtime)) -gt 30 ]]; then
            rmdir "$lockdir" 2>/dev/null || true
            continue
        fi
        i=$((i + 1))
        [[ "$i" -ge "$tries" ]] && return 75
        sleep 0.05 2>/dev/null || sleep 1
    done
    local rc=0
    "$@" || rc=$?
    rmdir "$lockdir" 2>/dev/null || true
    return "$rc"
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
