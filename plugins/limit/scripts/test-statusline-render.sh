#!/usr/bin/env bash
# test-statusline-render.sh - End-to-end render of usage-statusline.sh against
# fixtures: fake profile, fake usage cache, fake JSONL transcripts. No network:
# the fake profile has no credentials, so any background refresh stops before
# the API. The real profile's cache and state files are never touched.
# shellcheck disable=SC2250

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR=$(mktemp -d)
FAKE_PROFILE="limit-render-$$-${RANDOM}"
SID="render-session-$$"
export HOME="$TEST_DIR/home"
export CLAUDE_CONFIG_DIR="$TEST_DIR/home/$FAKE_PROFILE"
export CLAUDE_MB_LIMIT_DEBUG=false
DATA_DIR="$CLAUDE_CONFIG_DIR/marcel-bich-claude-marketplace/limit"
PROJ="$CLAUDE_CONFIG_DIR/projects/-home-myuser-acme"
mkdir -p "$PROJ/$SID/subagents" "$DATA_DIR"
CACHE="/tmp/claude-mb-limit-cache_${FAKE_PROFILE}.json"
cleanup() {
    rm -rf "$TEST_DIR"
    rm -f "$CACHE" "/tmp/claude-mb-limit-refresh-status_${FAKE_PROFILE}" \
        "/tmp/claude-mb-limit-refresh_${FAKE_PROFILE}.lock" \
        "/tmp/claude-mb-context-cache_${SID}.json" "/tmp/claude-mb-limit-caption-${SID}" \
        "/tmp/claude-mb-limit-debug_${FAKE_PROFILE}.log" 2>/dev/null
}
trap cleanup EXIT

export CLAUDE_MB_LIMIT_GIT=false
export CLAUDE_MB_LIMIT_COLORS=false
export CLAUDE_MB_LIMIT_CAPTION=false
export CLAUDE_MB_LIMIT_DEVICE_LABEL=box-1
export CLAUDE_MB_LIMIT_SESSION_SCAN=0
export CLAUDE_MB_LIMIT_SCAN_SYNC=1

PASS=0
FAIL=0
has() { if grep -qF -- "$2" <<< "$3"; then PASS=$((PASS + 1)); echo "  PASS: $1"; else FAIL=$((FAIL + 1)); echo "  FAIL: $1 (missing '$2')"; printf '%s\n' "$3" | sed 's/^/        | /'; fi; }
hasre() { if grep -qE -- "$2" <<< "$3"; then PASS=$((PASS + 1)); echo "  PASS: $1"; else FAIL=$((FAIL + 1)); echo "  FAIL: $1 (no match for /$2/)"; fi; }
hasnt() { if grep -qF -- "$2" <<< "$3"; then FAIL=$((FAIL + 1)); echo "  FAIL: $1 (unexpected '$2')"; else PASS=$((PASS + 1)); echo "  PASS: $1"; fi; }

NOW=$(date -u +%s)
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%S.000000+00:00; }
TS=$(date -u -d "@$((NOW - 300))" +%Y-%m-%dT%H:%M:%S.000Z)
line() { # id model in out cr cw
    jq -cn --arg id "$1" --arg m "$2" --arg ts "$TS" --argjson i "$3" --argjson o "$4" --argjson cr "$5" --argjson cw "$6" \
        '{type:"assistant", requestId:("r" + $id), timestamp:$ts,
          message:{id:$id, model:$m, content:[{type:"text"}],
                   usage:{input_tokens:$i, output_tokens:$o, cache_read_input_tokens:$cr, cache_creation_input_tokens:$cw}}}'
}
TRANSCRIPT="$PROJ/$SID.jsonl"
# 3 content-block lines of one message: counted once
{ line m1 claude-opus-5-5 1000 400000 9000000 99000; line m1 claude-opus-5-5 1000 400000 9000000 99000; line m1 claude-opus-5-5 1000 400000 9000000 99000; } > "$TRANSCRIPT"
line a1 claude-haiku-4-5 100000 400000 0 0 > "$PROJ/$SID/subagents/agent-a1.jsonl"
# session work tokens: 1000 + 400000 + 99000 + 100000 + 400000 = 1,000,000

write_cache() { # five_util five_reset seven_util
    jq -n --argjson f "$1" --arg fr "$2" --argjson s "$3" --arg sr "$(iso $((NOW + 3 * 86400)))" '{
        five_hour: {utilization: $f, resets_at: $fr},
        seven_day: {utilization: $s, resets_at: $sr},
        seven_day_opus: null, seven_day_sonnet: null,
        limits: [
          {kind: "session", group: "session", percent: $f, resets_at: $fr, scope: null},
          {kind: "weekly_all", group: "weekly", percent: $s, resets_at: $sr, scope: null},
          {kind: "weekly_scoped", group: "weekly", percent: 12, resets_at: $sr,
           scope: {model: {id: null, display_name: "Fable"}, surface: null}}
        ]}' > "$CACHE"
}
STDIN=$(jq -cn --arg sid "$SID" --arg tp "$TRANSCRIPT" --arg cwd "$TEST_DIR" '{
    session_id: $sid, transcript_path: $tp, cwd: $cwd,
    model: {id: "claude-opus-5-5", display_name: "Opus 5.5"},
    context_window: {total_input_tokens: 9100000, total_output_tokens: 400000, context_window_size: 1000000,
                     current_usage: {input_tokens: 1000, cache_read_input_tokens: 90000, cache_creation_input_tokens: 9000}},
    cost: {total_cost_usd: 1.5, total_duration_ms: 60000, total_api_duration_ms: 30000}}')
render() { printf '%s\n' "$STDIN" | bash "$SCRIPT_DIR/usage-statusline.sh" 2>&1; }

