#!/bin/bash
# kernel_check_batch.sh - re-check a BATCH of compiled modules with rhv-replay, one after another in one
# process. Called by 09_kernel_replay.sh --method rhv-replay through xargs, once per batch; not meant to be
# run by hand.
#
# What it does: runs scripts/verify/replay's rhv-replay on the modules named in a batch file and appends one
#   line per module to the results file, as each module finishes:
#     module <TAB> status <TAB> seconds <TAB> stamp <TAB> epoch <TAB> rhv-replay <TAB> program <TAB> batch
#   The sixth column names the tool; lines written by kernel_check_one.sh say "leanchecker" there. The stamp
#   identifies the compiled file that was checked (the content hash Lake stores next to it). "program" is the
#   SHA-256 of the rhv-replay binary that was run, so that results can be tied to one program.
# What it changes on disk: appends to RH_REPLAY_DIR/results.tsv; writes the error of a module that failed to
#   RH_REPLAY_DIR/out/<module>.replay.out; keeps a temporary directory under RH_REPLAY_DIR/tmp while it runs.
# How long it takes: a few seconds per module (docs/performance-notes.md, section 10).
#
#   Statuses recorded.
#     0    the kernel accepted every declaration of the module.
#     1    the replay ended in an error: the tool REJECTED the module. Like a crash (below), this is never
#          replaced by a later result; the summary keeps every line.
#     96   nothing was checked. Either the program's error begins with one of three texts that its own file
#          handling produces before any replay starts ("failed to open file '", "object file '", "unknown module
#          prefix '"), which is a fault of the installation; or the program could not be started, stopped
#          without a word, or printed something this script does not expect. Only the beginning of the error is
#          looked at: a kernel error quotes names that the author of the module chose, and must never be taken
#          for one of these.
#     128 and above: the program died while it was on this module (its REPLAY_START was the last line it
#          printed). 129, 130, 137 and 143 are a signal from outside (hang-up, interrupt, kill, terminate), which
#          the summary counts as not yet checked; anything else is a CRASH of the tool on the module.
#   Whatever happens to a process, every module it had finished is already recorded, and a new process takes
#   the rest of the batch. A process that dies between two modules is charged to neither. One that dies before
#   it has started its first module cannot run here: the rest of the batch is recorded as 96 and left for a
#   later run.
#   The program runs with LEAN_ABORT_ON_PANIC=1, so that an internal error of the Lean runtime, which would
#   otherwise print a message and carry on, ends the process and is recorded as a crash.
#
# Usage: kernel_check_batch.sh <batch file>      (lines: module <TAB> stamp)
# Environment (set by 09_kernel_replay.sh): RH_PROJ, RH_REPLAY_DIR, RH_LEAN_PATH, RH_REPLAY_DRIVER, and
#   RH_REPLAY_DRIVER_SHA (the SHA-256 of that binary).
set -u
batch=${1:?usage: kernel_check_batch.sh <batch file>}
: "${RH_PROJ:?}" "${RH_REPLAY_DIR:?}" "${RH_LEAN_PATH:?}" "${RH_REPLAY_DRIVER:?}"
cd "$RH_PROJ" || exit 1
res="$RH_REPLAY_DIR/results.tsv"
tab=$(printf '\t')
prog=${RH_REPLAY_DRIVER_SHA:-unknown}
record() { printf '%s\t%s\t%s\t%s\t%s\trhv-replay\t%s\tbatch\n' "$1" "$2" "$3" "$4" "$(date +%s)" "$prog" >> "$res"; }   # module status seconds stamp
all_not_run() { while IFS=$tab read -r m s _; do [ -n "$m" ] && record "$m" 96 0 "$s"; done < "$1"; }

work=$(mktemp -d "$RH_REPLAY_DIR/tmp/batch.XXXXXX" 2>/dev/null) || { all_not_run "$batch"; exit 0; }   # e.g. a full disk
trap 'rm -rf "$work"' EXIT
grep -v '^$' "$batch" > "$work/left" || { all_not_run "$batch"; exit 0; }

