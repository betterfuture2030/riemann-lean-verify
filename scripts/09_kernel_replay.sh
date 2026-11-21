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
#   --method leanchecker (the default) uses the stock tool 'leanchecker' shipped with the pinned
#   toolchain, one process per module. This is the tool criterion C3 names, and --c3 runs it on
#   every module and says whether the criterion's conditions hold.
#     leanchecker checks every module whose name starts with its argument, and to find them it
#   lists every compiled file on its search path, before it checks anything. With the whole
#   library on the search path that listing costs several times as much as the check itself
#   once the tree is built (docs/performance-notes.md, section 10), and a module whose name is a
#   prefix of other modules' names cannot be checked on its own. So each check is given a search
#   path that holds, of this project, only the module's import closure: a directory of hard links
#   to the compiled files of the module and of everything it imports, made for the check and
#   removed after it. The files are the same files; only what else is visible changes. If that
#   closure were ever computed too small, leanchecker would report a missing file and the module
#   would be recorded as not checked: it cannot make a module pass.
#     --whole-library does it the plain way instead: the whole library on the search path, then
#   a second pass (the "prefix pass") for the modules whose name is a prefix of another's, each
#   with every compiled module beneath it. It is also what happens when hard links cannot be
#   made where the results are kept. --prefix-modules runs that second pass alone.
#
#   --method rhv-replay uses the program in scripts/verify/replay, which contains a copy of the
#   function leanchecker runs on each module (compared, character for character, with the
#   toolchain's source before every run), takes exact module names and replays a batch of modules
#   one after another in one process. It is a second, independent way of running the same replay,
#   built on first use with the pinned toolchain. It is not the tool criterion C3 names.
#
#   Every result is kept, by tool. A module that a tool rejects, or crashes on, is run by that
#   tool again as evidence (twice, or until the rejection comes back, which makes it a failure),
#   and is never afterwards counted as passed, whatever those runs say: the kernel is deterministic on a given file, so a rejection that does not come back is a
#   fault of the machine or of these scripts, and it is not for a script to wave it through.
#   A check that was ended from outside, or could not open a file, has not tested the module and
#   is simply tried again by the next run.
#
#   The run is resumable. Results are appended to a file, and a module a tool has already passed
#   is skipped unless its compiled file has changed since (the content hash Lake keeps beside
#   it). That is the only thing a pass is tied to: if a module's imports were compiled again and
#   its own compiled file came out byte for byte the same, its pass still counts. With an
#   unmodified source tree nothing is ever compiled twice, so this does not arise; after changing
#   a source file, start from an empty results file. The hash is read from Lake's file, not
#   recomputed: a result that is to count should come from a run made after the build has
#   finished, with nothing rebuilt or replaced in between (the cloud driver enforces that by
#   hashing every compiled file before the checks and again after them). It can run while the
#   build is running, but it competes with it for CPU and memory. One run at a time: a second
#   run started while one is going stops with an error.
# What it changes on disk: writes under RH_WORKDIR/analysis/kernel_replay: results.tsv
#   (appended), summary.json, import_graph.json (read again whenever the source tree has
#   changed), out/<module>.out for modules that did not pass, out/<module>.replay.out for modules
#   rhv-replay rejected, and a tmp directory and a lock (run.lock) while it runs.
#   With --method rhv-replay it also builds scripts/verify/replay/.lake (about 180 MB), and
#   appends to replay_program.tsv the SHA-256 of the program each run used.
# How long it takes: see docs/performance-notes.md, section 10. On a 10-core, 24 GB Mac with a
#   third of the tree compiled, 10 to 18 seconds per module with leanchecker, 7 with rhv-replay.
#   Use --sample for a spot check.
#
# Usage: scripts/09_kernel_replay.sh [--c3] [--method leanchecker|rhv-replay] [--whole-library]
#                                    [--sample N] [--seed S] [--jobs N] [--batch N] [--list FILE]
#                                    [--prefix-modules] [--summary]
#   --c3         criterion C3: leanchecker on every compiled module, then the summary judged
#                against the criterion's conditions
#   --method M   leanchecker (default) or rhv-replay; RH_REPLAY_METHOD sets the default
#   --whole-library   leanchecker with the whole library on its search path (see above)
#   --sample N   check a random sample of N eligible modules (the same N and seed give the
#                same sample, so an interrupted sample can be resumed)
#   --seed S     seed for --sample (default 20261120)
#   --jobs N     parallel checker processes (default: RH_JOBS, else the recommended value)
#   --batch N    most modules handed to one worker process (default 25; fewer when there are too
#                few modules to give every job that many)
#   --list FILE  check the modules named in FILE (one per line) instead of all eligible ones
#   --prefix-modules  run only the prefix pass (leanchecker with --whole-library); with --list,
#                only for the prefix modules the list names. A --sample with --whole-library is
#                drawn from the modules that are not prefix modules, and has no prefix pass
#   --summary    print the summary of the recorded results and exit; checks nothing
# Exit status: 0 if no tool has rejected or crashed on any module (and, for a run over
#   everything, the run is complete: with leanchecker or --c3 that means every condition of
#   criterion C3 holds; with rhv-replay, that rhv-replay itself has passed every module);
#   1 if any rejection or crash is recorded; 2 if it could not run; 3 if nothing was rejected
#   but a run over everything is not yet complete (run it again), or the results file has a
#   damaged line, which may be what is left of a rejection; 130 or 143 if it was interrupted.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"
. "$HERE/common.sh"

