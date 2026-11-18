#!/usr/bin/env bash
# test-windows-compat.sh - limit on a Git-Bash-like system (native Windows): no
# bc, no flock, no setsid on PATH, a bare `bash` on PATH that is NOT the running
# shell (on Windows that is System32\bash.exe, the WSL launcher), and a native
# curl that does not translate POSIX paths inside its --config file.
# Fixtures and a mock curl only: no network, no real credentials, temp dirs only.
# shellcheck disable=SC2250

set -uo pipefail

while IFS= read -r limit_var; do unset "$limit_var"; done < <(compgen -e | grep '^CLAUDE_MB_LIMIT_')

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAL_BASH="$BASH"
TEST_DIR=$(mktemp -d)
FAKE_PROFILE="limit-wincompat-$$-${RANDOM}"
SID="wincompat-session-$$"
export HOME="$TEST_DIR/home"
export CLAUDE_CONFIG_DIR="$TEST_DIR/home/$FAKE_PROFILE"
export CLAUDE_MB_LIMIT_DEBUG=false
DATA_DIR="$CLAUDE_CONFIG_DIR/marcel-bich-claude-marketplace/limit"
mkdir -p "$DATA_DIR" "$CLAUDE_CONFIG_DIR/projects/-home-myuser-acme"
CACHE="/tmp/claude-mb-limit-cache_${FAKE_PROFILE}.json"
STATUS_FILE="/tmp/claude-mb-limit-refresh-status_${FAKE_PROFILE}"
cleanup() {
    rm -rf "$TEST_DIR"
    rm -f "$CACHE" "$STATUS_FILE" "/tmp/claude-mb-limit-refresh_${FAKE_PROFILE}.lock" \
        "/tmp/claude-mb-context-cache_${SID}.json" "/tmp/claude-mb-limit-caption-${SID}" \
        "/tmp/claude-mb-limit-debug_${FAKE_PROFILE}.log" 2>/dev/null
}
trap cleanup EXIT

PASS=0
FAIL=0
check() {
    if [[ "$2" == "$3" ]]; then PASS=$((PASS + 1)); echo "  PASS: $1"
    else FAIL=$((FAIL + 1)); echo "  FAIL: $1 (expected '$2', got '$3')"; fi
}
has() { if grep -qF -- "$2" <<< "$3"; then PASS=$((PASS + 1)); echo "  PASS: $1"; else FAIL=$((FAIL + 1)); echo "  FAIL: $1 (missing '$2')"; printf '%s\n' "$3" | sed 's/^/        | /'; fi; }
hasnt() { if grep -qF -- "$2" <<< "$3"; then FAIL=$((FAIL + 1)); echo "  FAIL: $1 (unexpected '$2')"; else PASS=$((PASS + 1)); echo "  PASS: $1"; fi; }

# --- a PATH like Git Bash: everything from the current PATH except bc, flock,
# setsid; in front of it a decoy `bash` that records being called and fails, and
# the mock curl. Under real Git Bash the PATH already lacks those three tools and
# is used as is (its `ln -s` would copy files instead of linking them). ---
GB_BIN="$TEST_DIR/gitbash-bin"
mkdir -p "$GB_BIN"
BASE_PATH="$PATH"
if command -v bc >/dev/null 2>&1 || command -v flock >/dev/null 2>&1 || command -v setsid >/dev/null 2>&1; then
    BASE_BIN="$TEST_DIR/base-bin"
    mkdir -p "$BASE_BIN"
    BASE_PATH="$BASE_BIN"
    IFS=: read -r -a path_dirs <<< "$PATH"
    for d in "${path_dirs[@]}"; do
        [[ -d "$d" ]] || continue
        # Skip Windows drives (WSL /mnt/c): slow to list; the tools under test come
        # from the POSIX dirs. jq may live there (winget).
        case "$d" in /mnt/*) [[ -x "$d/jq" && ! -e "$BASE_BIN/jq" ]] && ln -s "$d/jq" "$BASE_BIN/jq"; continue ;; esac
        for f in "$d"/*; do
            n="${f##*/}"
            case "$n" in bc|flock|setsid|bash|curl) continue ;; esac
            [[ -x "$f" && ! -d "$f" && ! -e "$BASE_BIN/$n" ]] && ln -s "$f" "$BASE_BIN/$n" 2>/dev/null
        done
    done
