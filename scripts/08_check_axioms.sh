#!/bin/bash
# 08_check_axioms.sh - the decisive check: which axioms do the headline theorems depend on,
# and do they state what they are claimed to state?
#
# What it does: generates a small Lean file that imports Main and, for each of the five
#   theorems in Main.lean (riemannHypothesis, riemannZeta_eq_zero_re,
#   LFunction_ne_zero_of_half_lt_re, LFunction_eq_zero_re, LFunction_eq_zero_re_of_isPrimitive),
#   prints its axioms and its type. It also checks that the type of riemannHypothesis is exactly
#   the constant RiemannHypothesis and that RiemannHypothesis is the definition in the Mathlib
#   module Mathlib.NumberTheory.LSeries.RiemannZeta, and lists, for each theorem, the project's
#   own definitions that its statement is built from. The file is run with lean directly (not
#   through lake), so nothing is compiled or recompiled.
#
#   It passes only if every theorem's axioms are a subset of propext, Classical.choice and
#   Quot.sound and both statement checks hold. Those three axioms are the ones used throughout
#   Mathlib. Anything else (sorryAx from 'sorry', Lean.ofReduceBool from 'native_decide', or
#   an axiom declared by the project) fails the check.
#
#   What a pass does and does not mean. It is a statement about the compiled modules on disk:
#   they must come from a complete build (see 06_progress.sh). In Lean v4.33.1, '#print axioms'
#   answers for an imported theorem from an axiom list that the compiler stored in each
#   compiled file; it does not re-read proofs across files. --deep adds a walk over every
#   constant the theorems depend on, as stored in the compiled files, without using those
#   stored lists. 09_kernel_replay.sh re-checks the compiled files with the kernel. Four of the
#   five statements are defined by the project itself, in Statements.lean; whether they say
#   what their names suggest is for a reader to judge, and this script prints them for that.
#
#   --probe runs the same checks on one already-compiled lemma, Formalism.VW.rh_of_right
#   ("if zeta has no zeros to the right of the critical line then RiemannHypothesis"). It needs
#   only the setup of step 04 and shows that the machinery works. It is not evidence about the
#   main theorems: the lemma has a hypothesis, and the probe does not look at how it is used.
# What it changes on disk: writes axioms-<mode>-<timestamp>.lean, .log and .json in
#   RH_WORKDIR/logs, and copies the .json to axioms-<mode>-latest.json. Nothing else.
# How long it takes: the probe takes seconds. The full check has to load every compiled module;
#   it had not been run on a complete build when this was written (2026-11-20), so its duration
#   is not known. --deep reads every proof the theorems depend on; expect it to be much slower
#   and to need much more memory. It, too, had not been run on a complete build.
#
# Usage: scripts/08_check_axioms.sh [--probe] [--deep]
# Exit status: 0 = pass, 1 = fail or could not run.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"
. "$HERE/common.sh"

MODE=full; DEEP=0
for arg in "$@"; do
  case "$arg" in
    --probe) MODE=probe ;;
    --deep) DEEP=1 ;;
    -h|--help) show_help; exit 0 ;;
    *) die "unknown argument: $arg (try --help)" ;;
  esac
done

if [ "$MODE" = probe ]; then
  IMPORT="Formalism.GammaFactorNonvanishing.RhOfRight"
  PRIMARY="Formalism.VW.rh_of_right"
  THEOREMS="Formalism.VW.rh_of_right"
else
  IMPORT="Main"
  PRIMARY="riemannHypothesis"
  THEOREMS="riemannHypothesis riemannZeta_eq_zero_re LFunction_ne_zero_of_half_lt_re LFunction_eq_zero_re LFunction_eq_zero_re_of_isPrimitive"
fi
BODY="$HERE/verify/axioms_check_body.lean"
[ -f "$BODY" ] || die "missing file: $BODY"
need_cmd python3
need_cmd lean
[ -f "$RH_PROJ/lean-toolchain" ] || die "project not found at $RH_PROJ (run steps 01 to 04 first)"
LIB="$RH_PROJ/.lake/build/lib/lean"
olean="$LIB/$(printf '%s' "$IMPORT" | tr '.' '/').olean"
if [ ! -f "$olean" ]; then
  if [ "$MODE" = probe ]; then die "$IMPORT is not compiled yet (run 04_setup_toolchain.sh first)"; fi
  die "Main is not compiled yet: the build has not finished. Check 06_progress.sh. (--probe works earlier.)"
fi
ensure_dirs
log "work directory: $RH_WORKDIR"
compiled=$(count_oleans); sources=$(count_sources)
log "compiled modules on disk: $compiled of $sources source files"
if [ "$MODE" = full ]; then
  [ "$compiled" -ge "$sources" ] || log "WARNING: fewer compiled modules than source files; the result describes an incomplete build"
  build_is_running && log "WARNING: a build is still running; run this again when it has finished"
fi

cd "$RH_PROJ" || die "cannot enter $RH_PROJ"
pinned=$(head -n 1 lean-toolchain | tr -d '[:space:]')
want=${pinned##*:}; want=${want#v}
leanver=$(lean --version 2>/dev/null | head -n 1)
case "$leanver" in
  *"version $want"[,\ ]*) ;;
  *) die "the lean on PATH is '$leanver', not the pinned version $want" ;;
esac

TS=$(date +%Y%m%d-%H%M%S)
BASE="$RH_LOGS/axioms-$MODE-$TS"
LEANFILE="$BASE.lean"; OUT="$BASE.log"; JSON="$BASE.json"
deep_lit=false; [ "$DEEP" -eq 1 ] && deep_lit=true
{
  echo "import $IMPORT"
  cat "$BODY"
  echo
  echo "-- Footer generated by scripts/08_check_axioms.sh ($MODE mode)."
  for t in $THEOREMS; do echo "#print axioms $t"; done
  printf 'run_cmd RHVerifyCheck.run "%s" %s `%s [' "$MODE" "$deep_lit" "$PRIMARY"
  sep=""
  for t in $THEOREMS; do printf '%s`%s' "$sep" "$t"; sep=", "; done
  printf ']\n'
} > "$LEANFILE"

raise_nofile
log "running lean on $LEANFILE"
[ "$DEEP" -eq 1 ] && log "--deep: walking every constant the theorems depend on; this can take a long time"
{ echo "### $(date '+%Y-%m-%d %H:%M:%S') $leanver"; echo "### mode=$MODE deep=$DEEP import=$IMPORT"; } > "$OUT"
LEAN_PATH="$(lean_path)" lean "$LEANFILE" >> "$OUT" 2>&1
rc=$?
echo "### lean exit status $rc" >> "$OUT"
log "lean exit status: $rc   output: $OUT"
if [ "$rc" -ne 0 ]; then
  echo "--- messages from lean that are not check output:" >&2
  grep -v '^RHV ' "$OUT" | grep -v '^###' | head -n 20 >&2
fi

set -- axioms-summary --output "$OUT" --mode "$MODE" --primary "$PRIMARY" --lean-status "$rc" \
       --json "$JSON" --tarball-sha256 "$RH_TARBALL_SHA256" --compiled "$compiled" --sources "$sources"
for t in $THEOREMS; do set -- "$@" --theorem "$t"; done
[ "$DEEP" -eq 1 ] && set -- "$@" --deep
python3 -B "$RH_TOOLS" "$@"
status=$?
cp "$JSON" "$RH_LOGS/axioms-$MODE-latest.json" 2>/dev/null
log "summary: $JSON"
exit "$status"
