#!/usr/bin/env bash
# show-highscores.sh - Display formatted highscore status
# Called by /limit:highscore command

set -euo pipefail

# Force C locale for numeric operations (prevents issues with de_DE locale expecting comma)
export LC_NUMERIC=C

# Multi-Account Support: CLAUDE_CONFIG_DIR determines the profile
CLAUDE_BASE_DIR="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}"
PROFILE_NAME=$(basename "${CLAUDE_BASE_DIR}")

# Paths - profile-specific
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DATA_DIR="${PLUGIN_DATA_DIR:-${CLAUDE_BASE_DIR}/marcel-bich-claude-marketplace/limit}"
HIGHSCORE_STATE="${PLUGIN_DATA_DIR}/limit-highscore-state_${PROFILE_NAME}.json"
API_CACHE="/tmp/claude-mb-limit-cache_${PROFILE_NAME}.json"
HISTORY_FILE="${PLUGIN_DATA_DIR}/limit-history_${PROFILE_NAME}.jsonl"
DEVICE_LABEL="${CLAUDE_MB_LIMIT_DEVICE_LABEL:-$(hostname 2>/dev/null || echo unknown)}"

# Source history functions (averages) and the token ledger
# shellcheck source=limit-history.sh
source "${SCRIPT_DIR}/limit-history.sh"
# shellcheck source=usage-ledger.sh
source "${SCRIPT_DIR}/usage-ledger.sh"

# Format number as human-readable (1.5M, 500.0k, 2.0G, 1.5T)
# Uses G (Giga) instead of B (Billion) for consistency with statusline
format_number() {
    local num="${1:-0}"
    [[ "$num" == "null" || -z "$num" ]] && { echo "n/a"; return; }
    [[ "$num" =~ ^[0-9]+(\.[0-9]+)?$ ]] || { echo "$num"; return; }

    # Remove decimals for comparison
    local int_num="${num%.*}"
    [[ -z "$int_num" ]] && int_num=0

    if (( int_num >= 1000000000000000000000000 )); then
        printf "%.1fY" "$(echo "scale=1; $num / 1000000000000000000000000" | bc)"
    elif (( int_num >= 1000000000000000000000 )); then
        printf "%.1fZ" "$(echo "scale=1; $num / 1000000000000000000000" | bc)"
    elif (( int_num >= 1000000000000000000 )); then
        printf "%.1fE" "$(echo "scale=1; $num / 1000000000000000000" | bc)"
    elif (( int_num >= 1000000000000000 )); then
        printf "%.1fP" "$(echo "scale=1; $num / 1000000000000000" | bc)"
    elif (( int_num >= 1000000000000 )); then
        printf "%.1fT" "$(echo "scale=1; $num / 1000000000000" | bc)"
    elif (( int_num >= 1000000000 )); then
        printf "%.1fG" "$(echo "scale=1; $num / 1000000000" | bc)"
    elif (( int_num >= 1000000 )); then
        printf "%.1fM" "$(echo "scale=1; $num / 1000000" | bc)"
    elif (( int_num >= 1000 )); then
        printf "%.1fk" "$(echo "scale=1; $num / 1000" | bc)"
    else
        echo "$int_num"
    fi
}

# Format price with 2 decimals
format_price() {
    local price="${1:-0}"
    [[ "$price" == "null" || -z "$price" ]] && { echo "n/a"; return; }
    printf "%.2f" "$price"
}

# Format reset time as absolute datetime
format_reset_datetime() {
    local reset_at="${1:-}"
    [[ -z "$reset_at" || "$reset_at" == "null" ]] && { echo "n/a"; return; }

    if date --version >/dev/null 2>&1; then
        # GNU date
        date -d "$reset_at" "+%Y-%m-%d %H:%M" 2>/dev/null || echo "n/a"
    else
        # BSD date
        date -j -f "%Y-%m-%dT%H:%M:%S" "${reset_at%%.*}" "+%Y-%m-%d %H:%M" 2>/dev/null || echo "n/a"
    fi
}