SAMPLE=0; SEED=20261120; JOBS=""; LIST=""; SUMMARY_ONLY=0; PREFIX_ONLY=0; BATCH=25; C3=0; WHOLE=0
METHOD=${RH_REPLAY_METHOD:-leanchecker}
# Exit status 1 means "a tool rejected a module". Anything that stops this script from running at all ends with 2.
die() { echo "ERROR: $*" >&2; exit 2; }
while [ $# -gt 0 ]; do
  case "$1" in
    --sample) shift; [ $# -gt 0 ] || die "--sample needs a number"; SAMPLE=$1 ;;
    --seed) shift; [ $# -gt 0 ] || die "--seed needs a number"; SEED=$1 ;;
    --jobs) shift; [ $# -gt 0 ] || die "--jobs needs a number"; JOBS=$1 ;;
    --list) shift; [ $# -gt 0 ] || die "--list needs a file"; LIST=$1 ;;
    --method) shift; [ $# -gt 0 ] || die "--method needs leanchecker or rhv-replay"; METHOD=$1 ;;
    --batch) shift; [ $# -gt 0 ] || die "--batch needs a number"; BATCH=$1 ;;
    --whole-library) WHOLE=1 ;;
    --prefix-modules) PREFIX_ONLY=1; WHOLE=1 ;;
    --summary) SUMMARY_ONLY=1 ;;
    --c3) C3=1; METHOD=leanchecker ;;
    -h|--help) show_help; exit 0 ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
  shift
done
case "$SAMPLE" in ''|*[!0-9]*) die "--sample must be a number" ;; esac
case "$SEED" in ''|*[!0-9]*) die "--seed must be a number" ;; esac
case "$BATCH" in ''|*[!0-9]*|0) die "--batch must be a number above zero" ;; esac
case "$METHOD" in leanchecker|rhv-replay) ;; *) die "--method must be leanchecker or rhv-replay" ;; esac
[ -z "$JOBS" ] || case "$JOBS" in *[!0-9]*|0) die "--jobs must be a number above zero" ;; esac
# --c3 is criterion C3, which names leanchecker. A --method given after it must not change the tool.
[ "$C3" -eq 0 ] || [ "$METHOD" = leanchecker ] || die "--c3 is run with leanchecker only; do not give --method with it"
[ "$WHOLE" -eq 0 ] || [ "$METHOD" = leanchecker ] || die "--whole-library and --prefix-modules are for leanchecker"
[ "$PREFIX_ONLY" -eq 0 ] || [ "$SAMPLE" -eq 0 ] || die "--prefix-modules does not take --sample (it takes --list)"
[ "$C3" -eq 0 ] || { [ "$SAMPLE" -eq 0 ] && [ -z "$LIST" ] && [ "$PREFIX_ONLY" -eq 0 ] && [ "$SUMMARY_ONLY" -eq 0 ]; } || die "--c3 covers every module: it takes only --jobs, --batch and --whole-library with it"
need_cmd python3
LIB="$RH_PROJ/.lake/build/lib/lean"
REPLAY="$RH_AN/kernel_replay"
RESULTS="$REPLAY/results.tsv"
set -- --lib "$LIB" --src "$RH_PROJ/src" --results "$RESULTS"
# The one rhv-replay program whose passes are expected, when the caller knows it (the cloud driver does).
TRUSTED=""; [ -n "${RH_REPLAY_TRUSTED_SHA:-}" ] && TRUSTED="--trusted-program $RH_REPLAY_TRUSTED_SHA"

