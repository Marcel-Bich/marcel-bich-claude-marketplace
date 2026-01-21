#!/usr/bin/env bash
# subagent-tokens.sh - Incremental subagent token tracking for limit plugin
# Scans ~/.claude/projects/*/subagents/agent-*.jsonl files for token usage
# Uses file-offset tracking for efficient append handling
# Tracks tokens per model (haiku, sonnet, opus) with accurate pricing
# shellcheck disable=SC2250

set -euo pipefail

# =============================================================================
# Configuration
# =============================================================================

# State file for subagent tracking (within plugin data dir)
SUBAGENT_STATE_FILE="${PLUGIN_DATA_DIR:-${HOME}/.claude/marcel-bich-claude-marketplace/limit}/subagent-state.json"

# Claude projects directory (contains subagent JSONL files)
CLAUDE_PROJECTS_DIR="${HOME}/.claude/projects"

# Cache duration for subagent scan (same as API cache, default 120s)
SUBAGENT_CACHE_MAX_AGE="${CLAUDE_MB_LIMIT_CACHE_AGE:-120}"

# Retention period for file offsets (30 days in seconds)
FILE_OFFSET_RETENTION_DAYS=30
FILE_OFFSET_RETENTION_SECONDS=$((FILE_OFFSET_RETENTION_DAYS * 86400))

# Current schema version - bump on breaking changes to trigger reset
SUBAGENT_SCHEMA_VERSION=2

# Debug logging
SUBAGENT_DEBUG="${CLAUDE_MB_LIMIT_DEBUG:-0}"
SUBAGENT_LOG_FILE="${PLUGIN_DATA_DIR:-${HOME}/.claude/marcel-bich-claude-marketplace/limit}/subagent-debug.log"

subagent_log() {
    if [[ "$SUBAGENT_DEBUG" == "1" ]]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$SUBAGENT_LOG_FILE"
    fi
}

# =============================================================================
# Pricing Configuration (per Million Tokens) - Claude 4.5
# =============================================================================

# Haiku 4.5 pricing
HAIKU_INPUT_PRICE=1.00
HAIKU_OUTPUT_PRICE=5.00
HAIKU_CACHE_READ_PRICE=0.10      # 90% discount
HAIKU_CACHE_WRITE_PRICE=1.25     # 25% surcharge

# Sonnet 4.5 pricing
SONNET_INPUT_PRICE=3.00
SONNET_OUTPUT_PRICE=15.00
SONNET_CACHE_READ_PRICE=0.30
SONNET_CACHE_WRITE_PRICE=3.75

# Opus 4.5 pricing
OPUS_INPUT_PRICE=5.00
OPUS_OUTPUT_PRICE=25.00
OPUS_CACHE_READ_PRICE=0.50
OPUS_CACHE_WRITE_PRICE=6.25

# =============================================================================
# Model classification
# =============================================================================

# Map model ID to category (haiku, sonnet, opus)
# Usage: get_model_category "claude-haiku-4-5-20251001"
# Returns: haiku, sonnet, or opus
get_model_category() {
    local model_id="$1"

    case "$model_id" in
        *haiku*)
            echo "haiku"
            ;;
        *sonnet*)
            echo "sonnet"
            ;;
        *opus*)
            echo "opus"
            ;;
        *)
            # Default to opus (most expensive) for unknown models
            echo "opus"
            ;;
    esac
}

# Calculate cost for a specific model category
# Usage: calculate_model_cost <category> <input> <output> <cache_read> <cache_creation>
# Returns: cost in USD (decimal)
calculate_model_cost() {
    local category="$1"
    local input="${2:-0}"
    local output="${3:-0}"
    local cache_read="${4:-0}"
    local cache_creation="${5:-0}"

    local inp_price out_price cache_r_price cache_w_price

    case "$category" in
        haiku)
            inp_price="$HAIKU_INPUT_PRICE"
            out_price="$HAIKU_OUTPUT_PRICE"
            cache_r_price="$HAIKU_CACHE_READ_PRICE"
            cache_w_price="$HAIKU_CACHE_WRITE_PRICE"
            ;;
        sonnet)
            inp_price="$SONNET_INPUT_PRICE"
            out_price="$SONNET_OUTPUT_PRICE"
            cache_r_price="$SONNET_CACHE_READ_PRICE"
            cache_w_price="$SONNET_CACHE_WRITE_PRICE"
            ;;
        *)  # opus or unknown
            inp_price="$OPUS_INPUT_PRICE"
            out_price="$OPUS_OUTPUT_PRICE"
            cache_r_price="$OPUS_CACHE_READ_PRICE"
            cache_w_price="$OPUS_CACHE_WRITE_PRICE"
            ;;
    esac

    awk -v inp="$input" -v out="$output" \
        -v cache_r="$cache_read" -v cache_c="$cache_creation" \
        -v inp_price="$inp_price" -v out_price="$out_price" \
        -v cache_r_price="$cache_r_price" -v cache_w_price="$cache_w_price" \
        'BEGIN {
            mtok = 1000000
            cost = (inp / mtok) * inp_price + \
                   (out / mtok) * out_price + \
                   (cache_r / mtok) * cache_r_price + \
                   (cache_c / mtok) * cache_w_price
            printf "%.6f", cost
        }'
}

