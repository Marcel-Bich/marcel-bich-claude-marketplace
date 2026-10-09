#!/bin/bash
# Dogma: Shared Permissions Library
# Used by all dogma readers of DOGMA-PERMISSIONS.md (hooks and read-only scripts)
#
# Finds the applicable DOGMA-PERMISSIONS.md (target of the action > credo pinned
# project > upward from $PWD) and inherits settings it does not define from the
# session folder's file (see "Which DOGMA-PERMISSIONS.md applies" below).
# If no file is found, returns empty (allow by default)
#
# Use /dogma:permissions to create the permissions file interactively

# Debug log file
DOGMA_DEBUG_LOG="/tmp/dogma-debug.log"

# Check if we're in a hydra worktree (not the main repo)
# Worktrees are isolated - agents there can work freely
is_hydra_worktree() {
    # Get worktree list
    local worktrees
    worktrees=$(git worktree list 2>/dev/null) || return 1
    local worktree_count
    worktree_count=$(echo "$worktrees" | wc -l)

    # Only one worktree = we're in main repo
    if [ "$worktree_count" -le 1 ]; then
        return 1
    fi

    # Get main worktree path (first line)
    local main_worktree
    main_worktree=$(echo "$worktrees" | head -1 | awk '{print $1}')
    local current_dir
    current_dir=$(pwd)

    # If current dir starts with main worktree path, we're in main
    if [[ "$current_dir" == "$main_worktree" ]] || [[ "$current_dir" == "$main_worktree"/* ]]; then
        return 1  # In main repo
    fi

    # We're in a secondary worktree
    dogma_debug_log "Detected hydra worktree: $current_dir"
    return 0
}

# Debug logging function (like limit plugin)
dogma_debug_log() {
    if [ "${CLAUDE_MB_DOGMA_DEBUG:-false}" = "true" ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$DOGMA_DEBUG_LOG"
    fi
}

# --- Which DOGMA-PERMISSIONS.md applies --------------------------------------
# Resolution order (the first start dir that applies wins; from it the file is
# searched upward as always):
#   1. the TARGET of the action when it is recognisable: a Bash command's
#      `git -C <dir> ...` / leading `cd <dir> && ...` / `cd <dir>; ...`, or a file
#      tool's own path (callers pass it to find_permissions_file / load_permissions).
#   2. the credo PINNED project (credo-config.sh resolve-project: CREDO_DIR or the
#      per-session pin of /credo:project) when credo is installed; skipped when the
#      current dir lies inside that project anyway. dogma never needs credo.
#   3. upward from the current dir ($PWD) - the behaviour before resolution existed.
# For a target or a pinned project the main worktree of the repository is searched as
# well when nothing is found upward (a linked worktree may lack the excluded file).
# When the target / pinned project / current dir has no file of its own, the session
# folder's file applies (everything is inherited).
#
# Session folder = the folder the Claude Code session was started in: DOGMA_SESSION_DIR
# when set, else the dir the SessionStart hook (hooks/session-dir-record.sh) recorded
# for this session in ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/dogma/session-dirs/<id>
# (credo's .../credo/session-dirs/<id> as well; id = CLAUDE_CODE_SESSION_ID, else
# DOGMA_SESSION_ID) when that dir still exists, else $PWD. The record keeps
# inheritance working when a Bash tool command ran `cd <project> && ...` first;
# without a record everything behaves as before.
#
# Inheritance (checkbox "(§r3nx) inherit permissions", missing = on): when the resolved
# file is not the session folder's file, every setting it does not define is taken
# from the session folder's file; settings defined in the resolved file always win.
# Lookups go per setting id (text fallback for lines without ids, within each file).
#
# Env overrides (mainly for tests):
#   DOGMA_SESSION_DIR   session folder and current dir (default: recorded session
#                       folder, else $PWD; current dir $PWD)
#   DOGMA_CREDO_CONFIG  path to credo's credo-config.sh, or "none" to skip step 2
#   DOGMA_SESSION_ID    session id for the credo pin (hooks set it from their input)

DOGMA_INHERIT_ID="r3nx"

# The session folder recorded by the SessionStart hook for this session (dogma's
# record, then credo's). Prints it; returns 1 when there is none or the dir is gone.
dogma_recorded_session_dir() {
    local sid="${CLAUDE_CODE_SESSION_ID:-${DOGMA_SESSION_ID:-}}" base="${CLAUDE_CONFIG_DIR:-$HOME/.claude}" rec d
    case "$sid" in
        ""|.|..|*[!A-Za-z0-9._-]*) return 1 ;;
    esac
    for rec in "$base/dogma/session-dirs/$sid" "$base/credo/session-dirs/$sid"; do
        [ -f "$rec" ] || continue
        d=""
        IFS= read -r d < "$rec" || true
        case "$d" in
            /*) [ -d "$d" ] && { printf '%s\n' "$d"; return 0; } ;;
        esac
    done
    return 1
}

# The session folder: DOGMA_SESSION_DIR > recorded session folder > $PWD
dogma_session_dir() {
    if [ -n "${DOGMA_SESSION_DIR:-}" ]; then
        printf '%s\n' "$DOGMA_SESSION_DIR"
    else
        dogma_recorded_session_dir || printf '%s\n' "$PWD"
    fi
}

# The current dir (where the lookup without target / pin starts): DOGMA_SESSION_DIR
# when set (tests, notices), else $PWD
dogma_current_dir() {
    printf '%s\n' "${DOGMA_SESSION_DIR:-$PWD}"
}

# Make a path absolute (relative to $PWD) without touching the filesystem.
dogma_abs_path() {
    local p="$1"
    case "$p" in
        "~") p="$HOME" ;;
        "~/"*) p="$HOME/${p#\~/}" ;;
        '$HOME') p="$HOME" ;;
        '$HOME/'*) p="$HOME/${p#\$HOME/}" ;;
        '${HOME}') p="$HOME" ;;
        '${HOME}/'*) p="$HOME/${p#\$\{HOME\}/}" ;;
    esac
    case "$p" in
        /*) ;;
        *) p="$PWD/$p" ;;
    esac
    while [ "${#p}" -gt 1 ] && [ "${p%/}" != "$p" ]; do p="${p%/}"; done
    printf '%s\n' "$p"
}

# Nearest existing directory at or above a path (prints it; returns 1 if none).
dogma_existing_dir() {
    local d
    d="$(dogma_abs_path "$1")"
    [ -f "$d" ] && d="$(dirname "$d")"
    while [ -n "$d" ] && [ "$d" != "/" ] && [ ! -d "$d" ]; do
        d="$(dirname "$d")"
    done
    [ -n "$d" ] && [ "$d" != "/" ] && [ -d "$d" ] || return 1
    printf '%s\n' "$d"
}

# Upward search for DOGMA-PERMISSIONS.md from an absolute dir (prints the path).
dogma_find_up() {
    local dir="$1"
    while [ -n "$dir" ] && [ "$dir" != "/" ] && [ "$dir" != "." ]; do
        if [ -f "$dir/DOGMA-PERMISSIONS.md" ]; then
            printf '%s\n' "$dir/DOGMA-PERMISSIONS.md"
            return 0
        fi
        dir="$(dirname "$dir")"
    done
    return 1
}

# Upward search plus the main worktree of the repository as fallback.
dogma_find_from() {
    dogma_find_up "$1" && return 0
    local main
    main="$(git -C "$1" worktree list --porcelain 2>/dev/null | sed -n '1s/^worktree //p')" || main=""
    if [ -n "$main" ] && [ -f "$main/DOGMA-PERMISSIONS.md" ]; then
        printf '%s\n' "$main/DOGMA-PERMISSIONS.md"
        return 0
    fi
    return 1
}

# Strip one level of quotes from a shell word.
dogma_unquote() {
    local w="$1"
    case "$w" in
        \"*\") w="${w#\"}"; w="${w%\"}" ;;
        \'*\') w="${w#\'}"; w="${w%\'}" ;;
    esac
    printf '%s\n' "$w"
}

# Target dir of a Bash command (prints an existing absolute dir; returns 1 if none).
# Recognised: `git -C <dir> ...` anywhere, a leading `cd <dir> && ...` / `cd <dir>; ...`
# (optionally inside "( ... )"). A relative `git -C` dir is taken relative to the cd dir.
dogma_target_from_command() {
    local cmd="$1" base="" dir="" word
    local q='("[^"]+"|'"'"'[^'"'"']+'"'"'|[^[:space:];&|()]+)'
    local re_cd='^[[:space:]]*\(?[[:space:]]*cd[[:space:]]+'"$q"'[[:space:]]*(&&|;)'
    local re_c='(^|[[:space:];&|(])git[[:space:]]+-C[[:space:]]+'"$q"
    if [[ "$cmd" =~ $re_cd ]]; then
        word="$(dogma_unquote "${BASH_REMATCH[1]}")"
        base="$(dogma_abs_path "$word")"
        [ -d "$base" ] || base=""
    fi
    if [[ "$cmd" =~ $re_c ]]; then
        word="$(dogma_unquote "${BASH_REMATCH[2]}")"
        case "$word" in
            /*|"~"|"~/"*|'$HOME'*|'${HOME}'*) dir="$(dogma_abs_path "$word")" ;;
            *) dir="$(cd "${base:-$PWD}" 2>/dev/null && dogma_abs_path "$word")" ;;
        esac
        [ -d "$dir" ] || dir=""
    fi
    [ -n "$dir" ] || dir="$base"
    [ -n "$dir" ] || return 1
    printf '%s\n' "$dir"
}

# Locate credo's credo-config.sh (prints the path; returns 1 when credo is absent).
dogma_credo_config() {
    case "${DOGMA_CREDO_CONFIG:-}" in
        none) return 1 ;;
        "") ;;
        *)
            [ -f "$DOGMA_CREDO_CONFIG" ] || return 1
            printf '%s\n' "$DOGMA_CREDO_CONFIG"
            return 0
            ;;
    esac
    local here f
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # marketplace / source layout: plugins/dogma/scripts -> plugins/credo/scripts
    f="$here/../../credo/scripts/credo-config.sh"
    if [ -f "$f" ]; then
        printf '%s\n' "$f"
        return 0
    fi
    # plugin cache layout: <cache>/<marketplace>/<plugin>/<version>/scripts
    f="$(ls -d "$here"/../../../credo/*/scripts/credo-config.sh \
        "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"/plugins/cache/*/credo/*/scripts/credo-config.sh 2>/dev/null \
        | sort -V | tail -n1)"
    [ -n "$f" ] && [ -f "$f" ] || return 1
    printf '%s\n' "$f"
}

# The credo pinned project dir (prints it; returns 1 when there is none, credo is
# absent, or the current dir lies inside the project anyway).
dogma_pinned_dir() {
    local cfg credo_dir proj sess
    cfg="$(dogma_credo_config)" || return 1
    credo_dir="$(CLAUDE_CODE_SESSION_ID="${CLAUDE_CODE_SESSION_ID:-${DOGMA_SESSION_ID:-}}" \
        bash "$cfg" resolve-project 2>/dev/null)" || return 1
    [ -n "$credo_dir" ] || return 1
    proj="$(dirname "$(dogma_abs_path "$credo_dir")")"
    [ -d "$proj" ] || return 1
    proj="$(cd "$proj" && pwd -P)"
    sess="$(cd "$(dogma_current_dir)" 2>/dev/null && pwd -P)" || sess=""
    case "$sess/" in
        "$proj"/*) return 1 ;;
    esac
    printf '%s\n' "$proj"
}

# Same file? (compares resolved paths)
dogma_same_file() {
    [ "$1" = "$2" ] && return 0
    local a b
    a="$(readlink -f "$1" 2>/dev/null)" || a="$1"
    b="$(readlink -f "$2" 2>/dev/null)" || b="$2"
    [ "$a" = "$b" ]
}

# Resolve the applicable file. Sets (no subshell):
#   DOGMA_RESOLVED_FILE  the file that applies (empty when none)
#   DOGMA_SESSION_FILE   the session folder's file (empty when none)
#   DOGMA_RESOLVED_FROM  target | pinned | cwd | session
# Usage: dogma_resolve [target]   (target: a dir or file path; empty = none)
dogma_resolve() {
    local target="${1:-}" start="" f="" sdir cur
    DOGMA_RESOLVED_FILE=""
    DOGMA_RESOLVED_FROM="session"
    sdir="$(dogma_session_dir)"
    DOGMA_SESSION_FILE="$(dogma_find_up "$(dogma_abs_path "$sdir")")" || DOGMA_SESSION_FILE=""
    if [ -n "$target" ]; then
        start="$(dogma_existing_dir "$target")" || start=""
        [ -n "$start" ] && DOGMA_RESOLVED_FROM="target"
    fi
    if [ -z "$start" ]; then
        start="$(dogma_pinned_dir)" || start=""
        [ -n "$start" ] && DOGMA_RESOLVED_FROM="pinned"
    fi
    # a recorded session folder differs from the cwd: the cwd's own file comes first
    cur="$(dogma_current_dir)"
    if [ -z "$start" ] && [ "$cur" != "$sdir" ]; then
        start="$(dogma_existing_dir "$cur")" || start=""
        [ -n "$start" ] && DOGMA_RESOLVED_FROM="cwd"
    fi
    if [ -n "$start" ]; then
        f="$(dogma_find_from "$start")" || f=""
    fi
    if [ -z "$f" ]; then
        f="$DOGMA_SESSION_FILE"
        DOGMA_RESOLVED_FROM="session"
    fi
    DOGMA_RESOLVED_FILE="$f"
    dogma_debug_log "Resolved permissions ($DOGMA_RESOLVED_FROM): ${f:-none}, session file: ${DOGMA_SESSION_FILE:-none}"
}

# Find permissions file (returns path or empty). Optional arg: the action's target
# (dir or file path). Without it: pinned project, then upward from $PWD, then the
# session folder's file.
find_permissions_file() {
    dogma_resolve "${1:-}"
    if [ -n "$DOGMA_RESOLVED_FILE" ]; then
        dogma_debug_log "Found permissions: $DOGMA_RESOLVED_FILE"
        printf '%s\n' "$DOGMA_RESOLVED_FILE"
        return 0
    fi
    dogma_debug_log "No DOGMA-PERMISSIONS.md found"
    return 1
}

# The file the resolved file inherits from (prints it; returns 1 when there is no
# inheritance: same file as the session folder's, no session file, or the resolved
# file switches inheritance off with "- [ ] (§r3nx) inherit permissions").
# Usage: dogma_inherit_file <resolved_file> [session_file]
dogma_inherit_file() {
    local file="$1" sess
    if [ $# -ge 2 ]; then
        sess="$2"
    else
        sess="$(dogma_find_up "$(dogma_abs_path "$(dogma_session_dir)")")" || sess=""
    fi
    [ -n "$file" ] && [ -n "$sess" ] && [ -f "$sess" ] || return 1
    dogma_same_file "$file" "$sess" && return 1
    local state block
    block="$(get_permissions_section "$file")"
    if state=$(perm_state_by_id "$block" "$DOGMA_INHERIT_ID"); then
        case "$state" in " "|0) return 1 ;; esac
    elif printf '%s\n' "$block" | grep -qiE '^[[:space:]]*-[[:space:]]*\[( |0)\].*inherit permissions'; then
        return 1
    fi
    printf '%s\n' "$sess"
}

# Load the applicable permissions into the current shell (no subshell). Sets
#   PERMS_FILE, PERMS_SECTION                    the resolved file and its block
#   DOGMA_INHERIT_FILE, DOGMA_INHERIT_SECTION    the inherited file and its block
#                                                (empty without inheritance)
# get_permission_mode / check_permission / perm_is_checked / perm_has_heading fall
# back to DOGMA_INHERIT_SECTION for settings the given content does not define.
# Usage: load_permissions [target]; returns 1 when no file applies.
load_permissions() {
    dogma_resolve "${1:-}"
    PERMS_FILE="$DOGMA_RESOLVED_FILE"
    PERMS_SECTION=""
    DOGMA_INHERIT_FILE=""
    DOGMA_INHERIT_SECTION=""
    [ -n "$PERMS_FILE" ] || return 1
    PERMS_SECTION="$(get_permissions_section "$PERMS_FILE")"
    if DOGMA_INHERIT_FILE="$(dogma_inherit_file "$PERMS_FILE" "$DOGMA_SESSION_FILE")"; then
        DOGMA_INHERIT_SECTION="$(get_permissions_section "$DOGMA_INHERIT_FILE")"
        dogma_debug_log "Inheriting missing settings from: $DOGMA_INHERIT_FILE"
    else
        DOGMA_INHERIT_FILE=""
    fi
    return 0
}

# Remember the hook's session id (for the credo pin lookup).
# Usage: dogma_session_from_input "$INPUT"
dogma_session_from_input() {
    local sid
    sid="$(printf '%s' "$1" | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([A-Za-z0-9._-]*\)".*/\1/p' | head -n1)"
    [ -n "$sid" ] && DOGMA_SESSION_ID="$sid"
    return 0
}

# Extract permissions section from file
get_permissions_section() {
    local file="$1"
    if [ -f "$file" ]; then
        sed -n '/<permissions>/,/<\/permissions>/p' "$file" 2>/dev/null
    fi
}

# --- Stable setting ids -------------------------------------------------------
# Every setting in the DOGMA-PERMISSIONS.md template carries a fixed id "(§xxxx)"
# (4 lowercase base36 chars) right after its checkbox, e.g.
#   - [ ] (§8eyz) run ALL tests only at release
# Ids are the same in every repo (see docs/permission-ids.md). Readers match the id
# first, anywhere in the given block; only when no line carries the id they fall back
# to the old text pattern, so files without ids keep working and the wording is free.
#
# A spec may be passed wherever a pattern is accepted:
#   "§xxxx|pattern"   id first, pattern as fallback
#   "§xxxx"           id only (no fallback)
#   "pattern"         text only (old behaviour)

# Split a spec into PERM_SPEC_ID and PERM_SPEC_PATTERN (globals, no subshell)
perm_split_spec() {
    local spec="$1"
    PERM_SPEC_ID=""
    PERM_SPEC_PATTERN="$spec"
    local re_full='^§([0-9a-z]{4})[|](.*)$'
    local re_id='^§([0-9a-z]{4})$'
    if [[ "$spec" =~ $re_full ]]; then
        PERM_SPEC_ID="${BASH_REMATCH[1]}"
        PERM_SPEC_PATTERN="${BASH_REMATCH[2]}"
    elif [[ "$spec" =~ $re_id ]]; then
        PERM_SPEC_ID="${BASH_REMATCH[1]}"
        PERM_SPEC_PATTERN=""
    fi
}

# Print the checkbox character of the first checkbox line carrying "(§id)" in the
# given content. Returns 1 (prints nothing) when no line carries the id.
perm_state_by_id() {
    local content="$1"
    local id="$2"
    [ -n "$id" ] && [ -n "$content" ] || return 1
    local line
    line=$(printf '%s\n' "$content" | grep -m1 -E "^[[:space:]]*-[[:space:]]*\[.\].*\(§${id}\)") || return 1
    [ -n "$line" ] || return 1
    printf '%s\n' "$line" | sed -E 's/^[[:space:]]*-[[:space:]]*\[(.)\].*/\1/'
}

# Map a checkbox character to a mode (auto/ask/deny/one/all). Unknown -> auto.
perm_state_to_mode() {
    case "$1" in
        x) echo "auto" ;;
        "?") echo "ask" ;;
        " "|0) echo "deny" ;;
        1) echo "one" ;;
        a) echo "all" ;;
        *) echo "auto" ;;
    esac
}

