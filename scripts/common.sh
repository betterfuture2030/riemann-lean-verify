#!/bin/bash
# common.sh - functions shared by the numbered scripts. Source it after lib.sh:
#   HERE="$(cd "$(dirname "$0")" && pwd)"; . "$HERE/lib.sh"; . "$HERE/common.sh"
#
# What it does: defines shell functions and a few read-only variables.
# What it changes on disk: nothing. Sourcing this file has no side effects.
# How long it takes: no measurable time.
#
# Works with bash 3.2 (macOS) and bash 5 (Linux), with BSD and GNU userlands.

# The status marks that Lake prints at the start of each job line. They are built from
# octal escapes so that this file stays plain ASCII.
MARK_OK=$(printf '\342\234\224')     # U+2714: job succeeded
MARK_WARN=$(printf '\342\232\240')   # U+26A0: job succeeded with warnings
MARK_INFO=$(printf '\342\204\271')   # U+2139: job succeeded with info-level output (counted by 06 for targets other than the default)
MARK_FAIL=$(printf '\342\234\226')   # U+2716: job failed

# The paths that used to be set here (RH_TARBALL, RH_PART_BASENAME, RH_EXPECTED, RH_PARTS_RECORD and
# RH_TOOLS) are set in lib.sh, with the other paths that follow from the target.

# Print the header comment of the calling script (everything after the first line up to the
# first line that is not a comment).
show_help() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

# sha256 of standard input.
sha256_stdin() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d' ' -f1; else shasum -a 256 | cut -d' ' -f1; fi
}

# Physical (symlink-free) path of a directory; empty output and status 1 if it does not exist.
phys_dir() { (cd "$1" 2>/dev/null && pwd -P); }

# The nearest existing ancestor of a path (the path itself if it exists).
existing_ancestor() {
  local p=$1
  while [ ! -e "$p" ] && [ "$p" != "/" ] && [ -n "$p" ]; do p=$(dirname "$p"); done
  printf '%s\n' "$p"
}

# Free space, in KiB, on the filesystem that holds (or will hold) the given path.
disk_free_kb() {
  df -Pk "$(existing_ancestor "$1")" 2>/dev/null | awk 'NR > 1 { for (i = 2; i <= NF; i++) if ($i ~ /^[0-9]+%$/) { print $(i - 1); exit } }'
}

# Recommended number of parallel compiler processes: min(cores, (RAM_GB - 8) / 2), at least 1.
# This is a rule of thumb (about 2 GB per compiler process, 8 GB left for the system), not a
# measured requirement. On a 10-core, 24 GB Mac it gives 8, which was also the fastest setting
# in a direct comparison of 3 to 10 jobs on 2026-11-20; at 10 jobs about half of all CPU time
# was spent in the operating system. Use 07_tune_jobs.sh to measure on your own machine.
recommended_jobs() {
  local c m j
  c=$(ncpu); m=$(mem_gb)
  j=$(( (m - 8) / 2 ))
  [ "$j" -gt "$c" ] && j=$c
  [ "$j" -lt 1 ] && j=1
  printf '%s\n' "$j"
}

# The job count to use: the argument if given, else RH_JOBS, else the recommended value.
effective_jobs() {
  local j=${1:-$RH_JOBS}
  case "$j" in
    ''|*[!0-9]*|0) recommended_jobs ;;
    *) printf '%s\n' "$j" ;;
  esac
}

# Raise the open-file limit for this shell and its children to at least 65,536. A limit that is
# already higher is left alone.
raise_nofile() {
  local cur
  cur=$(ulimit -n 2>/dev/null)
  case "$cur" in unlimited) return 0 ;; ''|*[!0-9]*) ;; *) [ "$cur" -ge 65536 ] && return 0 ;; esac
  ulimit -n 65536 2>/dev/null || ulimit -n "$(ulimit -Hn)" 2>/dev/null || true
}

# Number of compiled modules (.olean files) of the project itself (dependencies not included).
count_oleans() {
  if [ -d "$RH_PROJ/.lake/build/lib" ]; then
    find "$RH_PROJ/.lake/build/lib" -name '*.olean' -type f 2>/dev/null | wc -l | tr -d ' '
  else
    echo 0
  fi
}

