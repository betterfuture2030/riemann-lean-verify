#!/bin/bash
# 03_audit_source.sh - read-only text scan of the proof source for the standard escape hatches.
#
# What it does: scans every .lean file under RH_SRC, the source directory of the target (for the
#   default target RH_PROJ/src), and prints, for each category, the number of matching lines
#   and the number of files they are in. The categories are the words
#   sorry, admit, axiom, native_decide, unsafe, implemented_by, extern, opaque, '#eval',
#   initialize, IO / process / file primitives (by the names of Lean's functions, and
#   separately the bare word IO), skipKernelTC, addDecl-style calls, modifyEnv, run_cmd /
#   run_elab / run_meta, and commands that define syntax (elab, macro, notation and their local
#   and scoped forms). It also prints a histogram of set_option names, the list of files that
#   import Lean metaprogramming modules or mention MetaM, TacticM, CommandElabM or Environment,
#   and any declaration named by the target's TGT_PROTECTED_NAMES (for the default target
#   RiemannHypothesis, riemannZeta or LFunction). The exact patterns are in
#   scripts/verify/rhv_tools.py.
#   The result is compared with the target's expected.json (for the default target
#   records/source/expected.json) when that file exists and has an audit section. When it does
#   not, nothing is compared, the output says so in capitals, and the exit status is 0 whatever
#   was found: read the counts.
#
#   This is static reading of text, not a proof check. Matches are counted wherever they occur,
#   including comments. A zero is informative; a non-zero count is a list of places to read. The
#   Lean kernel, not this scan, decides what a proof depends on (see 08_check_axioms.sh).
#
#   How it works: one pass with ripgrep (or grep -r when ripgrep is not installed) keeps the
#   lines that contain any of a fixed list of strings; scripts/verify/rhv_tools.py then applies
#   the category patterns to those lines. The counts do not depend on which tool did the pass.
# What it changes on disk: nothing. The matched lines are passed between the two stages through
#   a pipe. Only with --save DIR are the matched lines and a JSON summary written, into DIR, and
#   only with --write-expected FILE is FILE written.
# How long it takes: 35 seconds with ripgrep on the full source of the default target (1.0 GB,
#   measured 2026-11-20 while a build was running). grep -r is slower; it was not timed on the
#   full source.
#
# Usage: scripts/03_audit_source.sh [--tool rg|grep] [--show N] [--save DIR] [--from-hits FILE]
#                                   [--strict] [--write-expected FILE]
#   --tool rg|grep         force the tool used for the pass (default: rg if installed)
#   --show N               print the first N matching lines of each category (default 3; 0 = none)
#   --save DIR             keep hits.txt and audit.json in DIR
#   --from-hits FILE       classify a hits.txt saved earlier instead of scanning again
#   --strict               treat any difference from the recorded values as a failure
#   --write-expected FILE  record the observed values in FILE (for maintainers of the records)
# Exit status: 0; or 1 if a category recorded as zero now has matches (with --strict: on any
#   difference from the recorded values), or if the scan could not be run.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"
. "$HERE/common.sh"

TOOL=""; SHOW=3; SAVE=""; FROM_HITS=""; STRICT=0; WRITE_EXPECTED=""
while [ $# -gt 0 ]; do
  case "$1" in
    --tool) shift; [ $# -gt 0 ] || die "--tool needs rg or grep"; TOOL=$1 ;;
    --show) shift; [ $# -gt 0 ] || die "--show needs a number"; SHOW=$1 ;;
    --save) shift; [ $# -gt 0 ] || die "--save needs a directory"; SAVE=$1 ;;
    --from-hits) shift; [ $# -gt 0 ] || die "--from-hits needs a file"; FROM_HITS=$1 ;;
    --strict) STRICT=1 ;;
    --write-expected) shift; [ $# -gt 0 ] || die "--write-expected needs a file name"; WRITE_EXPECTED=$1 ;;
    -h|--help) show_help; exit 0 ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
  shift
done
need_cmd python3
require_extract_from     # for a target other than the default one: the tree must be the profile's archive
SRC="$RH_SRC"
[ -d "$SRC" ] || die "source directory not found: $SRC (run 02_inspect_and_extract.sh first)"
# A source directory that is the project directory itself (TGT_SRC_DIR=.) also holds .lake once
# 04 has run, and in it the sources of every dependency. Those are not the published source:
# that one directory is left out of the count and of the scan. The default target's sources are
# in a directory of their own, so nothing is left out there.
SKIP_LAKE=0
[ "$SRC" -ef "$RH_PROJ" ] && SKIP_LAKE=1
if [ -z "$TOOL" ]; then
  if command -v rg >/dev/null 2>&1; then TOOL=rg; else TOOL=grep; fi
