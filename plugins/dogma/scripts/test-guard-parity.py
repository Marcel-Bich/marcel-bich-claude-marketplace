#!/usr/bin/env python3
"""Parity tests: the dogma Bash PreToolUse guards against the review case tables.

SAFETY: no case command is ever executed. Every command is only handed to the hook
scripts as PreToolUse JSON on stdin. All paths live in a fresh temporary directory with a
fake HOME inside it, so even a hook bug could not touch real data. The hooks run from a
copy of the plugin installed below the fake Claude configuration home (like a real
install), so the self-protection of installed hook files is tested too.

A case counts as "deny" when any guard hook answers deny or ask (both stop the command),
otherwise as "allow". Case tables live in guard-cases/: two review rounds (round 2 with
explicit ids), the audit probes and everyday commands that must pass. apply_patch cases
(a Codex tool) are skipped. An optional local table (guard-cases/local_cases.py, not
versioned) is run and reported without being asserted.

A unit table ("unit") runs the bash-guard -> delete-guard hand-over in process with a
literal working directory below /home/ (no directory is created), so the legacy text
patterns are proven to see only the command, never the generated "cd <dir>" lines.

Usage: test-guard-parity.py [-v] [--only r1x|r1n|r2|probes|everyday|local|unit]
"""

import json
import os
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
    # W: an allow-all project whose path contains a /home/<user> segment (outside the fake home)
    dirs = {"P": root / "perm", "N": root / "noperm", "X": root / "allow" / "proj",
            "W": root / "home" / "someone" / "proj"}
    for directory in list(dirs.values()) + [home]:
        directory.mkdir(parents=True)
    (dirs["P"] / "DOGMA-PERMISSIONS.md").write_text(
        "# perms\n<permissions>\n- [ ] (§6gpt) May git add\n- [ ] (§2w1t) May git commit\n"
        "- [?] (§bww9) May git push\n</permissions>\n", encoding="utf-8")
    (dirs["X"] / "DOGMA-PERMISSIONS.md").write_text(
        "<permissions>\n- [x] (§6gpt) May git add\n- [x] (§2w1t) May git commit\n"
        "- [x] (§bww9) May git push\n- [x] (§0lgy) May delete files\n</permissions>\n", encoding="utf-8")
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
    return home, dirs, plugin


class Runner:
    def __init__(self, root, home, dirs, plugin):
        self.root, self.home, self.dirs = root, home, dirs
        self.scripts = plugin / "scripts"
        self.codex_home = home / ".codex"
        mounts = [str(home / "clouddrive"), "/mnt/nas/share", "/mnt/c"]
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


def long_json():
    """A minified JSON document of about 37 KB with many braces and commas (a kubectl patch)."""
    items = [{"name": "c%d" % index, "env": [{"name": "K%d" % index, "value": "v,%d" % index}],
              "ports": [{"containerPort": 8000 + index, "protocol": "TCP"}]} for index in range(360)]
    return json.dumps({"spec": {"template": {"spec": {"containers": items}}}}, separators=(",", ":"))


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
        if only in (None, "unit"):
            for ok, line in unit_legacy_cwd() + unit_perf():
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
