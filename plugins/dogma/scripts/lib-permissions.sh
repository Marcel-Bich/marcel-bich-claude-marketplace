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

# Check if permission is granted
# Returns 0 (true) if allowed, 1 (false) if blocked
# If pattern not found, returns 0 (allow by default)
check_permission() {
    local perms_section="$1"
    local pattern="$2"

    if [ -z "$perms_section" ]; then
        dogma_debug_log "No permissions section - allowing by default"
        return 0  # Allow by default if no permissions section
    fi

    # Check for [x] (allowed)
    if echo "$perms_section" | grep -qE "^\s*-\s*\[x\].*$pattern"; then
        dogma_debug_log "Permission granted for: $pattern"
        return 0  # Allowed
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

# Get missing permissions message
get_missing_permissions_message() {
    cat <<'EOF'
DOGMA: No permissions file found.

Create DOGMA-PERMISSIONS.md in your project root to control Claude's autonomy.
Use /dogma:permissions to interactively create it, or create manually:

```markdown
# Dogma Permissions
<permissions>
- [x] May run `git add` autonomously
- [x] May run `git commit` autonomously
- [ ] May run `git push` autonomously
- [ ] May delete files autonomously (rm, unlink, git clean)
</permissions>
```

Mark [x] to allow, [ ] to block.
EOF
}
