#!/bin/bash
# 09_kernel_replay.sh - re-check compiled modules with Lean's kernel, independently of the
# compile that produced them.
#
# What it does: for each compiled module, loads the module's imports and replays every declaration
#   the module adds through the kernel. This detects compiled files whose contents were not
#   actually accepted by the kernel (the stock tool's own description: it is "not an external
#   verifier", it detects "environment hacking"). It does not judge whether an axiom is
#   acceptable: an 'axiom' declaration replays fine. Axioms are the business of 08.
#
#   Two methods run the same replay (the function replayFromImports of the pinned toolchain):
#
#   --method leanchecker (the default): the stock tool 'leanchecker', one process per module,
#   RH_JOBS at a time. leanchecker treats its argument as a name PREFIX and checks every module
#   whose name starts with it, in one process. So modules whose name is not a prefix of another
#   module's name are checked one at a time. The few that are prefixes (114 of 175,187 in the
#   source tree, with 119 modules beneath the largest) are checked afterwards in a second pass,
#   the "prefix pass": one process each, which replays the module together with every compiled
#   module beneath it and records the list of what it replayed. A sample (--sample) or a list
#   (--list) skips the prefix pass; --prefix-modules runs it alone.
#     To find the modules that match its argument, leanchecker lists every compiled file on the
#   search path, once per process. That listing grows with the number of compiled modules and,
#   on the whole tree, costs several times as much as the replay itself
#   (docs/performance-notes.md, section 10).
#
#   --method rhv-replay: the program in scripts/verify/replay, which contains a copy of
#   replayFromImports (compared here, character for character, with the toolchain's source
#   before every run), takes exact module names, finds each compiled file directly, and replays
#   a batch of modules one after another in one process, RH_JOBS processes at a time. It needs
#   no prefix pass. It is built on first use with the pinned toolchain (a few seconds).
#
#   Results of the two methods are recorded side by side. A module counts as passed if at least
#   one method passed it for the file now on disk and none failed it; the summary reports each
#   method's count and every module on which the two disagree.
#
#   The run is resumable. Results are appended to a file, and modules already recorded as
#   passed by the chosen method are skipped, unless their compiled file has changed since (the
#   content hash Lake keeps beside it). That is the only thing a recorded result is tied to: if
#   a module's imports were compiled again and its own compiled file came out byte for byte the
#   same, its result still counts and it is not replayed again. With an unmodified source tree
#   nothing is ever compiled twice, so this does not arise; after changing a source file, start
#   from an empty results file. The hash is read from Lake's file, not recomputed: a result
#   that is to count should come from a run made after the build has finished, with nothing
#   rebuilt or replaced in between (the cloud driver enforces that by hashing every compiled
#   file before the checks and again after them). Failed modules are tried again on the next run. It can run
#   while the build is running, but it competes with it for CPU and memory. One run at a time.
# What it changes on disk: writes under RH_WORKDIR/analysis/kernel_replay: results.tsv
#   (appended), summary.json, out/<module>.out for modules that failed, out/<module>.prefix.out
#   for each prefix module that passed, out/<module>.replay.out for modules rhv-replay failed.
#   With --method rhv-replay it also builds scripts/verify/replay/.lake (about 180 MB), and
#   appends to replay_program.tsv the SHA-256 of the program each run used.
# How long it takes: see docs/performance-notes.md, section 10. With leanchecker on a 10-core,
#   24 GB Mac, 14 to 28 seconds of wall time per module with 30,000 modules compiled, and more
#   as the tree fills: weeks for the whole tree. With rhv-replay, a few seconds per module.
#   Use --sample for a spot check.
#
# Usage: scripts/09_kernel_replay.sh [--method leanchecker|rhv-replay] [--sample N] [--seed S]
#                                    [--jobs N] [--batch N] [--list FILE] [--prefix-modules]
#                                    [--summary]
#   --method M   leanchecker (default) or rhv-replay; RH_REPLAY_METHOD sets the default
#   --sample N   check a random sample of N eligible modules (the same N and seed give the
#                same sample, so an interrupted sample can be resumed)
#   --seed S     seed for --sample (default 20261120)
#   --jobs N     parallel checker processes (default: RH_JOBS, else the recommended value)
#   --batch N    modules per rhv-replay process (default 25)
#   --list FILE  check the modules named in FILE (one per line) instead of all eligible ones
#   --prefix-modules  run only the prefix pass (leanchecker only)
#   --summary    print the summary of the recorded results and exit; checks nothing
# Exit status: 0 if no recorded module has failed (and, for a run over everything, every source
#   module is compiled and has passed); 1 if any module has failed; 2 if it could not run; 3 if
#   nothing has failed but a run over everything is not yet complete (run it again).
#   A checker killed by a signal counts as not yet checked, not as failed.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"
. "$HERE/common.sh"

