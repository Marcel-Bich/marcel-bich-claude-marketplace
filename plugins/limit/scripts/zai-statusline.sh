#!/bin/bash
# statusline-zai.sh - Standalone statusline for the z.ai / GLM Coding Plan profile.
#
# Mirrors the limit plugin's look and feel (same bars, colors, table layout, order),
# but does NONE of its token accounting / projects-dir scan (which would mix the
# shared .claude-work and .claude-z profiles). Everything here comes from the
# statusline stdin, env, git, or the z.ai quota endpoint. It writes ONLY ephemeral,
# session-keyed /tmp files - no shared state.
#
# Layout (matches the plugin, minus accounting-only parts):
#   cwd
#   [wt] <wt> (+X,-Y)<branch>
#   Tokens  -> Input/Output/Cached/User Tokens        (from stdin)
#   Context -> UsedT/TkLeft/CtxMax/ContextLeft         (from stdin)
#   Session -> Sessn/APIuse/SnCost  [bar] %  (try /compact)
#   <Model> | Style: <s> | Plan: <level> | Device: <host>   (LifetimeTotal dropped)
#   -
#   5h / Weekly / MCP   (from z.ai quota; replaces the Anthropic 5h/7d lines)
#   -
#   Session ID / Profile
#   Caption
#
# SECURITY: z.ai token from ANTHROPIC_AUTH_TOKEN env only; never read from a file,
# never printed.

set -uo pipefail
export LC_NUMERIC=C

INPUT=$(cat 2>/dev/null || echo '')
command -v jq   >/dev/null 2>&1 || { echo "GLM | jq missing"; exit 0; }
command -v curl >/dev/null 2>&1 || { echo "GLM | curl missing"; exit 0; }

# --- config -----------------------------------------------------------------
BASE_URL="${ANTHROPIC_BASE_URL:-}"
TOKEN="${ANTHROPIC_AUTH_TOKEN:-}"
TIMEOUT="${CLAUDE_MB_ZAI_TIMEOUT:-4}"
CACHE_FILE="/tmp/claude-mb-zai-quota.json"
CACHE_MAX_AGE="${CLAUDE_MB_ZAI_CACHE_AGE:-60}"
CTX_CACHE_ENABLED="${CLAUDE_MB_ZAI_CTX_CACHE:-true}"
AUTO_COMPACT_PCT="${CLAUDE_AUTOCOMPACT_PCT_OVERRIDE:-85}"
[[ "$AUTO_COMPACT_PCT" =~ ^[0-9]+$ ]] || AUTO_COMPACT_PCT=85
PROFILE_NAME=$(basename "${CLAUDE_CONFIG_DIR:-$HOME/.claude}")

SHOW_TOKENS="${CLAUDE_MB_LIMIT_TOKENS:-true}"
SHOW_CTX="${CLAUDE_MB_LIMIT_CTX:-true}"
SHOW_SESSION="${CLAUDE_MB_LIMIT_SESSION:-true}"
SHOW_MODEL="${CLAUDE_MB_LIMIT_MODEL:-true}"
SHOW_CWD="${CLAUDE_MB_LIMIT_CWD:-true}"
SHOW_GIT="${CLAUDE_MB_LIMIT_GIT:-true}"
SHOW_SESSION_ID="${CLAUDE_MB_LIMIT_SESSION_ID:-true}"
SHOW_PROFILE="${CLAUDE_MB_LIMIT_PROFILE:-true}"
SHOW_CAPTION="${CLAUDE_MB_LIMIT_CAPTION:-true}"
SHOW_SEPARATORS="${CLAUDE_MB_LIMIT_SEPARATORS:-true}"
DEVICE_LABEL="${CLAUDE_MB_LIMIT_DEVICE_LABEL:-$(hostname 2>/dev/null || echo unknown)}"

