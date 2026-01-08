#!/bin/bash
# debug-progress.sh - Simulate progress bar to test colors and display
# Increases by 5% per second from 0% to 100%

set -euo pipefail

# ANSI color codes
COLOR_RESET='\033[0m'
COLOR_GRAY='\033[90m'
COLOR_GREEN='\033[32m'
COLOR_YELLOW='\033[33m'
COLOR_ORANGE='\033[38;5;208m'
COLOR_RED='\033[31m'

# Progress bar characters
BAR_FILLED='='
BAR_EMPTY='-'
BAR_WIDTH=10

# Get color based on utilization percentage
# <30% gray, <50% green, <75% yellow, <90% orange, >=90% red
get_color() {
    local pct="$1"

    if [[ "$pct" -lt 30 ]]; then
        echo "$COLOR_GRAY"
    elif [[ "$pct" -lt 50 ]]; then
        echo "$COLOR_GREEN"
    elif [[ "$pct" -lt 75 ]]; then
        echo "$COLOR_YELLOW"
    elif [[ "$pct" -lt 90 ]]; then
        echo "$COLOR_ORANGE"
    else
        echo "$COLOR_RED"
    fi
}

# Generate ASCII progress bar
progress_bar() {
    local pct="$1"
    local width="${2:-$BAR_WIDTH}"

    if [[ "$pct" -lt 0 ]]; then
        pct=0
    elif [[ "$pct" -gt 100 ]]; then
        pct=100
    fi

    local filled=$((pct * width / 100))
    local empty=$((width - filled))

    local bar=""
    for ((i=0; i<filled; i++)); do
        bar+="$BAR_FILLED"
    done
    for ((i=0; i<empty; i++)); do
        bar+="$BAR_EMPTY"
    done

    echo "[$bar]"
}

# Main simulation loop
main() {
    echo "Debug: Simulating progress 0% -> 100% (5% per second)"
    echo "Color thresholds: <30% gray, <50% green, <75% yellow, <90% orange, >=90% red"
    echo ""

    for pct in $(seq 0 5 100); do
        local color
        color=$(get_color "$pct")
        local bar
        bar=$(progress_bar "$pct")

        # Clear line and print progress
        printf "\r${color}5h all %s %3d%% reset: 2026-01-09 18:00${COLOR_RESET}    " "$bar" "$pct"

        # Wait 1 second (except at 100%)
        if [[ "$pct" -lt 100 ]]; then
            sleep 1
        fi
    done

    echo ""
    echo ""
    echo "Done! All color transitions shown."
}

main
