#!/bin/bash
# 01_fetch.sh - download the proof source and verify its SHA-256.
#
# What it does: one of two things, according to how the target publishes its source
#   (TGT_SOURCE_KIND in the target's profile; see targets/README.md).
#   tarball-parts (the default target): downloads the RH_PART_COUNT parts of the tarball from
#   RH_PART_URL_PREFIX, computes the SHA-256 of each part, compares the parts with the target's
#   recorded parts.sha256 (records/source/parts.sha256 for the default target) when that file
#   exists, concatenates them, and checks the result against RH_TARBALL_SHA256. Parts that are
#   already present and correct are not downloaded again. The default target's server ignores
#   HTTP Range requests, so a part cannot be resumed: a failed part is downloaded again whole.
#   git: clones the repository TGT_GIT_URL into RH_WORKDIR/download/repo.git without checking
#   anything out (a clone that is already there is used as it is), confirms that TGT_GIT_COMMIT
#   is a commit in it, and has "rhv_tools.py git-export" write the files of that commit (of
#   TGT_GIT_SUBDIR in it, if that is set) to an uncompressed tar file. The file is written again
#   on every run; the same commit gives the same bytes. Its SHA-256 is compared with
#   TGT_TARBALL_SHA256. If that is empty there is nothing to compare with: the script says in
#   capitals that the value is NOT PINNED and prints the line to add to the profile.
# What it changes on disk: tarball-parts: writes the parts, the tarball, parts.sha256 and
#   <tarball name>.sha256 (lean.tar.gz.sha256 for the default target) into RH_WORKDIR/download.
#   git: writes the clone, the tar file, <tar file name>.from and, unless the file's SHA-256
#   differs from the pinned one, <tar file name>.sha256 into RH_WORKDIR/download. The .from file
#   names the address, commit, directory and prefix the file was written from;
#   02_inspect_and_extract.sh requires it, pinned or not. The clone records the address it was
#   made from (git config rhv.sourceurl), and a clone made from another address than the
#   profile's is not used. Only repositories that name their objects by SHA-1 are supported.
#   Both append to RH_WORKDIR/logs/download.log and, if RH_WORKDIR has no .rh-target file yet,
#   write the target's name to it. Nothing else. With --check-only it writes nothing at all.
# How long it takes: default target: about 240 MB of download (seconds to minutes) plus a few
#   seconds of hashing. git: one clone of the repository with its whole history, then one pass
#   over the files of the commit; not yet measured on a real repository.
#
# Usage: scripts/01_fetch.sh [--check-only] [--redownload]
#   --check-only  verify what is already on disk; download nothing, change nothing
#   --redownload  discard the parts on disk and download all of them again (git: discard the
#                 clone, the tar file and its .sha256 file, then clone and write again)
# Exit status: 0 if the tarball is present and has the expected SHA-256, 1 otherwise. For a git
#   source with no SHA-256 pinned: 0 if the tar file was written. For a git source with
#   --check-only, pinned or not, the tar file must also be present with a .from file that names
#   it and what the profile names, and the clone, if there is one, must hold the commit and have
#   been made from the profile's address.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"
. "$HERE/common.sh"

CHECK_ONLY=0; REDOWNLOAD=0
for arg in "$@"; do
  case "$arg" in
    --check-only) CHECK_ONLY=1 ;;
    --redownload) REDOWNLOAD=1 ;;
    -h|--help) show_help; exit 0 ;;
    *) die "unknown argument: $arg (try --help)" ;;
  esac
done
DLLOG="$RH_LOGS/download.log"

# ---------------------------------------------------------------------------- a git source
# is_lower_hex <string> <length>: true if the string is that many characters, all of 0-9 a-f.
is_lower_hex() {
  case "$1" in ''|*[!0-9a-f]*) return 1 ;; esac
  [ "${#1}" -eq "$2" ]
}

