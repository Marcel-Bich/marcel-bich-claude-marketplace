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
jq_py() { # python expression over the parsed JSON on stdin (d = the object)
    python3 -c "import json,sys; d=json.load(sys.stdin); print($1)"
}

# isolated config: builtin defaults only, unless a test writes a project layer
export CREDO_GLOBAL="$TMP/global.yaml" CREDO_PROJECT="$TMP/project.yaml" CREDO_PROFILE="$TMP/profile.yaml"
unset CREDO_DIR

# RAM: MemTotal 10000000 kB, so MemAvailable in kB maps directly to the used share
mem() { printf 'MemTotal:       10000000 kB\nMemFree:          100000 kB\nMemAvailable:   %s kB\n' "$1" > "$TMP/meminfo"; }
# CPU: 8 CPUs, so the 1-min load maps to a busy share of load / 8
load() { printf '%s 1.00 1.00 1/100 12345\n' "$1" > "$TMP/loadavg"; }
export CREDO_PROC_MEMINFO="$TMP/meminfo" CREDO_PROC_LOADAVG="$TMP/loadavg" CREDO_NPROC=8
# free disk on the target drive in KB: 100 GB unless a test sets it (empty = unreadable)
export CREDO_DISK_AVAIL_KB=104857600
# no real host query in tests (a WSL machine would add its live Windows RAM and CPU)
export CREDO_HOST_MEM=off

# healthy machine: RAM 50 % used, CPU 50 % busy
mem 5000000; load 4.0
out="$("$SUT")"; rc=$?
check "healthy ok" "ok/0" "$out/$rc"
out="$("$SUT" --json)"; rc=$?
check "healthy json" "ok resources ok True/0" "$(printf '%s' "$out" | jq_py 'd["status"], d["reason"], d["checked"]')/$rc"

# RAM at the default threshold (80 %) waits, just below it passes
mem 2000000
out="$("$SUT")"; rc=$?
check "RAM at 80 percent waits" "wait:RAM used 80.0% >= 80%/5" "$out/$rc"
mem 2010000
out="$("$SUT")"; rc=$?
check "RAM at 79.9 percent ok" "ok/0" "$out/$rc"

# CPU at the default threshold (load 7.52 on 8 CPUs = 94 %) waits, just below passes
mem 5000000; load 7.52
out="$("$SUT")"; rc=$?
check "CPU at 94 percent waits" "wait:CPU busy 94.0% >= 94%/5" "$out/$rc"
load 7.44
out="$("$SUT")"; rc=$?
check "CPU at 93 percent ok" "ok/0" "$out/$rc"

# both over the threshold: two reasons in one wait line (CPU first)
mem 500000; load 16.0
out="$("$SUT")"; rc=$?
check "CPU and RAM reasons" "wait:CPU busy 200.0% >= 94%; RAM used 95.0% >= 80%/5" "$out/$rc"

# JSON on wait: percentages, thresholds and raw readings
out="$("$SUT" --json)"; rc=$?
check "json exit" 5 "$rc"
check "json fields" "wait True 94 80 200.0 95.0 16.0 8 2.0 0.48" \
    "$(printf '%s' "$out" | jq_py '" ".join(str(x) for x in (d["status"], d["checked"], d["max_busy_percent"], d["max_ram_percent"], d["cpu_busy_percent"], d["ram_used_percent"], d["load1"], d["nproc"], d["load_per_cpu"], d["mem_available_gb"]))')"
check "json drops the removed gate keys" "[]" \
    "$(printf '%s' "$out" | jq_py 'sorted(k for k in ("running", "heavy", "gate_from_agents", "min_free_ram_gb", "max_load_per_cpu") if k in d)')"

# the gate is gone: the old keys change nothing, the check always looks at CPU and RAM
printf 'resources:\n  gate_from_agents: 99\n  min_free_ram_gb: 0\n  max_load_per_cpu: 100\n' > "$CREDO_PROJECT"
mem 500000; load 1.0
out="$("$SUT")"; rc=$?
check "old gate keys ignored, RAM still checked" "wait:RAM used 95.0% >= 80%/5" "$out/$rc"
mem 5000000; load 16.0
out="$("$SUT")"; rc=$?
check "old gate keys ignored, CPU still checked" "wait:CPU busy 200.0% >= 94%/5" "$out/$rc"
printf '' > "$CREDO_PROJECT"

