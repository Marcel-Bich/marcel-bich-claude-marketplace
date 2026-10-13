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
mkdir -p "$FH/proj/sub" "$T/plain/dir" "$T/repo/.git"   # repo: a whole repository root (hard)
ln -s "$FH" "$T/lnk"                # /tmp/... symlink pointing at the (fake) home
ln -s "$T/plain" "$T/oklnk"         # harmless symlink inside the temp dir

PASS=0
FAIL=0
# run <cwd> <command> -> prints "deny" or "allow"
run() {
    local out
    out="$(jq -n --arg c "$2" --arg d "$1" '{tool_name: "Bash", tool_input: {command: $c}, cwd: $d}' |
        HOME="$FH" CLAUDE_MB_DOGMA_ENABLED=true CLAUDE_MB_DOGMA_PROTECTED_MOUNTS="${PM:-}" bash "$HOOK" 2>/dev/null)"
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

# --- symlink under /tmp pointing at the home
expect deny  "$T" "rm -rf $T/lnk/"

# --- temporary roots: deletes inside pass, the root itself and the home below it do not
expect allow "$T" "rm -rf /mnt/c/Users/me/AppData/Local/Temp/abc"
expect deny  "$T" "rm -rf /mnt/c/Users/me/AppData/Local/Temp"
expect allow "$T" "rm -rf /var/tmp/dogma-fixture.log"
expect deny  "$T" "rm -rf $FH/proj"
expect deny  "$T" "rm -rf /tmp"
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
# a component before ".." that does not exist yet: where ".." leads is unknown (unsure, not a hard deny)
expect allow "$T" "mv $T/lnk $T/later && rm -rf $T/later/../u"
expect allow "$T" "rm -rf $T/nope/../plain/dir"
# env/sudo/doas options by the shared parser (working directory of the wrapped command)
expect deny  "$T" "env --chdir=$FH rm -rf proj"
expect deny  "$T" "env -iC $FH rm -rf proj"
expect deny  "$T" "env -S '-C $FH' rm -rf proj"
expect deny  "$T" "sudo -D$FH rm -rf proj"
expect deny  "$T" "sudo --chd $FH rm -rf proj"
# an unknown option or a login shell makes the working directory unknown: relative targets are unsure
expect allow "$T" "env --frobnicate x rm -rf proj"
expect allow "$T" "env -C $T/plain rm -rf dir"
expect allow "$T" "sudo -u root rm -rf $T/plain/dir"
expect allow "$T" "env -C $FH true; rm -rf $T/plain/dir"
# env -S is split like GNU env (\_ separates words); a login starts in the target home
expect deny  "$T" "env -S 'rm\\_-rf\\_$FH'"
expect deny  "$T" "env -S '-C\\_$FH rm -rf proj'"
expect deny  "$T" "env -S 'rm\\_-rf\\_\\q$FH'"
expect allow "$T" "sudo -i rm -rf proj"
expect allow "$T" "sudo -iu root rm -rf proj"
expect allow "$T" "env -S 'rm\\_-rf\\_$T/plain/dir'"
# POSIXLY_CORRECT: the options end at the first operand, so "-t ~" are sources
expect deny  "$T" "POSIXLY_CORRECT=1 mv $T/plain/a -t ~ $T/plain/b"
expect deny  "$T" "mv $T/plain/a -t ~ $T/plain/b"
expect deny  "$FH/proj" "rm -rf ../.."
expect deny  "$FH" "rm -rf proj"

# --- find
expect deny  "$T" "find $T/lnk -delete"
# find -L follows links while deleting: the start points are checked, the rest is unsure
expect allow "$T" "find -L $T/plain -delete"
expect allow "$T" "find $T/plain -follow -name x -delete"
expect allow "$T" "find $T/plain -name '*.tmp' -delete"
expect deny  "$T" "find ~ -name x -exec rm {} \\;"

# --- unresolvable targets: no hard denial since v1.46 (the delete setting decides, see the
# permission section below); a shell variable that is not resolved for sure is "unsure"
expect allow "$T" "rm -rf \"\$NOPE_UNSET_VAR\""
expect allow "$T" "rm -rf \$(cat list.txt)"
expect allow "$T" "rm -rf \`cat list.txt\`"
expect allow "$T" "eval \"rm -rf \$X\""
expect allow "$T" "find . -name '*.o' | xargs rm"
expect allow "$T" "D=\$(mktemp -d); touch \"\$D/a\"; rm -rf \"\$D\""
expect allow "$T" "D=\$(mktemp -d); D=\$HOME; rm -rf \"\$D\""
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

