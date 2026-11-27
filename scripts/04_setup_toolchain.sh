#!/bin/bash
# 04_setup_toolchain.sh - install the pinned Lean toolchain, fetch Mathlib's prebuilt cache,
# and prove with a small build that the cache is accepted.
#
# What it does, from RH_PROJ:
#   1. Lets elan select (and, the first time, download) the toolchain named in lean-toolchain,
#      and checks that the lean that runs is that version.
#   2. Clones each git package lake-manifest.json names, Mathlib and its dependencies, and checks
#      it out at the commit named (Lake would clone them in step 3, but see below).
#   3. Runs 'lake exe mathlib/cache get' (Mathlib's cache tool, named by its package), which
#      downloads Mathlib's compiled files instead of compiling them. 'lake update' is never run; the
#      manifest must come out byte-for-byte unchanged.
#   4. Builds the modules of the project that the target names in TGT_SMOKE_TARGETS (for the
#      default target two, Statements and Formalism.GammaFactorNonvanishing.RhOfRight), and
#      fails if any Mathlib module had to be compiled along the way (that would mean the cache
#      was not accepted, and the real build would first spend hours recompiling Mathlib).
#   The project must be configured by lakefile.toml and must have lean-toolchain and
#   lake-manifest.json. A project with a lakefile.lean is refused before anything is run: that
#   file is a program which Lake runs, and it has to be read first. The project files are then
#   checked again as 02 checked them (they may have changed since): lakefile.toml may declare only
#   libraries, with their sources under TGT_SRC_DIR (what 03 read), and requirements; the manifest
#   may name only git packages, each read from its own clone. The project chooses other code that
#   this step runs: the toolchain lean-toolchain names, and the packages at the addresses in
#   lake-manifest.json, whose lakefiles Lake runs (and Mathlib's cache tool). For any target but
#   the default one, 02_inspect_and_extract.sh prints where they come from: read that first. With
#   elan, the lean it chooses must be the release's own, in elan's toolchains directory (elan 4.2
#   would run a lean of the project's at the line's path). The packages are cloned here, not by
#   Lake, from a directory of this step's own and by the commit itself: Lake clones in the
#   project's directory, where git reads an address as a path first, checks a commit out by its
#   hash, which a branch of that name in the clone stands in for, and runs a package's lakefile
#   as soon as it has. Lake then finds each package at its commit and fetches nothing; after each
#   time Lake has run, every package must still be at its commit with the files git tracks
#   unchanged (files it does not track, the package's .lake among them, are not looked at), the
#   manifest must be unchanged, and there must be no .lake/package-overrides.json (Lake would
#   take the packages it names from where it says). Lake runs with LAKE_NO_CACHE=1 (set by lib.sh), so it does not download a
#   prebuilt build of a package before building it (from Reservoir or a package's GitHub
#   releases); a lakefile or tool that asks Lake for a package's release, barrel or cache facet
#   still has one downloaded, and this step stops if it finds the trace of one where Lake puts it
#   by default, in a package's .lake directory.
# What it changes on disk: elan may download a toolchain into ~/.elan. This step and Lake create
#   RH_PROJ/.lake (about 8 GB for the default target). Each package is cloned as
#   .lake/packages/.<name>.rhv-partial and renamed once it is checked; one left by a run that
#   was stopped is removed when the step runs again. A log is written to
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
# files the names with dots turned into slashes. The lists are split on spaces but never expanded
# as file patterns (set -f), so a name such as Foo.* cannot pick up file names from the project.
SMOKE_TARGETS=""; SMOKE_FILES=""; SMOKE_COUNT=0
set -f
for m in $TGT_SMOKE_TARGETS; do
  SMOKE_TARGETS="$SMOKE_TARGETS${SMOKE_TARGETS:+ }+$m"
  SMOKE_FILES="$SMOKE_FILES${SMOKE_FILES:+ }$(printf '%s' "$m" | tr '.' '/')"
  SMOKE_COUNT=$((SMOKE_COUNT + 1))
done
set +f
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

