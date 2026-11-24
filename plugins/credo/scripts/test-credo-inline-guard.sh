#!/usr/bin/env bash
# Tests for hooks/credo-inline-guard.sh + scripts/credo-inline-guard.py: oversized inline
# interpreter code and oversized browser_run_code blobs are denied with the alternative;
# short code, ordinary long commands and heredocs that are data pass; every error fails
# open. No case command is ever executed - the commands only travel in the hook input.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$HERE/../hooks/credo-inline-guard.sh"
GUARD="$HERE/credo-inline-guard.py"
HOOKS_JSON="$HERE/../hooks/hooks.json"
SID="11111111-2222-3333-4444-555555555555"

pass=0
fail=0
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
cd "$TMP" || exit 1

# Isolate the config cascade: builtin template only (guards.inline_code_max: 1500).
export CREDO_GLOBAL="$TMP/global-config"
export CREDO_PROJECT="$TMP/project-config"
export CREDO_SKIP_ENSURE=1
export CLAUDE_CONFIG_DIR="$TMP/cfg"
unset CREDO_INLINE_CODE_MAX CREDO_PROFILE CREDO_DIR
: > "$CREDO_GLOBAL"
: > "$CREDO_PROJECT"

check() { # name, want, got
    if [ "$2" = "$3" ]; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        echo "FAIL: $1 (want $2, got $3)"
    fi
}

# code <n>: n characters of python-ish code over several lines (no quotes, safe in any quoting)
code() {
    local n="$1" out=""
    while [ "${#out}" -lt "$n" ]; do
        out+="x = x + 1"$'\n'
    done
    out="${out:0:$n}"
    # $(...) drops a trailing newline: end on ";" so the size stays exact
    [ "${out: -1}" = $'\n' ] && out="${out:0:$((n - 1))};"
    printf '%s' "$out"
}
# text <n>: n characters of prose (mentions interpreters on purpose)
text() {
    local n="$1" out=""
    while [ "${#out}" -lt "$n" ]; do
        out+="fix: python3 -c and node -e (see #12) ok. "
    done
    printf '%s' "${out:0:$n}"
}

# decide <tool> <field> <value>: deny or allow for one hook call
decide() {
    local out
    out="$(jq -n --arg t "$1" --arg f "$2" --arg v "$3" --arg s "$SID" \
        '{session_id: $s, hook_event_name: "PreToolUse", tool_name: $t, tool_input: {($f): $v}, cwd: "/tmp"}' \
        | bash "$HOOK" 2>/dev/null)"
    case "$out" in
        *'"permissionDecision": "deny"'*|*'"permissionDecision":"deny"'*) echo deny ;;
        "") echo allow ;;
        *) echo "other:$out" ;;
    esac
}
bash_case() { # name want command
    check "$1" "$2" "$(decide Bash command "$3")"
}
reason_of() { # tool field value -> deny reason
    jq -n --arg t "$1" --arg f "$2" --arg v "$3" \
        '{session_id: "x", tool_name: $t, tool_input: {($f): $v}}' \
        | bash "$HOOK" 2>/dev/null | jq -r '.hookSpecificOutput.permissionDecisionReason // ""' 2>/dev/null
}

BIG="$(code 1600)"
SMALL="$(code 400)"
NL=$'\n'

# --- denied: oversized inline interpreter code ------------------------------------------
bash_case "python3 -c over the limit" deny "python3 -c \"$BIG\""
bash_case "python -c single-quoted" deny "python -c '$BIG'"
bash_case "python3.12 by path with -Ic" deny "/usr/bin/python3.12 -Ic '$BIG'"
bash_case "py -3 -c (Windows launcher)" deny "py -3 -c '$BIG'"
bash_case "python.exe by Windows path" deny "'C:\\Python312\\python.exe' -c '$BIG'"
bash_case "python3 - <<'EOF' heredoc" deny "python3 - <<'EOF'${NL}${BIG}${NL}EOF"
bash_case "python3 <<EOF heredoc (no script)" deny "python3 <<EOF${NL}${BIG}${NL}EOF"
bash_case "python3 <<-EOF heredoc with tabs" deny "python3 <<-EOF${NL}	${BIG}${NL}	EOF"
bash_case "cat <<EOF | python3" deny "cat <<'EOF' | python3${NL}${BIG}${NL}EOF"
bash_case "python3 <<< here-string" deny "python3 <<< '$BIG'"
bash_case "echo code | python3" deny "echo '$BIG' | python3"
bash_case "node -e" deny "node -e '$BIG'"
bash_case "node --eval=" deny "node --eval='$BIG'"
bash_case "node -p" deny "node -p '$BIG'"
bash_case "node - <<EOF" deny "node - <<'EOF'${NL}${BIG}${NL}EOF"
bash_case "bun -e" deny "bun -e '$BIG'"
bash_case "deno eval" deny "deno eval '$BIG'"
bash_case "perl -e" deny "perl -e '$BIG'"
bash_case "perl -lne cluster" deny "perl -lne '$BIG' file.txt"
bash_case "ruby -e" deny "ruby -e '$BIG'"
bash_case "php -r" deny "php -r '$BIG'"
bash_case "env and wrappers in front" deny "sudo -u alice env A=1 nice -n 5 timeout 30 python3 -c '$BIG'"
bash_case "taskset nice wrapper" deny "taskset -c 0-9 nice -n 19 python3 -c '$BIG'"
bash_case "assignment in front" deny "PYTHONPATH=. python3 -c '$BIG'"
bash_case "chained after cd" deny "cd /tmp && python3 -c '$BIG' && echo done"
bash_case "after a newline" deny "echo start${NL}python3 -c '$BIG'"
bash_case "inside a command substitution" deny "echo \"\$(python3 -c '$BIG')\""
bash_case "inside a subshell" deny "( cd /tmp; node -e '$BIG' )"
bash_case "redirects around it" deny "python3 -c '$BIG' > out.txt 2>&1"

