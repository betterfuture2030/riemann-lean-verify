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
# Usage: kernel_check_one.sh <module> <stamp>
# Environment (set by 09_kernel_replay.sh): RH_PROJ, RH_REPLAY_DIR, RH_LEAN_PATH, RH_LEANCHECKER.
set -u
mod=${1:?usage: kernel_check_one.sh <module> <stamp>}
stamp=${2:-nohash}
: "${RH_PROJ:?}" "${RH_REPLAY_DIR:?}" "${RH_LEAN_PATH:?}" "${RH_LEANCHECKER:?}"
cd "$RH_PROJ" || exit 1
out="$RH_REPLAY_DIR/out/$mod.out"
t0=$(date +%s)
LEAN_PATH="$RH_LEAN_PATH" "$RH_LEANCHECKER" "$mod" > "$out" 2>&1
rc=$?
t1=$(date +%s)
[ "$rc" -eq 0 ] && rm -f "$out"
printf '%s\t%s\t%s\t%s\t%s\n' "$mod" "$rc" "$((t1 - t0))" "$stamp" "$t1" >> "$RH_REPLAY_DIR/results.tsv"
# Always succeed, so that xargs carries on with the remaining modules after a failure.
exit 0
