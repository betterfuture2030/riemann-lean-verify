"""Where the analysis scripts find their inputs and put their outputs.

Each directory is taken, in this order, from
  1. the command line of the script that asks,
  2. the environment variables RH_PROJ, RH_AN and RH_LOGS,
  3. scripts/lib.sh, the same file the shell scripts use, which reads config.env, RH_WORKDIR and the
     target (RH_TARGET, see targets/README.md),
  4. for the default target only, and only when scripts/lib.sh cannot be asked (no bash, for
     example): the default target's layout under RH_WORKDIR, or under <repository>/work.
The source directory is the project directory followed by the target's TGT_SRC_DIR ("src" for the
default target; "." is the project directory itself). The target's root module is TGT_ROOT_MODULE
("Main" for the default target). Each is taken from the environment if it is set there; otherwise
from scripts/lib.sh, like the directories. One exception keeps what was done before there were
targets: for the default target, with RH_PROJ set in the environment or every directory given on the
command line, nothing is asked and the default target's values are used.

Nothing is guessed for another target. If scripts/lib.sh stops with an error (the working directory
belongs to another target, a profile is incomplete), the script that asked stops with that error.
If scripts/lib.sh cannot be asked and the target named is not the default one, it stops as well.
"""
import os
import re
import subprocess
import sys

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_TARGET = "alpoge-rh"
_NAMES = ("RH_TARGET", "RH_PROJ", "RH_AN", "RH_LOGS", "TGT_SRC_DIR", "TGT_ROOT_MODULE")
_DEFAULT_VALUES = {"TGT_SRC_DIR": "src", "TGT_ROOT_MODULE": "Main"}
_cache = {}


def _from_lib():
    """Ask scripts/lib.sh for RH_TARGET, RH_PROJ, RH_AN, RH_LOGS, TGT_SRC_DIR and TGT_ROOT_MODULE."""
    if _cache:
        return _cache
    lib = os.path.join(REPO_ROOT, "scripts", "lib.sh")
    errors = []
    try:
        out = subprocess.run(
            ["bash", "-c", '. "$1" && printf "%s\\n" "$RH_TARGET" "$RH_PROJ" "$RH_AN" "$RH_LOGS" "$TGT_SRC_DIR" "$TGT_ROOT_MODULE"',
             "bash", lib],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True, errors="surrogateescape",
            timeout=30)
        lines = out.stdout.splitlines()
        if out.returncode == 0 and len(lines) == len(_NAMES) and all(lines):
            _cache.update(zip(_NAMES, lines))
        elif out.returncode != 0:
            # lib.sh reports what it refuses on lines that start with "ERROR: ".
            errors = [line for line in out.stderr.splitlines() if line.startswith("ERROR: ")]
    except (OSError, subprocess.SubprocessError):
        pass
    if errors:
        sys.exit("\n".join(errors))
    if not _cache:
        _cache.update(_default_layout())
    return _cache


def _target_named():
    """The target named in the environment or in config.env, as far as that can be told without a shell."""
    if "RH_TARGET" in os.environ:
        return os.environ["RH_TARGET"] or DEFAULT_TARGET
    target = ""
    try:
        with open(os.path.join(REPO_ROOT, "config.env"), encoding="utf-8", errors="replace") as fh:
            for line in fh:
                m = re.match(r"\s*(?:export\s+)?RH_TARGET=(.*)", line)
                if m:
                    target = m.group(1).split("#")[0].strip().strip("\"'")
    except OSError:
        pass
    return target or DEFAULT_TARGET


def _default_layout():
    """The default target's layout, for when scripts/lib.sh cannot be asked. Any other target is refused."""
    work = os.environ.get("RH_WORKDIR") or os.path.join(REPO_ROOT, "work")
    target = _target_named()
    if target != DEFAULT_TARGET:
        sys.exit("ERROR: scripts/lib.sh could not be asked where target '%s' keeps its files, and without it only "
                 "the default target's layout is known. Name the directories on the command line, or run this "
                 "where bash can read scripts/lib.sh." % target)
    try:
        with open(os.path.join(work, ".rh-target"), encoding="utf-8", errors="replace") as fh:
            owner = fh.readline().rstrip("\n")
    except OSError:
        owner = DEFAULT_TARGET      # no marker: a directory from before markers, or a new one
    if owner == "":
        sys.exit("ERROR: the file %s is empty, so it does not say which target the working directory belongs "
                 "to. If the directory is target '%s''s, write that name into the file and run the command again: "
                 "see targets/README.md" % (os.path.join(work, ".rh-target"), DEFAULT_TARGET))
    if owner != DEFAULT_TARGET:
        sys.exit("ERROR: the working directory %s belongs to target '%s' (its file .rh-target says so) and "
                 "this command is for target '%s'. Every target has a working directory of its own: see "
                 "targets/README.md" % (work, owner, DEFAULT_TARGET))
    return {"RH_TARGET": DEFAULT_TARGET, "RH_PROJ": os.path.join(work, "extract", "lean"),
            "RH_AN": os.path.join(work, "analysis"),
            "RH_LOGS": os.path.join(work, "logs"),
            "TGT_SRC_DIR": "src", "TGT_ROOT_MODULE": "Main"}


def _pick(arg, var):
    return arg or os.environ.get(var) or _from_lib()[var]


def _unasked(paths_given):
    """True when scripts/lib.sh is not asked: for the default target, with RH_PROJ set in the environment or
    with every directory the script needs given on its command line (paths_given), as before there were
    targets."""
    return bool(paths_given or os.environ.get("RH_PROJ")) and _target_named() == DEFAULT_TARGET


def _target_value(var, paths_given=False):
    """A TGT_ setting: from the environment if set there; otherwise what scripts/lib.sh says, except where
    _unasked (then the default target's value)."""
    if os.environ.get(var):
        return os.environ[var]
    if _unasked(paths_given):
        return _DEFAULT_VALUES[var]
    return _from_lib()[var]


def target(paths_given=False):
    """The name of the target the analysis is for (see _target_value for when scripts/lib.sh is asked)."""
    if _unasked(paths_given):
        return DEFAULT_TARGET
    return _from_lib()["RH_TARGET"]


def src_dir(arg=None):
    """The Lean source directory (for the default target, the directory that contains Main.lean)."""
    if arg:
        return arg
    sub = _target_value("TGT_SRC_DIR")
    proj = _pick(None, "RH_PROJ")
    return proj if sub == "." else os.path.join(proj, sub)


def root_module(arg=None, paths_given=False):
    """The module whose import closure is computed (for the default target, Main)."""
    return arg or _target_value("TGT_ROOT_MODULE", paths_given)


def analysis_dir(arg=None):
    """Where derived data (import graph, statistics) is read from and written to."""
    return _pick(arg, "RH_AN")


def logs_dir(arg=None):
    """Where the build logs and build-status.txt are."""
    return _pick(arg, "RH_LOGS")