# --- parser cases (subshells, groups, pushd, combined -c, git clean, ${...})
expect deny  "$T" "(cd ~; rm -rf proj)"
expect deny  "$T" "{ rm -rf ~/proj; }"
expect deny  "$T" "pushd ~ && rm -rf proj"
expect deny  "$T" "bash -lc \"rm -rf ~/proj\""
expect deny  "$FH" "git clean -fdx"
expect allow "$T/plain" "git clean -fdx"
expect deny  "$FH" "rm -rf \"\$PWD\""
# a parameter expansion is not resolved for sure (unsure)
expect allow "$T" "rm -rf \${HOME%/}"

# --- legacy destructive rules kept
expect deny  "$T" "dd if=/dev/zero of=/dev/sda"
expect deny  "$T" "chmod -R 777 /etc"
expect deny  "$T" "rsync -a --delete $T/plain/ ~/"

# --- python under an import alias is the same call; the bare words stay no deletion
expect deny  "$T" "python3 -c \"import os as o; o.remove('/home/u/.bashrc')\""
expect allow "$T" "python3 -c \"import os as o; o.removedirs('/home/u/a/b')\""  # depth 4: follows the setting
expect deny  "$T" "python3 -c \"import os as o; o.remove(o.path.expanduser('~/.bashrc'))\""
expect deny  "$T" "python3 -c \"import shutil as s; s.move('/home/u/git', '/tmp/x')\""
expect deny  "$T" "python3 -c \"import shutil as s; s.rmtree('/home/u/git')\""
expect deny  "$T" "python3 -c \"import os; o = os; o.unlink('/home/u/.bashrc')\""
expect deny  "$T" "python3 -c \"from os import remove as r; r('/home/u/.bashrc')\""
expect allow "$T" "python3 -c \"import os as o; print(o.path.expanduser('~/x'))\""
expect allow "$T" "python3 -c \"import shutil as s; s.copy('/home/u/a', '/home/u/b')\""

