#!/usr/bin/env bash
# highscore-state.sh - Window tracking, highscores and the Est100% estimate.
#
# Window tokens are no longer accumulated here. They are summed from the
# deduplicated JSONL ledger (usage-ledger.sh) for the time range
# [window_start, now], so there is no per-render delta, no baseline and no
# counter that a lost write can reset. This file only keeps:
#   - windows.<5h|7d>: last resets_at, last API value and an optional start
#     override, used to detect window resets and derive window_start
#   - highscores.<plan>.<5h|7d>: highest window token count ever seen (only rises)
#   - est.<5h|7d>: samples tokens/(api%/100) of the current window; the median
#     is the Est100% estimate (replaces the old LimitAt easter egg)
#
# Every update is one read-modify-write under an exclusive lock with an atomic
# write. An unreadable state makes the caller skip the render instead of
# counting from zero.
# shellcheck disable=SC2250

CLAUDE_BASE_DIR="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}"
PROFILE_NAME=$(basename "${CLAUDE_BASE_DIR}")
_HS_DIR="${BASH_SOURCE[0]%/*}"
[[ "$_HS_DIR" == "${BASH_SOURCE[0]}" ]] && _HS_DIR="."

# shellcheck source=state-io.sh
source "${_HS_DIR}/state-io.sh"

HIGHSCORE_STATE_FILE="${PLUGIN_DATA_DIR:-${CLAUDE_BASE_DIR}/marcel-bich-claude-marketplace/limit}/limit-highscore-state_${PROFILE_NAME}.json"
HIGHSCORE_LOCK="${HIGHSCORE_STATE_FILE}.lock"

# Schema 2 (v2.36): window tokens are deduplicated work tokens (input + output +
# cache writes, cache reads excluded). Highscores and LimitAt values of schema 1
# were measured in an inflated unit (duplicated lines, cache reads 1:1, context
# re-adds) and are discarded on upgrade (a .bak copy is kept).
HIGHSCORE_SCHEMA_VERSION=2

# Starting highscores per plan (work tokens). They only serve as the initial
# denominator and are exceeded by real usage.
HIGHSCORE_DEFAULTS='{"max20": {"5h": 1000000, "7d": 10000000},
                     "max5":  {"5h": 500000,  "7d": 5000000},
                     "pro":   {"5h": 200000,  "7d": 2000000},
                     "unknown": {"5h": 1000000, "7d": 10000000}}'

# Estimate samples are only taken at or above this API utilization; below it the
# ratio tokens/pct is dominated by rounding of the integer percentage.
EST_MIN_PCT="${CLAUDE_MB_LIMIT_EST_MIN_PCT:-20}"

highscore_log() {
    limit_debug_enabled || return 0
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] highscore: $*" >> "/tmp/claude-mb-limit-debug_${PROFILE_NAME}.log" 2>/dev/null || true
}

_hs_fresh_state() {
    jq -cn --argjson v "$HIGHSCORE_SCHEMA_VERSION" --argjson d "$HIGHSCORE_DEFAULTS" \
        '{schema_version: $v, plan: "unknown", highscores: $d, windows: {}, est: {}}'
}

