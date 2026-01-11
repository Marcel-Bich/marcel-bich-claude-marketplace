#!/bin/bash
# Dogma: Version Sync Check (Stop Hook)
# Runs at the END of Claude's response
# Checks if versions are in sync based on CLAUDE.versioning.md rules
#
# Reads <marketplace_sync> or similar sections from CLAUDE.versioning.md
# to determine which files should have matching versions.
#
# If no CLAUDE.versioning.md exists, does nothing (project-specific config required)
#
# ENV: DOGMA_ENABLED=true (default) | false - master switch
# ENV: DOGMA_VERSION_SYNC=true (default) | false

trap 'exit 0' ERR

# === DEBUG MODE ===
DEBUG="${DOGMA_DEBUG:-false}"
if [ "$DEBUG" = "true" ]; then
    exec 2>>/tmp/dogma-hooks.log
    set -x
    echo "=== version-sync-check.sh START $(date) ===" >&2
fi

# === MASTER SWITCH ===
if [ "${DOGMA_ENABLED:-true}" != "true" ]; then
    exit 0
fi

# === CONFIGURATION ===
ENABLED="${DOGMA_VERSION_SYNC:-true}"
if [ "$ENABLED" != "true" ]; then
    exit 0
fi

# Read JSON input from stdin
INPUT=$(cat 2>/dev/null || true)

# Find CLAUDE.versioning.md
VERSION_FILE=""
if [ -f "CLAUDE/CLAUDE.versioning.md" ]; then
    VERSION_FILE="CLAUDE/CLAUDE.versioning.md"
elif [ -f "CLAUDE.versioning.md" ]; then
    VERSION_FILE="CLAUDE.versioning.md"
elif [ -f ".claude/CLAUDE.versioning.md" ]; then
    VERSION_FILE=".claude/CLAUDE.versioning.md"
fi

# If no versioning file, skip (project-specific config required)
if [ -z "$VERSION_FILE" ]; then
    exit 0
fi

# Extract version file paths from CLAUDE.versioning.md
# Look for patterns like: - `path/to/file` or `path/to/file` (version field)
VERSION_FILES=$(grep -oE '`[^`]+\.(yaml|json|toml|xml|txt)`' "$VERSION_FILE" 2>/dev/null | tr -d '`' | sort -u || true)

if [ -z "$VERSION_FILES" ]; then
    exit 0
fi

# Collect versions from each file
VERSIONS=""
FILES_CHECKED=""

for FILE in $VERSION_FILES; do
    if [ ! -f "$FILE" ]; then
        continue
    fi

    EXT="${FILE##*.}"
    VERSION=""

    case "$EXT" in
        yaml|yml)
            VERSION=$(grep -E '^version:' "$FILE" 2>/dev/null | head -1 | sed 's/version:\s*//' | tr -d ' "'"'" || echo "")
            ;;
        json)
            VERSION=$(jq -r '.version // empty' "$FILE" 2>/dev/null || echo "")
            ;;
        toml)
            VERSION=$(grep -E '^version\s*=' "$FILE" 2>/dev/null | head -1 | sed 's/version\s*=\s*//' | tr -d ' "'"'" || echo "")
            ;;
    esac

    if [ -n "$VERSION" ]; then
        VERSIONS="${VERSIONS}${VERSION}\n"
        FILES_CHECKED="${FILES_CHECKED}\n- $FILE: $VERSION"
    fi
done

# Check if all versions are the same
if [ -z "$VERSIONS" ]; then
    exit 0
fi

UNIQUE_VERSIONS=$(echo -e "$VERSIONS" | sort -u | grep -v '^$' | wc -l)

if [ "$UNIQUE_VERSIONS" -gt 1 ]; then
    echo ""
    echo "<dogma-version-warning>"
    echo "VERSION MISMATCH DETECTED!"
    echo ""
    echo "Files with different versions:"
    echo -e "$FILES_CHECKED"
    echo ""
    echo "All version files should have the same version."
    echo "See @${VERSION_FILE}"
    echo "</dogma-version-warning>"
fi

exit 0
