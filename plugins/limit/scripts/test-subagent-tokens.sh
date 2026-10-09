#!/usr/bin/env bash
# test-subagent-tokens.sh - The compatibility wrapper reports deduplicated
# ledger totals split into main agent and subagents. Temp dir only.
# shellcheck disable=SC2250

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
export HOME="$TEST_DIR/home"
# Fake profile name (never ".claude"): debug logs and caches are keyed by it.
export CLAUDE_CONFIG_DIR="$TEST_DIR/home/limit-test-$$"
export CLAUDE_MB_LIMIT_DEBUG=false
export PLUGIN_DATA_DIR="$TEST_DIR/data"
PROJ="$CLAUDE_CONFIG_DIR/projects/-home-myuser-acme"
mkdir -p "$PROJ/s1/subagents" "$PLUGIN_DATA_DIR"

PASS=0
FAIL=0
check() {
    if [[ "$2" == "$3" ]]; then PASS=$((PASS + 1)); echo "  PASS: $1"
    else FAIL=$((FAIL + 1)); echo "  FAIL: $1 (expected '$2', got '$3')"; fi
}

line() { # id model in out
    jq -cn --arg id "$1" --arg m "$2" --argjson i "$3" --argjson o "$4" \
        '{type:"assistant", requestId:("r" + $id), timestamp:"2026-01-01T10:00:00.000Z",
          message:{id:$id, model:$m, usage:{input_tokens:$i, output_tokens:$o, cache_read_input_tokens:500}}}'
}
{ line m1 claude-opus-5-5 10 20; line m1 claude-opus-5-5 10 20; } > "$PROJ/s1.jsonl"
{ line a1 claude-haiku-4-5 3 4; line a1 claude-haiku-4-5 3 4; line a2 claude-haiku-4-5 1 1; } > "$PROJ/s1/subagents/agent-x.jsonl"

# shellcheck source=subagent-tokens.sh
source "$SCRIPT_DIR/subagent-tokens.sh"

echo ">>> compatibility wrapper"
check "main agent tokens deduplicated, cache reads excluded" "30" "$(get_main_agent_tokens)"
check "subagent tokens deduplicated" "9" "$(get_subagent_tokens)"
check "main agent cost (opus-5-5: 10*4 + 20*20 + 500*0.2 per MTok)" "0.00054" "$(get_main_agent_cost)"

echo ""
echo "passed: $PASS failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