# --- denied: browser_run_code -------------------------------------------------------------
check "browser_run_code over the limit" deny \
    "$(decide mcp__plugin_playwright_playwright__browser_run_code code "$BIG")"
check "browser_run_code_unsafe over the limit" deny \
    "$(decide mcp__plugin_playwright_playwright__browser_run_code_unsafe code "$BIG")"
check "other server prefix, same tool name" deny "$(decide mcp__playwright__browser_run_code code "$BIG")"

# --- deny reasons name the alternative ----------------------------------------------------
r="$(reason_of Bash command "python3 -c '$BIG'")"
case "$r" in *"Write tool"*"SEPARATE Bash call with a literal path"*) ok=yes ;; *) ok=no ;; esac
check "Bash reason: Write a script, run it separately with a literal path" yes "$ok"
case "$r" in *"1600 characters, over the limit of 1500"*) ok=yes ;; *) ok=no ;; esac
check "Bash reason: size and limit" yes "$ok"
case "$r" in *"guards.inline_code_max"*) ok=yes ;; *) ok=no ;; esac
check "Bash reason: config key named" yes "$ok"
r="$(reason_of mcp__plugin_playwright_playwright__browser_run_code code "$BIG")"
case "$r" in *"filename parameter"*) ok=yes ;; *) ok=no ;; esac
check "browser_run_code reason: filename parameter" yes "$ok"

# --- allowed: size only, short multi-line code passes ------------------------------------
bash_case "short multi-line python3 -c" allow "python3 -c '$SMALL'"
bash_case "exactly the limit passes" allow "python3 -c '$(code 1500)'"
bash_case "one over the limit is denied" deny "python3 -c '$(code 1501)'"
bash_case "short heredoc into python3" allow "python3 - <<'EOF'${NL}${SMALL}${NL}EOF"
check "short browser_run_code" allow "$(decide mcp__plugin_playwright_playwright__browser_run_code code "$SMALL")"
check "browser_run_code with filename only" allow \
    "$(decide mcp__plugin_playwright_playwright__browser_run_code filename "/tmp/check.js")"

# --- allowed: ordinary long commands (false-positive guard) ---------------------------------
LONGMSG="$(text 3000)"
bash_case "git commit -m with a long message" allow "git commit -m \"$LONGMSG\""
bash_case "git commit -m \$(cat <<EOF) message" allow \
    "git commit -m \"\$(cat <<'EOF'${NL}${LONGMSG}${NL}python3 -c 'x' :)${NL}EOF${NL})\""
bash_case "heredoc into a file" allow "cat > /tmp/tool.py <<'EOF'${NL}$(code 4000)${NL}EOF"
bash_case "heredoc into tee" allow "tee /tmp/tool.py <<'EOF' >/dev/null${NL}$(code 4000)${NL}EOF"
bash_case "heredoc as data for a python script" allow "python3 /tmp/tool.py <<'EOF'${NL}$(code 4000)${NL}EOF"
bash_case "heredoc as data for a node script" allow "node build.js <<EOF${NL}$(code 4000)${NL}EOF"
bash_case "python3 -m with a long argument" allow "python3 -m pytest -k \"$LONGMSG\""
bash_case "python3 script with long args" allow "python3 tool.py \"$LONGMSG\""
bash_case "long echo into a file" allow "echo \"$LONGMSG\" > notes.txt"
bash_case "long echo piped into a non-interpreter" allow "echo \"$LONGMSG\" | grep -c python"
bash_case "long pipe without interpreter code" allow \
    "grep -rn python3 . | sed -e 's/a/b/' | awk '{print \$1}' | sort | uniq -c | sort -rn | head -50 # $LONGMSG"
