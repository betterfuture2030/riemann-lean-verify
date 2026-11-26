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
#   The names in this header are the default target's. They are read from the target's profile
#   (targets/README.md): the module is TGT_ROOT_MODULE, the theorems are TGT_THEOREMS, the theorem
#   whose type is compared is TGT_PRIMARY_THEOREM, the constant is TGT_STATEMENT_CONST and its
#   module TGT_STATEMENT_CONST_MODULE. The Lean code of the check is the file
#   scripts/verify/axioms_check_body.lean, unchanged when the constant and the constants whose
#   defining module is reported (TGT_REPORT_CONSTS) are the default target's; for other names it
#   is that file with the names replaced, as 'rhv_tools.py axioms-body' prints it.
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
#   The lemma and its module are TGT_PROBE_THEOREM and TGT_PROBE_MODULE of the profile. A profile
#   that names none has no probe: --probe then stops with an error.
# What it changes on disk: writes axioms-<mode>-<timestamp>.lean, .log and .json in
#   RH_WORKDIR/logs, and copies the .json to axioms-<mode>-latest.json. If RH_WORKDIR has no
#   .rh-target file yet, writes the target's name to it. Nothing else.
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

# Every name comes from the target's profile (for the default target, from the values built into lib.sh).
HAVE_PROBE=0; [ -n "$TGT_PROBE_MODULE" ] && [ -n "$TGT_PROBE_THEOREM" ] && HAVE_PROBE=1
if [ "$MODE" = probe ]; then
  [ "$HAVE_PROBE" -eq 1 ] || die "the profile of target $RH_TARGET names no probe lemma (TGT_PROBE_MODULE and TGT_PROBE_THEOREM): there is no --probe for this target"
  IMPORT="$TGT_PROBE_MODULE"
  PRIMARY="$TGT_PROBE_THEOREM"
  THEOREMS="$TGT_PROBE_THEOREM"
else
  IMPORT="$TGT_ROOT_MODULE"
  PRIMARY="$TGT_PRIMARY_THEOREM"
  THEOREMS="$TGT_THEOREMS"
fi
# The theorem whose statement is compared must be one of those whose axioms are checked.
# The lists are split on spaces but never expanded as file patterns (set -f), so a name such as
# Foo.* cannot pick up file names from the directory the script runs in.
set -f
found=0; for t in $THEOREMS; do [ "$t" = "$PRIMARY" ] && found=1; done
set +f
[ "$found" -eq 1 ] || die "the profile of target $RH_TARGET is not usable: TGT_PRIMARY_THEOREM ($PRIMARY) is not one of TGT_THEOREMS"
BODY="$HERE/verify/axioms_check_body.lean"
[ -f "$BODY" ] || die "missing file: $BODY"
# The body names the statement constant and the constants whose defining module it reports. With the
# default target's names the file is used as it is; with any others, rhv_tools.py rewrites those lines.
BODY_AS_IS=0
[ "$TGT_STATEMENT_CONST" = "RiemannHypothesis" ] \
  && [ "$TGT_REPORT_CONSTS" = "RiemannHypothesis riemannZeta DirichletCharacter.LFunction" ] && BODY_AS_IS=1
require_extract_from     # for a target other than the default one: the tree must be the profile's archive
need_cmd python3
need_cmd lean
[ -f "$RH_PROJ/lean-toolchain" ] || die "project not found at $RH_PROJ (run steps 01 to 04 first)"
LIB="$RH_PROJ/.lake/build/lib/lean"
olean="$LIB/$(printf '%s' "$IMPORT" | tr '.' '/').olean"
if [ ! -f "$olean" ]; then
  if [ "$MODE" = probe ]; then
    # 04 compiles the modules of TGT_SMOKE_TARGETS and nothing else of the project.
    case " $TGT_SMOKE_TARGETS " in
      *" $IMPORT "*) die "$IMPORT is not compiled yet (run 04_setup_toolchain.sh first)" ;;
      *) die "$IMPORT is not compiled yet (04_setup_toolchain.sh does not build it; compile it with: 05_build.sh start +$IMPORT)" ;;
    esac
  fi
  hint=""; [ "$HAVE_PROBE" -eq 1 ] && hint=" (--probe works earlier.)"
  die "$IMPORT is not compiled yet: the build has not finished. Check 06_progress.sh.$hint"
fi
ensure_dirs
log "work directory: $RH_WORKDIR"
[ "${RH_TARGET_IS_DEFAULT:-1}" = 1 ] || log "target: $RH_TARGET"
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
body_rc=0
set -f
{
  echo "import $IMPORT"
  if [ "$BODY_AS_IS" -eq 1 ]; then
    cat "$BODY"
  else
    python3 -I -B "$RH_TOOLS" axioms-body --body "$BODY" --statement-const "$TGT_STATEMENT_CONST" \
      --report-consts "$TGT_REPORT_CONSTS" || body_rc=$?
  fi
  echo
  echo "-- Footer generated by scripts/08_check_axioms.sh ($MODE mode)."
  for t in $THEOREMS; do echo "#print axioms $t"; done
  printf 'run_cmd RHVerifyCheck.run "%s" %s `%s [' "$MODE" "$deep_lit" "$PRIMARY"
  sep=""
  for t in $THEOREMS; do printf '%s`%s' "$sep" "$t"; sep=", "; done
  printf ']\n'
} > "$LEANFILE"
set +f
if [ "$body_rc" -ne 0 ]; then
  rm -f "$LEANFILE"
  die "could not write the check for the constants of target $RH_TARGET (see the message above); nothing was run"
fi

raise_nofile
log "running lean on $LEANFILE"
[ "$DEEP" -eq 1 ] && log "--deep: walking every constant the theorems depend on; this can take a long time"
{ echo "### $(date '+%Y-%m-%d %H:%M:%S') $leanver"; echo "### mode=$MODE deep=$DEEP import=$IMPORT"
  [ "${RH_TARGET_IS_DEFAULT:-1}" = 1 ] || echo "### target=$RH_TARGET"; } > "$OUT"
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
set -f; for t in $THEOREMS; do set -- "$@" --theorem "$t"; done; set +f
[ "$DEEP" -eq 1 ] && set -- "$@" --deep
# Only what differs from the default target's values is passed on, so that its command line stays as it was.
[ "$TGT_STATEMENT_CONST" = "RiemannHypothesis" ] || set -- "$@" --statement-const "$TGT_STATEMENT_CONST"
[ "$TGT_STATEMENT_CONST_MODULE" = "Mathlib.NumberTheory.LSeries.RiemannZeta" ] \
  || set -- "$@" --statement-const-module "$TGT_STATEMENT_CONST_MODULE"
# A git source is identified by its commit and directory, also while no SHA-256 of its archive is in the
# profile yet. Any target but the default one is named in the record.
[ "$TGT_SOURCE_KIND" = git ] && set -- "$@" --source-id "$TGT_GIT_URL commit $TGT_GIT_COMMIT${TGT_GIT_SUBDIR:+ directory $TGT_GIT_SUBDIR}"
[ "$RH_TARGET_IS_DEFAULT" = 1 ] || set -- "$@" --target "$RH_TARGET"
python3 -I -B "$RH_TOOLS" "$@"
status=$?
cp "$JSON" "$RH_LOGS/axioms-$MODE-latest.json" 2>/dev/null
log "summary: $JSON"
exit "$status"
