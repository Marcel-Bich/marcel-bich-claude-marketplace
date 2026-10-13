#!/usr/bin/env python3
"""Parity tests: the dogma Bash PreToolUse guards against the case tables.

SAFETY: no case command is ever executed. Every command is only handed to the hook
scripts as PreToolUse JSON on stdin. All paths live in a fresh temporary directory with a
fake HOME inside it, so even a hook bug could not touch real data. The hooks run from a
copy of the plugin installed below the fake Claude configuration home (like a real
install), so the self-protection of installed hook files is tested too.

A case counts as "deny" when any guard hook answers deny or ask (both stop the command),
otherwise as "allow". Case tables live in guard-cases/: review_r1 (REVIEW_X and REVIEW_N),
review_r2 (with explicit ids), the probes and everyday commands that must pass. apply_patch cases
(a Codex tool) are skipped. An optional local table (guard-cases/local_cases.py, not
versioned) is run and reported without being asserted.

A unit table ("unit") runs the bash-guard -> delete-guard hand-over in process with a
literal working directory below /home/ (no directory is created), so the legacy text
patterns are proven to see only the command, never the generated "cd <dir>" lines. The
same table checks that remote URL denials name the installed git-scope.sh, both in
bash-guard.py and in the token-protection.sh fallback that runs without python3. The mount table
(MOUNT_CASES) runs the bash-guard hook in process with MOUNTS_FIXTURE in place of /proc/self/mounts,
so network shares, USB sticks and mounts below the home are decided the same on every machine.

The fp table holds false positives (must pass) next to the protection that must
stay (must be blocked), plus Edit/Write inputs that no Edit/Write hook may treat as a deletion.
PEM_READ (guard-cases/false_positives.py) runs Read inputs through token-protection.sh: a key
block is denied, a lone PEM header line is allowed.
unit_todelete_entry runs file-protection.sh from fixture folders. A delete whose target is a shell variable logs
its command in TO-DELETE.md and gets the hint, a literal target and a discard keep the plain entry and reason.

Usage: test-guard-parity.py [-v] [--only r1x|r1n|r2|probes|everyday|fp|local|unit]
"""

import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.dont_write_bytecode = True
sys.path.insert(0, str(HERE / "guard-cases"))
import everyday  # noqa: E402
import false_positives  # noqa: E402
import probes  # noqa: E402
import review_r1  # noqa: E402
import review_r2  # noqa: E402

try:
    import local_cases  # noqa: E402  (optional, local only)
except ImportError:
    local_cases = None

# Bash PreToolUse guard hooks of hooks.json (order irrelevant: any deny/ask blocks).
HOOKS = ("token-protection.sh", "git-add-protection.sh", "git-permissions.sh", "delete-guard.sh",
         "file-protection.sh", "dependency-verification.sh")
USER = "alice"


def setup():
    root = Path(tempfile.mkdtemp(prefix="dogma-parity-"))
    if not str(root).startswith(("/tmp/", "/var/tmp/")):
        os.rmdir(root)  # still empty; nothing else outside /tmp is ever removed
        sys.exit("refusing: temporary directory %s is not below /tmp" % root)
    try:
        return (root,) + fill(root)
    except BaseException:
        shutil.rmtree(root, ignore_errors=True)
        raise


