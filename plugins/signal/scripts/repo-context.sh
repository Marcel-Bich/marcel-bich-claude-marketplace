#!/bin/bash
# repo-context.sh: Location context for signal notifications (sourced helper)
# Part of desktop-notifier plugin for Claude Code
#
# Provides:
#   signal_cwd_label <cwd>          -> ".../<parent>/<base>" (or the path as is when short)
#   signal_git_label <cwd> <sid>    -> "git: <parent>/<repo>" or nothing
#   signal_title <base> <cwd>       -> "<base> | cwd: <cwd_label>" (or "<base>")
#   signal_toast_name <sid> -> toast title name: user-set caption, else kitty tab,
#                                      else tmux session, else short session id (else "Claude Code");
#                                      every name is cut to 20 chars
#   signal_user_caption <sid>       -> the user-set session name only (never a derived one):
#                                      the session descriptor with nameSource "user", nothing else
#   signal_sid_short <sid>          -> short session id, e.g. a1b2c3d4-e5f6-7890-8bcd-0123456789d8 -> a-e-7-8-08
#   signal_adopt_client_tmux        -> exports TMUX / TMUX_PANE of the client pane when this process has none
#   signal_notify_key <sid> <project> <type> -> "session-<sid>-<type>" (or "project-<project>-<type>" without a valid sid)
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
# Paths with at most two segments (/tmp, /home/myuser, /) are returned as is.
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

# Replacement key for notify-replace.sh: one slot per session and hook type.
signal_notify_key() {
    local sid="$1" project="$2" type="$3"
    case "$sid" in
        ""|*[!A-Za-z0-9._-]*) printf '%s' "project-${project}-${type}" ;;
        *) printf '%s' "session-${sid}-${type}" ;;
    esac
}

# --- Toast title name ---------------------------------------------------------
#
# One fallback order for the title of EVERY toast (first hit wins):
#   1. the user-set session name: <config dir>/sessions/<pid>.json field "name", only when
#      "nameSource" is "user" (a derived or tooling name never counts; the transcript is not used)
#   2. the clean kitty tab title
#   3. the tmux session name of this session's pane
#   4. the short session id
# Every name is cut to 20 characters.
# Test hooks: SIGNAL_PROC_ROOT (default /proc) and SIGNAL_START_PID (default $$).

_SIGNAL_DESC_MAX_BYTES=262144
_SIGNAL_CAPTION_MAX=20

# Parent pid of <pid>, from <proc>/<pid>/stat.
_signal_ppid() {
    local stat="" rest="" ppid=""
    { read -r stat < "${SIGNAL_PROC_ROOT:-/proc}/$1/stat"; } 2>/dev/null || return 1
    rest="${stat##*) }"
    read -r _ ppid _ <<< "$rest"
    [ -n "$ppid" ] || return 1
    printf '%s' "$ppid"
}

# Load the argv of <pid> into _SIGNAL_ARGV (fails when unreadable or empty).
_signal_load_argv() {
    _SIGNAL_ARGV=()
    mapfile -d '' -t _SIGNAL_ARGV 2>/dev/null < "${SIGNAL_PROC_ROOT:-/proc}/$1/cmdline" || return 1
    [ "${#_SIGNAL_ARGV[@]}" -gt 0 ]
}

# Index of the "claude" token in _SIGNAL_ARGV (0 native, 1 behind node/bun/deno); fails
# when the loaded process (<pid>) is not the Claude Code CLI.
_signal_claude_end() {
    local a0="${_SIGNAL_ARGV[0]:-}" a1="${_SIGNAL_ARGV[1]:-}" b0 exe
    b0="${a0##*/}"
    if [ "$b0" = "claude" ]; then echo 0; return 0; fi
    case "$a0" in "claude "*) echo 0; return 0 ;; esac
    exe=$(readlink "${SIGNAL_PROC_ROOT:-/proc}/$1/exe" 2>/dev/null)
    case "$exe" in */claude/versions/*) echo 0; return 0 ;; esac
    case "${b0%%.*}" in
        node|bun|deno)
            case "$a1" in claude|*/claude|*claude-code*|*@anthropic-ai*) echo 1; return 0 ;; esac
            ;;
    esac
    return 1
}