# thresholds from the config cascade (project layer): CPU and RAM separately
printf 'resources:\n  max_busy_percent: 60\n' > "$CREDO_PROJECT"
mem 5000000; load 5.6
out="$("$SUT")"; rc=$?
check "config CPU threshold 60 applied" "wait:CPU busy 70.0% >= 60%/5" "$out/$rc"
printf 'resources:\n  max_ram_percent: 60\n' > "$CREDO_PROJECT"
mem 3000000; load 1.0
out="$("$SUT")"; rc=$?
check "config RAM threshold 60 applied" "wait:RAM used 70.0% >= 60%/5" "$out/$rc"
printf 'resources:\n  max_busy_percent: 95\n  max_ram_percent: 95\n' > "$CREDO_PROJECT"
mem 1000000; load 7.2
out="$("$SUT")"; rc=$?
check "config thresholds 95 let 90 percent pass" "ok/0" "$out/$rc"
printf 'resources:\n  max_busy_percent: lots\n  max_ram_percent: lots\n' > "$CREDO_PROJECT"
mem 1000000; load 7.6
out="$("$SUT")"; rc=$?
check "invalid thresholds fall back to 94 and 80" "wait:CPU busy 95.0% >= 94%; RAM used 90.0% >= 80%/5" "$out/$rc"
printf 'resources:\n  max_busy_percent: 095\n  max_ram_percent: 095\n' > "$CREDO_PROJECT"
mem 1000000; load 7.2
out="$("$SUT" --json)"; rc=$?
check "leading zero threshold json" "ok 95 95/0" "$(printf '%s' "$out" | jq_py 'd["status"], d["max_busy_percent"], d["max_ram_percent"]')/$rc"
printf '' > "$CREDO_PROJECT"

# the Windows host behind WSL (CREDO_HOST_MEM fakes the powershell reading)
mem 5000000; load 1.0
out="$(CREDO_HOST_MEM="1000 150 10" "$SUT")"; rc=$?
check "host RAM at 85 percent waits" "wait:host RAM used 85.0% >= 80%/5" "$out/$rc"
out="$(CREDO_HOST_MEM="1000 300 95" "$SUT")"; rc=$?
check "host CPU at 95 percent waits" "wait:host CPU busy 95% >= 94%/5" "$out/$rc"
out="$(CREDO_HOST_MEM="1000 300 50" "$SUT")"; rc=$?
check "host at 70 percent RAM and 50 percent CPU ok" "ok/0" "$out/$rc"
out="$(CREDO_HOST_MEM="1000 300" "$SUT")"; rc=$?
check "host without a CPU value checks RAM only" "ok/0" "$out/$rc"
out="$(CREDO_HOST_MEM="garbage" "$SUT" 2>/dev/null)"; rc=$?
check "unreadable host never blocks" "ok/0" "$out/$rc"
out="$(CREDO_HOST_MEM="1000 150 10" "$SUT" --json)"; rc=$?
check "host json fields" "85.0 10" "$(printf '%s' "$out" | jq_py 'd["host_ram_used_percent"], d["host_cpu_percent"]')"
printf '' > "$CREDO_PROJECT"
mem 5000000; load 4.0

# fail-safe: unreadable /proc -> ok with stderr notes, checked false
out="$(CREDO_PROC_MEMINFO="$TMP/missing" CREDO_PROC_LOADAVG="$TMP/missing" "$SUT" 2>"$TMP/err")"; rc=$?
check "fail-safe ok" "ok/0" "$out/$rc"
check "fail-safe note" "2" "$(grep -c 'not checked' "$TMP/err")"
out="$(CREDO_PROC_MEMINFO="$TMP/missing" CREDO_PROC_LOADAVG="$TMP/missing" "$SUT" --json 2>/dev/null)"; rc=$?
check "fail-safe json" "ok False None None/0" "$(printf '%s' "$out" | jq_py 'd["status"], d["checked"], d["cpu_busy_percent"], d["ram_used_percent"]')/$rc"
printf 'MemAvailable:   100 kB\n' > "$TMP/meminfo-nototal"
out="$(CREDO_PROC_MEMINFO="$TMP/meminfo-nototal" "$SUT" 2>"$TMP/err")"; rc=$?
check "missing MemTotal never blocks" "ok/0" "$out/$rc"
check "missing MemTotal note" "1" "$(grep -c 'RAM not checked' "$TMP/err")"
out="$(CREDO_NPROC=0 "$SUT" 2>"$TMP/err")"; rc=$?
check "zero CPU count never blocks" "ok/0" "$out/$rc"
check "zero CPU count note" "1" "$(grep -c 'CPU not checked' "$TMP/err")"

# free disk: only the reserve (default 3 GB) when the item has no disk_gb
out="$(CREDO_DISK_AVAIL_KB=3145728 "$SUT")"; rc=$?
check "reserve only, exactly enough ok" "ok/0" "$out/$rc"
out="$(CREDO_DISK_AVAIL_KB=2097152 "$SUT")"; rc=$?
check "reserve only, too little waits" "wait:low free disk 2.00 GB < 3 GB reserve/5" "$out/$rc"
out="$(CREDO_DISK_AVAIL_KB=2097152 "$SUT" --json)"; rc=$?
check "json disk fields" "wait 2.0 None 3" "$(printf '%s' "$out" | jq_py 'd["status"], d["disk_free_gb"], d["disk_need_gb"], d["disk_reserve_gb"]')"

