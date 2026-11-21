#!/bin/bash
# kernel_check_one.sh - re-check ONE compiled module with leanchecker. Called by
# 09_kernel_replay.sh through xargs, once per module; not meant to be run by hand.
#
# What it does: runs 'leanchecker <module>' in its own process and appends one line to the
#   results file:  module <TAB> exit status <TAB> seconds <TAB> stamp <TAB> epoch
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
#   Three recorded statuses say nothing about the module, and the summary counts such a module as
#   not yet checked, so that the next run tries it again: 137 (the checker was killed, typically
#   for lack of memory), 143 (terminated, typically by a time limit) and 96 (the checker could
#   not do its work: its output file could not be created, or it stopped because a compiled file
#   could not be opened or found, which is a fault of the installation and not of the module).
#   Any other non-zero status is a failure, including a checker that crashed by itself.
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
  printf '%s\t96\t0\t%s\t%s\n' "$mod" "$stamp" "$t0" >> "$RH_REPLAY_DIR/results.tsv"
  exit 0
fi
if [ "$kind" = prefix ]; then
  LEAN_NUM_THREADS=1 LEAN_PATH="$RH_LEAN_PATH" "$RH_LEANCHECKER" -v "$mod" > "$out" 2>&1
  rc=$?
  # A pass counts only if the checker reported replaying the module itself.
  if [ "$rc" -eq 0 ] && ! grep -qxF "replaying $mod" "$out"; then rc=97; fi
  [ "$rc" -eq 0 ] && mv -f "$out" "$RH_REPLAY_DIR/out/$mod.prefix.out"
else
  LEAN_PATH="$RH_LEAN_PATH" "$RH_LEANCHECKER" "$mod" > "$out" 2>&1
  rc=$?
  [ "$rc" -eq 0 ] && rm -f "$out"
fi
# A checker that could not open or find a compiled file checked nothing. Its output is kept.
if [ "$rc" -ne 0 ] && [ "$rc" -lt 128 ] && grep -qE 'failed to open file|Permission denied|No such file or directory|Could not find any oleans|object file .* does not exist' "$out" 2>/dev/null; then
  rc=96
fi
t1=$(date +%s)
printf '%s\t%s\t%s\t%s\t%s\n' "$mod" "$rc" "$((t1 - t0))" "$stamp" "$t1" >> "$RH_REPLAY_DIR/results.tsv"
# Always succeed, so that xargs carries on with the remaining modules after a failure.
exit 0
