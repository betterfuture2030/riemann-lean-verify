#!/bin/bash
# 09_kernel_replay.sh - re-check compiled modules with Lean's kernel, independently of the
# compile that produced them.
#
# What it does: runs 'leanchecker' on compiled modules, one process per module, RH_JOBS at a
#   time. For each module, leanchecker loads the module's imports and replays every declaration
#   the module adds through the kernel. This detects compiled files whose contents were not
#   actually accepted by the kernel (the tool's own description: it is "not an external
#   verifier", it detects "environment hacking"). It does not judge whether an axiom is
#   acceptable: an 'axiom' declaration replays fine. Axioms are the business of 08.
#
#   leanchecker treats its argument as a name PREFIX and checks every module whose name starts
#   with it, in one process. So only modules whose name is not a prefix of another module's
#   name are checked here, one at a time; the few that are prefixes are counted and listed in
#   the summary as not checked. (In the source tree, 114 of 175,187 modules are such prefixes.)
#
#   The run is resumable. Results are appended to a file, and modules already recorded as
#   passed are skipped, unless they were compiled again since (Lake's content hash changed).
#   Failed modules are tried again on the next run. It can run while the build is running,
#   but it competes with it for CPU and memory.
# What it changes on disk: writes under RH_WORKDIR/analysis/kernel_replay: results.tsv
#   (appended), summary.json, and out/<module>.out for modules that failed.
# How long it takes: 14 to 28 seconds of wall time per module, measured on 24 modules on
#   2026-11-20 with several thousand modules built and the build running alongside. Most of
#   it was system time. The tool's source suggests why: before checking one module it lists
#   every compiled file on the search path, so the cost per module should grow as the build
#   grows. At 15 seconds each, the 175,073 eligible modules are about 30 days of single-process
#   time, or about 4 days with 8 at once, and probably more. Use --sample for a spot check.
#
# Usage: scripts/09_kernel_replay.sh [--sample N] [--seed S] [--jobs N] [--list FILE] [--summary]
#   --sample N   check a random sample of N eligible modules (the same N and seed give the
#                same sample, so an interrupted sample can be resumed)
#   --seed S     seed for --sample (default 20261120)
#   --jobs N     parallel checker processes (default: RH_JOBS, else the recommended value)
#   --list FILE  check the modules named in FILE (one per line) instead of all eligible ones
#   --summary    print the summary of the recorded results and exit; checks nothing
# Exit status: 0 if no recorded module has failed, 1 if any has, 2 if it could not run.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"
. "$HERE/common.sh"

SAMPLE=0; SEED=20261120; JOBS=""; LIST=""; SUMMARY_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --sample) shift; [ $# -gt 0 ] || die "--sample needs a number"; SAMPLE=$1 ;;
    --seed) shift; [ $# -gt 0 ] || die "--seed needs a number"; SEED=$1 ;;
    --jobs) shift; [ $# -gt 0 ] || die "--jobs needs a number"; JOBS=$1 ;;
    --list) shift; [ $# -gt 0 ] || die "--list needs a file"; LIST=$1 ;;
    --summary) SUMMARY_ONLY=1 ;;
    -h|--help) show_help; exit 0 ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
  shift
done
case "$SAMPLE" in ''|*[!0-9]*) die "--sample must be a number" ;; esac
case "$SEED" in ''|*[!0-9]*) die "--seed must be a number" ;; esac
need_cmd python3
LIB="$RH_PROJ/.lake/build/lib/lean"
REPLAY="$RH_AN/kernel_replay"
RESULTS="$REPLAY/results.tsv"
set -- --lib "$LIB" --src "$RH_PROJ/src" --results "$RESULTS"

if [ "$SUMMARY_ONLY" -eq 1 ]; then
  python3 -B "$RH_TOOLS" replay-summary "$@"
  exit $?
fi

[ -d "$LIB" ] || { echo "ERROR: no compiled modules found at $LIB (run steps 04 and 05 first)" >&2; exit 2; }
[ -z "$LIST" ] || [ -f "$LIST" ] || { echo "ERROR: list file not found: $LIST" >&2; exit 2; }
need_cmd xargs
bindir=$(toolchain_bin_dir)
RH_LEANCHECKER="$bindir/leanchecker"
[ -n "$bindir" ] && [ -x "$RH_LEANCHECKER" ] || {
  echo "ERROR: leanchecker not found next to the pinned toolchain's lean (looked in '${bindir:-nowhere}')" >&2; exit 2; }
JOBS=$(effective_jobs "$JOBS")
ensure_dirs
mkdir -p "$REPLAY/out" || die "cannot create $REPLAY/out"
[ -f "$RESULTS" ] || printf 'module\texit_status\tseconds\tstamp\tepoch\n' > "$RESULTS"
log "work directory: $RH_WORKDIR"
log "checker: $RH_LEANCHECKER"

TODO="$REPLAY/todo.tsv"
plan_args="--retry-failed"
[ "$SAMPLE" -gt 0 ] && plan_args="$plan_args --sample $SAMPLE --seed $SEED"
# shellcheck disable=SC2086
if [ -n "$LIST" ]; then
  python3 -B "$RH_TOOLS" replay-plan "$@" $plan_args --list "$LIST" > "$TODO" || { echo "ERROR: could not plan the run" >&2; exit 2; }
else
  python3 -B "$RH_TOOLS" replay-plan "$@" $plan_args > "$TODO" || { echo "ERROR: could not plan the run" >&2; exit 2; }
fi
n=$(wc -l < "$TODO" | tr -d ' ')

if [ "$n" -gt 0 ]; then
  log "checking $n modules, $JOBS at a time (interrupt with Ctrl-C at any time; finished results are kept)"
  raise_nofile
  RH_REPLAY_DIR="$REPLAY"; RH_LEAN_PATH="$(lean_path)"
  export RH_PROJ RH_REPLAY_DIR RH_LEAN_PATH RH_LEANCHECKER
  # Each line of the plan is "module<TAB>stamp"; hand both to one checker process.
  tr '\n\t' '\0\0' < "$TODO" | xargs -0 -n 2 -P "$JOBS" "$HERE/verify/kernel_check_one.sh"
  log "checker processes finished (xargs status $?)"
else
  log "nothing to check: every selected module already has a current passing result"
fi

python3 -B "$RH_TOOLS" replay-summary "$@" --json "$REPLAY/summary.json"
status=$?
log "results: $RESULTS   summary: $REPLAY/summary.json"
exit "$status"
