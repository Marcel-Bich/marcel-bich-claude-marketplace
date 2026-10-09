#!/usr/bin/env bash
# Tests for scripts/delete-guard.sh.
#
# SAFETY: the hook only ANALYSES command text; no test command is ever executed.
# Every path a test names lives in a fresh mktemp directory with a fake HOME inside
# it, so even a hook bug could not touch real data. The only things created on disk
# are that directory, a few empty subdirectories and symlinks INSIDE it.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$HERE/delete-guard.sh"

T="$(mktemp -d)"
case "$T" in /tmp/?*) ;; *) echo "refusing: mktemp gave $T"; exit 1 ;; esac
trap 'rm -rf -- "$T"' EXIT
FH="$T/home/u"                      # fake HOME
mkdir -p "$FH/proj/sub" "$T/plain/dir"
ln -s "$FH" "$T/lnk"                # /tmp/... symlink pointing at the (fake) home
ln -s "$T/plain" "$T/oklnk"         # harmless symlink inside the temp dir

PASS=0
FAIL=0
# run <cwd> <command> -> prints "deny" or "allow"
run() {
    local out
    out="$(jq -n --arg c "$2" --arg d "$1" '{tool_name: "Bash", tool_input: {command: $c}, cwd: $d}' |
        HOME="$FH" CLAUDE_MB_DOGMA_ENABLED=true bash "$HOOK" 2>/dev/null)"
    case "$out" in *'"deny"'*) echo deny ;; *) echo allow ;; esac
}
expect() { # want cwd command
    local got
    got="$(run "$2" "$3")"
    if [ "$got" = "$1" ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); printf 'FAIL want %s got %s: %s (cwd %s)\n' "$1" "$got" "$3" "$2"; fi
}

# --- classic protected targets
expect deny  "$T" "rm -rf /"
expect deny  "$T" "rm -rf /home"
expect deny  "$T" "rm -rf /home/someone"
expect deny  "$T" "rm -rf /home/someone/docs"
expect allow "$T" "rm -rf /home/someone/docs/old"
expect deny  "$T" "rm -rf ~"
expect deny  "$T" "rm -rf \$HOME"
expect deny  "$T" "rm -rf ~/.ssh"
expect allow "$T" "rm -rf ~/proj/sub"
expect deny  "$T" "rm -rf /usr"
expect deny  "$T" "rm -rf /tmp"
expect deny  "$T" "rm -rf ."
expect allow "$T" "rm -f $T/plain/a.txt"
expect allow "$T/plain" "rm -rf dir"

# --- symlink under /tmp pointing at the home (the reported hole)
expect deny  "$T" "rm -rf $T/lnk/"
expect deny  "$T" "rm -rf $T/lnk/*"
expect deny  "$T" "rm -rf $T/lnk/proj"
expect allow "$T" "rm -rf $T/lnk"          # rm removes only the link itself
expect allow "$T" "unlink $T/lnk"
expect deny  "$T" "shred -u $T/lnk"        # shred writes through the link
expect allow "$T" "mv $T/lnk $T/plain/moved-link"
expect deny  "$T" "rm -rf lnk/proj"
expect deny  "$T/plain" "cd $T && rm -rf lnk/proj"
expect allow "$T" "rm -rf $T/oklnk/dir"
# ".." after a link component resolves against the link target (lnk/.. is $T/home)
expect deny  "$T" "rm -rf $T/lnk/../u"
expect deny  "$T" "rm -rf lnk/../u"
expect deny  "$T" "unlink $T/lnk/../u/.bashrc"
expect deny  "$T" "mv $T/lnk/../u $T/plain/x"
expect allow "$T" "rm -rf $T/oklnk/../plain/dir"
# a component before ".." that does not exist yet: where ".." leads is unknown
expect deny  "$T" "mv $T/lnk $T/later && rm -rf $T/later/../u"
expect deny  "$T" "rm -rf $T/nope/../plain/dir"
# env/sudo/doas options by the shared parser (working directory of the wrapped command)
expect deny  "$T" "env --chdir=$FH rm -rf proj"
expect deny  "$T" "env -iC $FH rm -rf proj"
expect deny  "$T" "env -S '-C $FH' rm -rf proj"
expect deny  "$T" "sudo -D$FH rm -rf proj"
expect deny  "$T" "sudo --chd $FH rm -rf proj"
expect deny  "$T" "env --frobnicate x rm -rf proj"
expect allow "$T" "env -C $T/plain rm -rf dir"
expect allow "$T" "sudo -u root rm -rf $T/plain/dir"
expect allow "$T" "env -C $FH true; rm -rf $T/plain/dir"
# env -S is split like GNU env (\_ separates words); a login starts in the target home
expect deny  "$T" "env -S 'rm\\_-rf\\_$FH'"
expect deny  "$T" "env -S '-C\\_$FH rm -rf proj'"
expect deny  "$T" "env -S 'rm\\_-rf\\_\\q$FH'"
expect deny  "$T" "sudo -i rm -rf proj"
expect deny  "$T" "sudo -iu root rm -rf proj"
expect allow "$T" "env -S 'rm\\_-rf\\_$T/plain/dir'"
# POSIXLY_CORRECT: the options end at the first operand, so "-t ~" are sources
expect deny  "$T" "POSIXLY_CORRECT=1 mv $T/plain/a -t ~ $T/plain/b"
expect deny  "$T" "mv $T/plain/a -t ~ $T/plain/b"
expect deny  "$FH/proj" "rm -rf ../.."
expect deny  "$FH" "rm -rf proj"