def fill(root):
    home = root / "home" / USER
    # P, N and X sit below the fake home: a folder below /tmp is temporary (deletes there are always
    # allowed), a folder below the home is not, as with real projects.
    # W: an allow-all project whose path contains a /home/<user> segment (outside the fake home)
    work = home / "work"
    dirs = {"P": work / "perm-project", "N": work / "noperm-project", "X": work / "allow-project" / "proj",
            "W": root / "home" / "someone" / "proj", "D": work / "discard-off", "E": work / "discard-on",
            "F": work / "discard-missing"}
    home.mkdir(parents=True)
    for directory in dirs.values():
        directory.mkdir(parents=True)
    (dirs["P"] / "DOGMA-PERMISSIONS.md").write_text(
        "# perms\n<permissions>\n- [ ] (§6gpt) May git add\n- [ ] (§2w1t) May git commit\n"
        "- [?] (§bww9) May git push\n</permissions>\n", encoding="utf-8")
    (dirs["X"] / "DOGMA-PERMISSIONS.md").write_text(
        "<permissions>\n- [x] (§6gpt) May git add\n- [x] (§2w1t) May git commit\n"
        "- [x] (§bww9) May git push\n- [x] (§0lgy) May delete files\n"
        "- [x] (§b4dk) Discard uncommitted changes\n</permissions>\n", encoding="utf-8")
    (dirs["D"] / "DOGMA-PERMISSIONS.md").write_text(
        "<permissions>\n- [x] (§0lgy) May delete files\n- [ ] (§b4dk) Discard uncommitted changes\n"
        "</permissions>\n", encoding="utf-8")
    (dirs["E"] / "DOGMA-PERMISSIONS.md").write_text(
        "<permissions>\n- [ ] (§0lgy) May delete files\n- [x] (§b4dk) Discard uncommitted changes\n"
        "</permissions>\n", encoding="utf-8")
    (dirs["F"] / "DOGMA-PERMISSIONS.md").write_text(
        "<permissions>\n- [x] (§0lgy) May delete files\n</permissions>\n", encoding="utf-8")
    # a file and a folder in the discard fixtures: "git checkout <path>" is a discard only for an existing
    # path, "git checkout main" stays a branch switch
    for name in ("D", "E", "F", "P"):
        (dirs[name] / "notes.txt").write_text("fixture\n", encoding="utf-8")
    for name in ("D", "E"):
        (dirs[name] / "src").mkdir()
    (dirs["W"] / "DOGMA-PERMISSIONS.md").write_text(
        (dirs["X"] / "DOGMA-PERMISSIONS.md").read_text(encoding="utf-8"), encoding="utf-8")
    (dirs["X"] / ".git" / "hooks").mkdir(parents=True)
    (dirs["N"] / "node_modules" / ".bin").mkdir(parents=True)
    for tool in ("tsc", "eslint", "prettier"):
        (dirs["N"] / "node_modules" / ".bin" / tool).write_text("", encoding="utf-8")
    # ordinary folders below the home (copy and move targets of everyday commands)
    for folder in ("git", "Documents", "Downloads"):
        (home / folder).mkdir()
    (home / ".bashrc").write_text("# fixture\n", encoding="utf-8")
    # a symlink inside the temporary root that points at the home (deletes through it stay blocked)
    (root / "homelink").symlink_to(home)
    # an existing symlink entry inside an ordinary folder that points at a protected file
    (home / "Documents" / "link.pdf").symlink_to(home / ".bashrc")
    # a symlink to the home inside the allow-all project (rm/unlink/mv act on the link only)
    (dirs["X"] / "homelink").symlink_to(home)
    # a linked worktree below the home (deleting a whole worktree is never allowed)
    worktree = home / "workspace" / "worktrees" / "cx-d1"
    worktree.mkdir(parents=True)
    (worktree / ".git").write_text("gitdir: /nonexistent/.git/worktrees/cx-d1\n", encoding="utf-8")
    plugin = home / ".claude" / "plugins" / "cache" / "test-market" / "dogma" / "0.0.0"
    shutil.copytree(HERE.parent, plugin, ignore=shutil.ignore_patterns("__pycache__", "guard-cases", "TO-DELETE.md"))
    # the installed plugin under a name that does not mention the config home (a path with ".claude" is
    # refused as agent configuration before the own-file rule applies)
    (home / "dogma-link").symlink_to(plugin)
    return home, dirs, plugin


