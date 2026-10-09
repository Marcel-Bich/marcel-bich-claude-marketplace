"""GNU getopt_long style option parsing for the commands the dogma guards inspect.

Used by bash-guard.py and delete-guard.py so both read the same operands. Short options
may be bundled (-rf, -ft DIR, -ftDIR): a value-taking letter at the end of a bundle takes
the next argument, in the middle it takes the rest of the bundle. Long options accept
any unique prefix down to one letter (--t=DIR, --t DIR), with "=" or a separate value
for required arguments; optional arguments only with "=". "--" ends the options;
options and operands may be mixed (GNU permutation).

POSIXLY_CORRECT (and popt's POSIX_ME_HARDER) switch the tools to POSIX mode, where the
options end at the first operand. Whether it is set cannot be known reliably before the
command runs (an inline assignment, an export earlier in the command, a sourced file, the
hook's own environment), so callers check both readings: parse_modes() returns the GNU and
the POSIX parse, and every target either one yields is checked.

rsync parses with popt: long options match exactly (no abbreviations), and an unknown
long option is reported as ("?--name", None) so the caller can fail closed.
"""

# value kinds of long options
import re

NONE, REQUIRED, OPTIONAL = 0, 1, 2

_BACKUP = {"backup": OPTIONAL, "suffix": REQUIRED, "target-directory": REQUIRED, "no-target-directory": NONE,
           "verbose": NONE, "help": NONE, "version": NONE, "debug": NONE}

