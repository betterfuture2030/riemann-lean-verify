#!/bin/bash
# kernel_check_one.sh - re-check ONE compiled module with leanchecker. Called by
# 09_kernel_replay.sh, once per module; not meant to be run by hand.
#
# What it does: runs 'leanchecker <module>' in its own process and appends one line to the
#   results file:
#     module <TAB> status <TAB> seconds <TAB> stamp <TAB> epoch <TAB> leanchecker <TAB> program <TAB> how
#   The stamp identifies the compiled file that was checked (the content hash Lake stores
#   next to it), so that a later run can tell whether the module was compiled again since.
#   "program" is the SHA-256 of the leanchecker binary that was run, and "how" is one of the
#   three ways below. (kernel_check_batch.sh writes the lines of the other tool, rhv-replay.)
# What it changes on disk: appends to RH_REPLAY_DIR/results.tsv; writes the checker's output to
#   RH_REPLAY_DIR/out/<module>.out and removes that file again if the module passed.
# How long it takes: seconds to tens of seconds per module.
#
#   Third argument, how the module is checked:
#   changed   Nothing is run. The compiled file at the module's path is no longer the one the plan read
#             the stamp of (closure-worker found that out); status 96 is recorded and a later run plans
#             the module again with its new stamp.
#   closure   The search path in RH_LEAN_PATH holds, of this project, only the module and what it
#             imports (scripts/verify/rhv_tools.py closure-worker makes that directory and calls this
#             script). leanchecker is run with -v, which makes it print "replaying <module>" for each
#             module it replays, and with one worker thread; the module has passed only if leanchecker
#             ends with status 0 AND printed that line for this module. This is the normal way.
#   closure-beneath   The same, and the directory also holds modules whose names lie beneath this
#             module's (it imports them). leanchecker replays every module whose name begins with its
#             argument, so those are replayed in the same process; the record says so, because a crash
#             of that process cannot be pinned on one of them. The list of what was replayed is kept.
#   (none)    The search path holds the whole library. Only for a module whose name is not a prefix of
#             another module's name: leanchecker checks every module whose name begins with its argument.
#   prefix    The search path holds the whole library and the module's name is a prefix of other
#             modules' names: leanchecker replays it together with every compiled module beneath it,
#             with -v and one worker thread, and the list of what it replayed is kept as
#             RH_REPLAY_DIR/out/<module>.prefix.out. (One worker, because leanchecker starts one task per
#             module and each task imports its module's whole closure; with many workers those imports
#             are held at once: 17.5 GB measured for a module with twelve small modules beneath it,
#             against 0.2 GB with one worker and the same wall time.)
#
#   What the status means.
#     0     leanchecker replayed the module and the kernel accepted every declaration in it.
#     96    Nothing was checked: the output file could not be created, or leanchecker stopped because a
#           compiled file could not be opened or found, which is a fault of the installation and not of
#           the module. This is recognised in two ways and no other. If leanchecker stopped before it
#           started any replay (it prints "leanchecker found a problem in ..." when a replay fails, and
#           had not), it was still reading its arguments or listing the compiled files. If a replay had
#           started, only the BEGINNING of the first "uncaught exception:" line counts, and only the
#           three texts the tool's own file handling writes there. A kernel error quotes names that the
#           author of the module chose, and must never be taken for one of these.
#     97    leanchecker ended with status 0 without reporting that it replayed this module: the module
#           was not tested.
#     98    leanchecker replayed other modules in the same process and rejected one of THEM, not this
#           module. That happens when the module's name is a prefix of the names of modules it can see:
#           the tool replays every module whose name begins with its argument, and reports the first that
#           fails ("leanchecker found a problem in <module>"). This module was not judged; the module
#           named has a check of its own, where the rejection is recorded. The output is kept.
#     129, 130, 137, 143   leanchecker was ended by a signal from outside (hang-up, interrupt, kill,
#           typically for lack of memory, or terminate, typically by a time limit).
#     Those say nothing about the module, which stays "not yet checked". Anything else is a REJECTION
#     (status 1: the replay ended in an error) or a CRASH of the tool on the module (any other status of
#     128 or more), and the summary never replaces either with a later result.
#   leanchecker runs with LEAN_ABORT_ON_PANIC=1, so that an internal error of the Lean runtime, which
#   would otherwise print a message and carry on, ends the process and is recorded as a crash.
#
# Usage: kernel_check_one.sh <module> <stamp> [closure|closure-beneath|prefix|changed]
# Environment (set by 09_kernel_replay.sh): RH_PROJ, RH_REPLAY_DIR, RH_LEAN_PATH, RH_LEANCHECKER,
#   and RH_LEANCHECKER_SHA (the SHA-256 of that binary).
set -u
mod=${1:?usage: kernel_check_one.sh <module> <stamp> [closure|closure-beneath|prefix|changed]}
stamp=${2:-nohash}
kind=${3:-}
: "${RH_PROJ:?}" "${RH_REPLAY_DIR:?}" "${RH_LEAN_PATH:?}" "${RH_LEANCHECKER:?}"
prog=${RH_LEANCHECKER_SHA:-unknown}
case "$kind" in closure) how=import-closure-directory ;; closure-beneath) how=import-closure-directory-holding-modules-beneath ;;
  prefix) how=whole-library-with-the-modules-beneath ;;
  changed) how=not-run-the-compiled-file-changed-after-the-plan ;; *) how=whole-library ;; esac