class Runner:
    def __init__(self, root, home, dirs, plugin):
        self.root, self.home, self.dirs = root, home, dirs
        self.scripts = plugin / "scripts"
        self.codex_home = home / ".codex"
        mounts = [str(home / "clouddrive"), "/mnt/vault", "/mnt/c"]
        env = {key: value for key, value in os.environ.items()
               if not key.startswith(("CLAUDE_MB_DOGMA", "DOGMA_", "CLAUDE_CODE_SESSION", "GIT_"))}
        env.update({"HOME": str(home), "CODEX_HOME": str(self.codex_home), "USER": USER,
                    "CLAUDE_CONFIG_DIR": str(home / ".claude"), "CLAUDE_PLUGIN_ROOT": str(plugin),
                    "DOGMA_CREDO_CONFIG": "none", "CLAUDE_MB_DOGMA_PROTECTED_MOUNTS": ":".join(mounts),
                    "TMPDIR": str(root)})
        self.env = env

    def decide(self, command, directory, tool="Bash"):
        cwd = str(self.dirs[directory])
        event = json.dumps({"hook_event_name": "PreToolUse", "tool_name": tool,
                            "tool_input": {"command": command}, "cwd": cwd, "session_id": ""})
        env = dict(self.env, DOGMA_SESSION_DIR=cwd)
        reasons = []
        for hook in HOOKS:
            try:
                result = subprocess.run(["bash", str(self.scripts / hook)], input=event, capture_output=True,
                                        text=True, cwd=cwd, env=env, timeout=30)
            except subprocess.TimeoutExpired:
                reasons.append(hook + ": timeout")
                continue
            out = result.stdout
            if '"deny"' in out or '"ask"' in out:
                try:
                    reason = json.loads(out)["hookSpecificOutput"]["permissionDecisionReason"]
                except (ValueError, KeyError, TypeError):
                    reason = out.strip()
                reasons.append("%s: %s" % (hook, reason[:160]))
        return ("deny" if reasons else "allow"), reasons

    def fill_r1(self, command):
        rel = os.path.relpath(self.codex_home, self.dirs["X"]) + "/"
        for key, value in (("<DOGMA_SCRIPT>", str(self.scripts / "bash-guard.py")),
                           ("<CODEX_HOME>", str(self.codex_home)), ("<PROJ>", str(self.dirs["X"])),
                           ("<HOME>", str(self.home)), ("~<USER>", "~" + USER), ("<NL>", "\n"),
                           ("../home/", rel)):
            command = command.replace(key, value)
        return command

    def fill_r2(self, command):
        up = "/".join([".."] * len(Path(os.path.realpath(self.dirs["X"])).parts[1:]))
        for key, value in (("{H}", str(self.home)), ("{U}", USER), ("{CH}", str(self.codex_home)),
                           ("{DS}", str(self.scripts)), ("{X}", str(self.dirs["X"])),
                           ("{N}", str(self.dirs["N"])), ("{R}", str(self.root)), ("{NL}", "\n"),
                           ("{UP}", up)):
            command = command.replace(key, value)
        return command.replace("{{", "{").replace("}}", "}")


def jobs(runner, only):
    """(table, id, expected, directory, tool, command, skip reason)"""
    if only in (None, "r1x"):
        for number, (expected, command) in enumerate(review_r1.REVIEW_X):
            yield "r1x", number, expected, "X", "Bash", runner.fill_r1(command), None
    if only in (None, "r1n"):
        for number, (expected, command) in enumerate(review_r1.REVIEW_N):
            yield "r1n", number, expected, "N", "Bash", runner.fill_r1(command), None
    if only in (None, "r2"):
        for number, group, expected, directory, tool, command in review_r2.CASES:
            skip = "apply_patch (Codex tool)" if tool != "Bash" else None
            yield "r2", number, expected, directory, tool, runner.fill_r2(command), skip
    if only in (None, "local") and local_cases is not None:
        for number, group, expected, directory, tool, command in local_cases.CASES:
            yield "local", number, "record", directory, tool, runner.fill_r2(command), None
    if only in (None, "probes"):
        for number, (command, directory, expected) in enumerate(probes.PROBES):
            yield "probes", number, expected, directory, "Bash", command, None
    if only in (None, "everyday"):
        for number, (command, directory) in enumerate(everyday.EVERYDAY):
            yield "everyday", number, "allow", directory, "Bash", command, None
    if only in (None, "fp"):
        for number, (expected, directory, command) in enumerate(false_positives.CASES):
            yield "fp", number, expected, directory, "Bash", runner.fill_r2(command), None


# PreToolUse hooks of hooks.json for Edit and Write (the tool name is passed where hooks.json does)
EDIT_HOOKS = (("secrets-detection.sh",), ("write-edit-reminder.sh",), ("subagent-enforcement.sh", "TOOL"))


def unit_edits(runner):
    """[(ok, line)]: Edit/Write inputs that change file content are never a deletion."""
    results = []
    for number, (tool, tool_input) in enumerate(false_positives.EDITS):
        tool_input = {key: runner.fill_r2(value) for key, value in tool_input.items()}
        cwd = str(runner.dirs["X"])
        event = json.dumps({"hook_event_name": "PreToolUse", "tool_name": tool, "tool_input": tool_input,
                            "cwd": cwd, "session_id": ""})
        reasons = []
        for hook in EDIT_HOOKS:
            argv = ["bash", str(runner.scripts / hook[0])] + [tool for _ in hook[1:]]
            result = subprocess.run(argv, input=event, capture_output=True, text=True, cwd=cwd,
                                    env=dict(runner.env, DOGMA_SESSION_DIR=cwd), timeout=30)
            if '"deny"' in result.stdout or '"ask"' in result.stdout:
                reasons.append("%s: %s" % (hook[0], result.stdout.strip()[:160]))
        results.append((not reasons, "fp-edit#%d %s must pass: %s" % (number, tool, " | ".join(reasons))))
    return results