# Timestamp reference file for find -newer
SUBAGENT_TIMESTAMP_FILE="/tmp/claude-mb-limit-subagent-timestamp"

# =============================================================================
# State file operations
# =============================================================================

# Initialize subagent state file if it does not exist
# New v2 schema with file_offsets and per-model tracking
init_subagent_state() {
    local state_dir
    state_dir=$(dirname "${SUBAGENT_STATE_FILE}")

    if [[ ! -d "${state_dir}" ]]; then
        mkdir -p "${state_dir}" 2>/dev/null || true
    fi

    if [[ ! -f "${SUBAGENT_STATE_FILE}" ]]; then
        cat > "${SUBAGENT_STATE_FILE}" << 'EOF'
{
  "schema_version": 2,
  "last_scan_timestamp": 0,
  "last_cache_time": 0,
  "file_offsets": {},
  "haiku": {
    "input_tokens": 0,
    "output_tokens": 0,
    "cache_read_tokens": 0,
    "cache_creation_tokens": 0
  },
  "sonnet": {
    "input_tokens": 0,
    "output_tokens": 0,
    "cache_read_tokens": 0,
    "cache_creation_tokens": 0
  },
  "opus": {
    "input_tokens": 0,
    "output_tokens": 0,
    "cache_read_tokens": 0,
    "cache_creation_tokens": 0
  },
  "total_tokens": 0,
  "total_price": 0
}
EOF
    fi
}

# Reset state if schema version mismatch (no migration, clean reset)
reset_state_if_incompatible() {
    if [[ ! -f "${SUBAGENT_STATE_FILE}" ]]; then
        return 0
    fi

    local file_version
    file_version=$(jq -r '.schema_version // 0' "${SUBAGENT_STATE_FILE}" 2>/dev/null) || file_version=0

    if [[ "$file_version" != "$SUBAGENT_SCHEMA_VERSION" ]]; then
        subagent_log "Schema mismatch: file=$file_version current=$SUBAGENT_SCHEMA_VERSION - resetting state"
        # Backup old state (single backup, overwrites previous)
        cp "${SUBAGENT_STATE_FILE}" "${SUBAGENT_STATE_FILE}.bak" 2>/dev/null || true
        rm -f "${SUBAGENT_STATE_FILE}"
        subagent_log "Old state backed up to ${SUBAGENT_STATE_FILE}.bak"
    fi
}

