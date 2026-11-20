#!/bin/bash
# verify.sh - top-level entry point: run the preparation steps in order, then explain how to
# run the long ones.
#
# What it does: runs, in order,
#     00_check_prereqs.sh         tools, disk, memory
#     01_fetch.sh                 download the source and verify its SHA-256
#     02_inspect_and_extract.sh   inspect the tarball, then extract it
#     03_audit_source.sh          text scan of the source for escape hatches
#     04_setup_toolchain.sh       pinned Lean toolchain, Mathlib cache, smoke build
#   and stops with a clear message at the first step that fails. It then prints how to start,
#   monitor and finish the build (05, 06) and how to run the two checks that matter (08, 09).
#   It does not start the build: that takes days and is your decision.
#
#   None of these steps establishes that the proof is correct, and none shows that it is not.
#   They establish that you have the published source, that it contains no obvious escape
#   hatches at the text level, and that your machine can compile it.
# What it changes on disk: whatever steps 00 to 04 change, all inside RH_WORKDIR (plus the
#   toolchain that elan installs in ~/.elan). Each step is safe to run again.
# How long it takes: 10 to 20 minutes the first time, most of it downloading.
#
# Usage: scripts/verify.sh [--install-elan]
#   --install-elan  passed to 00_check_prereqs.sh: install elan if it is missing
# Exit status: 0 if steps 00 to 04 all succeeded, otherwise the number of the step that failed
#   plus 10 (so 13 means step 03 failed).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"
. "$HERE/common.sh"

PREREQ_ARGS=""
for arg in "$@"; do
  case "$arg" in
    --install-elan) PREREQ_ARGS="--install-elan" ;;
    -h|--help) show_help; exit 0 ;;
    *) die "unknown argument: $arg (try --help)" ;;
  esac
done

step() {  # step <number> <script> [args...]
  local num=$1 script=$2 rc
  shift 2
  echo
  echo "=================================================================="
  echo "Step $num: $script $*"
  echo "=================================================================="
  bash "$HERE/$script" "$@"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    echo
    echo "STOPPED: step $num ($script) failed with status $rc."
    echo "Nothing after it was run. Fix the problem reported above and run verify.sh again;"
    echo "the steps that already succeeded are quick the second time."
    exit $((10 + ${num#0}))
  fi
}

# shellcheck disable=SC2086
step 00 00_check_prereqs.sh $PREREQ_ARGS
# elan may just have been installed; make it visible to the following steps.
if ! command -v lake >/dev/null 2>&1 && [ -d "$HOME/.elan/bin" ]; then PATH="$HOME/.elan/bin:$PATH"; export PATH; fi
step 01 01_fetch.sh
step 02 02_inspect_and_extract.sh
step 03 03_audit_source.sh --show 0
step 04 04_setup_toolchain.sh

total=$(count_sources)
jobs=$(effective_jobs)
days=$(awk -v t="$total" 'BEGIN { printf "%.1f to %.1f", t / 3200 / 24, t / 2500 / 24 }')
cat <<EOF

==================================================================
Preparation complete. Nothing has been proved or disproved yet.
==================================================================
You now have the published source ($total Lean files) with the recorded SHA-256, a text-level
audit of it, the pinned toolchain, and Mathlib's prebuilt cache. What remains is the part
that takes real time.

1. Compile everything (days, not hours):

     scripts/05_build.sh start        # runs detached, with $jobs parallel jobs on this machine
     scripts/06_progress.sh           # snapshot: modules compiled, failures, rate
     scripts/05_build.sh stop         # safe at any time; 'start' resumes where it stopped

   What to expect. On a 10-core, 24 GB Apple-silicon Mac with 8 jobs, the first 12,000 modules
   compiled at roughly 2,500 to 3,200 modules per hour (2026-11-20). At that rate $total
   modules take $days days. Modules that import more of the project appeared to take
   longer, and later modules import more, so treat that as a lower bound. Disk: extrapolating
   from the same partial build, a complete build needs roughly 1.5 TB, most of it Lake's
   per-module setup files. As of 2026-11-20 no complete build had been finished by the
   maintainers of these scripts, so neither figure is confirmed. A single failed module
   means the build is not complete: 06 reports failures.

2. When 06 shows every module compiled and no failures, run the decisive check:

     scripts/08_check_axioms.sh       # axioms and statements of the five theorems in Main
     scripts/08_check_axioms.sh --deep   # the same, plus a walk that ignores stored axiom lists

   It passes only if the theorems depend on no axioms beyond propext, Classical.choice and
   Quot.sound, and riemannHypothesis has exactly Mathlib's RiemannHypothesis as its type.
   You can try the machinery now, on one small lemma:  scripts/08_check_axioms.sh --probe

3. Optionally re-check compiled modules with the kernel, independently of the compiler:

     scripts/09_kernel_replay.sh --sample 500    # spot check; the full run takes far longer

A pass in step 2 is a statement about what Lean's kernel accepted from this source with this
toolchain. Whether the four statements defined in Statements.lean say what their names
suggest is for a reader to judge; step 2 prints them.
EOF
exit 0
