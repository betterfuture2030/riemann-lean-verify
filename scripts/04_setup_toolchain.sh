#!/bin/bash
# 04_setup_toolchain.sh - install the pinned Lean toolchain, fetch Mathlib's prebuilt cache,
# and prove with a small build that the cache is accepted.
#
# What it does, from RH_PROJ:
#   1. Lets elan select (and, the first time, download) the toolchain named in lean-toolchain,
#      and checks that the lean that runs is that version.
#   2. Runs 'lake exe cache get'. Lake clones Mathlib and its dependencies at the revisions
#      pinned in lake-manifest.json and downloads Mathlib's compiled files instead of compiling
#      them. 'lake update' is never run; the manifest must come out byte-for-byte unchanged.
#   3. Builds the modules of the project that the target names in TGT_SMOKE_TARGETS (for the
#      default target two, Statements and Formalism.GammaFactorNonvanishing.RhOfRight), and
#      fails if any Mathlib module had to be compiled along the way (that would mean the cache
#      was not accepted, and the real build would first spend hours recompiling Mathlib).
#   The project must be configured by lakefile.toml and must have lean-toolchain and
#   lake-manifest.json. A project with a lakefile.lean is refused before anything is run: that
#   file is a program which Lake runs, and it has to be read first.
# What it changes on disk: elan may download a toolchain into ~/.elan. Lake creates
#   RH_PROJ/.lake (about 8 GB for the default target). A log is written to
#   RH_WORKDIR/logs/setup-<timestamp>.log.
# How long it takes: 5 to 15 minutes the first time, depending on the network. Under a minute
#   when run again. Measured on the default target.
#
# Usage: scripts/04_setup_toolchain.sh
# Exit status: 0 if the toolchain works and the cache was accepted, 1 otherwise.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"
. "$HERE/common.sh"

for arg in "$@"; do
  case "$arg" in
    -h|--help) show_help; exit 0 ;;
    *) die "unknown argument: $arg (try --help)" ;;
  esac
done
# The smoke modules: the Lake targets are the module names with "+" in front, the compiled
# files the names with dots turned into slashes.
SMOKE_TARGETS=""; SMOKE_FILES=""; SMOKE_COUNT=0
for m in $TGT_SMOKE_TARGETS; do
  SMOKE_TARGETS="$SMOKE_TARGETS${SMOKE_TARGETS:+ }+$m"
  SMOKE_FILES="$SMOKE_FILES${SMOKE_FILES:+ }$(printf '%s' "$m" | tr '.' '/')"
  SMOKE_COUNT=$((SMOKE_COUNT + 1))
done
[ "$SMOKE_COUNT" -gt 0 ] || die "TGT_SMOKE_TARGETS names no module for target $RH_TARGET; the smoke build needs at least one"

require_extract_from     # for a target other than the default one: the tree must be the profile's archive
[ ! -f "$RH_PROJ/lakefile.lean" ] || die "$RH_PROJ/lakefile.lean exists. A lakefile that is a program has to be read first: Lake runs it, with your rights, before it builds anything. These scripts support only a project configured by lakefile.toml alone, and nothing was run."
[ -f "$RH_PROJ/lakefile.toml" ] || die "project not found at $RH_PROJ (run 02_inspect_and_extract.sh first)"
for f in lean-toolchain lake-manifest.json; do
  [ -f "$RH_PROJ/$f" ] || die "$RH_PROJ/$f is missing, so the toolchain or the dependency revisions are not pinned. Nothing was run. 02_inspect_and_extract.sh checks the project files."
done
need_cmd lake
need_cmd git
build_is_running && die "a build of this project is running; stop it first (05_build.sh stop) or skip this step"
ensure_dirs
LOG="$RH_LOGS/setup-$(date +%Y%m%d-%H%M%S).log"
[ "$RH_TARGET_IS_DEFAULT" = 1 ] || log "target: $RH_TARGET"
log "work directory: $RH_WORKDIR"
log "log file: $LOG"
cd "$RH_PROJ" || die "cannot enter $RH_PROJ"
raise_nofile

