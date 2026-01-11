#!/bin/bash
# Dogma: Version Sync Check (Stop Hook)
# Runs at the END of Claude's response
#
# Mode 1: If CLAUDE.versioning.md exists, use project-specific config
# Mode 2: If not, scan for common version files and help generically
# Mode 3: If no version files found at all, skip silently
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

# === HELPER: Extract version from file ===
extract_version() {
    local FILE="$1"
    local EXT="${FILE##*.}"
    local VERSION=""

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
        py)
            # setup.py or __version__ in Python files
            VERSION=$(grep -E "^__version__|version\s*=" "$FILE" 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' || echo "")
            ;;
        txt)
            # version.txt - just the version string
            VERSION=$(head -1 "$FILE" 2>/dev/null | tr -d ' \n' || echo "")
            ;;
    esac

    echo "$VERSION"
}

# === MODE 1: Check CLAUDE.versioning.md ===
VERSION_FILE=""
if [ -f "CLAUDE/CLAUDE.versioning.md" ]; then
    VERSION_FILE="CLAUDE/CLAUDE.versioning.md"
elif [ -f "CLAUDE.versioning.md" ]; then
    VERSION_FILE="CLAUDE.versioning.md"
elif [ -f ".claude/CLAUDE.versioning.md" ]; then
    VERSION_FILE=".claude/CLAUDE.versioning.md"
fi

if [ -n "$VERSION_FILE" ]; then
    # Extract version file paths from CLAUDE.versioning.md
    VERSION_FILES=$(grep -oE '`[^`]+\.(yaml|json|toml|py|txt)`' "$VERSION_FILE" 2>/dev/null | tr -d '`' | sort -u || true)

    if [ -n "$VERSION_FILES" ]; then
        VERSIONS=""
        FILES_CHECKED=""

        for FILE in $VERSION_FILES; do
            if [ ! -f "$FILE" ]; then
                continue
            fi
            VERSION=$(extract_version "$FILE")
            if [ -n "$VERSION" ]; then
                VERSIONS="${VERSIONS}${VERSION}\n"
                FILES_CHECKED="${FILES_CHECKED}\n- $FILE: $VERSION"
            fi
        done

        if [ -n "$VERSIONS" ]; then
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
        fi
        exit 0
    fi
fi

# === MODE 2: Generic fallback - scan common version files ===
COMMON_FILES="package.json pyproject.toml Cargo.toml setup.py version.txt VERSION.txt VERSION"
FOUND_FILES=""
VERSIONS=""
FILES_CHECKED=""

for FILE in $COMMON_FILES; do
    if [ -f "$FILE" ]; then
        VERSION=$(extract_version "$FILE")
        if [ -n "$VERSION" ]; then
            FOUND_FILES="${FOUND_FILES} $FILE"
            VERSIONS="${VERSIONS}${VERSION}\n"
            FILES_CHECKED="${FILES_CHECKED}\n- $FILE: $VERSION"
        fi
    fi
done

# Also check for plugin structures
if [ -d "plugins" ]; then
    for PLUGIN_DIR in plugins/*/; do
        if [ -d "$PLUGIN_DIR" ]; then
            for VFILE in plugin.yaml plugin.json .claude-plugin/plugin.json; do
                if [ -f "${PLUGIN_DIR}${VFILE}" ]; then
                    VERSION=$(extract_version "${PLUGIN_DIR}${VFILE}")
                    if [ -n "$VERSION" ]; then
                        FOUND_FILES="${FOUND_FILES} ${PLUGIN_DIR}${VFILE}"
                        VERSIONS="${VERSIONS}${VERSION}\n"
                        FILES_CHECKED="${FILES_CHECKED}\n- ${PLUGIN_DIR}${VFILE}: $VERSION"
                    fi
                fi
            done
        fi
    done
fi

# === MODE 3: No version files found - skip silently ===
if [ -z "$FOUND_FILES" ]; then
    exit 0
fi

# Check for mismatches
UNIQUE_VERSIONS=$(echo -e "$VERSIONS" | sort -u | grep -v '^$')
UNIQUE_COUNT=$(echo "$UNIQUE_VERSIONS" | wc -l)

if [ "$UNIQUE_COUNT" -gt 1 ]; then
    echo ""
    echo "<dogma-version-warning>"
    echo "VERSION MISMATCH DETECTED!"
    echo ""
    echo "Files with different versions:"
    echo -e "$FILES_CHECKED"
    echo ""
    echo "Tip: Keep all version files in sync."
    echo "Consider creating CLAUDE/CLAUDE.versioning.md to define version rules."
    echo "</dogma-version-warning>"
    exit 0
fi

# Check if version was never bumped (still at initial/default)
CURRENT_VERSION=$(echo "$UNIQUE_VERSIONS" | head -1)
case "$CURRENT_VERSION" in
    "0.0.0"|"0.0.1"|"0.1.0"|"1.0.0"|"")
        # Likely never bumped - but only mention if there are multiple files
        FILE_COUNT=$(echo "$FOUND_FILES" | wc -w)
        if [ "$FILE_COUNT" -gt 1 ]; then
            echo ""
            echo "<dogma-version-hint>"
            echo "Version files found (all at $CURRENT_VERSION):"
            echo -e "$FILES_CHECKED"
            echo ""
            echo "If you made changes, consider bumping the version."
            echo "Common formats:"
            echo "- Semantic: major.minor.patch (e.g., 1.2.3)"
            echo "- Date-based: YYYY.MM.DD (e.g., 2026.01.11)"
            echo ""
            echo "Create CLAUDE/CLAUDE.versioning.md to define your versioning rules."
            echo "</dogma-version-hint>"
        fi
        ;;
esac

exit 0