# --- find
expect deny  "$T" "find $T/lnk -delete"
expect deny  "$T" "find -L $T/plain -delete"
expect deny  "$T" "find $T/plain -follow -name x -delete"
expect allow "$T" "find $T/plain -name '*.tmp' -delete"
expect deny  "$T" "find ~ -name x -exec rm {} \\;"

# --- unresolvable targets (strict) and safe mktemp variables
expect deny  "$T" "rm -rf \"\$NOPE_UNSET_VAR\""
expect deny  "$T" "rm -rf \$(cat list.txt)"
expect deny  "$T" "rm -rf \`cat list.txt\`"
expect deny  "$T" "eval \"rm -rf \$X\""
expect deny  "$T" "find . -name '*.o' | xargs rm"
expect allow "$T" "D=\$(mktemp -d); touch \"\$D/a\"; rm -rf \"\$D\""
expect deny  "$T" "D=\$(mktemp -d); D=\$HOME; rm -rf \"\$D\""
expect deny  "$T" "bash -c 'rm -rf ~/.config'"

# --- mv sources
expect deny  "$T" "mv ~/.ssh $T/plain/x"
expect allow "$T" "mv $T/plain/dir $T/plain/dir2"

# --- symlink creation onto protected targets
expect deny  "$T" "ln -s ~ $T/l2"
expect deny  "$T" "ln -sf \$HOME/.ssh $T/l3"
expect deny  "$T" "ln -s / $T/root"
expect deny  "$T" "ln -s /etc $T/etc"
expect allow "$T" "ln -s /usr/bin/python3 $T/py"
expect allow "$T" "ln -s $T/plain $T/l4"
expect deny  "$T" "cp -s ~/proj $T/cp"
expect deny  "$T" "python3 -c \"import os; os.symlink(os.path.expanduser('~'), '$T/x')\""

# --- unrelated commands stay untouched
expect allow "$T" "cat /etc/hosts"
expect allow "$T" "ls -la ~"
expect allow "$T" "git rm --cached file.txt"
expect allow "$T" "echo done"

# --- everyday commands must not trip it
expect allow "$T" "grep -n \"^<rules>\" -A9 CLAUDE/CLAUDE.git.md | head -12"
expect allow "$T" "git log --format='<%h>' -3"
expect deny  "$T" "rm -rf \"unbalanced ~/x"
expect allow "$T" "rm -rf $T/plain/dir 2>/dev/null"
expect allow "$T/plain" "find . -name '*.pyc' -delete"
expect allow "$T" "ls $T/plain >/dev/null 2>&1"
expect deny  "$T" "echo x > /etc/passwd"
expect deny  "$FH" "find . -delete"

# --- parser gaps found in review (subshells, groups, pushd, combined -c, git clean, ${...})
expect deny  "$T" "(cd ~; rm -rf proj)"
expect deny  "$T" "{ rm -rf ~/proj; }"
expect deny  "$T" "pushd ~ && rm -rf proj"
expect deny  "$T" "bash -lc \"rm -rf ~/proj\""
expect deny  "$FH" "git clean -fdx"
expect allow "$T/plain" "git clean -fdx"
expect deny  "$FH" "rm -rf \"\$PWD\""
expect deny  "$T" "rm -rf \${HOME%/}"

# --- legacy destructive rules kept
expect deny  "$T" "dd if=/dev/zero of=/dev/sda"
expect deny  "$T" "chmod -R 777 /etc"
expect deny  "$T" "rsync -a --delete $T/plain/ ~/"

echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]