# 0. The project files, checked again as 02 checked them, before anything they name is run.
check_project() {
  set -- project-info "$RH_PROJ" --expected "$RH_EXPECTED"
  [ "$TGT_SRC_DIR" = src ] || set -- "$@" --src-dir "$TGT_SRC_DIR"
  echo "### $(date) project files"
  python3 -I -B "$RH_TOOLS" "$@"
}
check_project >> "$LOG" 2>&1 || { grep -E '^(REFUSED|WARNING)|DIFFER' "$LOG" | tail -n 5
  die "the project files were refused, or do not match what was recorded (see $LOG); nothing was run"; }

# 1. Toolchain.
pinned=$(head -n 1 lean-toolchain | LC_ALL=C tr -d '\r\n')     # C locale: no byte is dropped or stops tr
want=${pinned##*:}; want=${want#v}          # leanprover/lean4:v4.33.1 -> 4.33.1
# What the archive's file says is shown with anything that is not printable as '?', so that it cannot rewrite
# what the terminal shows (02 refuses such a file; this is for a tree put in place some other way).
shown_pinned=$(printf '%s' "$pinned" | LC_ALL=C tr -c '[:print:]' '?')
shown_want=$(printf '%s' "$want" | LC_ALL=C tr -c '[:print:]' '?')
log "pinned toolchain: $shown_pinned (the first use downloads it)"
# With elan, the lean it runs here must be the release's own (elan_bin_dir in common.sh): elan 4.2 reads the line as
# a path in the project first. project-info refuses a project with a file at that path; this checks what elan chose.
# The lean and lake run below, and by 05 and 08, are the first on PATH, normally elan's own, which run what it chose.
if command -v elan >/dev/null 2>&1; then
  echo "### $(date) elan which lean" >> "$LOG"
  tcbin=$(elan_bin_dir 2>> "$LOG") || { sed -n '/^### .* elan which lean$/,$p' "$LOG" | sed 1d | tail -n 6
    die "the lean elan would run is not the release lean-toolchain names, or could not be checked (the reason is above; see $LOG); lean and lake were not run"; }
  log "toolchain directory: $tcbin"
else
  log "elan not found: the lean and lake on PATH are used as they are"
fi
{ echo "### $(date) toolchain"; lean --version; lake --version; } >> "$LOG" 2>&1 \
  || die "lean or lake could not be run; see $LOG"
leanver=$(lean --version 2>/dev/null | head -n 1)
log "$leanver"
case "$leanver" in
  *"version $want"[,\ ]*) ;;
  *) die "the lean on PATH is not version $shown_want. With elan installed, the pinned version is selected automatically." ;;
esac