SAMPLE=0; SEED=20261120; JOBS=""; LIST=""; SUMMARY_ONLY=0; PREFIX_ONLY=0; BATCH=25
METHOD=${RH_REPLAY_METHOD:-leanchecker}
# Exit status 1 means "a module failed". Anything that stops this script from running at all ends with 2.
die() { echo "ERROR: $*" >&2; exit 2; }
while [ $# -gt 0 ]; do
  case "$1" in
    --sample) shift; [ $# -gt 0 ] || die "--sample needs a number"; SAMPLE=$1 ;;
    --seed) shift; [ $# -gt 0 ] || die "--seed needs a number"; SEED=$1 ;;
    --jobs) shift; [ $# -gt 0 ] || die "--jobs needs a number"; JOBS=$1 ;;
    --list) shift; [ $# -gt 0 ] || die "--list needs a file"; LIST=$1 ;;
    --method) shift; [ $# -gt 0 ] || die "--method needs leanchecker or rhv-replay"; METHOD=$1 ;;
    --batch) shift; [ $# -gt 0 ] || die "--batch needs a number"; BATCH=$1 ;;
    --prefix-modules) PREFIX_ONLY=1 ;;
    --summary) SUMMARY_ONLY=1 ;;
    -h|--help) show_help; exit 0 ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
  shift
done
case "$SAMPLE" in ''|*[!0-9]*) die "--sample must be a number" ;; esac
case "$SEED" in ''|*[!0-9]*) die "--seed must be a number" ;; esac
case "$BATCH" in ''|*[!0-9]*|0) die "--batch must be a number above zero" ;; esac
case "$METHOD" in leanchecker|rhv-replay) ;; *) die "--method must be leanchecker or rhv-replay" ;; esac
[ "$PREFIX_ONLY" -eq 0 ] || [ "$METHOD" = leanchecker ] || die "--prefix-modules is for leanchecker; rhv-replay checks prefix modules like any other"
need_cmd python3
LIB="$RH_PROJ/.lake/build/lib/lean"
REPLAY="$RH_AN/kernel_replay"
RESULTS="$REPLAY/results.tsv"
set -- --lib "$LIB" --src "$RH_PROJ/src" --results "$RESULTS"

if [ "$SUMMARY_ONLY" -eq 1 ]; then
  python3 -I -B "$RH_TOOLS" replay-summary "$@"
  status=$?
  case "$status" in 0|1|3) ;; *) status=2 ;; esac      # anything else is the summary itself failing
  exit "$status"
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
TMP="${REPLAY:?}/tmp"                      # scratch for this run; emptied at the start and at the end
mkdir -p "$REPLAY/out" || die "cannot create $REPLAY/out"
rm -rf "${REPLAY:?}/tmp"; mkdir -p "$TMP" || die "cannot create $TMP"
[ -f "$RESULTS" ] || printf 'module\texit_status\tseconds\tstamp\tepoch\tmethod\n' > "$RESULTS"
log "work directory: $RH_WORKDIR"

if [ "$METHOD" = rhv-replay ]; then
  # The copy of replayFromImports must be the pinned toolchain's own, character for character.
  DRV_SRC="$HERE/verify/replay"
  TC_SRC="$bindir/../src/lean/LeanChecker.lean"
  [ -f "$TC_SRC" ] || { echo "ERROR: the toolchain's source of leanchecker was not found at $TC_SRC" >&2; exit 2; }
  python3 -I -B "$RH_TOOLS" replay-driver-check --driver-src "$DRV_SRC/RhvReplay.lean" --toolchain-src "$TC_SRC" \
    || { echo "ERROR: scripts/verify/replay/RhvReplay.lean does not carry the toolchain's replayFromImports unchanged" >&2; exit 2; }
  DRV_ORIGIN=supplied_through_RH_REPLAY_DRIVER
  if [ -n "${RH_REPLAY_DRIVER:-}" ]; then
    # The cloud run builds the program as root, ahead of time, and hands it over this way. Anywhere else this
    # is a test setting: results are then only as good as the program named.
    log "NOTE: using the replay program named by RH_REPLAY_DRIVER; it was not built by this run"
  else
    DRV_ORIGIN=built_here_from_the_checked_source
    RH_REPLAY_DRIVER="$DRV_SRC/.lake/build/bin/rhv-replay"
    # lake rebuilds only what changed; with nothing to do this takes a fraction of a second.
    log "building rhv-replay with the pinned toolchain (scripts/verify/replay)"
    ( cd "$DRV_SRC" && PATH="$bindir:$PATH" "$bindir/lake" build > "$REPLAY/driver_build.log" 2>&1 ) \
      || { echo "ERROR: could not build rhv-replay; see $REPLAY/driver_build.log" >&2; exit 2; }
  fi
  [ -x "$RH_REPLAY_DRIVER" ] || { echo "ERROR: rhv-replay not found at $RH_REPLAY_DRIVER" >&2; exit 2; }
  log "checker: $RH_REPLAY_DRIVER"
  # Which program produced this run's results: its SHA-256, and whether it was built here from the checked source.
  printf '%s\t%s\t%s\t%s\n' "$(date +%s)" "$(sha256_of "$RH_REPLAY_DRIVER")" "$DRV_ORIGIN" "$RH_REPLAY_DRIVER" >> "$REPLAY/replay_program.tsv"
