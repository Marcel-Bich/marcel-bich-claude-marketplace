#!/usr/bin/env bash
# credo-agent-spawn-check.sh - credo plugin (PreToolUse hook on Agent and Task).
#
# Purpose: a fix round must run on the stage the active preset gives its attempt
# number (credo-preset.sh stage <role> <attempt>). This hook reads an Agent (or Task)
# call before it runs. When the call has no model, no effort, or a model/effort pair
# that matches no stage of any role of the active preset, it adds one non-blocking
# context line that names the stage helper and the active ladder per role. It never
# denies a call.
#
# Read-only built-ins (Explore, Plan) are checked only when the preset's explore stage
# has a model; with no explore model they are skipped.
#
# One preset read per call (credo-preset.sh show). Failure-safe: ANY problem -> exit 0
# with no output. Disable with CREDO_AGENT_SPAWN_CHECK=0.

case "${CREDO_AGENT_SPAWN_CHECK:-1}" in
    0|false|no|off) exit 0 ;;
esac
command -v jq >/dev/null 2>&1 || exit 0

INPUT=$(cat 2>/dev/null) || exit 0
[[ -n "$INPUT" ]] || exit 0

tool_name=$(printf '%s' "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null) || exit 0
case "$tool_name" in
    Agent|Task) ;;
    *) exit 0 ;;
esac

# tool_input field, "" when absent (jq prints null for a missing key)
field() {
    local v
    v=$(printf '%s' "$INPUT" | jq -r --arg k "$1" '.tool_input[$k] // ""' 2>/dev/null) || v=""
    [[ "$v" == "null" ]] && v=""
    printf '%s' "$v"
}
model=$(field model)
effort=$(field effort)
subagent=$(field subagent_type)

# Model id or alias -> the Agent tool alias (haiku, opus, sonnet); unknown -> as given.
alias_of() {
    case "$1" in
        claude-haiku-*|haiku) printf 'haiku' ;;
        claude-opus-*|opus) printf 'opus' ;;
        claude-sonnet-*|sonnet) printf 'sonnet' ;;
        *) printf '%s' "$1" ;;
    esac
}

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || exit 0
PRESET="$HOOK_DIR/../scripts/credo-preset.sh"
[[ -f "$PRESET" ]] || exit 0

show=$(bash "$PRESET" show 2>/dev/null) || exit 0

# One pass over the show output. Lines: preset <name>; stage <role> <model id>
# <effort> <attempts>; back <role>. Header and prompt lines do not match.
parsed=$(printf '%s\n' "$show" | awk '
/^preset: / { print "preset\t" $2; next }
/^(explore|build|review|hard):$/ { role = substr($0, 1, length($0) - 1); next }
/^  [0-9]+\. claude-/ {
    eff = $4
    sub(/,$/, "", eff)
    print "stage\t" role "\t" $2 "\t" eff "\t" $6
    next
}
/^  [0-9]+\. back-to-human$/ { print "back\t" role }
' 2>/dev/null) || exit 0
[[ -n "$parsed" ]] || exit 0

preset_name=""
pairs=" "
explore_model=""
declare -A ladder=()
declare -A next_attempt=()
declare -A open_chain=()
while IFS=$'\t' read -r kind a b c d; do
    case "$kind" in
        preset)
            preset_name="$a"
            ;;
        stage)
            role="$a"
            seg_alias=$(alias_of "$b")
            [[ "$role" == "explore" ]] && explore_model="$b"
            pairs+="${seg_alias}/${c} "
            [[ "${open_chain[$role]:-yes}" == "yes" ]] || continue
            start=${next_attempt[$role]:-1}
            if [[ "$d" == "until-done" ]]; then
                seg="${start}+ ${seg_alias}/${c}"
                open_chain[$role]="no"
            else
                end=$((start + d - 1))
                if (( d == 1 )); then
                    range="$start"
                else
                    range="$start-$end"
                fi
                seg="${range} ${seg_alias}/${c}"
                next_attempt[$role]=$((end + 1))
            fi
            ladder[$role]="${ladder[$role]:+${ladder[$role]}, }${seg}"
            ;;
        back)
            role="$a"
            ladder[$role]="${ladder[$role]:+${ladder[$role]}, }attempt ${next_attempt[$role]:-1} back-to-human"
            ;;
    esac
done <<< "$parsed"

# Explore and Plan: no explore model in the preset -> nothing to check against.
if [[ "$subagent" == "Explore" || "$subagent" == "Plan" ]] && [[ -z "$explore_model" ]]; then
    exit 0
fi

reasons=()
[[ -n "$model" ]] || reasons+=("no model")
[[ -n "$effort" ]] || reasons+=("no effort")
if [[ -n "$model" && -n "$effort" ]]; then
    tool_alias=$(alias_of "$model")
    case "$pairs" in
        *" ${tool_alias}/${effort} "*) ;;
        *) reasons+=("${tool_alias}/${effort} matches no stage of the preset") ;;
    esac
fi
[[ "${#reasons[@]}" -gt 0 ]] || exit 0

reason_text=""
for r in "${reasons[@]}"; do
    reason_text="${reason_text:+${reason_text}; }${r}"
done
ladder_text=""
for role in explore build review hard; do
    [[ -n "${ladder[$role]:-}" ]] || continue
    ladder_text="${ladder_text:+${ladder_text}; }${role}: ${ladder[$role]}"
done

msg="[credo-preset] Check this spawn against the active preset (${preset_name:-unknown}): ${reason_text}. Take the model and effort from the stage of the role and attempt: run credo-preset.sh stage <role> <attempt> and pass its alias as the Agent model and its effort as the Agent effort. The attempt is 1 for the first try of a role on the item and grows by one per failed try of that role. Explore and Plan calls use the explore role. Active ladder: ${ladder_text:-none}."

jq -n --arg c "$msg" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", additionalContext: $c}, suppressOutput: true}' 2>/dev/null

exit 0