# disk_gb plus reserve must fit
out="$(CREDO_DISK_AVAIL_KB=6291456 "$SUT" --disk-gb 5)"; rc=$?
check "disk_gb 5 with 6 GB free waits" "wait:low free disk 6.00 GB < 8 GB (5 needed + 3 reserve)/5" "$out/$rc"
out="$(CREDO_DISK_AVAIL_KB=9437184 "$SUT" --disk-gb 5)"; rc=$?
check "disk_gb 5 with 9 GB free ok" "ok/0" "$out/$rc"
out="$(CREDO_DISK_AVAIL_KB=5242880 "$SUT" --disk-gb 2.5)"; rc=$?
check "decimal disk_gb 2.5 with 5 GB free waits" "wait:low free disk 5.00 GB < 5.5 GB (2.5 needed + 3 reserve)/5" "$out/$rc"

# RAM and disk reasons together, in one wait line
mem 500000
out="$(CREDO_DISK_AVAIL_KB=2097152 "$SUT")"; rc=$?
check "ram and disk reasons" "wait:RAM used 95.0% >= 80%; low free disk 2.00 GB < 3 GB reserve/5" "$out/$rc"
mem 5000000

# config: reserve from the project layer, invalid value falls back to 3
printf 'resources:\n  disk_reserve_gb: 1\n' > "$CREDO_PROJECT"
out="$(CREDO_DISK_AVAIL_KB=1572864 "$SUT")"; rc=$?
check "config disk reserve applied" "ok/0" "$out/$rc"
printf 'resources:\n  disk_reserve_gb: lots\n' > "$CREDO_PROJECT"
out="$(CREDO_DISK_AVAIL_KB=2097152 "$SUT")"; rc=$?
check "invalid disk reserve falls back to 3" "wait:low free disk 2.00 GB < 3 GB reserve/5" "$out/$rc"
printf '' > "$CREDO_PROJECT"

# fail-safe: unreadable disk (empty override, or a path df cannot read) -> ok with note
out="$(CREDO_DISK_AVAIL_KB="" "$SUT" 2>"$TMP/err")"; rc=$?
check "disk fail-safe ok" "ok/0" "$out/$rc"
check "disk fail-safe note" "1" "$(grep -c 'cannot read free disk' "$TMP/err")"
out="$(env -u CREDO_DISK_AVAIL_KB "$SUT" --path "$TMP/no-such-dir" 2>"$TMP/err")"; rc=$?
check "unknown path fail-safe ok" "ok/0" "$out/$rc"

# leading zeros in numeric inputs: no invalid JSON (strict json parse), no odd text
out="$(CREDO_DISK_AVAIL_KB=9437184 "$SUT" --disk-gb 05 --json)"; rc=$?
check "leading zeros json strict parse" "ok 5/0" "$(printf '%s' "$out" | jq_py 'd["status"], d["disk_need_gb"]')/$rc"
out="$(CREDO_DISK_AVAIL_KB=6291456 "$SUT" --disk-gb 05)"; rc=$?
check "leading zero disk_gb text" "wait:low free disk 6.00 GB < 8 GB (5 needed + 3 reserve)/5" "$out/$rc"
printf 'resources:\n  disk_reserve_gb: 03\n' > "$CREDO_PROJECT"
out="$(CREDO_DISK_AVAIL_KB=2097152 "$SUT" --json)"; rc=$?
check "leading zero reserve json" "wait 3" "$(printf '%s' "$out" | jq_py 'd["status"], d["disk_reserve_gb"]')"
out="$(CREDO_DISK_AVAIL_KB=2097152 "$SUT")"; rc=$?
check "leading zero reserve text" "wait:low free disk 2.00 GB < 3 GB reserve/5" "$out/$rc"
printf '' > "$CREDO_PROJECT"

# bad args; --running and --heavy are removed (the check always runs)
"$SUT" --running 2 >/dev/null 2>&1; check "--running removed" 1 "$?"
"$SUT" --heavy >/dev/null 2>&1; check "--heavy removed" 1 "$?"
"$SUT" --bogus >/dev/null 2>&1; check "unknown flag" 1 "$?"
"$SUT" --disk-gb x >/dev/null 2>&1; check "non-numeric --disk-gb" 1 "$?"
"$SUT" --disk-gb >/dev/null 2>&1; check "--disk-gb without value" 1 "$?"
"$SUT" --path >/dev/null 2>&1; check "--path without value" 1 "$?"

printf 'test-resource-check: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
