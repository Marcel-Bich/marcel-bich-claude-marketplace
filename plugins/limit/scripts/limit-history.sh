#!/usr/bin/env bash
# limit-history.sh - History tracking and average calculation for limit plugin
# Stores JSONL entries with usage data for computing averages
# shellcheck disable=SC2250

set -euo pipefail

# =============================================================================
# Multi-Account Support: CLAUDE_CONFIG_DIR determines the profile
# =============================================================================
CLAUDE_BASE_DIR="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}"
PROFILE_NAME=$(basename "${CLAUDE_BASE_DIR}")
_HIST_DIR="${BASH_SOURCE[0]%/*}"
[[ "$_HIST_DIR" == "${BASH_SOURCE[0]}" ]] && _HIST_DIR="."
# shellcheck source=state-io.sh
source "${_HIST_DIR}/state-io.sh"

# History file location - profile-specific
HISTORY_FILE="${PLUGIN_DATA_DIR:-${CLAUDE_BASE_DIR}/marcel-bich-claude-marketplace/limit}/limit-history_${PROFILE_NAME}.jsonl"

# Configuration with defaults
HISTORY_ENABLED="${CLAUDE_MB_LIMIT_HISTORY_ENABLED:-true}"
HISTORY_INTERVAL="${CLAUDE_MB_LIMIT_HISTORY_INTERVAL:-600}"  # 10 minutes in seconds
HISTORY_DAYS="${CLAUDE_MB_LIMIT_HISTORY_DAYS:-28}"           # 28 days retention

# Last write timestamp file (to check interval) - profile-specific
HISTORY_LAST_WRITE="${PLUGIN_DATA_DIR:-${CLAUDE_BASE_DIR}/marcel-bich-claude-marketplace/limit}/history-last-write_${PROFILE_NAME}"
HISTORY_LOCK="${HISTORY_FILE}.lock"

# =============================================================================
# History write control
# =============================================================================

# Check if enough time has elapsed since last history write
# Returns: 0 if should write, 1 if too soon
should_write_history() {
    if [[ "$HISTORY_ENABLED" != "true" ]]; then
        return 1
    fi

    if [[ ! -f "$HISTORY_LAST_WRITE" ]]; then
        return 0
    fi

    local last_write now diff
    last_write=$(cat "$HISTORY_LAST_WRITE" 2>/dev/null) || last_write=0
    [[ "$last_write" =~ ^[0-9]+$ ]] || last_write=0
    now=$(date +%s)
    diff=$((now - last_write))

    if [[ $diff -ge $HISTORY_INTERVAL ]]; then
        return 0
    fi

    return 1
}

# Update last write timestamp (atomic)
update_last_write() {
    date +%s | LIMIT_ATOMIC_RAW=1 limit_atomic_write "$HISTORY_LAST_WRITE" || true
}

# =============================================================================
# History cleanup
# =============================================================================