# A package's prebuilt build that Lake downloaded although LAKE_NO_CACHE is set, because a lakefile or tool asked for
# the package's release, barrel or cache facet. Nothing checks such a build, and lean may load native code from it.
# Lake writes the trace of the archive beside it, by default in the package's .lake directory (<package>-<platform>
# .tar.gz.trace for a release, build.barrel.trace for a barrel): this looks for one in each package's .lake, at any
# depth outside its build directory, and in the project's .lake outside its build, config and packages directories
# (Lake 4.33 keeps the traces of what it builds in the build directories, and those of the packages' compiled
# lakefiles in the project's .lake/config; each package's .lake is looked at on its own). lakefile.olean.trace at the
# top of a .lake directory is left out: an older Lake kept a package's compiled lakefile there. A package's lakefile
# can put its archive elsewhere (buildArchive: in its build directory, outside .lake, or at an absolute path), where
# this does not look.
check_no_release_build() {
  local d f
  for d in .lake .lake/packages/*/.lake; do
    [ -d "$d" ] || continue
    set -- -path "$d/build" -o -path "$d/lakefile.olean.trace"
    [ "$d" = .lake ] && set -- "$@" -o -path "$d/config" -o -path "$d/packages"
    f=$(find -H "$d" \( "$@" \) -prune -o \
          \( -name '*.trace' -o -name '*.tar.gz' -o -name '*.barrel' \) -print 2>/dev/null | head -n 1)
    [ -z "$f" ] || die "Lake downloaded a prebuilt build of a package: $(printf '%s' "$f" | LC_ALL=C tr -c '[:print:]' '?') (a lakefile or tool asked for its release, barrel or cache facet). Nothing checks such a build; do not go on with it."
  done
}

# Lake reads .lake/package-overrides.json, when there is one, in place of the manifest's entries for the packages it
# names (Load/Resolve.lean): a path or another address and commit. Nothing here writes one; a lakefile Lake runs could.
check_no_overrides() {
  [ ! -e .lake/package-overrides.json ] && [ ! -L .lake/package-overrides.json ] \
    || die "$RH_PROJ/.lake/package-overrides.json is there: Lake would take the packages it names from where it says, in place of the entries of lake-manifest.json. Nothing here writes it; do not go on before you know what did"
}

# The git packages lake-manifest.json names, one line each: the directory Lake keeps the package in (its name with no
# guillemets, as Lake writes it), the commit and the address. An entry is read in either form Lake writes (before
# version 7 each is {"git": {...}}). project-info has checked the names, revisions and addresses, and refused every
# other kind of package, so a package this cannot list stops the step.
manifest_git_packages() {
  python3 -I -B -c '
import json, sys
ps = json.load(open(sys.argv[1], encoding="utf-8"))["packages"]
n = 0
for p in ps:
    if isinstance(p, dict) and len(p) == 1 and list(p)[0] in ("git", "path") and isinstance(p[list(p)[0]], dict):
        p = dict(p[list(p)[0]], type=list(p)[0])
    if isinstance(p, dict) and p.get("type") == "git" and all(isinstance(p.get(k), str) for k in ("name", "rev", "url")):
        print("".join(c for c in p["name"] if c not in "\xab\xbb"), p["rev"], p["url"])
        n += 1
if n != len(ps):
    sys.exit("%d of the %d packages in lake-manifest.json are not git packages with a name, a revision and an "
             "address" % (len(ps) - n, len(ps)))
' lake-manifest.json
}

# git for the packages, whatever ~/.gitconfig or the environment says: no replacement refs (a ref under refs/replace,
# or wherever GIT_REPLACE_REF_BASE pointed, would make a commit's files another commit's), and every file compared
# with the index by what is on disk (core.ignoreStat would have git take them all as unchanged, and an fsmonitor could
# answer for them). With GIT_OPTIONAL_LOCKS=0, git status, which compares, writes no index.
pkg_git() { GIT_OPTIONAL_LOCKS=0 git --no-replace-objects -c core.ignoreStat=false -c core.fsmonitor=false "$@"; }

# A package's directory ($1; $2 is the package's name, $3 its commit, $4 what to do if it is not right) must be a git
# clone (not a link) checked out at the commit the manifest names, with the files git tracks as in that commit: git
# status compares them with the clone's index (by size and time, and by content where those differ or cannot be
# trusted) and the index with the commit, and writes nothing. An index entry git is told not to look at
# (assume-unchanged or skip-worktree) is refused, since git would not compare that file. Files git does not track,
# the package's .lake among them, are not looked at.
check_checkout() {
  local d="$1" at out
  [ -d "$d" ] && [ ! -L "$d" ] && [ -d "$d/.git" ] && [ ! -L "$d/.git" ] && [ -f "$d/.git/index" ] \
    || die "$RH_PROJ/$d is not a git clone with its files checked out ($4); see $LOG"
  at=$(pkg_git -C "$d" rev-parse --verify -q HEAD 2>/dev/null) || at=""
  echo "### $2 $at" >> "$LOG"
  [ "$at" = "$3" ] || die "the package $2 is checked out at ${at:-no commit}, not at $3, the commit lake-manifest.json names ($4). Do not build in this state; see $LOG"
  out=$(pkg_git -C "$d" status --porcelain --untracked-files=no 2>> "$LOG") \
    || die "git could not compare the files of the package $2 with its commit $3 ($4). Do not build in this state; see $LOG"
  [ -z "$out" ] || { printf '%s\n' "$out" | head -n 20 >> "$LOG"
    die "the package $2 has files that are not as in its commit $3 ($4). Do not build in this state; see $LOG"; }
  out=$(pkg_git -C "$d" ls-files -v 2>> "$LOG") || die "git could not list the files of the package $2 ($4); see $LOG"
  out=$(printf '%s' "$out" | LC_ALL=C awk 'substr($0, 1, 2) != "H " { print; exit }')
  [ -z "$out" ] || { printf '%s\n' "$out" >> "$LOG"
    die "git is told not to look at a file of the package $2 (assume-unchanged or skip-worktree), so it would not compare that file with the commit $3 ($4). Do not build in this state; see $LOG"; }
}

# Every package again, after Lake has run ($1 says what ran).
check_all_checkouts() {
  echo "### $(date) package checkouts after $1" >> "$LOG"
  while read -r pkg pin url; do
    [ -n "$pkg" ] || continue
    check_checkout ".lake/packages/$pkg" "$pkg" "$pin" "Lake, or a lakefile or tool it ran, changed it during $1; running this step again will not undo that: look at the packages' lakefiles and at Mathlib's cache tool before you go on"
  done <<EOF
$pkgs
EOF
}

# 2. The packages. Lake clones a package with 'git clone <address> <directory>' in the project's directory, and git
# reads the address as a path there first ('https://github.com/x/y' is https:/github.com/x/y, which project-info
# refuses). It checks a commit out with 'git checkout --detach <hash>', which takes a branch of that name in the clone
# over the commit (a clone has one when it is the remote's default branch), does not compare what it checked out with
# the manifest, and runs the package's lakefile as soon as it has. So each git package is cloned here first, from a
# directory of this step's own, and checked out by '<hash>^{commit}', which no branch can stand for. Lake then finds
# each one at its commit and neither fetches nor checks out anything (Load/Materialize.lean). A package is cloned and
# checked under a name of its own beside the package's (no package's name starts with a dot) and only then renamed, so
# that a run stopped half way leaves no directory that looks finished. A package directory that is there already must
# be a clone at the commit named, with its files unchanged. Every package the manifest names is cloned, also one Lake
# would not fetch because nothing the project builds needs it.
echo "### $(date) packages" >> "$LOG"
pkgs=$(manifest_git_packages 2>> "$LOG") || { tail -n 1 "$LOG"; die "lake-manifest.json could not be read for its packages; see $LOG"; }
mkdir -p .lake/packages || die "cannot create $RH_PROJ/.lake/packages"
for p in .lake/packages/.*.rhv-partial; do
  [ -e "$p" ] || [ -L "$p" ] || continue
  log "removing $p, left by an earlier run of this step that did not finish"
  rm -rf -- "$p" || die "cannot remove $RH_PROJ/$p"
done
clonedir=$(mktemp -d "${TMPDIR:-/tmp}/rhv-clone.XXXXXX") || die "cannot make a directory to clone from"
trap 'rmdir "$clonedir" 2>/dev/null' EXIT
while read -r pkg pin url; do
  [ -n "$pkg" ] || continue
  # project-info refuses a name that is not one directory name; this is a second check before one is used as a path.
  case "$pkg" in
    .*|*/*|*\\*) die "the package name $(printf '%s' "$pkg" | LC_ALL=C tr -c '[:print:]' '?') in lake-manifest.json is not the name of one directory; nothing was cloned for it" ;;
  esac
  d=".lake/packages/$pkg"
  if [ -e "$d" ] || [ -L "$d" ]; then
    check_checkout "$d" "$pkg" "$pin" "an earlier run of this step that was stopped, or another program, may have left it; remove it (rm -rf -- $(printf '%q' "$RH_PROJ/$d")) and run this step again to clone it again"
    log "package $pkg: already at $pin"
    continue
  fi
  part=".lake/packages/.$pkg.rhv-partial"
  log "package $pkg: cloning $url, then checking out $pin"
  echo "### $pkg: git clone --no-checkout -- $url" >> "$LOG"
  ( cd "$clonedir" && export GIT_TERMINAL_PROMPT=0 && pkg_git clone -q --no-checkout -- "$url" "$RH_PROJ/$part" ) >> "$LOG" 2>&1 \
    || { tail -n 3 "$LOG"; die "the package $pkg could not be cloned from $url; see $LOG"; }
  # The commit's files are written as they are in it, whatever the package's .gitattributes says (.git/info/attributes
  # comes first): no line ends changed, no $Id$ filled in, no filter run (a filter is a program, git-lfs's for one).
  { mkdir -p "$part/.git/info" && printf '%s\n' '* -text -eol -ident -filter -working-tree-encoding' > "$part/.git/info/attributes"; } \
    || die "cannot write $RH_PROJ/$part/.git/info/attributes"
  pkg_git -C "$part" checkout -q --detach "$pin^{commit}" -- >> "$LOG" 2>&1 \
    || { tail -n 3 "$LOG"; die "the package $pkg could not be checked out at $pin, the commit lake-manifest.json names; see $LOG"; }
  check_checkout "$part" "$pkg" "$pin" "this is the clone this step has just made, and running this step again would make the same one: the commit named may be a tag rather than a commit, or its files cannot all be checked out unchanged on this file system (two paths that differ only in case, say); this step removes it when it runs again"
  mv -- "$part" "$d" || die "cannot rename $RH_PROJ/$part to $RH_PROJ/$d"