# True when <pid> is a Claude client TUI (not a daemon or a pty host) owned by this user.
_signal_is_client() {
    local pid="$1" e
    [ "$pid" -gt 1 ] 2>/dev/null || return 1
    [ -O "${SIGNAL_PROC_ROOT:-/proc}/$pid" ] || return 1
    _signal_load_argv "$pid" || return 1
    e=$(_signal_claude_end "$pid") || return 1
    [[ "${_SIGNAL_ARGV[0]}" == *bg-pty-host* ]] && return 1
    case "${_SIGNAL_ARGV[$((e + 1))]:-}" in daemon|bg-pty-host) return 1 ;; esac
    return 0
}

# Client TUI of a daemon-hosted session: the parent of `claude daemon run`, else (daemon
# reparented) the pid of its --spawned-by JSON. Fails closed: nothing when it is no client.
# Expects the daemon's argv in _SIGNAL_ARGV.
_signal_daemon_client() {
    local dpid="$1" parent i sb=""
    local -a dargv=("${_SIGNAL_ARGV[@]}")
    parent=$(_signal_ppid "$dpid") || return 1
    if _signal_is_client "$parent"; then
        printf '%s' "$parent"
        return 0
    fi
    for ((i = 0; i < ${#dargv[@]}; i++)); do
        case "${dargv[i]}" in
            --spawned-by) sb="${dargv[i+1]:-}"; break ;;
            --spawned-by=*) sb="${dargv[i]#--spawned-by=}"; break ;;
        esac
    done
    [ -n "$sb" ] || return 1
    sb=$(printf '%s' "$sb" | head -c 4096 \
        | jq -r 'if type == "object" and (.pid | type) == "number" and .pid > 1 and (.pid | floor) == .pid then .pid else empty end' 2>/dev/null)
    [ -n "$sb" ] || return 1
    _signal_is_client "$sb" || return 1
    printf '%s' "$sb"
}

# Pid whose environment holds this session's TMUX / TMUX_PANE: the client TUI for a
# daemon-hosted session (the agent has none), else the nearest Claude ancestor.
_signal_client_pid() {
    local pid="${SIGNAL_START_PID:-$$}" n=0 first="" e
    while [ "$n" -lt 64 ] && [ "$pid" -gt 1 ] 2>/dev/null; do
        n=$((n + 1))
        if _signal_load_argv "$pid" && e=$(_signal_claude_end "$pid"); then
            [ -n "$first" ] || first="$pid"
            if [ "${_SIGNAL_ARGV[$((e + 1))]:-}" = "daemon" ] && [ "${_SIGNAL_ARGV[$((e + 2))]:-}" = "run" ]; then
                _signal_daemon_client "$pid"
                return
            fi
        fi
        pid=$(_signal_ppid "$pid") || break
    done
    [ -n "$first" ] && printf '%s' "$first"
    return 0
}

# When this process has no TMUX_PANE (daemon-hosted session, stripped env), take TMUX and
# TMUX_PANE from the client's /proc/<pid>/environ. Only these two keys are read and both
# are validated; anything odd leaves the environment untouched.
signal_adopt_client_tmux() {
    [ -n "${TMUX_PANE:-}" ] && return 0
    local client item tmux_val="" pane=""
    client=$(_signal_client_pid) || return 0
    [ -n "$client" ] || return 0
    while IFS= read -r -d '' item; do
        case "$item" in
            TMUX=*) tmux_val="${item#TMUX=}" ;;
            TMUX_PANE=*) pane="${item#TMUX_PANE=}" ;;
        esac
    done 2>/dev/null < "${SIGNAL_PROC_ROOT:-/proc}/$client/environ"
    [[ "$pane" =~ ^%[0-9]+$ ]] || return 0
    [[ "$tmux_val" =~ ^/[^,[:cntrl:]]+,[0-9]+,[0-9]+$ ]] || return 0
    export TMUX="$tmux_val" TMUX_PANE="$pane"
}

# Short session id (same rule as the credo peer names): first char of each dash group
# joined by "-", plus the last char: a1b2c3d4-e5f6-7890-8bcd-0123456789d8 -> a-e-7-8-08.
# "??" without an id.
signal_sid_short() {
    local sid rest g out=""
    sid=$(printf '%s' "${1:-}" | tr -cd 'A-Za-z0-9._-')
    [ -n "$sid" ] || sid="?"
    rest="$sid"
    while [ -n "$rest" ]; do
        g="${rest%%-*}"
        if [ "$g" = "$rest" ]; then rest=""; else rest="${rest#*-}"; fi
        if [ -n "$g" ]; then out="${out:+$out-}${g:0:1}"; fi
    done
    printf '%s' "$out${sid: -1}"
}