summarise() { # summarise <extra arguments>: prints the summary; the status is 0, 1 or 3, or 2 if the summary itself failed
  local status
  # shellcheck disable=SC2086
  python3 -I -B "$RH_TOOLS" replay-summary "$@" --method "$METHOD" $TRUSTED
  status=$?
  case "$status" in 0|1|3) return "$status" ;; *) return 2 ;; esac
}

if [ "$SUMMARY_ONLY" -eq 1 ]; then
  summarise "$@"
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
TMP="${REPLAY:?}/tmp"                      # scratch for this run; emptied at the start and at the end
mkdir -p "$REPLAY/out" || die "cannot create $REPLAY/out"
# One run at a time: a second run would empty the first one's scratch directory under it. The lock is a
# symbolic link whose target is the owner's process id; making a link either succeeds or fails as a whole, so
# two starts cannot both get it. A lock whose process is gone, or is no longer this script, is taken over, and
# only one start at a time may look into that (the guard directory; one left by a start that was killed in
# that instant is removed after a minute).
LOCK="${REPLAY:?}/run.lock"
if ! ln -sn "$$" "$LOCK" 2>/dev/null; then
  if ! mkdir "$LOCK.takeover" 2>/dev/null; then
    [ -n "$(find "$LOCK.takeover" -maxdepth 0 -mmin +1 2>/dev/null)" ] && rmdir "$LOCK.takeover" 2>/dev/null
    mkdir "$LOCK.takeover" 2>/dev/null || die "another start of this script is looking at the lock in $REPLAY; try again in a moment"
  fi
  other=$(readlink "$LOCK" 2>/dev/null)
  case "$other" in ''|*[!0-9]*) other="" ;; esac
  if [ -n "$other" ] && [ "$other" != "$$" ] && ps -p "$other" -o args= 2>/dev/null | grep -q '09_kernel_replay'; then
    rmdir "$LOCK.takeover" 2>/dev/null
    die "another run of this script (process $other) is using $REPLAY; wait for it, or stop it first"
  fi
  rm -f "$LOCK"
  ln -sn "$$" "$LOCK" 2>/dev/null || { rmdir "$LOCK.takeover" 2>/dev/null; die "cannot create $LOCK"; }
  rmdir "$LOCK.takeover" 2>/dev/null
fi
# From here on the script cleans up after itself however it ends, and removes the lock only if it is its own.
# An interrupt ends the whole run: without the two lines for it, bash 3.2 would carry on with the next pass
# after Ctrl-C had stopped the current one.
trap 'rm -rf "${REPLAY:?}/tmp"; if [ "$(readlink "$LOCK" 2>/dev/null)" = "$$" ]; then rm -f "$LOCK"; fi' EXIT
trap 'echo "interrupted; finished results are kept" >&2; exit 130' INT
trap 'exit 143' TERM
rm -rf "${REPLAY:?}/tmp"; mkdir -p "$TMP" || die "cannot create $TMP"
[ -f "$RESULTS" ] || printf 'module\tstatus\tseconds\tstamp\tepoch\ttool\tprogram_sha256\thow\n' > "$RESULTS"
# A last line cut short (a full disk, a kill in mid-write) is closed off, so that the next result starts on a
# line of its own and cannot be swallowed by the fragment. A bare newline would not do: a line cut after its
# fifth field would then read as a complete line of the oldest format. Eight more fields are added, which no
# complete line has room for, so the fragment stays in the file and is counted as damaged whatever it held.
# (The test is "the last byte is not a newline", whatever else it is: a file can also end in zero bytes.)
if [ -s "$RESULTS" ] && [ "$(tail -c 1 "$RESULTS" | wc -l | tr -d ' ')" -eq 0 ]; then
  printf '\tcut-short\tcut-short\tcut-short\tcut-short\tcut-short\tcut-short\tcut-short\tcut-short\n' >> "$RESULTS"