# Is a workflow checkbox switched on ([x])?
# Usage: perm_is_checked <content> <id> <fallback_regex>
# Id first; without an id line, case-insensitive "- [x] ...<fallback_regex>".
# A setting the content does not define at all (no id line, no text line in any
# state) is looked up in the inherited block (DOGMA_INHERIT_SECTION, see
# load_permissions) when there is one.
perm_is_checked() {
    local content="$1" id="$2" regex="$3"
    if perm_is_checked_in "$content" "$id" "$regex"; then
        return 0
    elif [ $? -eq 1 ]; then
        return 1
    fi
    if [ -n "${DOGMA_INHERIT_SECTION:-}" ] && [ "$content" != "$DOGMA_INHERIT_SECTION" ]; then
        perm_is_checked_in "$DOGMA_INHERIT_SECTION" "$id" "$regex"
        [ $? -eq 0 ]
        return
    fi
    return 1
}

# One content only: 0 = checked, 1 = defined but not checked, 2 = not defined.
perm_is_checked_in() {
    local content="$1" id="$2" regex="$3"
    local state
    if state=$(perm_state_by_id "$content" "$id"); then
        [ "$state" = "x" ] && return 0
        return 1
    fi
    [ -n "$regex" ] || return 2
    if printf '%s\n' "$content" | grep -qiE "^[[:space:]]*-[[:space:]]*\[x\].*$regex"; then
        return 0
    fi
    if printf '%s\n' "$content" | grep -qiE "^[[:space:]]*-[[:space:]]*\[.\].*$regex"; then
        return 1
    fi
    return 2
}

