#!/usr/bin/env bash
# subagent-tokens.sh - Compatibility wrapper around usage-ledger.sh.
#
# Until v2.35 this file kept two separate scanners (main agent and subagents)
# that summed every JSONL line. Claude Code repeats message.usage on each
# content-block line, so those totals were ~2.3x too high, and cache reads were
# counted 1:1. Counting now lives in usage-ledger.sh (deduplicated by
# message.id + requestId, one ledger for main and subagents). The functions
# below keep their old names for scripts that still call them; tokens are work
# tokens (input + output + cache writes, cache reads excluded).
# The old state files (limit-subagent-state_*.json, limit-main-agent-state_*.json)
# are no longer read or written.
# shellcheck disable=SC2250

_SAT_DIR="${BASH_SOURCE[0]%/*}"
[[ "$_SAT_DIR" == "${BASH_SOURCE[0]}" ]] && _SAT_DIR="."
# shellcheck source=usage-ledger.sh
source "${_SAT_DIR}/usage-ledger.sh"

_sat_field() {
    ledger_scan_all >/dev/null 2>&1 || true
    local sum
    sum=$(ledger_summary "" 0 0) || { echo "0"; return 1; }
    printf '%s' "$sum" | jq -r ".lifetime.$1"
}

get_main_agent_tokens() { _sat_field main_tokens; }
get_subagent_tokens() { _sat_field sub_tokens; }
get_main_agent_cost() { _sat_field main_cost; }
get_subagent_cost() { _sat_field sub_cost; }

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-}" in
        get) echo "Total subagent tokens: $(get_subagent_tokens)" ;;
        main) echo "Total main agent tokens: $(get_main_agent_tokens)" ;;
        cost) echo "Subagent cost: \$$(get_subagent_cost)  Main agent cost: \$$(get_main_agent_cost)" ;;
        *) echo "Usage: $0 <get|main|cost>  (see usage-ledger.sh for the full CLI)" ;;
    esac
fi
