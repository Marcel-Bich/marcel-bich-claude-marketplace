#!/bin/bash
# kitty-tab.sh: Kitty terminal tab indicator for Claude Code sessions
# Shows "[ai...] title" prefix while Claude is working, "[fin] title" on stop
#
# Requires kitty.conf:
#   allow_remote_control yes
#   listen_on unix:/tmp/mykitty
#
# Environment variables:
#   CLAUDE_MB_KITTY_TAB: "true" (default) or "false" to disable
#   CLAUDE_MB_SIGNAL_DEBUG: "true" for debug logging to stderr
#
# State files (per kitty window PID):
#   /tmp/claude-mb-kitty-title-${window_pid}      -- saved original title
#   /tmp/claude-mb-kitty-reset-pid-${window_pid}  -- PID of background focus watcher
#   /tmp/claude-mb-kitty-socket                    -- cached socket path

# --- Debug helper ---

_signal_debug() {
    if [ "${CLAUDE_MB_SIGNAL_DEBUG:-false}" = "true" ]; then
        echo "[kitty-tab] $*" >&2
    fi
}

# --- Walk up process tree until parent is kitty, return that PID ---

_walk_up_to_kitty_child() {
    local pid="$1"
    while [ "$pid" -gt 1 ] 2>/dev/null; do
        local parent
        parent=$(ps -p "$pid" -o ppid= 2>/dev/null | tr -d ' ')
        if [ -z "$parent" ] || [ "$parent" -le 1 ] 2>/dev/null; then break; fi
        local parent_comm
        parent_comm=$(ps -p "$parent" -o comm= 2>/dev/null)
        if [ "$parent_comm" = "kitty" ]; then
            echo "$pid"
            return 0
        fi
        pid="$parent"
    done
    return 1
}

# --- Find kitty window PID via process tree ---

_find_kitty_window_pid() {
    # In tmux: start from tmux client PID (which is in kitty's process tree)
    if [ -n "${TMUX:-}" ]; then
        local client_pid
        client_pid=$(tmux display-message -p '#{client_pid}' 2>/dev/null)
        if [ -n "$client_pid" ]; then
            local result
            result=$(_walk_up_to_kitty_child "$client_pid")
            if [ -n "$result" ]; then
                _signal_debug "tmux client $client_pid -> kitty child $result"
                echo "$result"
                return 0
            fi
        fi
    fi

    # Not in tmux (or tmux detection failed): start from $$
    local result
    result=$(_walk_up_to_kitty_child "$$")
    if [ -n "$result" ]; then
        _signal_debug "process tree: kitty -> $result"
        echo "$result"
        return 0
    fi

    _signal_debug "could not find kitty window PID"
    return 1
}

# --- Check if our tab is focused ---