# Does the content have the heading of a parsed section?
# Usage: perm_has_heading <content> <id> <heading_text>
# Id first (any heading level ## or deeper carrying "(§id)"), else "### <heading_text>"
# matched case-insensitively (an optional trailing id is allowed). Falls back to the
# inherited block (DOGMA_INHERIT_SECTION) when there is one.
perm_has_heading() {
    local content="$1" id="$2" text="$3"
    perm_has_heading_in "$content" "$id" "$text" && return 0
    if [ -n "${DOGMA_INHERIT_SECTION:-}" ] && [ "$content" != "$DOGMA_INHERIT_SECTION" ]; then
        perm_has_heading_in "$DOGMA_INHERIT_SECTION" "$id" "$text"
        return
    fi
    return 1
}

perm_has_heading_in() {
    local content="$1" id="$2" text="$3"
    if [ -n "$id" ] && printf '%s\n' "$content" | grep -qE "^[[:space:]]*##+[[:space:]].*\(§${id}\)"; then
        return 0
    fi
    printf '%s\n' "$content" | grep -qiE "^[[:space:]]*###[[:space:]]+${text}[[:space:]]*(\(§[0-9a-z]{4}\))?[[:space:]]*$"
}

# Extract a section of a <permissions> block (helper of get_permission_mode).
#   "### Subsection Name" -> until next ## or ### or </permissions>
#   "## Section Name"     -> until next ## or </permissions> (includes ### subsections)
perm_extract_section() {
    local full_perms="$1" section="$2" out
    out=$(printf '%s\n' "$full_perms" | \
        sed -n "/^### $section\$/,/^##/p" | \
        sed '1d' | \
        sed '/^##/d')
    if [ -z "$out" ]; then
        out=$(printf '%s\n' "$full_perms" | \
            sed -n "/^## $section\$/,/^## [^#]/p" | \
            sed '1d' | \
            sed '/^## [^#]/d')
        if [ -z "$out" ]; then
            out=$(printf '%s\n' "$full_perms" | \
                sed -n "/^## $section\$/,/<\/permissions>/p" | \
                sed '1d' | \
                sed '/<\/permissions>/d')
        fi
    fi
    printf '%s\n' "$out"
}