while [ -s "$work/left" ]; do
  cut -f1 "$work/left" > "$work/names"
  : > "$work/n"; rm -f "$work/cur" "$work/out_of_step"
  # File descriptor 3 reads the batch, a line for each REPLAY_START, so that it stays in step with the program.
  LEAN_ABORT_ON_PANIC=1 LEAN_NUM_THREADS=1 LEAN_PATH="$RH_LEAN_PATH" "$RH_REPLAY_DRIVER" --list "$work/names" 2> "$work/err" | {
    n=0; mod=""; stamp=""; started=0
    while IFS= read -r line; do
      kind=${line%% *}; rest=${line#* }
      if [ "$kind" = REPLAY_START ] && [ "$started" = 0 ]; then
        IFS=$tab read -r mod stamp _ <&3 || { : > "$work/out_of_step"; break; }
        [ "$rest" = "$mod" ] || { : > "$work/out_of_step"; break; }       # not the module expected next
        started=1; printf '%s\t%s\n' "$mod" "$stamp" > "$work/cur"
        continue
      fi
      # A result line must be for the module just started. The module's name is compared as a whole (it is
      # not split at spaces), and what follows it must begin with a number of milliseconds.
      if [ "$started" != 1 ]; then : > "$work/out_of_step"; break; fi
      case "$line" in
        "REPLAY_OK $mod "*)   kind=OK;   rest=${line#"REPLAY_OK $mod "} ;;
        "REPLAY_FAIL $mod "*) kind=FAIL; rest=${line#"REPLAY_FAIL $mod "} ;;
        *) : > "$work/out_of_step"; break ;;
      esac
      ms=${rest%% *}
      case "$ms" in ''|*[!0-9]*) : > "$work/out_of_step"; break ;; esac
      secs="$((ms / 1000)).$((ms % 1000 / 100))"
      if [ "$kind" = OK ]; then
        [ "$rest" = "$ms" ] || { : > "$work/out_of_step"; break; }       # nothing may follow the milliseconds
        record "$mod" 0 "$secs" "$stamp"
      else
        msg=${rest#* }; st=1
        printf '%s\n' "$line" > "$RH_REPLAY_DIR/out/$mod.replay.out" 2>/dev/null
        # Only the three errors the program's own file handling raises, recognised by how the error BEGINS.
        case "$msg" in "failed to open file '"*|"object file '"*|"unknown module prefix '"*) st=96 ;; esac
        record "$mod" "$st" "$secs" "$stamp"
      fi
      started=0; rm -f "$work/cur"
      n=$((n + 1)); echo "$n" > "$work/n"
    done
  } 3< "$work/left"
  rc=${PIPESTATUS[0]}
  n=$(cat "$work/n" 2>/dev/null); case "$n" in ''|*[!0-9]*) n=0 ;; esac
  total=$(wc -l < "$work/left" | tr -d ' ')
  [ "$n" -ge "$total" ] && break
  # The program stopped before it had reported every module. Lines 1..n of the batch are recorded.
  charged=0
  if [ -e "$work/out_of_step" ]; then
    # Its output was not what this script expects: nothing can be concluded about the module due next.
    IFS=$tab read -r mod stamp _ < <(sed -n "$((n + 1))p" "$work/left")
    [ -s "$work/err" ] && cp "$work/err" "$RH_REPLAY_DIR/out/$mod.replay.err" 2>/dev/null
    record "$mod" 96 0 "$stamp"; charged=1
  elif [ -s "$work/cur" ]; then
    # It had started a module and never reported it: it died on that module, or was killed while on it.
    IFS=$tab read -r mod stamp _ < "$work/cur"
    st=$rc; [ "$st" -lt 128 ] && st=96
    [ -s "$work/err" ] && cp "$work/err" "$RH_REPLAY_DIR/out/$mod.replay.err" 2>/dev/null
    record "$mod" "$st" 0 "$stamp"; charged=1
  elif [ "$n" -eq 0 ]; then
    # It never started a module: it cannot run here (not found, not executable, died at start-up, wrong usage).
    [ -s "$work/err" ] && cp "$work/err" "$RH_REPLAY_DIR/out/batch-$(basename "$work").err" 2>/dev/null
    all_not_run "$work/left"; break
  fi
  # Otherwise it stopped between two modules, as it does after reporting a failure: the rest is simply next.
  sed -n "$((n + charged + 1)),\$p" "$work/left" > "$work/next"; mv -f "$work/next" "$work/left"
done
# Always succeed, so that xargs carries on with the remaining batches.
exit 0
