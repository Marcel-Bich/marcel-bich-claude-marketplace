#!/usr/bin/env bash
# subagent-tokens.sh - Incremental subagent token tracking for limit plugin
# Scans ~/.claude/projects/*/subagents/agent-*.jsonl files for token usage
# Uses incremental scanning with timestamp tracking for performance
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

# =============================================================================
# Pricing Configuration (per Million Tokens)
# =============================================================================

# Input token prices per MTok
declare -A PRICE_INPUT=(
    ["opus-4-5"]=5.00
    ["sonnet-4-5"]=3.00
    ["haiku-4-5"]=1.00
    # Legacy
    ["opus-4"]=15.00
    ["opus-4-1"]=15.00
    ["sonnet-4"]=3.00
    ["haiku-4"]=1.00
    ["haiku-3"]=0.25
    # Default fallback
    ["default"]=15.00
)

# Output token prices per MTok
declare -A PRICE_OUTPUT=(
    ["opus-4-5"]=25.00
    ["sonnet-4-5"]=15.00
    ["haiku-4-5"]=5.00
    # Legacy
    ["opus-4"]=75.00
    ["opus-4-1"]=75.00
    ["sonnet-4"]=15.00
    ["haiku-4"]=5.00
    ["haiku-3"]=1.25
    # Default fallback
    ["default"]=75.00
)

# Cache pricing multipliers
CACHE_READ_MULTIPLIER=0.1      # 90% discount
CACHE_WRITE_5M_MULTIPLIER=1.25 # 25% surcharge
CACHE_WRITE_1H_MULTIPLIER=2.0  # 100% surcharge

# =============================================================================
# Model pricing helpers
# =============================================================================

# Map model ID to pricing key
# Usage: get_model_price_key "claude-haiku-4-5-20251001"
# Returns: haiku-4-5
get_model_price_key() {
    local model_id="$1"
    # Extract model name without date: claude-haiku-4-5-20251001 -> haiku-4-5
    local key
    key=$(echo "$model_id" | sed -E 's/claude-([a-z]+)-([0-9]+-[0-9]+)-[0-9]+/\1-\2/' | sed 's/-$//')
    # Fallback if not found
    if [[ -z "${PRICE_INPUT[$key]:-}" ]]; then
        key="default"
    fi
    echo "$key"
}

# Calculate cost for tokens
# Usage: calculate_token_cost <model_key> <input_tokens> <output_tokens> <cache_read_tokens> <cache_creation_tokens>
# Returns: cost in USD (decimal)
calculate_token_cost() {
    local model_key="$1"
    local input_tokens="${2:-0}"
    local output_tokens="${3:-0}"
    local cache_read_tokens="${4:-0}"
    local cache_creation_tokens="${5:-0}"

    local input_price="${PRICE_INPUT[$model_key]:-${PRICE_INPUT[default]}}"
    local output_price="${PRICE_OUTPUT[$model_key]:-${PRICE_OUTPUT[default]}}"

    # Calculate costs (prices are per MTok, so divide by 1000000)
    # Using awk for floating point math
    awk -v inp="$input_tokens" -v out="$output_tokens" \
        -v cache_r="$cache_read_tokens" -v cache_c="$cache_creation_tokens" \
        -v inp_price="$input_price" -v out_price="$output_price" \
        -v cache_r_mult="$CACHE_READ_MULTIPLIER" -v cache_c_mult="$CACHE_WRITE_5M_MULTIPLIER" \
        'BEGIN {
            mtok = 1000000
            input_cost = (inp / mtok) * inp_price
            output_cost = (out / mtok) * out_price
            cache_read_cost = (cache_r / mtok) * inp_price * cache_r_mult
            cache_creation_cost = (cache_c / mtok) * inp_price * cache_c_mult
            total = input_cost + output_cost + cache_read_cost + cache_creation_cost
            printf "%.6f", total
        }'
}

# Timestamp reference file for find -newer
SUBAGENT_TIMESTAMP_FILE="/tmp/claude-mb-limit-subagent-timestamp"

# =============================================================================
# Compaction configuration
# =============================================================================

# Compaction thresholds for processed_files array
SUBAGENT_COMPACT_THRESHOLD=500
SUBAGENT_COMPACT_COUNT=250

