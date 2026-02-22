#!/bin/bash
# kitty-tab.sh: Kitty terminal tab indicator for Claude Code sessions
# Shows "[cc...]" suffix on tab title while Claude is working
#
# Requires kitty.conf:
#   allow_remote_control yes
#   listen_on unix:/tmp/mykitty
#
# Environment variables:
#   CLAUDE_MB_KITTY_TAB: "true" (default) or "false" to disable
#   CLAUDE_MB_SIGNAL_DEBUG: "true" for debug logging to stderr

# --- Debug helper ---

_signal_debug() {
    if [ "${CLAUDE_MB_SIGNAL_DEBUG:-false}" = "true" ]; then
        echo "[kitty-tab] $*" >&2
    fi
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

# --- Save current title and set indicator ---

kitty_tab_save_and_mark() {
    local project="${1:-claude}"
    local title_file="/tmp/claude-mb-kitty-title-${project}"
    local tab_id_file="/tmp/claude-mb-kitty-tab-id-${project}"

    if ! kitty_tab_available; then
        return 0
    fi

    local socket
    socket=$(kitty_tab_find_socket)

    # Get current tab info via kitty @ ls
    local tab_info
    tab_info=$(kitty @ --to "unix:${socket}" ls 2>/dev/null)
    if [ $? -ne 0 ] || [ -z "$tab_info" ]; then
        _signal_debug "kitty @ ls failed"
        return 0
    fi

    # Find the active tab's title and id
    local current_title tab_id
    current_title=$(echo "$tab_info" | jq -r '
        [.[] | .tabs[] | select(.is_focused == true)] | first |
        .title // empty
    ' 2>/dev/null)
    tab_id=$(echo "$tab_info" | jq -r '
        [.[] | .tabs[] | select(.is_focused == true)] | first |
        .id // empty
    ' 2>/dev/null)

    if [ -z "$current_title" ] || [ -z "$tab_id" ]; then
        _signal_debug "could not read tab title or id"
        return 0
    fi

    _signal_debug "current title: '$current_title', tab id: $tab_id"

    # Save original title and tab id
    echo "$current_title" > "$title_file"
    echo "$tab_id" > "$tab_id_file"

    # Set indicator title
    local new_title="${current_title} [cc...]"
    if kitty @ --to "unix:${socket}" set-tab-title --match "id:${tab_id}" "$new_title" 2>/dev/null; then
        _signal_debug "title set to: '$new_title'"
    else
        _signal_debug "kitty @ set-tab-title failed"
    fi
}

# --- Restore original title ---

kitty_tab_restore() {
    local project="${1:-claude}"
    local title_file="/tmp/claude-mb-kitty-title-${project}"
    local tab_id_file="/tmp/claude-mb-kitty-tab-id-${project}"

    if [ "${CLAUDE_MB_KITTY_TAB:-true}" = "false" ]; then
        return 0
    fi

    # Check if we have saved state
    if [ ! -f "$title_file" ] || [ ! -f "$tab_id_file" ]; then
        _signal_debug "no saved title/tab-id for project '$project'"
        return 0
    fi

    local original_title tab_id
    original_title=$(cat "$title_file" 2>/dev/null)
    tab_id=$(cat "$tab_id_file" 2>/dev/null)

    if [ -z "$original_title" ] || [ -z "$tab_id" ]; then
        _signal_debug "empty saved title or tab-id"
        rm -f "$title_file" "$tab_id_file"
        return 0
    fi

    local socket
    socket=$(kitty_tab_find_socket)
    if [ -z "$socket" ]; then
        rm -f "$title_file" "$tab_id_file"
        return 0
    fi

    if kitty @ --to "unix:${socket}" set-tab-title --match "id:${tab_id}" "$original_title" 2>/dev/null; then
        _signal_debug "title restored to: '$original_title'"
    else
        _signal_debug "kitty @ set-tab-title restore failed"
    fi

    rm -f "$title_file" "$tab_id_file"
}