# True if the clone holds TGT_GIT_COMMIT and that id is the commit itself. (The id of an
# annotated tag resolves to another id, that of the commit the tag points at, and is refused.)
git_clone_has_commit() {
  local got
  got=$(git --git-dir="$RH_GIT_DIR" rev-parse --verify --quiet "$TGT_GIT_COMMIT^{commit}" 2>/dev/null) || return 1
  [ "$got" = "$TGT_GIT_COMMIT" ]
}

# The address the clone was made from, as this script recorded it when it made the clone. (git's own
# remote.origin.url is not used: git rewrites a relative path there.)
git_clone_url() {
  git --git-dir="$RH_GIT_DIR" config --get rhv.sourceurl 2>/dev/null
}

# The kind of object names the clone uses, if it is not git's usual SHA-1: git-export checks every object it
# reads against its SHA-1 name, so a repository that names its objects by SHA-256 is not supported.
git_clone_odd_format() {
  local f
  f=$(git --git-dir="$RH_GIT_DIR" config --get extensions.objectFormat 2>/dev/null) || return 1
  [ -n "$f" ] && [ "$f" != sha1 ] && printf '%s' "$f"
}

# not_pinned_notice <sha256>: what to say when there is no recorded SHA-256 to compare with.
not_pinned_notice() {
  echo "THE SHA-256 OF THIS ARCHIVE IS NOT PINNED: TGT_TARBALL_SHA256 is empty for the target $RH_TARGET,"
  echo "so there was nothing to compare it with. Until it is pinned, the archive is identified by"
  echo "its commit only. To pin it, add this line to $REPO_ROOT/targets/$RH_TARGET/target.env"
  echo "TGT_TARBALL_SHA256=$1"
}

