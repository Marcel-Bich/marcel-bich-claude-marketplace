#!/usr/bin/env bash
# track-work-repo.sh - limit plugin
#
# PostToolUse hook. On every relevant tool call of the MAIN agent it determines
# the git repo the call targets and records it in a per-session state file so the
# statusline can show, LIVE, the repo the main agent is currently working in -
# even when the user sits in a non-git hub directory (e.g. a workstation folder)
# and jumps between different git repos from there.
#
# State file (per session, read by usage-statusline.sh):
#   /tmp/claude-mb-workrepo_<session_id>   (contains the canonical repo toplevel)
#
# Design rules (robustness before elegance):
#   - The script ALWAYS exits 0. It must never block or delay a tool call and
#     must never crash on missing jq/git or malformed input.
#   - SUBAGENTS ARE IGNORED: only the main agent's work is tracked. The
#     discriminator is `.agent_id` (set only on real subagent calls), NOT
#     `.agent_type` (which is also set on the main agent of --agent sessions).
#   - STICKY: when a call yields no valid repo, the state file is left untouched
#     so the last known main-agent repo stays on the statusline.
#
# Bash command parsing (branch b) is intentionally limited to simple, common
# forms: absolute `cd <path>` and `-C <path>` (git -C) targets, optionally
# quoted, plus ~ / $HOME expansion. Relative paths are ignored. Exotic constructs
# (subshells, pushd, variable-built paths) are deliberately NOT covered.

# Never let a failure here disturb the session.
set +e

# 1. Read stdin JSON. Bail out cheaply on missing jq or empty input.
input=$(cat 2>/dev/null) || input=""
[[ -z "$input" ]] && exit 0
command -v jq >/dev/null 2>&1 || exit 0

# 2. Subagent filter: `.agent_id` is set only on real subagent tool calls and is
#    the official discriminator. If present and non-empty -> ignore this call.
agent_id=$(printf '%s' "$input" | jq -r '.agent_id // empty' 2>/dev/null) || agent_id=""
if [[ -n "$agent_id" && "$agent_id" != "null" ]]; then
    exit 0
fi

# 3. Session id - without it we have no key to write.
session_id=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null) || session_id=""
[[ -z "$session_id" || "$session_id" == "null" ]] && exit 0

# 4. Tool name determines how we find the candidate path(s).
tool_name=$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null) || tool_name=""
[[ -z "$tool_name" || "$tool_name" == "null" ]] && exit 0

STATE_FILE="/tmp/claude-mb-workrepo_${session_id}"

# Validate a path as a git repo. On success prints the canonical toplevel and
# returns 0; on failure returns non-zero and prints nothing.
validate_repo() {
    local p="$1"
    [[ -z "$p" ]] && return 1
    local top
    top=$(git -C "$p" rev-parse --show-toplevel 2>/dev/null) || return 1
    [[ -z "$top" ]] && return 1
    printf '%s' "$top"
    return 0
}

# Atomically persist a resolved repo root (temp file + mv).
write_state() {
    local repo="$1"
    local tmp="${STATE_FILE}.tmp.$$"
    printf '%s\n' "$repo" > "$tmp" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return; }
    mv -f "$tmp" "$STATE_FILE" 2>/dev/null || rm -f "$tmp" 2>/dev/null
}

