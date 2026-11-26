#!/bin/bash
# 02_inspect_and_extract.sh - inspect the tarball before trusting it, then extract it.
#
# What it does:
#   1. Re-checks the tarball's SHA-256 against RH_TARBALL_SHA256. (A target whose source is a
#      git commit may have no SHA-256 pinned yet: the script then says so in capitals and goes on.)
#   2. Lists the tarball without extracting it and refuses to continue unless every entry is a
#      regular file under the archive's top directory (TGT_ARCHIVE_PREFIX; lean/ for the default
#      target), with no symbolic links, hard links, absolute paths, '..' components, executable
#      bits or duplicate names. Prints entry counts by extension. A target's profile can allow
#      executable bits (TGT_ARCHIVE_ALLOW_EXEC=1) and nothing else of that list.
#   3. Extracts into RH_WORKDIR/extract (skipped if already extracted). The tarball may be
#      gzipped or not. For a git source the extracted files get the time of extraction, because
#      the tar file that 01_fetch.sh writes carries no times. For any target but the default one,
#      what tar wrote is then compared with the listing (rhv_tools.py tar-inspect
#      --check-extracted), and the tree is put in place only if it holds the entries of the
#      listing and nothing else: no links, no other files, nothing in .lake.
#   4. Prints lean-toolchain, the Mathlib revision from lake-manifest.json and the SHA-256 of
#      lakefile.toml, lake-manifest.json and lean-toolchain.
#   Steps 2 and 4 are compared with the target's expected.json (records/source/expected.json for
#   the default target) when that file exists.
# What it changes on disk: creates RH_WORKDIR/extract (via a temporary RH_WORKDIR/extract.partial,
#   which is removed if a previous run left one behind). For any target but the default one it also
#   writes RH_WORKDIR/extract.from, which names the archive the tree came from (its SHA-256 and, for
#   a git source, the address, commit, directory and prefix), and uses an existing tree only if that
#   whole line is what the archive here now and the profile give. A git source, pinned or not, is
#   used only if 01_fetch.sh's record beside it (<tar file>.from) says it was written from the
#   address, commit, directory and prefix the profile names. With --check-only it writes nothing.
#   --write-expected writes FILE, with or without --check-only, and creates its directory if
#   that is missing.
# How long it takes: for the default target, under a minute to list and one to a few minutes to
#   extract 175,190 files; --verify-tree reads every extracted file once more (1.0 GB): about a
#   minute.
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
if [ -n "$RH_TARBALL_SHA256" ]; then
  [ "$sha" = "$RH_TARBALL_SHA256" ] || die "tarball SHA-256 is $sha, expected $RH_TARBALL_SHA256 (run 01_fetch.sh)"
  log "tarball SHA-256 ok: $sha"
elif [ "$TGT_SOURCE_KIND" = git ]; then
  # Allowed for a git source only, and meant for its first run: see targets/README.md.
  log "THE ARCHIVE IS NOT PINNED BY A SHA-256: TGT_TARBALL_SHA256 is empty for the target $RH_TARGET, so the"
  log "file is identified only by the commit that 01_fetch.sh wrote it from. 01_fetch.sh prints the line that pins it."
  log "tarball SHA-256, compared with nothing: $sha"
else
  die "no SHA-256 is set for the tarball (RH_TARBALL_SHA256 is empty); only a git source may be without one"
fi
if [ "$TGT_SOURCE_KIND" = git ]; then
  # Pinned or not, only 01_fetch.sh's record ties the file to a commit. A SHA-256 says which bytes the file has,
  # not which commit they are: a pin left over from an earlier commit would pass that commit's file as the one
  # the profile names now. So the record must name this file and the address, commit, directory and prefix the
  # profile names now.
  rec=""; [ -f "$RH_TARBALL.from" ] && IFS= read -r rec < "$RH_TARBALL.from"
  [ "$rec" = "$(source_record "$sha")" ] || die "$RH_TARBALL is not known to be the archive of the address, commit, directory and prefix the profile names: $RH_TARBALL.from says '${rec:-nothing}', and the profile and the file give '$(source_record "$sha")'. Run 01_fetch.sh, which writes both again."
  log "01_fetch.sh's record says it wrote this file from commit $TGT_GIT_COMMIT${TGT_GIT_SUBDIR:+, directory $TGT_GIT_SUBDIR} of $TGT_GIT_URL"
fi

# Is there a complete extraction already? (All three project files and every source file.)
extracted=0
if [ -d "$EXTRACT" ]; then
  if [ -f "$RH_PROJ/lakefile.toml" ] && [ -f "$RH_PROJ/lake-manifest.json" ] && [ -f "$RH_PROJ/lean-toolchain" ]; then
    extracted=1
  else
    die "$EXTRACT exists but does not contain the project files. Move it aside or delete it, then run this script again."
  fi
