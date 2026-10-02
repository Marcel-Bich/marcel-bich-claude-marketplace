#!/bin/bash
# test-release - tests for scripts/changelog/release.py.
#
# Every test builds a fake repository layout in a temporary directory and runs
# release.py with --repo against it, so the real repository is never touched.
#
# Usage: scripts/changelog/test-release.sh

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RELEASE="$HERE/release.py"
TMP_BASE="$(mktemp -d "${TMPDIR:-/tmp}/test-release.XXXXXX")"
cleanup() {
    case "$TMP_BASE" in
        */test-release.??????) rm -rf -- "$TMP_BASE" ;;
    esac
}
trap cleanup EXIT

# Keep the environment from leaking a backdate into tests that do not set one.
unset GIT_COMMITTER_DATE GIT_AUTHOR_DATE RELEASE_REPO_ROOT

PASS=0
FAIL=0
REPO=""
N=0

ok() { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }

# new_repo: fresh fake repo in $REPO
new_repo() {
    N=$((N + 1))
    REPO="$TMP_BASE/repo$N"
    mkdir -p "$REPO/plugins"
}

# add_plugin NAME VERSION [JSON_VERSION]
add_plugin() {
    local name="$1" version="$2" json_version="${3:-$2}"
    mkdir -p "$REPO/plugins/$name/.claude-plugin" "$REPO/plugins/$name/changelog.d"
    printf 'name: %s\ndescription: "fake plugin"\nversion: %s\nauthor: Someone\n' "$name" "$version" \
        >"$REPO/plugins/$name/plugin.yaml"
    printf '{\n  "name": "%s",\n  "version": "%s",\n  "description": "fake plugin"\n}\n' "$name" "$json_version" \
        >"$REPO/plugins/$name/.claude-plugin/plugin.json"
}

# frag PLUGIN FILE BUMP SECTION TEXT  (simple one-section fragment)
frag() {
    printf -- '---\nbump: %s\n---\n\n### %s\n\n- %s\n' "$3" "$4" "$5" >"$REPO/plugins/$1/changelog.d/$2"
}

# raw_frag PLUGIN FILE  (content from stdin)
raw_frag() { cat >"$REPO/plugins/$1/changelog.d/$2"; }

run() { python3 "$RELEASE" --repo "$REPO" "$@"; }

yaml_version() { sed -n 's/^version: //p' "$REPO/plugins/$1/plugin.yaml"; }
json_version() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$REPO/plugins/$1/.claude-plugin/plugin.json"; }

expect_version() {
    local p="$1" want="$2" label="$3"
    if [ "$(yaml_version "$p")" = "$want" ] && [ "$(json_version "$p")" = "$want" ]; then ok; else
        fail "$label: expected $want, got yaml=$(yaml_version "$p") json=$(json_version "$p")"
    fi
}

# expect_fail LABEL PATTERN cmd...  (non-zero exit and stderr/stdout matches PATTERN)
expect_fail() {
    local label="$1" pattern="$2"
    shift 2
    local out
    if out="$("$@" 2>&1)"; then fail "$label: expected failure, got success"; return; fi
    if printf '%s' "$out" | grep -qE -- "$pattern"; then ok; else fail "$label: output did not match /$pattern/: $out"; fi
}

expect_contains() {
    local label="$1" file="$2" pattern="$3"
    if grep -qE -- "$pattern" "$file"; then ok; else fail "$label: $file lacks /$pattern/"; fi
}

expect_equal() {
    if [ "$2" = "$3" ]; then ok; else fail "$1: expected [$3], got [$2]"; fi
}

# line_of FILE EXACT_LINE  -> first line number
line_of() { grep -nxF -- "$2" "$1" | head -1 | cut -d: -f1; }

expect_before() {
    local label="$1" file="$2" a b
    a="$(line_of "$file" "$3")"
    b="$(line_of "$file" "$4")"
    if [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]; then ok; else fail "$label: '$3' ($a) not before '$4' ($b)"; fi
}

snapshot() { (cd "$REPO" && find . -type f -print0 | sort -z | xargs -0 sha256sum); }

