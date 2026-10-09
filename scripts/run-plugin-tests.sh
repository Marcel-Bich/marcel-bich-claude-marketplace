#!/bin/bash
# run-plugin-tests - run the plugins' own test scripts (plugins/*/scripts/test-*.sh).
#
# Usage:
#   scripts/run-plugin-tests.sh            all plugins (dogma stage "all")
#   scripts/run-plugin-tests.sh --changed  only plugins touched by uncommitted changes
#                                          or the last commit (dogma stage "relevant")
#   scripts/run-plugin-tests.sh --validate run `claude plugin validate` on every plugin
#                                          (dogma stage "build")
#
# Tests whose first lines say "Manual test" (they need a live environment) are skipped.
# Prints one line per failure and exits 1 on the first failing script; quiet on success
# apart from a summary line.

set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

case "${1:-}" in
    --validate)
        for p in plugins/*/; do
            claude plugin validate "$p" >/dev/null 2>&1 || { echo "FAIL validate $p"; exit 1; }
            # every script a hook runs directly must be committed executable
            [ -f "$p/hooks/hooks.json" ] || continue
            for s in $(grep -o '"command": *"${CLAUDE_PLUGIN_ROOT}/[^" ]*' "$p/hooks/hooks.json" | sed 's|.*${CLAUDE_PLUGIN_ROOT}/||' | sort -u); do
                mode="$(git ls-files -s "$p$s" | cut -d' ' -f1)"
                [ "$mode" = "100755" ] || { echo "FAIL not executable in git: $p$s"; exit 1; }
            done
        done
        echo "validate: all plugins OK"
        exit 0
        ;;
    --changed)
        plugins="$( { git diff --name-only HEAD; git diff --name-only HEAD~1 HEAD; } 2>/dev/null \
            | awk -F/ '/^plugins\//{print $2}' | sort -u)"
        ;;
    "")
        plugins="$(ls plugins)"
        ;;
    *)
        echo "usage: run-plugin-tests.sh [--changed|--validate]" >&2
        exit 1
        ;;
esac

# One temp root per run: every suite gets TMPDIR below it, so whatever a suite leaves
# behind is removed with it. The cleanup stops a still running suite first (its own trap
# then stops its child processes) and removes only this root.
RUN_TMP="$(mktemp -d "${TMPDIR:-/tmp}/pt.XXXXXX")" || exit 1
child=""
cleanup() {
    if [ -n "$child" ]; then kill -TERM "$child" 2>/dev/null; wait "$child" 2>/dev/null; fi
    case "$RUN_TMP" in
        "${TMPDIR:-/tmp}"/pt.??????) rm -rf -- "$RUN_TMP" ;;
        *) echo "refusing to remove unexpected temp root: '$RUN_TMP'" >&2 ;;
    esac
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

count=0
skipped=0
for p in $plugins; do
    for t in plugins/"$p"/scripts/test-*.sh; do
        [ -f "$t" ] || continue
        # manual/environment tests (header says "Manual test", e.g. a running terminal) are skipped
        if head -n 5 "$t" | grep -qi 'manual test'; then
            skipped=$((skipped + 1))
            continue
        fi
        # in the background + wait, so a signal reaches the trap at once
        TMPDIR="$RUN_TMP" bash "$t" >/dev/null 2>&1 </dev/null &
        child=$!
        wait "$child" || { child=""; echo "FAIL $t"; exit 1; }
        child=""
        count=$((count + 1))
    done
done
echo "tests: $count script(s) passed, $skipped manual skipped"