# Look one setting up in one block (no default, no inheritance).
# Usage: perm_lookup <id_scope> <spec> <text_scope>
#   id_scope    content searched for the id (the whole <permissions> block)
#   text_scope  content searched for the text pattern (the block or one section)
# Prints the mode (auto/ask/deny/one/all) and returns 0, or returns 1 when the block
# does not define the setting.
perm_lookup() {
    local id_scope="$1" spec="$2" text_scope="$3"
    perm_split_spec "$spec"
    local pattern="$PERM_SPEC_PATTERN" id="$PERM_SPEC_ID"
    local id_state
    if id_state=$(perm_state_by_id "$id_scope" "$id"); then
        dogma_debug_log "Permission by id $id: [$id_state]"
        perm_state_to_mode "$id_state"
        return 0
    fi
    [ -n "$text_scope" ] && [ -n "$pattern" ] || return 1
    local state mode
    # same precedence as before: [x], [?], [ ], [1], [a], [0]
    for state in x '?' ' ' 1 a 0; do
        if printf '%s\n' "$text_scope" | grep -qE "^\s*-\s*\[[$state]\].*$pattern"; then
            mode=$(perm_state_to_mode "$state")
            dogma_debug_log "Permission mode $mode for: $pattern"
            echo "$mode"
            return 0
        fi
    done
    return 1
}