# ------------------------------------------------------------ fragment validation

new_repo
add_plugin alpha 1.0.0
frag alpha Bad_Name.md patch Added "x"
expect_fail "bad name" "Bad_Name.md: invalid file name" run alpha --month 2026-10

new_repo
add_plugin alpha 1.0.0
printf '### Added\n\n- x\n' >"$REPO/plugins/alpha/changelog.d/no-front.md"
expect_fail "missing front matter" "no-front.md: missing front matter" run alpha --month 2026-10

new_repo
add_plugin alpha 1.0.0
frag alpha huge.md mega Added "x"
expect_fail "unknown bump" "huge.md:2: unknown bump 'mega'" run alpha --month 2026-10

new_repo
add_plugin alpha 1.0.0
frag alpha sec.md patch Improved "x"
expect_fail "unknown section" "sec.md:5: unknown section heading" run alpha --month 2026-10

new_repo
add_plugin alpha 1.0.0
raw_frag alpha before.md <<'EOF'
---
bump: patch
---
Some intro text.

### Added

- x
EOF
expect_fail "text before first section" "before.md:4: text before the first section" run alpha --month 2026-10

new_repo
add_plugin alpha 1.0.0
raw_frag alpha empty.md <<'EOF'
---
bump: patch
---

### Added

### Fixed

- y
EOF
expect_fail "empty section" "empty.md: section 'Added' is empty" run alpha --month 2026-10

new_repo
add_plugin alpha 1.0.0
expect_fail "no fragments" "no fragments to release" run alpha --month 2026-10

# invalid + valid fragment: nothing written
new_repo
add_plugin alpha 1.0.0
frag alpha good.md patch Added "fine"
frag alpha Bad.md patch Added "x"
before="$(snapshot)"
expect_fail "invalid refuses all" "Bad.md" run alpha --month 2026-10
expect_equal "invalid writes nothing" "$(snapshot)" "$before"

# valid edge forms: item-number prefix, wrapped continuation, README.md ignored
new_repo
add_plugin alpha 1.0.0
raw_frag alpha 42-wrapped-item.md <<'EOF'
---
bump: patch
---

### Changed

- first line of a long bullet
  continued here
- second bullet
EOF
printf 'not a fragment\n' >"$REPO/plugins/alpha/changelog.d/README.md"
if run alpha --month 2026-10 >/dev/null 2>&1; then ok; else fail "valid edge forms rejected"; fi
expect_contains "continuation kept" "$REPO/plugins/alpha/CHANGELOG.md" '^  continued here$'
[ -f "$REPO/plugins/alpha/changelog.d/README.md" ] && ok || fail "README.md in changelog.d must not be consumed"

# ------------------------------------------------------------ bump math

bump_case() {
    local label="$1" start="$2" want="$3"
    shift 3
    new_repo
    add_plugin alpha "$start"
    local i=0 b
    for b in "$@"; do
        i=$((i + 1))
        frag alpha "f$i.md" "$b" Added "change $i"
    done
    run alpha --month 2026-10 >/dev/null 2>&1 || { fail "$label: release failed"; return; }
    expect_version alpha "$want" "$label"
}
bump_case "patch" 1.2.3 1.2.4 patch
bump_case "minor resets patch" 1.2.3 1.3.0 minor
bump_case "major resets minor+patch" 1.2.3 2.0.0 major
bump_case "highest wins (minor)" 1.2.3 1.3.0 patch minor patch
bump_case "highest wins (major)" 0.9.9 1.0.0 patch major minor

# ------------------------------------------------------------ version sync refusal

new_repo
add_plugin alpha 1.0.0 1.0.1
frag alpha a.md patch Fixed "x"
before="$(snapshot)"
expect_fail "version files out of sync" "out of sync" run alpha --month 2026-10
expect_equal "out of sync writes nothing" "$(snapshot)" "$before"

# ------------------------------------------------------------ month resolution