done <<EOF
$pkgs
EOF
log "each git package is checked out at the commit lake-manifest.json names"

# 3. Mathlib cache. The manifest must not change.
check_no_overrides
manifest_before=$(sha256_of lake-manifest.json)
# By its package's name: an executable of the project's own called cache would otherwise be the one run.
log "running: lake exe mathlib/cache get (downloads Mathlib's compiled files; several minutes the first time)"
echo "### $(date) lake exe mathlib/cache get" >> "$LOG"
lake exe mathlib/cache get >> "$LOG" 2>&1
rc=$?
echo "### cache rc=$rc" >> "$LOG"
[ "$rc" -eq 0 ] || { tail -n 5 "$LOG"; die "'lake exe mathlib/cache get' failed with status $rc; see $LOG"; }
manifest_after=$(sha256_of lake-manifest.json)
[ "$manifest_before" = "$manifest_after" ] \
  || die "lake-manifest.json changed during setup ($manifest_before -> $manifest_after). The dependency pins are no longer the published ones; extract the source again."
log "lake-manifest.json unchanged: $manifest_after"
check_no_release_build
check_no_overrides
# The packages again, now that Lake has run: each must still be at its commit, with its files unchanged.
check_all_checkouts "lake exe mathlib/cache get"
log "each git package is still checked out at the commit lake-manifest.json names"