HS_STATE="$DATA_DIR/limit-highscore-state_${FAKE_PROFILE}.json"
LEDGER="$DATA_DIR/limit-ledger_${FAKE_PROFILE}.json"
est_samples() { jq -r --arg w "$1" '(.est[$w].samples // []) | length' "$HS_STATE" 2>/dev/null || echo 0; }

echo ">>> first render after an upgrade: bounded inline scan, no estimate samples while the backfill runs"
write_cache 50 "$(iso $((NOW + 7200)))" 30
TRANSCRIPT_SIZE=$(stat -c %s "$TRANSCRIPT")
out=$(CLAUDE_MB_LIMIT_SESSION_SCAN_BYTES=200 CLAUDE_MB_LIMIT_SCAN_BYTES=200 render)
off=$(jq -r --arg p "$TRANSCRIPT" '.files[$p].b // 0' "$LEDGER")
if [[ "$off" -gt 0 && "$off" -lt "$TRANSCRIPT_SIZE" ]]; then PASS=$((PASS + 1)); echo "  PASS: inline scan stops at its byte budget ($off of $TRANSCRIPT_SIZE bytes)"; else FAIL=$((FAIL + 1)); echo "  FAIL: inline scan read $off of $TRANSCRIPT_SIZE bytes"; fi
hasnt "no Est100% from an incomplete backfill" "Est100%" "$out"
has_n() { if [[ "$2" == "$3" ]]; then PASS=$((PASS + 1)); echo "  PASS: $1"; else FAIL=$((FAIL + 1)); echo "  FAIL: $1 (expected '$2', got '$3')"; fi; }
has_n "no 5h estimate sample while incomplete" "0" "$(est_samples 5h)"
has_n "no 7d estimate sample while incomplete" "0" "$(est_samples 7d)"

echo ">>> normal render"
render >/dev/null
out=$(render)
has "session token sums from deduplicated JSONL" "Tokens  -> Input: 200.0k" "$out"
hasre "cache reads shown separately" "Cached: +9\.0M" "$out"
has "lifetime counts each message once" "LifetimeTotal: 1.0M" "$out"
has "Est100% sits on the device line with the device label" "[Highest:1.0M/1.0M] [Est100%:2.0M] (box-1)" "$out"
hasnt "Est100% is not shown on the account-wide API lines" "Est100%" "$(grep -v 'box-1' <<< "$out")"
has_n "one 5h estimate sample once the backfill is complete" "1" "$(est_samples 5h)"
hasnt "LimitAt is gone" "LimitAt" "$out"
hasnt "old fake Local/API average is gone" "[Average:" "$out"
has "weekly_scoped limit is shown" "7d Fable" "$out"
has "window tokens on the local line" "[Highest:1.0M/1.0M]" "$out"

echo ">>> two parallel renders against one state"
render >/dev/null & p1=$!
render >/dev/null & p2=$!
wait "$p1"; wait "$p2"
ok_state=1
for f in "$DATA_DIR"/limit-highscore-state_*.json "$DATA_DIR"/limit-ledger_*.json; do
    jq -e . "$f" >/dev/null 2>&1 || ok_state=0
done
if [[ "$ok_state" -eq 1 ]]; then PASS=$((PASS + 1)); echo "  PASS: state files valid after parallel renders"; else FAIL=$((FAIL + 1)); echo "  FAIL: state file corrupt after parallel renders"; fi
out=$(render)
has "window tokens unchanged by parallel renders" "[Highest:1.0M/1.0M]" "$out"

echo ">>> stale cache shows its age"
# 100 s old: younger than the refresh cadence (no background fetch attempt),
# older than the stale threshold set for this render.
touch -d "@$(($(date +%s) - 100))" "$CACHE"
samples_before=$(est_samples 5h)
out=$(CLAUDE_MB_LIMIT_STALE_AFTER=60 render)
has "stale marker" "[stale 1m]" "$out"
write_cache 60 "$(iso $((NOW + 7200)))" 30
touch -d "@$(($(date +%s) - 100))" "$CACHE"
CLAUDE_MB_LIMIT_STALE_AFTER=60 render >/dev/null
has_n "a stale API value adds no estimate sample" "$samples_before" "$(est_samples 5h)"
# I: not stale yet for the [stale] marker (600 s), but older than the
# estimate freshness limit: no sample either.
write_cache 70 "$(iso $((NOW + 7200)))" 30
touch -d "@$(($(date +%s) - 100))" "$CACHE"
out=$(CLAUDE_MB_LIMIT_EST_MAX_AGE=60 render)
hasnt "no stale marker below the stale threshold" "[stale" "$out"
has_n "an API value older than the estimate limit adds no sample" "$samples_before" "$(est_samples 5h)"
write_cache 80 "$(iso $((NOW + 7200)))" 30
CLAUDE_MB_LIMIT_EST_MAX_AGE=60 render >/dev/null
has_n "a fresh API value adds a sample" "$((samples_before + 1))" "$(est_samples 5h)"

echo ">>> after resets_at the window shows 0 % (reset)"
write_cache 87 "$(iso $((NOW - 60)))" 30
out=$(render)
has "reset window shows 0 %" "0.0% reset: " "$out"
has "reset marker" "(reset)" "$out"

echo ">>> show-highscores uses the device label"
out=$(bash "$SCRIPT_DIR/show-highscores.sh" 2>&1)
has "device label instead of hostname" "**Device:** box-1" "$out"
has "Est100% labelled as a per-device value" "**Est100% (box-1)**" "$out"
has "per-device limitation documented" "Est100% is therefore a lower bound" "$out"

echo ""
echo "passed: $PASS failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