# Calculate time until reset (relative)
format_time_until() {
    local reset_at="${1:-}"
    [[ -z "$reset_at" || "$reset_at" == "null" ]] && { echo "n/a"; return; }

    local now reset_epoch diff
    now=$(date +%s)

    # Parse ISO timestamp
    if date --version >/dev/null 2>&1; then
        # GNU date
        reset_epoch=$(date -d "$reset_at" +%s 2>/dev/null) || { echo "n/a"; return; }
    else
        # BSD date
        reset_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S" "${reset_at%%.*}" +%s 2>/dev/null) || { echo "n/a"; return; }
    fi

    diff=$((reset_epoch - now))
    [[ $diff -lt 0 ]] && diff=0

    local days hours minutes
    days=$((diff / 86400))
    hours=$(( (diff % 86400) / 3600 ))
    minutes=$(( (diff % 3600) / 60 ))

    if (( days > 0 )); then
        echo "${days}d ${hours}h"
    elif (( hours > 0 )); then
        echo "${hours}h ${minutes}m"
    else
        echo "${minutes}m"
    fi
}

# Safe JSON read with default
json_get() {
    local file="$1"
    local path="$2"
    local default="${3:-0}"

    if [[ -f "$file" ]]; then
        local val
        val=$(jq -r "$path // \"$default\"" "$file" 2>/dev/null) || val="$default"
        [[ "$val" == "null" ]] && val="$default"
        echo "$val"
    else
        echo "$default"
    fi
}

# Detect current plan
detect_plan() {
    # First try highscore state
    if [[ -f "$HIGHSCORE_STATE" ]]; then
        local plan
        plan=$(jq -r '.plan // ""' "$HIGHSCORE_STATE" 2>/dev/null)
        if [[ -n "$plan" && "$plan" != "null" && "$plan" != "unknown" ]]; then
            echo "$plan"
            return
        fi
    fi

    # Try plan-detect.sh if available
    if [[ -x "${SCRIPT_DIR}/plan-detect.sh" ]]; then
        local detected
        detected=$("${SCRIPT_DIR}/plan-detect.sh" 2>/dev/null) || detected=""
        if [[ -n "$detected" && "$detected" != "unknown" ]]; then
            echo "$detected"
            return
        fi
    fi

    echo "unknown"
}

