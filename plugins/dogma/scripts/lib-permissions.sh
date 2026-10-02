#!/bin/bash
# Dogma: Shared Permissions Library
# Used by git-permissions.sh and file-protection.sh
#
# Searches for DOGMA-PERMISSIONS.md in project root (upward search)
# If not found, returns empty (allow by default)
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

# Find permissions file (returns path or empty)
find_permissions_file() {
    local dir="$PWD"

    # Search upward from current directory
    while [ "$dir" != "/" ]; do
        if [ -f "$dir/DOGMA-PERMISSIONS.md" ]; then
            dogma_debug_log "Found permissions: $dir/DOGMA-PERMISSIONS.md"
            echo "$dir/DOGMA-PERMISSIONS.md"
            return 0
        fi
        dir=$(dirname "$dir")
    done

    dogma_debug_log "No DOGMA-PERMISSIONS.md found"
    return 1
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
perm_is_checked() {
    local content="$1" id="$2" regex="$3"
    local state
    if state=$(perm_state_by_id "$content" "$id"); then
        [ "$state" = "x" ]
        return
    fi
    [ -n "$regex" ] || return 1
    printf '%s\n' "$content" | grep -qiE "^[[:space:]]*-[[:space:]]*\[x\].*$regex"
}

# Does the content have the heading of a parsed section?
# Usage: perm_has_heading <content> <id> <heading_text>
# Id first (any heading level ## or deeper carrying "(§id)"), else "### <heading_text>"
# matched case-insensitively (an optional trailing id is allowed).
perm_has_heading() {
    local content="$1" id="$2" text="$3"
    if [ -n "$id" ] && printf '%s\n' "$content" | grep -qE "^[[:space:]]*##+[[:space:]].*\(§${id}\)"; then
        return 0
    fi
    printf '%s\n' "$content" | grep -qiE "^[[:space:]]*###[[:space:]]+${text}[[:space:]]*(\(§[0-9a-z]{4}\))?[[:space:]]*$"
}

# Check if permission is granted (legacy - use get_permission_mode for 3-state)
# Returns 0 (true) if allowed, 1 (false) if blocked
# If pattern not found, returns 0 (allow by default)
# pattern may be a spec "§xxxx|pattern" (id first, see above)
check_permission() {
    local perms_section="$1"
    local pattern="$2"

    if [ -z "$perms_section" ]; then
        dogma_debug_log "No permissions section - allowing by default"
        return 0  # Allow by default if no permissions section
    fi

    # Id first, then the text pattern
    perm_split_spec "$pattern"
    pattern="$PERM_SPEC_PATTERN"
    local id_state
    if id_state=$(perm_state_by_id "$perms_section" "$PERM_SPEC_ID"); then
        dogma_debug_log "Permission by id $PERM_SPEC_ID: [$id_state]"
        case "$id_state" in
            " "|0) return 1 ;;
            *) return 0 ;;
        esac
    fi
    if [ -z "$pattern" ]; then
        dogma_debug_log "Id $PERM_SPEC_ID not found, no fallback pattern - allowing by default"
        return 0
    fi

    # Check for [x] (allowed)
    if echo "$perms_section" | grep -qE "^\s*-\s*\[x\].*$pattern"; then
        dogma_debug_log "Permission granted for: $pattern"
        return 0  # Allowed
    fi

    # Check for [?] (ask) - treat as allowed for legacy compatibility
    if echo "$perms_section" | grep -qE "^\s*-\s*\[\?\].*$pattern"; then
        dogma_debug_log "Permission ask mode for: $pattern"
        return 0  # Allowed (caller should use get_permission_mode instead)
    fi

    # Check for [ ] (blocked)
    if echo "$perms_section" | grep -qE "^\s*-\s*\[ \].*$pattern"; then
        dogma_debug_log "Permission denied for: $pattern"
        return 1  # Blocked
    fi

    # Pattern not found - allow by default
    dogma_debug_log "Permission pattern not found: $pattern - allowing by default"
    return 0
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
        local permissions_file="$arg2"
        id_scope=$(sed -n '/<permissions>/,/<\/permissions>/p' "$permissions_file" 2>/dev/null)

        if [ -n "$section" ]; then
            # Get the entire permissions block first
            local full_perms
            full_perms=$(sed -n '/<permissions>/,/<\/permissions>/p' "$permissions_file" 2>/dev/null)

            # Try to find as ### Subsection first
            # Subsection starts with "### Section Name" and ends at next ## or ### or </permissions>
            perms_section=$(echo "$full_perms" | \
                sed -n "/^### $section\$/,/^##/p" | \
                sed '1d' | \
                sed '/^##/d')

            # If not found as subsection, try as ## Section
            if [ -z "$perms_section" ]; then
                # Section starts with "## Section Name" and ends at next "##" or "</permissions>"
                # This includes all ### subsections within it
                perms_section=$(echo "$full_perms" | \
                    sed -n "/^## $section\$/,/^## [^#]/p" | \
                    sed '1d' | \
                    sed '/^## [^#]/d')

                # If still empty, section might be last one (no following ##)
                if [ -z "$perms_section" ]; then
                    perms_section=$(echo "$full_perms" | \
                        sed -n "/^## $section\$/,/<\/permissions>/p" | \
                        sed '1d' | \
                        sed '/<\/permissions>/d')
                fi
            fi
            dogma_debug_log "Extracted section '$section': $perms_section"
        else
            # No section - search entire permissions block
            perms_section=$(sed -n '/<permissions>/,/<\/permissions>/p' "$permissions_file" 2>/dev/null)
        fi
    else
        # Legacy mode: get_permission_mode(perms_section, pattern)
        perms_section="$arg1"
        pattern="$arg2"
        id_scope="$perms_section"
    fi

    # Id first ("§xxxx|pattern"): anywhere in the block, regardless of section
    perm_split_spec "$pattern"
    pattern="$PERM_SPEC_PATTERN"
    local id_state
    if id_state=$(perm_state_by_id "$id_scope" "$PERM_SPEC_ID"); then
        dogma_debug_log "Permission by id $PERM_SPEC_ID: [$id_state]"
        perm_state_to_mode "$id_state"
        return
    fi

    if [ -z "$perms_section" ]; then
        dogma_debug_log "No permissions section - auto by default"
        echo "auto"
        return
    fi

    if [ -z "$pattern" ]; then
        dogma_debug_log "Id $PERM_SPEC_ID not found, no fallback pattern - auto by default"
        echo "auto"
        return
    fi

    # Check for [x] (auto)
    if echo "$perms_section" | grep -qE "^\s*-\s*\[x\].*$pattern"; then
        dogma_debug_log "Permission mode auto for: $pattern"
        echo "auto"
        return
    fi

    # Check for [?] (ask)
    if echo "$perms_section" | grep -qE "^\s*-\s*\[\?\].*$pattern"; then
        dogma_debug_log "Permission mode ask for: $pattern"
        echo "ask"
        return
    fi

    # Check for [ ] (deny)
    if echo "$perms_section" | grep -qE "^\s*-\s*\[ \].*$pattern"; then
        dogma_debug_log "Permission mode deny for: $pattern"
        echo "deny"
        return
    fi

    # Check for [1] (one - only one at a time)
    if echo "$perms_section" | grep -qE "^\s*-\s*\[1\].*$pattern"; then
        dogma_debug_log "Permission mode one for: $pattern"
        echo "one"
        return
    fi

    # Check for [a] (all - everything, not just relevant)
    if echo "$perms_section" | grep -qE "^\s*-\s*\[a\].*$pattern"; then
        dogma_debug_log "Permission mode all for: $pattern"
        echo "all"
        return
    fi

    # Check for [0] (deny - same as [ ])
    if echo "$perms_section" | grep -qE "^\s*-\s*\[0\].*$pattern"; then
        dogma_debug_log "Permission mode deny for: $pattern"
        echo "deny"
        return
    fi

    # Pattern not found - auto by default
    dogma_debug_log "Permission pattern not found: $pattern - auto by default"
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
