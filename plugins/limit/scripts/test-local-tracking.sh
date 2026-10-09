#!/usr/bin/env bash
# test-local-tracking.sh - Fixture tests for window tracking, reset detection,
# highscores, the Est100% estimate, averages, concurrency and the API backoff.
# Everything runs in a temp dir with a fake profile; the real plugin state, the
# real usage cache and the credentials file are never read or written.
# shellcheck disable=SC2250

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR=$(mktemp -d)
FAKE_PROFILE="limit-test-$$-${RANDOM}"
export HOME="$TEST_DIR/home"
export CLAUDE_CONFIG_DIR="$TEST_DIR/home/$FAKE_PROFILE"
export CLAUDE_MB_LIMIT_DEBUG=false
export PLUGIN_DATA_DIR="$CLAUDE_CONFIG_DIR/marcel-bich-claude-marketplace/limit"
mkdir -p "$PLUGIN_DATA_DIR" "$CLAUDE_CONFIG_DIR/projects"
FAKE_CACHE="/tmp/claude-mb-limit-cache_${FAKE_PROFILE}.json"
FAKE_STATUS="/tmp/claude-mb-limit-refresh-status_${FAKE_PROFILE}"
FAKE_LOCK="/tmp/claude-mb-limit-refresh_${FAKE_PROFILE}.lock"
cleanup() {
    rm -rf "$TEST_DIR"
    rm -f "$FAKE_CACHE" "$FAKE_STATUS" "$FAKE_LOCK" "/tmp/claude-mb-context-cache_${FAKE_PROFILE}.json" \
        "/tmp/claude-mb-context-cache_test-session-1.json" "/tmp/claude-mb-limit-caption-test-session-1" 2>/dev/null
}
trap cleanup EXIT

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (expected '$2', got '$3')"; fi; }
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%S.000000+00:00; }

# shellcheck source=highscore-state.sh
source "$SCRIPT_DIR/highscore-state.sh"
# shellcheck source=limit-history.sh
source "$SCRIPT_DIR/limit-history.sh"

NOW=$(date -u +%s)
R1=$(( (NOW / 3600 + 2) * 3600 ))          # reset in ~2h
R1_ISO=$(iso "$R1")

echo ">>> window start follows resets_at (5h window = resets_at - 5h)"
read -r start detected <<< "$(window_track 5h 30 "$R1_ISO" "$NOW")"
check "start = resets_at - 5h" "$((R1 - 18000))" "$start"

echo ">>> unknown window (no API yet, nothing stored) is -1, never 'all history'"
read -r start detected <<< "$(window_track 7d "" "" "$NOW")"
check "unknown start" "-1" "$start"

echo ">>> sharp utilization drop with unchanged resets_at is a reset"
window_track 5h 82 "$R1_ISO" "$((NOW + 60))" >/dev/null
read -r start detected <<< "$(window_track 5h 4 "$R1_ISO" "$((NOW + 120))")"
check "drop detected" "1" "$detected"
check "window restarts at the last sample before the drop" "$((NOW + 60))" "$start"
read -r start detected <<< "$(window_track 5h 6 "$R1_ISO" "$((NOW + 180))")"
check "no second reset while rising again" "0" "$detected"
check "override kept for the same resets_at" "$((NOW + 60))" "$start"

echo ">>> small fluctuation is not a reset"
read -r start detected <<< "$(window_track 5h 5 "$R1_ISO" "$((NOW + 240))")"
check "1 point dip ignored" "0" "$detected"

echo ">>> now past resets_at (stale cache) is a reset; window starts at the old reset"
read -r start detected <<< "$(window_track 5h 90 "$R1_ISO" "$((R1 + 30))")"
check "expired window detected" "1" "$detected"
check "start = old resets_at" "$R1" "$start"

echo ">>> new resets_at hour clears the override"
R2=$((R1 + 5 * 3600))
read -r start detected <<< "$(window_track 5h 3 "$(iso "$R2")" "$((R1 + 300))")"
check "start from new resets_at" "$((R2 - 18000))" "$start"

echo ">>> highscores only rise; Est100% is the median of tokens/(api%/100)"
out=$(highscore_record max20 5h "$R2" 1000 10 "$((R1 + 400))")   # api < 20: no sample
check "below 20 % no estimate yet" "1000000 null cur" "$(jq -r '"\(.hs) \(.est) \(.src)"' <<< "$out")"
highscore_record max20 5h "$R2" 2000000 20 "$((R1 + 500))" >/dev/null   # ratio 10.0M
highscore_record max20 5h "$R2" 4400000 40 "$((R1 + 600))" >/dev/null   # ratio 11.0M
out=$(highscore_record max20 5h "$R2" 6000000 60 "$((R1 + 700))")       # ratio 10.0M
check "highscore raised to window tokens" "6000000" "$(jq -r '.hs' <<< "$out")"
check "estimate median" "10000000" "$(jq -r '.est' <<< "$out")"
out=$(highscore_record max20 5h "$R2" 100 60 "$((R1 + 800))")
check "highscore never decreases" "6000000" "$(jq -r '.hs' <<< "$out")"
check "repeated api value adds no sample" "10000000" "$(jq -r '.est' <<< "$out")"
R3=$((R2 + 5 * 3600))
out=$(highscore_record max20 5h "$R3" 500 2 "$((R2 + 100))")
check "new window falls back to previous window estimate" "10000000 prev" "$(jq -r '"\(.est) \(.src)"' <<< "$out")"

echo ">>> parallel renders against one state file stay consistent"
pids=()
for i in $(seq 1 12); do
    highscore_record max20 7d "$R3" "$((20000000 + i * 1000))" 30 "$((R2 + 200 + i))" >/dev/null &
    pids+=($!)
