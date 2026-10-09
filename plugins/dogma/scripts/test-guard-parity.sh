#!/usr/bin/env bash
# Parity tests of the dogma Bash guard hooks against the shared case tables in
# guard-cases/ (see test-guard-parity.py). No case command is ever executed.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 -I "$HERE/test-guard-parity.py" "$@"
