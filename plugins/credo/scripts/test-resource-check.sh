#!/bin/bash
# Tests for credo-resource-check.sh. Fakes /proc values via CREDO_PROC_MEMINFO /
# CREDO_PROC_LOADAVG / CREDO_NPROC and isolates the config cascade in a temp dir
# (removed on exit). Usage: bash test-resource-check.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="$SCRIPT_DIR/credo-resource-check.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/credo-resource-test.XXXXXX")"
trap 'rm -rf -- "$TMP"' EXIT

PASS=0
FAIL=0
check() { # name expected actual
    if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"; fi
}

# isolated config: builtin defaults only, unless a test writes a project layer
export CREDO_GLOBAL="$TMP/global.yaml" CREDO_PROJECT="$TMP/project.yaml" CREDO_PROFILE="$TMP/profile.yaml"
unset CREDO_DIR

mem() { printf 'MemTotal:       32000000 kB\nMemAvailable:   %s kB\n' "$1" > "$TMP/meminfo"; }
load() { printf '%s 1.00 1.00 1/100 12345\n' "$1" > "$TMP/loadavg"; }
export CREDO_PROC_MEMINFO="$TMP/meminfo" CREDO_PROC_LOADAVG="$TMP/loadavg" CREDO_NPROC=8

# plenty of RAM (16 GB), low load (0.5 per CPU)
mem 16777216; load 4.0
out="$("$SUT" --running 2)"; rc=$?
check "below gate ok" "ok/0" "$out/$rc"
out="$("$SUT" --running 6)"; rc=$?
check "at gate, healthy ok" "ok/0" "$out/$rc"

# low RAM (2 GB), below the gate: no check -> ok
mem 2097152
out="$("$SUT" --running 5)"; rc=$?
check "below gate skips check" "ok/0" "$out/$rc"
out="$("$SUT" --running 6)"; rc=$?
check "at gate low RAM waits" "wait:low free RAM 2.00 GB < 4 GB/5" "$out/$rc"
out="$("$SUT" --running 0 --heavy)"; rc=$?
check "heavy always checked" "wait:low free RAM 2.00 GB < 4 GB/5" "$out/$rc"

# high load (2.0 per CPU) + low RAM
load 16.0
out="$("$SUT" --running 7)"; rc=$?
check "two reasons" "wait:low free RAM 2.00 GB < 4 GB; high load 2.00 per CPU > 1.0/5" "$out/$rc"

# JSON
out="$("$SUT" --running 7 --json)"; rc=$?
check "json exit" 5 "$rc"
check "json parses" "wait True 2.0" "$(printf '%s' "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["status"], d["checked"], d["load_per_cpu"])')"
out="$("$SUT" --running 1 --json)"; rc=$?
check "json below gate" "ok False" "$(printf '%s' "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["status"], d["checked"])')"

# config overrides via the project layer
printf 'resources:\n  gate_from_agents: 2\n  min_free_ram_gb: 1\n  max_load_per_cpu: 3\n' > "$CREDO_PROJECT"
out="$("$SUT" --running 2)"; rc=$?
check "config thresholds applied" "ok/0" "$out/$rc"
printf 'resources:\n  gate_from_agents: 2\n  min_free_ram_gb: 8\n' > "$CREDO_PROJECT"
out="$("$SUT" --running 2)"; rc=$?
check "config gate lowered" "wait:low free RAM 2.00 GB < 8 GB; high load 2.00 per CPU > 1.0/5" "$out/$rc"
out="$("$SUT" --running 1)"; rc=$?
check "below lowered gate" "ok/0" "$out/$rc"
printf 'resources:\n  min_free_ram_gb: lots\n' > "$CREDO_PROJECT"
mem 16777216; load 1.0
out="$("$SUT" --running 9)"; rc=$?
check "invalid config falls back" "ok/0" "$out/$rc"
printf '' > "$CREDO_PROJECT"

# fail-safe: unreadable /proc -> ok with stderr note
out="$(CREDO_PROC_MEMINFO="$TMP/missing" CREDO_PROC_LOADAVG="$TMP/missing" "$SUT" --running 9 2>"$TMP/err")"; rc=$?
check "fail-safe ok" "ok/0" "$out/$rc"
check "fail-safe note" "2" "$(grep -c 'not checked' "$TMP/err")"

# bad args
"$SUT" >/dev/null 2>&1; check "missing --running" 1 "$?"
"$SUT" --running x >/dev/null 2>&1; check "non-numeric --running" 1 "$?"
"$SUT" --running 1 --bogus >/dev/null 2>&1; check "unknown flag" 1 "$?"

printf 'test-resource-check: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
