#!/bin/bash
# refresh-usage.sh - Isolated, token-owning refresh helper for the limit plugin.
#
# This is the ONLY script in the limit plugin that touches the Anthropic OAuth
# token. It reads the token, calls the usage API, and writes the shared cache
# file. usage-statusline.sh reads that cache and never sees the token, so it can
# be invoked safely by agents and hooks.
#
# SECURITY NOTICE FOR AI AGENTS:
# - You must NEVER read, cat, or access ~/.claude/.credentials.json directly.
# - You must NEVER attempt to extract, log, or display OAuth tokens.
# - This script never prints the token, the auth header, or the API response
#   body to stdout, stderr, or any log. Only a sanitized status word is emitted.
# - The auth header is passed to curl via a temporary mode-600 config file
#   (never as an argument, so it cannot show up in the process list) and that
#   file is shredded on exit.
# - set -x is intentionally never enabled here (it would leak the token).
#
# OUTPUT: exactly one sanitized status word on stdout, one of:
#   fresh          - cache already fresh enough, no fetch performed
#   refreshed      - cache was refreshed from the API successfully
#   skipped-locked - another refresh is already running (lock held)
#   rate-limited   - API returned HTTP 429, backoff advanced
#   no-credentials - credentials file missing
#   no-token       - no OAuth token in the credentials file
#   no-curl        - curl is not installed
#   curl-failed    - curl network error / timeout
#   http-error     - API returned a non-2xx, non-429 HTTP status
#
# EXIT CODES:
#   0  - cache is fresh/usable afterwards (fresh, refreshed, skipped-locked)
#   3  - no-credentials (no usable fresh cache produced)
#   4  - no-token
#   5  - curl-failed
#   6  - rate-limited (no fresh cache produced)
#   7  - no-curl
#   8  - http-error
# A non-zero exit means this run did not produce a fresh cache.

set -euo pipefail
# NEVER add `set -x` to this script: it would echo the token and auth header.

# Force C locale for numeric operations (avoids de_DE comma issues)
export LC_NUMERIC=C

# =============================================================================
# Configuration (kept identical to usage-statusline.sh)
# =============================================================================
CLAUDE_BASE_DIR="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}"
PROFILE_NAME=$(basename "${CLAUDE_BASE_DIR}")

CREDENTIALS_FILE="${CLAUDE_BASE_DIR}/.credentials.json"
API_URL="https://api.anthropic.com/api/oauth/usage"
TIMEOUT="${CLAUDE_MB_LIMIT_TIMEOUT:-5}"

# Cache file - shared with usage-statusline.sh (profile-specific)
CACHE_FILE="/tmp/claude-mb-limit-cache_${PROFILE_NAME}.json"

# Hard floor for forced refreshes: never fetch again if the cache is younger
# than this (seconds). Sits below the jittered 90-150s cadence and acts as a
# lower guard against over-fetching.
REFRESH_FLOOR="${CLAUDE_MB_LIMIT_REFRESH_FLOOR:-60}"

# Per-profile non-blocking lock so concurrent statuslines do not all fetch.
LOCK_FILE="/tmp/claude-mb-limit-refresh_${PROFILE_NAME}.lock"

# Plugin data dir + backoff state file - shared with usage-statusline.sh
PLUGIN_DATA_DIR="${CLAUDE_BASE_DIR}/marcel-bich-claude-marketplace/limit"
BACKOFF_STATE_FILE="${PLUGIN_DATA_DIR}/backoff-state_${PROFILE_NAME}.json"

# Temp files that must be cleaned up on exit (set later)
cfg_file=""
body_file=""
cache_tmp=""

