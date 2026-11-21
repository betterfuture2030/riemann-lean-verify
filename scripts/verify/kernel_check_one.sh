#!/bin/bash
# kernel_check_one.sh - re-check ONE compiled module with leanchecker. Called by
# 09_kernel_replay.sh through xargs, once per module; not meant to be run by hand.
#
# What it does: runs 'leanchecker <module>' in its own process and appends one line to the
#   results file:  module <TAB> exit status <TAB> seconds <TAB> stamp <TAB> epoch <TAB> leanchecker
#   The last column names the method (kernel_check_batch.sh writes "rhv-replay" there).
#   The stamp identifies the compiled file that was checked (the content hash Lake stores
#   next to it), so that a later run can tell whether the module was compiled again since.
# What it changes on disk: appends to RH_REPLAY_DIR/results.tsv; writes the checker's output to
#   RH_REPLAY_DIR/out/<module>.out and removes that file again if the module passed.
# How long it takes: seconds to tens of seconds per module.
#
#   With a third argument "prefix", the module is one whose name is a prefix of other modules'
#   names. leanchecker then replays it together with every compiled module beneath it. It is run
#   with -v, which makes it print one "replaying <module>" line for each, and on success that
#   list is kept as RH_REPLAY_DIR/out/<module>.prefix.out as the record of what was covered.
#   It is also run with one worker thread. leanchecker starts one task per module and each task
#   imports its module's whole closure; with many workers those imports are held at once
#   (measured: 17.5 GB for a module with twelve small modules beneath it, against 0.2 GB with one
#   worker and the same wall time).
#
#   Some recorded statuses say nothing about the module, and the summary counts such a module as not yet
#   checked, so that the next run tries it again: 129, 130, 137 and 143 (the checker was ended by a signal from
#   outside: hang-up, interrupt, kill, typically for lack of memory, or terminate, typically by a time limit)
#   and 96 (the checker could not do its work: its output file could not be created, or it stopped because a
#   compiled file could not be opened or found, which is a fault of the installation and not of the module).
#   That last case is recognised in two ways and no other. If the checker stopped before it started any
#   replay (it prints "leanchecker found a problem in ..." when a replay fails, and had not), it was still
#   reading its arguments or listing the compiled files, and no module had been looked at. If a replay had
#   started, only the BEGINNING of the first "uncaught exception:" line counts, and only the three texts the
#   tool's own file handling writes there. A kernel error quotes names that the author of the module chose,
#   and must never be taken for one of these.
#   Any other non-zero status is a failure; a checker that crashed by itself (another status of 128 or more)
#   is counted as a failure and reported apart.
#   The checker runs with LEAN_ABORT_ON_PANIC=1, so that an internal error of the Lean runtime, which would
#   otherwise print a message and carry on, ends the process and is recorded as a crash.
#
# Usage: kernel_check_one.sh <module> <stamp> [prefix]
# Environment (set by 09_kernel_replay.sh): RH_PROJ, RH_REPLAY_DIR, RH_LEAN_PATH, RH_LEANCHECKER.
set -u
mod=${1:?usage: kernel_check_one.sh <module> <stamp> [prefix]}
stamp=${2:-nohash}
kind=${3:-}
: "${RH_PROJ:?}" "${RH_REPLAY_DIR:?}" "${RH_LEAN_PATH:?}" "${RH_LEANCHECKER:?}"
cd "$RH_PROJ" || exit 1
out="$RH_REPLAY_DIR/out/$mod.out"
t0=$(date +%s)
if ! : > "$out" 2>/dev/null; then      # for example a full disk: nothing was checked
  printf '%s\t96\t0\t%s\t%s\tleanchecker\n' "$mod" "$stamp" "$t0" >> "$RH_REPLAY_DIR/results.tsv"
  exit 0
fi
if [ "$kind" = prefix ]; then
  LEAN_ABORT_ON_PANIC=1 LEAN_NUM_THREADS=1 LEAN_PATH="$RH_LEAN_PATH" "$RH_LEANCHECKER" -v "$mod" > "$out" 2>&1
  rc=$?
  # A pass counts only if the checker reported replaying the module itself.
  if [ "$rc" -eq 0 ] && ! grep -qxF "replaying $mod" "$out"; then rc=97; fi
  [ "$rc" -eq 0 ] && mv -f "$out" "$RH_REPLAY_DIR/out/$mod.prefix.out"
else
  LEAN_ABORT_ON_PANIC=1 LEAN_PATH="$RH_LEAN_PATH" "$RH_LEANCHECKER" "$mod" > "$out" 2>&1
  rc=$?
  [ "$rc" -eq 0 ] && rm -f "$out"
fi
# A checker that could not open or find a compiled file checked nothing. Its output is kept.
if [ "$rc" -ne 0 ] && [ "$rc" -lt 128 ]; then
  first=$(grep -m 1 '^uncaught exception: ' "$out" 2>/dev/null)
  if grep -q '^leanchecker found a problem in ' "$out" 2>/dev/null; then
    # A replay was started and ended in an error. It checked nothing only if the error begins as the tool's
    # own file handling writes it.
    case "$first" in
      "uncaught exception: failed to open file '"*|"uncaught exception: object file '"*|"uncaught exception: unknown module prefix '"*) rc=96 ;;
    esac
  elif [ -n "$first" ]; then
    # It stopped before it replayed anything: while reading its arguments or listing the compiled files (no
    # module found for the name, a directory it could not read, too many open files). No module was looked at.
    rc=96
  fi
fi
t1=$(date +%s)
printf '%s\t%s\t%s\t%s\t%s\tleanchecker\n' "$mod" "$rc" "$((t1 - t0))" "$stamp" "$t1" >> "$RH_REPLAY_DIR/results.tsv"
# Always succeed, so that xargs carries on with the remaining modules after a failure.
exit 0
