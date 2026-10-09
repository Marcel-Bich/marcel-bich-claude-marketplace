#!/bin/bash
# Tests for hooks/credo-peer-meta-record.sh - records a session's model, effort level
# and credo directory decision per session_id, so peers (credo-peer-check.py) can show
# them. Informational only: nothing here grants trust or permissions.
#
# Covered:
#   - SessionStart with model + effort.level -> both recorded
#   - UserPromptSubmit without model -> model taken from the last valid assistant
#     model in the transcript tail (a "<synthetic>" model is skipped)
#   - invalid model / effort values are never recorded (older valid values stay),
#     also when the field is missing; a transcript line cut by the tail read is skipped
#   - the credo directory decision of the session cwd is recorded as on / off
#   - subagent calls (agent_id set), bad session ids and the off toggle write nothing
#   - the hook prints nothing and always exits 0, also on garbage input
# Uses a throwaway config dir only (never the real ~/.claude).
#
# Usage: bash test-credo-peer-meta-record.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/../hooks/credo-peer-meta-record.sh"
DEC="$SCRIPT_DIR/credo-dir-decision.sh"
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not found"; exit 0; }
[ -f "$HOOK" ] || { echo "FAIL: $HOOK missing"; echo "passed: 0, failed: 1"; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/cpmr.XXXXXX")"
trap 'rm -rf -- "$TMP"' EXIT
CFG="$TMP/cfg"
mkdir -p "$CFG" "$TMP/work/proj-a" "$TMP/work/proj-b"
export CLAUDE_CONFIG_DIR="$CFG"
export CREDO_DIR_DECISIONS_DIR="$TMP/dec"
META="$CFG/credo/session-meta"

PASS=0
FAIL=0
check() { # name expected actual
    if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"; fi
}
field() { # sid key
    jq -r --arg k "$2" '.[$k] // "-"' "$META/$1.json" 2>/dev/null || echo "missing"
}
run() { # cwd json -> stdout of the hook
    (cd "$1" && printf '%s' "$2" | bash "$HOOK")
}

(cd "$TMP/work/proj-a" && bash "$DEC" set accepted >/dev/null)
(cd "$TMP/work/proj-b" && bash "$DEC" set declined >/dev/null)

OUT="$(run "$TMP/work/proj-a" '{"hook_event_name":"SessionStart","session_id":"sid-1","model":"claude-test-5","effort":{"level":"high"},"cwd":"'"$TMP"'/work/proj-a"}')"
check "hook prints nothing" "" "$OUT"
check "SessionStart records model" "claude-test-5" "$(field sid-1 model)"
check "SessionStart records effort" "high" "$(field sid-1 effort)"
check "credo decision accepted -> on" "on" "$(field sid-1 credo)"

# transcript: last valid assistant model wins, <synthetic> is skipped
TR="$TMP/tr.jsonl"
{
    printf '%s\n' '{"type":"assistant","message":{"model":"claude-old-1","content":[]}}'
    printf '%s\n' '{"type":"user","message":{"content":"\"model\":\"claude-fake-9\""}}'
    printf '%s\n' '{"type":"assistant","message":{"model":"claude-new-2","content":[]}}'
    printf '%s\n' '{"type":"assistant","message":{"model":"<synthetic>","content":[]}}'
} > "$TR"
run "$TMP/work/proj-a" '{"hook_event_name":"UserPromptSubmit","session_id":"sid-1","prompt":"x","transcript_path":"'"$TR"'","effort":{"level":"xhigh"}}' >/dev/null
check "prompt: model from the transcript tail" "claude-new-2" "$(field sid-1 model)"
check "prompt: effort updated" "xhigh" "$(field sid-1 effort)"

# invalid values are never recorded; a known valid model stays
printf '%s\n' '{"type":"assistant","message":{"model":"bad model;rm","content":[]}}' > "$TR"
run "$TMP/work/proj-a" '{"hook_event_name":"UserPromptSubmit","session_id":"sid-1","prompt":"x","transcript_path":"'"$TR"'","model":"evil<x>","effort":{"level":"ultra"}}' >/dev/null
check "invalid model ignored, previous model kept" "claude-new-2" "$(field sid-1 model)"
check "invalid effort not recorded, previous effort kept" "xhigh" "$(field sid-1 effort)"

# a prompt without an effort field keeps the last known effort
run "$TMP/work/proj-a" '{"hook_event_name":"UserPromptSubmit","session_id":"sid-1","prompt":"x","effort":{"level":"medium"}}' >/dev/null
run "$TMP/work/proj-a" '{"hook_event_name":"UserPromptSubmit","session_id":"sid-1","prompt":"x"}' >/dev/null
check "prompt without effort keeps the previous one" "medium" "$(field sid-1 effort)"

# a real transcript is longer than the tail read: the first line it returns is cut
# in the middle and must be skipped, not abort the parse
BIG="$(head -c 300000 /dev/zero | tr '\0' 'a')"
{
    printf '{"type":"assistant","message":{"model":"claude-cut-0","content":"%s"}}\n' "$BIG"
    printf '%s\n' '{"type":"assistant","message":{"model":"claude-tail-3","content":[]}}'
} > "$TMP/big.jsonl"
run "$TMP" '{"hook_event_name":"UserPromptSubmit","session_id":"sid-5","prompt":"x","transcript_path":"'"$TMP"'/big.jsonl"}' >/dev/null
check "cut first line of the transcript tail is skipped" "claude-tail-3" "$(field sid-5 model)"

# brackets only as one trailing context suffix
run "$TMP" '{"hook_event_name":"SessionStart","session_id":"sid-6","model":"x[urgent]"}' >/dev/null
check "marker-like brackets in a model are rejected" "-" "$(field sid-6 model)"

run "$TMP/work/proj-b" '{"hook_event_name":"SessionStart","session_id":"sid-2","model":"claude-test-5"}' >/dev/null
check "credo decision declined -> off" "off" "$(field sid-2 credo)"
run "$TMP" '{"hook_event_name":"SessionStart","session_id":"sid-3","model":"claude-test-5[1m]"}' >/dev/null
check "model with a context suffix is recorded" "claude-test-5[1m]" "$(field sid-3 model)"
check "no credo decision -> not recorded" "-" "$(field sid-3 credo)"

run "$TMP" '{"hook_event_name":"UserPromptSubmit","session_id":"sid-sub","agent_id":"a0123456789abcdef","model":"claude-test-5"}' >/dev/null
check "subagent call writes nothing" "no" "$([ -e "$META/sid-sub.json" ] && echo yes || echo no)"
run "$TMP" '{"hook_event_name":"SessionStart","session_id":"../evil","model":"claude-test-5"}' >/dev/null
check "bad session id writes nothing" "no" "$([ -e "$CFG/credo/evil.json" ] || [ -e "$META/../evil.json" ] && echo yes || echo no)"
OUT="$(cd "$TMP" && printf '{"hook_event_name":"SessionStart","session_id":"sid-off","model":"claude-test-5"}' | CREDO_PEER_META_RECORD=0 bash "$HOOK")"
check "toggle off writes nothing" "no" "$([ -e "$META/sid-off.json" ] && echo yes || echo no)"
printf 'not json' | bash "$HOOK" >/dev/null 2>&1
check "garbage input exits 0" "0" "$?"

# file stays a small JSON object with whitelisted keys only
check "record keys whitelisted" "ok" "$(jq -r 'if (keys - ["credo","effort","model","updatedAt"]) == [] then "ok" else keys | join(",") end' "$META/sid-1.json" 2>/dev/null)"

echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]