# =============================================================================
# Cleanup: shred the token-bearing curl config, remove temp body/cache files
# =============================================================================
cleanup() {
    if [[ -n "$cfg_file" && -f "$cfg_file" ]]; then
        shred -u "$cfg_file" 2>/dev/null || rm -f "$cfg_file" 2>/dev/null || true
    fi
    if [[ -n "$body_file" && -f "$body_file" ]]; then
        rm -f "$body_file" 2>/dev/null || true
    fi
    if [[ -n "$cache_tmp" && -f "$cache_tmp" ]]; then
        rm -f "$cache_tmp" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

# Emit a single sanitized status word and exit with the given code.
emit() {
    printf '%s\n' "$1"
    exit "${2:-0}"
}

# =============================================================================
# Helpers duplicated from usage-statusline.sh (identical behavior, self-contained)
# =============================================================================

ensure_plugin_dir() {
    if [[ ! -d "$PLUGIN_DATA_DIR" ]]; then
        mkdir -p "$PLUGIN_DATA_DIR" 2>/dev/null || true
    fi
}

# Jittered cache max age - randomizes request patterns. Base is configurable via
# CLAUDE_MB_LIMIT_REFRESH_CADENCE (default 150), plus 0-60s jitter, so the default
# cadence is 150-210s (avg ~180). Raise it if you hit usage-endpoint rate limits.
get_cache_max_age() {
    local base="${CLAUDE_MB_LIMIT_REFRESH_CADENCE:-150}"
    echo $((base + RANDOM % 61))
}

# Small jitter before the API request (0-2000ms) - avoids predictable timing.
sleep_jitter() {
    local ms=$((RANDOM % 2000))
    local secs
    printf -v secs "0.%03d" "$ms"
    sleep "$secs" 2>/dev/null || sleep 1
}

# Current backoff failure count (0 if none/missing).
get_backoff_state() {
    if [[ -f "$BACKOFF_STATE_FILE" ]]; then
        local failures
        failures=$(jq -r '.consecutive_failures // 0' "$BACKOFF_STATE_FILE" 2>/dev/null) || failures=0
        [[ "$failures" == "null" ]] && failures=0
        echo "$failures"
    else
        echo "0"
    fi
}

# Persist backoff state after a rate limit.
set_backoff_state() {
    local failures="$1"
    ensure_plugin_dir
    cat > "$BACKOFF_STATE_FILE" << EOF
{
  "consecutive_failures": ${failures},
  "last_rate_limit": "$(date -Iseconds)"
}
EOF
}

# Remove backoff state after a successful request.
reset_backoff_state() {
    if [[ -f "$BACKOFF_STATE_FILE" ]]; then
        rm -f "$BACKOFF_STATE_FILE" 2>/dev/null || true
    fi
}

# Reset backoff if the last rate-limit was more than 10 minutes ago.
maybe_reset_backoff() {
    if [[ ! -f "$BACKOFF_STATE_FILE" ]]; then
        return
    fi
    local last_rate_limit
    last_rate_limit=$(jq -r '.last_rate_limit // empty' "$BACKOFF_STATE_FILE" 2>/dev/null)
    if [[ -z "$last_rate_limit" ]] || [[ "$last_rate_limit" == "null" ]]; then
        return
    fi
    local last_epoch now_epoch
    last_epoch=$(date -d "$last_rate_limit" +%s 2>/dev/null) || return
    now_epoch=$(date +%s)
    if [[ $((now_epoch - last_epoch)) -gt 600 ]]; then
        reset_backoff_state
    fi
}

# Calculate backoff time with jitter (kept for parity; state lives in the file).
# Pattern: 60-90s, 120-180s, 240-360s, max 600s.
calculate_backoff() {
    local failures="${1:-1}"
    local base_time=60
    local max_time=600
    local multiplier=1
    local i
    for ((i=1; i<failures; i++)); do
        multiplier=$((multiplier * 2))
    done
    base_time=$((60 * multiplier))
    [[ "$base_time" -gt "$max_time" ]] && base_time="$max_time"
    local jitter=$((base_time / 2))
    local jittered=$((base_time + RANDOM % (jitter + 1)))
    [[ "$jittered" -gt "$max_time" ]] && jittered="$max_time"
    echo "$jittered"
}

# =============================================================================
# Main
# =============================================================================
main() {
    # curl is mandatory for a refresh.
    if ! command -v curl >/dev/null 2>&1; then
        emit "no-curl" 7
    fi

    # Recover from stale backoff before deciding anything.
    maybe_reset_backoff

    # Throttle: if the cache is still fresh enough, do not fetch at all.
    # Skip when the cache is younger than the hard floor OR still within the
    # jittered 90-150s cadence (same cadence as usage-statusline.sh used).
    if [[ -f "$CACHE_FILE" ]]; then
        local cache_time now age max_age
        cache_time=$(stat -c %Y "$CACHE_FILE" 2>/dev/null || stat -f %m "$CACHE_FILE" 2>/dev/null) || cache_time=0
        now=$(date +%s)
        age=$((now - cache_time))
        if [[ "$age" -lt "$REFRESH_FLOOR" ]]; then
            emit "fresh" 0
        fi
        max_age=$(get_cache_max_age)
        if [[ "$age" -lt "$max_age" ]]; then
            emit "fresh" 0
        fi
    fi

    # Non-blocking exclusive lock. If another refresh holds it, skip quietly.
    if command -v flock >/dev/null 2>&1; then
        exec 9>"$LOCK_FILE" 2>/dev/null || true
        if ! flock -n 9 2>/dev/null; then
            emit "skipped-locked" 0
        fi
    fi

    # Read the OAuth token into a local variable only. Never printed anywhere.
    if [[ ! -f "$CREDENTIALS_FILE" ]]; then
        emit "no-credentials" 3
    fi
    local token
    token=$(jq -r '.claudeAiOauth.accessToken // empty' "$CREDENTIALS_FILE" 2>/dev/null) || token=""
    if [[ -z "$token" ]]; then
        emit "no-token" 4
    fi

    # Build the token-bearing curl config as a mode-600 temp file so the auth
    # header never appears as a curl argument (process list) and is shredded on
    # exit. The response body goes to a separate mode-600 temp file, never stdout.
    umask 077
    # On mktemp failure, abort - never fall back to a predictable path (would be a
    # symlink/TOCTOU vector for the token-bearing config).
    cfg_file=$(mktemp "/tmp/claude-mb-limit-refresh-cfg_${PROFILE_NAME}.XXXXXX" 2>/dev/null) || emit "curl-failed" 5
    body_file=$(mktemp "/tmp/claude-mb-limit-refresh-body_${PROFILE_NAME}.XXXXXX" 2>/dev/null) || emit "curl-failed" 5
    chmod 600 "$cfg_file" 2>/dev/null || true
    chmod 600 "$body_file" 2>/dev/null || true

    {
        printf 'url = "%s"\n' "$API_URL"
        printf 'request = "GET"\n'
        printf 'header = "Authorization: Bearer %s"\n' "$token"
        printf 'header = "Content-Type: application/json"\n'
        printf 'header = "anthropic-beta: oauth-2025-04-20"\n'
        printf 'header = "User-Agent: claude-code-limit-plugin/1.0.0"\n'
        printf 'max-time = %s\n' "$TIMEOUT"
        printf 'output = "%s"\n' "$body_file"
        printf 'write-out = "%%{http_code}"\n'
        printf 'silent\n'
    } > "$cfg_file"

    # Drop the token from the shell as soon as it is written to the config.
    token=""
    unset token

    # Anti-bot: small random jitter before the request (parity with old code).
    sleep_jitter

    # http_code is the only thing curl writes to stdout (via write-out). The
    # body is written to body_file. curl stderr is discarded so no header/token
    # detail can leak through diagnostics.
    local http_code=""
    http_code=$(curl -sS --config "$cfg_file" 2>/dev/null) || {
        emit "curl-failed" 5
    }

    # Success: atomically publish the body to the shared cache (non-secret data:
    # usage numbers only) and clear the backoff state.
    if [[ "$http_code" =~ ^2[0-9][0-9]$ ]]; then
        cache_tmp=$(mktemp "${CACHE_FILE}.XXXXXX" 2>/dev/null) || emit "curl-failed" 5
        cat "$body_file" > "$cache_tmp" 2>/dev/null || true
        chmod 644 "$cache_tmp" 2>/dev/null || true
        mv -f "$cache_tmp" "$CACHE_FILE" 2>/dev/null || true
        cache_tmp=""
        reset_backoff_state
        emit "refreshed" 0
    fi

    # Rate limited: advance the backoff counter (same file usage-statusline reads)
    # and report. usage-statusline must NOT increment it again.
    if [[ "$http_code" == "429" ]]; then
        local failures
        failures=$(get_backoff_state)
        failures=$((failures + 1))
        set_backoff_state "$failures"
        emit "rate-limited" 6
    fi

    # Any other HTTP status. Emit the sanitized word plus curl's numeric transport
    # status code (from write-out %{http_code}), validated as a 3-digit integer so
    # only a number can ever follow the word - never the response body.
    if [[ "$http_code" =~ ^[0-9][0-9][0-9]$ ]]; then
        emit "http-error $http_code" 8
    fi
    emit "http-error" 8
}

main