_is_our_tab_focused() {
    local socket="$1"
    local window_pid="$2"
    local tab_info
    tab_info=$(kitty @ --to "unix:${socket}" ls 2>/dev/null)
    [ $? -eq 0 ] || return 1
    local focused
    focused=$(echo "$tab_info" | jq -r --argjson pid "$window_pid" '
        [.[] | .tabs[] | select(.windows[] | .pid == $pid)] | first |
        .is_focused // false
    ' 2>/dev/null)
    [ "$focused" = "true" ]
}

# --- Socket discovery ---

kitty_tab_find_socket() {
    local cached="/tmp/claude-mb-kitty-socket"

    # Return cached socket if still valid
    if [ -f "$cached" ]; then
        local sock
        sock=$(cat "$cached" 2>/dev/null)
        if [ -S "$sock" ]; then
            _signal_debug "using cached socket: $sock"
            echo "$sock"
            return 0
        fi
        rm -f "$cached"
    fi

    # Search for kitty socket
    local sock
    for sock in /tmp/mykitty-* /tmp/mykitty; do
        if [ -S "$sock" ]; then
            echo "$sock" > "$cached"
            _signal_debug "found socket: $sock"
            echo "$sock"
            return 0
        fi
    done

    _signal_debug "no kitty socket found"
    return 1
}

# --- Availability check ---

kitty_tab_available() {
    if [ "${CLAUDE_MB_KITTY_TAB:-true}" = "false" ]; then
        _signal_debug "disabled via CLAUDE_MB_KITTY_TAB=false"
        return 1
    fi

    if ! command -v kitty &> /dev/null; then
        _signal_debug "kitty not found"
        return 1
    fi

    if ! kitty_tab_find_socket > /dev/null; then
        return 1
    fi

    return 0
}

# --- Save current title and set working indicator ---

kitty_tab_save_and_mark() {
    local project="${1:-claude}"

    if ! kitty_tab_available; then return 0; fi

    local socket
    socket=$(kitty_tab_find_socket)

    # Find our kitty window PID -- this IS the unique key
    local window_pid
    window_pid=$(_find_kitty_window_pid)
    if [ -z "$window_pid" ]; then
        _signal_debug "could not find kitty window PID"
        return 0
    fi

    local title_file="/tmp/claude-mb-kitty-title-${window_pid}"
    local pid_file="/tmp/claude-mb-kitty-reset-pid-${window_pid}"

    # Cancel pending focus-watcher if exists
    if [ -f "$pid_file" ]; then
        local old_pid
        old_pid=$(cat "$pid_file" 2>/dev/null)
        if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
            kill "$old_pid" 2>/dev/null
            _signal_debug "cancelled pending watcher (pid $old_pid)"
        fi
        rm -f "$pid_file"
    fi

    local original_title
    if [ -f "$title_file" ]; then
        original_title=$(cat "$title_file" 2>/dev/null)
        _signal_debug "reusing saved title for window pid $window_pid: '$original_title'"
    else
        # First call: read current tab title via kitty @ ls + PID match
        local tab_info
        tab_info=$(kitty @ --to "unix:${socket}" ls 2>/dev/null)
        if [ $? -ne 0 ] || [ -z "$tab_info" ]; then
            _signal_debug "kitty @ ls failed"
            return 0
        fi

        original_title=$(echo "$tab_info" | jq -r --argjson pid "$window_pid" '
            [.[] | .tabs[] | select(.windows[] | .pid == $pid)] | first |
            .title // empty
        ' 2>/dev/null)

        if [ -z "$original_title" ]; then
            _signal_debug "could not read tab title for window pid $window_pid"
            return 0
        fi

        echo "$original_title" > "$title_file"
        _signal_debug "saved title for window pid $window_pid: '$original_title'"
    fi

    # Set working indicator as PREFIX
    local new_title="[ai...] ${original_title}"
    if kitty @ --to "unix:${socket}" set-tab-title --match "pid:${window_pid}" "$new_title" 2>/dev/null; then
        _signal_debug "title set to: '$new_title'"
    else
        _signal_debug "kitty @ set-tab-title failed"
    fi
}

# --- Restore original title (with [fin] transition) ---

kitty_tab_restore() {
    local project="${1:-claude}"

    if [ "${CLAUDE_MB_KITTY_TAB:-true}" = "false" ]; then return 0; fi

    # Find our kitty window PID -- same key as save
    local window_pid
    window_pid=$(_find_kitty_window_pid)
    if [ -z "$window_pid" ]; then
        _signal_debug "could not find kitty window PID for restore"
        return 0
    fi

    local title_file="/tmp/claude-mb-kitty-title-${window_pid}"
    local pid_file="/tmp/claude-mb-kitty-reset-pid-${window_pid}"

    if [ ! -f "$title_file" ]; then
        _signal_debug "no saved state for window pid $window_pid"
        return 0
    fi

    local original_title
    original_title=$(cat "$title_file" 2>/dev/null)

    local socket
    socket=$(kitty_tab_find_socket)
    if [ -z "$socket" ]; then
        rm -f "$title_file"
        return 0
    fi

    # Set finished indicator as PREFIX
    kitty @ --to "unix:${socket}" set-tab-title --match "pid:${window_pid}" "[fin] ${original_title}" 2>/dev/null
    _signal_debug "title set to: '[fin] ${original_title}'"

    # Background: watch for sustained tab focus (3s debounce), then restore
    (
        local focused_for=0
        while [ -f "$title_file" ]; do
            sleep 1
            if _is_our_tab_focused "$socket" "$window_pid"; then
                focused_for=$((focused_for + 1))
                if [ "$focused_for" -ge "${CLAUDE_MB_KITTY_RESET_INTERVAL:-3}" ]; then
                    kitty @ --to "unix:${socket}" set-tab-title --match "pid:${window_pid}" "$original_title" 2>/dev/null
                    rm -f "$title_file" "$pid_file"
                    _signal_debug "tab focused ${CLAUDE_MB_KITTY_RESET_INTERVAL:-3}s, restored to: '$original_title'"
                    break
                fi
            else
                focused_for=0
            fi
        done
    ) &
    echo $! > "$pid_file"
    _signal_debug "started focus watcher (pid $!)"
}

# --- Return kitty tab title if available, otherwise fallback ---

kitty_tab_get_display_name() {
    local fallback="${1:-claude}"

    # Try saved title file (already cached by kitty_tab_save_and_mark)
    local window_pid
    window_pid=$(_find_kitty_window_pid 2>/dev/null)
    if [ -n "$window_pid" ]; then
        local title_file="/tmp/claude-mb-kitty-title-${window_pid}"
        if [ -f "$title_file" ]; then
            local title
            title=$(cat "$title_file" 2>/dev/null)
            if [ -n "$title" ]; then
                echo "$title"
                return 0
            fi
        fi
    fi

    echo "$fallback"
}