fetch_git_source() {
  local bad h t err rc out last rec
  need_cmd git
  need_cmd python3
  [ -n "$TGT_GIT_URL" ] || die "TGT_GIT_URL is empty: a git source needs the address of the repository"
  is_lower_hex "$TGT_GIT_COMMIT" 40 \
    || die "TGT_GIT_COMMIT must be a commit id written out as 40 hexadecimal characters in lower case; a branch or tag name is refused (it is '$TGT_GIT_COMMIT')"
  if [ -n "$RH_TARBALL_SHA256" ]; then
    is_lower_hex "$RH_TARBALL_SHA256" 64 \
      || die "TGT_TARBALL_SHA256 must be empty or a SHA-256 as sha256sum prints it, 64 hexadecimal characters in lower case (it is '$RH_TARBALL_SHA256')"
  fi
  case "$RH_GIT_DIR" in "$RH_DL"/?*) ;; *) die "RH_GIT_DIR ($RH_GIT_DIR) is not inside $RH_DL" ;; esac
  # Read the clone and no other repository, and read its objects as they are stored: a git
  # variable left in the environment (by a hook, say) must not point git somewhere else.
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_NAMESPACE
  unset GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES
  GIT_NO_REPLACE_OBJECTS=1; export GIT_NO_REPLACE_OBJECTS
  # Do not stop to ask for a user name or password: a published source needs none. Set
  # GIT_TERMINAL_PROMPT=1 in the environment to be asked all the same.
  GIT_TERMINAL_PROMPT=${GIT_TERMINAL_PROMPT:-0}; export GIT_TERMINAL_PROMPT

  if [ "$CHECK_ONLY" -eq 1 ]; then
    echo "Checking $RH_DL (nothing will be changed)"
    echo "The source is commit $TGT_GIT_COMMIT of $TGT_GIT_URL${TGT_GIT_SUBDIR:+ (directory $TGT_GIT_SUBDIR)}"
    [ -n "$RH_TARBALL_SHA256" ] \
      || echo "No SHA-256 is pinned for it (TGT_TARBALL_SHA256 is empty): the archive is identified by its commit only"
    bad=0; h=""
    if [ ! -d "$RH_GIT_DIR" ]; then
      echo "clone:    not present ($RH_GIT_DIR)"
    elif [ -z "$(git_clone_url)" ]; then
      echo "clone:    DOES NOT RECORD THE ADDRESS IT WAS MADE FROM ($RH_GIT_DIR; --redownload makes a new clone)"; bad=$((bad + 1))
    elif [ "$(git_clone_url)" != "$TGT_GIT_URL" ]; then
      echo "clone:    NOT MADE FROM THE PROFILE'S ADDRESS ($RH_GIT_DIR records '$(git_clone_url)'; --redownload makes a new clone)"; bad=$((bad + 1))
    elif t=$(git_clone_odd_format); then
      echo "clone:    NAMES ITS OBJECTS BY $t, NOT SHA-1, WHICH IS NOT SUPPORTED ($RH_GIT_DIR)"; bad=$((bad + 1))
    elif git_clone_has_commit; then
      echo "clone:    holds the commit ($RH_GIT_DIR)"
    else
      echo "clone:    DOES NOT HOLD THE COMMIT ($RH_GIT_DIR)"; bad=$((bad + 1))
    fi
    if [ -f "$RH_TARBALL" ]; then
      h=$(sha256_of "$RH_TARBALL")
      if [ -z "$RH_TARBALL_SHA256" ]; then echo "archive:  $h  not pinned"
      elif [ "$h" = "$RH_TARBALL_SHA256" ]; then echo "archive:  $h  ok"
      else echo "archive:  $h  MISMATCH (expected $RH_TARBALL_SHA256)"; bad=$((bad + 1)); fi
    else
      echo "archive:  not present ($RH_TARBALL)"; bad=$((bad + 1))
    fi
    # Pinned or not: the SHA-256 says which bytes the file has, and only the record says which commit they are.
    if [ -n "$h" ]; then
      rec=""; [ -f "$RH_TARBALL.from" ] && IFS= read -r rec < "$RH_TARBALL.from"
      if [ "$rec" = "$(source_record "$h")" ]; then echo "record:   written from this address, commit, directory and prefix ($RH_TARBALL.from)"
      else echo "record:   DOES NOT NAME THIS FILE AND THIS PROFILE'S ADDRESS, COMMIT, DIRECTORY AND PREFIX ($RH_TARBALL.from says '${rec:-nothing}')"; bad=$((bad + 1)); fi
    fi
    if [ "$bad" -ne 0 ]; then
      echo "RESULT: $bad problem(s). Without --check-only this script clones the repository if there is no clone and writes the archive again."; exit 1
    fi
    if [ -n "$RH_TARBALL_SHA256" ]; then echo "RESULT: the archive on disk has the expected SHA-256."; exit 0; fi
    not_pinned_notice "$h"
    echo "(That is the SHA-256 of the file as it is on disk. A run without --check-only writes the"
    echo "file again from the clone before it prints the value.)"
    echo "RESULT: the archive is on disk; there is no pinned SHA-256 to compare it with."; exit 0
  fi

  ensure_dirs
  log "work directory: $RH_WORKDIR"
  if [ "$REDOWNLOAD" -eq 1 ]; then
    log "--redownload: removing the clone, the archive and its .sha256 file"
    rm -rf "$RH_GIT_DIR" "$RH_GIT_DIR.partial"
    rm -f "$RH_TARBALL" "$RH_TARBALL.tmp" "$RH_TARBALL.sha256" "$RH_TARBALL.from"
  fi

  # The clone. --bare: nothing is checked out, so nothing in the repository is run or filtered.
  # --no-local: a repository given as a local path is fetched like a remote one, so that git
  # computes the id of every object it receives. protocol.ext.allow=never: an address cannot
  # name a command to run.
  if [ -d "$RH_GIT_DIR" ]; then
    t=$(git_clone_url)
    [ "$t" = "$TGT_GIT_URL" ] || die "the clone in $RH_GIT_DIR was made from '${t:-an address it does not record}', and the profile names $TGT_GIT_URL. Run this script again with --redownload to clone from the profile's address."
    log "clone already present: $RH_GIT_DIR, made from $TGT_GIT_URL (not fetched again; --redownload discards it)"
  else
    if [ -e "$RH_GIT_DIR.partial" ]; then
      log "removing the incomplete clone left by an earlier run: $RH_GIT_DIR.partial"
      rm -rf "$RH_GIT_DIR.partial"
    fi
    log "cloning $TGT_GIT_URL into $RH_GIT_DIR (nothing is checked out)"
    err=$(git -c protocol.ext.allow=never clone --bare --quiet --no-local -- "$TGT_GIT_URL" "$RH_GIT_DIR.partial" 2>&1)
    rc=$?
    [ -n "$err" ] && printf '%s\n' "$err" >&2
    if [ "$rc" -ne 0 ]; then
      echo "$(date '+%Y-%m-%d %H:%M:%S') CLONE FAIL rc=$rc url=$TGT_GIT_URL" >> "$DLLOG"
      [ -n "$err" ] && printf '%s\n' "$err" >> "$DLLOG"
      rm -rf "$RH_GIT_DIR.partial"
      die "could not clone $TGT_GIT_URL (git status $rc); git's messages are above and in $DLLOG"
    fi
    git --git-dir="$RH_GIT_DIR.partial" config rhv.sourceurl "$TGT_GIT_URL" \
      || die "could not record in $RH_GIT_DIR.partial the address it was cloned from"
    mv "$RH_GIT_DIR.partial" "$RH_GIT_DIR" || die "could not move $RH_GIT_DIR.partial into place"
    echo "$(date '+%Y-%m-%d %H:%M:%S') CLONE OK url=$TGT_GIT_URL" >> "$DLLOG"
  fi
  if t=$(git_clone_odd_format); then
    die "the repository names its objects by $t, not by SHA-1 ($RH_GIT_DIR, extensions.objectFormat): this is not supported, because git-export checks every object it reads against its SHA-1 name"
  fi

  if ! git_clone_has_commit; then
    t=$(git --git-dir="$RH_GIT_DIR" cat-file -t "$TGT_GIT_COMMIT" 2>/dev/null) || t=""
    echo "$(date '+%Y-%m-%d %H:%M:%S') COMMIT FAIL commit=$TGT_GIT_COMMIT found=${t:-nothing}" >> "$DLLOG"
    case "$t" in
      '') die "commit $TGT_GIT_COMMIT is not in $RH_GIT_DIR. A clone holds what the branches and tags of the repository reach. If the clone was made before the commit was published, run this script again with --redownload." ;;
      commit) die "git could not read commit $TGT_GIT_COMMIT in $RH_GIT_DIR; the clone may be damaged (--redownload makes a new one)" ;;
      *) die "$TGT_GIT_COMMIT is a $t in $RH_GIT_DIR, not a commit; TGT_GIT_COMMIT must be the id of the commit itself" ;;
    esac
  fi
  log "the clone holds commit $TGT_GIT_COMMIT"

  # The tar file. git-export writes to <file>.tmp and renames it, so a failure leaves any file
  # from an earlier run as it was.
  set -- git-export --git-dir "$RH_GIT_DIR" --commit "$TGT_GIT_COMMIT"
  [ -n "$TGT_GIT_SUBDIR" ] && set -- "$@" --subdir="$TGT_GIT_SUBDIR"
  set -- "$@" --prefix "$TGT_ARCHIVE_PREFIX" --out "$RH_TARBALL"
  # The records of what the file was written from and of its SHA-256 go first, and come back only once the file
  # is written (the .sha256 file only if the SHA-256 is the pinned one, or none is pinned).
  rm -f "$RH_TARBALL.from" "$RH_TARBALL.sha256" || die "could not remove $RH_TARBALL.from or $RH_TARBALL.sha256"
  log "writing the files of that commit${TGT_GIT_SUBDIR:+ under $TGT_GIT_SUBDIR/} to $RH_TARBALL"
  out=$(python3 -I -B "$RH_TOOLS" "$@")
  rc=$?
  [ -n "$out" ] && printf '%s\n' "$out"
  if [ "$rc" -ne 0 ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') EXPORT FAIL rc=$rc commit=$TGT_GIT_COMMIT" >> "$DLLOG"
    die "the files of commit $TGT_GIT_COMMIT could not be written to a tar file (rhv_tools.py git-export, status $rc)"
  fi
  [ -f "$RH_TARBALL" ] || die "git-export reported success but $RH_TARBALL does not exist"
  h=$(sha256_of "$RH_TARBALL")
  last=$(printf '%s\n' "$out" | tail -n 1)
  case "$last" in
    "sha256 $h entries "*) ;;
    *) die "the file on disk has SHA-256 $h, which is not what git-export reported in its last line ('$last')" ;;
  esac
  # What the file was written from, whatever the comparison below finds: it is that commit's file.
  source_record "$h" > "$RH_TARBALL.from" || die "could not write $RH_TARBALL.from"

  if [ -z "$RH_TARBALL_SHA256" ]; then
    printf '%s  %s\n' "$h" "$(basename "$RH_TARBALL")" > "$RH_TARBALL.sha256"
    echo "$(date '+%Y-%m-%d %H:%M:%S') TARBALL NOT PINNED sha256=$h commit=$TGT_GIT_COMMIT" >> "$DLLOG"
    log "archive written: $RH_TARBALL"
    log "sha256 $h"
    not_pinned_notice "$h"
    exit 0
  fi
  if [ "$h" != "$RH_TARBALL_SHA256" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') TARBALL MISMATCH sha256=$h expected=$RH_TARBALL_SHA256 commit=$TGT_GIT_COMMIT" >> "$DLLOG"
    echo "The archive written from commit $TGT_GIT_COMMIT has SHA-256" >&2
    echo "  $h" >&2
    echo "but TGT_TARBALL_SHA256 for the target $RH_TARGET is" >&2
    echo "  $RH_TARBALL_SHA256" >&2
    echo "The same commit, subdirectory and prefix always give the same file, so one of them is not" >&2
    echo "what it was when that value was recorded, or the clone or the tool that writes the file" >&2
    echo "has changed since. The file just written is kept at $RH_TARBALL (no .sha256 file" >&2
    echo "was written for it, and any from an earlier run was removed), and the clone at $RH_GIT_DIR." >&2
    exit 1
  fi
  printf '%s  %s\n' "$h" "$(basename "$RH_TARBALL")" > "$RH_TARBALL.sha256"
  echo "$(date '+%Y-%m-%d %H:%M:%S') TARBALL OK sha256=$h commit=$TGT_GIT_COMMIT" >> "$DLLOG"
  log "archive verified: $RH_TARBALL"
  log "sha256 $h"
  exit 0
}