# Look a setting up in the inherited block (DOGMA_INHERIT_SECTION) when there is one.
# Usage: perm_lookup_inherited <spec> [section] ; same output as perm_lookup.
perm_lookup_inherited() {
    local spec="$1" section="${2:-}" text_scope
    [ -n "${DOGMA_INHERIT_SECTION:-}" ] || return 1
    text_scope="$DOGMA_INHERIT_SECTION"
    if [ -n "$section" ]; then
        text_scope=$(perm_extract_section "$DOGMA_INHERIT_SECTION" "$section")
    fi
    perm_lookup "$DOGMA_INHERIT_SECTION" "$spec" "$text_scope"
}

# Which file defines a setting after load_permissions? Prints PERMS_FILE when its
# block defines the spec, DOGMA_INHERIT_FILE when only the inherited block does,
# else PERMS_FILE (the setting is missing everywhere and defaults).
perm_defining_file() {
    local spec="$1"
    if [ -n "${DOGMA_INHERIT_FILE:-}" ] \
        && ! perm_lookup "${PERMS_SECTION:-}" "$spec" "${PERMS_SECTION:-}" >/dev/null \
        && perm_lookup_inherited "$spec" >/dev/null; then
        printf '%s\n' "$DOGMA_INHERIT_FILE"
        return 0
    fi
    printf '%s\n' "${PERMS_FILE:-}"
}