else
  RH_REPLAY_DRIVER=""
  log "checker: $RH_LEANCHECKER"
fi

TODO="$REPLAY/todo.tsv"
raise_nofile
RH_REPLAY_DIR="$REPLAY"; RH_LEAN_PATH="$(lean_path)"
export RH_PROJ RH_REPLAY_DIR RH_LEAN_PATH RH_LEANCHECKER RH_REPLAY_DRIVER

if [ "$PREFIX_ONLY" -eq 0 ]; then
  plan_args="--retry-failed --method $METHOD"
  [ "$SAMPLE" -gt 0 ] && plan_args="$plan_args --sample $SAMPLE --seed $SEED"
  # shellcheck disable=SC2086
  if [ -n "$LIST" ]; then
    python3 -I -B "$RH_TOOLS" replay-plan "$@" $plan_args --list "$LIST" > "$TODO" || { echo "ERROR: could not plan the run" >&2; exit 2; }
  else
    python3 -I -B "$RH_TOOLS" replay-plan "$@" $plan_args > "$TODO" || { echo "ERROR: could not plan the run" >&2; exit 2; }
  fi
  n=$(wc -l < "$TODO" | tr -d ' ')
  if [ "$n" -eq 0 ]; then
    log "nothing to check: every selected module already has a current passing result by $METHOD"
  elif [ "$METHOD" = rhv-replay ]; then
    log "checking $n modules with rhv-replay, $BATCH to a process, $JOBS processes at a time (interrupt with Ctrl-C at any time; finished results are kept)"
    mkdir -p "$TMP/plan" || die "cannot create $TMP/plan"
    split -l "$BATCH" -a 6 "$TODO" "$TMP/plan/part." || die "could not split the plan into batches"
    find "$TMP/plan" -type f -name 'part.*' -print0 | xargs -0 -n 1 -P "$JOBS" "$HERE/verify/kernel_check_batch.sh"
    log "checker processes finished (xargs status $?)"
  else
    log "checking $n modules with leanchecker, $JOBS at a time (interrupt with Ctrl-C at any time; finished results are kept)"
    # Each line of the plan is "module<TAB>stamp"; hand both to one checker process.
    tr '\n\t' '\0\0' < "$TODO" | xargs -0 -n 2 -P "$JOBS" "$HERE/verify/kernel_check_one.sh"
    log "checker processes finished (xargs status $?)"
  fi
fi

# The prefix pass: leanchecker only. Skipped for a sample or a list, which are spot checks.
if [ "$METHOD" = leanchecker ] && { [ "$PREFIX_ONLY" -eq 1 ] || { [ "$SAMPLE" -eq 0 ] && [ -z "$LIST" ]; }; }; then
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
rm -rf "${REPLAY:?}/tmp"

# A run over everything must also be complete to exit 0; a sample, a list or the prefix pass alone need not be.
REQUIRE=""; [ "$PREFIX_ONLY" -eq 0 ] && [ "$SAMPLE" -eq 0 ] && [ -z "$LIST" ] && REQUIRE="--require-complete"
# shellcheck disable=SC2086
python3 -I -B "$RH_TOOLS" replay-summary "$@" --json "$REPLAY/summary.json" $REQUIRE
status=$?
case "$status" in 0|1|3) ;; *) status=2 ;; esac        # anything else is the summary itself failing
log "results: $RESULTS   summary: $REPLAY/summary.json"
exit "$status"