# --- palette (1:1 from the limit plugin) ------------------------------------
COLOR_RESET='\033[0m'; COLOR_GRAY='\033[90m'
COLOR_GREEN='\033[32m'; COLOR_YELLOW='\033[33m'; COLOR_ORANGE='\033[38;5;208m'; COLOR_RED='\033[31m'
COLOR_BLACK='\033[30m'; COLOR_BRIGHT_BLUE='\033[94m'; COLOR_BRIGHT_CYAN='\033[96m'
COLOR_SOFT_GREEN='\033[38;5;151m'; COLOR_SOFT_RED='\033[38;5;181m'
COLOR_SILVER='\033[38;5;250m'; COLOR_GOLD='\033[38;5;220m'; COLOR_SALMON='\033[38;5;210m'
BAR_FILLED='='; BAR_EMPTY='-'; BAR_WIDTH=10

get_color() {
    local pct="$1"
    [[ -z "$pct" || "$pct" == "-" ]] && { echo "$COLOR_GRAY"; return; }
    local t
    t=$(awk "BEGIN{ if($pct<30)print 0; else if($pct<50)print 1; else if($pct<75)print 2; else if($pct<90)print 3; else print 4 }")
    case "$t" in 0) echo "$COLOR_GRAY";; 1) echo "$COLOR_GREEN";; 2) echo "$COLOR_YELLOW";; 3) echo "$COLOR_ORANGE";; *) echo "$COLOR_RED";; esac
}
progress_bar() {
    local pct="${1:-0}" width="${2:-$BAR_WIDTH}"
    [[ -z "$pct" || "$pct" == "-" ]] && pct=0
    local filled empty bar=""
    filled=$(awk "BEGIN{p=$pct; if(p<0)p=0; if(p>100)p=100; printf \"%d\", int(p*$width/100+0.5)}")
    empty=$((width - filled))
    for ((i=0;i<filled;i++)); do bar+="$BAR_FILLED"; done
    for ((i=0;i<empty;i++)); do bar+="$BAR_EMPTY"; done
    echo "[$bar]"
}
parse_decimal() { local v="$1"; [[ -z "$v" || "$v" == "null" ]] && { echo ""; return; }; awk "BEGIN{printf \"%.1f\", $v}"; }