# Check if permission is granted (legacy - use get_permission_mode for 3-state)
# Returns 0 (true) if allowed, 1 (false) if blocked
# If pattern not found, returns 0 (allow by default)
# pattern may be a spec "§xxxx|pattern" (id first, see above)
# A setting the section does not define is taken from the inherited block
# (DOGMA_INHERIT_SECTION, see load_permissions) when there is one.
check_permission() {
    local perms_section="$1"
    local pattern="$2"
    local mode=""

    if [ -n "$perms_section" ]; then
        mode=$(perm_lookup "$perms_section" "$pattern" "$perms_section") || mode=""
    fi
    if [ -z "$mode" ] && [ "$perms_section" != "${DOGMA_INHERIT_SECTION:-}" ]; then
        mode=$(perm_lookup_inherited "$pattern") || mode=""
    fi
    case "$mode" in
        deny)
            dogma_debug_log "Permission denied for: $pattern"
            return 1
            ;;
        "")
            dogma_debug_log "Permission not found: $pattern - allowing by default"
            return 0
            ;;
        *)
            # auto, ask (legacy: allowed, caller should use get_permission_mode), one, all
            return 0
            ;;
    esac
}

# Get permission mode (extended states: auto/ask/deny/one/all)
# Returns: "auto", "ask", "deny", "one", or "all"
# If pattern not found, returns "auto" (allow by default)
#
# Checkbox states:
#   [x] = auto (all relevant)
#   [?] = ask (prompt user)
#   [ ] = deny/disabled
#   [1] = one (only one at a time)
#   [a] = all (everything, not just relevant)
#   [0] = deny/disabled (same as [ ])
#
# Usage:
#   get_permission_mode "pattern" [permissions_file] [section]
#   - pattern may be a spec "§xxxx|pattern" (or "§xxxx"): the id is matched first in
#     the whole <permissions> block (section ignored), the pattern only as fallback
#   - If permissions_file is empty/missing: uses first arg as perms_section (legacy)
#   - If section is empty: searches entire <permissions> block
#   - If section is set: searches only within that section
#     - "### Subsection Name" -> extracts until next ## or ### or </permissions>
#     - "## Section Name" -> extracts until next ## or </permissions> (includes ### subsections)
#   - A setting the file / section does not define is taken from the inherited block
#     (DOGMA_INHERIT_SECTION, set by load_permissions) when there is one.
get_permission_mode() {
    local arg1="$1"
    local arg2="${2:-}"
    local section="${3:-}"
    local perms_section=""
    local pattern=""
    local id_scope=""

    # Detect usage mode: new (pattern, file, section) vs legacy (perms_section, pattern)
    # If arg2 is a file path, use new mode
    if [ -n "$arg2" ] && [ -f "$arg2" ]; then
        # New mode: get_permission_mode(pattern, file, section)
        pattern="$arg1"
        id_scope=$(get_permissions_section "$arg2")
        if [ -n "$section" ]; then
            perms_section=$(perm_extract_section "$id_scope" "$section")
            dogma_debug_log "Extracted section '$section': $perms_section"
        else
            section=""
            perms_section="$id_scope"
        fi
    else
        # Legacy mode: get_permission_mode(perms_section, pattern)
        perms_section="$arg1"
        pattern="$arg2"
        id_scope="$perms_section"
        section=""
    fi

    local mode
    if mode=$(perm_lookup "$id_scope" "$pattern" "$perms_section"); then
        echo "$mode"
        return
    fi
    if [ "$id_scope" != "${DOGMA_INHERIT_SECTION:-}" ] && mode=$(perm_lookup_inherited "$pattern" "$section"); then
        dogma_debug_log "Permission inherited from ${DOGMA_INHERIT_FILE:-session folder}: $mode"
        echo "$mode"
        return
    fi

    dogma_debug_log "Permission not found: $pattern - auto by default"
    echo "auto"
}