TABLES = {
    "cp": ("St", dict(_BACKUP, **{
        "archive": NONE, "attributes-only": NONE, "copy-contents": NONE, "force": NONE, "interactive": NONE,
        "link": NONE, "dereference": NONE, "no-clobber": NONE, "no-dereference": NONE, "preserve": OPTIONAL,
        "no-preserve": REQUIRED, "parents": NONE, "recursive": NONE, "reflink": OPTIONAL,
        "remove-destination": NONE, "sparse": REQUIRED, "strip-trailing-slashes": NONE, "symbolic-link": NONE,
        "update": OPTIONAL, "one-file-system": NONE, "context": OPTIONAL, "keep-directory-symlink": NONE}),
           ),
    "mv": ("St", dict(_BACKUP, **{
        "context": NONE, "exchange": NONE, "force": NONE, "interactive": NONE, "no-clobber": NONE,
        "no-copy": NONE, "strip-trailing-slashes": NONE, "update": OPTIONAL})),
    "install": ("gmoSt", dict(_BACKUP, **{
        "compare": NONE, "directory": NONE, "group": REQUIRED, "mode": REQUIRED, "owner": REQUIRED,
        "preserve-timestamps": NONE, "strip": NONE, "strip-program": REQUIRED, "preserve-context": NONE,
        "context": OPTIONAL})),
    "ln": ("St", dict(_BACKUP, **{
        "directory": NONE, "force": NONE, "interactive": NONE, "logical": NONE, "no-dereference": NONE,
        "physical": NONE, "relative": NONE, "symbolic": NONE})),
    "rm": ("", {"force": NONE, "interactive": OPTIONAL, "one-file-system": NONE, "no-preserve-root": NONE,
                "preserve-root": OPTIONAL, "recursive": NONE, "dir": NONE, "verbose": NONE, "help": NONE,
                "version": NONE}),
    # rsync 3.2.x, from rsync --help plus the aliases in options.c; popt matches exactly
    "rsync": ("eBTfM@", dict({name: REQUIRED for name in (
        "info", "debug", "stderr", "backup-dir", "suffix", "chmod", "checksum-choice", "cc", "block-size",
        "rsh", "rsync-path", "max-delete", "max-size", "min-size", "max-alloc", "partial-dir", "usermap",
        "groupmap", "chown", "timeout", "contimeout", "modify-window", "temp-dir", "compare-dest",
        "copy-dest", "link-dest", "compress-choice", "zc", "compress-level", "zl", "skip-compress", "filter",
        "exclude", "exclude-from", "include", "include-from", "files-from", "copy-as", "address", "port",
        "sockopts", "outbuf", "remote-option", "out-format", "log-format", "log-file", "log-file-format",
        "password-file", "early-input", "bwlimit", "stop-after", "time-limit", "stop-at", "write-batch",
        "only-write-batch", "read-batch", "protocol", "iconv", "checksum-seed", "config", "dparam")},
        **{name: NONE for name in (
            "verbose", "quiet", "no-motd", "checksum", "archive", "recursive", "relative", "no-implied-dirs",
            "backup", "update", "inplace", "append", "append-verify", "dirs", "old-dirs", "old-d", "mkpath",
            "links", "copy-links", "copy-unsafe-links", "safe-links", "munge-links", "copy-dirlinks",
            "keep-dirlinks", "hard-links", "perms", "executability", "acls", "xattrs", "owner", "group",
            "devices", "copy-devices", "write-devices", "specials", "times", "atimes", "open-noatime",
            "crtimes", "omit-dir-times", "omit-link-times", "super", "fake-super", "sparse", "preallocate",
            "dry-run", "whole-file", "one-file-system", "existing", "ignore-existing", "ignore-non-existing",
            "remove-source-files", "remove-sent-files", "del", "delete", "delete-before", "delete-during",
            "delete-delay", "delete-after", "delete-excluded", "ignore-missing-args", "delete-missing-args",
            "ignore-errors", "force", "partial", "delay-updates", "prune-empty-dirs", "numeric-ids",
            "ignore-times", "size-only", "fuzzy", "compress", "old-compress", "new-compress", "cvs-exclude",
            "from0", "old-args", "secluded-args", "protect-args", "trust-sender", "blocking-io", "stats",
            "8-bit-output", "human-readable", "progress", "itemize-changes", "list-only", "fsync", "ipv4",
            "ipv6", "version", "help", "inc-recursive", "i-r", "msgs2stderr", "qsort", "daemon", "detach",
            "server", "sender", "implied-dirs", "i-d")})),
}
# wrappers that run a command: their options always end at the first operand (getopt "+")
TABLES["env"] = ("uCSa", {
    "ignore-environment": NONE, "null": NONE, "unset": REQUIRED, "chdir": REQUIRED, "split-string": REQUIRED,
    "block-signal": OPTIONAL, "default-signal": OPTIONAL, "ignore-signal": OPTIONAL,
    "list-signal-handling": NONE, "debug": NONE, "argv0": REQUIRED, "help": NONE, "version": NONE})
TABLES["sudo"] = ("aCcDgpRrTtUu", {
    "askpass": NONE, "auth-type": REQUIRED, "background": NONE, "bell": NONE, "close-from": REQUIRED,
    "login-class": REQUIRED, "chdir": REQUIRED, "preserve-env": OPTIONAL, "edit": NONE, "group": REQUIRED,
    "set-home": NONE, "help": NONE, "host": REQUIRED, "login": NONE, "remove-timestamp": NONE,
    "reset-timestamp": NONE, "list": NONE, "no-update": NONE, "non-interactive": NONE,
    "preserve-groups": NONE, "prompt": REQUIRED, "chroot": REQUIRED, "role": REQUIRED, "stdin": NONE,
    "shell": NONE, "type": REQUIRED, "command-timeout": REQUIRED, "other-user": REQUIRED, "user": REQUIRED,
    "version": NONE, "validate": NONE})
TABLES["doas"] = ("aCu", {})  # -C checks a config file (no chdir); no long options
# letters without a value that a wrapper knows; any other letter is reported as "?-x"
_SU = {"command": REQUIRED, "session-command": REQUIRED, "fast": NONE, "group": REQUIRED,
       "supp-group": REQUIRED, "login": NONE, "preserve-environment": NONE, "pty": NONE, "shell": REQUIRED,
       "whitelist-environment": REQUIRED, "help": NONE, "version": NONE}