# Expand a single path token (strip quotes, expand ~ / $HOME). Prints the
# expanded path and returns 0 only if it is ABSOLUTE; otherwise returns 1.
expand_token() {
    local t="$1"
    # Strip a single layer of surrounding quotes.
    if [[ "$t" == \"*\" ]]; then t="${t%\"}"; t="${t#\"}"; fi
    if [[ "$t" == \'*\' ]]; then t="${t%\'}"; t="${t#\'}"; fi
    case "$t" in
        '~')            t="$HOME" ;;
        '~/'*)          t="${HOME}/${t#\~/}" ;;
        '$HOME')        t="$HOME" ;;
        '$HOME/'*)      t="${HOME}/${t#\$HOME/}" ;;
        '${HOME}')      t="$HOME" ;;
        '${HOME}/'*)    t="${HOME}/${t#\$\{HOME\}/}" ;;
    esac
    [[ "$t" == /* ]] || return 1
    printf '%s' "$t"
    return 0
}

resolved_repo=""

case "$tool_name" in
    Edit|Write|MultiEdit)
        file_path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null) || file_path=""
        [[ -z "$file_path" || "$file_path" == "null" ]] && exit 0
        cand_dir=$(dirname "$file_path" 2>/dev/null) || cand_dir=""
        resolved_repo=$(validate_repo "$cand_dir") || resolved_repo=""
        ;;
    NotebookEdit)
        file_path=$(printf '%s' "$input" | jq -r '.tool_input.notebook_path // empty' 2>/dev/null) || file_path=""
        [[ -z "$file_path" || "$file_path" == "null" ]] && exit 0
        cand_dir=$(dirname "$file_path" 2>/dev/null) || cand_dir=""
        resolved_repo=$(validate_repo "$cand_dir") || resolved_repo=""
        ;;
    Bash)
        command_str=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null) || command_str=""
        [[ -z "$command_str" || "$command_str" == "null" ]] && exit 0

        # Collect cd targets and -C targets in appearance order.
        # A token is quoted-double, quoted-single, or a bare run of non-delimiters.
        cd_re="(^|[[:space:]\;\&\|\(])cd[[:space:]]+(\"[^\"]*\"|'[^']*'|[^[:space:]\;\&\|<>\(\)]+)"
        c_re="-C[[:space:]]+(\"[^\"]*\"|'[^']*'|[^[:space:]\;\&\|<>\(\)]+)"

        cd_cands=()
        c_cands=()

        rest="$command_str"
        while [[ "$rest" =~ $cd_re ]]; do
            tok="${BASH_REMATCH[2]}"
            exp=$(expand_token "$tok") && cd_cands+=("$exp")
            rest="${rest#*"${BASH_REMATCH[0]}"}"
        done

        rest="$command_str"
        while [[ "$rest" =~ $c_re ]]; do
            tok="${BASH_REMATCH[1]}"
            exp=$(expand_token "$tok") && c_cands+=("$exp")
            rest="${rest#*"${BASH_REMATCH[0]}"}"
        done

        # Priority for the PRIMARY candidate:
        #   1. last `cd` target (a shell ends up in the last cd it ran)
        #   2. else last `-C` target
        primary=""
        if [[ "${#cd_cands[@]}" -gt 0 ]]; then
            primary="${cd_cands[${#cd_cands[@]}-1]}"
        elif [[ "${#c_cands[@]}" -gt 0 ]]; then
            primary="${c_cands[${#c_cands[@]}-1]}"
        fi

        # No absolute cd / -C target at all -> leave the state file sticky.
        [[ -z "$primary" ]] && exit 0

        # Try the primary first; if it is not a real repo, fall back to the
        # remaining candidates newest-first (cd targets, then -C targets).
        resolved_repo=$(validate_repo "$primary") || resolved_repo=""
        if [[ -z "$resolved_repo" ]]; then
            fallback=()
            for ((i=${#cd_cands[@]}-1; i>=0; i--)); do fallback+=("${cd_cands[i]}"); done
            for ((i=${#c_cands[@]}-1; i>=0; i--)); do fallback+=("${c_cands[i]}"); done
            for cand in "${fallback[@]}"; do
                resolved_repo=$(validate_repo "$cand") && break
                resolved_repo=""
            done
        fi
        ;;
    *)
        # Any other tool is irrelevant to work-repo tracking.
        exit 0
        ;;
esac

# Only write when we actually resolved a repo (sticky otherwise).
[[ -n "$resolved_repo" ]] && write_state "$resolved_repo"

exit 0