# Locked RMW. Args: jq_program [jq args...]. The program gets the state as input
# and must output {state: <new state>, out: <value to print>}.
_hs_rmw_locked() {
    local program="$1"
    shift
    local result="" state_line="" out_line=""
    # Fast path (every render, four times): ONE jq call reads the current
    # state, checks it and runs the program; it prints the new state and the
    # output on two lines. Anything unusual falls through to the slow path.
    if [[ -s "$HIGHSCORE_STATE_FILE" ]]; then
        result=$(jq -r "$@" --argjson __v "$HIGHSCORE_SCHEMA_VERSION" '
            if type == "object" and .schema_version == $__v then . else error("state") end
            | '"$program"' | (.state | tojson), (.out | tostring)' "$HIGHSCORE_STATE_FILE" 2>/dev/null) || result=""
        if [[ -n "$result" ]]; then
            state_line="${result%%$'\n'*}"
            out_line="${result#*$'\n'}"
            printf '%s\n' "$state_line" | LIMIT_ATOMIC_RAW=1 limit_atomic_write "$HIGHSCORE_STATE_FILE" || return 1
            printf '%s' "$out_line"
            return 0
        fi
    fi
    _hs_rmw_slow "$program" "$@"
}

# Slow path: missing, unreadable or old-schema state (rare).
_hs_rmw_slow() {
    local program="$1"
    shift
    local state=""
    if [[ -e "$HIGHSCORE_STATE_FILE" ]]; then
        if ! state=$(limit_read_json "$HIGHSCORE_STATE_FILE"); then
            # Unreadable. Writes are atomic, so this is real corruption (or a file
            # from an old non-atomic version). Skip this render; only rebuild when
            # the file has been broken for a while.
            local mtime now
            mtime=$(stat -c %Y "$HIGHSCORE_STATE_FILE" 2>/dev/null || stat -f %m "$HIGHSCORE_STATE_FILE" 2>/dev/null || echo 0)
            now=$(date +%s)
            if [[ $((now - mtime)) -lt 30 ]]; then
                highscore_log "state unreadable - skipping render"
                return 1
            fi
            cp "$HIGHSCORE_STATE_FILE" "${HIGHSCORE_STATE_FILE}.bak" 2>/dev/null || true
            state=""
        elif [[ "$(printf '%s' "$state" | jq -r '.schema_version // 0')" != "$HIGHSCORE_SCHEMA_VERSION" ]]; then
            highscore_log "schema mismatch - discarding old highscores (backup kept)"
            cp "$HIGHSCORE_STATE_FILE" "${HIGHSCORE_STATE_FILE}.bak" 2>/dev/null || true
            state=""
        fi
    fi
    [[ -n "$state" ]] || state=$(_hs_fresh_state)

    local result
    result=$(printf '%s' "$state" | jq -c "$@" "$program" 2>/dev/null) || return 1
    [[ -n "$result" ]] || return 1
    printf '%s' "$result" | jq -c '.state' | limit_atomic_write "$HIGHSCORE_STATE_FILE" || return 1
    printf '%s' "$result" | jq -r '.out'
}

_hs_rmw() {
    limit_with_lock "$HIGHSCORE_LOCK" _hs_rmw_locked "$@"
}

_hs_epoch() {
    local iso="${1:-}"
    [[ -z "$iso" || "$iso" == "null" ]] && { echo ""; return; }
    if date --version >/dev/null 2>&1; then
        date -d "$iso" +%s 2>/dev/null || echo ""
    else
        local clean="${iso%%.*}"
        clean="${clean%%+*}"
        date -j -u -f "%Y-%m-%dT%H:%M:%S" "$clean" +%s 2>/dev/null || echo ""
    fi
}

# Track a limit window and detect resets.
# Usage: window_track <5h|7d> <api_pct|""> <resets_at_iso|""> [now]
# Prints "<window_start_epoch> <reset_detected 0|1>"; the start is -1 when it is
# unknown (no resets_at seen yet and none passed) - callers must skip that window.
# A reset is detected when
#   a) resets_at moved to a different hour (normal case), or
#   b) the utilization dropped sharply (> 20 points, or below half of a value
#      >= 10) while resets_at stayed the same - the window then starts at the
#      last sample before the drop, or
#   c) now is past the stored resets_at (stale cache) - the new window starts at
#      the old resets_at.
# With an empty api/resets_at (API unavailable) the stored values are used.
window_track() {
    local win="$1" api="${2:-}" reset_iso="${3:-}" now="${4:-$(date +%s)}"
    local dur=18000
    [[ "$win" == "7d" ]] && dur=604800
    local reset_epoch
    reset_epoch=$(_hs_epoch "$reset_iso")
    [[ "$api" =~ ^[0-9]+(\.[0-9]+)?$ ]] || api=""
    _hs_rmw '
        def hour(e): ((e + 1800) / 3600 | floor);
        (.windows[$w] // {}) as $p
        | ($p.reset_epoch // null) as $prev
        | (if $r == "" then $prev else ($r | tonumber) end) as $new
        | (if $a == "" then null else ($a | tonumber) end) as $api
        | ($p.override // 0) as $ov0
        | (if $prev != null and $new != null and hour($new) != hour($prev) then {d: 1, ov: 0}
           elif $prev != null and $now > $prev and hour($new) == hour($prev) and $ov0 != $prev
               then {d: 1, ov: $prev}
           elif $api != null and $p.last_api != null
               and (($p.last_api - $api) > 20 or ($p.last_api >= 10 and $api < ($p.last_api / 2)))
               then {d: 1, ov: ($p.last_seen // $now)}
           else {d: 0, ov: $ov0} end) as $res
        | (if $new == null then (if $res.ov > 0 then $res.ov else -1 end)
           else ([$new - $dur, $res.ov] + (if $now >= $new then [$new] else [] end) | max) end) as $start
        | .windows[$w] = {reset_epoch: $new, override: $res.ov,
                          last_api: ($api // $p.last_api), last_seen: (if $api != null then $now else $p.last_seen end)}
        | {state: ., out: "\($start | floor) \($res.d)"}
    ' --arg w "$win" --arg a "$api" --arg r "${reset_epoch:-}" \
      --argjson now "$now" --argjson dur "$dur"
}

# Record window tokens: raise the highscore and collect an Est100% sample.
# Usage: highscore_record <plan> <5h|7d> <window_id> <window_tokens> <api_pct|""> [now]
# window_id identifies the current window (its start epoch); a new id starts a
# new sample set and keeps the old median as fallback.
# Prints JSON {hs, est, src} (est null when unknown, src "cur" or "prev").
highscore_record() {
    local plan="${1:-unknown}" win="$2" wid="${3:-0}" tokens="${4:-0}" api="${5:-}" now="${6:-$(date +%s)}"
    [[ "$tokens" =~ ^[0-9]+$ ]] || tokens=0
    [[ "$api" =~ ^[0-9]+(\.[0-9]+)?$ ]] || api=""
    _hs_rmw '
        def median: sort | length as $n
            | if $n == 0 then null
              elif $n % 2 == 1 then .[($n - 1) / 2]
              else ((.[$n / 2 - 1] + .[$n / 2]) / 2) end;
        .plan = $plan
        | (.highscores[$plan][$w] // $defaults[$plan][$w] // $defaults.unknown[$w]) as $hs0
        | ([$hs0, $tok] | max) as $hs
        | .highscores[$plan][$w] = $hs
        | (.est[$w] // {id: null, samples: [], prev: null}) as $e0
        | (if $e0.id != $wid
             then {id: $wid, samples: [],
                   prev: (($e0.samples | map(.[1]) | median) // $e0.prev)}
             else $e0 end) as $e1
        | (if $a != "" and ($a | tonumber) >= $min and ($a | tonumber) <= 100 and $tok > 0
              and (($e1.samples | last | .[0]) != ($a | tonumber))
             then $e1 | .samples = ((.samples + [[($a | tonumber), ($tok * 100 / ($a | tonumber) | round)]]) | .[-50:])
             else $e1 end) as $e
        | .est[$w] = $e
        | ($e.samples | map(.[1]) | median) as $cur
        | {state: ., out: ({hs: $hs,
                            est: (if $cur != null then ($cur | round) elif $e.prev != null then ($e.prev | round) else null end),
                            src: (if $cur == null and $e.prev != null then "prev" else "cur" end)} | tojson)}
    ' --arg plan "$plan" --arg w "$win" --argjson wid "$wid" --argjson tok "$tokens" \
      --arg a "$api" --argjson min "$EST_MIN_PCT" --argjson defaults "$HIGHSCORE_DEFAULTS"
}

# Read-only helpers (show-highscores, debug). Print nothing when unreadable.
get_highscore() {
    local plan="${1:-unknown}" win="${2:-5h}"
    limit_read_json "$HIGHSCORE_STATE_FILE" 2>/dev/null \
        | jq -r --arg p "$plan" --arg w "$win" --argjson d "$HIGHSCORE_DEFAULTS" \
            '.highscores[$p][$w] // $d[$p][$w] // $d.unknown[$w]' 2>/dev/null
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-}" in
        show) jq . "$HIGHSCORE_STATE_FILE" 2>/dev/null ;;
        get-highscore) get_highscore "${2:-unknown}" "${3:-5h}" ;;
        *) echo "Usage: $0 <show|get-highscore <plan> <5h|7d>>" ;;
    esac
fi
