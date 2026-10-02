#!/bin/bash
# source-cache - read the NOTICES.md broadcasts of the user's dogma source
# (CLAUDE_MB_DOGMA_SOURCE) through a cached clone that is refreshed at most once a day.
# Read-only towards every repo; it only writes its own cache/state.
#
# Source (CLAUDE_MB_DOGMA_SOURCE):
#   URL   https://..., http://..., ssh://..., git://..., file://..., or scp-like
#         [user@]host:path (incl. SSH host aliases like git@github-work:owner/repo.git)
#         -> shallow clone under <cache>/repo, `git fetch` when the last check is
#            older than 24h
#   path  /abs/path or ~/path -> read directly, never cloned
#   unset -> nothing (exit 4); dogma has no implicit default here
#
# Cache/state per profile, source and git identity:
#   ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/dogma/source-cache/<key>/
#     repo/        shallow clone (URL sources only)
#     last-check   epoch seconds of the last fetch attempt (success or failure)
#     status       ok | fail
#     hint-shown   epoch seconds of the last "not reachable" hint
#   key = first 16 hex chars of sha256(source string [+ identity routing])
#
# Identity routing: git picks an account per folder (includeIf gitdir, per-account
# url.<alias>.insteadOf, core.sshCommand with its own key). Those rules do not match
# the cache dir, so the url.*.insteadOf and core.sshCommand values of the CURRENT
# repo (cwd) are passed to the cache git via GIT_CONFIG_COUNT/KEY/VALUE (never
# printed; credential helpers and other keys are not copied). Each identity gets
# its own clone, daily throttle and hint.
#
# Fetches never prompt and never hang: timeout 15s, GIT_TERMINAL_PROMPT=0, empty
# askpass, credential.interactive=never, ssh BatchMode=yes; git hooks are off in
# the cache clone. The user's normal git configuration (credential helpers, ssh config, host aliases) is used as is.
#
# Usage:
#   source-cache.sh dir                print the local dir with the source content
#   source-cache.sh state-dir          print the cache/state dir of (source, identity)
#   source-cache.sh refresh [--force]  fetch now when due (or always with --force)
#   source-cache.sh notices            NOTICES.md entries within the max age, one TSV
#                                      line each: id, action, date, text
#   source-cache.sh hint               print the "not reachable" hint, at most once a
#                                      day per source (records that it was shown)
#
# ENV: CLAUDE_MB_DOGMA_SOURCE                 the source (see above)
# ENV: CLAUDE_MB_DOGMA_NOTICES_MAX_AGE_DAYS   skip entries older than this (default 90, 0 = no limit)
# ENV: CLAUDE_MB_DOGMA_SOURCE_FETCH           background (default) | sync | off - how `dir` and
#                                             `notices` refresh a stale cache
#
# Exit codes: 0 = done / printed, 4 = nothing (no source, no cache, nothing to show,
# error), 1 = bad argument. Never prompts.

SOURCE="${CLAUDE_MB_DOGMA_SOURCE:-}"
STATE_ROOT="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/dogma/source-cache"
DAY=86400
FETCH_TIMEOUT=15

# --- helpers ---

sha256_hex() {
    if command -v sha256sum >/dev/null 2>&1; then
        printf '%s' "$1" | sha256sum | cut -c1-64
    elif command -v shasum >/dev/null 2>&1; then
        printf '%s' "$1" | shasum -a 256 | cut -c1-64
    elif command -v python3 >/dev/null 2>&1; then
        printf '%s' "$1" | python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())'
    else
        return 1
    fi
}

now() { date +%s; }

# file content as an integer, 0 when missing or garbage
read_epoch() {
    local v
    v="$(cat "$1" 2>/dev/null)"
    case "$v" in
        ''|*[!0-9]*) echo 0 ;;
        *) echo "$v" ;;
    esac
}