month_case() {
    local label="$1" want="$2"
    shift 2
    new_repo
    add_plugin alpha 1.0.0
    frag alpha a.md patch Fixed "x"
    env "$@" python3 "$RELEASE" --repo "$REPO" alpha >/dev/null 2>&1 || { fail "$label: release failed"; return; }
    expect_contains "$label" "$REPO/plugins/alpha/CHANGELOG.md" "^# $want\$"
}
month_case "GIT_COMMITTER_DATE backdate format" 2026-09 GIT_COMMITTER_DATE="2026-09-30 21:31:05 +0200"
month_case "GIT_COMMITTER_DATE wins over AUTHOR" 2026-09 GIT_COMMITTER_DATE="2026-09-30 21:31:05 +0200" GIT_AUTHOR_DATE="2025-01-01 10:00:00 +0100"
month_case "GIT_AUTHOR_DATE" 2025-03 GIT_AUTHOR_DATE="2025-03-14 08:00:00 +0100"
month_case "ISO 8601" 2026-07 GIT_COMMITTER_DATE="2026-07-02T21:31:05+02:00"
month_case "git default format" 2026-10 GIT_COMMITTER_DATE="Fri Oct 2 21:31:05 2026 +0200"
month_case "RFC 2822" 2026-10 GIT_COMMITTER_DATE="Fri, 2 Oct 2026 21:31:05 +0200"
month_case "git internal" 2026-10 GIT_COMMITTER_DATE="@1790969465 +0200"

new_repo
add_plugin alpha 1.0.0
frag alpha a.md patch Fixed "x"
GIT_COMMITTER_DATE="2026-09-30 21:31:05 +0200" run alpha --month 2024-02 >/dev/null 2>&1
expect_contains "--month wins over env" "$REPO/plugins/alpha/CHANGELOG.md" '^# 2024-02$'

new_repo
add_plugin alpha 1.0.0
frag alpha a.md patch Fixed "x"
expect_fail "bad --month" "not a valid YYYY-MM" run alpha --month 2026-13
expect_fail "bad env date" "GIT_COMMITTER_DATE=.*not a date format" env GIT_COMMITTER_DATE="yesterday-ish" python3 "$RELEASE" --repo "$REPO" alpha

new_repo
add_plugin alpha 1.0.0
frag alpha a.md patch Fixed "x"
run alpha >/dev/null 2>&1
expect_contains "today fallback" "$REPO/plugins/alpha/CHANGELOG.md" "^# $(date +%Y-%m)\$"
if grep -qE '[0-9]{4}-[0-9]{2}-[0-9]{2}' "$REPO/plugins/alpha/CHANGELOG.md" "$REPO/CHANGELOG.md"; then
    fail "day date written into a changelog"
else ok; fi

# ------------------------------------------------------------ insertion + newest-first order

new_repo
add_plugin alpha 0.69.0
frag alpha one.md patch Added "first release"
run alpha --month 2026-10 >/dev/null 2>&1
frag alpha two.md patch Fixed "second release"
run alpha --month 2026-10 >/dev/null 2>&1
CL="$REPO/plugins/alpha/CHANGELOG.md"
expect_equal "same month: one month heading" "$(grep -c '^# 2026-10$' "$CL")" "1"
expect_equal "same month: one major heading" "$(grep -c '^## v0$' "$CL")" "1"
expect_equal "same month: one minor heading" "$(grep -c '^### v0.69$' "$CL")" "1"
expect_before "same month: newest patch on top" "$CL" "#### v0.69.2" "#### v0.69.1"
frag alpha three.md minor Added "new minor"
run alpha --month 2026-11 >/dev/null 2>&1
expect_before "new month on top" "$CL" "# 2026-11" "# 2026-10"
expect_before "new month holds new minor" "$CL" "### v0.70" "# 2026-10"
first_line="$(head -1 "$CL")"
case "$first_line" in "Changelog of the alpha plugin."*) ok ;; *) fail "intro paragraph missing: $first_line" ;; esac
expect_equal "no H1 title besides months" "$(grep -c '^# ' "$CL")" "2"
expected_tail="$(cat <<'EOF'
# 2026-11

## v0

### v0.70

#### v0.70.0

##### Added

- new minor

# 2026-10

## v0

### v0.69

#### v0.69.2

##### Fixed