TABLES["su"] = ("cgGsw", _SU)
TABLES["runuser"] = ("cgGswu", dict(_SU, user=REQUIRED))
# launchers that start a command in their own working directory or root
TABLES["systemd-run"] = ("uMHpEC", {name: REQUIRED for name in (
    "unit", "property", "description", "slice", "uid", "gid", "nice", "setenv", "working-directory",
    "on-active", "on-boot", "on-startup", "on-unit-active", "on-unit-inactive", "on-calendar",
    "timer-property", "path-property", "socket-property", "service-type", "machine", "host", "capsule",
    "json", "background", "expand-environment", "job-mode")} | {name: NONE for name in (
    "user", "system", "scope", "same-dir", "pty", "pipe", "quiet", "collect", "remain-after-exit",
    "send-sighup", "no-ask-password", "no-block", "shell", "wait", "help", "version", "on-clock-change",
    "on-timezone-change", "slice-inherit", "ignore-failure", "verbose")})
TABLES["nsenter"] = ("tSG", {
    "target": REQUIRED, "mount": OPTIONAL, "uts": OPTIONAL, "ipc": OPTIONAL, "net": OPTIONAL, "pid": OPTIONAL,
    "user": OPTIONAL, "cgroup": OPTIONAL, "time": OPTIONAL, "all": NONE, "setuid": REQUIRED, "setgid": REQUIRED,
    "preserve-credentials": NONE, "root": OPTIONAL, "wd": OPTIONAL, "wdns": REQUIRED, "env": NONE,
    "no-fork": NONE, "follow-context": NONE, "user-parent": NONE, "keep-caps": NONE, "join-cgroup": NONE,
    "help": NONE, "version": NONE})
TABLES["unshare"] = ("RwSGl", {
    "mount": OPTIONAL, "uts": OPTIONAL, "ipc": OPTIONAL, "net": OPTIONAL, "pid": OPTIONAL, "user": OPTIONAL,
    "cgroup": OPTIONAL, "time": OPTIONAL, "fork": NONE, "kill-child": OPTIONAL, "mount-proc": OPTIONAL,
    "mount-binfmt": OPTIONAL, "map-root-user": NONE, "map-current-user": NONE, "map-auto": NONE,
    "map-user": REQUIRED, "map-group": REQUIRED, "map-users": REQUIRED, "map-groups": REQUIRED,
    "owner": REQUIRED, "propagation": REQUIRED, "setgroups": REQUIRED, "keep-caps": NONE, "setuid": REQUIRED,
    "setgid": REQUIRED, "root": REQUIRED, "wd": REQUIRED, "monotonic": REQUIRED, "boottime": REQUIRED,
    "load-interp": REQUIRED, "help": NONE, "version": NONE})
TABLES["start-stop-daemon"] = ("xapnucgrdNPIksRO", {
    "start": NONE, "stop": NONE, "status": NONE, "exec": REQUIRED, "startas": REQUIRED, "pidfile": REQUIRED,
    "remove-pidfile": NONE, "ppid": REQUIRED, "name": REQUIRED, "user": REQUIRED, "chuid": REQUIRED,
    "group": REQUIRED, "chroot": REQUIRED, "chdir": REQUIRED, "nicelevel": REQUIRED, "procsched": REQUIRED,
    "iosched": REQUIRED, "umask": REQUIRED, "signal": REQUIRED, "retry": REQUIRED, "background": NONE,
    "notify-await": NONE, "notify-timeout": REQUIRED, "no-close": NONE, "output": REQUIRED,
    "make-pidfile": NONE, "test": NONE, "oknodo": NONE, "quiet": NONE, "verbose": NONE, "help": NONE,
    "version": NONE})
TABLES["chroot"] = ("", {"userspec": REQUIRED, "groups": REQUIRED, "skip-chdir": NONE, "help": NONE,
                         "version": NONE})