case "$TGT_SOURCE_KIND" in
  tarball-parts) ;;   # the rest of this file
  git) fetch_git_source; exit 1 ;;   # not reached: fetch_git_source always exits
  *) die "TGT_SOURCE_KIND is '$TGT_SOURCE_KIND'; this script knows tarball-parts and git" ;;
esac

# ---------------------------------------------------------------------------- a tarball in parts
case "$RH_PART_COUNT" in ''|*[!0-9]*|0) die "RH_PART_COUNT must be a positive number" ;; esac

part_name() { printf '%s%02d' "$RH_PART_BASENAME" "$1"; }
part_url()  { printf '%s%02d' "$RH_PART_URL_PREFIX" "$1"; }
recorded_sha() {  # recorded_sha <part file name>: the recorded hash, or nothing
  [ -f "$RH_PARTS_RECORD" ] || return 0
  awk -v f="$1" '$1 !~ /^#/ && ($2 == f || $2 == "*" f) { print $1; exit }' "$RH_PARTS_RECORD"
}

# ---------------------------------------------------------------------------- check only
if [ "$CHECK_ONLY" -eq 1 ]; then
  echo "Checking $RH_DL (nothing will be changed)"
  [ -f "$RH_PARTS_RECORD" ] && echo "Part hashes are compared with $RH_PARTS_RECORD" \
                            || echo "No recorded part hashes ($RH_PARTS_RECORD does not exist); parts are only listed"
  bad=0; present=0; i=1
  while [ "$i" -le "$RH_PART_COUNT" ]; do
    n=$(part_name "$i"); f="$RH_DL/$n"
    if [ -f "$f" ]; then
      present=$((present + 1)); h=$(sha256_of "$f"); r=$(recorded_sha "$n")
      if [ -z "$r" ]; then st="not recorded"
      elif [ "$h" = "$r" ]; then st="ok"
      else st="MISMATCH (recorded $r)"; bad=$((bad + 1)); fi
      printf '%s  %s  %s\n' "$h" "$n" "$st"
    else
      printf '%-64s  %s  %s\n' "-" "$n" "not present"
    fi
    i=$((i + 1))
  done
  if [ "$present" -eq "$RH_PART_COUNT" ]; then
    h=$(i=1; while [ "$i" -le "$RH_PART_COUNT" ]; do cat "$RH_DL/$(part_name "$i")"; i=$((i + 1)); done | sha256_stdin)
    if [ "$h" = "$RH_TARBALL_SHA256" ]; then echo "parts concatenated:  $h  ok"
    else echo "parts concatenated:  $h  MISMATCH (expected $RH_TARBALL_SHA256)"; bad=$((bad + 1)); fi
  else
    echo "parts concatenated:  not checked ($present of $RH_PART_COUNT parts present)"
  fi
  if [ -f "$RH_TARBALL" ]; then
    h=$(sha256_of "$RH_TARBALL")
    if [ "$h" = "$RH_TARBALL_SHA256" ]; then echo "tarball:             $h  ok"
    else echo "tarball:             $h  MISMATCH (expected $RH_TARBALL_SHA256)"; bad=$((bad + 1)); fi
  else
    echo "tarball:             not present"; bad=$((bad + 1))
  fi
  if [ "$bad" -eq 0 ]; then echo "RESULT: the tarball on disk has the expected SHA-256."; exit 0; fi
  echo "RESULT: $bad problem(s). Run this script without --check-only to download."; exit 1