- second release

#### v0.69.1

##### Added

- first release
EOF
)"
expect_equal "exact plugin layout" "$(sed -n '3,$p' "$CL")" "$expected_tail"
[ ! -e "$REPO/plugins/alpha/changelog.d/one.md" ] && [ ! -e "$REPO/plugins/alpha/changelog.d/three.md" ] && ok \
    || fail "consumed fragments not deleted"

# a minor heading may appear again under an older month; insertion under existing month
new_repo
add_plugin alpha 0.70.1
cat >"$REPO/plugins/alpha/CHANGELOG.md" <<'EOF'
Custom intro kept as is.

# 2026-10

## v0

### v0.70

#### v0.70.1

##### Fixed

- older fix

# 2026-09

## v0

### v0.70

#### v0.70.0

##### Added

- the minor
EOF
frag alpha f.md patch Fixed "newer fix"
run alpha --month 2026-10 >/dev/null 2>&1
CL="$REPO/plugins/alpha/CHANGELOG.md"
expect_equal "intro preserved" "$(head -1 "$CL")" "Custom intro kept as is."
expect_equal "minor heading in two months" "$(grep -c '^### v0.70$' "$CL")" "2"
expect_before "inserted above existing patch" "$CL" "#### v0.70.2" "#### v0.70.1"
expect_before "inserted inside existing month" "$CL" "#### v0.70.2" "# 2026-09"

# ------------------------------------------------------------ coarse history + root rendering

new_repo
add_plugin alpha 0.13.0
add_plugin beta 2.0.0
cat >"$REPO/plugins/alpha/CHANGELOG.md" <<'EOF'
Alpha intro.

# 2025-05

## v0

### v0.13

#### v0.13.0

##### Added

- thirteen

### v0.12

#### Added

- coarse twelve

#### Fixed

- coarse fix
EOF
cat >"$REPO/plugins/beta/CHANGELOG.md" <<'EOF'
Beta intro.

# 2025-05

## v2

### v2.0

#### v2.0.0

##### Changed

- beta two
EOF
if run --root >/dev/null 2>&1; then ok; else fail "--root on coarse history failed"; fi
ROOT="$REPO/CHANGELOG.md"
expect_contains "root intro says generated" "$ROOT" "generated by scripts/changelog/release.py"
expected_root="$(cat <<'EOF'
# 2025-05

## beta

### v2

#### v2.0

##### v2.0.0

###### Changed

- beta two

## alpha

### v0

#### v0.13

##### v0.13.0

###### Added

- thirteen

#### v0.12

##### Added

- coarse twelve

##### Fixed

- coarse fix
EOF
)"
expect_equal "root layout, depth and fresh ordering" "$(sed -n '3,$p' "$ROOT")" "$expected_root"
if grep -qE '^#{7,}' "$ROOT"; then fail "root heading deeper than 6"; else ok; fi

# releasing alpha in the same month moves alpha to the top; then determinism
frag alpha z.md patch Fixed "alpha later"
run alpha --month 2025-05 >/dev/null 2>&1
expect_before "released plugin first in month" "$ROOT" "## alpha" "## beta"
frag beta y.md patch Fixed "beta new month"
run beta --month 2025-06 >/dev/null 2>&1
expect_before "months descending in root" "$ROOT" "# 2025-06" "# 2025-05"
sed -n '/^# 2025-05$/,$p' "$ROOT" >"$TMP_BASE/may.md"
expect_before "older month keeps recency order" "$TMP_BASE/may.md" "## alpha" "## beta"
sum1="$(sha256sum "$ROOT")"
run --root >/dev/null 2>&1
sum2="$(sha256sum "$ROOT")"
expect_equal "determinism (--root twice)" "$sum2" "$sum1"
mv "$ROOT" "$ROOT.bak"
run --root >/dev/null 2>&1
a="$(sha256sum <"$ROOT")"
run --root >/dev/null 2>&1
b="$(sha256sum <"$ROOT")"
expect_equal "determinism (fresh regeneration)" "$b" "$a"
mv "$ROOT.bak" "$ROOT"