fi
# For any target but the default one, the file extract.from beside the tree names the archive it was
# extracted from, and a tree is used again only if that line is the one the archive here now and the profile
# give. The whole line is compared: the SHA-256 and, for a git source, the address, commit, directory and
# prefix. (For the default target nothing is written or required, as before there were targets: its archive
# has one SHA-256.)
FROM_FILE="$RH_WORKDIR/extract.from"
if [ "$extracted" -eq 1 ] && [ "$RH_TARGET_IS_DEFAULT" = 0 ]; then
  from=""; [ -f "$FROM_FILE" ] && IFS= read -r from < "$FROM_FILE"
  [ "$from" = "$(source_record "$sha")" ] || die "the tree in $EXTRACT is not recorded as extracted from the archive in $RH_DL now and the source the profile names: $FROM_FILE says '${from:-nothing}', and the archive with the profile gives '$(source_record "$sha")'. Any difference counts, even one that leaves the archive the same byte for byte (another address for the same repository, or a commit that changes nothing in the directory). Move $EXTRACT aside, or delete it, and run this script again to extract this archive."
fi

# tar_inspect <arguments>: run tar-inspect on the tarball with what the target's profile says about
# the archive (its top directory, where the sources are, whether executable bits are accepted). What
# is the tool's default (lean/, src, no executable bits) is not passed, so that for the default target
# the command is the one it was before there were targets.
tar_inspect() {
  set -- tar-inspect "$RH_TARBALL" "$@"
  [ "$TGT_ARCHIVE_PREFIX" = lean/ ] || set -- "$@" --prefix "$TGT_ARCHIVE_PREFIX"
  [ "$TGT_SRC_DIR" = src ] || set -- "$@" --src-dir "$TGT_SRC_DIR"
  [ "$TGT_ARCHIVE_ALLOW_EXEC" = 1 ] && set -- "$@" --allow-exec
  python3 -I -B "$RH_TOOLS" "$@"
}

# The record is written by the tool; it does not create the directory for it.
if [ -n "$WRITE_EXPECTED" ]; then
  wdir=$(dirname "$WRITE_EXPECTED")
  if [ ! -d "$wdir" ]; then
    mkdir -p "$wdir" || die "cannot create $wdir (the directory of the file given to --write-expected)"
    log "created $wdir (the directory of the file given to --write-expected)"
  fi
fi

# 2. Listing and entry checks (and, on request, the byte-for-byte tree comparison).
set -- --sha256 "$sha" --expected "$RH_EXPECTED"
if [ "$VERIFY_TREE" -eq 1 ]; then
  if [ "$extracted" -eq 1 ]; then set -- "$@" --verify-tree "$EXTRACT"
  else log "--verify-tree: nothing is extracted yet; it will be done after extraction"; fi
fi
[ -n "$WRITE_EXPECTED" ] && set -- "$@" --write-expected "$WRITE_EXPECTED"
log "listing the tarball (nothing is extracted in this step)"
tar_inspect "$@" || die "the tarball listing did not pass; nothing was extracted"

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
  # A gzipped file starts with the bytes 1f 8b and is read with -z. Anything else is read as a
  # plain tar, which is what 01_fetch.sh writes for a git source: GNU tar refuses -z on one.
  # That tar file gives every entry the time 0, so for a git source -m leaves the extracted
  # files with the time of extraction instead of 1970.
  tarflags=x
  [ "$TGT_SOURCE_KIND" = git ] && tarflags=${tarflags}m
  [ "$(od -An -tx1 -N2 "$RH_TARBALL" | tr -d ' \t\n')" = 1f8b ] && tarflags=${tarflags}z
  tar "-${tarflags}f" "$RH_TARBALL" -C "$EXTRACT.partial" || die "tar failed; the incomplete tree is in $EXTRACT.partial"
  # For any target but the default one, what tar wrote is compared with the listing before the tree is put in
  # place: two programs that read one archive need not agree on what is in it. Everything in the tree, .lake
  # included, must be an entry the listing checked, with no links and no other files. (The default target's
  # archive is pinned, and its listing is recorded, so this is not done for it, as before there were targets.)
  if [ "$RH_TARGET_IS_DEFAULT" = 0 ]; then
    tar_inspect --quiet --check-extracted "$EXTRACT.partial" \
      || die "what tar extracted is not what the listing showed; it was not put in place and is in $EXTRACT.partial (nothing in it has been run)"
  fi
  # The record is written first: a tree that is in place always has one.
  [ "$RH_TARGET_IS_DEFAULT" = 1 ] || source_record "$sha" > "$FROM_FILE" || die "could not write $FROM_FILE"
  mv "$EXTRACT.partial" "$EXTRACT" || die "could not move $EXTRACT.partial into place"
  extracted=1
  log "extracted $(count_sources) Lean source files"
  if [ "$VERIFY_TREE" -eq 1 ]; then
    tar_inspect --quiet --verify-tree "$EXTRACT" || die "the extracted tree does not match the tarball"
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