def unit_read_content(runner):
    """[(ok, line)]: the Read guard (token-protection.sh) denies a key block and allows a lone PEM header."""
    folder = runner.root / "pem-read"
    folder.mkdir()
    cwd = str(runner.dirs["X"])
    env = dict(runner.env, DOGMA_SESSION_DIR=cwd)
    results = []
    for expected, name, content in false_positives.PEM_READ:
        path = folder / name
        path.write_bytes(content.encode("utf-8"))
        event = json.dumps({"hook_event_name": "PreToolUse", "tool_name": "Read",
                            "tool_input": {"file_path": str(path)}, "cwd": cwd, "session_id": ""})
        result = subprocess.run(["bash", str(runner.scripts / "token-protection.sh")], input=event,
                                capture_output=True, text=True, cwd=cwd, env=env, timeout=30)
        got = "deny" if '"deny"' in result.stdout or '"ask"' in result.stdout else "allow"
        reason_ok = expected == "allow" or "private key" in result.stdout
        results.append((got == expected and reason_ok, "unit read %s (want %s got %s): %s" % (
            name, expected, got, result.stdout.strip()[:160])))
    return results


# (expected, command) with the literal working directory UNIT_CWD; never executed
UNIT_CWD = "/home/someone/proj"
UNIT = (
    ("allow", "rsync -a --delete build/ out/"),
    ("allow", "rsync -av --delete-after src/ /tmp/backup/"),
    ("allow", "chmod -R u+w build"),
    ("allow", "tar --remove-files -czf build.tgz build"),
    ("allow", "cd sub && rm -rf dist"),
    ("deny", "rsync -a --delete build/ /home/"),
    ("deny", "rm -rf /home/someone"),
)


def unit_legacy_cwd():
    """[(ok, line)] for UNIT: bash-guard's hand-over to delete-guard with a /home/ cwd."""
    import importlib.util
    spec = importlib.util.spec_from_file_location("dogma_bash_guard", HERE / "bash-guard.py")
    guard = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(guard)

    class Analysis:
        def __init__(self, command):
            self.batch = [(command.split(), {UNIT_CWD})]

    results = []
    for expected, command in UNIT:
        reason = guard.run_delete_guard(guard.guard_batch(Analysis(command), command, UNIT_CWD), UNIT_CWD, command)
        got = "deny" if reason else "allow"
        results.append((got == expected, "unit (%s, want %s got %s): %s%s" % (
            UNIT_CWD, expected, got, command, (" - " + reason) if reason else "")))
    return results


SCOPE_HINT_COMMANDS = ("git remote -v", "git remote get-url origin", "git config --get remote.origin.url")


def unit_scope_hint(runner):
    """[(ok, line)]: remote denials name the installed git-scope.sh, with python3 and without it."""
    script = runner.scripts / "git-scope.sh"
    hint = "bash %s [dir]" % script
    cwd = str(runner.dirs["X"])
    env = dict(runner.env, DOGMA_SESSION_DIR=cwd)
    results = []
    for command in SCOPE_HINT_COMMANDS:
        event = json.dumps({"hook_event_name": "PreToolUse", "tool_name": "Bash",
                            "tool_input": {"command": command}, "cwd": cwd, "session_id": ""})
        result = subprocess.run(["python3", "-I", str(runner.scripts / "bash-guard.py")], input=event,
                                capture_output=True, text=True, cwd=cwd, env=env, timeout=30)
        reason = result.stdout.strip()
        results.append((hint in reason and script.is_file(),
                        "scope hint (bash-guard, %s): %s" % (command, reason[:200])))
    # token-protection.sh only decides on its own when python3 is missing: a PATH with the
    # tools it needs but no python3 forces that fallback
    bare = runner.root / "no-python-bin"
    bare.mkdir()
    for tool in ("jq", "grep", "sed", "xargs", "date", "stat", "basename", "dirname", "cat", "head", "tr", "wc"):
        found = shutil.which(tool)
        if found:
            (bare / tool).symlink_to(found)
    event = json.dumps({"tool_name": "Bash", "tool_input": {"command": "git remote -v"}, "cwd": cwd})
    result = subprocess.run([shutil.which("bash"), str(runner.scripts / "token-protection.sh")], input=event,
                            capture_output=True, text=True, cwd=cwd, env=dict(env, PATH=str(bare)), timeout=30)
    reason = result.stdout.strip()
    results.append((hint in reason and script.is_file(),
                    "scope hint (token-protection fallback): %s" % reason[:200]))
    return results


def long_json():
    """A minified JSON document of about 37 KB with many braces and commas (a kubectl patch)."""
    items = [{"name": "c%d" % index, "env": [{"name": "K%d" % index, "value": "v,%d" % index}],
              "ports": [{"containerPort": 8000 + index, "protocol": "TCP"}]} for index in range(360)]
    return json.dumps({"spec": {"template": {"spec": {"containers": items}}}}, separators=(",", ":"))


