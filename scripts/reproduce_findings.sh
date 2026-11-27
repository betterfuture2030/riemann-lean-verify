#!/bin/bash
# reproduce_findings.sh - re-run every tier-S claim in CLAIMS.md and print PASS or FAIL for each.
#
# What it does: downloads the proof source if it is not already there, verifies its SHA-256, inspects
#   the archive, extracts it, runs the source audit, checks that the pinned Mathlib revision is the
#   official tag, rebuilds the import graph and compares it with the recorded summary, and counts
#   the files that use the kernel-deferring tactics. Nothing is compiled; Lean is not needed.
#
#   The claims in CLAIMS.md are about the default target. For another target (RH_TARGET, see
#   targets/README.md) the same checks are run on that target's source and compared with that
#   target's records, under the same names S1 to S10. A check that had nothing to compare with is
#   reported as n/a, with the reason, and is not counted as reproduced. That is the case for S5
#   when the profile names no Mathlib tag (TGT_MATHLIB_TAG), for S10 when it names no pattern
#   (TGT_S10_PATTERN) or no count (TGT_S10_COUNT), and, for a target other than the default one,
#   for S2-S4, S6-S8 and S9 when nothing is recorded for it: those steps still run, and what they
#   found is in their logs. For the default target a missing record is a failure, as it always was:
#   its records are part of this repository.
# What it changes on disk: RH_WORKDIR/download (about 0.5 GB), RH_WORKDIR/extract (about 1.3 GB),
#   RH_WORKDIR/analysis and RH_WORKDIR/logs. Nothing outside RH_WORKDIR. The sizes are the default
#   target's.
# How long it takes: 5 to 15 minutes on a laptop for the default target, mostly the download and
#   the scans.
#
# Usage: scripts/reproduce_findings.sh
# Exit status: 0 if no check failed, 1 otherwise. A check reported as n/a is not a failure.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"
. "$HERE/common.sh"
ensure_dirs
need_cmd python3
# git fetches a git source and looks up the Mathlib tag (S5); curl downloads the parts of a tarball.
if [ "$TGT_SOURCE_KIND" = git ] || [ -n "$TGT_MATHLIB_TAG" ]; then need_cmd git; fi
[ "$TGT_SOURCE_KIND" != tarball-parts ] || need_cmd curl
need_cmd tar
require_extract_from     # for a target other than the default one: the tree must be the profile's archive
[ "$RH_TARGET_IS_DEFAULT" = 1 ] || log "target: $RH_TARGET   work directory: $RH_WORKDIR"

RESULTS=""; FAILED=0; TOTAL=0; PASSED=0; NA=0
RC_NA=77       # status of a check function that had nothing to compare with; NA_REASON says why
NA_REASON=""
record() { # record <claim ids> <PASS|FAIL|n/a> <description>
  RESULTS="$RESULTS$1|$2|$3
"
  TOTAL=$((TOTAL + 1))
  case "$2" in PASS) PASSED=$((PASSED + 1)) ;; n/a) NA=$((NA + 1)) ;; *) FAILED=1 ;; esac
}
# run <claim ids> <description> <description if nothing was recorded> <command...>
# The command's output goes to a log. The result is n/a, not PASS, in two cases: the command is one
# of the functions below and returned RC_NA after setting NA_REASON; or the third argument is not
# empty and a step that ended with status 0 printed the notice that 02 and 03 print when they have
# no recorded values to compare with (they then end with status 0 whatever they found).
run() {
  local ids=$1 desc=$2 unrecorded=$3 out rc
  shift 3
  log "---- $ids: $desc"
  out="$RH_LOGS/reproduce_$(echo "$ids" | tr ' ,/' '___').log"
  NA_REASON=""
  "$@" > "$out" 2>&1
  rc=$?
  if [ "$rc" -eq "$RC_NA" ] && [ -n "$NA_REASON" ]; then record "$ids" "n/a" "$NA_REASON"
  elif [ "$rc" -ne 0 ]; then record "$ids" FAIL "$desc (see $RH_LOGS)"
  elif [ -n "$unrecorded" ] && LC_ALL=C grep -q 'NO RECORDED VALUES TO COMPARE WITH' "$out"; then record "$ids" "n/a" "$unrecorded"
  else record "$ids" PASS "$desc"; fi
}