KNOWN_SHORT = {"env": "iv0", "sudo": "ABbEeHiKklNnPSsVv", "doas": "Lns", "su": "flmpPhV", "runuser": "flmpPhV",
               "systemd-run": "rtPqGdShV", "nsenter": "aFZcehV", "unshare": "frchV",
               "start-stop-daemon": "SKTHVtoqbCmv", "chroot": ""}
# short options with an optional value (attached only)
OPTIONAL_SHORT = {"sudo": "h", "nsenter": "muinpUCTrw", "unshare": "muinpUCT"}
WRAPPERS = ("env", "sudo", "doas")
LAUNCHERS = ("systemd-run", "nsenter", "unshare", "start-stop-daemon", "chroot")
# getopt "+": the options end at the first operand
_POSIX_ALWAYS = set(WRAPPERS) | {"systemd-run", "nsenter", "unshare", "chroot"}
TABLES["unlink"] = ("", {"help": NONE, "version": NONE})
TABLES["rmdir"] = ("", {"ignore-fail-on-non-empty": NONE, "parents": NONE, "verbose": NONE, "help": NONE,
                        "version": NONE})


def resolve_long(longs, name):
    """Full long option name for an exact name or a unique prefix; None when unknown or ambiguous."""
    if name in longs:
        return name
    matches = [full for full in longs if full.startswith(name)]
    return matches[0] if len(matches) == 1 else None


# popt (rsync) matches long options exactly; "--no-X" negates any option
EXACT = {"rsync"}


def parse(verb, args, posix=False):
    """(options, operands) for verb; options as ("-x" or "--name", value or None).

    posix=True: the options end at the first operand (POSIXLY_CORRECT). An unknown long
    option is kept as ("?--name", None). Returns None when the verb has no table."""
    scanned = scan(verb, args, posix)
    return None if scanned is None else scanned[:2]


def scan_wrapper(verb, args):
    """env, sudo, doas: (options, rest, split) where rest starts at the wrapped command.

    The options end at the first operand. For env -S/--split-string the scan stops there:
    split is the string and rest the arguments after it (env splits the string and goes on
    parsing options from it). Unknown letters or long options are reported as "?..."."""
    options, rest, stopped = scan(verb, args, True, stop=("-S", "--split-string") if verb == "env" else ())
    split = options[-1][1] if stopped else None
    return (options[:-1] if stopped else options), rest, split


def scan(verb, args, posix=False, stop=()):
    """(options, operands, stopped): stopped is True when an option in stop ended the scan
    (operands then hold the arguments after it)."""
    table = TABLES.get(verb)
    if table is None:
        return None
    short_values, longs = table
    posix = posix or verb in _POSIX_ALWAYS
    known_short = KNOWN_SHORT.get(verb)
    optional_short = OPTIONAL_SHORT.get(verb, "")
    options, operands, position = [], [], 0
    while position < len(args):
        if options and options[-1][0] in stop:
            return options, list(args[position:]), True
        arg = args[position]
        if arg == "--":
            operands.extend(args[position + 1:])
            break
        if posix and (not arg.startswith("-") or arg == "-"):
            operands.extend(args[position:])
            break
        if arg.startswith("--"):
            name, equals, value = arg[2:].partition("=")
            if verb in EXACT:
                full = name if name in longs else None
                if full is None and name.startswith("no-") and not equals:
                    options.append((arg, None))
                    position += 1
                    continue
            else:
                full = resolve_long(longs, name)
            if full is None:
                # unknown or ambiguous: the tool refuses to run; marked for callers that fail closed
                options.append(("?" + arg, None))
            elif longs[full] == REQUIRED and not equals:
                options.append(("--" + full, args[position + 1] if position + 1 < len(args) else None))
                position += 1
            else:
                options.append(("--" + full, value if equals else None))
            position += 1
            continue
        if arg.startswith("-") and len(arg) > 1:
            index = 1
            while index < len(arg):
                letter = arg[index]
                if letter in short_values:
                    if index + 1 < len(arg):
                        options.append(("-" + letter, arg[index + 1:]))
                    else:
                        options.append(("-" + letter, args[position + 1] if position + 1 < len(args) else None))
                        position += 1
                    break
                if letter in optional_short:
                    options.append(("-" + letter, arg[index + 1:] or None))
                    break
                if known_short is not None and letter not in known_short:
                    options.append(("?-" + letter, None))
                else:
                    options.append(("-" + letter, None))
                index += 1
            position += 1
            continue
        operands.append(arg)
        position += 1
    if options and options[-1][0] in stop:
        return options, [], True
    return options, operands, False