# Get missing permissions message
get_missing_permissions_message() {
    cat <<'EOF'
DOGMA: No permissions file found.

Create DOGMA-PERMISSIONS.md in your project root to control Claude's autonomy.
Use /dogma:permissions to interactively create it, or create manually:

```markdown
# Dogma Permissions
<permissions>
- [x] (§6gpt) May run `git add` autonomously
- [x] (§2w1t) May run `git commit` autonomously
- [?] (§bww9) May run `git push` autonomously
- [ ] (§0lgy) May delete files autonomously (rm, unlink, git clean)
</permissions>
```

Checkbox states: [x]=auto, [?]=ask, [ ]=deny, [1]=one, [a]=all, [0]=deny
The (§xxxx) ids are stable; the text after them may be reworded freely.
EOF
}

# --- Shell-aware command findings (bash-guard.py) ------------------------------
# bash-guard.py normalises a Bash command like a shell (quoting, variables, wrappers,
# nested shells, substitutions, heredocs, cd tracking) and reports the deletes,
# package installs and git add/commit/push it contains, each with the directories it
# runs in. Hooks use these findings instead of text patterns when python3 exists.

# Print the findings JSON for a hook input; returns 1 (prints nothing) without python3
# or when the analysis failed (callers then fall back to their text patterns).
# Usage: dogma_bash_findings "$INPUT"
dogma_bash_findings() {
    command -v python3 >/dev/null 2>&1 || return 1
    local here out
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    out="$(printf '%s' "$1" | python3 -I "$here/bash-guard.py" --findings 2>/dev/null)" || return 1
    [ -n "$out" ] || return 1
    printf '%s\n' "$out"
}