fi

# ---------------------------------------------------------------------------- download
need_cmd curl
ensure_dirs
log "work directory: $RH_WORKDIR"

if [ -f "$RH_TARBALL" ] && [ "$REDOWNLOAD" -eq 0 ]; then
  h=$(sha256_of "$RH_TARBALL")
  if [ "$h" = "$RH_TARBALL_SHA256" ]; then
    log "tarball already present with the expected SHA-256; nothing to do"
    exit 0
  fi
  log "existing tarball has SHA-256 $h, not the expected one; rebuilding it from the parts"
fi

# Download one part to <file>.tmp and move it into place only after a complete HTTP 200 reply.
fetch_part() {  # fetch_part <index>
  local n f url attempt res rc code h r
  n=$(part_name "$1"); f="$RH_DL/$n"; url=$(part_url "$1"); r=$(recorded_sha "$n")
  attempt=1
  while [ "$attempt" -le 5 ]; do
    res=$(curl -sS -L -A "curl" --connect-timeout 30 --speed-limit 1024 --speed-time 120 \
            -o "$f.tmp" -w '%{http_code} %{size_download} %{time_total}' "$url" 2>>"$DLLOG")
    rc=$?
    code=${res%% *}
    if [ "$rc" -eq 0 ] && [ "$code" = "200" ]; then
      h=$(sha256_of "$f.tmp")
      if [ -n "$r" ] && [ "$h" != "$r" ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') $n BADHASH attempt=$attempt $res sha256=$h recorded=$r" >> "$DLLOG"
        log "$n: downloaded but the SHA-256 does not match the record (attempt $attempt)"
      else
        mv "$f.tmp" "$f"
        echo "$(date '+%Y-%m-%d %H:%M:%S') $n OK attempt=$attempt $res sha256=$h" >> "$DLLOG"
        log "$n: downloaded ($res) sha256=$h"
        return 0
      fi
    else
      echo "$(date '+%Y-%m-%d %H:%M:%S') $n FAIL attempt=$attempt rc=$rc $res" >> "$DLLOG"
      log "$n: download failed (curl status $rc, HTTP ${code:-none}), attempt $attempt of 5"
    fi
    rm -f "$f.tmp"
    sleep $((attempt * 5))
    attempt=$((attempt + 1))
  done
  return 1
}

failed=0; i=1
while [ "$i" -le "$RH_PART_COUNT" ]; do
  n=$(part_name "$i"); f="$RH_DL/$n"; r=$(recorded_sha "$n")
  [ "$REDOWNLOAD" -eq 1 ] && rm -f "$f"
  if [ -f "$f" ]; then
    h=$(sha256_of "$f")
    if [ -z "$r" ]; then
      log "$n: present (no recorded hash for it; the tarball hash below covers it)"
    elif [ "$h" = "$r" ]; then
      log "$n: present and matches the record"
    else
      log "$n: present but does not match the record; downloading it again"
      rm -f "$f"
      fetch_part "$i" || failed=$((failed + 1))
    fi
  else
    fetch_part "$i" || failed=$((failed + 1))
  fi
  i=$((i + 1))
done
[ "$failed" -eq 0 ] || die "$failed part(s) could not be downloaded; see $DLLOG and run this script again"

# Record each part's hash, then assemble and verify.
: > "$RH_DL/parts.sha256.tmp"
i=1
while [ "$i" -le "$RH_PART_COUNT" ]; do
  n=$(part_name "$i")
  printf '%s  %s\n' "$(sha256_of "$RH_DL/$n")" "$n" >> "$RH_DL/parts.sha256.tmp"
  i=$((i + 1))
done
mv "$RH_DL/parts.sha256.tmp" "$RH_DL/parts.sha256"

log "concatenating $RH_PART_COUNT parts"
: > "$RH_TARBALL.tmp"
i=1
while [ "$i" -le "$RH_PART_COUNT" ]; do
  cat "$RH_DL/$(part_name "$i")" >> "$RH_TARBALL.tmp" || die "could not append part $i"
  i=$((i + 1))
done
h=$(sha256_of "$RH_TARBALL.tmp")
if [ "$h" != "$RH_TARBALL_SHA256" ]; then
  rm -f "$RH_TARBALL.tmp"
  echo "$(date '+%Y-%m-%d %H:%M:%S') TARBALL MISMATCH sha256=$h expected=$RH_TARBALL_SHA256" >> "$DLLOG"
  echo "The assembled tarball has SHA-256" >&2
  echo "  $h" >&2
  echo "but this repository's records refer to" >&2
  echo "  $RH_TARBALL_SHA256" >&2
  echo "Either a part was corrupted in transit (run again with --redownload), or the published" >&2
  echo "files have changed since the records were made. In the second case the records in this" >&2
  echo "repository do not describe what you downloaded. Part hashes are in $RH_DL/parts.sha256." >&2
  exit 1
fi
mv "$RH_TARBALL.tmp" "$RH_TARBALL"
printf '%s  %s\n' "$h" "$(basename "$RH_TARBALL")" > "$RH_TARBALL.sha256"
echo "$(date '+%Y-%m-%d %H:%M:%S') TARBALL OK sha256=$h" >> "$DLLOG"
log "tarball verified: $RH_TARBALL"
log "sha256 $h"
exit 0
