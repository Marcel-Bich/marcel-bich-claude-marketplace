#!/bin/bash
# credo-counter-lib - shared mechanics for credo's monotone counters.
#
# Sourced by credo-id-next.sh (work-item ids) and credo-code-next.sh (typed codes
# T, Q, V). Sourcing only defines functions: it runs nothing and changes no state.
# Each caller owns its counter file, its lock file and its floor scan; these
# helpers give every counter the same discipline:
#
#   credo_counter_lock LOCK     open fd 9 on LOCK and take an exclusive flock
#   credo_counter_unlock        release that lock (fd 9)
#   credo_counter_read FILE     print the number stored in FILE; 0 when the file is
#                               missing, empty, or not a plain non-negative integer
#   credo_counter_write FILE    read the new content from stdin and replace FILE
#                               atomically (temp file next to it, then mv -f)
#
# Hold the lock around the whole read-modify-write, so two processes never draw
# the same number.

credo_counter_lock() {
    exec 9>"$1"
    flock 9
}

credo_counter_unlock() {
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