def unit_discard_reason(runner):
    """[(ok, line)]: the discard ask/deny text. A missing (§b4dk) line says to ADD it (or run /dogma:sync),
    a present [ ] line says to change it; neither says "Change [?] to [x]" for a missing line."""
    cwd_missing = str(runner.dirs["F"])
    cwd_off = str(runner.dirs["D"])
    env = dict(runner.env, DOGMA_SESSION_DIR=cwd_missing)
    results = []
    for cwd, want_decision, must, must_not in (
            (cwd_missing, "ask", ("has no line for (§b4dk)", "add `- [?] (§b4dk)", "/dogma:sync"),
             ("Change [?] to [x]",)),
            (cwd_off, "deny", ("Change [ ] to [?] or [x]",), ("has no line for",))):
        event = json.dumps({"hook_event_name": "PreToolUse", "tool_name": "Bash",
                            "tool_input": {"command": "git restore notes.txt"}, "cwd": cwd, "session_id": ""})
        result = subprocess.run(["bash", str(runner.scripts / "file-protection.sh")], input=event,
                                capture_output=True, text=True, cwd=cwd, env=dict(env, DOGMA_SESSION_DIR=cwd),
                                timeout=30)
        try:
            output = json.loads(result.stdout)["hookSpecificOutput"]
            decision, reason = output["permissionDecision"], output["permissionDecisionReason"]
        except (ValueError, KeyError, TypeError):
            decision, reason = "no json", result.stdout.strip()[:200]
        ok = decision == want_decision and all(text in reason for text in must) and \
            not any(text in reason for text in must_not)
        results.append((ok, "discard reason (%s, want %s): %s" % (os.path.basename(cwd), want_decision,
                                                                   reason[:300])))
    return results


TODELETE_HINT = "The target uses a shell variable dogma cannot resolve - retry with the literal path."
TODELETE_TIME = r"\(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\)"


def todelete_folder(runner, name, box):
    """A fresh folder whose DOGMA-PERMISSIONS.md sets the delete setting to box ("[ ]" deny, "[?]" ask)."""
    folder = runner.root / "todelete" / name
    folder.mkdir(parents=True)
    (folder / "DOGMA-PERMISSIONS.md").write_text(
        "<permissions>\n- %s (§0lgy) May delete files\n- [ ] (§b4dk) Discard uncommitted changes\n"
        "</permissions>\n" % box, encoding="utf-8")
    (folder / "notes.txt").write_text("fixture\n", encoding="utf-8")
    return folder


def no_python_path(runner):
    """A PATH directory with the tools the guards use but no python3, which forces the text fallback."""
    bare = runner.root / "todelete-no-python"
    bare.mkdir()
    for tool in ("jq", "grep", "sed", "awk", "cat", "head", "tail", "tr", "wc", "cut", "date", "basename",
                 "dirname", "xargs", "sort", "uniq", "readlink", "realpath", "stat", "mktemp"):
        found = shutil.which(tool)
        if found:
            (bare / tool).symlink_to(found)
    return bare


def run_file_protection(runner, folder, command, bare=None):
    """(decision, reason) of file-protection.sh for one Bash command run from folder."""
    event = json.dumps({"hook_event_name": "PreToolUse", "tool_name": "Bash",
                        "tool_input": {"command": command}, "cwd": str(folder), "session_id": ""})
    env = dict(runner.env, DOGMA_SESSION_DIR=str(folder))
    if bare is not None:
        env["PATH"] = str(bare)
    result = subprocess.run([shutil.which("bash"), str(runner.scripts / "file-protection.sh")], input=event,
                            capture_output=True, text=True, cwd=folder, env=env, timeout=30)
    try:
        output = json.loads(result.stdout)["hookSpecificOutput"]
        return output["permissionDecision"], output["permissionDecisionReason"]
    except (ValueError, KeyError, TypeError):
        return "no json", result.stdout.strip()[:200]


def todelete_lines(folder):
    """The checklist entries of the TO-DELETE.md in folder, or None when the file was not created."""
    path = folder / "TO-DELETE.md"
    if not path.is_file():
        return None
    return [line for line in path.read_text(encoding="utf-8").splitlines() if line.startswith("- [")]


def todelete_entry(target, command=None):
    """Regex of the one TO-DELETE.md entry of a permanent delete, with the command suffix when given.
    A target of None accepts any single-line rm target."""
    shown = r"rm [^`]+" if target is None else re.escape(target)
    text = r"- \[ \] `%s` - Deletes files permanently %s" % (shown, TODELETE_TIME)
    if command is not None:
        text += " - command: `%s`" % re.escape(command)
    return re.compile(text + "$")