# Model color by tier slot from settings.json env (dynamic, name-independent):
# ANTHROPIC_DEFAULT_OPUS_MODEL=gold, _SONNET_MODEL=salmon, _HAIKU_MODEL=silver, else gray.
# Opus is checked first, so when opus==sonnet (same model) the highest tier wins (gold).
# Matching is case-insensitive and bidirectional-substring (display name vs raw id, e.g.
# "GLM-5.2" vs "glm-5.2[1m]"). Quoting keeps the [1m] literal, not a glob.
model_color() {
    local dn op so ha
    dn=$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')
    op=$(printf '%s' "${ANTHROPIC_DEFAULT_OPUS_MODEL:-}"   | tr '[:upper:]' '[:lower:]')
    so=$(printf '%s' "${ANTHROPIC_DEFAULT_SONNET_MODEL:-}" | tr '[:upper:]' '[:lower:]')
    ha=$(printf '%s' "${ANTHROPIC_DEFAULT_HAIKU_MODEL:-}"  | tr '[:upper:]' '[:lower:]')
    if [[ -n "$op" && ( "$dn" == "$op" || "$dn" == *"$op"* || "$op" == *"$dn"* ) ]]; then echo "$COLOR_GOLD";   return; fi
    if [[ -n "$so" && ( "$dn" == "$so" || "$dn" == *"$so"* || "$so" == *"$dn"* ) ]]; then echo "$COLOR_SALMON"; return; fi
    if [[ -n "$ha" && ( "$dn" == "$ha" || "$dn" == *"$ha"* || "$ha" == *"$dn"* ) ]]; then echo "$COLOR_SILVER"; return; fi
    # fallback (env not set / unknown model): name patterns like the plugin
    case "$dn" in
        opus*) echo "$COLOR_GOLD";; sonnet*) echo "$COLOR_SALMON";; haiku*|*air*) echo "$COLOR_SILVER";;
        glm*)  echo "$COLOR_GOLD";; *) echo "$COLOR_GRAY";;
    esac
}
format_tokens() {
    local t="${1:-0}"; [[ "$t" =~ ^[0-9]+$ ]] || { echo "0"; return; }
    if   [[ "$t" -ge 1000000000 ]]; then awk "BEGIN{printf \"%.1fG\", $t/1000000000}"
    elif [[ "$t" -ge 1000000 ]];    then awk "BEGIN{printf \"%.1fM\", $t/1000000}"
    elif [[ "$t" -ge 1000 ]];       then awk "BEGIN{printf \"%.1fk\", $t/1000}"
    else echo "$t"; fi
}
format_duration() {
    local s="${1:-}"; [[ -z "$s" || ! "$s" =~ ^[0-9]+$ ]] && { echo "-"; return; }
    local d=$((s/86400)) h=$(((s%86400)/3600)) m=$(((s%3600)/60)) sec=$((s%60))
    if   [[ $d -gt 0 ]]; then echo "${d}d${h}h"
    elif [[ $h -gt 0 ]]; then echo "${h}h${m}m"
    elif [[ $m -gt 0 ]]; then echo "${m}m"
    else echo "${sec}s"; fi
}
format_reset_datetime() {
    local ms="${1:-}"; [[ -n "$ms" && "$ms" =~ ^[0-9]+$ ]] || { echo "-"; return; }
    date -d "@$(( ms/1000 + 1800 ))" "+%Y-%m-%d %H:00" 2>/dev/null || echo "-"
}
ms_to_iso() { local ms="${1:-}"; [[ -n "$ms" && "$ms" =~ ^[0-9]+$ ]] || { echo ""; return; }; date -u -d "@$(( ms/1000 ))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo ""; }
# limit line: "<color><label><bar> <pct6>%[ reset: dt]<reset>"
format_limit_line() {
    local label="$1" pct="$2" reset_ms="${3:-}" color reset_str=""
    color=$(get_color "$pct")
    [[ -n "$reset_ms" ]] && reset_str=" reset: $(format_reset_datetime "$reset_ms")"
    printf "${color}%s %s %6s%%${reset_str}${COLOR_RESET}" "$label" "$(progress_bar "$pct")" "$pct"
}

# --- git helpers (/mnt-safe) ------------------------------------------------
get_git_worktree() {
    local g; g=$(git rev-parse --git-dir 2>/dev/null) || return 1
    [[ "$g" == ".git" || "$g" == *"/.git" ]] && { echo "main"; return; }
    [[ "$g" == *"/worktrees/"* ]] && { basename "$g"; return; }
    echo "main"
}
get_git_branch() { git branch --show-current 2>/dev/null || echo ""; }
get_git_changes() {
    local ins=0 del=0 to=7 staged uns ec
    staged=$(timeout "$to" git diff --cached --shortstat 2>/dev/null) || true
    if [[ -n "$staged" ]]; then
        local a b; a=$(echo "$staged"|grep -oE '[0-9]+ insertion'|grep -oE '[0-9]+'||echo 0); b=$(echo "$staged"|grep -oE '[0-9]+ deletion'|grep -oE '[0-9]+'||echo 0)
        ins=$((ins+${a:-0})); del=$((del+${b:-0}))
    fi
    if [[ "$PWD" == /mnt/* ]]; then uns=$(timeout 14 git -c core.checkStat=minimal diff --shortstat 2>/dev/null); ec=$?
    else uns=$(timeout "$to" git diff --shortstat 2>/dev/null); ec=$?
         [[ $ec -eq 124 ]] && { uns=$(timeout "$to" git -c core.checkStat=minimal diff --shortstat 2>/dev/null); ec=$?; }
    fi
    [[ $ec -eq 124 ]] && { local fc; fc=$(git -c core.checkStat=minimal diff --name-only 2>/dev/null|wc -l); echo "+${ins},${fc}f"; return; }
    if [[ -n "$uns" ]]; then
        local a b; a=$(echo "$uns"|grep -oE '[0-9]+ insertion'|grep -oE '[0-9]+'||echo 0); b=$(echo "$uns"|grep -oE '[0-9]+ deletion'|grep -oE '[0-9]+'||echo 0)
        ins=$((ins+${a:-0})); del=$((del+${b:-0}))
    fi
    echo "+${ins},-${del}"
}
get_session_caption() {
    local sid="$1" max_len=60
    local sn; sn=$(printf '%s' "$INPUT" | jq -r '.session_name // empty' 2>/dev/null)
    if [[ -n "$sn" && "$sn" != "null" ]]; then [[ ${#sn} -gt $max_len ]] && echo "${sn:0:$max_len}..." || echo "$sn"; return; fi
    [[ -n "$sid" ]] || return
    local cf="/tmp/claude-mb-zai-caption-${sid}"; [[ -f "$cf" ]] && { cat "$cf"; return; }
    local cd="${CLAUDE_CONFIG_DIR:-$HOME/.claude}" jf=""
    [[ -d "${cd}/projects" ]] && jf=$(find "${cd}/projects" -name "${sid}.jsonl" -print -quit 2>/dev/null)
    [[ -n "$jf" && -f "$jf" ]] || return
    local cap=""
    cap=$(grep -m1 '"custom-title"' "$jf" 2>/dev/null | jq -r '.customTitle // empty' 2>/dev/null)
    [[ -z "$cap" ]] && cap=$(grep -m1 '"type".*"summary"' "$jf" 2>/dev/null | jq -r '.summary // empty' 2>/dev/null)
    if [[ -z "$cap" ]]; then
        while IFS= read -r line; do
            local c; c=$(echo "$line"|jq -r '.message.content // empty' 2>/dev/null)
            [[ "$c" == "["* ]] && c=$(echo "$line"|jq -r '.message.content[0].text // empty' 2>/dev/null)
            if [[ -n "$c" && "$c" != "<"* ]]; then cap="$c"; break; fi
        done < <(grep '"type":"user"' "$jf" 2>/dev/null | head -10)
    fi
    if [[ -n "$cap" && "$cap" != "null" ]]; then [[ ${#cap} -gt $max_len ]] && cap="${cap:0:$max_len}..."; echo "$cap" > "$cf"; echo "$cap"; fi
}

# --- stdin --------------------------------------------------------------------
session_id=$(printf '%s' "$INPUT" | jq -r '.session_id // ""' 2>/dev/null); [[ "$session_id" == "null" ]] && session_id=""
disp_name=$(printf '%s' "$INPUT" | jq -r '.model.display_name // ""' 2>/dev/null); [[ "$disp_name" == "null" ]] && disp_name=""
model_name="${disp_name#Claude }"; [[ -n "$model_name" ]] || model_name="GLM"
style=$(printf '%s' "$INPUT" | jq -r '.output_style.name // "default"' 2>/dev/null); [[ -z "$style" || "$style" == "null" ]] && style="default"
cwd=$(printf '%s' "$INPUT" | jq -r '.cwd // ""' 2>/dev/null); [[ "$cwd" == "null" ]] && cwd=""
[[ -n "$cwd" ]] || cwd=$(pwd 2>/dev/null || echo "")

in_tok=$(printf '%s' "$INPUT" | jq -r '.context_window.total_input_tokens // 0' 2>/dev/null)
out_tok=$(printf '%s' "$INPUT" | jq -r '.context_window.total_output_tokens // 0' 2>/dev/null)
cr=$(printf '%s' "$INPUT" | jq -r '.context_window.current_usage.cache_read_input_tokens // 0' 2>/dev/null)
cc=$(printf '%s' "$INPUT" | jq -r '.context_window.current_usage.cache_creation_input_tokens // 0' 2>/dev/null)
it=$(printf '%s' "$INPUT" | jq -r '.context_window.current_usage.input_tokens // 0' 2>/dev/null)
ctx_window=$(printf '%s' "$INPUT" | jq -r '.context_window.context_window_size // 0' 2>/dev/null)
for v in in_tok out_tok cr cc it ctx_window; do [[ "${!v}" =~ ^[0-9]+$ ]] || printf -v "$v" '%s' 0; done
[[ "$ctx_window" -gt 0 ]] || ctx_window=200000
ctx_len=$(( cr + cc + it ))
total_pct=$(awk "BEGIN{printf \"%.1f\", ($ctx_len*100)/$ctx_window}")
tokens_left=$(( ctx_window - ctx_len )); [[ $tokens_left -lt 0 ]] && tokens_left=0
ctx_left_pct=$(awk "BEGIN{printf \"%.1f\", 100-$total_pct}")
usable_tokens=$(( ctx_window * AUTO_COMPACT_PCT / 100 ))
usable_pct=$(awk "BEGIN{printf \"%.1f\", ($ctx_len*100)/$usable_tokens}")
sess_secs=$(printf '%s' "$INPUT" | jq -r '.cost.total_duration_ms // empty' 2>/dev/null); [[ "$sess_secs" =~ ^[0-9]+$ ]] && sess_secs=$((sess_secs/1000)) || sess_secs=""
api_secs=$(printf '%s' "$INPUT" | jq -r '.cost.total_api_duration_ms // empty' 2>/dev/null); [[ "$api_secs" =~ ^[0-9]+$ ]] && api_secs=$((api_secs/1000)) || api_secs=""
cost=$(printf '%s' "$INPUT" | jq -r '.cost.total_cost_usd // 0' 2>/dev/null); cost=$(awk "BEGIN{printf \"%.2f\", ${cost:-0}}" 2>/dev/null || echo "0.00")

# --- z.ai quota fetch (cached) ----------------------------------------------
quota_json=""
fetch_fresh() {
    [[ -n "$TOKEN" && -n "$BASE_URL" ]] || return 1
    local host; host=$(printf '%s' "$BASE_URL" | sed -E 's#^(https?://[^/]+).*#\1#')
    curl -s --max-time "$TIMEOUT" -X GET "${host}/api/monitor/usage/quota/limit" \
        -H "Authorization: ${TOKEN}" -H "Accept-Language: en-US,en" -H "Content-Type: application/json" 2>/dev/null
}
cage=999999
if [[ -f "$CACHE_FILE" ]]; then mt=$(stat -c %Y "$CACHE_FILE" 2>/dev/null || stat -f %m "$CACHE_FILE" 2>/dev/null || echo 0); cage=$(( $(date +%s) - mt )); fi
if [[ "$cage" -lt "$CACHE_MAX_AGE" ]]; then quota_json=$(cat "$CACHE_FILE" 2>/dev/null)
else
    fresh=$(fetch_fresh)
    if printf '%s' "$fresh" | jq -e '.data.limits' >/dev/null 2>&1; then quota_json="$fresh"; printf '%s' "$fresh" > "$CACHE_FILE" 2>/dev/null || true
    elif [[ -f "$CACHE_FILE" ]]; then quota_json=$(cat "$CACHE_FILE" 2>/dev/null); fi
fi
p5=""; pw=""; pm=""; r5=""; rw=""; rm_=""; level=""
if [[ -n "$quota_json" ]]; then
    level=$(printf '%s' "$quota_json" | jq -r '.data.level // ""' 2>/dev/null); [[ "$level" == "null" ]] && level=""
    p5=$(printf '%s' "$quota_json" | jq -r '[.data.limits[]?|select(.type=="TOKENS_LIMIT" and .unit==3)][0].percentage // empty' 2>/dev/null)
    pw=$(printf '%s' "$quota_json" | jq -r '[.data.limits[]?|select(.type=="TOKENS_LIMIT" and .unit==6)][0].percentage // empty' 2>/dev/null)
    pm=$(printf '%s' "$quota_json" | jq -r '[.data.limits[]?|select(.type=="TIME_LIMIT")][0].percentage // empty' 2>/dev/null)
    r5=$(printf '%s' "$quota_json" | jq -r '[.data.limits[]?|select(.type=="TOKENS_LIMIT" and .unit==3)][0].nextResetTime // empty' 2>/dev/null)
    rw=$(printf '%s' "$quota_json" | jq -r '[.data.limits[]?|select(.type=="TOKENS_LIMIT" and .unit==6)][0].nextResetTime // empty' 2>/dev/null)
    rm_=$(printf '%s' "$quota_json" | jq -r '[.data.limits[]?|select(.type=="TIME_LIMIT")][0].nextResetTime // empty' 2>/dev/null)
    if [[ -z "$p5" && -z "$pw" ]]; then
        p5=$(printf '%s' "$quota_json" | jq -r '[.data.limits[]?|select(.type=="TOKENS_LIMIT")]|sort_by(.nextResetTime)[0].percentage // empty' 2>/dev/null)
        pw=$(printf '%s' "$quota_json" | jq -r '[.data.limits[]?|select(.type=="TOKENS_LIMIT")]|sort_by(.nextResetTime)[-1].percentage // empty' 2>/dev/null)
    fi
fi

# --- per-session context cache (keeps inject hook / compact trigger alive) --
if [[ "$CTX_CACHE_ENABLED" == "true" && -n "$session_id" ]]; then
    tmpf=$(mktemp 2>/dev/null) && {
        jq -n --arg sid "$session_id" --arg model "$model_name" \
            --argjson ctx_tokens "$ctx_len" --argjson ctx_window "$ctx_window" --argjson ctx_pct "${total_pct:-0}" \
            --arg five "${p5:-}" --arg weekly "${pw:-}" --arg five_reset "$(ms_to_iso "$r5")" --arg weekly_reset "$(ms_to_iso "$rw")" \
            --arg updated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" \
            '{session_id:$sid,model:$model,ctx_tokens:$ctx_tokens,ctx_window:$ctx_window,ctx_pct:$ctx_pct,
              five_hour_pct:(if $five=="" then null else ($five|tonumber) end),
              seven_day_pct:(if $weekly=="" then null else ($weekly|tonumber) end),
              five_hour_resets_at:(if $five_reset=="" then null else $five_reset end),
              seven_day_resets_at:(if $weekly_reset=="" then null else $weekly_reset end),
              updated_at:$updated_at}' > "$tmpf" 2>/dev/null \
        && mv -f "$tmpf" "/tmp/claude-mb-context-cache_${session_id}.json" 2>/dev/null
        rm -f "$tmpf" 2>/dev/null
    }
fi

# --- assemble lines (exact plugin order + alignment) ------------------------
lines=()
[[ -n "$cwd" && -d "$cwd" ]] && cd "$cwd" 2>/dev/null || true

# cwd
[[ "$SHOW_CWD" == "true" && -n "$cwd" ]] && lines+=("$(printf "${COLOR_GRAY}cwd: %s${COLOR_RESET}" "$cwd")")

# git
if [[ "$SHOW_GIT" == "true" ]] && git rev-parse --git-dir >/dev/null 2>&1; then
    gl=""; wt=$(get_git_worktree 2>/dev/null) || true
    [[ -n "$wt" ]] && gl="${COLOR_BRIGHT_BLUE}[wt] ${wt}${COLOR_RESET}"
    ch=$(get_git_changes); ins=$(echo "$ch"|cut -d',' -f1); del=$(echo "$ch"|cut -d',' -f2)
    chg="${COLOR_GRAY}(${COLOR_SOFT_GREEN}${ins}${COLOR_GRAY},${COLOR_SOFT_RED}${del}${COLOR_GRAY})${COLOR_RESET}"
    [[ -n "$gl" ]] && gl="${gl} ${chg}" || gl="$chg"
    br=$(get_git_branch); [[ -n "$br" ]] && gl="${gl}${COLOR_BRIGHT_CYAN}\xE2\x8E\x87 ${br}${COLOR_RESET}"
    [[ -n "$gl" ]] && lines+=("$gl")
fi

# Tokens / Context / Session table values
tok1=$(format_tokens "$in_tok"); tok2=$(format_tokens "$out_tok"); tok3=$(format_tokens "$cr"); tok4=$(format_tokens "$((in_tok+out_tok))")
ctx1=$(format_tokens "$ctx_len"); ctx2=$(format_tokens "$tokens_left"); ctx3="${total_pct}%"; ctx4="${ctx_left_pct}%"
ses1=$(format_duration "$sess_secs"); ses2=$(format_duration "$api_secs"); ses3="\$${cost}"

# column widths across the three rows
c1=${#tok1}; [[ ${#ctx1} -gt $c1 ]] && c1=${#ctx1}; [[ ${#ses1} -gt $c1 ]] && c1=${#ses1}
c2=${#tok2}; [[ ${#ctx2} -gt $c2 ]] && c2=${#ctx2}; [[ ${#ses2} -gt $c2 ]] && c2=${#ses2}
c3=${#tok3}; [[ ${#ctx3} -gt $c3 ]] && c3=${#ctx3}; [[ ${#ses3} -gt $c3 ]] && c3=${#ses3}
c4=${#tok4}; [[ ${#ctx4} -gt $c4 ]] && c4=${#ctx4}
sp_len=$(( ${#usable_pct} + 1 )); [[ $sp_len -gt $c4 ]] && c4=$sp_len

if [[ "$SHOW_TOKENS" == "true" ]]; then
    printf -v l "Tokens  -> Input: %${c1}s    Output: %${c2}s    Cached: %${c3}s    User Tokens: %${c4}s" "$tok1" "$tok2" "$tok3" "$tok4"
    lines+=("${COLOR_GRAY}${l}${COLOR_RESET}")
fi
if [[ "$SHOW_CTX" == "true" ]]; then
    printf -v l "Context -> UsedT: %${c1}s    TkLeft: %${c2}s    CtxMax: %${c3}s    ContextLeft: %${c4}s" "$ctx1" "$ctx2" "$ctx3" "$ctx4"
    lines+=("${COLOR_GRAY}${l}${COLOR_RESET}")
fi
if [[ "$SHOW_SESSION" == "true" ]]; then
    printf -v l "Session -> Sessn: %${c1}s    APIuse: %${c2}s    SnCost: %${c3}s" "$ses1" "$ses2" "$ses3"
    pct_fmt=""; printf -v pct_fmt "%${c4}s" "${usable_pct}%"
    ucol=$(get_color "${usable_pct%%.*}")
    warn=""; awk "BEGIN{exit !(${total_pct:-0} > 50)}" 2>/dev/null && warn=" ${COLOR_ORANGE}(try /compact)${COLOR_RESET}"
    lines+=("${COLOR_GRAY}${l}${COLOR_RESET}${ucol}    $(progress_bar "$usable_pct") ${pct_fmt}${COLOR_RESET}${warn}")
fi

# Model line (model | style | plan | device) - LifetimeTotal dropped
if [[ "$SHOW_MODEL" == "true" && -n "$model_name" ]]; then
    mcol=$(model_color "$model_name")
    ml="${mcol}${model_name}${COLOR_RESET}${COLOR_GRAY} | Style: ${style}"
    [[ -n "$level" ]] && ml="${ml} | Plan: ${level}"
    ml="${ml} | Device: ${DEVICE_LABEL}${COLOR_RESET}"
    lines+=("$ml")
fi

# separator
[[ "$SHOW_SEPARATORS" == "true" ]] && lines+=("$(printf "${COLOR_BLACK}-${COLOR_RESET}")")

# z.ai limits (replace the Anthropic 5h/7d block); labels padded to width 6
[[ -n "$p5" ]] && lines+=("$(format_limit_line "5h    " "$(parse_decimal "$p5")" "$r5")")
[[ -n "$pw" ]] && lines+=("$(format_limit_line "Weekly" "$(parse_decimal "$pw")" "$rw")")
[[ -n "$pm" ]] && lines+=("$(format_limit_line "MCP   " "$(parse_decimal "$pm")" "$rm_")")
[[ -z "$quota_json" ]] && lines+=("$(printf "${COLOR_GRAY}limits offline${COLOR_RESET}")")

# separator
[[ "$SHOW_SEPARATORS" == "true" ]] && lines+=("$(printf "${COLOR_BLACK}-${COLOR_RESET}")")

# Session ID / Profile
info=()
[[ "$SHOW_SESSION_ID" == "true" && -n "$session_id" ]] && info+=("Session ID: ${session_id}")
[[ "$SHOW_PROFILE" == "true" ]] && info+=("Profile: ${PROFILE_NAME}")
if [[ ${#info[@]} -gt 0 ]]; then
    il=""; f=true; for p in "${info[@]}"; do [[ "$f" == true ]] && { il="$p"; f=false; } || il="${il}    ${p}"; done
    lines+=("$(printf "${COLOR_GRAY}%s${COLOR_RESET}" "$il")")
fi

# Caption
if [[ "$SHOW_CAPTION" == "true" && -n "$session_id" ]]; then
    cap=$(get_session_caption "$session_id"); [[ -n "$cap" ]] && lines+=("$(printf "${COLOR_GRAY}Caption: %s${COLOR_RESET}" "$cap")")
fi

printf "%b\n" "$(printf '%s\n' "${lines[@]}")"
