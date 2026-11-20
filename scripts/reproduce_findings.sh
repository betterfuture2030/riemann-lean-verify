#!/bin/bash
# reproduce_findings.sh - re-run every tier-S claim in CLAIMS.md and print PASS or FAIL for each.
#
# What it does: downloads the proof source if it is not already there, verifies its SHA-256, inspects
#   the archive, extracts it, runs the source audit, checks that the pinned Mathlib revision is the
#   official tag, rebuilds the import graph and compares it with the recorded summary, and counts
#   the files that use the kernel-deferring tactics. Nothing is compiled; Lean is not needed.
# What it changes on disk: RH_WORKDIR/download (about 0.5 GB), RH_WORKDIR/extract (about 1.3 GB),
#   RH_WORKDIR/analysis and RH_WORKDIR/logs. Nothing outside RH_WORKDIR.
# How long it takes: 5 to 15 minutes on a laptop, mostly the download and the scans.
#
# Usage: scripts/reproduce_findings.sh
# Exit status: 0 if every check passed, 1 otherwise.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"
ensure_dirs
need_cmd python3; need_cmd git; need_cmd curl; need_cmd tar
RESULTS=""; FAILED=0
record() { RESULTS="$RESULTS$1|$2|$3
"; [ "$2" = PASS ] || FAILED=1; }
run() { # run <claim ids> <description> <command...>
  local ids=$1 desc=$2; shift 2
  log "---- $ids: $desc"
  if "$@" > "$RH_LOGS/reproduce_$(echo "$ids" | tr ' ,/' '___').log" 2>&1; then record "$ids" PASS "$desc"; else record "$ids" FAIL "$desc (see $RH_LOGS)"; fi
}

run "S1" "source parts and tarball match the recorded SHA-256" bash "$HERE/01_fetch.sh"
run "S2-S4" "archive is structurally safe; file counts and build configuration match" bash "$HERE/02_inspect_and_extract.sh"
run "S6-S8" "no escape hatches, no IO, no shadowing of the headline names" bash "$HERE/03_audit_source.sh" --show 0

s5() { # the pinned Mathlib revision is what the official repository's tag v4.33.1 points to
  local want got
  want=$(python3 -c "import json,sys; print([p['rev'] for p in json.load(open(sys.argv[1]))['packages'] if p['name']=='mathlib'][0])" "$RH_PROJ/lake-manifest.json") || return 1
  got=$(git ls-remote https://github.com/leanprover-community/mathlib4 refs/tags/v4.33.1 | cut -f1) || return 1
  echo "manifest: $want"; echo "official tag v4.33.1: $got"
  [ -n "$want" ] && [ "$want" = "$got" ]
}
run "S5" "pinned Mathlib revision is the official tag v4.33.1" s5

s9() { # import graph: every module is in the closure of Main; longest chain as recorded
  python3 "$REPO_ROOT/analysis/import_graph.py" "$RH_PROJ/src" "$RH_AN" > /dev/null || return 1
  python3 - "$RH_AN/import_graph_summary.json" "$RECORDS/source/import_graph_summary.json" <<'PY'
import json, sys
got, want = json.load(open(sys.argv[1])), json.load(open(sys.argv[2]))
ok = True
for k in ('modules_total', 'main_closure_modules', 'not_in_main_closure', 'critical_path_depth_modules', 'lines_total'):
    same = got.get(k) == want.get(k); ok = ok and same
    print('%-30s got %-12s recorded %-12s %s' % (k, got.get(k), want.get(k), 'ok' if same else 'DIFFERENT'))
sys.exit(0 if ok else 1)
PY
}
run "S9" "import graph matches the recorded summary" s9

s10() { # files that use the kernel-deferring tactics
  local n
  if command -v rg >/dev/null 2>&1; then n=$(rg -l --no-messages -e 'kexactB|kc%|kcopy|tr_via|tr_clause|cpt_copy_thms' "$RH_PROJ/src" | wc -l | tr -d ' ')
  else n=$(grep -rlE 'kexactB|kc%|kcopy|tr_via|tr_clause|cpt_copy_thms' "$RH_PROJ/src" | wc -l | tr -d ' '); fi
  echo "files using kernel-deferring tactics: $n (recorded: 77)"; [ "$n" = 77 ]
}
run "S10" "77 files use the kernel-deferring tactics" s10

echo
echo "Claim     Result  Check"
echo "--------  ------  -----"
printf '%s' "$RESULTS" | while IFS='|' read -r ids res desc; do [ -n "$ids" ] && printf '%-8s  %-6s  %s\n' "$ids" "$res" "$desc"; done
echo
if [ "$FAILED" = 0 ]; then echo "All tier-S claims reproduced."; else echo "At least one claim did NOT reproduce. Logs are in $RH_LOGS."; fi
exit "$FAILED"