done
for p in "${pids[@]}"; do wait "$p"; done
if jq -e . "$HIGHSCORE_STATE_FILE" >/dev/null 2>&1; then ok "state is valid JSON after 12 parallel writers"; else bad "state corrupt after parallel writers"; fi
check "7d highscore is the max of all writers" "20012000" "$(jq -r '.highscores.max20["7d"]' "$HIGHSCORE_STATE_FILE")"
check "5h highscore untouched by 7d writers" "6000000" "$(jq -r '.highscores.max20["5h"]' "$HIGHSCORE_STATE_FILE")"

echo ">>> unreadable state is skipped, not treated as zero"
cp "$HIGHSCORE_STATE_FILE" "$TEST_DIR/hs.good"
: > "$HIGHSCORE_STATE_FILE"
if highscore_record max20 5h "$R3" 1 30 "$((R2 + 999))" >/dev/null 2>&1; then
    bad "empty state must skip the render"
else
    ok "empty state skips the render"
fi
cp "$TEST_DIR/hs.good" "$HIGHSCORE_STATE_FILE"

echo ">>> schema bump discards inflated old highscores and LimitAt"
cat > "$HIGHSCORE_STATE_FILE" << 'EOF'
{"schema_version": 1, "plan": "max20", "highscores": {"max20": {"5h": 698300000, "7d": 9000000000}},
 "limits_at": {"max20": {"5h": 25000000, "7d": null}}, "window_tokens_5h": 698300000}
EOF
out=$(highscore_record max20 5h "$R3" 1500000 30 "$((R2 + 1000))")
check "old inflated highscore discarded" "1500000" "$(jq -r '.hs' <<< "$out")"
if [[ -f "${HIGHSCORE_STATE_FILE}.bak" ]]; then ok "old state backed up"; else bad "no backup of old state"; fi
check "no limits_at in new schema" "null" "$(jq -r '.limits_at' "$HIGHSCORE_STATE_FILE")"

echo ">>> averages: peak per window and usage per hour from history"
HISTORY_FILE="$TEST_DIR/history.jsonl"
H0=$((NOW - 20 * 3600))
{
    # window A peaks at 60, window B peaks at 40 (sawtooth), current window at 10
    for v in 10 30 60; do jq -cn --arg ts "$(date -u -d "@$H0" +%Y-%m-%dT%H:%M:%SZ)" --argjson v "$v" '{ts:$ts,"5h":{api:$v},"7d":{api:1}}'; H0=$((H0 + 3600)); done
    for v in 5 25 40; do jq -cn --arg ts "$(date -u -d "@$H0" +%Y-%m-%dT%H:%M:%SZ)" --argjson v "$v" '{ts:$ts,"5h":{api:$v},"7d":{api:2}}'; H0=$((H0 + 3600)); done
    for v in 2 10; do jq -cn --arg ts "$(date -u -d "@$H0" +%Y-%m-%dT%H:%M:%SZ)" --argjson v "$v" '{ts:$ts,"5h":{api:$v},"7d":{api:3}}'; H0=$((H0 + 3600)); done
} > "$HISTORY_FILE"
check "avg peak of completed windows (60, 40)" "50.0" "$(get_avg_peak '."5h".api' 168)"
# consumption between consecutive samples: 20+30 (A) + 5+20+15 (B, restart counts
# from 0) + 2+8 (C) = 100; history is only 20h old, so the rate is per 20h, not 24h
check "avg usage per hour" "5.0" "$(get_avg_rate '."5h".api' 24 "$NOW")"
check "rounding is half-up, not floor or half-even" "2.3" "$(limit_round1 2.25)"
# one pass for the statusline: 5h peak, 5h %/h, 7d peak (none completed), 7d %/day
# (increase 2 points over 20h = 2.4 per day), opus, sonnet (no data)
check "single-pass averages" "50.0 5.0 - 2.4 - -" "$(history_averages "$NOW")"
check "no history -> empty" "" "$(HISTORY_FILE=$TEST_DIR/none.jsonl get_avg_peak '."5h".api' 168)"

echo ">>> refresh-usage honours the stored backoff (no API call, no credentials read)"
mkdir -p "$PLUGIN_DATA_DIR"
jq -n --argjson r $((NOW + 300)) '{consecutive_failures: 2, last_rate_limit: "x", retry_at: $r}' \
    > "$PLUGIN_DATA_DIR/backoff-state_${FAKE_PROFILE}.json"
rc=0; out=$(bash "$SCRIPT_DIR/refresh-usage.sh" 2>/dev/null) || rc=$?
check "backoff active -> rate-limited without fetching" "rate-limited 6" "$out $rc"
jq -n --argjson r $((NOW - 5)) '{consecutive_failures: 2, last_rate_limit: "x", retry_at: $r}' \
    > "$PLUGIN_DATA_DIR/backoff-state_${FAKE_PROFILE}.json"
rc=0; out=$(bash "$SCRIPT_DIR/refresh-usage.sh" 2>/dev/null) || rc=$?
check "backoff expired -> proceeds (fake profile has no credentials)" "no-credentials 3" "$out $rc"
jq -n --argjson r $((NOW + 300)) '{consecutive_failures: 2, last_rate_limit: "x", retry_at: $r}' \
    > "$TEST_DIR/backoff.json"
check "retry seconds come from the stored retry_at (stable across renders)" "300 300" \
    "$(backoff_retry_in "$TEST_DIR/backoff.json" "$NOW") $(backoff_retry_in "$TEST_DIR/backoff.json" "$NOW")"

echo ""
echo "passed: $PASS failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
