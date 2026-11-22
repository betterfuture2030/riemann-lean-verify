#!/bin/bash
# test_spot_checkpoint.sh - tests of scripts/spot_checkpoint.sh, the archives of compiled modules a Spot run saves.
#
# What it does: runs on a Mac or on Linux with no network. Always: bash -n on the scripts a Spot run uses (and
#   shellcheck on them if it is installed, as information only); the selection rules of `cut` on a made-up build
#   directory (saved files, settle margin, half-written and setup files, an incomplete module, a damaged trace, a
#   symbolic link, a saved output written again or gone, one written again with the same bytes, one changed within
#   the settle margin (left for a later round; strict without the margin), a .hash file written again, --all,
#   --paths-from, --dry-run, an archive on the standard output); the done and members files that cut, list and
#   restore write (the done lines with their SHA-256), and that they agree; `restore` refusing a bad checksum, an
#   absolute path, a ".." member, a link member, a path outside lib/ and ir/, and a planted link in the build
#   directory; `cover` (equal, missing, different, extra, not a file, a repair part read last); `trim` (and its
#   refusal of a symbolic link); the state file (quoting, progress that never goes down). If the v4.33.1 toolchain
#   is installed (elan) and zstd is available: on a toy Lake project (Toy.A; Toy.W with a `sorry` warning and an
#   #eval; Toy.B; Toy.F, which fails to compile; and the root Toy), builds the four modules (Toy.F failing), cuts,
#   wipes the build directory, restores it into a clean tree, touches every source and lean-toolchain, builds
#   again (Toy.F failing again), and shows that no restored module is compiled again while the root is, that the
#   restored files are byte for byte what was saved and that the build gives none of them a new time, size or
#   bytes (it also prints, as INFO, these counts by kind of file), that a cut with the restored done list after
#   that build saves only the root (not status 4), that modification times do not matter to the build tool, that
#   a .hash file the build tool writes again is saved again, and that a module compiled again is noticed.
# What it changes on disk: only a temporary directory of its own, removed at the end.
# Usage: scripts/dev/test_spot_checkpoint.sh      Prints PASS or FAIL per case.
# Exit status: 0 if every case passed, 1 otherwise.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/../.." && pwd)"
SPK="$ROOT/scripts/spot_checkpoint.sh"
TMPD=$(mktemp -d "${TMPDIR:-/tmp}/spotck.XXXXXX") || exit 1
trap 'rm -rf "${TMPD:?}"' EXIT
FAILS=0; N=0
pass() { N=$((N + 1)); echo "PASS  $1"; }
fail() { N=$((N + 1)); FAILS=$((FAILS + 1)); echo "FAIL  $1${2:+: $2}"; }
check() { if eval "$2"; then pass "$1"; else fail "$1" "${3:-}"; fi; }   # check <name> <shell test> [detail]
sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }
mtime() { if stat -c %Y "$1" >/dev/null 2>&1; then stat -c %Y "$1"; else stat -f %m "$1"; fi; }
modeof() { if stat -c %a "$1" >/dev/null 2>&1; then stat -c %a "$1"; else stat -f %Lp "$1"; fi; }
fsize() { if stat -c %s "$1" >/dev/null 2>&1; then stat -c %s "$1"; else stat -f %z "$1"; fi; }
dline() { printf '%s\t%s\t%s\t%s\n' "$2" "$(fsize "$1/$2")" "$(mtime "$1/$2")" "$(sha "$1/$2")"; }   # dline <build dir> <path>: a done-file line
setmt() { python3 -I -c 'import os,sys
for p in sys.argv[2:]: os.utime(p, (int(sys.argv[1]), int(sys.argv[1])))' "$@"; }    # setmt <epoch> <file>...
# the guest's fingerprint of lib/lean (lib_manifest): "<sha256>  ./<path>", sorted by path
libman() { ( cd "$1" && find . -type f | LC_ALL=C sort | while read -r f; do echo "$(sha "$f")  $f"; done ); }
# a tar member list, read with the system's tar (GNU or BSD)
members() { zstd -q -d -c "$1" | tar -tf - | LC_ALL=C sort; }
HAVE_ZSTD=0; command -v zstd >/dev/null 2>&1 && HAVE_ZSTD=1

# ---------------------------------------------------------------- syntax
for f in "$ROOT/cloud/gcp/full_guest.sh" "$SPK" "$0"; do
  check "bash -n $(basename "$f")" "bash -n '$f' 2>'$TMPD/n.err'" "$(cat "$TMPD/n.err" 2>/dev/null)"
done
if command -v shellcheck >/dev/null 2>&1; then
  for f in "$ROOT/cloud/gcp/full_guest.sh" "$SPK"; do
    echo "INFO  shellcheck $(basename "$f"): $(shellcheck -S warning "$f" 2>&1 | grep -c '^In ') warnings (not counted)"
  done
fi
if [ "$HAVE_ZSTD" = 0 ]; then echo "SKIP  everything else: zstd is not installed"; echo "$N cases, $FAILS failed"; [ "$FAILS" = 0 ]; exit; fi

# ---------------------------------------------------------------- cut: selection
# A made-up build directory. A, B, C complete; C already saved; B's trace too new for the settle margin; D's trace
# does not parse; E has a half-written leftover beside it; F lacks its C file; Z is an .olean with no trace.
B="$TMPD/b1/build"; mkdir -p "$B/lib/lean/P" "$B/ir/P"
mkmod() { # mkmod <stem> [trace text]
  local s=$1 t=${2:-'{"depHash": "1", "outputs": {}}'} e
  for e in olean olean.hash ilean ilean.hash; do echo "$s $e" > "$B/lib/lean/$s.$e"; done
  for e in c c.hash setup.json; do echo "$s $e" > "$B/ir/$s.$e"; done
  printf '%s' "$t" > "$B/lib/lean/$s.trace"
}
for m in P/A P/B P/C P/D P/E P/F; do mkmod "$m"; done
printf 'not json' > "$B/lib/lean/P/D.trace"
echo half > "$B/lib/lean/P/E.olean.tmp.4242"
rm -f "$B/ir/P/F.c"
echo orphan > "$B/lib/lean/P/Z.olean"; echo half > "$B/lib/lean/P/Z.olean.tmp.7"
OLD=$(( $(date +%s) - 100 ))
setmt "$OLD" $(find "$B" -type f ! -name 'B.trace')
# P.C is saved already: its files, each with its size and time, as the done file holds them
{ for e in olean olean.hash ilean ilean.hash trace; do dline "$B" "lib/lean/P/C.$e"; done; dline "$B" ir/P/C.c; dline "$B" ir/P/C.c.hash; } > "$TMPD/done1"
SETTLE=$(( $(date +%s) - 5 ))
bash "$SPK" cut --build-dir "$B" --done "$TMPD/done1" --out "$TMPD/p1.tar.zst" --list "$TMPD/l1" --settle-before "$SETTLE" \
  --done-out "$TMPD/d1" --members-out "$TMPD/m1.gz" 2>"$TMPD/e1"; rc=$?
check "cut: makes a part" "[ $rc = 0 ] && [ -s '$TMPD/p1.tar.zst' ]" "status $rc: $(cat "$TMPD/e1")"
check "cut: lists only the complete, settled, unsaved modules" "[ \"\$(tr '\n' ' ' < '$TMPD/l1')\" = 'P.A P.E ' ]" "$(tr '\n' ' ' < "$TMPD/l1")"
members "$TMPD/p1.tar.zst" > "$TMPD/t1"
want="ir/P/A.c ir/P/A.c.hash ir/P/E.c ir/P/E.c.hash lib/lean/P/A.ilean lib/lean/P/A.ilean.hash lib/lean/P/A.olean lib/lean/P/A.olean.hash lib/lean/P/A.trace lib/lean/P/E.ilean lib/lean/P/E.ilean.hash lib/lean/P/E.olean lib/lean/P/E.olean.hash lib/lean/P/E.trace "
check "cut: takes every file Lake needs, and no setup or half-written file" "[ \"\$(tr '\n' ' ' < '$TMPD/t1')\" = '$want' ]" "$(tr '\n' ' ' < "$TMPD/t1")"
for f in $want; do dline "$B" "$f"; done > "$TMPD/d1.want"
check "cut: its done lines name exactly the files archived, with their size and time" "LC_ALL=C sort '$TMPD/d1' | cmp -s - '$TMPD/d1.want'" "$(LC_ALL=C sort "$TMPD/d1" | diff - "$TMPD/d1.want" | head -3)"
gzip -dc "$TMPD/m1.gz" | while read -r h f; do [ "$(sha "$B/$f")" = "$h" ] || echo "$f"; done > "$TMPD/m1.bad"
check "cut: its members file holds the SHA-256 of each archived file (gzip-compressed)" "[ \$(gzip -dc '$TMPD/m1.gz' | wc -l) -eq 14 ] && [ ! -s '$TMPD/m1.bad' ]" "$(cat "$TMPD/m1.bad")"
check "list: reads the modules back from the part" "[ \"\$(bash '$SPK' list --part '$TMPD/p1.tar.zst' | tr '\n' ' ')\" = 'P.A P.E ' ]"
bash "$SPK" list --part "$TMPD/p1.tar.zst" --members-out "$TMPD/lm1" --done-out "$TMPD/ld1" 2>"$TMPD/e"; rc=$?
check "list: its members and done files are the cut's own" "[ $rc = 0 ] && gzip -dc '$TMPD/m1.gz' | cmp -s - '$TMPD/lm1' && cmp -s '$TMPD/d1' '$TMPD/ld1'" "status $rc $(cat "$TMPD/e")"
bash "$SPK" cut --build-dir "$B" --done "$TMPD/done1" --out "$TMPD/p1b.tar.zst" --settle-before "$OLD" 2>/dev/null; rc=$?
check "cut: nothing due when every trace is newer than the margin (status 3)" "[ $rc = 3 ] && [ ! -e '$TMPD/p1b.tar.zst' ]" "status $rc"
# --all: everything left, with no margin: B now, but nothing of D and F (not complete) or of the orphan Z.olean
cat "$TMPD/done1" "$TMPD/d1" > "$TMPD/done2"
bash "$SPK" cut --build-dir "$B" --done "$TMPD/done2" --out "$TMPD/p2.tar.zst" --list "$TMPD/l2" --done-out "$TMPD/d2" --all 2>"$TMPD/e2"; rc=$?
want2="ir/P/B.c ir/P/B.c.hash lib/lean/P/B.ilean lib/lean/P/B.ilean.hash lib/lean/P/B.olean lib/lean/P/B.olean.hash lib/lean/P/B.trace "
check "cut --all: the rest of the complete modules, and no file of an incomplete one" "[ $rc = 0 ] && [ \"\$(cat '$TMPD/l2')\" = P.B ] && [ \"\$(members '$TMPD/p2.tar.zst' | tr '\n' ' ')\" = '$want2' ]" \
  "status $rc: $(members "$TMPD/p2.tar.zst" | tr '\n' ' ') $(cat "$TMPD/e2")"
echo stray > "$B/lib/lean/notes.txt"; setmt "$OLD" "$B/lib/lean/notes.txt"
bash "$SPK" cut --build-dir "$B" --done "$TMPD/done2" --out "$TMPD/p2c.tar.zst" --all 2>/dev/null; rc=$?
check "cut --all: a file that belongs to no module goes in too" "[ $rc = 0 ] && members '$TMPD/p2c.tar.zst' | grep -qx lib/lean/notes.txt" "status $rc"
rm -f "$B/lib/lean/notes.txt"
cat "$TMPD/done2" "$TMPD/d2" > "$TMPD/done2b"
bash "$SPK" cut --build-dir "$B" --done "$TMPD/done2b" --out "$TMPD/p2b.tar.zst" --all 2>/dev/null; rc=$?
check "cut --all: nothing due once everything is saved (status 3)" "[ $rc = 3 ]" "status $rc"
check "cut --all: never a *.tmp.* or setup file" "! members '$TMPD/p2.tar.zst' | grep -qE 'tmp|setup'"
# a saved module's .hash file written again: saved again, once it is older than the margin
echo "P/A olean.hash v2" > "$B/lib/lean/P/A.olean.hash"
bash "$SPK" cut --build-dir "$B" --done "$TMPD/done2b" --out "$TMPD/p3.tar.zst" --settle-before "$SETTLE" 2>/dev/null; rc=$?
check "cut: a .hash file written again within the margin waits (status 3)" "[ $rc = 3 ]" "status $rc"
setmt $(( OLD + 50 )) "$B/lib/lean/P/A.olean.hash"
bash "$SPK" cut --build-dir "$B" --done "$TMPD/done2b" --out "$TMPD/p3.tar.zst" --list "$TMPD/l3" --done-out "$TMPD/d3" --settle-before "$SETTLE" 2>/dev/null; rc=$?
check "cut: a saved module's .hash file written again is saved again, alone" "[ $rc = 0 ] && [ \"\$(members '$TMPD/p3.tar.zst')\" = lib/lean/P/A.olean.hash ] && [ ! -s '$TMPD/l3' ]" "status $rc"
cat "$TMPD/done2b" "$TMPD/d3" > "$TMPD/done3"
bash "$SPK" cut --build-dir "$B" --done "$TMPD/done3" --out "$TMPD/p3b.tar.zst" 2>/dev/null; rc=$?
check "cut: and the later done line wins (status 3)" "[ $rc = 3 ]" "status $rc"
# a saved output written again, or gone
setmt $(( OLD + 7 )) "$B/lib/lean/P/A.ilean"
cut -f1-3 "$TMPD/done3" > "$TMPD/done3n"                  # done lines of three columns: no SHA-256 recorded
bash "$SPK" cut --build-dir "$B" --done "$TMPD/done3n" --out "$TMPD/p3c.tar.zst" 2>"$TMPD/e"; rc=$?
check "cut: a saved output with another time and no SHA-256 recorded is a module compiled again (status 4)" "[ $rc = 4 ] && grep -q 'lib/lean/P/A.ilean' '$TMPD/e' && [ ! -e '$TMPD/p3c.tar.zst' ]" "status $rc"
setmt "$OLD" "$B/lib/lean/P/A.ilean"
# written again with the same bytes (only the time is new): saved again in the next part, not status 4
setmt $(( OLD + 9 )) "$B/lib/lean/P/A.olean"
bash "$SPK" cut --build-dir "$B" --done "$TMPD/done3" --out "$TMPD/p3s.tar.zst" --done-out "$TMPD/d3s" --list "$TMPD/l3s" 2>"$TMPD/e"; rc=$?
check "cut: a saved .olean written again with the same bytes is saved again, with its new time, alone (status 0)" \
  "[ $rc = 0 ] && [ \"\$(members '$TMPD/p3s.tar.zst')\" = lib/lean/P/A.olean ] && [ \"\$(cut -f1-3 '$TMPD/d3s')\" = \"\$(printf 'lib/lean/P/A.olean\t%s\t%s' \"\$(fsize '$B/lib/lean/P/A.olean')\" $(( OLD + 9 )))\" ] && [ ! -s '$TMPD/l3s' ]" "status $rc $(cat "$TMPD/e")"
check "...and the error output counts it as written again with the same bytes" "grep -q '; 1 files written again with the same bytes' '$TMPD/e'" "$(cat "$TMPD/e")"
cat "$TMPD/done3" "$TMPD/d3s" > "$TMPD/done3s"
bash "$SPK" cut --build-dir "$B" --done "$TMPD/done3s" --out "$TMPD/p3t.tar.zst" 2>/dev/null; rc=$?
check "...with that part's done line, nothing is due (status 3)" "[ $rc = 3 ]" "status $rc"
# A saved file changed within the settle margin may be in the middle of being written: with --settle-before it is
# neither status 4 nor saved, but looked at again in a later round; without --settle-before, strict as ever.
cp -p "$B/lib/lean/P/A.ilean" "$TMPD/A.ilean.keep"
echo "more bytes" >> "$B/lib/lean/P/A.ilean"                        # a new size, and a time after the margin
bash "$SPK" cut --build-dir "$B" --done "$TMPD/done3s" --out "$TMPD/p3r.tar.zst" --settle-before "$SETTLE" 2>"$TMPD/e"; rc=$?
check "cut --settle-before: a saved file changed after the margin is not status 4 and not saved (status 3), and the error output says so" \
  "[ $rc = 3 ] && [ ! -e '$TMPD/p3r.tar.zst' ] && grep -q '^1 saved files changed in the last seconds; looked at again next round$' '$TMPD/e'" "status $rc $(cat "$TMPD/e")"
bash "$SPK" cut --build-dir "$B" --done "$TMPD/done3s" --out "$TMPD/p3r.tar.zst" --all 2>"$TMPD/e"; rc=$?
check "...without --settle-before (the last cut, --all) it is a module compiled again (status 4)" "[ $rc = 4 ] && [ ! -e '$TMPD/p3r.tar.zst' ] && grep -q 'lib/lean/P/A.ilean' '$TMPD/e'" "status $rc $(cat "$TMPD/e")"
setmt $(( OLD + 13 )) "$B/lib/lean/P/A.ilean"
bash "$SPK" cut --build-dir "$B" --done "$TMPD/done3s" --out "$TMPD/p3r.tar.zst" --settle-before "$SETTLE" 2>"$TMPD/e"; rc=$?
check "...and once it is older than the margin, with other bytes, the next round says status 4" "[ $rc = 4 ] && grep -q 'lib/lean/P/A.ilean' '$TMPD/e'" "status $rc $(cat "$TMPD/e")"
cp -p "$TMPD/A.ilean.keep" "$B/lib/lean/P/A.ilean"
touch "$B/lib/lean/P/A.olean"                                        # the same bytes, a time after the margin
bash "$SPK" cut --build-dir "$B" --done "$TMPD/done3s" --out "$TMPD/p3r.tar.zst" --settle-before "$SETTLE" 2>"$TMPD/e"; rc=$?
check "cut --settle-before: a saved file written again with the same bytes after the margin also waits (status 3)" "[ $rc = 3 ] && grep -q '^1 saved files changed in the last seconds' '$TMPD/e'" "status $rc $(cat "$TMPD/e")"
setmt $(( OLD + 15 )) "$B/lib/lean/P/A.olean"
bash "$SPK" cut --build-dir "$B" --done "$TMPD/done3s" --out "$TMPD/p3r.tar.zst" --settle-before "$SETTLE" 2>"$TMPD/e"; rc=$?
check "...and the next round, once it is older than the margin, saves it again, alone (status 0)" "[ $rc = 0 ] && [ \"\$(members '$TMPD/p3r.tar.zst')\" = lib/lean/P/A.olean ] && ! grep -q 'changed in the last seconds' '$TMPD/e'" "status $rc $(cat "$TMPD/e")"
setmt $(( OLD + 9 )) "$B/lib/lean/P/A.olean"; rm -f "$TMPD/p3r.tar.zst"
# B19: only a time not more than 60 s ahead of now is put off; a time further in the future is judged at once
echo "more bytes" >> "$B/lib/lean/P/A.ilean"; setmt $(( $(date +%s) + 30 )) "$B/lib/lean/P/A.ilean"
bash "$SPK" cut --build-dir "$B" --done "$TMPD/done3s" --out "$TMPD/p3r.tar.zst" --settle-before "$SETTLE" 2>"$TMPD/e"; rc=$?
check "cut --settle-before: a saved file with other bytes and a time 30 s ahead of now still waits (status 3)" "[ $rc = 3 ] && [ ! -e '$TMPD/p3r.tar.zst' ] && grep -q '^1 saved files changed in the last seconds' '$TMPD/e'" "status $rc $(cat "$TMPD/e")"
setmt $(( $(date +%s) + 3600 )) "$B/lib/lean/P/A.ilean"
bash "$SPK" cut --build-dir "$B" --done "$TMPD/done3s" --out "$TMPD/p3r.tar.zst" --settle-before "$SETTLE" 2>"$TMPD/e"; rc=$?
check "cut --settle-before: a saved file with other bytes and a time an hour ahead is judged at once: a module compiled again (status 4)" \
  "[ $rc = 4 ] && [ ! -e '$TMPD/p3r.tar.zst' ] && grep -q 'lib/lean/P/A.ilean' '$TMPD/e' && ! grep -q 'changed in the last seconds' '$TMPD/e'" "status $rc $(cat "$TMPD/e")"
cp -p "$TMPD/A.ilean.keep" "$B/lib/lean/P/A.ilean"
setmt $(( $(date +%s) + 3600 )) "$B/lib/lean/P/A.olean"                # the same bytes, a time an hour ahead
bash "$SPK" cut --build-dir "$B" --done "$TMPD/done3s" --out "$TMPD/p3r.tar.zst" --settle-before "$SETTLE" 2>"$TMPD/e"; rc=$?
check "...the same bytes with a time an hour ahead: saved again at once, alone (status 0)" "[ $rc = 0 ] && [ \"\$(members '$TMPD/p3r.tar.zst')\" = lib/lean/P/A.olean ] && ! grep -q 'changed in the last seconds' '$TMPD/e'" "status $rc $(cat "$TMPD/e")"
setmt $(( OLD + 9 )) "$B/lib/lean/P/A.olean"; rm -f "$TMPD/p3r.tar.zst"
cp -p "$B/lib/lean/P/A.olean" "$TMPD/A.olean.keep"
python3 -I -c 'import sys; p = sys.argv[1]; b = bytearray(open(p, "rb").read()); b[0] ^= 1; open(p, "wb").write(bytes(b))' "$B/lib/lean/P/A.olean"
setmt $(( OLD + 11 )) "$B/lib/lean/P/A.olean"
bash "$SPK" cut --build-dir "$B" --done "$TMPD/done3s" --out "$TMPD/p3u.tar.zst" 2>"$TMPD/e"; rc=$?
check "cut: a saved .olean with one byte changed, the same size and a new time is a module compiled again (status 4)" "[ $rc = 4 ] && grep -q 'lib/lean/P/A.olean' '$TMPD/e' && [ ! -e '$TMPD/p3u.tar.zst' ]" "status $rc"
cp -p "$TMPD/A.olean.keep" "$B/lib/lean/P/A.olean"; setmt "$OLD" "$B/lib/lean/P/A.olean"
echo more >> "$B/ir/P/A.c"; setmt "$OLD" "$B/ir/P/A.c"
bash "$SPK" cut --build-dir "$B" --done "$TMPD/done3" --out "$TMPD/p3c.tar.zst" 2>/dev/null; rc=$?
check "cut: a saved output with another size, same time, too (status 4)" "[ $rc = 4 ]" "status $rc"
rm -f "$B/lib/lean/P/C.olean"
bash "$SPK" cut --build-dir "$B" --done "$TMPD/done1" --out "$TMPD/p3c.tar.zst" 2>/dev/null; rc=$?
check "cut: a saved module whose .olean has gone is reported (status 4)" "[ $rc = 4 ] && [ ! -e '$TMPD/p3c.tar.zst' ]" "status $rc"
# a symbolic link under a selected name
mkdir -p "$TMPD/b4/build/lib/lean" "$TMPD/b4/build/ir"; B4="$TMPD/b4/build"
echo '{"depHash": "1"}' > "$B4/lib/lean/L.trace"; echo i > "$B4/lib/lean/L.ilean"; echo c > "$B4/ir/L.c"; ln -s /etc/hosts "$B4/lib/lean/L.olean"
: > "$TMPD/empty"
bash "$SPK" cut --build-dir "$B4" --done "$TMPD/empty" --out "$TMPD/p4.tar.zst" 2>/dev/null; rc=$?
check "cut: a symbolic link under a selected name is an error" "[ $rc = 1 ] && [ ! -e '$TMPD/p4.tar.zst' ]" "status $rc"
# --paths-from: exactly the files listed (the seal's repair part), whatever module they belong to
printf 'lib/lean/P/D.olean\nir/P/D.c\n' > "$TMPD/pf1"
bash "$SPK" cut --build-dir "$B" --paths-from "$TMPD/pf1" --out "$TMPD/p5.tar.zst" --done-out "$TMPD/d5" --members-out "$TMPD/m5" 2>"$TMPD/e"; rc=$?
check "cut --paths-from: exactly the files listed" "[ $rc = 0 ] && [ \"\$(members '$TMPD/p5.tar.zst' | tr '\n' ' ')\" = 'ir/P/D.c lib/lean/P/D.olean ' ]" "status $rc $(cat "$TMPD/e")"
for bad in '../x' '/etc/hosts' 'other/x' 'lib/lean/P/NOPE.olean'; do
  printf '%s\n' "$bad" > "$TMPD/pf2"
  bash "$SPK" cut --build-dir "$B" --paths-from "$TMPD/pf2" --out "$TMPD/p5b.tar.zst" 2>/dev/null; rc=$?
  check "cut --paths-from: refuses '$bad'" "[ $rc = 1 ] && [ ! -e '$TMPD/p5b.tar.zst' ]" "status $rc"
done
bash "$SPK" cut --build-dir "$B" --paths-from "$TMPD/pf1" --dry-run > "$TMPD/dr5" 2>/dev/null; rc=$?
check "cut --dry-run: prints the done lines and writes no archive" "[ $rc = 0 ] && cmp -s '$TMPD/dr5' '$TMPD/d5'" "status $rc"
bash "$SPK" cut --build-dir "$B" --paths-from "$TMPD/pf1" --out - 2>/dev/null > "$TMPD/p5s"; rc=$?
bash "$SPK" list --part - --done-out - < "$TMPD/p5s" > "$TMPD/d5s" 2>/dev/null; rc2=$?
check "cut --out -: the archive on standard output, which list reads from standard input" "[ $rc = 0 ] && [ $rc2 = 0 ] && cmp -s '$TMPD/d5s' '$TMPD/d5'" "status $rc $rc2"
bash "$SPK" cut --build-dir "$B" --paths-from "$TMPD/pf1" --out - --done-out - >/dev/null 2>&1; rc=$?
check "cut: refuses two outputs on standard output (status 2)" "[ $rc = 2 ]" "status $rc"

# ---------------------------------------------------------------- restore: refusals and a good restore
GOOD=$(sha "$TMPD/p1.tar.zst")
mkdir -p "$TMPD/r1"
bash "$SPK" restore --build-dir "$TMPD/r1/build" --part "$TMPD/p1.tar.zst" --sha256 "$(echo "$GOOD" | tr 0-9a-f 1-9a-f0)" >/dev/null 2>"$TMPD/e"; rc=$?
check "restore: refuses a bad checksum, writing nothing" "[ $rc = 1 ] && [ ! -e '$TMPD/r1/build/lib' ] && grep -q mismatch '$TMPD/e'" "status $rc"
bash "$SPK" restore --build-dir "$TMPD/r1/build" --part "$TMPD/p1.tar.zst" --sha256 "$GOOD" --list "$TMPD/rl1" --members-out "$TMPD/rm1" --done-out "$TMPD/rd1" >"$TMPD/o" 2>"$TMPD/e"; rc=$?
check "restore: a good part" "[ $rc = 0 ] && cmp -s '$TMPD/rl1' '$TMPD/l1' && cmp -s '$TMPD/r1/build/lib/lean/P/E.olean' '$B/lib/lean/P/E.olean'" "status $rc $(cat "$TMPD/e")"
check "restore: its summary goes to the error output, not the standard output" "[ ! -s '$TMPD/o' ] && grep -q 'restored 2 modules' '$TMPD/e'"
check "restore: mode 644 and the saved modification time" "[ \"\$(modeof '$TMPD/r1/build/lib/lean/P/E.olean')\" = 644 ] && [ \"\$(mtime '$TMPD/r1/build/lib/lean/P/E.olean')\" = $OLD ]" \
  "$(modeof "$TMPD/r1/build/lib/lean/P/E.olean") $(mtime "$TMPD/r1/build/lib/lean/P/E.olean")"
check "restore: its members and done files are the cut's own" "gzip -dc '$TMPD/m1.gz' | cmp -s - '$TMPD/rm1' && cmp -s '$TMPD/rd1' '$TMPD/d1'"
# What the guest does after a restore: checks, writing no archive, that the tree is what the parts say.
bash "$SPK" cut --build-dir "$TMPD/r1/build" --done "$TMPD/rd1" --dry-run --all > "$TMPD/dl1" 2>"$TMPD/e"; rc=$?
check "cut --dry-run after a restore: nothing unsaved, nothing changed (status 3)" "[ $rc = 3 ] && [ ! -s '$TMPD/dl1' ] && [ -z \"\$(find '$TMPD/r1' -name '*.zst*')\" ]" "status $rc: $(cat "$TMPD/dl1" "$TMPD/e")"
setmt $(( OLD + 3 )) "$TMPD/r1/build/lib/lean/P/A.trace"
bash "$SPK" cut --build-dir "$TMPD/r1/build" --done "$TMPD/rd1" --dry-run --all > "$TMPD/dl1b" 2>"$TMPD/e"; rc=$?
check "cut --dry-run after a restore: a restored file with a new time and the same bytes is listed, not status 4" "[ $rc = 0 ] && [ \"\$(cut -f1 '$TMPD/dl1b')\" = lib/lean/P/A.trace ] && grep -q '1 files written again with the same bytes' '$TMPD/e'" "status $rc"
printf '{"depHash": "2", "outputs": {}}' > "$TMPD/r1/build/lib/lean/P/A.trace"; setmt $(( OLD + 3 )) "$TMPD/r1/build/lib/lean/P/A.trace"
bash "$SPK" cut --build-dir "$TMPD/r1/build" --done "$TMPD/rd1" --dry-run --all >/dev/null 2>&1; rc=$?
check "cut --dry-run after a restore: a restored file not as saved (status 4)" "[ $rc = 4 ]" "status $rc"
printf '{"depHash": "1", "outputs": {}}' > "$TMPD/r1/build/lib/lean/P/A.trace"; setmt "$OLD" "$TMPD/r1/build/lib/lean/P/A.trace"
badpart() { # badpart <out> <kind>   -- a part with one bad member, made with python's tarfile
  python3 -I - "$1.tar" "$2" <<'PY'
import io, sys, tarfile
out, kind = sys.argv[1], sys.argv[2]
with tarfile.open(out, "w", format=tarfile.PAX_FORMAT) as t:
    ok = tarfile.TarInfo("lib/lean/Ok.trace"); data = b'{"depHash": "1"}'; ok.size = len(data); t.addfile(ok, io.BytesIO(data))
    if kind == "link":
        ti = tarfile.TarInfo("lib/lean/Evil.olean"); ti.type = tarfile.SYMTYPE; ti.linkname = "/etc/passwd"; t.addfile(ti)
    elif kind == "hardlink":
        ti = tarfile.TarInfo("lib/lean/Evil.olean"); ti.type = tarfile.LNKTYPE; ti.linkname = "lib/lean/Ok.trace"; t.addfile(ti)
    else:
        name = {"abs": "/tmp/spot-evil", "dotdot": "lib/lean/../../../spot-evil", "outside": "other/x.olean"}[kind]
        ti = tarfile.TarInfo(name); ti.size = 4; t.addfile(ti, io.BytesIO(b"evil"))
PY
  zstd -q -f "$1.tar" -o "$1" && rm -f "$1.tar"
}
for k in abs dotdot link hardlink outside; do
  badpart "$TMPD/bad_$k.tar.zst" "$k"; mkdir -p "$TMPD/rb_$k"
  bash "$SPK" restore --build-dir "$TMPD/rb_$k/build" --part "$TMPD/bad_$k.tar.zst" --sha256 "$(sha "$TMPD/bad_$k.tar.zst")" --members-out "$TMPD/rbm_$k" >/dev/null 2>"$TMPD/e"; rc=$?
  check "restore: refuses a member of kind '$k', and leaves no members file" "[ $rc = 1 ] && grep -q refused '$TMPD/e' && [ ! -e '$TMPD/rb_$k/build/lib/lean/Evil.olean' ] && [ ! -e '$TMPD/spot-evil' ] && [ ! -e '$TMPD/rb_$k/build/other' ] && [ ! -e '$TMPD/rbm_$k' ]" "status $rc: $(cat "$TMPD/e")"
done
# a planted link where restore would make a directory
mkdir -p "$TMPD/r5/build" "$TMPD/elsewhere"; ln -s "$TMPD/elsewhere" "$TMPD/r5/build/lib"
bash "$SPK" restore --build-dir "$TMPD/r5/build" --part "$TMPD/p1.tar.zst" --sha256 "$GOOD" >/dev/null 2>"$TMPD/e"; rc=$?
check "restore: does not follow a planted link in the build directory" "[ $rc = 1 ] && [ -z \"\$(ls -A '$TMPD/elsewhere')\" ]" "status $rc"
# an existing file is replaced, not written through (a hard link elsewhere keeps its content)
mkdir -p "$TMPD/r6/build/lib/lean/P"; echo precious > "$TMPD/precious"; ln "$TMPD/precious" "$TMPD/r6/build/lib/lean/P/A.olean" 2>/dev/null
bash "$SPK" restore --build-dir "$TMPD/r6/build" --part "$TMPD/p1.tar.zst" --sha256 "$GOOD" >/dev/null 2>&1; rc=$?
check "restore: replaces an existing file instead of writing through it" "[ $rc = 0 ] && [ \"\$(cat '$TMPD/precious')\" = precious ]" "status $rc"

# ---------------------------------------------------------------- cover: do the parts reproduce the sealed files?
R="$TMPD/r1/build"
libman "$R/lib/lean" > "$TMPD/man1"
bash "$SPK" cover --lib-manifest "$TMPD/man1" --members "$TMPD/m1.gz" > "$TMPD/c1" 2>/dev/null; rc=$?
check "cover: equal when the parts hold exactly the sealed files (status 0)" "[ $rc = 0 ] && [ ! -s '$TMPD/c1' ]" "status $rc: $(cat "$TMPD/c1")"
echo new > "$R/lib/lean/P/New.olean"; echo changed > "$R/lib/lean/P/E.olean"
libman "$R/lib/lean" > "$TMPD/man2"
bash "$SPK" cover --lib-manifest "$TMPD/man2" --members "$TMPD/m1.gz" > "$TMPD/c2" 2>/dev/null; rc=$?
printf 'different\tlib/lean/P/E.olean\nmissing\tlib/lean/P/New.olean\n' > "$TMPD/c2.want"
check "cover: names a sealed file in no part, and one the parts hold with other bytes (status 3)" "[ $rc = 3 ] && cmp -s '$TMPD/c2' '$TMPD/c2.want'" "status $rc: $(cat "$TMPD/c2")"
grep -v 'A.trace$' "$TMPD/man1" > "$TMPD/man3"
bash "$SPK" cover --lib-manifest "$TMPD/man3" --members "$TMPD/m1.gz" > "$TMPD/c3" 2>/dev/null; rc=$?
check "cover: names a file the parts hold that was not sealed (status 3)" "[ $rc = 3 ] && [ \"\$(cat '$TMPD/c3')\" = \"\$(printf 'extra\tlib/lean/P/A.trace')\" ]" "status $rc: $(cat "$TMPD/c3")"
{ grep -v 'E.ilean$' "$TMPD/man1"; echo 'not-a-file:l  ./P/E.ilean -> /etc/hosts'; } > "$TMPD/man4"
bash "$SPK" cover --lib-manifest "$TMPD/man4" --members "$TMPD/m1.gz" > "$TMPD/c4" 2>/dev/null; rc=$?
check "cover: a sealed entry that is not a file is never reproduced (status 3)" "[ $rc = 3 ] && [ \"\$(cat '$TMPD/c4')\" = \"\$(printf 'different\tlib/lean/P/E.ilean')\" ]" "status $rc: $(cat "$TMPD/c4")"
# the seal's repair: one more part of exactly the files named, whose members file is read last and wins
cut -f2 "$TMPD/c2" > "$TMPD/fix"
bash "$SPK" cut --build-dir "$R" --paths-from "$TMPD/fix" --out "$TMPD/fix.tar.zst" --members-out "$TMPD/mfix.gz" 2>/dev/null; rc=$?
bash "$SPK" cover --lib-manifest "$TMPD/man2" --members "$TMPD/m1.gz" --members "$TMPD/mfix.gz" > "$TMPD/c5" 2>/dev/null; rc2=$?
check "cover: a repair part read last makes the parts equal to the seal" "[ $rc = 0 ] && [ $rc2 = 0 ] && [ ! -s '$TMPD/c5' ]" "status $rc $rc2: $(cat "$TMPD/c5")"
bash "$SPK" cover --lib-manifest "$TMPD/man2" --members "$TMPD/mfix.gz" --members "$TMPD/m1.gz" > /dev/null 2>&1; rc=$?
check "cover: the order matters (the older part read last brings back the old bytes)" "[ $rc = 3 ]" "status $rc"
bash "$SPK" cover --lib-manifest "$TMPD/man2" --members "$TMPD/no-such-file" > /dev/null 2>&1; rc=$?
check "cover: a members file that is not there is an error (status 1)" "[ $rc = 1 ]" "status $rc"

# ---------------------------------------------------------------- trim
printf 'h\ta\nm1\t0\nm2\t0\tcut' > "$TMPD/t1"; bash "$SPK" trim --file "$TMPD/t1"
check "trim: drops a last line with no newline" "[ \"\$(cat '$TMPD/t1')\" = \"\$(printf 'h\ta\nm1\t0')\" ] && [ \"\$(tail -c 1 '$TMPD/t1' | od -An -c | tr -d ' ')\" = '\\n' ]"
printf 'h\nm1\n' > "$TMPD/t2"; cp "$TMPD/t2" "$TMPD/t2.orig"; bash "$SPK" trim --file "$TMPD/t2"
check "trim: leaves a complete file alone" "cmp -s '$TMPD/t2' '$TMPD/t2.orig'"
printf 'partial' > "$TMPD/t3"; bash "$SPK" trim --file "$TMPD/t3"
check "trim: a file with no complete line becomes empty" "[ ! -s '$TMPD/t3' ]"
printf 'h\nm1\tcut' > "$TMPD/t4.target"; cp "$TMPD/t4.target" "$TMPD/t4.orig"; ln -s "$TMPD/t4.target" "$TMPD/t4"
bash "$SPK" trim --file "$TMPD/t4" 2>"$TMPD/e"; rc=$?
check "trim: refuses a symbolic link (status 1) and leaves its target untouched" "[ $rc = 1 ] && cmp -s '$TMPD/t4.target' '$TMPD/t4.orig' && [ -L '$TMPD/t4' ]" "status $rc $(cat "$TMPD/e")"
mkfifo "$TMPD/t5" 2>/dev/null && { bash "$SPK" trim --file "$TMPD/t5" 2>/dev/null; rc=$?
  check "trim: refuses a named pipe without waiting on it (status 1)" "[ $rc = 1 ]" "status $rc"; }

# ---------------------------------------------------------------- state
S="$TMPD/state.json"
bash "$SPK" state --file "$S" --runtag rt1 --attempt 1 --attempt-set zone=z-a --set stage=build --var "C1_STATE=built" --var "EVIL=x'; touch $TMPD/pwned; echo '" --parts-modules 10
bash "$SPK" state --file "$S" --done build --results-saved 5
bash "$SPK" state --file "$S" --parts-modules 3 --results-saved 2      # smaller numbers must not lower progress
P=$(bash "$SPK" state-get --file "$S" --key progress)
check "state: progress counts saved work and units, and never goes down" "[ '$P' = 1000015 ]" "$P"
eval "$(bash "$SPK" state-export --file "$S" C1_STATE EVIL NOT_THERE)"
check "state-export: values come back exactly, quoted, and run nothing" "[ \"\$C1_STATE\" = built ] && [ ! -e '$TMPD/pwned' ] && [ \"\${EVIL#x}\" != \"\$EVIL\" ] && [ -z \"\${NOT_THERE:-}\" ]"
bash "$SPK" state-export --file "$S" 'bad;name' >/dev/null 2>&1; rc=$?
check "state-export: refuses a name that is not a variable name" "[ $rc = 2 ]"
check "state-get --done" "bash '$SPK' state-get --file '$S' --done build && ! bash '$SPK' state-get --file '$S' --done seal"
bash "$SPK" state --file "$S" --attempt 2 --close-open-attempts "cut without notice"
check "state: open attempts are closed with a reason, and the attempt is recorded" \
  "python3 -I -c 'import json,sys; s=json.load(open(sys.argv[1])); a=s[\"attempts\"]; sys.exit(0 if s[\"attempt\"]==2 and a[0][\"ended\"]==\"cut without notice\" and a[0][\"zone\"]==\"z-a\" and a[1][\"n\"]==2 else 1)' '$S'"

# ---------------------------------------------------------------- the toolchain's own build tool on a toy project
TC="${ELAN_HOME:-$HOME/.elan}/toolchains/leanprover--lean4---v4.33.1/bin"
if [ ! -x "$TC/lake" ]; then
  echo "SKIP  toy project: the v4.33.1 toolchain is not installed"
else
  # Four modules and a root: Toy.A plain, Toy.W with a warning (a `sorry`) and an #eval, Toy.B importing Toy.A,
  # Toy.F that fails to compile, and the root Toy (the default target: Toy.B and Toy.W, not Toy.F).
  T="$TMPD/toy"; mkdir -p "$T/Toy"
  printf 'import Lake\nopen Lake DSL\npackage toy\n@[default_target] lean_lib Toy\n' > "$T/lakefile.lean"
  echo 'leanprover/lean4:v4.33.1' > "$T/lean-toolchain"
  printf 'def a : Nat := 41\ntheorem a_eq : a = 41 := rfl\n' > "$T/Toy/A.lean"
  printf 'def w : Nat := 7\ntheorem w_le : w ≤ 8 := by sorry\n#eval w + 1\n' > "$T/Toy/W.lean"
  printf 'import Toy.A\ndef b : Nat := a + 1\ntheorem b_eq : b = 42 := by decide\n' > "$T/Toy/B.lean"
  printf 'import Toy.A\ntheorem f_bad : a = 42 := rfl\n' > "$T/Toy/F.lean"
  printf 'import Toy.B\nimport Toy.W\ntheorem c_eq : b + 1 = 43 := by decide\n' > "$T/Toy.lean"
  ( cd "$T" && "$TC/lake" build Toy.A Toy.W Toy.B Toy.F ) > "$TMPD/lake1.log" 2>&1; rc=$?
  check "toy: first build compiles Toy.A, Toy.W (with its warning) and Toy.B, fails on Toy.F, and does not build Toy" \
    "[ $rc != 0 ] && grep -q 'Built Toy.A' '$TMPD/lake1.log' && grep -q '⚠ .*Built Toy.W' '$TMPD/lake1.log' && grep -q 'declaration uses .sorry.' '$TMPD/lake1.log' && grep -q 'Built Toy.B' '$TMPD/lake1.log' && grep -q '✖ .*Toy.F' '$TMPD/lake1.log' && ! grep -qE 'Built Toy( |$)' '$TMPD/lake1.log'" "status $rc: $(grep -E 'Built|✖' "$TMPD/lake1.log" | tr '\n' ' ')"
  sleep 1
  bash "$SPK" cut --build-dir "$T/.lake/build" --done "$TMPD/empty" --out "$TMPD/toy.tar.zst" --list "$TMPD/toy.list" --members-out "$TMPD/toy.members" \
    --settle-before "$(date +%s)" 2>"$TMPD/e"; rc=$?
  check "toy: cut saves the three modules that compiled, and nothing of the one that failed" "[ $rc = 0 ] && [ \"\$(tr '\n' ' ' < '$TMPD/toy.list')\" = 'Toy.A Toy.B Toy.W ' ] && ! grep -q 'Toy/F' '$TMPD/toy.members'" "status $rc $(cat "$TMPD/e")"
  ( cd "$T/.lake/build" && find lib ir -type f ! -name '*.setup.json' | LC_ALL=C sort | while read -r f; do echo "$(sha "$f")  $f"; done ) > "$TMPD/toy.before"
  rm -rf "${T:?}/.lake/build"
  # restored, into a clean tree, with the done list the guest keeps (restore --done-out: path, size, time, SHA-256)
  bash "$SPK" restore --build-dir "$T/.lake/build" --part "$TMPD/toy.tar.zst" --sha256 "$(sha "$TMPD/toy.tar.zst")" --done-out "$TMPD/toy.rdone" >/dev/null 2>"$TMPD/e"; rc=$?
  ( cd "$T/.lake/build" && find lib ir -type f | LC_ALL=C sort | while read -r f; do echo "$(sha "$f")  $f"; done ) > "$TMPD/toy.restored"
  check "toy: the wiped build directory is restored byte for byte (setup files apart)" "[ $rc = 0 ] && cmp -s '$TMPD/toy.before' '$TMPD/toy.restored'" "$(diff "$TMPD/toy.before" "$TMPD/toy.restored" | head -5)"
  libman "$T/.lake/build/lib/lean" > "$TMPD/toy.man"
  bash "$SPK" cover --lib-manifest "$TMPD/toy.man" --members "$TMPD/toy.members" >"$TMPD/toy.cover" 2>&1; rc=$?
  check "toy: cover finds the part reproduces the restored lib/lean exactly" "[ $rc = 0 ]" "status $rc $(cat "$TMPD/toy.cover")"
  # The sources and the toolchain file as a fresh machine has them, newer than every restored file; and a second
  # later, the build again, with the module that fails.
  sleep 1; find "$T" -name '*.lean' -exec touch {} +; touch "$T/lean-toolchain"
  ( cd "$T" && "$TC/lake" build Toy Toy.F ) > "$TMPD/lake2.log" 2>&1; rc=$?
  check "toy: the build after the restore compiles the root, fails on Toy.F again, and compiles no restored module" \
    "[ $rc != 0 ] && grep -qE 'Built Toy( |$)' '$TMPD/lake2.log' && grep -q '✖ .*Toy.F' '$TMPD/lake2.log' && ! grep -qE 'Built Toy\.(A|B|W)' '$TMPD/lake2.log'" "status $rc: $(grep -E 'Built|Replayed|✖' "$TMPD/lake2.log" | tr '\n' ' ')"
  ( cd "$T/.lake/build" && while read -r h f; do [ "$(sha "$f")" = "$h" ] || echo "$f"; done < "$TMPD/toy.before" ) > "$TMPD/toy.changed"
  check "toy: that build left every restored file's bytes as they were (traces and .hash files included)" "[ ! -s '$TMPD/toy.changed' ]" "$(tr '\n' ' ' < "$TMPD/toy.changed")"
  # What the build did to each restored file, by kind (extension): its time, its size, its bytes.
  python3 -I - "$T/.lake/build" "$TMPD/toy.rdone" "$TMPD/toy.whatsum" > "$TMPD/toy.what" <<'PY'
import hashlib, os, sys
b, kinds = sys.argv[1], {}
for line in open(sys.argv[2]):
    rel, size, mt, h = line.rstrip("\n").split("\t")
    f = rel.rsplit("/", 1)[-1]; ext = f.split(".", 1)[1] if "." in f else "-"
    k = kinds.setdefault(ext, {"files": 0, "time": 0, "size": 0, "bytes": 0, "gone": 0})
    k["files"] += 1; p = os.path.join(b, rel)
    if not os.path.isfile(p): k["gone"] += 1; continue
    st = os.stat(p)
    k["time"] += int(st.st_mtime) != int(mt); k["size"] += st.st_size != int(size)
    k["bytes"] += hashlib.sha256(open(p, "rb").read()).hexdigest() != h
print("; ".join("%s: %d files, %d new time, %d new size, %d new bytes, %d gone" % (e, v["files"], v["time"], v["size"], v["bytes"], v["gone"])
                for e, v in sorted(kinds.items())))
open(sys.argv[3], "w").write("%d %d\n" % (sum(v["files"] for v in kinds.values()),
                                          sum(v["time"] + v["size"] + v["bytes"] + v["gone"] for v in kinds.values())))
PY
  echo "INFO  toy: what the build after the restore did to the restored files, by kind: $(cat "$TMPD/toy.what")"
  check "toy: no restored file has a new time, a new size or new bytes, or has gone" "[ \"\$(cut -d' ' -f2 '$TMPD/toy.whatsum')\" = 0 ] && [ \"\$(cut -d' ' -f1 '$TMPD/toy.whatsum')\" -gt 0 ]" "$(cat "$TMPD/toy.whatsum")"
  # The guest's next cut, with the done list the restore wrote: it must not take a restored module as compiled again.
  bash "$SPK" cut --build-dir "$T/.lake/build" --done "$TMPD/toy.rdone" --out "$TMPD/toy.after.tar.zst" --list "$TMPD/toy.after.list" 2>"$TMPD/e"; rc=$?
  check "toy: a cut with the restored done list after that build saves the new root only (not status 4)" \
    "[ $rc = 0 ] && [ \"\$(cat '$TMPD/toy.after.list')\" = Toy ] && ! members '$TMPD/toy.after.tar.zst' | grep -q 'Toy/'" "status $rc $(cat "$TMPD/e")"
  # Modification times: every file set to now, then to long ago. Neither makes the build tool compile anything.
  find "$T/.lake/build" -type f -exec touch {} +
  ( cd "$T" && "$TC/lake" build ) > "$TMPD/lake3.log" 2>&1; rc=$?
  find "$T/.lake/build" -type f -exec touch -t 200001010000 {} +
  ( cd "$T" && "$TC/lake" build ) >> "$TMPD/lake3.log" 2>&1; rc2=$?
  check "toy: modification times do not matter to the build tool" "[ $rc = 0 ] && [ $rc2 = 0 ] && ! grep -q 'Built ' '$TMPD/lake3.log'" "$(grep Built "$TMPD/lake3.log" | tr '\n' ' ')"
  # What is saved now (all three modules, with the times just set), as the done file would hold it.
  bash "$SPK" cut --build-dir "$T/.lake/build" --done "$TMPD/empty" --all --dry-run > "$TMPD/toy.done" 2>/dev/null
  # And the case the guest guards against: a restored module whose .hash files are missing.
  rm -f "$T/.lake/build/lib/lean/Toy/A.olean.hash"
  ( cd "$T" && "$TC/lake" build ) > "$TMPD/lake4.log" 2>&1
  check "toy: a missing .hash file is recomputed, not a reason to compile again" "! grep -q 'Built ' '$TMPD/lake4.log' && [ -s '$T/.lake/build/lib/lean/Toy/A.olean.hash' ]" "$(grep Built "$TMPD/lake4.log" | tr '\n' ' ')"
  bash "$SPK" cut --build-dir "$T/.lake/build" --done "$TMPD/toy.done" --out "$TMPD/toy3.tar.zst" --done-out "$TMPD/toy3.done" 2>"$TMPD/e"; rc=$?
  check "toy: the next cut saves that .hash file again, and nothing else" "[ $rc = 0 ] && [ \"\$(members '$TMPD/toy3.tar.zst')\" = lib/lean/Toy/A.olean.hash ]" "status $rc $(cat "$TMPD/e")"
  cat "$TMPD/toy3.done" >> "$TMPD/toy.done"
  # The guest's own check: a later cut notices if a saved module was compiled again.
  sleep 1; printf '\n' >> "$T/Toy/A.lean"
  ( cd "$T" && "$TC/lake" build ) > "$TMPD/lake5.log" 2>&1
  bash "$SPK" cut --build-dir "$T/.lake/build" --done "$TMPD/toy.done" --out "$TMPD/toy2.tar.zst" 2>/dev/null; rc=$?
  check "toy: after a source change recompiles saved modules, the next cut says so (status 4)" "grep -q 'Built Toy.A' '$TMPD/lake5.log' && [ $rc = 4 ]" "status $rc"
fi

echo "$N cases, $FAILS failed"
[ "$FAILS" = 0 ]