def unit_todelete_entry(runner):
    """[(ok, line)]: a denied delete whose target is a shell variable logs its command in TO-DELETE.md and its
    deny or ask reason names the hint; a literal target keeps the plain entry, a discard keeps its reason."""
    variable = 'S=/tmp/x/fx && rm -rf "$S"'
    long_command = variable + " && echo 'a`b' && echo " + "a" * 320
    long_flat = long_command.replace("`", "'")[:300] + "..."
    bare = no_python_path(runner)
    # name, delete setting box, command, want decision, reason text, hint wanted, entry regex or None, bare path
    rows = (
        ("var-deny", "[ ]", variable, "deny", "BLOCKED by dogma", True, todelete_entry("rm $S", variable), None),
        ("var-ask", "[?]", variable, "ask", "requires confirmation", True, None, None),
        ("literal", "[ ]", "rm -rf /home/myuser/proj/old", "deny", "BLOCKED by dogma", False,
         todelete_entry("rm /home/myuser/proj/old"), None),
        ("multi-line", "[ ]", 'S=/tmp/x/fx\nrm -rf "$S"', "deny", "BLOCKED by dogma", True,
         todelete_entry("rm $S", 'S=/tmp/x/fx ; rm -rf "$S"'), None),
        ("long", "[ ]", long_command, "deny", "BLOCKED by dogma", True, todelete_entry("rm $S", long_flat), None),
        ("text-fallback", "[ ]", variable, "deny", "BLOCKED by dogma", True,
         todelete_entry('rm "$S"', variable), bare),
        ("discard", "[ ]", 'F=notes.txt && git restore "$F"', "deny",
         "discards uncommitted changes and is denied", False, None, None),
        # F1 - an operand with an unassigned variable is unsure: the delete setting logs it with the hint
        ("refused-variable", "[ ]", 'rm -rf "$PROJ/build"', "deny", "BLOCKED by dogma", True,
         todelete_entry("rm $PROJ/build", 'rm -rf "$PROJ/build"'), None),
        # F1b - a literal assignment is resolved: a deep project path is no hard target, the setting logs it
        ("literal-deep", "[ ]", 'R=/home/myuser/proj/old/renders && rm -- "$R/final.mp4"', "deny", "BLOCKED by dogma",
         True, todelete_entry("rm $R/final.mp4", 'R=/home/myuser/proj/old/renders && rm -- "$R/final.mp4"'), None),
        # F2 - the variable sits in a later delete of the group, the first target is literal
        ("any-variable", "[ ]", 'S=/tmp/x/fx && rm -rf build && rm -rf "$S"', "deny", "BLOCKED by dogma", True,
         todelete_entry(None, 'S=/tmp/x/fx && rm -rf build && rm -rf "$S"'), None),
        # F3 - a tab is one space in the entry
        ("tab-separator", "[ ]", 'S=/tmp/x/fx\t&& rm -rf "$S"', "deny", "BLOCKED by dogma", True,
         todelete_entry("rm $S", variable), None),
        # F4 - a backslash and a tab in the target keep the reason valid JSON
        ("backslash-target", "[ ]", 'S=/tmp/x/fx && rm -rf "$S/a\\ b"', "deny", 'rm $S/a\\ b logged', True,
         todelete_entry(None, 'S=/tmp/x/fx && rm -rf "$S/a\\ b"'), None),
        ("tab-target", "[ ]", 'S=/tmp/x/fx && rm -rf "$S/a\tb"', "deny", "BLOCKED by dogma", True,
         todelete_entry(None, 'S=/tmp/x/fx && rm -rf "$S/a b"'), None),
        # text fallback: a multi-line command, and two deletes whose targets span two lines
        ("text-multi-line", "[ ]", 'S=/tmp/x/fx\nrm -rf "$S"', "deny", "BLOCKED by dogma", True,
         todelete_entry('rm "$S"', 'S=/tmp/x/fx ; rm -rf "$S"'), bare),
        ("text-two-deletes", "[ ]", 'rm -rf "$S"\nrm -rf "$T"', "deny", "BLOCKED by dogma", True,
         todelete_entry('rm "$S" ; "$T"', 'rm -rf "$S" ; rm -rf "$T"'), bare),
    )
    results = []
    for name, box, command, want, text, hint, entry, path in rows:
        folder = todelete_folder(runner, name, box)
        decision, reason = run_file_protection(runner, folder, command, bare=path)
        lines = todelete_lines(folder)
        if entry is None:
            entry_ok = lines is None
        else:
            entry_ok = lines is not None and len(lines) == 1 and entry.match(lines[0]) is not None
        ok = decision == want and text in reason and (TODELETE_HINT in reason) == hint and entry_ok
        results.append((ok, "todelete %s (want %s, hint %s): reason %s | entries %s" % (
            name, want, hint, reason[:300], lines)))
    return results


