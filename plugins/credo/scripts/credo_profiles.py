"""Local Claude Code profiles of the current user (stdlib only).

A profile is one Claude Code config dir (CLAUDE_CONFIG_DIR) with a sessions/ dir in
it. The LAN relay serves every profile of a machine, so it needs exactly one rule for
which profiles exist:

  - the config dir the caller runs in (the daemon's own profile), always;
  - plus every sibling ~/.claude* dir (".claude", ".claude-work", ...) that holds a
    sessions/ dir, is a directory owned by the current user, and whose real path
    (symlinks resolved) stays inside the home dir. The sessions/ dir itself must be a
    real directory of that user, not a symlink.

Anything else is skipped: an empty profile, a plain file, a foreign-owned dir, a
symlink that leaves HOME. Nothing here writes or creates anything.
"""

import os
import stat


def own_config_dir():
    """CLAUDE_CONFIG_DIR of this process, default ~/.claude."""
    return os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(
        os.path.expanduser("~"), ".claude"
    )


def profile_name(cfg_dir):
    """Short profile name of a config dir, e.g. ".claude-work"."""
    return os.path.basename(cfg_dir.rstrip("/"))


def _inside(path, root):
    return path == root or path.startswith(root + os.sep)


def _owned_real_dir(path, uid):
    """Real path of path when it is a directory owned by uid, else None."""
    try:
        real = os.path.realpath(path)
        st = os.stat(real)
    except OSError:
        return None
    if not stat.S_ISDIR(st.st_mode):
        return None
    if uid is not None and st.st_uid != uid:
        return None
    return real


def _sessions_ok(cfg, home_real, uid):
    sess = os.path.join(cfg, "sessions")
    if os.path.islink(sess):
        return False
    real = _owned_real_dir(sess, uid)
    return real is not None and _inside(real, home_real)


def profile_dirs(own=None, home=None, uid=None):
    """Config dirs of every local profile: the own dir first (always, as given), then
    the sibling ~/.claude* profiles in home that pass the rule in the module docstring.
    A profile is listed once: a config dir with the same real path as one already
    listed is skipped, and so is one whose sessions/ dir has the same real path as the
    sessions/ dir of a profile already listed (the own sessions/ may be a symlink to a
    sibling's, and then both name one registry)."""
    own = own or own_config_dir()
    if uid is None and hasattr(os, "getuid"):
        uid = os.getuid()
    home_real = os.path.realpath(home or os.path.expanduser("~"))
    out = [own]
    seen = {os.path.realpath(own)}
    seen_sessions = {os.path.realpath(os.path.join(own, "sessions"))}
    try:
        names = sorted(os.listdir(home_real))
    except OSError:
        return out
    for name in names:
        if not name.startswith(".claude"):
            continue
        cand = os.path.join(home_real, name)
        real = _owned_real_dir(cand, uid)
        if real is None or not _inside(real, home_real) or real in seen:
            continue
        if not _sessions_ok(cand, home_real, uid):
            continue
        sessions_real = os.path.realpath(os.path.join(cand, "sessions"))
        if sessions_real in seen_sessions:
            continue
        seen.add(real)
        seen_sessions.add(sessions_real)
        out.append(cand)
    return out


def sessions_dirs(own=None, home=None, uid=None):
    """The sessions/ dir of every profile from profile_dirs(), same order."""
    return [os.path.join(p, "sessions") for p in profile_dirs(own, home, uid)]