fi
log "work directory: $RH_WORKDIR"
RH_LEANCHECKER_SHA=$(sha256_of "$RH_LEANCHECKER")
RH_REPLAY_DRIVER=${RH_REPLAY_DRIVER:-}; RH_REPLAY_DRIVER_SHA=""
RH_REPLAY_DIR="$REPLAY"; RH_LEAN_PATH="$(lean_path)"
PACKAGES=${RH_LEAN_PATH#"$LIB"}; PACKAGES=${PACKAGES#:}     # the search path without the project's own library
TODO="$REPLAY/todo.tsv"
raise_nofile

if [ "$METHOD" = rhv-replay ]; then
  # The copy of replayFromImports must be the pinned toolchain's own, character for character.
  DRV_SRC="$HERE/verify/replay"
  TC_SRC="$bindir/../src/lean/LeanChecker.lean"
  [ -f "$TC_SRC" ] || { echo "ERROR: the toolchain's source of leanchecker was not found at $TC_SRC" >&2; exit 2; }
  python3 -I -B "$RH_TOOLS" replay-driver-check --driver-src "$DRV_SRC/RhvReplay.lean" --toolchain-src "$TC_SRC" \
    || { echo "ERROR: scripts/verify/replay/RhvReplay.lean does not carry the toolchain's replayFromImports unchanged" >&2; exit 2; }
  DRV_ORIGIN=supplied_through_RH_REPLAY_DRIVER
  if [ -n "$RH_REPLAY_DRIVER" ]; then
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
  RH_REPLAY_DRIVER_SHA=$(sha256_of "$RH_REPLAY_DRIVER")
  log "checker: $RH_REPLAY_DRIVER"
  # Which program produced this run's results: its SHA-256, and whether it was built here from the checked source.
  printf '%s\t%s\t%s\t%s\n' "$(date +%s)" "$RH_REPLAY_DRIVER_SHA" "$DRV_ORIGIN" "$RH_REPLAY_DRIVER" >> "$REPLAY/replay_program.tsv"
else
  log "checker: $RH_LEANCHECKER"
  if [ "$WHOLE" -eq 0 ]; then
    # Import-closure directories need hard links from where the results are kept to the compiled files.
    probe=$(find "$LIB" -name '*.olean' -type f 2>/dev/null | head -1)
    [ -n "$probe" ] || die "no compiled modules found under $LIB (run steps 04 and 05 first)"
    if ln "$probe" "$TMP/link-probe.olean" 2>/dev/null; then
      rm -f "$TMP/link-probe.olean"
      GRAPH="$REPLAY/import_graph.json"
      # Read once and kept; read again whenever the source tree is not the one the stored graph was made from.
      [ -s "$GRAPH" ] || log "reading the import lines of every source file (kept as $GRAPH)"
      python3 -I -B "$RH_TOOLS" import-graph --if-stale --src "$RH_PROJ/src" --out "$GRAPH" || die "could not build the import graph"
      mkdir -p "$TMP/closure" || die "cannot create $TMP/closure"
    else
      WHOLE=1
      log "NOTE: hard links to the compiled files cannot be made under $REPLAY (another volume, or not permitted);"
      log "      leanchecker will be run with the whole library on its search path, which is much slower on a large tree"
    fi
  fi
fi
export RH_PROJ RH_REPLAY_DIR RH_LEAN_PATH RH_LEANCHECKER RH_LEANCHECKER_SHA RH_REPLAY_DRIVER RH_REPLAY_DRIVER_SHA

run_batches() { # run_batches <todo file> <worker command...>: one worker process per batch of the plan
  local todo=$1 n b; shift
  rm -rf "${TMP:?}/plan"; mkdir -p "$TMP/plan" || die "cannot create $TMP/plan"
  # At most BATCH modules to a worker, and fewer when the plan is short, so that a short pass (a retry, a
  # rehearsal) still gives every job a worker: 635 modules for 32 jobs go out 19 to a worker, which makes 34
  # workers, where 25 to a worker made 26.
  n=$(wc -l < "$todo" | tr -d ' ')
  b=$(( n / JOBS )); [ "$b" -ge 1 ] || b=1; [ "$b" -le "$BATCH" ] || b=$BATCH
  split -l "$b" -a 6 "$todo" "$TMP/plan/part." || die "could not split the plan into batches"
  find "$TMP/plan" -type f -name 'part.*' -print0 | xargs -0 -n 1 -P "$JOBS" "$@"
  log "checker processes finished (xargs status $?)"
}

main_pass() { # main_pass <extra arguments for the plan>: plan what the tool has still to do, and do it. Sets N.
  local plan=(--method "$METHOD" "$@")
  [ "$SAMPLE" -gt 0 ] && plan+=(--sample "$SAMPLE" --seed "$SEED")
  [ -n "$LIST" ] && plan+=(--list "$LIST")
  [ "$METHOD" = leanchecker ] && [ "$WHOLE" -eq 0 ] && plan+=(--all-modules)
  python3 -I -B "$RH_TOOLS" replay-plan "${ARGS[@]}" "${plan[@]}" > "$TODO" || { echo "ERROR: could not plan the run" >&2; exit 2; }
  N=$(wc -l < "$TODO" | tr -d ' ')
  [ "$N" -gt 0 ] || return 0
  if [ "$METHOD" = rhv-replay ]; then
    log "checking $N modules with rhv-replay, at most $BATCH to a process, $JOBS processes at a time (interrupt with Ctrl-C at any time; finished results are kept)"
    run_batches "$TODO" "$HERE/verify/kernel_check_batch.sh"
  elif [ "$WHOLE" -eq 0 ]; then
    log "checking $N modules with leanchecker, each with only its imports on the search path, $JOBS at a time (interrupt with Ctrl-C at any time; finished results are kept)"
    run_batches "$TODO" python3 -I -B "$RH_TOOLS" closure-worker --graph "$GRAPH" --lib "$LIB" --dir-base "$TMP/closure" \
      --packages "$PACKAGES" --check-one "$HERE/verify/kernel_check_one.sh" --batch
  else
    log "checking $N modules with leanchecker, the whole library on the search path, $JOBS at a time (interrupt with Ctrl-C at any time; finished results are kept)"
    # Each line of the plan is "module<TAB>stamp"; hand both to one checker process.
    tr '\n\t' '\0\0' < "$TODO" | xargs -0 -n 2 -P "$JOBS" "$HERE/verify/kernel_check_one.sh"
    log "checker processes finished (xargs status $?)"
  fi
}
ARGS=("$@")

if [ "$PREFIX_ONLY" -eq 0 ]; then
  main_pass
  [ "$N" -gt 0 ] || log "nothing to check: $METHOD has a result for every selected module"
  # A module the tool rejected or crashed on is run by it again, as evidence: twice, or until it is rejected a
  # second time. Never more, and whatever those runs say the module is not afterwards counted as passed.
  for round in 1 2; do
    main_pass --only-reruns
    [ "$N" -gt 0 ] || break
    log "that was re-run $round of 2 for modules $METHOD rejected or crashed on"
  done
fi

# The prefix pass: leanchecker with the whole library only. With a list, for the prefix modules it names.
# Skipped for a sample, which is drawn from the other modules.
if [ "$METHOD" = leanchecker ] && [ "$WHOLE" -eq 1 ] && { [ "$PREFIX_ONLY" -eq 1 ] || [ "$SAMPLE" -eq 0 ]; }; then
  for round in 0 1 2; do
    pplan=(--prefix-modules); [ "$round" -gt 0 ] && pplan+=(--only-reruns)
    [ -n "$LIST" ] && pplan+=(--list "$LIST")
    python3 -I -B "$RH_TOOLS" replay-plan "$@" "${pplan[@]}" > "$TODO" || { echo "ERROR: could not plan the prefix pass" >&2; exit 2; }
    n=$(wc -l < "$TODO" | tr -d ' ')
    [ "$n" -gt 0 ] || { [ "$round" -gt 0 ] || log "prefix pass: nothing to check"; break; }
    PJOBS=$JOBS; [ "$PJOBS" -gt 8 ] && PJOBS=8
    log "prefix pass: $n modules, each with the modules beneath it, $PJOBS at a time"
    # Each line is "module<TAB>stamp<TAB>prefix".
    tr '\n\t' '\0\0' < "$TODO" | xargs -0 -n 3 -P "$PJOBS" "$HERE/verify/kernel_check_one.sh"
    log "prefix pass finished (xargs status $?)"
  done
fi
rm -rf "${REPLAY:?}/tmp"

# A run over everything must also be complete to exit 0; a sample, a list or the prefix pass alone need not be.
# For leanchecker, complete means criterion C3: leanchecker itself has passed every compiled module.
REQUIRE=""
if [ "$PREFIX_ONLY" -eq 0 ] && [ "$SAMPLE" -eq 0 ] && [ -z "$LIST" ]; then
  if [ "$C3" -eq 1 ] || [ "$METHOD" = leanchecker ]; then REQUIRE="--require-c3"; else REQUIRE="--require-complete"; fi
fi
# shellcheck disable=SC2086
summarise "$@" --json "$REPLAY/summary.json" $REQUIRE
status=$?
log "results: $RESULTS   summary: $REPLAY/summary.json"
if [ "$C3" -eq 1 ]; then
  case "$status" in
    0) log "criterion C3: every condition holds" ;;
    1) log "criterion C3: NOT met: a tool rejected or crashed on a module; see the summary above" ;;
    *) log "criterion C3: not established by this run (status $status); see the summary above" ;;
  esac
fi
exit "$status"
