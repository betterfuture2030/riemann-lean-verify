#!/bin/bash
# 02_inspect_and_extract.sh - inspect the tarball before trusting it, then extract it.
#
# What it does:
#   1. Re-checks the tarball's SHA-256 against RH_TARBALL_SHA256.
#   2. Lists the tarball without extracting it and refuses to continue unless every entry is a
#      regular file under lean/, with no symbolic links, hard links, absolute paths, '..'
#      components, executable bits or duplicate names. Prints entry counts by extension.
#   3. Extracts into RH_WORKDIR/extract (skipped if already extracted).
#   4. Prints lean-toolchain, the Mathlib revision from lake-manifest.json and the SHA-256 of
#      lakefile.toml, lake-manifest.json and lean-toolchain.
#   Steps 2 and 4 are compared with records/source/expected.json when that file exists.
# What it changes on disk: creates RH_WORKDIR/extract (via a temporary RH_WORKDIR/extract.partial,
#   which is removed if a previous run left one behind). With --check-only it writes nothing.
# How long it takes: under a minute to list, one to a few minutes to extract 175,190 files.
#   --verify-tree reads every extracted file once more (1.0 GB): about a minute.
#
# Usage: scripts/02_inspect_and_extract.sh [--check-only] [--verify-tree] [--write-expected FILE]
#   --check-only           do the listing and the comparisons; extract nothing, change nothing
#   --verify-tree          also compare every extracted file byte for byte with the tarball and
#                          report files on disk (outside .lake) that are not in the tarball
#   --write-expected FILE  record the observed values in FILE (for maintainers of the records)
# Exit status: 0 if everything checked out, 1 otherwise.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"
. "$HERE/common.sh"

CHECK_ONLY=0; VERIFY_TREE=0; WRITE_EXPECTED=""
while [ $# -gt 0 ]; do
  case "$1" in
    --check-only) CHECK_ONLY=1 ;;
    --verify-tree) VERIFY_TREE=1 ;;
    --write-expected) shift; [ $# -gt 0 ] || die "--write-expected needs a file name"; WRITE_EXPECTED=$1 ;;
    -h|--help) show_help; exit 0 ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
  shift
done
need_cmd python3
need_cmd tar
EXTRACT="$RH_WORKDIR/extract"
log "work directory: $RH_WORKDIR"

# 1. The tarball must be the one the records refer to.
[ -f "$RH_TARBALL" ] || die "tarball not found: $RH_TARBALL (run 01_fetch.sh first)"
sha=$(sha256_of "$RH_TARBALL")
[ "$sha" = "$RH_TARBALL_SHA256" ] || die "tarball SHA-256 is $sha, expected $RH_TARBALL_SHA256 (run 01_fetch.sh)"
log "tarball SHA-256 ok: $sha"

# Is there a complete extraction already? (All three project files and every source file.)
extracted=0
if [ -d "$EXTRACT" ]; then
  if [ -f "$RH_PROJ/lakefile.toml" ] && [ -f "$RH_PROJ/lake-manifest.json" ] && [ -f "$RH_PROJ/lean-toolchain" ]; then
    extracted=1
  else
    die "$EXTRACT exists but does not contain the project files. Move it aside or delete it, then run this script again."
  fi
fi

# 2. Listing and entry checks (and, on request, the byte-for-byte tree comparison).
set -- tar-inspect "$RH_TARBALL" --sha256 "$sha" --expected "$RH_EXPECTED"
if [ "$VERIFY_TREE" -eq 1 ]; then
  if [ "$extracted" -eq 1 ]; then set -- "$@" --verify-tree "$EXTRACT"
  else log "--verify-tree: nothing is extracted yet; it will be done after extraction"; fi
fi
[ -n "$WRITE_EXPECTED" ] && set -- "$@" --write-expected "$WRITE_EXPECTED"
log "listing the tarball (nothing is extracted in this step)"
python3 -I -B "$RH_TOOLS" "$@" || die "the tarball listing did not pass; nothing was extracted"

# 3. Extraction.
if [ "$extracted" -eq 1 ]; then
  have=$(count_sources)
  log "already extracted: $RH_PROJ ($have Lean source files); not extracting again"
elif [ "$CHECK_ONLY" -eq 1 ]; then
  log "--check-only: not extracting"
else
  if [ -d "$EXTRACT.partial" ]; then
    log "removing the incomplete extraction left by an earlier run: $EXTRACT.partial"
    rm -rf "$EXTRACT.partial"
  fi
  mkdir -p "$EXTRACT.partial" || die "cannot create $EXTRACT.partial"
  log "extracting into $EXTRACT (this takes a minute or more)"
  tar -xzf "$RH_TARBALL" -C "$EXTRACT.partial" || die "tar failed; the incomplete tree is in $EXTRACT.partial"
  mv "$EXTRACT.partial" "$EXTRACT" || die "could not move $EXTRACT.partial into place"
  extracted=1
  log "extracted $(count_sources) Lean source files"
  if [ "$VERIFY_TREE" -eq 1 ]; then
    python3 -I -B "$RH_TOOLS" tar-inspect "$RH_TARBALL" --quiet --verify-tree "$EXTRACT" \
      || die "the extracted tree does not match the tarball"
  fi
fi

# 4. Project files.
if [ "$extracted" -eq 1 ]; then
  set -- project-info "$RH_PROJ" --expected "$RH_EXPECTED"
  [ -n "$WRITE_EXPECTED" ] && set -- "$@" --write-expected "$WRITE_EXPECTED"
  python3 -I -B "$RH_TOOLS" "$@" || die "the project files do not match what was expected"
else
  log "project files not checked: nothing is extracted"
fi
log "done"
exit 0