# Remove entries older than HISTORY_DAYS (caller holds HISTORY_LOCK).
cleanup_history() {
    if [[ ! -f "$HISTORY_FILE" ]]; then
        return 0
    fi

    local cutoff_seconds retention_seconds
    retention_seconds=$((HISTORY_DAYS * 86400))
    cutoff_seconds=$(($(date +%s) - retention_seconds))

    local kept
    kept=$(jq -c --argjson cutoff "$cutoff_seconds" '
        select((.ts | fromdateiso8601) > $cutoff)
    ' "$HISTORY_FILE" 2>/dev/null) || return 0

    # Nothing left (or a parse problem): keep the file as it is.
    [[ -n "$kept" ]] || return 0
    printf '%s\n' "$kept" | LIMIT_ATOMIC_RAW=1 limit_atomic_write "$HISTORY_FILE" || true
}

# =============================================================================
# History append
# =============================================================================

_append_history_locked() {
    should_write_history || return 0
    local entry="$1"
    printf '%s\n' "$entry" >> "$HISTORY_FILE" || return 0
    update_last_write
    cleanup_history
}

# Append a history entry with current usage data (at most every HISTORY_INTERVAL)
# Usage: append_history <5h_api_pct> <5h_window_tokens> <5h_highscore> \
#                       <7d_api_pct> <7d_window_tokens> <7d_highscore> \
#                       <opus_pct> <sonnet_pct> <plan> <device> \
#                       [5h_resets_at] [7d_resets_at]
# The resets_at values let the averages segment windows exactly.
append_history() {
    if [[ "$HISTORY_ENABLED" != "true" ]]; then
        return 0
    fi

    if ! should_write_history; then
        return 0
    fi

    local api_5h="${1:-0}"
    local local_5h="${2:-0}"
    local hs_5h="${3:-0}"
    local api_7d="${4:-0}"
    local local_7d="${5:-0}"
    local hs_7d="${6:-0}"
    local opus="${7:-0}"
    local sonnet="${8:-0}"
    local plan="${9:-unknown}"
    local device="${10:-$(hostname)}"
    local reset_5h="${11:-}"
    local reset_7d="${12:-}"

    local dir
    dir=$(dirname "$HISTORY_FILE")
    if [[ ! -d "$dir" ]]; then
        mkdir -p "$dir" 2>/dev/null || return 0
    fi

    local ts entry
    ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    entry=$(jq -cn \
        --arg ts "$ts" \
        --argjson api5h "${api_5h:-0}" \
        --argjson local5h "${local_5h:-0}" \
        --argjson hs5h "${hs_5h:-0}" \
        --argjson api7d "${api_7d:-0}" \
        --argjson local7d "${local_7d:-0}" \
        --argjson hs7d "${hs_7d:-0}" \
        --argjson opus "${opus:-0}" \
        --argjson sonnet "${sonnet:-0}" \
        --arg plan "$plan" \
        --arg device "$device" \
        --arg r5 "$reset_5h" \
        --arg r7 "$reset_7d" \
        '{
            ts: $ts,
            "5h": ({api: $api5h, local: $local5h, hs: $hs5h} + (if $r5 != "" then {reset: $r5} else {} end)),
            "7d": ({api: $api7d, local: $local7d, hs: $hs7d} + (if $r7 != "" then {reset: $r7} else {} end)),
            opus: $opus,
            sonnet: $sonnet,
            plan: $plan,
            device: $device
        }' 2>/dev/null)

    if [[ -n "$entry" ]]; then
        LIMIT_LOCK_WAIT=0 limit_with_lock "$HISTORY_LOCK" _append_history_locked "$entry" || true
    fi
}

# =============================================================================
# Average calculation
# =============================================================================
# The old [Average:L%/A%] took the plain mean of all 10-minute samples of the
# API utilization. That is the mean of a sawtooth, only taken while the
# statusline runs, and both halves queried the same field (so L == A always).
# Two meaningful replacements, both from the account-wide API utilization:
#   get_avg_peak <field> <hours>   average peak per completed window
#   get_avg_rate <field> <hours>   average consumption per hour (idle included)
# Samples are grouped by their recorded resets_at (minute resolution), so samples
# of different windows interleaved in one file never count as consumption.
# Inside a group, consumption is measured against the running max. A sharp drop
# (more than 20 points, or below half of a value >= 10) is a restart, and a dip
# below the max is noise. The first value of every group counts as consumption
# (its window started at 0), except in the group of the very first sample, which
# is only the baseline. A group whose resets_at has passed is a completed window.
# The last segment of an open group is still running and is not a completed peak.
# Samples without resets_at form one group and use the same running-max rule, so
# jitter in them is no consumption either. This is intended.
# Lines with a missing or unparsable ts are skipped; the other samples still count.

_HISTORY_JQ_SEGMENT='
    def drop(p; c): (p - c) > 20 or (p >= 10 and c < p / 2);
    def rmin: if type == "string"
        then (sub("\\.[0-9]+"; "") | sub("[+]00:00$"; "Z") | (fromdateiso8601? // null)
              | if . == null then null else ((. + 30) / 60 | floor) end)
        else null end;
    def series(f; rf; cutoff):
        [.[] | (.ts | fromdateiso8601?) as $t
             | select($t != null and $t > cutoff)
             | {t: $t, v: (f // null), r: (rf | rmin)}
             | select(.v != null)] | sort_by(.t);
    def runs($first):
        reduce .[] as $e ({m: null, used: 0, segs: []};
            if .m == null then {m: $e.v, used: (if $first then 0 else $e.v end), segs: [$e.v]}
            elif drop(.m; $e.v) then {m: $e.v, used: (.used + $e.v), segs: (.segs + [$e.v])}
            elif $e.v > .m then {m: $e.v, used: (.used + $e.v - .m), segs: (.segs[:-1] + [$e.v])}
            else . end);
    def avgpeak($now):
        . as $s
        | [group_by(.r)[] as $g
            | ($g | runs(true) | .segs) as $sg
            | (if $g[0].r != null then ($g[0].r * 60 <= $now) else ($g[-1].t != $s[-1].t) end) as $done
            | (if $done then $sg else $sg[:-1] end)[]]
        | if length > 0 then add / length else null end;
    def avgrate($now):
        . as $s
        | if ($s | length) < 2 then null
          else
            ([group_by(.r)[] as $g | ($g | runs($g[0].t == $s[0].t) | .used)] | add) as $used
            | (($now - $s[0].t) / 3600) as $span
            | if $span <= 0 then null else $used / $span end
          end;
'

# jq path of the recorded resets_at that belongs to a utilization field
# (."5h".api -> ."5h".reset); other fields have none.
_hist_reset_field() {
    case "$1" in
        *.api) echo "${1%.api}.reset" ;;
        *) echo "null" ;;
    esac
}

# Average peak of completed windows within the last <hours> (the still running
# window is excluded). Empty when no window has completed yet.
get_avg_peak() {
    local field="$1" hours="${2:-168}" now="${3:-$(date +%s)}"
    [[ -f "$HISTORY_FILE" ]] || { echo ""; return; }
    local cutoff result
    cutoff=$((now - hours * 3600))
    result=$(jq -rs --argjson cutoff "$cutoff" --argjson now "$now" "${_HISTORY_JQ_SEGMENT}"'
        series('"$field"'; '"$(_hist_reset_field "$field")"'; $cutoff) | avgpeak($now)
    ' "$HISTORY_FILE" 2>/dev/null)
    if [[ -z "$result" || "$result" == "null" ]]; then echo ""; else limit_round1 "$result"; fi
}

# Average consumption per hour over the last <hours>: the sum of increases
# between consecutive samples (a drop counts as a restart from 0) divided by
# the covered time (the full period, or less when the history is younger).
# Args: field hours [now]
get_avg_rate() {
    local field="$1" hours="${2:-24}" now="${3:-$(date +%s)}"
    [[ -f "$HISTORY_FILE" ]] || { echo ""; return; }
    local cutoff result
    cutoff=$((now - hours * 3600))
    result=$(jq -rs --argjson cutoff "$cutoff" --argjson now "$now" "${_HISTORY_JQ_SEGMENT}"'
        series('"$field"'; '"$(_hist_reset_field "$field")"'; $cutoff) | avgrate($now)
    ' "$HISTORY_FILE" 2>/dev/null)
    if [[ -z "$result" || "$result" == "null" ]]; then echo ""; else limit_round1 "$result"; fi
}

# All averages the statusline shows, in ONE jq pass (it renders often).
# Prints: "<5h peak> <5h %/h> <7d peak> <7d %/day> <opus peak> <sonnet peak>",
# each value rounded half-up to one decimal or "-" when unknown.
# 5h: peaks over 7 days, rate over 24 h. 7d/opus/sonnet: peaks over 28 days,
# 7d rate over 7 days (shown per day).
history_averages() {
    local now="${1:-$(date +%s)}"
    [[ -f "$HISTORY_FILE" ]] || { echo "- - - - - -"; return; }
    local raw
    raw=$(jq -rs --argjson now "$now" "${_HISTORY_JQ_SEGMENT}"'
        . as $all
        | [ ($all | series(."5h".api; ."5h".reset; $now - 168*3600) | avgpeak($now)),
            ($all | series(."5h".api; ."5h".reset; $now - 24*3600) | avgrate($now)),
            ($all | series(."7d".api; ."7d".reset; $now - 672*3600) | avgpeak($now)),
            ($all | series(."7d".api; ."7d".reset; $now - 168*3600) | avgrate($now) | if . == null then null else . * 24 end),
            ($all | series(.opus; null; $now - 672*3600) | avgpeak($now)),
            ($all | series(.sonnet; null; $now - 672*3600) | avgpeak($now)) ]
        | map(if . == null then "-" else tostring end) | join(" ")
    ' "$HISTORY_FILE" 2>/dev/null) || raw=""
    [[ -n "$raw" ]] || { echo "- - - - - -"; return; }
    local out="" v
    for v in $raw; do
        if [[ "$v" == "-" ]]; then out="${out} -"; else out="${out} $(limit_round1 "$v")"; fi
    done
    echo "${out# }"
}

# Get history entry count (for diagnostics)
# Usage: get_history_count [hours]
get_history_count() {
    local hours="${1:-}"

    if [[ ! -f "$HISTORY_FILE" ]]; then
        echo "0"
        return
    fi

    if [[ -z "$hours" ]]; then
        # Total count
        wc -l < "$HISTORY_FILE" | tr -d ' '
    else
        local cutoff_seconds
        cutoff_seconds=$(($(date +%s) - hours * 3600))

        jq -rs --argjson cutoff "$cutoff_seconds" '
            [.[] | select((.ts | fromdateiso8601) > $cutoff)] | length
        ' "$HISTORY_FILE" 2>/dev/null || echo "0"
    fi
}

# =============================================================================
# CLI interface for testing
# =============================================================================

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-}" in
        should-write)
            if should_write_history; then
                echo "yes"
            else
                echo "no"
            fi
            ;;
        append)
            # append <5h_api> <5h_local> <5h_hs> <7d_api> <7d_local> <7d_hs> <opus> <sonnet> <plan> <device>
            append_history "${2:-0}" "${3:-0}" "${4:-0}" "${5:-0}" "${6:-0}" "${7:-0}" "${8:-0}" "${9:-0}" "${10:-unknown}" "${11:-$(hostname)}"
            echo "Entry appended (if interval passed)"
            ;;
        cleanup)
            limit_with_lock "$HISTORY_LOCK" cleanup_history
            echo "Cleanup complete"
            ;;
        avg-peak)
            # avg-peak <field> [hours]
            get_avg_peak "${2:-.\"5h\".api}" "${3:-168}"
            ;;
        avg-rate)
            # avg-rate <field> [hours]
            get_avg_rate "${2:-.\"5h\".api}" "${3:-24}"
            ;;
        count)
            # count [hours]
            get_history_count "${2:-}"
            ;;
        show)
            if [[ -f "$HISTORY_FILE" ]]; then
                jq -s '.' "$HISTORY_FILE" 2>/dev/null || cat "$HISTORY_FILE"
            else
                echo "No history file"
            fi
            ;;
        *)
            echo "Usage: $0 <command> [args]"
            echo ""
            echo "Commands:"
            echo "  should-write                  Check if history write is due"
            echo "  append <5h_api> <5h_local> <5h_hs> <7d_api> <7d_local> <7d_hs> <opus> <sonnet> <plan> <device>"
            echo "  cleanup                       Remove entries older than ${HISTORY_DAYS} days"
            echo "  avg-peak <field> [hours]      Average peak per completed window"
            echo "  avg-rate <field> [hours]      Average consumption per hour"
            echo "  count [hours]                 Get entry count (total or in hours)"
            echo "  show                          Show all history entries"
            ;;
    esac
fi