fi
DECOY_MARK="$TEST_DIR/decoy-bash-called"
printf '#!%s\necho "called: $*" >> "%s"\nexit 1\n' "$REAL_BASH" "$DECOY_MARK" > "$GB_BIN/bash"
chmod +x "$GB_BIN/bash"

# Mock native curl: a Windows build does not map /tmp/... inside a --config file,
# so an `output = "/tmp/x"` line lands on the drive root (here: FAKE_DRIVE). A path
# given on the command line is translated by the MSYS runtime and works.
FAKE_DRIVE="$TEST_DIR/fake-drive-root"
ARGV_LOG="$TEST_DIR/curl-argv"
mkdir -p "$FAKE_DRIVE"
cat > "$GB_BIN/curl" <<EOF
#!$REAL_BASH
printf '%s\n' "\$*" >> "$ARGV_LOG"
cfg="" out=""
while [[ \$# -gt 0 ]]; do
    case "\$1" in
        --config|-K) cfg="\$2"; shift ;;
        -o|--output) out="\$2"; shift ;;
    esac
    shift
done
[[ -n "\$cfg" ]] && grep -q 'fixture-token-not-real' "\$cfg" && echo cfg-has-token >> "$ARGV_LOG.cfg"
if [[ -z "\$out" && -n "\$cfg" ]]; then
    out=\$(sed -n 's/^output = "\(.*\)"\$/\1/p' "\$cfg")
    [[ -n "\$out" ]] && { mkdir -p "$FAKE_DRIVE\$(dirname "\$out")"; out="$FAKE_DRIVE\$out"; }
fi
[[ -n "\$out" ]] && printf '%s' '{"five_hour":{"utilization":42,"resets_at":null},"seven_day":{"utilization":17,"resets_at":null}}' > "\$out"
printf '200'
EOF
chmod +x "$GB_BIN/curl"

gb() { PATH="$GB_BIN:$BASE_PATH" "$@"; }

echo ">>> the Git-Bash-like PATH really lacks bc, flock, setsid"
check "no bc" "" "$(gb "$REAL_BASH" -c 'command -v bc' 2>/dev/null)"
check "no flock" "" "$(gb "$REAL_BASH" -c 'command -v flock' 2>/dev/null)"
check "no setsid" "" "$(gb "$REAL_BASH" -c 'command -v setsid' 2>/dev/null)"

echo ">>> SI formatting without bc (same truncation as bc scale=1)"
fmt_defs="$(sed -n '/^format_highscore() {/,/^}/p' "$SCRIPT_DIR/usage-statusline.sh")
$(sed -n '/^format_number() {/,/^}/p' "$SCRIPT_DIR/show-highscores.sh")"
fmt() { # fn value -> stdout+stderr under the Git-Bash-like PATH
    gb "$REAL_BASH" -c 'source "$1/state-io.sh"; eval "$2"; "$3" "$4"' _ "$SCRIPT_DIR" "$fmt_defs" "$1" "$2" 2>&1
}
for pair in 0:0 999:999 1000:1.0k 1500:1.5k 999999:999.9k 7560000:7.5M 1999999999:1.9G \
            1500000000000:1.5T 1500000000000000:1.5P 1500000000000000000:1.5E; do
    v="${pair%%:*}"; want="${pair#*:}"
    check "format_highscore $v" "$want" "$(fmt format_highscore "$v")"
done
for pair in 0:0 999:999 1500:1.5k 1500.9:1.5k 7560000:7.5M 1500000000000000000:1.5E; do
    v="${pair%%:*}"; want="${pair#*:}"
    check "format_number $v" "$want" "$(fmt format_number "$v")"
done
check "format_number null" "n/a" "$(fmt format_number null)"
check "format_number non-numeric passes through" "abc" "$(fmt format_number abc)"

echo ">>> refresh-usage.sh without flock, with a native curl"
printf '%s' '{"claudeAiOauth":{"accessToken":"fixture-token-not-real"}}' > "$CLAUDE_CONFIG_DIR/.credentials.json"
rm -f "$CACHE"
status=$(gb "$REAL_BASH" "$SCRIPT_DIR/refresh-usage.sh" 2>&1)
check "refresh status" "refreshed" "$status"
check "cache holds the 5h figure" "42" "$(jq -r '.five_hour.utilization' "$CACHE" 2>/dev/null)"
check "cache holds the weekly figure" "17" "$(jq -r '.seven_day.utilization' "$CACHE" 2>/dev/null)"
check "no body file stranded on the drive root" "0" "$(find "$FAKE_DRIVE" -type f | wc -l | tr -d ' ')"
hasnt "token never on the curl command line" "fixture-token-not-real" "$(cat "$ARGV_LOG" 2>/dev/null)"
check "token only in the curl config file" "cfg-has-token" "$(cat "$ARGV_LOG.cfg" 2>/dev/null)"