# What each row of the table says. For the default target these are the claims of CLAIMS.md, in
# the words used before there were targets; for another target they say what was compared.
case "$TGT_SOURCE_KIND" in
  git)
    if [ -n "$RH_TARBALL_SHA256" ]; then d1="source is commit $TGT_GIT_COMMIT; the archive made from it matches the recorded SHA-256"
    else d1="source is commit $TGT_GIT_COMMIT (no SHA-256 is recorded yet for the archive made from it; 01_fetch.sh prints the value)"; fi ;;
  *) d1="source parts and tarball match the recorded SHA-256" ;;
esac
if [ "$RH_TARGET_IS_DEFAULT" = 1 ]; then
  d6="no escape hatches, no IO, no shadowing of the headline names"
  d10="$TGT_S10_COUNT files use the kernel-deferring tactics"
else
  d6="source audit: no category recorded as zero has matches"
  d10="$TGT_S10_COUNT source files match TGT_S10_PATTERN"
fi

# What to say when 02 or 03 had nothing recorded to compare with. Only for a target other than the default one:
# for the default target such a step passes or fails as it did before there were targets.
u24=""; u68=""
if [ "$RH_TARGET_IS_DEFAULT" = 0 ]; then
  u24="archive listing and project files: nothing recorded for this target (every entry passed the safety checks; what was found is in $RH_LOGS; to record it: scripts/02_inspect_and_extract.sh --write-expected $TGT_RECORDS_DIR/expected.json)"
  u68="source audit: nothing recorded for this target (the scan ran; its counts are in $RH_LOGS and were compared with nothing; to record them: scripts/03_audit_source.sh --write-expected $TGT_RECORDS_DIR/expected.json)"
fi
run "S1" "$d1" "" bash "$HERE/01_fetch.sh"
run "S2-S4" "archive is structurally safe; file counts and build configuration match" "$u24" \
  bash "$HERE/02_inspect_and_extract.sh"
run "S6-S8" "$d6" "$u68" bash "$HERE/03_audit_source.sh" --show 0

