#!/bin/bash
# prune_setup_files.sh - optional: reclaim disk space from a build, running or finished.
#
# What it does: for every module it compiles, Lake writes a file <module>.setup.json under
#   RH_PROJ/.lake/build/ir. The file lists every compiled file the module imports. It is 5.4 to
#   6.4 MB for a module that imports only Mathlib, depending on how long the paths are, and grows
#   with the module's imports: 1.1 to 1.3 TB for the whole tree, against about 0.13 TB of compiled
#   output. The file is read while its module is being built (by the compiler when it starts, and
#   by Lake's code generator where that runs as a separate step) and not after the module's .trace
#   file has been written. Lake decides what is up to date from the .trace and .hash files beside
#   the compiled output, not from the setup file.
#
#   This script finds the setup file of each module that has finished compiling and reports how
#   much space they take. With --delete it removes them. A module counts as finished when its
#   .trace file exists, its .olean file exists, and the .trace file is newer than the setup file
#   (Lake writes the setup file first and the .trace file last). Setup files younger than
#   --min-age minutes are left alone whatever their state.
#
#   Tested on 2026-11-20 with Lake 5.0.0 (Lean 4.33.1) on a five-module project: after deleting
#   the setup files, a second `lake build` recompiled nothing and left the compiled files
#   byte-for-byte unchanged, modules that import the pruned ones compiled normally, and
#   leanchecker passed on all of them. On the real tree, on Linux, two cloud rehearsals then
#   deleted the setup files of 641 and 644 finished modules and restarted the build: none was
#   recompiled (records/cloud/full-rehearsals/). It had not been run with --delete on a Mac when
#   this was written; the first time you do, check that the next `lake build` prints no "Built"
#   line for a module that was already compiled.
# What it changes on disk: nothing without --delete. With --delete, it removes files named
#   *.setup.json under RH_PROJ/.lake/build/ir and nothing else. They are build products, not
#   part of the proof source, and Lake writes a new one whenever it compiles a module.
# How long it takes: under a minute for a few thousand modules; several minutes for the whole tree.
#
# Usage: scripts/prune_setup_files.sh [--delete] [--min-age MINUTES] [--project DIR]
#   --delete           remove the files (default: report only)
#   --min-age MINUTES  leave setup files younger than this alone (default 5)
#   --project DIR      a Lake project directory other than RH_PROJ (for testing)
# Exit status: 0; 1 on a usage error or if a file could not be removed.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"
. "$HERE/common.sh"

DELETE=0; MIN_AGE=5; PROJ="$RH_PROJ"
while [ $# -gt 0 ]; do
  case "$1" in
    --delete) DELETE=1 ;;
    --min-age) shift; MIN_AGE="${1:-}" ;;
    --project) shift; PROJ="${1:-}" ;;
    -h|--help) show_help; exit 0 ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
  shift
done
case "$MIN_AGE" in ''|*[!0-9]*) die "--min-age needs a whole number of minutes" ;; esac
[ -f "$PROJ/lakefile.toml" ] || [ -f "$PROJ/lakefile.lean" ] || die "no Lake project at $PROJ"
IR="$PROJ/.lake/build/ir"; LIB="$PROJ/.lake/build/lib/lean"
[ -d "$IR" ] || die "nothing has been built here yet ($IR does not exist)"
need_cmd python3

python3 -I - "$IR" "$LIB" "$DELETE" "$MIN_AGE" <<'EOF'
import os, sys, time
ir, lib, delete, min_age = sys.argv[1], sys.argv[2], sys.argv[3] == '1', int(sys.argv[4]) * 60
now = time.time()
SUFFIX = '.setup.json'
seen = finished = removed = failed = 0
seen_bytes = finished_bytes = 0
for root, dirs, files in os.walk(ir):
    for f in files:
        if not f.endswith(SUFFIX): continue
        p = os.path.join(root, f)
        try: s = os.lstat(p)
        except OSError: continue
        seen += 1; seen_bytes += s.st_size
        stem = os.path.join(lib, os.path.relpath(p, ir)[:-len(SUFFIX)])
        try: t = os.stat(stem + '.trace'); os.stat(stem + '.olean')
        except OSError: continue                       # not finished, or never built
        if t.st_mtime <= s.st_mtime or now - s.st_mtime < min_age: continue
        finished += 1; finished_bytes += s.st_size
        if delete:
            try: os.unlink(p); removed += 1
            except OSError as e: failed += 1; print('could not remove %s: %s' % (p, e), file=sys.stderr)
gb = lambda b: '%.1f GB' % (b / 1e9)
print('setup files found:            %d (%s)' % (seen, gb(seen_bytes)))
print('of finished modules:          %d (%s)' % (finished, gb(finished_bytes)))
if delete: print('removed:                      %d' % removed)
else: print('nothing was removed; run again with --delete to remove the files of finished modules')
sys.exit(1 if failed else 0)
EOF