# Window start (read-only) from the stored window tracking:
# max(resets_at - duration, override, resets_at if already passed)
window_start() {
    local win="$1" dur=18000
    [[ "$win" == "7d" ]] && dur=604800
    [[ -f "$HIGHSCORE_STATE" ]] || { echo 0; return; }
    jq -r --arg w "$win" --argjson dur "$dur" --argjson now "$(date +%s)" '
        (.windows[$w] // {}) as $x
        | if $x.reset_epoch == null then ($x.override // 0)
          else ([$x.reset_epoch - $dur, ($x.override // 0)]
                + (if $now >= $x.reset_epoch then [$x.reset_epoch] else [] end) | max) end
        | floor' "$HIGHSCORE_STATE" 2>/dev/null || echo 0
}

# Main output
main() {
    local current_plan
    current_plan=$(detect_plan)

    echo "## Highscore Status"
    echo ""
    echo "**Plan:** $current_plan | **Device:** $DEVICE_LABEL"
    echo ""
    echo "Token unit: work tokens = input + output + cache writes, each API message"
    echo "counted once (Claude Code repeats usage on every content-block line)."
    echo "Cache reads are listed separately."
    echo ""
    echo "---"
    echo ""

    ledger_scan_all >/dev/null 2>&1 || true
    local start_5h start_7d summary=""
    start_5h=$(window_start 5h)
    start_7d=$(window_start 7d)
    summary=$(ledger_summary "" "$start_5h" "$start_7d" 2>/dev/null) || summary=""

    echo "### Combined Total (Main + Subagents)"
    echo ""
    if [[ -n "$summary" ]]; then
        local lt_tokens lt_cost lt_unpriced lt_cr
        read -r lt_tokens lt_cost lt_unpriced lt_cr <<< "$(jq -r '.lifetime | "\(.tokens) \(.cost) \(.unpriced) \(.cache_read)"' <<< "$summary")"
        local cost_str
        cost_str="\$$(format_price "$lt_cost")"
        [[ "$lt_unpriced" -gt 0 ]] && cost_str="${cost_str} (+n/a: ${lt_unpriced} unpriced model(s))"
        echo "**$(format_number "$lt_tokens") Tokens** | ${cost_str} | Cache reads: $(format_number "$lt_cr")"
    else
        echo "> Ledger not available yet (it is built on the next statusline render)."
    fi
    echo ""
    echo "---"
    echo ""

    echo "### Current Window (Main + Subagents)"
    echo ""
    if [[ -n "$summary" ]]; then
        local w5 w5cr w7 w7cr
        read -r w5 w5cr w7 w7cr <<< "$(jq -r '"\(.w5[0]) \(.w5[1]) \(.w7[0]) \(.w7[1])"' <<< "$summary")"
        echo "- **5h:** $(format_number "$w5") Tokens (cache reads $(format_number "$w5cr"))"
        echo "- **7d:** $(format_number "$w7") Tokens (cache reads $(format_number "$w7cr"))"
        if [[ "$(jq -r '.complete == true' <<< "$summary")" != "true" ]]; then
            echo ""
            echo "> Transcript backfill still running: window sums are incomplete and no"
            echo "> Est100% samples are taken until it has finished (a few statusline renders)."
        fi
    else
        echo "- n/a"
    fi
    echo ""
    echo "---"
    echo ""

    echo "### Current Usage (from API)"
    echo ""
    if [[ -f "$API_CACHE" ]]; then
        local five_util five_reset seven_util seven_reset
        five_util=$(json_get "$API_CACHE" ".five_hour.utilization" "n/a")
        five_reset=$(json_get "$API_CACHE" ".five_hour.resets_at" "")
        seven_util=$(json_get "$API_CACHE" ".seven_day.utilization" "n/a")
        seven_reset=$(json_get "$API_CACHE" ".seven_day.resets_at" "")

        echo "- **5h:** ${five_util}% (resets in $(format_time_until "$five_reset") - $(format_reset_datetime "$five_reset"))"
        echo "- **7d:** ${seven_util}% (resets in $(format_time_until "$seven_reset") - $(format_reset_datetime "$seven_reset"))"
        jq -r '.limits[]? | select(.kind != "session" and .kind != "weekly_all")
            | "- **\(.kind)\((.scope.model.display_name // .scope.surface) as $n | if $n then " (" + $n + ")" else "" end):** \(.percent // 0)%"' \
            "$API_CACHE" 2>/dev/null || true
    else
        echo "> API cache not available. Run a Claude session to populate usage data."
    fi
    echo ""
    echo "---"
    echo ""

    echo "### Local Highscores and Est100%"
    echo ""
    if [[ -f "$HIGHSCORE_STATE" ]]; then
        local hs_5h hs_7d
        hs_5h=$(json_get "$HIGHSCORE_STATE" ".highscores[\"$current_plan\"][\"5h\"]" "0")
        hs_7d=$(json_get "$HIGHSCORE_STATE" ".highscores[\"$current_plan\"][\"7d\"]" "0")
        echo "**Highscores ($current_plan)**"
        echo "- 5h: $(format_number "$hs_5h")"
        echo "- 7d: $(format_number "$hs_7d")"
        echo ""
        local est5 est7
        est5=$(jq -r 'def median: sort | length as $n | if $n == 0 then null elif $n % 2 == 1 then .[($n-1)/2] else ((.[$n/2-1] + .[$n/2]) / 2) end;
            (.est["5h"] // {}) | ((.samples // []) | map(.[1]) | median) // .prev // "n/a"' "$HIGHSCORE_STATE" 2>/dev/null) || est5="n/a"
        est7=$(jq -r 'def median: sort | length as $n | if $n == 0 then null elif $n % 2 == 1 then .[($n-1)/2] else ((.[$n/2-1] + .[$n/2]) / 2) end;
            (.est["7d"] // {}) | ((.samples // []) | map(.[1]) | median) // .prev // "n/a"' "$HIGHSCORE_STATE" 2>/dev/null) || est7="n/a"
        echo "**Est100% (${DEVICE_LABEL})** (median of this device's tokens / (account-wide API% / 100), samples at >= 20 %)"
        echo "- 5h: $(format_number "$est5")"
        echo "- 7d: $(format_number "$est7")"
        echo ""
        echo "**Other Plans:**"
        for other_plan in max20 max5 pro unknown; do
            if [[ "$other_plan" != "$current_plan" ]]; then
                local other_5h other_7d
                other_5h=$(json_get "$HIGHSCORE_STATE" ".highscores[\"$other_plan\"][\"5h\"]" "0")
                other_7d=$(json_get "$HIGHSCORE_STATE" ".highscores[\"$other_plan\"][\"7d\"]" "0")
                echo "- $other_plan: 5h=$(format_number "$other_5h"), 7d=$(format_number "$other_7d")"
            fi
        done
    else
        echo "> No local highscore data yet."
        echo "> All data stays on your device - nothing is sent anywhere."
    fi
    echo ""
    echo "---"
    echo ""

    echo "### Lifetime Breakdown (per model)"
    echo ""
    if [[ -n "$summary" ]] && [[ -f "$LEDGER_FILE" ]]; then
        local kind label
        for kind in main sub; do
            [[ "$kind" == "main" ]] && label="Main Agent" || label="Subagents"
            echo "**${label}:**"
            local rows
            rows=$(jq -r --argjson p "$LEDGER_PRICES" --arg k "$kind" '
                def base: sub("\\[.*$"; "") | sub("-[0-9]{8}$"; "");
                .lifetime[$k] // {} | to_entries[]
                | (.value) as $v | ($p[.key | base]) as $pr
                | [.key, (($v[0] // 0) + ($v[1] // 0) + ($v[3] // 0) + ($v[4] // 0)), ($v[2] // 0),
                   (if $pr == null then "n/a" else ([range(0;5) as $i | ($v[$i] // 0) * $pr[$i]] | add / 1000000 | tostring) end)]
                | @tsv' "$LEDGER_FILE" 2>/dev/null) || rows=""
            if [[ -z "$rows" ]]; then
                echo "- none recorded"
            else
                local m t cr c
                while IFS=$'\t' read -r m t cr c; do
                    if [[ "$c" == "n/a" ]]; then
                        echo "- ${m}: $(format_number "$t") (cache reads $(format_number "$cr")), cost n/a (unknown price)"
                    else
                        echo "- ${m}: $(format_number "$t") (cache reads $(format_number "$cr")), \$$(format_price "$c")"
                    fi
                done <<< "$rows"
            fi
            echo ""
        done
    else
        echo "- n/a"
        echo ""
    fi
    echo "---"
    echo ""

    echo "### History & Averages"
    echo ""
    if [[ -f "$HISTORY_FILE" ]]; then
        echo "**History Data:**"
        echo "- Total entries: $(get_history_count)"
        echo "- Last 24h: $(get_history_count 24) entries"
        echo "- Last 7d: $(get_history_count 168) entries"
        echo ""
        local p5 r5 p7 r7 po ps
        read -r p5 r5 p7 r7 po ps <<< "$(history_averages)"
        echo "**Averages (account-wide API utilization):**"
        echo "- 5h: average peak per window (7d) ${p5/#-/n/a}% | usage per hour (24h) ${r5/#-/n/a}%"
        echo "- 7d: average peak per window (28d) ${p7/#-/n/a}% | usage per day (7d) ${r7/#-/n/a}%"
        [[ "$po" != "-" ]] && echo "- Opus 7d: average peak ${po}%"
        [[ "$ps" != "-" ]] && echo "- Sonnet 7d: average peak ${ps}%"
        echo ""
    else
        echo "> No history data yet. History is recorded every 10 minutes"
        echo "> during active usage and retained for 28 days."
        echo ""
    fi

    echo "---"
    echo ""
    echo "### Achievement Symbol"
    echo ""
    echo "The achievement symbol (trophy or [!]) appears when the global API"
    echo "usage is >= 95% AND your local device usage is >= 95% of its own"
    echo "highscore."
    echo ""
    echo "---"
    echo ""
    echo "> **How does Local Highscore Tracking work?**"
    echo ">"
    echo "> Window tokens are summed from the Claude Code transcripts for the"
    echo "> current 5h / 7d window. Highscores only increase; they are stored per"
    echo "> plan so that a plan change does not mix up the records. Est100% is a"
    echo "> continuous estimate of the token count at 100 % API utilization."
    echo "> Both only see this device's transcripts: other devices on the same"
    echo "> account keep their own ~/.claude, which cannot be read from here, while"
    echo "> the API percentage is account-wide. With parallel use on other devices"
    echo "> Est100% is therefore a lower bound."
    echo ">"
    echo "> All data is stored locally - nothing leaves your device."
}

main "$@"
