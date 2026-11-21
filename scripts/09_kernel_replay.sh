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
#   with it, in one process. So modules whose name is not a prefix of another module's name are
#   checked one at a time. The few that are prefixes (114 of 175,187 in the source tree, with
#   119 modules beneath the largest) are checked afterwards in a second pass, the "prefix pass":
#   one process each, which replays the module together with every compiled module beneath it
#   and records the list of what it replayed. A sample (--sample) or a list (--list) skips the
#   prefix pass; --prefix-modules runs it alone.
#
#   The run is resumable. Results are appended to a file, and modules already recorded as
#   passed are skipped, unless they were compiled again since (Lake's content hash changed).
#   Failed modules are tried again on the next run. It can run while the build is running,
#   but it competes with it for CPU and memory.
# What it changes on disk: writes under RH_WORKDIR/analysis/kernel_replay: results.tsv
#   (appended), summary.json, out/<module>.out for modules that failed, and
#   out/<module>.prefix.out for each prefix module that passed.
# How long it takes: on a 10-core, 24 GB Mac, 14 to 28 seconds of wall time per module, measured
#   on 24 modules on 2026-11-20 with the build running alongside: days for the whole tree. On a
#   Linux machine with 16 cores, 32 threads and 256 GB, 32 at a time, 2,233 modules took 10
#   minutes: 3.7 per second, an estimated 14 hours for the whole tree (docs/cloud-notes.md,
#   section 8). Most of the cost is importing, not checking. Use --sample for a spot check.
#
# Usage: scripts/09_kernel_replay.sh [--sample N] [--seed S] [--jobs N] [--list FILE]
#                                    [--prefix-modules] [--summary]
#   --sample N   check a random sample of N eligible modules (the same N and seed give the
#                same sample, so an interrupted sample can be resumed)
#   --seed S     seed for --sample (default 20261120)
#   --jobs N     parallel checker processes (default: RH_JOBS, else the recommended value)
#   --list FILE  check the modules named in FILE (one per line) instead of all eligible ones
#   --prefix-modules  run only the prefix pass
#   --summary    print the summary of the recorded results and exit; checks nothing
# Exit status: 0 if no recorded module has failed (and, for a run over everything, every source
#   module is compiled and has passed); 1 if any module has failed; 2 if it could not run; 3 if
#   nothing has failed but a run over everything is not yet complete (run it again).
#   A checker killed by a signal counts as not yet checked, not as failed.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"
. "$HERE/common.sh"

SAMPLE=0; SEED=20261120; JOBS=""; LIST=""; SUMMARY_ONLY=0; PREFIX_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --sample) shift; [ $# -gt 0 ] || die "--sample needs a number"; SAMPLE=$1 ;;
    --seed) shift; [ $# -gt 0 ] || die "--seed needs a number"; SEED=$1 ;;
    --jobs) shift; [ $# -gt 0 ] || die "--jobs needs a number"; JOBS=$1 ;;
    --list) shift; [ $# -gt 0 ] || die "--list needs a file"; LIST=$1 ;;
    --prefix-modules) PREFIX_ONLY=1 ;;
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
  python3 -I -B "$RH_TOOLS" replay-summary "$@"
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
raise_nofile
RH_REPLAY_DIR="$REPLAY"; RH_LEAN_PATH="$(lean_path)"
export RH_PROJ RH_REPLAY_DIR RH_LEAN_PATH RH_LEANCHECKER

if [ "$PREFIX_ONLY" -eq 0 ]; then
  plan_args="--retry-failed"
  [ "$SAMPLE" -gt 0 ] && plan_args="$plan_args --sample $SAMPLE --seed $SEED"
  # shellcheck disable=SC2086
  if [ -n "$LIST" ]; then
    python3 -I -B "$RH_TOOLS" replay-plan "$@" $plan_args --list "$LIST" > "$TODO" || { echo "ERROR: could not plan the run" >&2; exit 2; }
  else
    python3 -I -B "$RH_TOOLS" replay-plan "$@" $plan_args > "$TODO" || { echo "ERROR: could not plan the run" >&2; exit 2; }
  fi
  n=$(wc -l < "$TODO" | tr -d ' ')
  if [ "$n" -gt 0 ]; then
    log "checking $n modules, $JOBS at a time (interrupt with Ctrl-C at any time; finished results are kept)"
    # Each line of the plan is "module<TAB>stamp"; hand both to one checker process.
    tr '\n\t' '\0\0' < "$TODO" | xargs -0 -n 2 -P "$JOBS" "$HERE/verify/kernel_check_one.sh"
    log "checker processes finished (xargs status $?)"
  else
    log "nothing to check: every selected module already has a current passing result"
  fi
fi

# The prefix pass. Skipped for a sample or a list, which are spot checks.
if [ "$PREFIX_ONLY" -eq 1 ] || { [ "$SAMPLE" -eq 0 ] && [ -z "$LIST" ]; }; then
  python3 -I -B "$RH_TOOLS" replay-plan "$@" --retry-failed --prefix-modules > "$TODO" || { echo "ERROR: could not plan the prefix pass" >&2; exit 2; }
  n=$(wc -l < "$TODO" | tr -d ' ')
  if [ "$n" -gt 0 ]; then
    PJOBS=$JOBS; [ "$PJOBS" -gt 8 ] && PJOBS=8
    log "prefix pass: $n modules, each with the modules beneath it, $PJOBS at a time"
    # Each line is "module<TAB>stamp<TAB>prefix".
    tr '\n\t' '\0\0' < "$TODO" | xargs -0 -n 3 -P "$PJOBS" "$HERE/verify/kernel_check_one.sh"
    log "prefix pass finished (xargs status $?)"
  else
    log "prefix pass: nothing to check"
  fi
fi

# A run over everything must also be complete to exit 0; a sample, a list or the prefix pass alone need not be.
REQUIRE=""; [ "$PREFIX_ONLY" -eq 0 ] && [ "$SAMPLE" -eq 0 ] && [ -z "$LIST" ] && REQUIRE="--require-complete"
# shellcheck disable=SC2086
python3 -I -B "$RH_TOOLS" replay-summary "$@" --json "$REPLAY/summary.json" $REQUIRE
status=$?
log "results: $RESULTS   summary: $REPLAY/summary.json"
exit "$status"
