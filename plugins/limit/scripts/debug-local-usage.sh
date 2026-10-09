#!/bin/bash
# debug-local-usage.sh - Show the local accounting state (read-only).
# Ledger (deduplicated JSONL token counts), window tracking, highscores and
# the Est100% samples. Changes nothing.

set -uo pipefail

CLAUDE_BASE_DIR="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}"
PROFILE_NAME=$(basename "${CLAUDE_BASE_DIR}")
PLUGIN_DATA_DIR="${PLUGIN_DATA_DIR:-${CLAUDE_BASE_DIR}/marcel-bich-claude-marketplace/limit}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACHE_FILE="/tmp/claude-mb-limit-cache_${PROFILE_NAME}.json"

# shellcheck source=usage-ledger.sh
source "${SCRIPT_DIR}/usage-ledger.sh"
# shellcheck source=highscore-state.sh
source "${SCRIPT_DIR}/highscore-state.sh"

echo "=== limit: local accounting debug (profile ${PROFILE_NAME}) ==="
echo ""
echo "Device label: ${CLAUDE_MB_LIMIT_DEVICE_LABEL:-$(hostname) (hostname, CLAUDE_MB_LIMIT_DEVICE_LABEL not set)}"
echo "Debug logging: $(limit_debug_enabled && echo on || echo off)"
echo ""

echo "1. Ledger: ${LEDGER_FILE}"
if [[ -f "$LEDGER_FILE" ]]; then
    jq '{schema_version, last_scan: (.last_scan | todate? // .), files: (.files | length),
         pending_files: ([.files[] | select(.p == 1)] | length),
         backfill_complete: ((.last_scan // 0) > 0 and ([.files[] | select(.p == 1)] | length) == 0),
         buckets: (.buckets | length), lifetime_models: (.lifetime | map_values(keys))}' "$LEDGER_FILE" 2>/dev/null \
        || echo "   unreadable"
    echo "   lifetime (work tokens, cost USD, unpriced models): $(ledger_lifetime 2>/dev/null || echo unreadable)"
else
    echo "   not created yet"
fi
echo ""

echo "2. Window tracking / highscores / Est100%: ${HIGHSCORE_STATE_FILE}"
if [[ -f "$HIGHSCORE_STATE_FILE" ]]; then
    jq '{schema_version, plan, highscores, windows,
         est: (.est | map_values({id, prev, samples: (.samples | length)}))}' "$HIGHSCORE_STATE_FILE" 2>/dev/null \
        || echo "   unreadable"
else
    echo "   not created yet"
fi
echo ""

echo "3. API cache: ${CACHE_FILE}"
if [[ -f "$CACHE_FILE" ]]; then
    jq '{five_hour: .five_hour | {utilization, resets_at}, seven_day: .seven_day | {utilization, resets_at},
         limits: [.limits[]? | {kind, percent, model: .scope.model.display_name}]}' "$CACHE_FILE" 2>/dev/null \
        || echo "   unreadable"
else
    echo "   not present"
fi