# =============================================================================
# State file operations
# =============================================================================

# Compact processed_files array when threshold exceeded
# Since files are tracked by mtime, we only need recent entries
# Older files will be re-scanned if modified (which is fine)
compact_processed_files() {
    if [[ ! -f "${SUBAGENT_STATE_FILE}" ]]; then
        return 0
    fi

    # Check array length
    local file_count
    file_count=$(jq '.processed_files | length' "${SUBAGENT_STATE_FILE}" 2>/dev/null) || return 0
    [[ "${file_count}" == "null" ]] && return 0

    if [[ "${file_count}" -le "${SUBAGENT_COMPACT_THRESHOLD}" ]]; then
        return 0
    fi

    # Keep only the last (newest) entries, remove oldest
    # Since we append new files, oldest are at the beginning
    local keep_count=$((file_count - SUBAGENT_COMPACT_COUNT))

    local tmp_file
    tmp_file=$(mktemp)

    jq --argjson keep "${keep_count}" '
        .processed_files = .processed_files[-$keep:]
    ' "${SUBAGENT_STATE_FILE}" > "${tmp_file}" 2>/dev/null

    if [[ $? -eq 0 ]] && [[ -s "${tmp_file}" ]]; then
        mv "${tmp_file}" "${SUBAGENT_STATE_FILE}"
    else
        rm -f "${tmp_file}" 2>/dev/null
    fi
}