def unit_perf():
    """[(ok, line)]: long and pathological arguments are analysed well below the hook timeout."""
    import importlib.util
    import time
    spec = importlib.util.spec_from_file_location("dogma_bash_guard_perf", HERE / "bash-guard.py")
    guard = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(guard)
    flags = {feature: True for feature in guard.FEATURES}
    size = 50000
    texts = {"=": "=" * size, "quote": "'" * size, "paren": "(" * size, "dollar": "!$a" * (size // 3),
             "slash": "x/" * (size // 2)}
    results = []
    for name, text in texts.items():
        for pattern in ("OPAQUE_RE", "FALLBACK_RE"):
            started = time.monotonic()
            getattr(guard, pattern).search(text)
            took = time.monotonic() - started
            results.append((took < 1.0, "unit perf %s on 50 KB %s: %.3fs" % (pattern, name, took)))
    commands = {"json": "kubectl patch deploy web -p '%s'" % long_json(),
                "=": "foo \"%s\"" % texts["="], "quote": "foo \"%s\"" % texts["quote"],
                "paren": "foo \"%s\"" % texts["paren"], "dollar": "foo '%s'" % texts["dollar"]}
    for name, command in commands.items():
        guard.STARTED[0] = time.monotonic()
        started = time.monotonic()
        guard.analyse(command, "/tmp", flags)
        took = time.monotonic() - started
        results.append((took < 1.0, "unit perf analyse 50 KB %s argument: %.3fs" % (name, took)))
    return results


# /proc/self/mounts as bash-guard.py reads it. The real table differs per machine, so the hook
# reads this fixture instead (HOMEDIR is the fake home). Invented names only.
MOUNTS_FIXTURE = (
    "proc /proc proc rw,nosuid 0 0\n"
    "//fileserver/share /mnt/nas/share cifs rw,relatime 0 0\n"
    "//fileserver/deep /mnt/nas/deep/share cifs rw,relatime 0 0\n"
    "/dev/sdb1 /media/usb vfat rw,nosuid 0 0\n"
    "drvfs /mnt/c 9p rw,noatime,aname=drvfs;path=C:;uid=1000 0 0\n"
    "rclone:gdrive HOMEDIR/gdrive fuse.rclone rw,nosuid 0 0\n"
)
# (expected, command, CLAUDE_MB_DOGMA_PROTECTED_MOUNTS) run through the bash-guard hook in process;
# {H} is the fake home. A network share or USB stick below /mnt or /media protects its mount point
# (at any depth), the levels down to depth 4 and the first level below the mount point; deeper files are
# ordinary (the delete setting decides). A mount found in /proc/self/mounts below the home (a cloud drive)
# protects its mount point and first level the same way; a declared mount protects its whole subtree.
MOUNT_CASES = (
    ("allow", "rm /mnt/nas/share/old/x.bin", ""),
    ("deny", "rm -r /mnt/nas/share/tmpdir", ""),
    ("deny", "rm -rf /media/usb/folder/x", ""),
    ("deny", "rm -rf /mnt/nas", ""),
    ("deny", "rm -rf /mnt/nas/share", ""),
    ("deny", "rm -rf /media/usb", ""),
    ("deny", "rm -rf /media/usb/folder", ""),
    ("deny", "rm -rf /mnt/nas/deep/share", ""),
    ("deny", "rm -r /mnt/nas/deep/share/old", ""),
    ("allow", "rm -rf /mnt/c/Users/alice/workspace/proj/old", ""),
    ("deny", "rm -rf /mnt/c", ""),
    ("deny", "rm -rf {H}/gdrive", ""),
    ("allow", "rm -rf {H}/gdrive/old/x.bin", ""),
    ("deny", "rm -rf {H}/gdrive/old", ""),
    ("deny", "rm -rf /mnt/vault/a/b/c/x", "/mnt/vault"),
    ("allow", "rm -rf /mnt/vault2/a/b/c/x", "/mnt/vault"),
    ("allow", "rm -rf /mnt/c/Users/alice/workspace/proj/old", "/mnt/c"),
    ("deny", "rm -rf /mnt/c", "/mnt/c"),
    ("deny", "rm -rf /mnt/nas/share/old/x.bin", "/mnt/nas/share"),
)


def unit_mounts(runner):
    """[(ok, line)]: the bash-guard hook with MOUNTS_FIXTURE in place of /proc/self/mounts."""
    import contextlib
    import importlib.util
    import io
    import time
    spec = importlib.util.spec_from_file_location("dogma_bash_guard_mounts", HERE / "bash-guard.py")
    guard = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(guard)
    fixture = MOUNTS_FIXTURE.replace("HOMEDIR", os.path.realpath(str(runner.home)))
    real_open = open

    def fake_open(path, *args, **kwargs):
        if path == "/proc/self/mounts":
            return io.StringIO(fixture)
        return real_open(path, *args, **kwargs)

    cwd = str(runner.dirs["X"])
    keys = ("HOME", "CLAUDE_MB_DOGMA_PROTECTED_MOUNTS")
    saved = {key: os.environ.get(key) for key in keys}
    saved_stdin = sys.stdin
    results = []
    guard.open = fake_open
    try:
        os.environ["HOME"] = str(runner.home)
        for expected, command, declared in MOUNT_CASES:
            command = command.replace("{H}", str(runner.home))
            os.environ["CLAUDE_MB_DOGMA_PROTECTED_MOUNTS"] = declared
            event = json.dumps({"tool_name": "Bash", "tool_input": {"command": command}, "cwd": cwd})
            sys.stdin = io.StringIO(event)
            out = io.StringIO()
            guard.STARTED[0] = time.monotonic()
            with contextlib.redirect_stdout(out):
                guard.main()
            reason = out.getvalue().strip()
            got = "deny" if reason else "allow"
            results.append((got == expected, "unit mounts (want %s got %s): %s%s" % (
                expected, got, command, (" - " + reason) if reason else "")))
    finally:
        del guard.open
        sys.stdin = saved_stdin
        for key, value in saved.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value
    return results


def main():
    verbose = "-v" in sys.argv
    only = sys.argv[sys.argv.index("--only") + 1] if "--only" in sys.argv else None
    # TERM/HUP end via SystemExit, so the finally below still removes the temp root
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    signal.signal(signal.SIGHUP, lambda *_: sys.exit(129))
    root, home, dirs, plugin = setup()
    try:
        runner = Runner(root, home, dirs, plugin)
        work = list(jobs(runner, only))
        ids = [item[1] for item in work if item[0] == "r2"]
        if len(ids) != len(set(ids)):
            print("FAIL duplicate case ids in review_r2")
            return 1
        todo = [item for item in work if item[6] is None]

        def run(item):
            table, number, expected, directory, tool, command, _skip = item
            return item, runner.decide(command, directory, tool)

        with ThreadPoolExecutor(max_workers=min(16, (os.cpu_count() or 4) * 2)) as pool:
            results = list(pool.map(run, todo))
        failed, counts = [], {}
        recorded = []
        for (table, number, expected, directory, tool, command, _skip), (got, reasons) in results:
            if expected == "record":
                recorded.append("%s#%d: %s" % (table, number, got))
                continue
            ok = got == expected
            passed, total = counts.get(table, (0, 0))
            counts[table] = (passed + ok, total + 1)
            if not ok:
                failed.append("FAIL %s#%d (%s, want %s got %s)%s" % (
                    table, number, directory, expected, got,
                    (": " + " | ".join(reasons)) if verbose and reasons else ""))
        if only in (None, "fp"):
            for ok, line in unit_edits(runner):
                passed, total = counts.get("fp", (0, 0))
                counts["fp"] = (passed + ok, total + 1)
                if not ok:
                    failed.append("FAIL " + line)
        if only in (None, "unit"):
            for ok, line in (unit_legacy_cwd() + unit_perf() + unit_scope_hint(runner) + unit_read_content(runner)
                             + unit_mounts(runner) + unit_discard_reason(runner) + unit_todelete_entry(runner)):
                passed, total = counts.get("unit", (0, 0))
                counts["unit"] = (passed + ok, total + 1)
                if not ok:
                    failed.append("FAIL " + line)
        for line in failed:
            print(line)
        skipped = len(work) - len(todo)
        for table, (passed, total) in sorted(counts.items()):
            print("%-7s passed %d/%d" % (table, passed, total))
        print("passed: %d, failed: %d, skipped: %d" % (sum(p for p, _ in counts.values()), len(failed), skipped))
        if recorded:
            print("local (recorded, not asserted): %s" % ", ".join(recorded))
        return 1 if failed else 0
    finally:
        shutil.rmtree(root, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