def has(options, *names):
    return any(name in names for name, _value in options)


def value(options, *names):
    """Last value of any of the given options (GNU: the last one wins)."""
    found = None
    for name, item in options:
        if name in names and item is not None:
            found = item
    return found


def parse_modes(verb, args):
    """The distinct parses of args: GNU permutation first, then POSIX mode when it differs."""
    gnu = parse(verb, args)
    if gnu is None:
        return []
    posix = parse(verb, args, posix=True)
    return [gnu] if posix == gnu else [gnu, posix]


def copy_layout(verb, args, posix=False):
    """For cp, mv, install and ln: (options, sources, destination, into_directory, no_target).

    destination is None when there is none; into_directory is True with -t/--target-directory."""
    parsed = parse(verb, args, posix)
    if parsed is None:
        return None
    options, operands = parsed
    target = value(options, "-t", "--target-directory")
    no_target = has(options, "-T", "--no-target-directory")
    if target is not None:
        return options, operands, target, True, no_target
    if len(operands) > 1:
        return options, operands[:-1], operands[-1], False, no_target
    return options, operands, None, False, no_target


def copy_layouts(verb, args):
    """copy_layout for the GNU and (when it differs) the POSIX reading of args."""
    gnu = copy_layout(verb, args)
    if gnu is None:
        return []
    posix = copy_layout(verb, args, posix=True)
    return [gnu] if posix == gnu else [gnu, posix]


_ENV_ESCAPES = {'"': '"', "#": "#", "$": "$", "'": "'", "\\": "\\", "f": "\f", "n": "\n", "r": "\r",
                "t": "\t", "v": "\v"}


def env_split(text):
    """Words of an env -S string, split as GNU env does; ValueError when env would refuse it.

    Whitespace separates words outside quotes; "\\_" separates outside double quotes and is
    a space inside them; "\\c" ends the string; "#" at the start of a word starts a comment;
    inside single quotes only \\\\ and \\' are escapes. ${NAME} is kept as written (the
    caller expands what it knows); any other "$" or an unknown escape is refused."""
    words, current, sep, single, double, position = [], None, True, False, False, 0

    def word():
        nonlocal current, sep
        if sep:
            if current is not None:
                words.append(current)
            current, sep = "", False

    while position < len(text):
        char = text[position]
        if char == "'" and not double:
            single = not single
            word()
            position += 1
            continue
        if char == '"' and not single:
            double = not double
            word()
            position += 1
            continue
        if char in " \t\n\v\f\r" and not (single or double):
            sep = True
            position += 1
            continue
        if char == "#" and sep:
            break
        if char == "\\" and not (single and text[position + 1:position + 2] not in ("\\", "'")):
            position += 1
            if position >= len(text):
                raise ValueError("backslash at the end of the string")
            escape = text[position]
            if escape == "_":
                if not double:
                    sep = True
                    position += 1
                    continue
                char = " "
            elif escape == "c":
                if double:
                    raise ValueError("\\c inside double quotes")
                single = double = False
                break
            elif escape in _ENV_ESCAPES:
                char = _ENV_ESCAPES[escape]
            else:
                raise ValueError("unknown escape \\%s" % escape)
        elif char == "$" and not single:
            match = re.match(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}", text[position:])
            if not match:
                raise ValueError("only ${NAME} expansion is supported")
            word()
            current += match.group(0)
            position += match.end()
            continue
        word()
        current += char
        position += 1
    if single or double:
        raise ValueError("no terminating quote")
    if current is not None:
        words.append(current)
    return words
