#!/bin/bash
# repo-context.sh: Location context for signal notifications (sourced helper)
# Part of desktop-notifier plugin for Claude Code
#
# Provides:
#   signal_cwd_label <cwd>          -> ".../<parent>/<base>" (or the path as is when short)
#   signal_git_label <cwd> <sid>    -> "git: <parent>/<repo>" or nothing
#   signal_title <base> <cwd>       -> "<base> | cwd: <cwd_label>" (or "<base>")
#   signal_session_label            -> "tmux: <session> | kitty: <tab>" (only parts that exist)
#   signal_body <git> <msg> [<sess>] -> "<git>\n<msg>\n\n<sess>" (empty parts are omitted)
#
# The git repo is resolved like the limit plugin's statusline git line:
#   0. limit's per-session work-repo state file /tmp/claude-mb-workrepo_<sid>
#   1. git discovery from cwd (git rev-parse --show-toplevel)
#   2. credo session pin via credo-config.sh resolve-project (soft dependency)
# All failures are silent and fall through; no network access.

_SIGNAL_RC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"

# Upper bound per external call so a slow filesystem never blocks the hook.
_signal_timeout() {
    if command -v timeout &> /dev/null; then
        timeout 2 "$@"
    else
        "$@"
    fi
}

# Print the git toplevel of <dir>, or nothing if it is not a git repo.
_signal_git_toplevel() {
    local dir="$1"
    [ -n "$dir" ] && [ -d "$dir" ] || return 1
    _signal_timeout git -C "$dir" rev-parse --show-toplevel 2>/dev/null
}

# Shorten a path to its last two segments: /a/b/c/d -> .../c/d
# Paths with at most two segments (/tmp, /home/marcel, /) are returned as is.
signal_cwd_label() {
    local path="$1"
    [ -z "$path" ] && return 0
    # Drop trailing slashes (but keep "/" itself)
    while [ "${#path}" -gt 1 ] && [ "${path%/}" != "$path" ]; do
        path="${path%/}"
    done
    local base parent grand
    base=$(basename "$path")
    parent=$(dirname "$path")
    grand=$(dirname "$parent")
    if [ "$path" = "/" ] || [ "$parent" = "/" ] || [ "$parent" = "." ] \
        || [ "$grand" = "/" ] || [ "$grand" = "." ]; then
        printf '%s' "$path"
    else
        printf '%s' ".../$(basename "$parent")/$base"
    fi
}

# Resolve the repo toplevel for <cwd> / <session_id>, print "git: <parent>/<repo>".
signal_git_label() {
    local cwd="${1:-$PWD}"
    local sid="$2"
    local repo_root=""

    # Reject session ids with unexpected characters (used in a file path).
    case "$sid" in
        *[!A-Za-z0-9._-]*) sid="" ;;
    esac

    # 0. limit's work-repo state file (soft dependency)
    if [ -n "$sid" ]; then
        local wr_file="/tmp/claude-mb-workrepo_${sid}"
        if [ -f "$wr_file" ]; then
            local wr_val=""
            wr_val=$(head -n 1 "$wr_file" 2>/dev/null | tr -d '\r')
            repo_root=$(_signal_git_toplevel "$wr_val") || repo_root=""
        fi
    fi

    # 1. git discovery from cwd
    if [ -z "$repo_root" ]; then
        repo_root=$(_signal_git_toplevel "$cwd") || repo_root=""
    fi

    # 2. credo session pin (soft dependency, located relative to this script)
    if [ -z "$repo_root" ] && [ -d "$cwd" ]; then
        local cfg="$_SIGNAL_RC_DIR/../../credo/scripts/credo-config.sh"
        if [ -f "$cfg" ] && [ -x "$cfg" ]; then
            local credo_dir=""
            # resolve-project prints "<repo>/.credo" (exit 0) or exits non-zero.
            credo_dir=$(cd "$cwd" 2>/dev/null && CLAUDE_CODE_SESSION_ID="$sid" CREDO_SESSION_ID="$sid" \
                _signal_timeout "$cfg" resolve-project 2>/dev/null) || credo_dir=""
            if [ -n "$credo_dir" ]; then
                repo_root=$(_signal_git_toplevel "$(dirname "$credo_dir")") || repo_root=""
            fi
        fi
    fi

    [ -n "$repo_root" ] || return 0
    printf '%s' "git: $(basename "$(dirname "$repo_root")")/$(basename "$repo_root")"
}

# Notification title: "<base> | cwd: <label>", or "<base>" without a cwd.
signal_title() {
    local base="$1"
    local label
    label=$(signal_cwd_label "$2")
    if [ -n "$label" ]; then
        printf '%s' "$base | cwd: $label"
    else
        printf '%s' "$base"
    fi
}

# Session location: "tmux: <session> | kitty: <tab title>", only the parts that exist.
# tmux: session of THIS pane (-t "$TMUX_PANE"), not the most recent client.
# kitty: clean tab title from kitty-tab.sh (only if kitty-tab.sh is loaded).
signal_session_label() {
    local parts=() tmux_name="" kitty_name=""
    if [ -n "${TMUX_PANE:-}" ] && command -v tmux &> /dev/null; then
        tmux_name=$(_signal_timeout tmux display-message -p -t "$TMUX_PANE" '#S' 2>/dev/null | head -n 1)
        [ -n "$tmux_name" ] && parts+=("tmux: $tmux_name")
    fi
    if declare -F kitty_tab_get_clean_title > /dev/null; then
        kitty_name=$(kitty_tab_get_clean_title 2>/dev/null)
        [ -n "$kitty_name" ] && parts+=("kitty: $kitty_name")
    fi
    [ "${#parts[@]}" -gt 0 ] || return 0
    local out="${parts[0]}"
    [ "${#parts[@]}" -gt 1 ] && out="$out | ${parts[1]}"
    printf '%s' "$out"
}

# Notification body: git line first (if any), then the message, then the
# session line set off by an empty line (if any). Empty parts leave no blank lines.
signal_body() {
    local git_label="$1"
    local message="$2"
    local session_label="${3:-}"
    local out="$message"
    [ -n "$git_label" ] && out="$git_label"$'\n'"$out"
    [ -n "$session_label" ] && out="$out"$'\n\n'"$session_label"
    printf '%s' "$out"
}