fi
case "$TOOL" in
  rg) need_cmd rg ;;
  grep) need_cmd grep ;;
  *) die "--tool must be rg or grep" ;;
esac

[ "$RH_TARGET_IS_DEFAULT" = 1 ] || log "target: $RH_TARGET"
log "source directory: $SRC"
if [ "$SKIP_LAKE" -eq 1 ]; then
  log "the source directory is the project directory: its .lake directory is not scanned or counted"
  nfiles=$(cd "$SRC" && find . -path ./.lake -prune -o -name '*.lean' -type f -print | wc -l | tr -d ' ')
else
  nfiles=$(count_sources)
fi
# The protected names are passed on only when they are not the default target's, so that its command
# lines stay as they were before there were targets (the tool's defaults are the same names).
PROTECTED=()
[ "$TGT_PROTECTED_NAMES" = "RiemannHypothesis riemannZeta LFunction" ] || PROTECTED=(--protected-names "$TGT_PROTECTED_NAMES")
LITS=()
while IFS= read -r lit; do
  [ -n "$lit" ] && LITS+=(-e "$lit")
done < <(python3 -I -B "$RH_TOOLS" audit-literals ${PROTECTED[@]+"${PROTECTED[@]}"})
[ "${#LITS[@]}" -gt 0 ] || die "could not list the search strings"

set -- audit-classify --hits - --lean-files "$nfiles" --show "$SHOW" --expected "$RH_EXPECTED" \
       ${PROTECTED[@]+"${PROTECTED[@]}"}
[ "$STRICT" -eq 1 ] && set -- "$@" --strict
[ -n "$WRITE_EXPECTED" ] && set -- "$@" --write-expected "$WRITE_EXPECTED"
if [ -n "$SAVE" ]; then
  mkdir -p "$SAVE" || die "cannot create $SAVE"
  set -- "$@" --json "$SAVE/audit.json"
fi

# Stage 1 prints  ./path:line:text  for every line that contains one of the strings; stage 2
# reads that from its standard input. Nothing is written unless --save was given.
stage1() {
  if [ -n "$FROM_HITS" ]; then
    cat "$FROM_HITS"
  elif [ "$TOOL" = rg ] && [ "$SKIP_LAKE" -eq 1 ]; then
    (cd "$SRC" && rg --no-config --no-ignore --hidden --text --no-heading --line-number --with-filename \
        --color never -F "${LITS[@]}" -g '*.lean' -g '!/.lake/' .)
  elif [ "$TOOL" = rg ]; then
    (cd "$SRC" && rg --no-config --no-ignore --hidden --text --no-heading --line-number --with-filename \
        --color never -F "${LITS[@]}" -g '*.lean' .)
  elif [ "$SKIP_LAKE" -eq 1 ]; then
    # grep cannot leave out one directory by its path, so its lines are dropped afterwards.
    (cd "$SRC" && { LC_ALL=C grep -r -a -n -H -F "${LITS[@]}" --include='*.lean' . | LC_ALL=C grep -a -v '^\./\.lake/'
                    exit "${PIPESTATUS[0]}"; })
  else
    (cd "$SRC" && LC_ALL=C grep -r -a -n -H -F "${LITS[@]}" --include='*.lean' .)
  fi
}
if [ -n "$FROM_HITS" ]; then
  [ -f "$FROM_HITS" ] || die "hits file not found: $FROM_HITS"
  TOOL="saved-hits-file"
  log "classifying saved hits (the source is not scanned again)"
else
  log "scanning $nfiles Lean files with $TOOL for $(( ${#LITS[@]} / 2 )) fixed strings"
fi
if [ -n "$SAVE" ] && [ "$FROM_HITS" != "$SAVE/hits.txt" ]; then
  stage1 | tee "$SAVE/hits.txt" | python3 -I -B "$RH_TOOLS" "$@" --tool "$TOOL"
  st=("${PIPESTATUS[@]}"); rc1=${st[0]}; rc=${st[2]}
else
  stage1 | python3 -I -B "$RH_TOOLS" "$@" --tool "$TOOL"
  st=("${PIPESTATUS[@]}"); rc1=${st[0]}; rc=${st[1]}
fi
# Status 1 from rg or grep means "no line matched", which is not an error here.
[ "$rc1" -le 1 ] || die "$TOOL failed with status $rc1; the counts above are not reliable"
[ -n "$SAVE" ] && log "kept the matched lines and the summary in $SAVE"
exit "$rc"