# Initialize subagent state file if it does not exist
init_subagent_state() {
    local state_dir
    state_dir=$(dirname "${SUBAGENT_STATE_FILE}")

    if [[ ! -d "${state_dir}" ]]; then
        mkdir -p "${state_dir}" 2>/dev/null || true
    fi

    if [[ ! -f "${SUBAGENT_STATE_FILE}" ]]; then
        cat > "${SUBAGENT_STATE_FILE}" << 'EOF'
{
  "last_scan_timestamp": 0,
  "last_cache_time": 0,
  "processed_files": [],
  "total_input_tokens": 0,
  "total_output_tokens": 0,
  "total_cache_read_tokens": 0,
  "total_cache_creation_tokens": 0,
  "total_cost_usd": 0
}
EOF
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
# Token extraction from JSONL files
# =============================================================================

# Extract total tokens from a single JSONL file
# Usage: extract_tokens_from_file <filepath>
# Returns: input_tokens output_tokens cache_read_tokens cache_creation_tokens (space separated)
extract_tokens_from_file() {
    local filepath="${1:-}"

    if [[ ! -f "${filepath}" ]]; then
        echo "0 0 0 0"
        return
    fi

    # Use jq to sum all token values from assistant messages with usage data
    # Fields: input_tokens, output_tokens, cache_read_input_tokens, cache_creation_input_tokens
    local result
    result=$(jq -s '
        [.[] | select(.message.usage != null) | .message.usage] |
        {
            input: (map(.input_tokens // 0) | add // 0),
            output: (map(.output_tokens // 0) | add // 0),
            cache_read: (map(.cache_read_input_tokens // 0) | add // 0),
            cache_creation: (map(.cache_creation_input_tokens // 0) | add // 0)
        } |
        "\(.input) \(.output) \(.cache_read) \(.cache_creation)"
    ' "${filepath}" 2>/dev/null) || result="0 0 0 0"

    # Remove quotes if present
    result="${result//\"/}"
    echo "${result}"
}

# Extract tokens with model breakdown from a single JSONL file
# Usage: extract_tokens_with_model <filepath>
# Returns: JSON object with model-keyed token counts
extract_tokens_with_model() {
    local filepath="${1:-}"

    if [[ ! -f "${filepath}" ]]; then
        echo "{}"
        return
    fi

    # Extract tokens grouped by model
    jq -s '
        [.[] | select(.message.usage != null and .message.model != null)] |
        group_by(.message.model) |
        map({
            key: .[0].message.model,
            value: {
                input: (map(.message.usage.input_tokens // 0) | add // 0),
                output: (map(.message.usage.output_tokens // 0) | add // 0),
                cache_read: (map(.message.usage.cache_read_input_tokens // 0) | add // 0),
                cache_creation: (map(.message.usage.cache_creation_input_tokens // 0) | add // 0)
            }
        }) |
        from_entries
    ' "${filepath}" 2>/dev/null || echo "{}"
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
# Uses caching: only rescans if cache expired
# Returns: total_tokens (input + output + cache_read + cache_creation)
get_subagent_tokens() {
    # Check if projects directory exists
    if [[ ! -d "${CLAUDE_PROJECTS_DIR}" ]]; then
        echo "0"
        return
    fi

    init_subagent_state

    # Check cache: if last scan was recent, return cached value
    local last_cache_time current_time cache_age
    last_cache_time=$(get_subagent_state_value "last_cache_time")
    [[ "${last_cache_time}" == "null" ]] && last_cache_time=0
    current_time=$(date +%s)
    cache_age=$((current_time - last_cache_time))

    if [[ "${cache_age}" -lt "${SUBAGENT_CACHE_MAX_AGE}" ]]; then
        # Return cached totals
        local cached_input cached_output cached_cache_read cached_cache_creation
        cached_input=$(get_subagent_state_value "total_input_tokens")
        cached_output=$(get_subagent_state_value "total_output_tokens")
        cached_cache_read=$(get_subagent_state_value "total_cache_read_tokens")
        cached_cache_creation=$(get_subagent_state_value "total_cache_creation_tokens")
        [[ "${cached_input}" == "null" ]] && cached_input=0
        [[ "${cached_output}" == "null" ]] && cached_output=0
        [[ "${cached_cache_read}" == "null" ]] && cached_cache_read=0
        [[ "${cached_cache_creation}" == "null" ]] && cached_cache_creation=0
        echo "$((cached_input + cached_output + cached_cache_read + cached_cache_creation))"
        return
    fi

    # Find new files to process
    local new_files
    new_files=$(find_new_jsonl_files)

    # If no new files and we have cached data, return cached
    if [[ -z "${new_files}" ]]; then
        local cached_input cached_output cached_cache_read cached_cache_creation
        cached_input=$(get_subagent_state_value "total_input_tokens")
        cached_output=$(get_subagent_state_value "total_output_tokens")
        cached_cache_read=$(get_subagent_state_value "total_cache_read_tokens")
        cached_cache_creation=$(get_subagent_state_value "total_cache_creation_tokens")
        [[ "${cached_input}" == "null" ]] && cached_input=0
        [[ "${cached_output}" == "null" ]] && cached_output=0
        [[ "${cached_cache_read}" == "null" ]] && cached_cache_read=0
        [[ "${cached_cache_creation}" == "null" ]] && cached_cache_creation=0

        # Update cache time even if no new files
        local tmp_file
        tmp_file=$(mktemp)
        jq ".last_cache_time = ${current_time}" "${SUBAGENT_STATE_FILE}" > "${tmp_file}" && \
            mv "${tmp_file}" "${SUBAGENT_STATE_FILE}"

        echo "$((cached_input + cached_output + cached_cache_read + cached_cache_creation))"
        return
    fi

    # Get current totals
    local total_input total_output total_cache_read total_cache_creation
    total_input=$(get_subagent_state_value "total_input_tokens")
    total_output=$(get_subagent_state_value "total_output_tokens")
    total_cache_read=$(get_subagent_state_value "total_cache_read_tokens")
    total_cache_creation=$(get_subagent_state_value "total_cache_creation_tokens")
    [[ "${total_input}" == "null" ]] && total_input=0
    [[ "${total_output}" == "null" ]] && total_output=0
    [[ "${total_cache_read}" == "null" ]] && total_cache_read=0
    [[ "${total_cache_creation}" == "null" ]] && total_cache_creation=0

    # Read processed files for lookup
    local processed_json
    processed_json=$(jq -c '.processed_files // []' "${SUBAGENT_STATE_FILE}" 2>/dev/null) || processed_json="[]"

    # Process each new file
    local new_processed=()
    local file_input file_output file_cache file_cache_creation tokens_line

    while IFS= read -r filepath; do
        [[ -z "${filepath}" ]] && continue

        # Extract tokens from file
        tokens_line=$(extract_tokens_from_file "${filepath}")
        read -r file_input file_output file_cache file_cache_creation <<< "${tokens_line}"

        # Add to totals
        total_input=$((total_input + file_input))
        total_output=$((total_output + file_output))
        total_cache_read=$((total_cache_read + file_cache))
        total_cache_creation=$((total_cache_creation + file_cache_creation))

        # Mark file as processed
        new_processed+=("\"${filepath}\"")

    done <<< "${new_files}"

    # Build updated processed files array
    local updated_processed_json
    if [[ ${#new_processed[@]} -gt 0 ]]; then
        local new_files_json
        new_files_json=$(printf '%s\n' "${new_processed[@]}" | jq -s '.')
        updated_processed_json=$(echo "${processed_json}" | jq --argjson new "${new_files_json}" '. + $new | unique')
    else
        updated_processed_json="${processed_json}"
    fi

    # Write updated state
    cat > "${SUBAGENT_STATE_FILE}" << EOF
{
  "last_scan_timestamp": ${current_time},
  "last_cache_time": ${current_time},
  "processed_files": ${updated_processed_json},
  "total_input_tokens": ${total_input},
  "total_output_tokens": ${total_output},
  "total_cache_read_tokens": ${total_cache_read},
  "total_cache_creation_tokens": ${total_cache_creation},
  "total_cost_usd": 0
}
EOF

    # Run compaction if needed (non-blocking, runs only when threshold exceeded)
    compact_processed_files

    echo "$((total_input + total_output + total_cache_read + total_cache_creation))"
}

# Get breakdown of subagent tokens (input, output, cache_read, cache_creation)
# Usage: get_subagent_tokens_breakdown
# Returns: input output cache_read cache_creation (space separated)
get_subagent_tokens_breakdown() {
    # Ensure state is initialized and cached
    get_subagent_tokens >/dev/null

    local input output cache_read cache_creation
    input=$(get_subagent_state_value "total_input_tokens")
    output=$(get_subagent_state_value "total_output_tokens")
    cache_read=$(get_subagent_state_value "total_cache_read_tokens")
    cache_creation=$(get_subagent_state_value "total_cache_creation_tokens")
    [[ "${input}" == "null" ]] && input=0
    [[ "${output}" == "null" ]] && output=0
    [[ "${cache_read}" == "null" ]] && cache_read=0
    [[ "${cache_creation}" == "null" ]] && cache_creation=0

    echo "${input} ${output} ${cache_read} ${cache_creation}"
}

# Scan subagent files with cost calculation
# Uses model-specific pricing for accurate cost estimation
# Returns: total_tokens total_cost_usd (space separated)
get_subagent_tokens_with_cost() {
    # Check if projects directory exists
    if [[ ! -d "${CLAUDE_PROJECTS_DIR}" ]]; then
        echo "0 0.000000"
        return
    fi

    init_subagent_state

    # Check cache: if last scan was recent, return cached value
    local last_cache_time current_time cache_age
    last_cache_time=$(get_subagent_state_value "last_cache_time")
    [[ "${last_cache_time}" == "null" ]] && last_cache_time=0
    current_time=$(date +%s)
    cache_age=$((current_time - last_cache_time))

    if [[ "${cache_age}" -lt "${SUBAGENT_CACHE_MAX_AGE}" ]]; then
        # Return cached totals
        local cached_input cached_output cached_cache_read cached_cache_creation cached_cost
        cached_input=$(get_subagent_state_value "total_input_tokens")
        cached_output=$(get_subagent_state_value "total_output_tokens")
        cached_cache_read=$(get_subagent_state_value "total_cache_read_tokens")
        cached_cache_creation=$(get_subagent_state_value "total_cache_creation_tokens")
        cached_cost=$(get_subagent_state_value "total_cost_usd")
        [[ "${cached_input}" == "null" ]] && cached_input=0
        [[ "${cached_output}" == "null" ]] && cached_output=0
        [[ "${cached_cache_read}" == "null" ]] && cached_cache_read=0
        [[ "${cached_cache_creation}" == "null" ]] && cached_cache_creation=0
        [[ "${cached_cost}" == "null" || "${cached_cost}" == "0" ]] && cached_cost="0.000000"
        local total_tokens=$((cached_input + cached_output + cached_cache_read + cached_cache_creation))
        echo "${total_tokens} ${cached_cost}"
        return
    fi

    # Get all JSONL files (for cost calculation we need to scan all files with model info)
    local all_files
    all_files=$(find "${CLAUDE_PROJECTS_DIR}" -name "agent-*.jsonl" -type f 2>/dev/null)

    if [[ -z "${all_files}" ]]; then
        echo "0 0.000000"
        return
    fi

    # Accumulate tokens by model
    local total_cost="0"
    local total_input=0 total_output=0 total_cache_read=0 total_cache_creation=0

    while IFS= read -r filepath; do
        [[ -z "${filepath}" ]] && continue

        # Extract tokens grouped by model
        local model_data
        model_data=$(extract_tokens_with_model "${filepath}")

        # Process each model's tokens
        while IFS= read -r line; do
            [[ -z "${line}" || "${line}" == "{}" ]] && continue

            local model_id input output cache_read cache_creation
            model_id=$(echo "${line}" | jq -r '.key // empty')
            [[ -z "${model_id}" ]] && continue

            input=$(echo "${line}" | jq -r '.value.input // 0')
            output=$(echo "${line}" | jq -r '.value.output // 0')
            cache_read=$(echo "${line}" | jq -r '.value.cache_read // 0')
            cache_creation=$(echo "${line}" | jq -r '.value.cache_creation // 0')

            # Get pricing key for this model
            local price_key
            price_key=$(get_model_price_key "${model_id}")

            # Calculate cost for this model's tokens
            local model_cost
            model_cost=$(calculate_token_cost "${price_key}" "${input}" "${output}" "${cache_read}" "${cache_creation}")

            # Accumulate totals
            total_input=$((total_input + input))
            total_output=$((total_output + output))
            total_cache_read=$((total_cache_read + cache_read))
            total_cache_creation=$((total_cache_creation + cache_creation))
            total_cost=$(awk -v a="${total_cost}" -v b="${model_cost}" 'BEGIN { printf "%.6f", a + b }')

        done < <(echo "${model_data}" | jq -c 'to_entries[]' 2>/dev/null)

    done <<< "${all_files}"

    # Update state file with cost
    local processed_json
    processed_json=$(jq -c '.processed_files // []' "${SUBAGENT_STATE_FILE}" 2>/dev/null) || processed_json="[]"

    cat > "${SUBAGENT_STATE_FILE}" << EOF
{
  "last_scan_timestamp": ${current_time},
  "last_cache_time": ${current_time},
  "processed_files": ${processed_json},
  "total_input_tokens": ${total_input},
  "total_output_tokens": ${total_output},
  "total_cache_read_tokens": ${total_cache_read},
  "total_cache_creation_tokens": ${total_cache_creation},
  "total_cost_usd": ${total_cost}
}
EOF

    local total_tokens=$((total_input + total_output + total_cache_read + total_cache_creation))
    echo "${total_tokens} ${total_cost}"
}

# Get only the total cost (convenience wrapper)
# Usage: get_subagent_cost
# Returns: cost in USD (decimal)
get_subagent_cost() {
    local result
    result=$(get_subagent_tokens_with_cost)
    echo "${result}" | awk '{print $2}'
}

# Reset subagent state (for testing or manual reset)
# Usage: reset_subagent_state
reset_subagent_state() {
    rm -f "${SUBAGENT_STATE_FILE}" 2>/dev/null || true
    rm -f "${SUBAGENT_TIMESTAMP_FILE}" 2>/dev/null || true
    init_subagent_state
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
        reset)
            reset_subagent_state
            echo "Subagent state reset"
            ;;
        show)
            init_subagent_state
            jq . "${SUBAGENT_STATE_FILE}" 2>/dev/null
            ;;
        files)
            find_new_jsonl_files | head -20
            echo "..."
            echo "Total files: $(find "${CLAUDE_PROJECTS_DIR}" -name "agent-*.jsonl" -type f 2>/dev/null | wc -l)"
            ;;
        *)
            echo "Usage: $0 <command>"
            echo ""
            echo "Commands:"
            echo "  get        Get total subagent tokens"
            echo "  breakdown  Get token breakdown (input, output, cache_read, cache_creation)"
            echo "  cost       Get tokens and cost with model-specific pricing"
            echo "  cost-only  Get only the total cost (USD)"
            echo "  reset      Reset subagent state"
            echo "  show       Show full state file"
            echo "  files      List new JSONL files to process"
            ;;
    esac
fi