# root regenerated from plugin files alone is byte-identical across two separate repos
new_repo
R1="$REPO"
add_plugin alpha 1.0.0
add_plugin beta 1.0.0
frag alpha a.md minor Added "a"
frag beta b.md patch Fixed "b"
run alpha --month 2026-01 >/dev/null 2>&1
run beta --month 2026-01 >/dev/null 2>&1
new_repo
add_plugin alpha 1.0.0
add_plugin beta 1.0.0
frag alpha a.md minor Added "a"
frag beta b.md patch Fixed "b"
run alpha --month 2026-01 >/dev/null 2>&1
run beta --month 2026-01 >/dev/null 2>&1
if cmp -s "$R1/CHANGELOG.md" "$REPO/CHANGELOG.md" && cmp -s "$R1/plugins/alpha/CHANGELOG.md" "$REPO/plugins/alpha/CHANGELOG.md"; then
    ok
else fail "same input produced different output"; fi
expect_before "most recent release first (beta after alpha)" "$REPO/CHANGELOG.md" "## beta" "## alpha"

# ------------------------------------------------------------ summary + changed files

new_repo
add_plugin alpha 1.0.0
frag alpha a-first.md patch Added "Short one."
frag alpha b-second.md patch Fixed "A very long bullet text that definitely exceeds the sixty character summary limit by far"
out="$(run alpha --month 2026-10 2>&1)"
if printf '%s\n' "$out" | grep -qxF "  v1.0.1: Short one, A very long bullet text that definitely exceeds the..."; then ok; else
    fail "suggested subject wrong: $out"
fi
for f in CHANGELOG.md plugins/alpha/CHANGELOG.md plugins/alpha/plugin.yaml plugins/alpha/.claude-plugin/plugin.json \
    plugins/alpha/changelog.d/a-first.md plugins/alpha/changelog.d/b-second.md; do
    if printf '%s\n' "$out" | grep -qxF "  $f"; then ok; else fail "changed files list lacks $f"; fi
done
expect_contains "json formatting kept" "$REPO/plugins/alpha/.claude-plugin/plugin.json" '^  "version": "1.0.1",$'

# ------------------------------------------------------------ dry run

new_repo
add_plugin alpha 1.0.0
frag alpha a.md minor Added "dry"
before="$(snapshot)"
out="$(run alpha --dry-run --month 2026-10 2>&1)"
expect_equal "--dry-run writes nothing" "$(snapshot)" "$before"
if printf '%s' "$out" | grep -q "would write  plugins/alpha/CHANGELOG.md" && printf '%s' "$out" | grep -q "v1.1.0: dry"; then ok; else
    fail "--dry-run output incomplete: $out"
fi
before="$(snapshot)"
run --root --dry-run >/dev/null 2>&1
expect_equal "--root --dry-run writes nothing" "$(snapshot)" "$before"

# ------------------------------------------------------------ --check

new_repo
add_plugin alpha 1.0.0
add_plugin beta 1.0.0
add_plugin gamma 1.0.0
(
    cd "$REPO" && git init -q && git -c user.name=t -c user.email=t@example.invalid add -A \
        && git -c user.name=t -c user.email=t@example.invalid commit -qm init
)
printf 'change\n' >>"$REPO/plugins/alpha/plugin.yaml.extra"
printf 'change\n' >"$REPO/plugins/beta/new-file.txt"
frag beta b.md patch Fixed "beta has a fragment"
out="$(run --check 2>&1)"
rc=$?
expect_equal "--check passes with only warnings" "$rc" "0"
if printf '%s' "$out" | grep -q "WARNING: plugins/alpha: files changed but no fragment"; then ok; else fail "--check missing alpha warning: $out"; fi
if printf '%s' "$out" | grep -q "plugins/beta: files changed"; then fail "--check warned for beta with fragment"; else ok; fi
if printf '%s' "$out" | grep -q "plugins/gamma"; then fail "--check warned for untouched gamma"; else ok; fi
frag gamma Bad.md patch Added "x"
expect_fail "--check fails on invalid fragment" "Bad.md: invalid file name" run --check

printf '\nSummary: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