bash_case "interpreter only inside a quoted word" allow "printf '%s' \"python3 -c '$BIG'\""
bash_case "bash -c is not an interpreter here" allow "bash -c '$BIG'"
bash_case "short perl -i -pe" allow "perl -i -pe 's/a/b/' file.txt"
bash_case "npx is not inline code" allow "npx tsc --noEmit"

# --- configuration: env override, config file, off ----------------------------------------
check "env limit 100 denies 200 chars" deny \
    "$(CREDO_INLINE_CODE_MAX=100 decide Bash command "python3 -c '$(code 200)'")"
check "env limit 0 switches off" allow \
    "$(CREDO_INLINE_CODE_MAX=0 decide Bash command "python3 -c '$BIG'")"
check "env limit negative switches off" allow \
    "$(CREDO_INLINE_CODE_MAX=-1 decide Bash command "python3 -c '$BIG'")"
check "invalid env limit fails open" allow \
    "$(CREDO_INLINE_CODE_MAX=abc decide Bash command "python3 -c '$BIG'")"
printf 'guards:\n  inline_code_max: 0\n' > "$CREDO_PROJECT"
check "config 0 switches off" allow "$(decide Bash command "python3 -c '$BIG'")"
printf 'guards:\n  inline_code_max: 100\n' > "$CREDO_PROJECT"
check "config 100 denies 200 chars" deny "$(decide Bash command "python3 -c '$(code 200)'")"
check "env override beats config" allow \
    "$(CREDO_INLINE_CODE_MAX=5000 decide Bash command "python3 -c '$BIG'")"
printf 'guards:\n  inline_code_max: lots\n' > "$CREDO_PROJECT"
check "invalid config value fails open" allow "$(decide Bash command "python3 -c '$BIG'")"
: > "$CREDO_PROJECT"

# --- fail open: unknown input, parse errors, no Python ----------------------------------
out="$(printf 'not json' | bash "$HOOK" 2>/dev/null)"; rc=$?
check "garbage input: no output" "" "$out"
check "garbage input: exit 0" 0 "$rc"
out="$(printf '' | bash "$HOOK" 2>/dev/null)"; rc=$?
check "empty input: exit 0 and no output" "0:" "$rc:$out"
check "unterminated quote fails open" allow "$(decide Bash command "python3 -c \"$BIG")"
check "unknown tool with long code text" allow "$(decide Write content "python3 -c '$BIG'")"
check "Bash without a command field" allow "$(decide Bash description "python3 -c '$BIG'")"
mkdir -p "$TMP/nopy"
for tool in bash cat dirname; do
    ln -s "$(command -v "$tool")" "$TMP/nopy/$tool"
done
out="$(jq -n --arg v "python3 -c '$BIG'" '{tool_name: "Bash", tool_input: {command: $v}}' > "$TMP/in.json"
    PATH="$TMP/nopy" bash "$HOOK" < "$TMP/in.json" 2>/dev/null)"; rc=$?
check "no Python on PATH: allow, exit 0" "0:" "$rc:$out"

# --- measure mode (analysis only) ------------------------------------------------------
m="$(jq -n --arg v "python3 -c '$(code 321)'" '{tool_name: "Bash", tool_input: {command: $v}}' \
    | python3 -I "$GUARD" --measure 2>/dev/null)"
check "measure: size and interpreter" "321 python3" "$m"

# --- registration: PreToolUse matcher covers Bash and browser_run_code ------------------
matcher="$(jq -r '.hooks.PreToolUse[] | select(any(.hooks[]; .command | contains("credo-inline-guard.sh"))) | .matcher' \
    "$HOOKS_JSON" 2>/dev/null)"
check "hooks.json registers the guard once" 1 "$(printf '%s\n' "$matcher" | grep -c .)"
for tool in Bash mcp__plugin_playwright_playwright__browser_run_code \
    mcp__plugin_playwright_playwright__browser_run_code_unsafe; do
    if [[ $tool =~ ^($matcher)$ ]]; then got=yes; else got=no; fi
    check "matcher covers $tool" yes "$got"
done
for tool in Write Edit mcp__plugin_playwright_playwright__browser_click; do
    if [[ $tool =~ ^($matcher)$ ]]; then got=yes; else got=no; fi
    check "matcher skips $tool" no "$got"
done
[ -x "$HOOK" ] && got=yes || got=no
check "hook is executable" yes "$got"

echo "passed: $pass failed: $fail"
[ "$fail" -eq 0 ]