# Single-line name: all control characters removed, "null" dropped, surrounding blanks
# trimmed, cut to 20 chars. Used for every name in the title.
_signal_label_clean() {
    local v
    v=$(printf '%s' "${1:-}" | tr -d '[:cntrl:]')
    v="${v#"${v%%[![:space:]]*}"}"
    v="${v%"${v##*[![:space:]]}"}"
    [ "$v" = "null" ] && v=""
    printf '%s' "${v:0:$_SIGNAL_CAPTION_MAX}"
}

# The user-set session name from the session descriptor (see signal_user_caption).
# Looks for <config dir>/sessions/<pid>.json along the process ancestry; a descriptor naming
# another session id, or none while the session id is known, is skipped. Read safely: owned
# regular file, no symlink, first 256 KiB only, control characters removed. A name counts
# only with "nameSource": "user".
_signal_caption_descriptor() {
    local sid cfg pid n=0 f res=""
    sid=$(printf '%s' "${1:-}" | tr -cd 'A-Za-z0-9._-')
    cfg="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
    pid="${SIGNAL_START_PID:-$$}"
    while [ "$n" -lt 64 ] && [ "$pid" -gt 1 ] 2>/dev/null; do
        n=$((n + 1))
        f="$cfg/sessions/$pid.json"
        if [ -f "$f" ] && [ ! -L "$f" ] && [ -O "$f" ]; then
            res=$(head -c "$_SIGNAL_DESC_MAX_BYTES" "$f" 2>/dev/null | jq -r --arg sid "$sid" --argjson max "$_SIGNAL_CAPTION_MAX" '
                if ($sid != "" and ((.sessionId | type) != "string" or .sessionId != $sid)) then "skip"
                elif (.nameSource == "user" and (.name | type) == "string") then
                    "ok" + (.name | gsub("[\\p{Cc}]"; "") | .[0:$max] | sub("^\\s+"; "") | sub("\\s+$"; ""))
                else "ok" end' 2>/dev/null)
            case "$res" in
                ok*) printf '%s' "${res#ok}"; return 0 ;;
            esac
        fi
        pid=$(_signal_ppid "$pid") || break
    done
    return 0
}

# The user-set session name (max 20 chars), or nothing; never a name Claude Code derived.
# Only the session descriptor with nameSource "user" counts, no transcript fallback.
signal_user_caption() {
    _signal_caption_descriptor "${1:-}"
}

# tmux session name of this session's pane (-t "$TMUX_PANE"), or nothing.
_signal_tmux_name() {
    [ -n "${TMUX_PANE:-}" ] && command -v tmux &> /dev/null || return 0
    _signal_timeout tmux display-message -p -t "$TMUX_PANE" '#S' 2>/dev/null | head -n 1
}

# Name for the title of every toast, see the order above. "Claude Code" when even the
# session id is unknown.
signal_toast_name() {
    local sid name=""
    sid=$(printf '%s' "${1:-}" | tr -cd 'A-Za-z0-9._-')
    signal_adopt_client_tmux
    name=$(signal_user_caption "$sid")
    if [ -z "$name" ] && declare -F kitty_tab_get_clean_title > /dev/null; then
        name=$(_signal_label_clean "$(kitty_tab_get_clean_title 2>/dev/null)")
    fi
    if [ -z "$name" ]; then
        name=$(_signal_label_clean "$(_signal_tmux_name)")
    fi
    if [ -z "$name" ] && [ -n "$sid" ]; then
        name=$(signal_sid_short "$sid")
    fi
    [ -n "$name" ] || name="Claude Code"
    printf '%s' "$name"
}

# Session location: "tmux: <session> | kitty: <tab title>", only the parts that exist.
# tmux: session of THIS session's pane (-t "$TMUX_PANE"), not the most recent client; for
# daemon-hosted sessions the pane of the client (see signal_adopt_client_tmux).
# kitty: clean tab title from kitty-tab.sh (only if kitty-tab.sh is loaded).
signal_session_label() {
    local parts=() tmux_name="" kitty_name=""
    signal_adopt_client_tmux
    tmux_name=$(_signal_tmux_name)
    [ -n "$tmux_name" ] && parts+=("tmux: $tmux_name")
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