# --- redirects: ">" and ">>" onto startup and persistence files, plain appends pass
expect deny  "$T" "echo x > ~/.bashrc"
expect deny  "$T" "echo x >> ~/.bashrc"
expect deny  "$T" "echo x >> ~/.profile"
expect deny  "$T" "echo x >> $FH/.zshrc"
expect deny  "$T" "echo x >> ~/.config/fish/config.fish"
expect deny  "$T" "echo x >> /etc/hosts"
expect allow "$T" "echo x >> ~/notes.md"
expect allow "$T" "echo x >> ~/proj/notes.md"
expect allow "$T" "echo x >> $T/plain/log.txt"
# quotes inside the target, a relative target after cd, tee -a
expect deny  "$T" "echo x >> \"\$HOME\"/.bashrc"
expect deny  "$T" "echo x >> ~/\".bashrc\""
expect deny  "$T" "echo x >> ~/'.bashrc'"
expect deny  "$T" "echo x > \"\$HOME\"/.bashrc"
expect deny  "$T" "cd ~ && echo x >> .bashrc"
expect deny  "$T" "cd ~; echo x >> ./.bashrc"
expect deny  "$T" "cd ~ && echo x >> .config/fish/config.fish"
expect deny  "$T" "echo x | tee -a ~/.bashrc"
expect deny  "$T" "echo x | tee -a $FH/.profile"
expect allow "$T" "cd ~ && echo x >> notes.md"
expect allow "$T" "echo x | tee -a ~/proj/notes.md"
expect allow "$T" "echo x | tee -a $T/plain/log.txt"
# WSL drives: only /mnt, /mnt/<x> and the first level below stay critical
expect allow "$T" "echo x > /mnt/c/somewhere/project/.bench/results/x.log"
expect allow "$T" "echo x >> /mnt/c/somewhere/project/.bench/results/x.log"
expect deny  "$T" "echo x > /mnt/c"
expect deny  "$T" "echo x > /mnt/c/somewhere"
expect deny  "$T" "echo x >> /mnt/c/Users/me/.bashrc"
# WSL drives: persistence and system paths below a drive stay critical (truncate and append)
expect deny  "$T" "echo x > /mnt/c/Users/me/AppData/Roaming/Microsoft/Windows/Start\\ Menu/Programs/Startup/a.bat"
expect deny  "$T" "echo x >> /mnt/c/Users/me/AppData/Local/a/b/c.txt"
expect deny  "$T" "echo x > /mnt/c/Windows/System32/drivers/etc/hosts"
expect deny  "$T" "echo x >> /mnt/c/Windows/System32/drivers/etc/hosts"
expect deny  "$T" "echo x > /mnt/c/ProgramData/a/b/c.txt"
expect deny  "$T" "echo x > \"/mnt/c/Program Files/App/sub/x.cfg\""
expect deny  "$T" "echo x >> \"/mnt/c/Program Files (x86)/App/sub/x.cfg\""
expect deny  "$T" "echo x > /mnt/c/Users/me/Documents/PowerShell/profile.ps1"
expect deny  "$T" "echo x >> /mnt/c/Users/me/Documents/WindowsPowerShell/profile.ps1"
expect deny  "$T" "echo x > /mnt/c/Users/me/NTUSER.DAT"
expect allow "$T" "echo x > /mnt/c/Users/me/workspace/proj/out.txt"
expect allow "$T" "echo x >> /mnt/c/Users/me/Documents/notes/a/b.txt"
# a mount the user declares is protected for redirects at any depth; a Windows drive keeps the rule above
PM="/mnt/vault:/mnt/c"
expect deny  "$T" "echo x > /mnt/vault/a/b/c/x.txt"
expect deny  "$T" "echo x >> /mnt/vault/a/b/c/x.txt"
expect deny  "$T" "echo x | tee /mnt/vault/a/b/c/x.txt"
expect allow "$T" "echo x > /mnt/nas/share2/a/b/c/x.txt"
expect allow "$T" "echo x > /mnt/c/Users/me/workspace/proj/out.txt"
PM=""
# an undeclared network share: redirects below it stay ordinary
expect allow "$T" "echo x > /mnt/nas/share/a/b/c/x.txt"