s5() { # the pinned Mathlib revision is what the official repository's tag TGT_MATHLIB_TAG points to
  local want got
  want=$(python3 -c "import json,sys; print([p['rev'] for p in json.load(open(sys.argv[1]))['packages'] if p['name']=='mathlib'][0])" "$RH_PROJ/lake-manifest.json") || return 1
  got=$(git ls-remote https://github.com/leanprover-community/mathlib4 "refs/tags/$TGT_MATHLIB_TAG" | cut -f1) || return 1
  echo "manifest: $want"; echo "official tag $TGT_MATHLIB_TAG: $got"
  [ -n "$want" ] && [ "$want" = "$got" ]
}
if [ -n "$TGT_MATHLIB_TAG" ]; then
  run "S5" "pinned Mathlib revision is the official tag $TGT_MATHLIB_TAG" "" s5
else
  log "---- S5: not applicable: the profile names no Mathlib tag"
  record "S5" "n/a" "pinned Mathlib revision: the profile names no official tag to compare it with (TGT_MATHLIB_TAG is empty)"
fi

s9() { # import graph: every module is in the closure of the root module; longest chain as recorded
  local recorded="$RH_RECORDS_SRC/import_graph_summary.json"
  # For the default target the command is the one it was before there were targets (its root is Main).
  set -- "$RH_SRC" "$RH_AN"
  [ "$RH_TARGET_IS_DEFAULT" = 1 ] || set -- "$@" --root "$TGT_ROOT_MODULE"
  python3 "$REPO_ROOT/analysis/import_graph.py" "$@" > /dev/null || return 1
  # For the default target a missing record is a failure (the comparison below cannot read it), as before.
  if [ ! -f "$recorded" ] && [ "$RH_TARGET_IS_DEFAULT" = 0 ]; then
    echo "nothing to compare with: $recorded does not exist"
    echo "the summary made now: $RH_AN/import_graph_summary.json"
    NA_REASON="import graph: nothing recorded for this target (to record the summary made now: cp $RH_AN/import_graph_summary.json $TGT_RECORDS_DIR/)"
    return "$RC_NA"
  fi
  python3 - "$RH_AN/import_graph_summary.json" "$recorded" <<'PY'
import json, sys
got, want = json.load(open(sys.argv[1])), json.load(open(sys.argv[2]))
ok = True
for k in ('modules_total', 'main_closure_modules', 'not_in_main_closure', 'critical_path_depth_modules', 'lines_total'):
    same = got.get(k) == want.get(k); ok = ok and same
    print('%-30s got %-12s recorded %-12s %s' % (k, got.get(k), want.get(k), 'ok' if same else 'DIFFERENT'))
sys.exit(0 if ok else 1)
PY
}
run "S9" "import graph matches the recorded summary" "" s9

s10() { # source files that match TGT_S10_PATTERN (for the default target: the kernel-deferring tactics)
  local n
  if [ "$RH_TARGET_IS_DEFAULT" = 1 ]; then
    # The commands that gave the recorded count, as they were before there were targets.
    if command -v rg >/dev/null 2>&1; then n=$(rg -l --no-messages -e "$TGT_S10_PATTERN" "$RH_SRC" | wc -l | tr -d ' ')
    else n=$(grep -rlE "$TGT_S10_PATTERN" "$RH_SRC" | wc -l | tr -d ' '); fi
  else
    # Every .lean file is searched as text, hidden or not and whatever an ignore file in the archive says,
    # except what Lake keeps in .lake (there is one under the sources only when they are the project
    # directory itself).
    if command -v rg >/dev/null 2>&1; then n=$(rg -l --no-messages --no-ignore --hidden --text --glob '*.lean' --glob '!.lake' -e "$TGT_S10_PATTERN" "$RH_SRC" | wc -l | tr -d ' ')
    else n=$(grep -rlE -a --include='*.lean' --exclude-dir=.lake -e "$TGT_S10_PATTERN" "$RH_SRC" | wc -l | tr -d ' '); fi
  fi
  if [ -z "$TGT_S10_COUNT" ]; then
    echo "files matching TGT_S10_PATTERN: $n (the profile gives no number to compare with)"
    NA_REASON="$n source files match TGT_S10_PATTERN; the profile gives no number to compare with (TGT_S10_COUNT is empty)"
    return "$RC_NA"
  fi
  if [ "$RH_TARGET_IS_DEFAULT" = 1 ]; then echo "files using kernel-deferring tactics: $n (recorded: $TGT_S10_COUNT)"
  else echo "files matching TGT_S10_PATTERN: $n (the profile says: $TGT_S10_COUNT)"; fi
  [ "$n" = "$TGT_S10_COUNT" ]
}
if [ -n "$TGT_S10_PATTERN" ]; then
  run "S10" "$d10" "" s10
else
  log "---- S10: not applicable: the profile names no pattern"
  record "S10" "n/a" "source-file pattern count: the profile names no pattern to count (TGT_S10_PATTERN is empty)"
fi

echo
echo "Claim     Result  Check"
echo "--------  ------  -----"
printf '%s' "$RESULTS" | while IFS='|' read -r ids res desc; do [ -n "$ids" ] && printf '%-8s  %-6s  %s\n' "$ids" "$res" "$desc"; done
echo
if [ "$RH_TARGET_IS_DEFAULT" = 1 ]; then claims="tier-S claims"; whose=""; else claims="claims"; whose=" for target $RH_TARGET"; fi
if [ "$NA" = 1 ]; then na_line="1 claim was not applicable (n/a above)"; else na_line="$NA claims were not applicable (n/a above)"; fi
if [ "$FAILED" != 0 ]; then
  echo "At least one claim did NOT reproduce$whose. Logs are in $RH_LOGS."
  [ "$NA" = 0 ] || echo "$na_line."
elif [ "$NA" != 0 ]; then
  echo "$PASSED of $TOTAL $claims reproduced$whose. $na_line: nothing was compared for them, so they are neither reproduced nor refuted. None failed."
elif [ "$RH_TARGET_IS_DEFAULT" = 1 ]; then
  echo "All tier-S claims reproduced."
else
  echo "All $TOTAL claims reproduced$whose."
fi
exit "$FAILED"
