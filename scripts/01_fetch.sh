#!/bin/bash
# 01_fetch.sh - download the proof source and verify its SHA-256.
#
# What it does: downloads the RH_PART_COUNT parts of the tarball from RH_PART_URL_PREFIX,
#   computes the SHA-256 of each part, compares the parts with records/source/parts.sha256
#   when that file exists, concatenates them, and checks the result against RH_TARBALL_SHA256.
#   Parts that are already present and correct are not downloaded again. The server ignores
#   HTTP Range requests, so a part cannot be resumed: a failed part is downloaded again whole.
# What it changes on disk: writes the parts, the tarball, parts.sha256 and lean.tar.gz.sha256
#   into RH_WORKDIR/download and appends to RH_WORKDIR/logs/download.log. Nothing else.
#   With --check-only it writes nothing at all.
# How long it takes: about 240 MB of download (seconds to minutes) plus a few seconds of hashing.
#
# Usage: scripts/01_fetch.sh [--check-only] [--redownload]
#   --check-only  verify what is already on disk; download nothing, change nothing
#   --redownload  discard the parts on disk and download all of them again
# Exit status: 0 if the tarball is present and has the expected SHA-256, 1 otherwise.
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
case "$RH_PART_COUNT" in ''|*[!0-9]*|0) die "RH_PART_COUNT must be a positive number" ;; esac

DLLOG="$RH_LOGS/download.log"
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