# --- deletes below /mnt and /media: the mount point, the drive and the first level below it stay protected,
# deeper project files are ordinary (file-protection.sh and the permissions decide); the Windows profile
# root and its first level follow the /home rule, Windows system and profile paths and declared mounts stay
expect allow "$T" "rm /mnt/d/data/proj/models/x.gguf"
expect allow "$T" "rm -r /mnt/d/data/proj/old"
expect allow "$T" "rm -rf /media/usb/x/y/old"
# a network share or USB stick (any filesystem, not declared): the mount point and the levels down to
# depth 4 stay refused, deeper files are ordinary. These results do not depend on the host's
# /proc/self/mounts: a mount point up to depth 4 is refused by the depth rule anyway
expect allow "$T" "rm /mnt/nas/share/old/x.bin"
expect deny  "$T" "rm -r /mnt/nas/share/tmpdir"
expect deny  "$T" "rm -rf /media/usb/folder/x"
expect deny  "$T" "rm -rf /mnt"
expect deny  "$T" "rm -rf /mnt/d"
expect deny  "$T" "rm -rf /mnt/d/data"
expect deny  "$T" "rm -rf /mnt/nas"
expect deny  "$T" "rm -rf /mnt/nas/share"
expect deny  "$T" "rm -rf /media/usb"
expect deny  "$T" "rm -rf /media/usb/folder"
expect deny  "$T" "rm -rf /media/usb/x"
expect deny  "$T" "rm -rf /mnt/c/Windows/x"
expect deny  "$T" "rm -rf /mnt/c/Users/alice/AppData/x"
expect deny  "$T" "rm -rf /mnt/c/Users/alice/.ssh/x"
expect deny  "$T" "rm -rf /mnt/c/Users/alice"
expect deny  "$T" "rm -rf /mnt/c/Users/alice/Documents"
expect allow "$T" "rm -rf /mnt/c/Users/alice/workspace/proj/old"
expect deny  "$T" "rm -rf /etc/x"
expect allow "$T" "rm -rf /opt/x/y/z"    # depth 4 outside the hard list: the setting decides
# a declared mount keeps its whole subtree protected; a sibling with a longer name is ordinary
PM="/mnt/vault"
expect deny  "$T" "rm -rf /mnt/vault"
expect deny  "$T" "rm -rf /mnt/vault/a/b/c/x"
expect allow "$T" "rm -rf /mnt/vault2/a/b/c/x"
PM=""
# a home that itself sits below /mnt: its home, parent and first level are hard, deeper files follow the setting
run_home() { # home command -> deny or allow
    local out
    out="$(jq -n --arg c "$2" --arg d "$T" '{tool_name: "Bash", tool_input: {command: $c}, cwd: $d}' |
        HOME="$1" CLAUDE_MB_DOGMA_ENABLED=true CLAUDE_MB_DOGMA_PROTECTED_MOUNTS="" bash "$HOOK" 2>/dev/null)"
    case "$out" in *'"deny"'*) echo deny ;; *) echo allow ;; esac
}
got="$(run_home /mnt/d/home-u "rm -rf /mnt/d/home-u/proj")"
if [ "$got" = deny ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL want deny got $got: home first level below /mnt"; fi
got="$(run_home /mnt/d/home-u "rm -rf /mnt/d/home-u/proj/old")"
if [ "$got" = allow ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL want allow got $got: home below /mnt, deeper file"; fi
got="$(run_home /mnt/d/home-u "rm -rf /mnt/d/data/proj/old")"
if [ "$got" = allow ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL want allow got $got: project below /mnt with home below /mnt"; fi

# --- truncate only in command position; redirects inside quotes are text
expect allow "$T" "grep -n \"truncate\" /home/u/proj/a.py"
expect allow "$T" "cd /home/u/proj && grep -n truncate a.py"
expect deny  "$T" "truncate -s 0 ~/.bashrc"
expect deny  "$T" "sudo truncate -s 0 /home/u/x"
expect deny  "$T" "find /home/u/proj -exec truncate -s0 {} \\;"
expect deny  "$T" "grep -rn x /home/u/proj | xargs truncate -s 0"
expect allow "$T" "git commit -m \"fix: no longer blocks > ~/.bashrc\""
expect allow "$T" "echo \"use > ~/.bashrc carefully\""
expect allow "$T" "grep -n \"> ~/.bashrc\" notes.md"
expect allow "$T" "gh pr create --body \"\$(cat <<'EOF'
> /etc/passwd
EOF
)\""
expect allow "$T" "git commit -m \"\$(cat <<'EOF'
fix: python os.remove(~/x) is checked
EOF
)\""
expect deny  "$T" "echo x > ~/.bashrc"
expect deny  "$T" "echo \"a\" \"b\" > ~/.bashrc"
expect deny  "$T" "echo \"done\"; echo x > ~/.bashrc"
expect deny  "$T" "cat <<'EOF' > $T/plain/f
don't
EOF
echo 'a' 'b' > ~/.bashrc"

# --- a heredoc piped into a subshell reaches the shell inside it
expect deny  "$T" "cat <<'EOF' | (sh)
rm -rf ~
EOF"
expect deny  "$T" "cat <<'EOF' | ( bash -s )
rm -rf ~
EOF"
expect deny  "$T" "cat <<'EOF' | (sh) > /dev/null
rm -rf ~
EOF"
expect allow "$T" "cat <<'EOF' | (wc -l)
line
EOF"

# --- heredoc bodies: data only when the output goes to a normal file or /dev/null
expect allow "$T" "cat > $T/plain/c.sh <<'EOF'
rm -rf \"\${VAR:?}\"
EOF"
expect allow "$T" "cat > $T/plain/c.sh <<'EOF'
rm -rf \\
  \"\${VAR:?}\"
EOF"
expect deny  "$T" "cat <<'EOF' > $T/plain/f
a\\
EOF
rm -rf ~
EOF"
expect deny  "$T" "cat <<'EOF' > >(sh)
rm -rf ~
EOF"
expect deny  "$T" "cat <<'EOF' > /dev/stdout
rm -rf ~
EOF"
expect deny  "$T" "cat > $T/plain/x.sh <<'EOF'
rm -rf ~
EOF
sh < $T/plain/x.sh"
expect deny  "$T" "printf 'rm -rf ~' > $T/plain/x.sh && sh -s < $T/plain/x.sh"

# --- python deletes through indirection stay blocked, plain reads and writes pass
expect deny  "$T" "python3 -c \"from os import *; remove('/home/u/.bashrc')\""
expect deny  "$T" "python3 -c \"import posix; posix.remove('/home/u/.bashrc')\""
expect deny  "$T" "python3 -c \"import os; vars(os)['remove']('/home/u/.bashrc')\""
expect deny  "$T" "python3 -c \"import os as o; getattr(o, 'remove')('/home/u/.bashrc')\""
expect deny  "$T" "python3 -c \"import os; (os).remove('/home/u/.bashrc')\""
expect deny  "$T" "python3 -c \"import sys; sys.modules['os'].remove('/home/u/.bashrc')\""
expect deny  "$T" "python3 -c \"import importlib; importlib.import_module('posix').remove('/home/u/.bashrc')\""
expect deny  "$T" "python3 -c \"exec('import os; os.remove(\\\"/home/u/.bashrc\\\")')\""
expect allow "$T" "python3 -c \"import os; p = '/home/u/proj/d.json'; os.replace(p + '.tmp', p)\""
expect allow "$T" "python3 -c \"import importlib; print(importlib.import_module('json'))\""
expect deny  "$T" "python3 -c \"import os; os.replace('/tmp/x', '/home/u/.config/git/config')\""

# --- a heredoc body is data only when cat, tee or the interpreter is the real one
expect deny  "$T" "cat() { sh; }; cat > $T/plain/f.txt <<'EOF'
rm -rf ~
EOF"
expect deny  "$T" "alias tee=sh
tee $T/plain/f.txt <<'EOF'
rm -rf ~
EOF"
expect deny  "$T" "function cat { sh; }; cat > $T/plain/f.txt <<'EOF'
rm -rf ~
EOF"
expect allow "$T" "/bin/cat > $T/plain/c.sh <<'EOF'
rm -rf \"\${VAR:?}\"
EOF"
expect allow "$T" "cat > $T/plain/c.sh <<'EOF'
cleanup() {
  rm -rf \"\${VAR:?}\"
}
EOF"

# --- inline code in a heredoc: symlinks onto the home, a python line continuation
expect deny  "$T" "python3 <<'EOF'
import os
os.symlink('$FH', 'link')
EOF
rm -rf link/*"
expect allow "$T" "python3 <<'EOF'
import os
os.symlink('a.txt', 'b.txt')
EOF"
expect deny  "$T" "python3 <<'PY'
import os
os.\\
remove('$FH/.bashrc')
PY"

# --- a redirect target with an unresolved variable, ANSI-C quoting, the standard streams
expect deny  "$T" "echo x > ~/\$X"
expect deny  "$T" "echo x > /etc/\$X"
expect deny  "$T" "echo x >> \$HOME/.\$X"
expect deny  "$T" "echo x > \$'/etc/hosts'"
expect deny  "$T" "echo x >> \$'$FH/.bashrc'"
expect allow "$T" "echo x > $FH/proj/\$X.log"
expect allow "$T" "echo x > \$X"
expect allow "$T" "echo x > /dev/stdout"
expect allow "$T" "echo x >> /dev/stderr"
expect allow "$T" "echo x > /dev/stdin"

# --- an append is blocked onto startup and persistence files only
expect allow "$T" "echo x >> ~/.cache/x.log"
expect allow "$T" "echo x >> ~/.local/state/app/x.log"
expect allow "$T" "echo x >> ~/.npm/_logs/run.log"
expect deny  "$T" "echo x >> ~/.ssh/config"
expect deny  "$T" "echo x >> ~/.zshenv"
expect deny  "$T" "echo x >> ~/.config/autostart/a.desktop"
expect deny  "$T" "echo x >> ~/.config/systemd/user/a.service"
expect deny  "$T" "echo x > ~/.cache/x.log"

# --- a heredoc inside $(...) inside double quotes: apostrophes in the body do not unbalance the quoting
expect allow "$T" "git commit -m \"\$(cat <<'EOF'
fix: don't crash
EOF
)\""
expect allow "$T" "git tag -a v1 -m \"\$(cat <<'EOF'
release, don't panic
EOF
)\""
expect deny  "$T" "git commit -m \"\$(cat <<'EOF'
don't
EOF
)\" && rm -rf ~"
expect deny  "$T" "git commit -m \"it's"

# --- a "#" inside ${...} is no comment: the rest of the line is code; a real comment stays one
expect deny  "$T" 'x=a; echo ${x// #/y} > /etc/hosts'
expect deny  "$T" 'echo ${x%% #*} > ~/.bashrc'
expect deny  "$T" 'echo ${x/#a/ #} > ~/.bashrc'
expect deny  "$T" 'echo ${x// #/y}; truncate -s0 /etc/hosts'
expect allow "$T" 'echo ${x// #/y} # note > ~/.bashrc'
expect allow "$T" 'echo ${x:-a} # note > ~/.bashrc'

# --- 8.3 short names of Windows system folders and the localized PowerShell profile folder
expect deny  "$T" 'echo x > /mnt/c/PROGRA~1/app/a.txt'
expect deny  "$T" 'echo x >> /mnt/c/PROGRA~2/app/a.txt'
expect deny  "$T" 'echo x > /mnt/c/Users/me/Documents/WINDOW~1/profile.ps1'
expect deny  "$T" 'echo x > /mnt/c/Users/me/OneDrive/Dokumente/WindowsPowerShell/profile.ps1'
expect allow "$T" 'echo x > /mnt/c/Users/me/Documents/notes/a.txt'

# --- a shell syntax check runs nothing
expect allow "$T" "printf 'echo hi' > $T/plain/x.sh && bash -n $T/plain/x.sh"
expect allow "$T" "printf 'echo hi' > $T/plain/x.sh && sh -n $T/plain/x.sh"
expect deny  "$T" "printf 'echo hi' > $T/plain/x.sh && bash $T/plain/x.sh"
expect deny  "$T" "printf 'echo hi' > $T/plain/x.sh && bash +n $T/plain/x.sh"

# --- hard list by depth (v1.46): outside the temp roots an absolute path of depth <= 3 is hard,
# below /mnt and /media depth <= 4; deeper paths follow the delete setting (the permission section)
expect deny  "$T" "rm -rf /usr/local"
expect deny  "$T" "rm -rf /home/alice"
expect deny  "$T" "rm -rf /home/alice/.ssh"
expect deny  "$T" "rm -rf /var/lib/x"
expect deny  "$T" "rm -rf /opt/a/b"
expect deny  "$T" "rm -rf /mnt/c"
expect deny  "$T" "rm -rf /mnt/c/Users/alice/Pictures"
expect deny  "$T" "rm -rf /mnt/nas/share/folder"
expect deny  "$T" "rm -rf $T/repo"             # a whole repository root
expect allow "$T" "rm -rf /mnt/c/Users/alice/work/proj/old"
expect allow "$T" "rm -rf /home/alice/proj/old/build"
expect allow "$T" "rm -rf /home/alice/proj/old"

# --- literal variables: a plain assignment earlier in the same command is resolved; any failed rule
# (value with $ ~ glob or blank, name used twice, pipe or || before the use, use before the assignment,
# compound syntax) leaves the target unsure
expect deny  "$T" "R=/home; rm -rf \"\$R\""
expect deny  "$T" "R=/home && rm -rf \"\$R\""
expect deny  "$T" "R='/home'; rm -rf \"\$R\""
expect deny  "$T" "R=$FH/proj; rm -rf \"\$R\""
expect deny  "$T" "R=$T/repo; rm -rf \"\$R\""
expect allow "$T" "R=$FH/proj/sub/renders; rm -- \"\$R/final.mp4\""
expect allow "$T" "R=/home | rm -rf \"\$R\""
expect allow "$T" "R=/home || rm -rf \"\$R\""
expect allow "$T" "R=/home; R=$FH/proj/sub; rm -rf \"\$R\""
expect allow "$T" "rm -rf \"\$R\"; R=/home"
expect allow "$T" "R=~; rm -rf \"\$R\""
expect allow "$T" "R=\$HOME; rm -rf \"\$R\""
expect allow "$T" "R=/ho*; rm -rf \"\$R\""
expect allow "$T" "if true; then R=/home; fi; rm -rf \"\$R\""
expect allow "$T" "(R=/home); rm -rf \"\$R\""

# --- unsure run-time forms: a literal eval text is walked, python paths that cannot be read stay unsure
expect deny  "$T" "eval \"rm -rf ~\""
expect allow "$T" "eval \"rm x\""
expect allow "$T" "python3 -c \"import os; os.remove(sys.argv[1])\""

# ~+ is the working directory: the directory itself and its parent stay hard
expect deny  "$T/plain/dir" "rm -rf ~+"
expect deny  "$FH/proj/sub" "rm -rf ~+/.."

# --- non-delete protections stay hard whatever the setting
expect deny  "$T" "git commit --no-verify -m x"
expect deny  "$T" "echo x > $FH/proj/.git/hooks/pre-commit"
expect deny  "$T" "echo \"\$GITHUB_TOKEN\""
expect deny  "$T" "cp $T/plain/dir/x $T/plain/DOGMA-PERMISSIONS.md"

# --- the delete setting (file-protection.sh behind delete-guard.sh): [x] runs, [?] asks, [ ] denies and
# writes TO-DELETE.md. The hard list is denied before the setting and stays denied with [x].
PERM="$T/perm"
for box in x q d; do
    case "$box" in x) mark=x ;; q) mark='?' ;; d) mark=' ' ;; esac
    mkdir -p "$PERM/$box"
    printf '<permissions>\n- [%s] (§0lgy) May delete files\n- [ ] (§b4dk) Discard uncommitted changes\n</permissions>\n' \
        "$mark" > "$PERM/$box/DOGMA-PERMISSIONS.md"
done

# chain <folder> <command> -> deny-hard (delete-guard.sh), deny, ask or allow (file-protection.sh)
chain() {
    local input out
    input="$(jq -n --arg c "$2" --arg d "$1" '{tool_name: "Bash", tool_input: {command: $c}, cwd: $d}')"
    out="$(printf '%s' "$input" | HOME="$FH" CLAUDE_MB_DOGMA_ENABLED=true DOGMA_CREDO_CONFIG=none \
        DOGMA_SESSION_DIR="$1" bash "$HOOK" 2>/dev/null)"
    case "$out" in *'"deny"'*) echo deny-hard; return ;; esac
    # run in the folder itself, like the hooks in a session (file-protection.sh exempts a hydra worktree by cwd)
    out="$(cd "$1" && printf '%s' "$input" | HOME="$FH" CLAUDE_MB_DOGMA_ENABLED=true CLAUDE_MB_DOGMA_FILE_PROTECTION=true \
        DOGMA_CREDO_CONFIG=none DOGMA_SESSION_DIR="$1" bash "$HERE/file-protection.sh" 2>/dev/null)"
    case "$out" in *'"deny"'*) echo deny ;; *'"ask"'*) echo ask ;; *) echo allow ;; esac
}
expect_chain() { # want folder command
    local got
    got="$(chain "$2" "$3")"
    if [ "$got" = "$1" ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); printf 'FAIL want %s got %s: %s (folder %s)\n' "$1" "$got" "$3" "$2"; fi
}
# setting_rows <command> <want in [x]> <want in [?]> <want in [ ]>
setting_rows() {
    expect_chain "$2" "$PERM/x" "$1"
    expect_chain "$3" "$PERM/q" "$1"
    expect_chain "$4" "$PERM/d" "$1"
}
setting_rows 'rm -rf "$NOPE_UNSET_VAR/x"' allow ask deny
setting_rows 'rm "$(cat list.txt)"' allow ask deny
setting_rows "find . -name '*.o' | xargs rm" allow ask deny
setting_rows "eval \"rm $FH/proj/old/x\"" allow ask deny   # literal eval text is walked: an ordinary target
setting_rows "R=$FH/proj/sub/renders; rm -- \"\$R/final.mp4\"" allow ask deny
setting_rows "rm -rf $FH/proj/sub/old/build" allow ask deny
setting_rows "R=/home; rm -rf \"\$R\"" deny-hard deny-hard deny-hard
setting_rows "rm -rf /home/alice" deny-hard deny-hard deny-hard
[ -s "$PERM/d/TO-DELETE.md" ] && [ ! -e "$PERM/x/TO-DELETE.md" ] && [ ! -e "$PERM/q/TO-DELETE.md" ] \
    && PASS=$((PASS + 1)) || { FAIL=$((FAIL + 1)); echo "FAIL TO-DELETE.md only in the [ ] folder"; }

echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]
