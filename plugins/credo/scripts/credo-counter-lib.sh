#!/bin/bash
# credo-counter-lib - shared mechanics for credo's monotone counters.
#
# Sourced by credo-id-next.sh (work-item ids) and credo-code-next.sh (typed codes
# T, Q, V). Sourcing only defines functions: it runs nothing and changes no state.
# Each caller owns its counter file, its lock file and its floor scan; these
# helpers give every counter the same discipline:
#
#   credo_counter_lock LOCK     open fd 9 on LOCK and take an exclusive flock (without
#                               flock: an atomic mkdir of LOCK.d)
#   credo_counter_unlock        release that lock
#   credo_counter_read FILE     print the number stored in FILE; 0 when the file is
#                               missing, empty, or not a plain non-negative integer
#   credo_counter_write FILE    read the new content from stdin and replace FILE
#                               atomically (temp file next to it, then mv -f)
#
# Hold the lock around the whole read-modify-write, so two processes never draw
# the same number.

# flock is missing on Git Bash (native Windows) and macOS: there an atomic mkdir of
# LOCK.d is the lock. A lock dir older than 30 s belongs to a dead holder and is broken;
# a lock still busy after about 15 s fails (return 1), so a counter is never drawn
# without the lock.
CREDO_COUNTER_LOCKDIR=""

credo_counter_lock() {
    if command -v flock >/dev/null 2>&1; then
        exec 9>"$1"
        flock 9
        return
    fi
    local lockdir="$1.d" i=0 mtime now
    while ! mkdir "$lockdir" 2>/dev/null; do
        mtime="$(stat -c %Y "$lockdir" 2>/dev/null || stat -f %m "$lockdir" 2>/dev/null || echo 0)"
        now="$(date +%s)"
        if [ $((now - mtime)) -gt 30 ]; then
            rmdir "$lockdir" 2>/dev/null || return 1
            continue
        fi
        i=$((i + 1))
        [ "$i" -ge 300 ] && return 1
        sleep 0.05 2>/dev/null || sleep 1
    done
    CREDO_COUNTER_LOCKDIR="$lockdir"
}

credo_counter_unlock() {
    if [ -n "$CREDO_COUNTER_LOCKDIR" ]; then
        rmdir "$CREDO_COUNTER_LOCKDIR" 2>/dev/null || true
        CREDO_COUNTER_LOCKDIR=""
        return 0
    fi
    flock -u 9
}

credo_counter_read() {
    local counter=0
    if [ -f "$1" ]; then
        counter="$(tr -d '[:space:]' < "$1")"
        case "$counter" in
            ''|*[!0-9]*) counter=0 ;;
        esac
    fi
    printf '%s' "$counter"
}

credo_counter_write() {
    local file="$1" tmp
    tmp="$(dirname -- "$file")/.$(basename -- "$file").tmp.$$"
    cat > "$tmp" && mv -f -- "$tmp" "$file"
}