# 1. Toolchain.
pinned=$(head -n 1 lean-toolchain | tr -d '[:space:]')
want=${pinned##*:}; want=${want#v}          # leanprover/lean4:v4.33.1 -> 4.33.1
log "pinned toolchain: $pinned (the first use downloads it)"
{ echo "### $(date) toolchain"; lean --version; lake --version; } >> "$LOG" 2>&1 \
  || die "lean or lake could not be run; see $LOG"
leanver=$(lean --version 2>/dev/null | head -n 1)
log "$leanver"
case "$leanver" in
  *"version $want"[,\ ]*) ;;
  *) die "the lean on PATH is not version $want. With elan installed, the pinned version is selected automatically." ;;
esac

# 2. Mathlib cache. The manifest must not change.
manifest_before=$(sha256_of lake-manifest.json)
log "running: lake exe cache get (downloads Mathlib's compiled files; several minutes the first time)"
echo "### $(date) lake exe cache get" >> "$LOG"
lake exe cache get >> "$LOG" 2>&1
rc=$?
echo "### cache rc=$rc" >> "$LOG"
[ "$rc" -eq 0 ] || { tail -n 5 "$LOG"; die "'lake exe cache get' failed with status $rc; see $LOG"; }
manifest_after=$(sha256_of lake-manifest.json)
[ "$manifest_before" = "$manifest_after" ] \
  || die "lake-manifest.json changed during setup ($manifest_before -> $manifest_after). The dependency pins are no longer the published ones; extract the source again."
log "lake-manifest.json unchanged: $manifest_after"

mathlib_dir=".lake/packages/mathlib"
if [ -d "$mathlib_dir/.git" ]; then
  rev=$(git -C "$mathlib_dir" rev-parse HEAD 2>/dev/null)
  tags=$(git -C "$mathlib_dir" tag --points-at HEAD 2>/dev/null | tr '\n' ' ')
  log "Mathlib checkout: $rev"
  log "Mathlib tags at that commit: ${tags:-none found in the local clone}"
  { echo "### mathlib rev $rev"; echo "### mathlib tags at HEAD: $tags"; } >> "$LOG"
fi

# 3. Smoke build. No Mathlib module may be compiled.
jobs=$(effective_jobs)
log "running: lake build $SMOKE_TARGETS (with $jobs jobs)"
echo "### $(date) lake build $SMOKE_TARGETS" >> "$LOG"
SMOKE="$LOG.smoke"
# shellcheck disable=SC2086
LEAN_NUM_THREADS="$jobs" lake build $SMOKE_TARGETS > "$SMOKE" 2>&1
rc=$?
cat "$SMOKE" >> "$LOG"
echo "### smoke rc=$rc" >> "$LOG"
rebuilt=$(LC_ALL=C grep -cE 'Built Mathlib(\.| )' "$SMOKE")
failed=$(LC_ALL=C grep -c "^$MARK_FAIL " "$SMOKE")
rm -f "$SMOKE"
[ "$rc" -eq 0 ] || { tail -n 15 "$LOG"; die "the smoke build failed with status $rc; see $LOG"; }
[ "$failed" -eq 0 ] || die "the smoke build reported $failed failed job(s); see $LOG"
[ "$rebuilt" -eq 0 ] || die "$rebuilt Mathlib module(s) were compiled locally: the cache was not accepted. See $LOG. Do not start the full build in this state."
for m in $SMOKE_FILES; do
  [ -f ".lake/build/lib/lean/$m.olean" ] || die "expected compiled file is missing: .lake/build/lib/lean/$m.olean"
done
case "$SMOKE_COUNT" in
  1) compiled_msg="the module compiled" ;;
  2) compiled_msg="both modules compiled" ;;
  *) compiled_msg="all $SMOKE_COUNT modules compiled" ;;
esac
log "smoke build ok: $compiled_msg, no Mathlib module was rebuilt"
# 08_check_axioms.sh --probe needs the target's probe module compiled. Say so only if it is.
probe_file=""
[ -n "$TGT_PROBE_MODULE" ] && probe_file=".lake/build/lib/lean/$(printf '%s' "$TGT_PROBE_MODULE" | tr '.' '/').olean"
if [ -n "$probe_file" ] && [ -f "$probe_file" ]; then
  log "setup complete. Next: 05_build.sh start (optionally 08_check_axioms.sh --probe first)"
else
  log "setup complete. Next: 05_build.sh start"
fi
exit 0
