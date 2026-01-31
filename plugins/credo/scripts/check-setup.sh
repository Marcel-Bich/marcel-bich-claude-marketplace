#!/bin/bash
# Credo Setup Check Script
# Runs all setup checks at once and outputs structured results

# System requirements check (git not checked - claude/plugins won't work without it anyway)
JQ_INSTALLED=$(command -v jq >/dev/null 2>&1 && echo "true" || echo "false")
CURL_INSTALLED=$(command -v curl >/dev/null 2>&1 && echo "true" || echo "false")

# Plugin checks
DOGMA_INSTALLED=$(claude plugin list 2>/dev/null | grep -q "dogma@marcel-bich-claude-marketplace" && echo "true" || echo "false")
GSD_INSTALLED=$(claude plugin list 2>/dev/null | grep -q "get-shit-done@marcel-bich-claude-marketplace" && echo "true" || echo "false")

# Directory checks
CLAUDE_EXISTS=$([ -d "CLAUDE" ] && echo "true" || echo "false")
PLANNING_EXISTS=$([ -d ".planning" ] && echo "true" || echo "false")
CODEBASE_MAPPED=$([ -d ".planning/codebase" ] && echo "true" || echo "false")
ROADMAP_EXISTS=$([ -f ".planning/ROADMAP.md" ] && echo "true" || echo "false")
LANGUAGE_EXISTS=$([ -f "CLAUDE/CLAUDE.language.md" ] && echo "true" || echo "false")

# Git check
GIT_INIT=$(git rev-parse --is-inside-work-tree >/dev/null 2>&1 && echo "true" || echo "false")

# Code detection
HAS_CODE=$(find . -maxdepth 2 -type f \( -name "*.ts" -o -name "*.js" -o -name "*.py" -o -name "*.go" -o -name "*.rs" -o -name "*.java" -o -name "*.c" -o -name "*.cpp" \) 2>/dev/null | head -1 | grep -q . && echo "true" || echo "false")

# File checks
PROJECT_MD_EXISTS=$([ -f ".planning/PROJECT.md" ] && echo "true" || echo "false")

# File count for greenfield detection
FILE_COUNT=$(find . -maxdepth 2 -type f ! -path "./.git/*" 2>/dev/null | head -10 | wc -l)

# Greenfield detection
IS_GREENFIELD="false"
if [ "$FILE_COUNT" -eq 0 ] || [ "$GIT_INIT" = "false" ]; then
    IS_GREENFIELD="true"
fi

# Project state summary
PROJECT_STATE="unknown"
if [ "$CLAUDE_EXISTS" = "false" ]; then
    PROJECT_STATE="needs_setup"
elif [ "$PROJECT_MD_EXISTS" = "false" ] && [ "$CODEBASE_MAPPED" = "false" ]; then
    # Neither PROJECT.md nor codebase map exists
    if [ "$HAS_CODE" = "true" ]; then
        PROJECT_STATE="needs_mapping"
    else
        PROJECT_STATE="needs_project"
    fi
elif [ "$ROADMAP_EXISTS" = "false" ]; then
    PROJECT_STATE="needs_roadmap"
else
    PROJECT_STATE="ready"
fi

# Build missing requirements warnings
MISSING_WARNINGS=""
if [ "$JQ_INSTALLED" = "false" ]; then
    MISSING_WARNINGS="${MISSING_WARNINGS}  - jq: dogma, limit, signal (install: sudo apt install jq)\n"
fi
if [ "$CURL_INSTALLED" = "false" ]; then
    MISSING_WARNINGS="${MISSING_WARNINGS}  - curl: limit (install: sudo apt install curl)\n"
fi

# Output structured results
cat <<EOF
CREDO_SETUP_CHECK_V1
====================
system_requirements:
  jq: $JQ_INSTALLED
  curl: $CURL_INSTALLED
plugins:
  dogma: $DOGMA_INSTALLED
  gsd: $GSD_INSTALLED
directories:
  claude: $CLAUDE_EXISTS
  planning: $PLANNING_EXISTS
  codebase_map: $CODEBASE_MAPPED
  language_config: $LANGUAGE_EXISTS
files:
  project_md: $PROJECT_MD_EXISTS
  roadmap: $ROADMAP_EXISTS
project:
  git_init: $GIT_INIT
  has_code: $HAS_CODE
  file_count: $FILE_COUNT
  is_greenfield: $IS_GREENFIELD
  state: $PROJECT_STATE
EOF

# Output warnings for missing requirements
if [ -n "$MISSING_WARNINGS" ]; then
    echo "missing_requirements:"
    echo -e "$MISSING_WARNINGS"
fi