# Cleanup old file offsets (older than 30 days)
cleanup_old_offsets() {
    if [[ ! -f "${SUBAGENT_STATE_FILE}" ]]; then
        return 0
    fi

    local current_time
    current_time=$(date +%s)
    local cutoff_time=$((current_time - FILE_OFFSET_RETENTION_SECONDS))

    local tmp_file
    tmp_file=$(mktemp)

    jq --argjson cutoff "$cutoff_time" '
        .file_offsets = (.file_offsets // {} | with_entries(select(.value.ts >= $cutoff)))
    ' "${SUBAGENT_STATE_FILE}" > "${tmp_file}" 2>/dev/null

    if [[ $? -eq 0 ]] && [[ -s "${tmp_file}" ]]; then
        mv "${tmp_file}" "${SUBAGENT_STATE_FILE}"
    else
        rm -f "${tmp_file}" 2>/dev/null
    fi
}

# Get value from subagent state
# Usage: get_subagent_state_value <key>
get_subagent_state_value() {
    local key="${1:-}"
    init_subagent_state

    jq -r ".${key} // 0" "${SUBAGENT_STATE_FILE}" 2>/dev/null || echo "0"
}

# =============================================================================
# File offset operations
# =============================================================================

# Get stored byte offset for a file
# Usage: get_file_offset <filepath>
# Returns: byte offset (0 if not tracked)
get_file_offset() {
    local filepath="$1"

    if [[ ! -f "${SUBAGENT_STATE_FILE}" ]]; then
        echo "0"
        return
    fi

    local offset
    offset=$(jq -r --arg path "$filepath" '.file_offsets[$path].bytes // 0' "${SUBAGENT_STATE_FILE}" 2>/dev/null) || offset=0
    [[ "$offset" == "null" ]] && offset=0
    echo "$offset"
}

# Read file content starting from byte offset
# Usage: read_file_from_offset <filepath> <offset>
# Returns: file content from offset to end
read_file_from_offset() {
    local filepath="$1"
    local offset="${2:-0}"

    if [[ ! -f "$filepath" ]]; then
        return
    fi

    if [[ "$offset" -eq 0 ]]; then
        cat "$filepath"
    else
        # tail -c +N reads from byte N to end (1-indexed, so add 1)
        tail -c +$((offset + 1)) "$filepath" 2>/dev/null || cat "$filepath"
    fi
}

# Get current file size in bytes
# Usage: get_file_size <filepath>
get_file_size() {
    local filepath="$1"

    if [[ ! -f "$filepath" ]]; then
        echo "0"
        return
    fi

    # Cross-platform file size
    if stat --version >/dev/null 2>&1; then
        # GNU stat
        stat -c %s "$filepath" 2>/dev/null || echo "0"
    else
        # BSD stat (macOS)
        stat -f %z "$filepath" 2>/dev/null || echo "0"
    fi
}

# =============================================================================
# Token extraction from JSONL files
# =============================================================================

# Extract tokens from JSONL content with per-model breakdown
# Usage: extract_tokens_from_content <content>
# Returns JSON: {"haiku":{...},"sonnet":{...},"opus":{...}}
extract_tokens_per_model() {
    local content="$1"

    if [[ -z "$content" ]]; then
        echo '{"haiku":{"input":0,"output":0,"cache_read":0,"cache_creation":0},"sonnet":{"input":0,"output":0,"cache_read":0,"cache_creation":0},"opus":{"input":0,"output":0,"cache_read":0,"cache_creation":0}}'
        return
    fi

    # Use jq to extract tokens grouped by model category (haiku/sonnet/opus)
    echo "$content" | jq -rs '
        # Map model ID to category
        def get_category:
            if test("haiku"; "i") then "haiku"
            elif test("sonnet"; "i") then "sonnet"
            else "opus"
            end;

        # Extract and categorize tokens
        [.[] | select(.message.usage and .message.model) |
            {
                category: (.message.model | get_category),
                input: (.message.usage.input_tokens // 0),
                output: (.message.usage.output_tokens // 0),
                cache_read: (.message.usage.cache_read_input_tokens // 0),
                cache_creation: (.message.usage.cache_creation_input_tokens // 0)
            }
        ] |

        # Group by category and sum
        group_by(.category) |
        map({
            key: .[0].category,
            value: {
                input: (map(.input) | add // 0),
                output: (map(.output) | add // 0),
                cache_read: (map(.cache_read) | add // 0),
                cache_creation: (map(.cache_creation) | add // 0)
            }
        }) | from_entries |

        # Ensure all categories exist
        {
            haiku: (.haiku // {input:0, output:0, cache_read:0, cache_creation:0}),
            sonnet: (.sonnet // {input:0, output:0, cache_read:0, cache_creation:0}),
            opus: (.opus // {input:0, output:0, cache_read:0, cache_creation:0})
        }
    ' 2>/dev/null || echo '{"haiku":{"input":0,"output":0,"cache_read":0,"cache_creation":0},"sonnet":{"input":0,"output":0,"cache_read":0,"cache_creation":0},"opus":{"input":0,"output":0,"cache_read":0,"cache_creation":0}}'
}

# Extract tokens from a file starting at offset, return per-model breakdown
# Usage: extract_tokens_from_file_offset <filepath> <offset>
# Returns JSON: {"haiku":{...},"sonnet":{...},"opus":{...},"new_offset":<bytes>}
extract_tokens_from_file_offset() {
    local filepath="$1"
    local offset="${2:-0}"

    if [[ ! -f "$filepath" ]]; then
        echo '{"haiku":{"input":0,"output":0,"cache_read":0,"cache_creation":0},"sonnet":{"input":0,"output":0,"cache_read":0,"cache_creation":0},"opus":{"input":0,"output":0,"cache_read":0,"cache_creation":0},"new_offset":0}'
        return
    fi

    local current_size
    current_size=$(get_file_size "$filepath")

    # Skip if file hasn't grown
    if [[ "$offset" -ge "$current_size" ]]; then
        echo "{\"haiku\":{\"input\":0,\"output\":0,\"cache_read\":0,\"cache_creation\":0},\"sonnet\":{\"input\":0,\"output\":0,\"cache_read\":0,\"cache_creation\":0},\"opus\":{\"input\":0,\"output\":0,\"cache_read\":0,\"cache_creation\":0},\"new_offset\":$current_size}"
        return
    fi

    # Read new content from offset
    local content
    content=$(read_file_from_offset "$filepath" "$offset")

    # Extract per-model tokens
    local tokens_json
    tokens_json=$(extract_tokens_per_model "$content")

    # Add new_offset to result
    echo "$tokens_json" | jq --argjson offset "$current_size" '. + {new_offset: $offset}' 2>/dev/null || \
        echo "{\"haiku\":{\"input\":0,\"output\":0,\"cache_read\":0,\"cache_creation\":0},\"sonnet\":{\"input\":0,\"output\":0,\"cache_read\":0,\"cache_creation\":0},\"opus\":{\"input\":0,\"output\":0,\"cache_read\":0,\"cache_creation\":0},\"new_offset\":$current_size}"
}

# =============================================================================
# Incremental scanning
# =============================================================================

# Set timestamp file to specific epoch time
# Usage: set_timestamp_file <epoch_seconds>
set_timestamp_file() {
    local epoch="${1:-0}"

    if [[ "${epoch}" -eq 0 ]]; then
        # Create with epoch 0 (1970-01-01) - will match all files
        touch -t 197001010000 "${SUBAGENT_TIMESTAMP_FILE}" 2>/dev/null || true
    else
        # Set to specific time
        if date --version >/dev/null 2>&1; then
            # GNU date
            touch -d "@${epoch}" "${SUBAGENT_TIMESTAMP_FILE}" 2>/dev/null || true
        else
            # BSD date (macOS)
            local formatted
            formatted=$(date -r "${epoch}" "+%Y%m%d%H%M.%S" 2>/dev/null)
            touch -t "${formatted}" "${SUBAGENT_TIMESTAMP_FILE}" 2>/dev/null || true
        fi
    fi
}

# Find new JSONL files since last scan
# Usage: find_new_jsonl_files
# Returns: list of file paths, one per line
find_new_jsonl_files() {
    local last_scan
    last_scan=$(get_subagent_state_value "last_scan_timestamp")
    [[ "${last_scan}" == "null" ]] && last_scan=0

    # Set timestamp file for find -newer
    set_timestamp_file "${last_scan}"

    # Find files newer than timestamp file
    # Use -newer for performance (avoids stat on every file)
    if [[ "${last_scan}" -eq 0 ]]; then
        # First scan: get all files
        find "${CLAUDE_PROJECTS_DIR}" -name "agent-*.jsonl" -type f 2>/dev/null || true
    else
        # Incremental scan: only files modified since last scan
        find "${CLAUDE_PROJECTS_DIR}" -name "agent-*.jsonl" -type f -newer "${SUBAGENT_TIMESTAMP_FILE}" 2>/dev/null || true
    fi
}

# =============================================================================
# Main scanning function
# =============================================================================

# Scan subagent files and update totals
# Uses file-offset tracking for efficient append handling
# Tracks tokens per model (haiku, sonnet, opus)
# Returns: total_tokens (all models combined)
get_subagent_tokens() {
    # Check if projects directory exists
    if [[ ! -d "${CLAUDE_PROJECTS_DIR}" ]]; then
        echo "0"
        return
    fi

    reset_state_if_incompatible
    init_subagent_state
    subagent_log "get_subagent_tokens: starting scan"

    local current_time
    current_time=$(date +%s)

    # Check cache: if last scan was recent, return cached value
    local last_cache_time cache_age
    last_cache_time=$(get_subagent_state_value "last_cache_time")
    [[ "${last_cache_time}" == "null" ]] && last_cache_time=0
    cache_age=$((current_time - last_cache_time))

    if [[ "${cache_age}" -lt "${SUBAGENT_CACHE_MAX_AGE}" ]]; then
        # Return cached total
        local cached_total
        cached_total=$(get_subagent_state_value "total_tokens")
        [[ "${cached_total}" == "null" ]] && cached_total=0
        echo "${cached_total}"
        return
    fi

    # Find files to process (modified since last scan)
    local files_to_scan
    files_to_scan=$(find_new_jsonl_files)

    # If no modified files, just update cache time and return
    if [[ -z "${files_to_scan}" ]]; then
        local cached_total
        cached_total=$(get_subagent_state_value "total_tokens")
        [[ "${cached_total}" == "null" ]] && cached_total=0

        # Update cache time
        local tmp_file
        tmp_file=$(mktemp)
        jq ".last_cache_time = ${current_time}" "${SUBAGENT_STATE_FILE}" > "${tmp_file}" && \
            mv "${tmp_file}" "${SUBAGENT_STATE_FILE}"

        echo "${cached_total}"
        return
    fi

    # Read current state for accumulation
    local state_json
    state_json=$(cat "${SUBAGENT_STATE_FILE}" 2>/dev/null) || state_json="{}"

    # Initialize delta accumulators per model
    local haiku_inp=0 haiku_out=0 haiku_cr=0 haiku_cc=0
    local sonnet_inp=0 sonnet_out=0 sonnet_cr=0 sonnet_cc=0
    local opus_inp=0 opus_out=0 opus_cr=0 opus_cc=0

    # Track file offsets to update
    local file_offsets_updates=""

    # Process each file with offset tracking
    while IFS= read -r filepath; do
        [[ -z "${filepath}" ]] && continue

        # Get stored offset for this file
        local stored_offset
        stored_offset=$(echo "$state_json" | jq -r --arg p "$filepath" '.file_offsets[$p].bytes // 0' 2>/dev/null) || stored_offset=0
        [[ "$stored_offset" == "null" ]] && stored_offset=0

        # Extract tokens from new content only
        local result_json
        result_json=$(extract_tokens_from_file_offset "$filepath" "$stored_offset")

        # Parse per-model deltas
        local h_inp h_out h_cr h_cc
        local s_inp s_out s_cr s_cc
        local o_inp o_out o_cr o_cc
        local new_offset

        h_inp=$(echo "$result_json" | jq -r '.haiku.input // 0') || h_inp=0
        h_out=$(echo "$result_json" | jq -r '.haiku.output // 0') || h_out=0
        h_cr=$(echo "$result_json" | jq -r '.haiku.cache_read // 0') || h_cr=0
        h_cc=$(echo "$result_json" | jq -r '.haiku.cache_creation // 0') || h_cc=0

        s_inp=$(echo "$result_json" | jq -r '.sonnet.input // 0') || s_inp=0
        s_out=$(echo "$result_json" | jq -r '.sonnet.output // 0') || s_out=0
        s_cr=$(echo "$result_json" | jq -r '.sonnet.cache_read // 0') || s_cr=0
        s_cc=$(echo "$result_json" | jq -r '.sonnet.cache_creation // 0') || s_cc=0

        o_inp=$(echo "$result_json" | jq -r '.opus.input // 0') || o_inp=0
        o_out=$(echo "$result_json" | jq -r '.opus.output // 0') || o_out=0
        o_cr=$(echo "$result_json" | jq -r '.opus.cache_read // 0') || o_cr=0
        o_cc=$(echo "$result_json" | jq -r '.opus.cache_creation // 0') || o_cc=0

        new_offset=$(echo "$result_json" | jq -r '.new_offset // 0') || new_offset=0

        # Accumulate deltas
        haiku_inp=$((haiku_inp + h_inp))
        haiku_out=$((haiku_out + h_out))
        haiku_cr=$((haiku_cr + h_cr))
        haiku_cc=$((haiku_cc + h_cc))

        sonnet_inp=$((sonnet_inp + s_inp))
        sonnet_out=$((sonnet_out + s_out))
        sonnet_cr=$((sonnet_cr + s_cr))
        sonnet_cc=$((sonnet_cc + s_cc))

        opus_inp=$((opus_inp + o_inp))
        opus_out=$((opus_out + o_out))
        opus_cr=$((opus_cr + o_cr))
        opus_cc=$((opus_cc + o_cc))

        # Build file offset update entry
        file_offsets_updates="${file_offsets_updates}\"${filepath}\":{\"bytes\":${new_offset},\"ts\":${current_time}},"

    done <<< "${files_to_scan}"

    # Remove trailing comma from file_offsets_updates
    file_offsets_updates="${file_offsets_updates%,}"

    # Get current totals per model from state
    local cur_haiku_inp cur_haiku_out cur_haiku_cr cur_haiku_cc
    local cur_sonnet_inp cur_sonnet_out cur_sonnet_cr cur_sonnet_cc
    local cur_opus_inp cur_opus_out cur_opus_cr cur_opus_cc

    cur_haiku_inp=$(echo "$state_json" | jq -r '.haiku.input_tokens // 0') || cur_haiku_inp=0
    cur_haiku_out=$(echo "$state_json" | jq -r '.haiku.output_tokens // 0') || cur_haiku_out=0
    cur_haiku_cr=$(echo "$state_json" | jq -r '.haiku.cache_read_tokens // 0') || cur_haiku_cr=0
    cur_haiku_cc=$(echo "$state_json" | jq -r '.haiku.cache_creation_tokens // 0') || cur_haiku_cc=0

    cur_sonnet_inp=$(echo "$state_json" | jq -r '.sonnet.input_tokens // 0') || cur_sonnet_inp=0
    cur_sonnet_out=$(echo "$state_json" | jq -r '.sonnet.output_tokens // 0') || cur_sonnet_out=0
    cur_sonnet_cr=$(echo "$state_json" | jq -r '.sonnet.cache_read_tokens // 0') || cur_sonnet_cr=0
    cur_sonnet_cc=$(echo "$state_json" | jq -r '.sonnet.cache_creation_tokens // 0') || cur_sonnet_cc=0

    cur_opus_inp=$(echo "$state_json" | jq -r '.opus.input_tokens // 0') || cur_opus_inp=0
    cur_opus_out=$(echo "$state_json" | jq -r '.opus.output_tokens // 0') || cur_opus_out=0
    cur_opus_cr=$(echo "$state_json" | jq -r '.opus.cache_read_tokens // 0') || cur_opus_cr=0
    cur_opus_cc=$(echo "$state_json" | jq -r '.opus.cache_creation_tokens // 0') || cur_opus_cc=0

    # Calculate new totals per model
    local new_haiku_inp=$((cur_haiku_inp + haiku_inp))
    local new_haiku_out=$((cur_haiku_out + haiku_out))
    local new_haiku_cr=$((cur_haiku_cr + haiku_cr))
    local new_haiku_cc=$((cur_haiku_cc + haiku_cc))

    local new_sonnet_inp=$((cur_sonnet_inp + sonnet_inp))
    local new_sonnet_out=$((cur_sonnet_out + sonnet_out))
    local new_sonnet_cr=$((cur_sonnet_cr + sonnet_cr))
    local new_sonnet_cc=$((cur_sonnet_cc + sonnet_cc))

    local new_opus_inp=$((cur_opus_inp + opus_inp))
    local new_opus_out=$((cur_opus_out + opus_out))
    local new_opus_cr=$((cur_opus_cr + opus_cr))
    local new_opus_cc=$((cur_opus_cc + opus_cc))

    # Calculate total tokens (all models)
    local total_tokens=$((
        new_haiku_inp + new_haiku_out + new_haiku_cr + new_haiku_cc +
        new_sonnet_inp + new_sonnet_out + new_sonnet_cr + new_sonnet_cc +
        new_opus_inp + new_opus_out + new_opus_cr + new_opus_cc
    ))

    # Calculate total price using per-model pricing
    local haiku_price sonnet_price opus_price total_price
    haiku_price=$(calculate_model_cost "haiku" "$new_haiku_inp" "$new_haiku_out" "$new_haiku_cr" "$new_haiku_cc")
    sonnet_price=$(calculate_model_cost "sonnet" "$new_sonnet_inp" "$new_sonnet_out" "$new_sonnet_cr" "$new_sonnet_cc")
    opus_price=$(calculate_model_cost "opus" "$new_opus_inp" "$new_opus_out" "$new_opus_cr" "$new_opus_cc")
    total_price=$(awk -v h="$haiku_price" -v s="$sonnet_price" -v o="$opus_price" 'BEGIN { printf "%.6f", h + s + o }')

    # Get existing file_offsets and merge with updates
    local existing_offsets
    existing_offsets=$(echo "$state_json" | jq -c '.file_offsets // {}') || existing_offsets="{}"

    # Write updated state with v2 schema
    local tmp_file
    tmp_file=$(mktemp)

    cat > "${tmp_file}" << EOF
{
  "schema_version": 2,
  "last_scan_timestamp": ${current_time},
  "last_cache_time": ${current_time},
  "file_offsets": ${existing_offsets},
  "haiku": {
    "input_tokens": ${new_haiku_inp},
    "output_tokens": ${new_haiku_out},
    "cache_read_tokens": ${new_haiku_cr},
    "cache_creation_tokens": ${new_haiku_cc}
  },
  "sonnet": {
    "input_tokens": ${new_sonnet_inp},
    "output_tokens": ${new_sonnet_out},
    "cache_read_tokens": ${new_sonnet_cr},
    "cache_creation_tokens": ${new_sonnet_cc}
  },
  "opus": {
    "input_tokens": ${new_opus_inp},
    "output_tokens": ${new_opus_out},
    "cache_read_tokens": ${new_opus_cr},
    "cache_creation_tokens": ${new_opus_cc}
  },
  "total_tokens": ${total_tokens},
  "total_price": ${total_price}
}
EOF

    # Merge file offset updates into state
    if [[ -n "$file_offsets_updates" ]]; then
        jq --argjson updates "{${file_offsets_updates}}" '.file_offsets = (.file_offsets + $updates)' "${tmp_file}" > "${tmp_file}.merged" && \
            mv "${tmp_file}.merged" "${tmp_file}"
    fi

    mv "${tmp_file}" "${SUBAGENT_STATE_FILE}"

    # Cleanup old offsets periodically (every ~100 scans based on randomness)
    if [[ $((RANDOM % 100)) -eq 0 ]]; then
        cleanup_old_offsets
    fi

    echo "${total_tokens}"
}

# Get breakdown of subagent tokens (input, output, cache_read, cache_creation)
# Combines all models into aggregate totals
# Usage: get_subagent_tokens_breakdown
# Returns: input output cache_read cache_creation (space separated)
get_subagent_tokens_breakdown() {
    # Ensure state is initialized and cached
    get_subagent_tokens >/dev/null

    if [[ ! -f "${SUBAGENT_STATE_FILE}" ]]; then
        echo "0 0 0 0"
        return
    fi

    # Sum across all models
    local result
    result=$(jq -r '
        ((.haiku.input_tokens // 0) + (.sonnet.input_tokens // 0) + (.opus.input_tokens // 0)) as $inp |
        ((.haiku.output_tokens // 0) + (.sonnet.output_tokens // 0) + (.opus.output_tokens // 0)) as $out |
        ((.haiku.cache_read_tokens // 0) + (.sonnet.cache_read_tokens // 0) + (.opus.cache_read_tokens // 0)) as $cr |
        ((.haiku.cache_creation_tokens // 0) + (.sonnet.cache_creation_tokens // 0) + (.opus.cache_creation_tokens // 0)) as $cc |
        "\($inp) \($out) \($cr) \($cc)"
    ' "${SUBAGENT_STATE_FILE}" 2>/dev/null) || result="0 0 0 0"

    echo "${result}"
}

# Get subagent tokens with cost (reads from state, no full rescan)
# Returns: total_tokens total_cost_usd (space separated)
get_subagent_tokens_with_cost() {
    # Update state via incremental scan (cost is calculated during scan)
    get_subagent_tokens >/dev/null

    # Read totals from state
    local total_tokens cost
    total_tokens=$(get_subagent_state_value "total_tokens")
    cost=$(get_subagent_state_value "total_price")

    [[ "${total_tokens}" == "null" ]] && total_tokens=0
    [[ "${cost}" == "null" || "${cost}" == "0" ]] && cost="0.000000"

    echo "${total_tokens} ${cost}"
}

# Get only the total cost (convenience wrapper)
# Usage: get_subagent_cost
# Returns: cost in USD (decimal)
get_subagent_cost() {
    # Update state via incremental scan
    get_subagent_tokens >/dev/null

    # Read cost from state
    local cost
    cost=$(get_subagent_state_value "total_price")
    [[ "${cost}" == "null" || "${cost}" == "0" ]] && cost="0.000000"
    echo "${cost}"
}

# Get per-model token breakdown
# Usage: get_subagent_tokens_per_model
# Returns JSON: {"haiku":{...},"sonnet":{...},"opus":{...},"total_tokens":N,"total_price":N}
get_subagent_tokens_per_model() {
    # Ensure state is initialized and cached
    get_subagent_tokens >/dev/null

    if [[ ! -f "${SUBAGENT_STATE_FILE}" ]]; then
        echo '{"haiku":{"input_tokens":0,"output_tokens":0,"cache_read_tokens":0,"cache_creation_tokens":0},"sonnet":{"input_tokens":0,"output_tokens":0,"cache_read_tokens":0,"cache_creation_tokens":0},"opus":{"input_tokens":0,"output_tokens":0,"cache_read_tokens":0,"cache_creation_tokens":0},"total_tokens":0,"total_price":0}'
        return
    fi

    jq -c '{
        haiku: .haiku,
        sonnet: .sonnet,
        opus: .opus,
        total_tokens: .total_tokens,
        total_price: .total_price
    }' "${SUBAGENT_STATE_FILE}" 2>/dev/null || \
        echo '{"haiku":{"input_tokens":0,"output_tokens":0,"cache_read_tokens":0,"cache_creation_tokens":0},"sonnet":{"input_tokens":0,"output_tokens":0,"cache_read_tokens":0,"cache_creation_tokens":0},"opus":{"input_tokens":0,"output_tokens":0,"cache_read_tokens":0,"cache_creation_tokens":0},"total_tokens":0,"total_price":0}'
}

# Reset subagent state (for testing or manual reset)
# Usage: reset_subagent_state
reset_subagent_state() {
    subagent_log "reset_subagent_state: manual reset requested"
    rm -f "${SUBAGENT_STATE_FILE}" 2>/dev/null || true
    rm -f "${SUBAGENT_TIMESTAMP_FILE}" 2>/dev/null || true
    init_subagent_state
    subagent_log "reset_subagent_state: complete"
}

# =============================================================================
# CLI interface for testing
# =============================================================================

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # Set PLUGIN_DATA_DIR if not set (for standalone execution)
    PLUGIN_DATA_DIR="${PLUGIN_DATA_DIR:-${HOME}/.claude/marcel-bich-claude-marketplace/limit}"
    SUBAGENT_STATE_FILE="${PLUGIN_DATA_DIR}/subagent-state.json"

    case "${1:-}" in
        get)
            echo "Total subagent tokens: $(get_subagent_tokens)"
            ;;
        breakdown)
            read -r inp out cache cache_creation <<< "$(get_subagent_tokens_breakdown)"
            echo "Input: ${inp}, Output: ${out}, Cache Read: ${cache}, Cache Creation: ${cache_creation}"
            ;;
        cost)
            read -r tokens cost <<< "$(get_subagent_tokens_with_cost)"
            echo "Total tokens: ${tokens}"
            echo "Total cost: \$${cost}"
            ;;
        cost-only)
            echo "$(get_subagent_cost)"
            ;;
        per-model)
            # Show per-model breakdown with costs
            get_subagent_tokens >/dev/null
            if [[ -f "${SUBAGENT_STATE_FILE}" ]]; then
                echo "=== Per-Model Token Breakdown ==="
                jq -r '
                    def fmt: if . >= 1000000 then "\(./1000000 | . * 10 | floor / 10)M"
                        elif . >= 1000 then "\(./1000 | . * 10 | floor / 10)k"
                        else "\(.)" end;

                    "Haiku:  In: \(.haiku.input_tokens | fmt)  Out: \(.haiku.output_tokens | fmt)  Cache: \(.haiku.cache_read_tokens | fmt)  Write: \(.haiku.cache_creation_tokens | fmt)",
                    "Sonnet: In: \(.sonnet.input_tokens | fmt)  Out: \(.sonnet.output_tokens | fmt)  Cache: \(.sonnet.cache_read_tokens | fmt)  Write: \(.sonnet.cache_creation_tokens | fmt)",
                    "Opus:   In: \(.opus.input_tokens | fmt)  Out: \(.opus.output_tokens | fmt)  Cache: \(.opus.cache_read_tokens | fmt)  Write: \(.opus.cache_creation_tokens | fmt)",
                    "",
                    "Total tokens: \(.total_tokens | fmt)",
                    "Total cost:   $\(.total_price | . * 100 | floor / 100)"
                ' "${SUBAGENT_STATE_FILE}"
            fi
            ;;
        cleanup)
            cleanup_old_offsets
            echo "Old file offsets cleaned up"
            local offset_count
            offset_count=$(jq '.file_offsets | length' "${SUBAGENT_STATE_FILE}" 2>/dev/null) || offset_count=0
            echo "Remaining offsets: ${offset_count}"
            ;;
        reset)
            reset_subagent_state
            echo "Subagent state reset"
            ;;
        show)
            reset_state_if_incompatible
            init_subagent_state
            jq . "${SUBAGENT_STATE_FILE}" 2>/dev/null
            ;;
        files)
            find_new_jsonl_files | head -20
            echo "..."
            echo "Total files: $(find "${CLAUDE_PROJECTS_DIR}" -name "agent-*.jsonl" -type f 2>/dev/null | wc -l)"
            ;;
        offsets)
            init_subagent_state
            local offset_count
            offset_count=$(jq '.file_offsets | length' "${SUBAGENT_STATE_FILE}" 2>/dev/null) || offset_count=0
            echo "Tracked file offsets: ${offset_count}"
            jq '.file_offsets | to_entries | .[:10] | from_entries' "${SUBAGENT_STATE_FILE}" 2>/dev/null
            if [[ "${offset_count}" -gt 10 ]]; then
                echo "... and $((offset_count - 10)) more"
            fi
            ;;
        *)
            echo "Usage: $0 <command>"
            echo ""
            echo "Commands:"
            echo "  get        Get total subagent tokens"
            echo "  breakdown  Get token breakdown (input, output, cache_read, cache_creation)"
            echo "  cost       Get tokens and cost with model-specific pricing"
            echo "  cost-only  Get only the total cost (USD)"
            echo "  per-model  Show per-model token and cost breakdown"
            echo "  cleanup    Remove old file offsets (>30 days)"
            echo "  reset      Reset subagent state"
            echo "  show       Show full state file"
            echo "  files      List new JSONL files to process"
            echo "  offsets    Show tracked file offsets"
            ;;
    esac
fi