# The deny reason when the analysis refused the command or ran out of time (prints
# nothing otherwise); quotes and backslashes are dropped so it fits the hook JSON.
# Without jq the findings cannot be read: any refusal or finding then denies (fail closed).
# Usage: dogma_findings_blocked "$FINDINGS"
dogma_findings_blocked() {
    if ! command -v jq >/dev/null 2>&1; then
        if printf '%s' "$1" | grep -qE '"blocked"|"label"|"op"|"installs": \["'; then
            echo "dogma: jq is missing, the command cannot be checked against the settings (fail closed)."
        fi
        return 0
    fi
    printf '%s' "$1" | jq -r '.blocked // empty' 2>/dev/null | tr -d '"\\' | tr '\n' ' ' | cut -c1-300
}

# Strictest mode of one setting over several directories (deny > ask > auto). An empty
# directory means "no explicit target": the default lookup applies (credo pinned
# project, current dir, session folder).
# Sets DOGMA_STRICT_MODE and DOGMA_STRICT_SRC (the defining file, empty when none).
# Usage: dogma_strictest_mode <spec> <mode when no file applies> <dir>...
dogma_strictest_mode() {
    local spec="$1" missing="$2" dir mode src rank best=-1
    shift 2
    DOGMA_STRICT_MODE="auto"
    DOGMA_STRICT_SRC=""
    for dir in "$@"; do
        if load_permissions "$dir"; then
            mode="$(get_permission_mode "$PERMS_SECTION" "$spec")"
            src="$(perm_defining_file "$spec")"
        else
            mode="$missing"
            src=""
        fi
        case "$mode" in
            deny) rank=2 ;;
            ask) rank=1 ;;
            *) rank=0; mode="auto" ;;
        esac
        if [ "$rank" -gt "$best" ]; then
            best="$rank"
            DOGMA_STRICT_MODE="$mode"
            DOGMA_STRICT_SRC="$src"
        fi
    done
}