# Number of Lean source files of the project: the .lean files under its source directory. When that is the
# project directory itself (TGT_SRC_DIR=.), what Lake keeps in .lake is not counted.
count_sources() {
  if [ ! -d "$RH_SRC" ]; then echo 0
  elif [ "$TGT_SRC_DIR" = . ]; then (cd "$RH_SRC" && find . -path ./.lake -prune -o -name '*.lean' -type f -print) | wc -l | tr -d ' '
  else find "$RH_SRC" -name '*.lean' -type f | wc -l | tr -d ' '; fi
}

# Directory that holds the pinned toolchain's binaries (lean, lake, leanchecker), or empty.
# elan chooses the toolchain from the lean-toolchain file in the current directory.
toolchain_bin_dir() {
  local l
  if command -v elan >/dev/null 2>&1; then
    l=$(cd "$RH_PROJ" 2>/dev/null && elan which lean 2>/dev/null) || l=""
    [ -n "$l" ] && [ -x "$l" ] && { dirname "$l"; return 0; }
  fi
  l=$(command -v lean 2>/dev/null) || l=""
  [ -n "$l" ] && dirname "$l"
}

# ---------------------------------------------------------------------------------------------
# Process inspection. All of this is read-only.

# PIDs of processes whose executable is named $1 (for example lake, lean, leanchecker).
pids_named() {
  ps -A -o pid= -o comm= 2>/dev/null | awk -v want="$1" '
    { pid = $1; sub(/^ *[0-9]+ +/, ""); n = split($0, p, "/"); if (p[n] == want) print pid }'
}

# Current working directory of a process, or empty if it cannot be determined.
proc_cwd() {
  if [ -e "/proc/$1/cwd" ]; then
    (cd "/proc/$1/cwd" 2>/dev/null && pwd -P)
  elif command -v lsof >/dev/null 2>&1; then
    lsof -a -d cwd -p "$1" -Fn 2>/dev/null | sed -n 's/^n//p' | head -n 1
  fi
}

# Full command line of a process.
proc_args() { ps -ww -o args= -p "$1" 2>/dev/null; }

# Does process $1 belong to this project? True if its working directory is RH_PROJ or its
# command line names a path inside RH_PROJ.
proc_in_project() {
  local proj cwd args
  proj=$(phys_dir "$RH_PROJ") || proj=$RH_PROJ
  cwd=$(proc_cwd "$1")
  [ -n "$cwd" ] && [ "$cwd" = "$proj" ] && return 0
  args=$(proc_args "$1") || return 1
  case "$args" in *"$proj/"*|*"$RH_PROJ/"*) return 0 ;; esac
  return 1
}

# PIDs of processes named $1 that belong to this project.
project_pids_named() {
  local pid
  for pid in $(pids_named "$1"); do
    proc_in_project "$pid" && printf '%s\n' "$pid"
  done
  return 0
}

# PID of the detached build launcher recorded in build.pid, if that process is still alive and
# is recognisably a launcher for this project (so that a recycled PID is never mistaken for it).
build_runner_pid() {
  local pid args
  [ -f "$RH_LOGS/build.pid" ] || return 0
  pid=$(tr -cd '0-9' < "$RH_LOGS/build.pid")
  [ -n "$pid" ] || return 0
  kill -0 "$pid" 2>/dev/null || return 0
  args=$(proc_args "$pid") || return 0
  case "$args" in *build*) ;; *) return 0 ;; esac
  proc_in_project "$pid" && printf '%s\n' "$pid"
  return 0
}

# PIDs of `lake build` processes that belong to this project. Other lake processes (for example
# an editor's `lake serve`, or a build of a different project) are not reported.
lake_build_pids() {
  local pid args runner
  runner=$(build_runner_pid)
  for pid in $(pids_named lake); do
    args=$(proc_args "$pid") || continue
    case " $args " in *"lake build "*) ;; *) continue ;; esac
    if proc_in_project "$pid"; then
      printf '%s\n' "$pid"
    elif [ -n "$runner" ] && [ "$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')" = "$runner" ]; then
      printf '%s\n' "$pid"
    fi
  done
  return 0
}

# True if a build of this project appears to be running.
build_is_running() {
  [ -n "$(build_runner_pid)" ] && return 0
  [ -n "$(lake_build_pids)" ] && return 0
  return 1
}
