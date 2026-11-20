"""Where the analysis scripts find their inputs and put their outputs.

Each directory is taken, in this order, from
  1. the command line of the script that asks,
  2. the environment variables RH_PROJ, RH_AN and RH_LOGS,
  3. scripts/lib.sh, the same file the shell scripts use, which reads config.env and RH_WORKDIR,
  4. <repository>/work, the default work directory.
No path is hard-coded.
"""
import os
import subprocess

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
_cache = {}


def _from_lib():
    """Ask scripts/lib.sh for RH_PROJ, RH_AN and RH_LOGS."""
    if _cache:
        return _cache
    lib = os.path.join(REPO_ROOT, "scripts", "lib.sh")
    names = ("RH_PROJ", "RH_AN", "RH_LOGS")
    try:
        out = subprocess.run(
            ["bash", "-c", '. "$1" && printf "%s\\n" "$RH_PROJ" "$RH_AN" "$RH_LOGS"', "bash", lib],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, universal_newlines=True, timeout=30)
        lines = out.stdout.splitlines()
        if out.returncode == 0 and len(lines) == 3 and all(lines):
            _cache.update(zip(names, lines))
    except (OSError, subprocess.SubprocessError):
        pass
    if not _cache:
        work = os.environ.get("RH_WORKDIR") or os.path.join(REPO_ROOT, "work")
        _cache.update({"RH_PROJ": os.path.join(work, "extract", "lean"),
                       "RH_AN": os.path.join(work, "analysis"),
                       "RH_LOGS": os.path.join(work, "logs")})
    return _cache


def _pick(arg, var):
    return arg or os.environ.get(var) or _from_lib()[var]


def src_dir(arg=None):
    """The Lean source directory (the directory that contains Main.lean)."""
    return arg or os.path.join(_pick(None, "RH_PROJ"), "src")


def analysis_dir(arg=None):
    """Where derived data (import graph, statistics) is read from and written to."""
    return _pick(arg, "RH_AN")


def logs_dir(arg=None):
    """Where the build logs and build-status.txt are."""
    return _pick(arg, "RH_LOGS")