cd "$RH_PROJ" || exit 1
out="$RH_REPLAY_DIR/out/$mod.out"
record() { printf '%s\t%s\t%s\t%s\t%s\tleanchecker\t%s\t%s\n' "$mod" "$1" "$2" "$stamp" "$3" "$prog" "$how" >> "$RH_REPLAY_DIR/results.tsv"; }   # status seconds epoch
t0=$(date +%s)
if [ "$kind" = changed ]; then record 96 0 "$t0"; exit 0; fi
if ! : > "$out" 2>/dev/null; then      # for example a full disk: nothing was checked
  record 96 0 "$t0"
  exit 0
fi
if [ "$kind" = closure ] || [ "$kind" = closure-beneath ] || [ "$kind" = prefix ]; then
  LEAN_ABORT_ON_PANIC=1 LEAN_NUM_THREADS=1 LEAN_PATH="$RH_LEAN_PATH" "$RH_LEANCHECKER" -v "$mod" > "$out" 2>&1
  rc=$?
  # A pass counts only if the checker reported replaying the module itself.
  if [ "$rc" -eq 0 ] && ! grep -qxF "replaying $mod" "$out"; then rc=97; fi
  if [ "$rc" -eq 0 ]; then
    # Keep the list when the tool replayed other modules with this one; otherwise there is nothing to keep.
    if [ "$(grep -c '^replaying ' "$out")" -gt 1 ]; then mv -f "$out" "$RH_REPLAY_DIR/out/$mod.prefix.out"; else rm -f "$out"; fi
  fi
else
  LEAN_ABORT_ON_PANIC=1 LEAN_PATH="$RH_LEAN_PATH" "$RH_LEANCHECKER" "$mod" > "$out" 2>&1
  rc=$?
  [ "$rc" -eq 0 ] && rm -f "$out"
fi
# A checker that could not open or find a compiled file checked nothing. Its output is kept.
if [ "$rc" -ne 0 ] && [ "$rc" -lt 128 ] && [ "$rc" -ne 97 ]; then
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
  # A rejection of ANOTHER module replayed in the same process is not a judgement of this one. The tool names
  # the module it stopped at; when that is not this module, this module was not judged.
  if [ "$rc" -ne 96 ]; then
    culprit=$(sed -n 's/^leanchecker found a problem in //p' "$out" 2>/dev/null | head -1)
    if [ -n "$culprit" ] && [ "$culprit" != "$mod" ]; then rc=98; fi
  fi
fi
t1=$(date +%s)
record "$rc" "$((t1 - t0))" "$t1"
# Always succeed, so that the caller carries on with the remaining modules.
exit 0