mathlib_dir=".lake/packages/mathlib"
if [ -d "$mathlib_dir/.git" ]; then
  rev=$(git -C "$mathlib_dir" rev-parse HEAD 2>/dev/null)
  tags=$(git -C "$mathlib_dir" tag --points-at HEAD 2>/dev/null | tr '\n' ' ')
  log "Mathlib checkout: $rev"
  log "Mathlib tags at that commit: ${tags:-none found in the local clone}"
  { echo "### mathlib rev $rev"; echo "### mathlib tags at HEAD: $tags"; } >> "$LOG"
fi

# 4. Smoke build. No Mathlib module may be compiled.
jobs=$(effective_jobs)
log "running: lake build $SMOKE_TARGETS (with $jobs jobs)"
echo "### $(date) lake build $SMOKE_TARGETS" >> "$LOG"
SMOKE="$LOG.smoke"
set -f
# shellcheck disable=SC2086
LEAN_NUM_THREADS="$jobs" lake build $SMOKE_TARGETS > "$SMOKE" 2>&1
rc=$?
set +f
cat "$SMOKE" >> "$LOG"
echo "### smoke rc=$rc" >> "$LOG"
rebuilt=$(LC_ALL=C grep -cE 'Built Mathlib(\.| )' "$SMOKE")
failed=$(LC_ALL=C grep -c "^$MARK_FAIL " "$SMOKE")
rm -f "$SMOKE"
[ "$rc" -eq 0 ] || { tail -n 15 "$LOG"; die "the smoke build failed with status $rc; see $LOG"; }
[ "$failed" -eq 0 ] || die "the smoke build reported $failed failed job(s); see $LOG"
[ "$rebuilt" -eq 0 ] || die "$rebuilt Mathlib module(s) were compiled locally: the cache was not accepted. See $LOG. Do not start the full build in this state."
check_no_release_build
check_no_overrides
[ "$(sha256_of lake-manifest.json)" = "$manifest_after" ] \
  || die "lake-manifest.json changed during the smoke build (it was $manifest_after). The dependency pins are no longer the published ones; extract the source again."
check_all_checkouts "the smoke build"
set -f
for m in $SMOKE_FILES; do
  [ -f ".lake/build/lib/lean/$m.olean" ] || die "expected compiled file is missing: .lake/build/lib/lean/$m.olean"
done
set +f
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