# url | path | invalid
source_kind() {
    case "$1" in
        *://*) echo url ;;
        /*|\~|\~/*) echo path ;;
        *) case "${1%%/*}" in
               *:*) echo url ;;   # scp-like [user@]host:path, colon before the first slash
               *) echo invalid ;;
           esac ;;
    esac
}

# the source for messages: userinfo of scheme URLs removed, so nothing secret is echoed
display_source() {
    case "$1" in
        *://*@*)
            local scheme="${1%%://*}" rest="${1#*://}"
            local auth="${rest%%/*}"
            case "$auth" in
                *@*) echo "${scheme}://${auth##*@}${rest#"$auth"}" ;;
                *) echo "$1" ;;
            esac
            ;;
        *) echo "$1" ;;
    esac
}

local_path() {
    local p="$1"
    case "$p" in
        \~) p="$HOME" ;;
        \~/*) p="$HOME/${p#\~/}" ;;
    esac
    printf '%s' "$p"
}

# Identity routing of the CURRENT repo (the cwd): folder-based git rules (includeIf
# gitdir, per-account url.<alias>.insteadOf, core.sshCommand with a per-account key)
# do not apply inside the cache dir, so these keys - and only these - are read from
# the current repo's effective config and handed to the cache git via
# GIT_CONFIG_COUNT/KEY/VALUE. Never printed; credential.* and anything else is ignored.
ID_KEYS=()
ID_VALUES=()
ID_SSH=""
load_identity() {
    local top entry key value
    top="$(git rev-parse --show-toplevel 2>/dev/null)" || return 0
    [ -n "$top" ] || return 0
    while IFS= read -r -d '' entry; do
        key="${entry%%$'\n'*}"
        value=""
        [ "$key" != "$entry" ] && value="${entry#*$'\n'}"
        case "$key" in
            core.sshcommand) ID_SSH="$value" ;;
            url.*.insteadof) ID_KEYS+=("$key"); ID_VALUES+=("$value") ;;
        esac
    done < <(git -C "$top" config --null --get-regexp '^(url\..*\.insteadof|core\.sshcommand)$' 2>/dev/null)
}

# stable text of the identity routing, for the state key (empty without any)
identity_text() {
    local i
    {
        [ -n "$ID_SSH" ] && printf 'core.sshcommand=%s\n' "$ID_SSH"
        for i in "${!ID_KEYS[@]}"; do
            printf '%s=%s\n' "${ID_KEYS[$i]}" "${ID_VALUES[$i]}"
        done
    } | LC_ALL=C sort
}

# git without any chance of an interactive prompt, with the identity routing above
quiet_git() {
    local ssh_cmd="${GIT_SSH_COMMAND:-}"
    [ -n "$ssh_cmd" ] || ssh_cmd="$ID_SSH"
    [ -n "$ssh_cmd" ] || ssh_cmd="ssh"
    local runner=()
    command -v timeout >/dev/null 2>&1 && runner=(timeout -k 2 "$FETCH_TIMEOUT")
    local n="${GIT_CONFIG_COUNT:-0}" i cfg_env=()
    case "$n" in ''|*[!0-9]*) n=0 ;; esac
    for i in "${!ID_KEYS[@]}"; do
        cfg_env+=("GIT_CONFIG_KEY_$n=${ID_KEYS[$i]}" "GIT_CONFIG_VALUE_$n=${ID_VALUES[$i]}")
        n=$((n + 1))
    done
    cfg_env+=("GIT_CONFIG_COUNT=$n")
    env "${cfg_env[@]}" GIT_TERMINAL_PROMPT=0 GIT_ASKPASS="" SSH_ASKPASS="" GCM_INTERACTIVE=never \
        GIT_SSH_COMMAND="$ssh_cmd -o BatchMode=yes -o ConnectTimeout=10" \
        "${runner[@]}" git -c core.askPass= -c credential.interactive=never -c core.hooksPath=/dev/null "$@" </dev/null >/dev/null 2>&1
}

[ -n "$SOURCE" ] || exit 4
KIND="$(source_kind "$SOURCE")"
IDENTITY=""
if [ "$KIND" = "url" ]; then
    load_identity
    IDENTITY="$(identity_text)"
fi
# one state dir per (source, identity): own clone, own daily throttle, own hint
if [ -n "$IDENTITY" ]; then
    HASH="$(sha256_hex "$SOURCE"$'\n'"$IDENTITY")" || exit 4
else
    HASH="$(sha256_hex "$SOURCE")" || exit 4
fi
[ ${#HASH} -ge 16 ] || exit 4
STATE="$STATE_ROOT/${HASH:0:16}"
REPO="$STATE/repo"

# --- refresh (URL sources only) ---

# synchronous fetch/clone; the lock keeps parallel session starts from fetching twice
do_refresh() {
    local force="$1"
    [ "$KIND" = "url" ] || return 0
    mkdir -p "$STATE" 2>/dev/null || return 4
    local last
    last="$(read_epoch "$STATE/last-check")"
    # last-check is written before each attempt, so a failure is throttled too
    if [ "$force" != "force" ] && [ $(( $(now) - last )) -lt $DAY ]; then
        return 0
    fi
    # stale lock (crashed run) older than 2 minutes is taken over
    if ! mkdir "$STATE/lock" 2>/dev/null; then
        local lock_age
        lock_age=$(( $(now) - $(stat -c %Y "$STATE/lock" 2>/dev/null || stat -f %m "$STATE/lock" 2>/dev/null || echo 0) ))
        [ "$lock_age" -gt 120 ] || return 0
        rmdir "$STATE/lock" 2>/dev/null
        mkdir "$STATE/lock" 2>/dev/null || return 0
    fi
    now > "$STATE/last-check"
    local ok=1
    if [ -d "$REPO/.git" ]; then
        quiet_git -C "$REPO" fetch --depth 1 --quiet --no-tags origin HEAD \
            && quiet_git -C "$REPO" reset --hard --quiet FETCH_HEAD \
            || ok=0
    else
        local tmp="$STATE/repo.tmp.$$"
        rm -rf "$tmp"
        if quiet_git clone --depth 1 --quiet --no-tags "$SOURCE" "$tmp"; then
            rm -rf "$REPO"
            mv "$tmp" "$REPO" || ok=0
        else
            ok=0
            rm -rf "$tmp"
        fi
    fi
    if [ "$ok" -eq 1 ]; then echo ok > "$STATE/status"; else echo fail > "$STATE/status"; fi
    rmdir "$STATE/lock" 2>/dev/null
    return 0
}

# refresh according to CLAUDE_MB_DOGMA_SOURCE_FETCH; background never blocks the caller
maybe_refresh() {
    [ "$KIND" = "url" ] || return 0
    case "${CLAUDE_MB_DOGMA_SOURCE_FETCH:-background}" in
        off) return 0 ;;
        sync) do_refresh ;;
        *)
            local last
            last="$(read_epoch "$STATE/last-check")"
            [ $(( $(now) - last )) -lt $DAY ] && return 0
            if command -v setsid >/dev/null 2>&1; then
                setsid "$0" refresh </dev/null >/dev/null 2>&1 &
            else
                nohup "$0" refresh </dev/null >/dev/null 2>&1 &
            fi
            ;;
    esac
    return 0
}

# local dir with the source content, or fail
content_dir() {
    case "$KIND" in
        path)
            local p
            p="$(local_path "$SOURCE")"
            [ -d "$p" ] || return 1
            (cd "$p" && pwd)
            ;;
        url)
            [ -d "$REPO/.git" ] || return 1
            printf '%s\n' "$REPO"
            ;;
        *) return 1 ;;
    esac
}

# reachable right now (path) or at the last fetch (url)
is_unreachable() {
    case "$KIND" in
        path) [ -d "$(local_path "$SOURCE")" ] && return 1 || return 0 ;;
        url) [ "$(cat "$STATE/status" 2>/dev/null)" = "fail" ] ;;
        *) return 0 ;;
    esac
}

# NOTICES.md -> TSV id, action, date, text (entries within the max age, id-first)
parse_notices_md() {
    command -v python3 >/dev/null 2>&1 || return 1
    python3 - "$1" "${CLAUDE_MB_DOGMA_NOTICES_MAX_AGE_DAYS:-90}" <<'PY'
import datetime, re, sys

path, max_age = sys.argv[1], sys.argv[2]
try:
    max_age = int(max_age)
except ValueError:
    max_age = 90
try:
    lines = open(path, encoding="utf-8").read().splitlines()
except OSError:
    sys.exit(1)

ID = re.compile(r"\(§([A-Za-z0-9][A-Za-z0-9._-]{0,63})\)")
DATE = re.compile(r"\b(\d{4}-\d{2}-\d{2})\b")
ACTION = re.compile(r"^\s*action\s*:\s*(.*?)\s*$", re.I)
today = datetime.date.today()

entries, cur, in_code = [], None, False
for line in lines:
    if line.lstrip().startswith("```"):
        in_code = not in_code
        if cur is not None:
            cur["body"].append(line)
        continue
    if not in_code and line.startswith("## "):
        head = line[3:]
        m = ID.search(head)
        cur = None
        if m:
            cur = {"id": m.group(1), "head": head, "body": [], "action": ""}
            entries.append(cur)
        continue
    if not in_code and line.startswith("# "):
        cur = None
        continue
    if cur is None:
        continue
    a = ACTION.match(line)
    if a and not cur["action"] and not in_code:
        cur["action"] = a.group(1).strip("`")
        continue
    cur["body"].append(line)

seen = set()
for e in entries:
    if e["id"] in seen:
        continue
    seen.add(e["id"])
    d = DATE.search(e["head"])
    if not d:
        continue
    try:
        day = datetime.date.fromisoformat(d.group(1))
    except ValueError:
        continue
    if max_age > 0 and (today - day).days > max_age:
        continue
    title = ID.sub("", DATE.sub("", e["head"], count=1), count=1)
    title = " ".join(title.split()).strip(" -:")
    body = " ".join(" ".join(e["body"]).split())
    text = title
    if body:
        text = (title + ": " if title else "") + body
    text = "{} ({})".format(text, day.isoformat()) if text else day.isoformat()
    print("\t".join(" ".join(v.split()) for v in (e["id"], e["action"], day.isoformat(), text)))
PY
}

# --- commands ---

CMD="${1:-}"
case "$CMD" in
    dir)
        maybe_refresh
        content_dir || exit 4
        ;;
    state-dir)
        printf '%s\n' "$STATE"
        ;;
    refresh)
        [ "${2:-}" = "--force" ] && do_refresh force || do_refresh
        exit 0
        ;;
    notices)
        maybe_refresh
        DIR="$(content_dir)" || exit 4
        [ -f "$DIR/NOTICES.md" ] || exit 4
        OUT="$(parse_notices_md "$DIR/NOTICES.md")" || exit 4
        [ -n "$OUT" ] || exit 4
        printf '%s\n' "$OUT"
        ;;
    hint)
        is_unreachable || exit 4
        mkdir -p "$STATE" 2>/dev/null || exit 4
        LAST="$(read_epoch "$STATE/hint-shown")"
        [ $(( $(now) - LAST )) -lt $DAY ] && exit 4
        now > "$STATE/hint-shown" 2>/dev/null || exit 4
        SHOWN="$(display_source "$SOURCE")"
        case "$KIND" in
            path) echo "The dogma source $SHOWN (CLAUDE_MB_DOGMA_SOURCE) does not exist on this machine, so its broadcasts (NOTICES.md) cannot be checked. Point CLAUDE_MB_DOGMA_SOURCE to an existing absolute path or to a git URL." ;;
            url) echo "The dogma source $SHOWN (CLAUDE_MB_DOGMA_SOURCE) was not reachable with the current git access (no prompts are allowed in the background), so its broadcasts (NOTICES.md) cannot be checked. For a private repo use a URL your git reaches without prompting, e.g. an SSH host alias (git@github-work:owner/repo.git), or a local path." ;;
            *) echo "CLAUDE_MB_DOGMA_SOURCE ($SHOWN) is neither a git URL nor an absolute path, so the dogma source broadcasts (NOTICES.md) cannot be checked." ;;
        esac
        ;;
    *)
        echo "source-cache: usage: source-cache.sh dir|state-dir|refresh [--force]|notices|hint" >&2
        exit 1
        ;;
esac
exit 0