echo ">>> statusline renders 5h and weekly without bc"
STDIN=$(jq -cn --arg sid "$SID" --arg cwd "$TEST_DIR" '{session_id: $sid, cwd: $cwd,
    model: {id: "claude-opus-5-5", display_name: "Opus 5.5"},
    context_window: {total_input_tokens: 1000, total_output_tokens: 500, context_window_size: 200000,
                     current_usage: {input_tokens: 1000, cache_read_input_tokens: 0, cache_creation_input_tokens: 0}},
    cost: {total_cost_usd: 0.5, total_duration_ms: 1000, total_api_duration_ms: 500}}')
out=$(printf '%s\n' "$STDIN" | CLAUDE_MB_LIMIT_GIT=false CLAUDE_MB_LIMIT_COLORS=false CLAUDE_MB_LIMIT_CAPTION=false \
    CLAUDE_MB_LIMIT_SCAN_SYNC=1 CLAUDE_MB_LIMIT_PRESET=enthusiast CLAUDE_MB_LIMIT_DEVICE_LABEL=box-1 \
    gb "$REAL_BASH" "$SCRIPT_DIR/usage-statusline.sh" 2>&1)
has "5h line" "5h all" "$out"
has "5h figure" "42" "$out"
has "weekly figure" "17" "$out"
hasnt "no bc error" "bc:" "$out"
hasnt "no command-not-found" "command not found" "$out"
check "context cache carries the 5h figure for the inject line" "42" \
    "$(jq -r '.five_hour_pct' "/tmp/claude-mb-context-cache_${SID}.json" 2>/dev/null)"

wait_for() { # file seconds
    local i
    for ((i = 0; i < $2 * 10; i++)); do [[ -s "$1" ]] && return 0; sleep 0.1; done
    return 1
}

echo ">>> detached ledger scan starts the running bash, not a bare 'bash' from PATH"
LEDGER_DIR_T="$TEST_DIR/ledger"
mkdir -p "$LEDGER_DIR_T"
rm -f "$DECOY_MARK"
gb "$REAL_BASH" -c '
    PLUGIN_DATA_DIR="$1"; source "$2/usage-ledger.sh"
    ledger_scan_all_detached
' _ "$LEDGER_DIR_T" "$SCRIPT_DIR" >/dev/null 2>&1
for _ in $(seq 1 100); do
    ledger_file=$(ls "$LEDGER_DIR_T"/limit-ledger_*.json 2>/dev/null | head -1)
    [[ -n "$ledger_file" ]] && break
    sleep 0.1
done
check "decoy bash not called by the ledger scan" "no" "$([[ -e "$DECOY_MARK" ]] && echo yes || echo no)"
check "detached ledger scan ran" "yes" "$([[ -n "$ledger_file" ]] && echo yes || echo no)"

echo ">>> warm statusline with setsid: detached refresh uses the running bash"
SETSID_BIN="$TEST_DIR/with-setsid"
mkdir -p "$SETSID_BIN"
real_setsid=$(command -v setsid 2>/dev/null || true)
if [[ -n "$real_setsid" ]]; then
    ln -s "$real_setsid" "$SETSID_BIN/setsid"
    rm -f "$DECOY_MARK" "$STATUS_FILE"
    printf '%s\n' "$STDIN" | PATH="$SETSID_BIN:$GB_BIN:$BASE_PATH" CLAUDE_MB_LIMIT_GIT=false CLAUDE_MB_LIMIT_COLORS=false \
        CLAUDE_MB_LIMIT_CAPTION=false CLAUDE_MB_LIMIT_SCAN_SYNC=1 "$REAL_BASH" "$SCRIPT_DIR/usage-statusline.sh" >/dev/null 2>&1
    wait_for "$STATUS_FILE" 10
    check "decoy bash not called by the detached refresh" "no" "$([[ -e "$DECOY_MARK" ]] && echo yes || echo no)"
    [[ -e "$DECOY_MARK" ]] && sed "s/^/        decoy: /" "$DECOY_MARK"
    check "detached refresh wrote its status" "fresh" "$(cut -f1 "$STATUS_FILE" 2>/dev/null)"
else
    echo "  SKIP: no setsid on this system"
fi

echo
echo "passed: $PASS failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
