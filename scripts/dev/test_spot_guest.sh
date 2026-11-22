#!/bin/bash
# test_spot_guest.sh - tests of the Spot code of cloud/gcp/full_guest.sh (full-spot=1), on a Mac, with no network.
#
# Why it exists: the guest's Spot code otherwise runs for the first time on a paid machine, and every rehearsal
#   there needs the owner's go-ahead. This runs that code here, as it is in the file, in a few minutes.
# What it does: takes the Spot block of cloud/gcp/full_guest.sh (from the `if [ "$SPOT" = 1 ]; then` under the
#   "Spot (full-spot=1) only" line to its closing `fi`), the settings at the top of the file, and the functions
#   the block calls that are defined elsewhere in the file, all extracted from the file when the test runs and
#   never retyped; loads them into a fresh bash process for each machine a case needs; and calls the guest's own
#   functions. Only three things are replaced: the transport (a fake `curl` that keeps the bucket in a local
#   directory and plays the metadata server), the GNU and Ubuntu tools that macOS lacks (small shims, below), and
#   `idle_until_deleted`, which on the real machine never returns and here ends the process with status 77, so
#   that `finish`, `spot_pause` and `spot_reclaimed` run for real and their uploads can be checked. The build
#   tree is made up of files named as the build tool names them (as in scripts/dev/test_spot_checkpoint.sh, whose
#   fixtures are written inline in that test and cannot be loaded from here); scripts/spot_checkpoint.sh, the
#   helper the guest calls, is the real one.
# Shims, each in one line (written to a scratch directory and put first on the PATH of the guest's processes):
#   curl       the bucket (uploads and downloads, as files under a local directory) and the metadata server
#              (attributes, token, zone, the preempted value with an ETag); it can be told to fail, stall an upload
#              (until its --max-time, scaled as sleep is), cut a download short, damage one, or answer 404, a given
#              number of times, and it logs every request in order
#   sha256sum  GNU output ("<hash>  <name>", "-" for the standard input), by python
#   stat       GNU `stat -c FORMAT` (%s %Y %a %n), by python; anything else goes to the system's stat
#   find       GNU `-printf` (%p %y %l %s and \n), by python on top of the system's find
#   date       GNU `-d @EPOCH` turned into BSD `-r EPOCH`
#   cp         GNU `--no-dereference` turned into BSD `-P`
#   wc         GNU's output without the leading spaces BSD wc adds (the guest compares counts as text)
#   timeout    GNU timeout (duration, --kill-after, -s), by python: status 124 when the time ran out
#   flock      util-linux `flock [-w SECS] FD` (and `flock FILE CMD`), by python on the same flock(2) call
#   runuser    runs the command as the current user, and logs that it was asked to run it as another
#   usermod, loginctl, crontab, chown   log what they were asked and do nothing (they would need root)
#   pkill      only `-P PID` (the children of a process) is carried out; by name or by user it only logs, so
#              that nothing named lean, lake or leanchecker on this Mac is ever touched
#   pgrep      finds nothing
#   id         says the users pilot, chk2 and chk3 do not exist
#   sleep      sleeps a fiftieth of the time asked (SPOTTEST_SLEEP_SCALE), so retries and loops take moments
# Bash 3.2: $BASHPID does not exist before bash 4; the guest uses it only to name a snapshot file, so this sets it
#   once to the process's PID (a loop and the main script could then share a name; the guest never runs both at
#   once). An empty array expanded as "${a[@]}" under set -u is an error before bash 4.4; no case here reaches
#   such an expansion (spot_cover with no parts would).
# What it does not cover: the main script's own flow between the functions (setup, the build loop, the seal's
#   other steps, the checks), the watchdog (it is one long subshell in the file), the build tool and the real
#   check programs, real users and permissions (runuser and chown are shims), Linux's /proc and signals sent by
#   the system, real network errors (the fake curl does not retry, where the real one retries some errors
#   itself), and timing at full scale. Those need a rehearsal.
# What it changes on disk: only a temporary directory of its own, removed at the end (kept with SPOTTEST_KEEP=1).
# Requires: python3 and zstd (as scripts/dev/test_spot_checkpoint.sh does). Nothing is installed.
# Usage: scripts/dev/test_spot_guest.sh        Prints PASS or FAIL per case, then the count.
# Exit status: 0 if every case passed, 1 otherwise.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/../.." && pwd)"
SELF="$HERE/$(basename "$0")"
# SPOTTEST_GUEST: another copy of the guest to test (to see that the harness notices a bug planted in a copy)
GUEST="${SPOTTEST_GUEST:-$ROOT/cloud/gcp/full_guest.sh}"; SPK_REAL="$ROOT/scripts/spot_checkpoint.sh"
HDR=$(printf 'seq\tobject\tsha256\tbytes\tmodules\tcut_epoch\tattempt')
ZEROS=0000000000000000000000000000000000000000000000000000000000000000

# ================================================================ inside one case (a process of its own)
# Checks go to the case's checks file, one line each; the parent prints the case's line from it.
ok() { local d=$1; shift; if "$@" >/dev/null 2>&1; then printf 'PASS\t%s\n' "$d" >> "$CHK"; else printf 'FAIL\t%s\t(test: %s)\n' "$d" "$*" >> "$CHK"; fi; }
# okc <description>: records the status of the test just run, for one of several parts: { a && b; }; okc "..."
okc() { local s=$?; if [ "$s" = 0 ]; then printf 'PASS\t%s\n' "$1" >> "$CHK"; else printf 'FAIL\t%s\t(status %s)\n' "$1" "$s" >> "$CHK"; fi; }
not() { ! "$@"; }
bk() { echo "$SPOTTEST_FAKE/bucket/$1"; }                       # bk <object>: the file that holds it
has() { [ -e "$(bk "$1")" ]; }
shaf() { shasum -a 256 "$1" | cut -d' ' -f1; }
nl_() { awk 'END {print NR}' "$1" 2>/dev/null || echo 0; }        # nl_ <file>: its number of lines
jtrue() { python3 -I -c 'import json, sys
try: d = json.load(open(sys.argv[1]))
except Exception: sys.exit(1)
sys.exit(0 if eval(sys.argv[2]) else 1)' "$1" "$2"; }           # jtrue <json file> <python expression on d>
jstate() { jtrue "$(bk "$CK/state.json")" "$1"; }
jstatus() { jtrue "$(bk "$RT/status.json")" "$1"; }
rule() { echo "$*" >> "$SPOTTEST_FAKE/rules"; }                 # rule <put|get> <object glob> <fail|stall|truncate|corrupt|404> <times>
ops() { cat "$SPOTTEST_FAKE/ops.log" 2>/dev/null; }
ops_mark() { OPS0=$(nl_ "$SPOTTEST_FAKE/ops.log"); }
ops_since() { tail -n +$(( OPS0 + 1 )) "$SPOTTEST_FAKE/ops.log"; }
gets() { grep -c "^GET $1 " "$SPOTTEST_FAKE/ops.log"; }
seqs() { awk -F'\t' 'NR > 1 {printf "%s ", $1}' "$(bk "$CK/manifest.tsv")"; }
md_set() { printf '%s' "$2" > "$SPOTTEST_FAKE/md/$1"; }
# runs one step that ends the attempt or the run in the real guest; its status is in $RC (77: it reached idle)
ends() { ( "$@" ); RC=$?; }
# mkmod <stem> [tag]: one complete module, as the build tool leaves it, written long ago (settled)
mkmod() {
  local b="$PROJ/.lake/build" s=$1 e d
  d=$(dirname "$s"); mkdir -p "$b/lib/lean/$d" "$b/ir/$d"
  for e in olean olean.hash ilean ilean.hash; do echo "$s $e ${2:-v1}" > "$b/lib/lean/$s.$e"; done
  for e in c c.hash setup.json; do echo "$s $e ${2:-v1}" > "$b/ir/$s.$e"; done
  printf '{"depHash": "1", "outputs": {}}' > "$b/lib/lean/$s.trace"
  touch -t 202001010000 "$b/lib/lean/$s".* "$b/ir/$s".*
}
# treesum <build dir>: every file the parts may hold, with its SHA-256 (the setup files never go into a part)
treesum() { ( cd "$1" && find lib ir -type f ! -name '*.setup.json' | LC_ALL=C sort | while read -r f; do echo "$(shasum -a 256 "$f" | cut -d' ' -f1) $f"; done ); }

# new_env <name> [metadata-key=value]...: a fresh machine: its own directories, bucket and metadata, and the
# guest's code loaded again (it reads the metadata as it loads, as the real script does at boot).
new_env() {
  local e="$CD/$1" kv; shift
  HARNESS_PD=$e/pd; HARNESS_WORK=$e/work; HARNESS_TOOLS=$e/tools; HARNESS_TC=$e/opt-lean-tc
  SPOTTEST_FAKE=$e/fake; export SPOTTEST_FAKE
  mkdir -p "$SPOTTEST_FAKE/md" "$SPOTTEST_FAKE/bucket" "$HARNESS_TOOLS/scripts" "$HARNESS_TC/bin" "$HARNESS_WORK/extract/lean/.lake/build" \
    "$HARNESS_WORK/extract/lean/.lake/packages/mathlib/.lake/build/lib/lean/Mathlib" || exit 1
  ln -s "$SPK_REAL" "$HARNESS_TOOLS/scripts/spot_checkpoint.sh"
  echo testbucket > "$SPOTTEST_FAKE/bucket_name"
  echo "a toolchain file" > "$HARNESS_TC/bin/lean"
  echo "a compiled file of Mathlib" > "$HARNESS_WORK/extract/lean/.lake/packages/mathlib/.lake/build/lib/lean/Mathlib/X.olean"
  md_set pilot-bucket testbucket; md_set pilot-runtag full-spot-test; md_set pilot-mode full; md_set pilot-nmax 4
  md_set full-spot 1; md_set full-attempt 1; md_set startup-script '#!/bin/bash'
  for kv in "$@"; do md_set "${kv%%=*}" "${kv#*=}"; done
  # shellcheck disable=SC1090
  . "$TMPD/guest.sh"
}
fixture_env() { # fixture_env <name> [metadata]...: attempt 2 of the run the fixture case saved
  # shellcheck disable=SC1090
  . "$TMPD/fixture/shas"
  new_env "$1" full-attempt=2 "full-state-sha=$FX_STATE" "full-manifest-sha=$FX_MAN" "${@:2}"
  rm -rf "${SPOTTEST_FAKE:?}/bucket"; cp -Rp "$TMPD/fixture/bucket" "$SPOTTEST_FAKE/bucket"
}
# sealed_env <name> [metadata]...: a machine at the seal: compiled files, their manifest and the two baselines
sealed_env() {
  new_env "$@"; s_spot_resume >/dev/null || exit 1
  mkmod P/A; mkmod P/B
  lib_manifest > "$PD/lib_sha256.txt"; pkgs_manifest > "$PD/baseline_pkgs.txt"; tc_manifest /opt/lean-tc > "$PD/baseline_tc.txt"
  mkdir -p "$AN/kernel_replay"
  printf 'module\tstatus\tseconds\tstamp\tepoch\ttool\tprogram_sha256\thow\n' > "$AN/kernel_replay/results.tsv"
}
res_line() { printf '%s\t%s\t1\tstamp\t1\tleanchecker\t-\timport-closure-directory\n' "$1" "$2" >> "$AN/kernel_replay/results.tsv"; }

# ---------------------------------------------------------------- the cases
case_extract() { # the extracted code loads, and holds the functions the cases call
  new_env x
  local f missing=""
  for f in spot_state spot_record spot_load spot_fetch spot_fetch_checked spot_pause spot_reclaimed spot_watch_preempted spot_confirm \
           spot_ckpt_round spot_apply_pending spot_lake_n spot_put_lake_logs spot_results_round s_spot_resume s_spot_baselines spot_restore_all \
           spot_cover spot_ckpt_final finish t_step write_facts lib_manifest built_in_log reboot_branch idle_until_deleted \
           spot_lake_copies failed_lines spot_timebox_saved spot_results_restore spot_parts_arg; do
    declare -F "$f" >/dev/null || missing="$missing $f"
  done
  ok "every function the cases call is defined" [ -z "$missing" ]
  ok "the metadata is read through the fake metadata server (attempt, bucket, runtag)" [ "$SPOT/$ATTEMPT/$BUCKET/$RUNTAG" = 1/1/testbucket/full-spot-test ]
  ok "the Spot paths are set as in the file (state, checkpoint prefix, this attempt's results)" [ "$CK|$RES|$RT" = "ckpt/full-spot-test|results/full-spot-test/attempt-1|results/full-spot-test" ]
  ok "the Spot status() is the one in effect" grep -q '"spot": 1' <(declare -f status)
  ok "...and so is the Spot failed_lines (it reads root's copies)" grep -q 'spot_lake_copies' <(declare -f failed_lines)
  echo hi > "$PD/x"
  gcs_put "$PD/x" "ckpt/t/x" && spot_fetch "ckpt/t/x" "$PD/y"; local rc=$?
  ok "...gcs_put then spot_fetch: status 0, same bytes" [ "$rc" = 0 ]
  ok "...same bytes" cmp -s "$PD/x" "$PD/y"
  spot_fetch "ckpt/t/none" "$PD/z"; rc=$?
  { [ "$rc/$([ -e "$PD/z" ] && echo f)" = 4/ ]; }; okc "...spot_fetch of an object that is not there: status 4, no file"
}

case_fixture() { # attempt 1 of a run: a fresh state, its baselines, and two parts (later cases restore from these)
  new_env a1
  s_spot_resume; local rc=$?
  ok "s_spot_resume on a fresh run: status 0" [ "$rc" = 0 ]
  ok "...the bucket's manifest is the bare header" [ "$(cat "$(bk "$CK/manifest.tsv")")" = "$HDR" ]
  ok "...the state names the run, stage build, attempt 1 in the metadata's zone" jstate 'd["runtag"] == "full-spot-test" and d["stage"] == "build" and d["attempts"][0]["n"] == 1 and d["attempts"][0]["zone"] == "fake-zone-a"'
  for f in src tc pkgs; do echo "baseline $f of the first attempt" > "$PD/baseline_$f.txt"; done
  s_spot_baselines; rc=$?
  { [ "$rc/$(has "$CK/baseline_src.txt.gz" && has "$CK/baseline_tc.txt.gz" && has "$CK/baseline_pkgs.txt.gz" && echo y)" = 0/y ]; }; okc "s_spot_baselines on the first attempt: status 0, the three baselines uploaded"
  ok "...their SHA-256 recorded in the state" jstate "d['vars']['BASE_TC_SHA'] == '$(shaf "$PD/baseline_tc.txt")'"
  mkmod P/A; mkmod P/B
  spot_ckpt_round loop >/dev/null; rc=$?
  mkmod P/C
  spot_ckpt_round loop >/dev/null; local rc2=$?
  ok "two part rounds: status 0 both" [ "$rc/$rc2" = 0/0 ]
  ok "...the manifest lists parts 1 and 2, with 2 and 1 modules, by attempt 1" [ "$(awk -F'\t' 'NR > 1 {printf "%s:%s:%s ", $1, $5, $7}' "$(bk "$CK/manifest.tsv")")" = "1:2:1 2:1:1 " ]
  ok "...the state counts 3 modules saved" jstate 'd["parts_modules"] == 3 and d["progress"] >= 3'
  mkdir -p "$TMPD/fixture" && cp -Rp "$SPOTTEST_FAKE/bucket" "$TMPD/fixture/bucket" && cp -Rp "$PROJ/.lake/build" "$TMPD/fixture/build" \
    && cp "$PD"/baseline_*.txt "$TMPD/fixture/" || exit 1
  printf 'FX_STATE=%s\nFX_MAN=%s\n' "$(shaf "$(bk "$CK/state.json")")" "$(shaf "$(bk "$CK/manifest.tsv")")" > "$TMPD/fixture/shas"
}

case_rounds() { # case 1: a part round
  new_env r1; s_spot_resume >/dev/null
  local rc d="$SPD/done.txt" f bad
  mkmod P/A; mkmod P/B
  ops_mark; spot_ckpt_round loop >/dev/null; rc=$?
  ok "a round with two finished modules: status 0" [ "$rc" = 0 ]
  { [ "$(ops_since | awk '$1 == "PUT" && $2 ~ /^ckpt\// {printf "%s ", $2}')" = "$CK/part-000001.tar.zst $CK/manifest.tsv $CK/state.json " ]; }; okc "...uploads in the order part, manifest, state"
  ok "...the cut ran as the build user, with the archive on its standard output" grep -q -- '-u pilot -- bash .*spot_checkpoint.sh cut .*--out -' "$SPOTTEST_FAKE/runuser.log"
  ok "...the done list holds the part's 14 files, and the sequence number is 1" [ "$(nl_ "$d")/$(cat "$SPD/seq")" = 14/1 ]
  bad=$(while IFS=$'\t' read -r f s m h; do [ "$(shaf "$PROJ/.lake/build/$f")" = "$h" ] || echo "$f"; done < "$d")
  { [ "$(awk -F'\t' 'NF != 4' "$d" | wc -l)" = 0 ] && [ -z "$bad" ]; }; okc "...each done line has four columns, the fourth the SHA-256 of the file as archived"
  bad=$(gzip -dc "$SPD/members/1.gz" | while read -r h f; do [ "$(shaf "$PROJ/.lake/build/$f")" = "$h" ] || echo "$f"; done)
  ok "...root's members file of the part has the SHA-256 of each of its 14 files" [ "$(gzip -dc "$SPD/members/1.gz" | wc -l)/$bad" = 14/ ]
  # a manifest upload that fails: nothing counts as saved; the next round uploads the same manifest
  mkmod P/C; cp "$d" "$CD/done.before"
  rule put "$CK/manifest.tsv" fail 5
  spot_ckpt_round loop >/dev/null; rc=$?
  ok "a round whose manifest upload fails: status 1" [ "$rc" = 1 ]
  ok "...the done list is left alone" cmp -s "$d" "$CD/done.before"
  { [ "$(has "$CK/part-000002.tar.zst" && echo y)/$(seqs)" = "y/1 " ]; }; okc "...the part is in the bucket, the bucket's manifest still lists one part"
  { [ -e "$SPD/manifest.new" ] && [ -e "$SPD/pending.sha" ]; }; okc "...the new manifest and the pending files wait for the next round"
  cp "$SPD/manifest.new" "$CD/manifest.2"
  ops_mark; spot_ckpt_round loop >/dev/null; rc=$?
  { [ "$rc/$(ops_since | awk '$1 == "PUT" && $2 ~ /^ckpt\// {printf "%s ", $2}')" = "3/$CK/manifest.tsv $CK/state.json " ]; }; okc "the next round: uploads that same manifest, then the state, and has nothing new to cut (status 3)"
  ok "...the bucket's manifest is that manifest" cmp -s "$(bk "$CK/manifest.tsv")" "$CD/manifest.2"
  ok "...and only now the done list holds the second part's files" [ "$(nl_ "$d")" = 21 ]
  # a part upload that fails: its number is never used again
  mkmod P/D; rule put "$CK/part-*" fail 5
  spot_ckpt_round loop >/dev/null; rc=$?
  { [ "$rc/$(cat "$SPD/seq")/$(has "$CK/part-000003.tar.zst" && echo y)" = 1/3/ ]; }; okc "a round whose part upload fails: status 1, number 3 used up, no part 3 in the bucket"
  spot_ckpt_round loop >/dev/null; rc=$?
  { [ "$rc/$(seqs)/$(has "$CK/part-000004.tar.zst" && echo y)" = "0/1 2 4 /y" ]; }; okc "...the next round saves it as part 4: the manifest lists 1 2 4"
  # G5.1: a round cut off after the manifest went up and was moved into place leaves only pending files
  sha256sum < "$SPD/manifest.tsv" | cut -d' ' -f1 > "$SPD/pending.sha"
  printf 'lib/lean/P/Ghost.olean\t1\t1\n' > "$SPD/pending.list"; echo 99 > "$SPD/pending.seq"; echo 1 > "$SPD/pending.t"
  mkmod P/E
  spot_ckpt_round loop >/dev/null; rc=$?
  ok "pending files of a manifest already applied: cleared, and the round carries on (part 5 saved)" [ "$rc/$(seqs)" = "0/1 2 4 5 " ]
  { [ ! -e "$SPD/pending.list" ] && not grep -q Ghost "$d"; }; okc "...nothing of them reaches the done list, and none is left"
  ok "...spot.log says so" grep -q 'pending part already applied' "$PD/spot.log"
  echo "$ZEROS" > "$SPD/pending.sha"; printf 'lib/lean/P/Ghost.olean\t1\t1\n' > "$SPD/pending.list"
  spot_ckpt_round loop >/dev/null; rc=$?
  { [ "$rc/$([ -e "$SPD/pending.sha" ] && echo left)" = 3/ ] && grep -q 'WARNING: pending files' "$PD/spot.log"; }; okc "pending files of some other manifest: cleared with a warning, nothing due (status 3)"
  ok "the sequence numbers in the bucket's manifest only ever go up" [ "$(seqs)" = "1 2 4 5 " ]
  # G2: what an attempt cut without notice would lose. The part loop's shell was started before the build tool,
  # so its LAKE_N is 0; the build tool's two logs are in the build user's directory (the second a link).
  mkdir -p "$LOGS"; printf 'ok\n✖ [3/9] Building P.X\nerror\n✖ [4/9] Building P.Y\n' > "$LOGS/lake_build_1.log"
  echo "a secret of root's" > "$CD/secret"; ln -s "$CD/secret" "$LOGS/lake_build_2.log"
  LAKE_N=0; mkmod P/F; ops_mark
  spot_ckpt_round loop >/dev/null; rc=$?
  { [ "$rc" = 0 ] && jstate '[a for a in d["attempts"] if a["n"] == 1][0]["failed_job_lines"] == 2'; }; okc "a part round records this attempt's failed job lines in its state entry (2, from a log the loop's shell did not know of)"
  { has "$RES/logs/lake_build_1.log.gz" && gzip -dc "$(bk "$RES/logs/lake_build_1.log.gz")" | cmp -s - "$LOGS/lake_build_1.log"; }; okc "...and uploads the build tool's log so far, compressed, under the name put_logs gives it"
  { [ "$(ops_since | awk '$1 == "PUT" {print $2}' | grep -e '/part-' -e 'logs/lake_build_1' -e "$CK/manifest.tsv" -e "$CK/state.json" | tr '\n' ' ')" = "$CK/part-000006.tar.zst $RES/logs/lake_build_1.log.gz $CK/manifest.tsv $CK/state.json " ]; }; okc "...right after the part, before the manifest and the state (part, logs, manifest, state)"
  ok "...a log that is a link is not read" not has "$RES/logs/lake_build_2.log.gz"
  mkmod P/G; rule put "$RES/logs/lake_build_1.log.gz" fail 1
  spot_ckpt_round loop >/dev/null; rc=$?
  { [ "$rc/$(seqs)" = "0/1 2 4 5 6 7 " ] && grep -q 'WARNING: the build log lake_build_1.log was not uploaded' "$PD/spot.log"; }; okc "...a log upload that fails is noted in spot.log and does not fail the round"
  # G3: a saved file the build tool wrote again with the same bytes (a new time only)
  touch -t 202101010000 "$LIB/P/A.olean"; ops_mark
  spot_ckpt_round loop >/dev/null; rc=$?
  { [ "$rc" = 0 ] && [ "$(zstd -q -d -c "$(bk "$CK/part-000008.tar.zst")" | tar -tf -)" = lib/lean/P/A.olean ]; }; okc "a saved .olean written again with the same bytes: saved again in the next part, alone (not status 4)"
  { grep -q 'part 8 (loop): 0 modules, 1 files, .* 1 files written again with the same bytes' "$PD/spot.log" && jstate 'd["files_rewritten_same_bytes"] == 1'; }; okc "...spot.log gives the count for the part, and the state adds it up"
  touch -t 202102010000 "$LIB/P/A.olean" "$LIB/P/B.trace"
  spot_ckpt_round loop >/dev/null; rc=$?
  ok "...a second such part: the state's total is 3" [ "$rc/$(jtrue "$(bk "$CK/state.json")" 'd["files_rewritten_same_bytes"] == 3' && echo y)" = 0/y ]
  write_facts RUNNING "a test"
  ok "...and facts.json's spot block shows the total, and says what the per-attempt files are" jtrue "$PD/facts.json" 'd["spot"]["files_rewritten_same_bytes"] == 3 and d["spot"]["per_attempt_files"].startswith("files under attempt-N/ are that machine")'
  echo "other bytes" > "$LIB/P/A.ilean"; touch -t 202103010000 "$LIB/P/A.ilean"
  spot_ckpt_round loop >/dev/null; rc=$?
  ok "...but a saved file with other bytes is a module compiled again (status 4)" [ "$rc" = 4 ]
}

case_resume() { # case 2: s_spot_resume on a later attempt
  local rc m f
  fixture_env ok; cp "$TMPD/fixture"/baseline_*.txt "$PD/"
  s_spot_resume >/dev/null; rc=$?
  ok "attempt 2 with the state and manifest the controller saw: status 0" [ "$rc" = 0 ]
  ok "...attempt 1 closed as cut without notice, attempt 2 recorded in its zone" jstate 'd["attempts"][0]["ended"] == "no report: cut without notice" and d["attempts"][1]["n"] == 2 and d["attempts"][1]["zone"] == "fake-zone-a"'
  ok "...the last part number used is 2, the done list starts empty, the build is not skipped" [ "$(cat "$SPD/seq")/$(nl_ "$SPD/done.txt")/$SKIP_BUILD/$SEAL_DONE" = 2/0/0/0 ]
  s_spot_baselines >/dev/null; rc=$?
  { [ "$rc" = 0 ] && jstate 'd["attempts"][1]["baselines_same"] is True'; }; okc "...s_spot_baselines: this machine's baselines equal the first attempt's (status 0, recorded)"
  echo "another toolchain" > "$PD/baseline_tc.txt"
  ends s_spot_baselines
  { [ "$RC" = 77 ] && jstatus 'd["state"] == "FAIL" and "differ from the first attempt" in d["message"]'; }; okc "...a toolchain that differs from the first attempt's: the run FAILs"
  fixture_env badsha "full-state-sha=$ZEROS"
  m=$(s_spot_resume); rc=$?
  { [ "$rc" = 1 ] && [ "$m" = "the run's state is not the one the controller saw" ]; }; okc "a state whose SHA-256 is not the one the controller saw: setup fails (status 1)"
  ok "...after three complete downloads" [ "$(gets "$CK/state.json")" = 3 ]
  for f in "$CK/part-000009.tar.zst" "ckpt/another-run/part-000002.tar.zst"; do
    awk -F'\t' -v OFS='\t' -v f="$f" 'NR == 3 {$2 = f} {print}' "$TMPD/fixture/bucket/$CK/manifest.tsv" > "$CD/forged.tsv"
    fixture_env "forged$(echo "$f" | tr -c 'a-z0-9' _)" "full-manifest-sha=$(shaf "$CD/forged.tsv")"
    cp "$CD/forged.tsv" "$(bk "$CK/manifest.tsv")"
    m=$(s_spot_resume); rc=$?
    { [ "$rc" = 1 ] && [ "$m" = "the run's manifest is malformed" ]; }; okc "a manifest row naming $f: setup fails as malformed"
  done
  fixture_env trunc1; rule get "$CK/state.json" truncate 1
  s_spot_resume >/dev/null; rc=$?
  ok "a download of the state cut short once: fetched again, and setup goes on (status 0)" [ "$rc/$(gets "$CK/state.json")" = 0/2 ]
  fixture_env trunc3; rule get "$CK/state.json" truncate 3
  ends s_spot_resume
  { [ "$RC" = 77 ] && jstatus 'd["state"] == "PAUSED" and "could not fetch the run" in d["message"] and d["pause"] == "retry"'; }; okc "a download of the state cut short three times: the attempt PAUSES (kind retry), the run is not failed"
  ok "...and the state in the bucket is untouched" cmp -s "$(bk "$CK/state.json")" "$TMPD/fixture/bucket/$CK/state.json"
  fixture_env nosha "full-state-sha="
  ends s_spot_resume
  { [ "$RC" = 77 ] && jstatus 'd["state"] == "PAUSED" and "a state exists that the controller did not see" in d["message"] and d["pause"] == "stop"'; }; okc "no state SHA-256 from the controller, but a state in the bucket: PAUSED, of kind stop"
  { cmp -s "$(bk "$CK/manifest.tsv")" "$TMPD/fixture/bucket/$CK/manifest.tsv" && cmp -s "$(bk "$CK/state.json")" "$TMPD/fixture/bucket/$CK/state.json"; }; okc "...and neither the manifest nor the state is overwritten"
  fixture_env nosha2 "full-state-sha="; rule get "$CK/state.json" fail 1
  ends s_spot_resume
  { [ "$RC" = 77 ] && jstatus 'd["state"] == "PAUSED" and "could not find out" in d["message"]' && cmp -s "$(bk "$CK/manifest.tsv")" "$TMPD/fixture/bucket/$CK/manifest.tsv"; }; okc "no state SHA-256 and the look for a state fails: PAUSED, the manifest untouched"
}

case_restore() { # case 3: spot_restore_all on real parts
  local rc
  fixture_env good; mkdir -p "$PROJ/.lake"
  s_spot_resume >/dev/null && s_spot_restore; rc=$?
  ok "restoring the two parts before the seal: status 0" [ "$rc" = 0 ]
  { [ "$(tr '\n' ' ' < "$SPD/restored.txt")" = "P.A P.B P.C " ] && jstate 'd["attempts"][1]["restore"]["modules"] == 3 and d["attempts"][1]["restore"]["parts"] == 2'; }; okc "...the count check passes: 3 modules, from the parts' own lists"
  ok "...every file is back byte for byte" [ "$(treesum "$PROJ/.lake/build")" = "$(treesum "$TMPD/fixture/build")" ]
  { [ ! -s "$SPD/restore_check.txt" ] && [ "$(nl_ "$SPD/done.txt")" = 21 ]; }; okc "...the check afterwards finds nothing changed or unsaved"
  { grep -q -- '-u pilot -- bash .*spot_checkpoint.sh restore' "$SPOTTEST_FAKE/runuser.log" && [ -s "$SPD/members/1.gz" ] && [ -s "$SPD/members/2.gz" ]; }; okc "...it was extracted by the build user, and root kept a members file per part"
  fixture_env bad1; mkdir -p "$PROJ/.lake"; rule get "$CK/part-000001.tar.zst" corrupt 1
  s_spot_resume >/dev/null && s_spot_restore; rc=$?
  { [ "$rc/$(gets "$CK/part-000001.tar.zst")" = 0/2 ] && grep -q 'part-000001.tar.zst: download 1 has sha256' "$PD/spot.log"; }; okc "a part with the wrong checksum on the first fetch and the right one on the second: restored (status 0)"
  fixture_env bad3; mkdir -p "$PROJ/.lake"; rule get "$CK/part-000001.tar.zst" corrupt 3
  s_spot_resume >/dev/null; ends s_spot_restore
  { [ "$RC" = 77 ] && jstatus 'd["state"] == "FAIL" and "does not match the checksum" in d["message"]'; }; okc "three complete downloads of the right size, every one with the wrong checksum: the run FAILs"
  fixture_env trunc3; mkdir -p "$PROJ/.lake"; rule get "$CK/part-000002.tar.zst" truncate 3
  s_spot_resume >/dev/null; ends s_spot_restore
  { [ "$RC" = 77 ] && jstatus 'd["state"] == "PAUSED" and "could not fetch" in d["message"]'; }; okc "three downloads of a part cut short: the attempt PAUSES, the run is not failed"
  fixture_env root; mkdir -p "$PROJ/.lake"; : > "$SPOTTEST_FAKE/runuser.log"
  s_spot_resume >/dev/null && spot_after_seal_restore >/dev/null; rc=$?
  [ -n "${GUARD_PID:-}" ] && kill "$GUARD_PID" 2>/dev/null
  { [ "$rc" = 0 ] && grep -q 'usermod -L -s /usr/sbin/nologin pilot' "$SPOTTEST_FAKE/root.log"; }; okc "after the seal: the build user locked first, then root restores the parts (status 0)"
  { [ "$(treesum "$PROJ/.lake/build")" = "$(treesum "$TMPD/fixture/build")" ] && not grep -q restore "$SPOTTEST_FAKE/runuser.log" && [ ! -s "$SPD/restore_check.txt" ]; }; okc "...every file back byte for byte, nothing run as the build user, the check clean"
}

case_record() { # case 4: spot_record and spot_load
  new_env k; s_spot_resume >/dev/null
  local rc want sha
  C3_RATE="it's 1.5 \"modules\" a second; \$HOME \`id\` and spaces"; CHECK_JOBS=24; want=$C3_RATE
  spot_record - - C3_RATE CHECK_JOBS; rc=$?
  ok "spot_record of two variables: status 0" [ "$rc" = 0 ]
  C3_RATE=""; CHECK_JOBS=""
  spot_load; rc=$?
  { [ "$rc" = 0 ] && [ "$C3_RATE" = "$want" ] && [ "$CHECK_JOBS" = 24 ]; }; okc "spot_load gives them back exactly, quotes, spaces and all"
  C3_RATE=""; spot_load C3_RATE
  ok "spot_load of one name" [ "$C3_RATE" = "$want" ]
  C2_PLAIN_RC=0; spot_record c2_plain c2 C2_PLAIN_RC; rc=$?
  { [ "$rc" = 0 ] && spot_done c2_plain && jstate 'd["stage"] == "c2" and "c2_plain" in d["done"]'; }; okc "spot_record of a unit: recorded as done, with the stage"
  sha=$(shaf "$(bk "$CK/state.json")")
  touch "$PD/PREEMPTED"; CHECK_JOBS=8; spot_record trials c3 CHECK_JOBS; rc=$?
  { [ "$rc" = 1 ] && not spot_done trials && [ "$(shaf "$(bk "$CK/state.json")")" = "$sha" ]; }; okc "spot_record once PREEMPTED exists: refused (status 1), nothing recorded or uploaded"
  rm -f "$PD/PREEMPTED"; touch "$PD/DEADLINE"; spot_record trials c3 CHECK_JOBS; rc=$?
  { [ "$rc" = 1 ] && not spot_done trials && [ "$(shaf "$(bk "$CK/state.json")")" = "$sha" ]; }; okc "spot_record once DEADLINE exists: refused (status 1), nothing recorded or uploaded"
  rm -f "$PD/DEADLINE"
}

case_confirm() { # case 5: spot_confirm and the results it lets through
  local rc n
  sealed_env c
  spot_confirm 4; rc=$?
  ok "an unchanged tree confirms (status 0, one confirm counted)" [ "$rc/$(cat "$SPD/confirms")" = 0/1 ]
  # three results and a fourth half-written; while the confirm hashes, the replay finishes writing the fourth,
  # which must then wait for the next round (the harness's hook in lib_manifest does the writing)
  res_line P.A 0; res_line P.B 0; res_line P.C 0; printf 'P.D\t0\t1\tst' >> "$AN/kernel_replay/results.tsv"
  eval "harness_real_$(declare -f lib_manifest)"
  lib_manifest() { if [ ! -e "$CD/hooked" ]; then touch "$CD/hooked"; printf 'amp\t1\tleanchecker\t-\timport-closure-directory\n' >> "$AN/kernel_replay/results.tsv"; fi; harness_real_lib_manifest; }
  ops_mark; spot_results_round 4; rc=$?
  { [ "$rc/$(gzip -dc "$(bk "$CK/results/000000003.tsv.gz")" | wc -l)" = 0/4 ] && jstate 'd["results_saved"] == 3'; }; okc "a results round: status 0; it uploads only the 3 whole lines its copy held before the confirm"
  { jstate "d['results_object'] == '$CK/results/000000003.tsv.gz' and d['results_sha256'] == '$(shaf "$(bk "$CK/results/000000003.tsv.gz")")'" && not has "$CK/results.tsv.gz"; }; okc "...as $CK/results/000000003.tsv.gz, its name and the SHA-256 of the compressed file in the state; nothing under the old name"
  ok "...the copy was taken first and confirmed before it went up" [ "$(grep -n 'confirm: as sealed' "$PD/spot.log" | tail -1 | cut -d: -f1)" -lt "$(grep -n 'results: 3 lines confirmed' "$PD/spot.log" | cut -d: -f1)" ]
  # the results loop: a pass waits for the next round; a rejection goes up at once
  spot_res_loop_start; sleep 100                  # the shim makes this two seconds: about ten of the loop's polls
  res_line P.E 0; sleep 100
  ok "the results loop: a new pass does not start a round" jstate 'd["results_saved"] == 3'
  res_line P.F 1
  n=0; while [ "$n" -lt 75 ] && ! jstate 'd["results_saved"] == 6'; do /bin/sleep 0.2; n=$((n + 1)); done
  { jstate 'd["results_saved"] == 6' && grep -q 'a rejection, crash or damaged line' "$PD/spot.log"; }; okc "...a new rejection starts a confirmed upload at once"
  spot_res_loop_stop; rc=$?
  { [ "$rc" = 0 ] && [ "$(tail -1 "$PD/spot.log" | grep -c 'results:\|confirm: as sealed')" = 1 ]; }; okc "...stopping it ends with one more confirmed round (status 0)"
  # a reclaim uploads no results
  res_line P.G 0; ops_mark
  ends spot_reclaimed "a test"
  { [ "$RC" = 77 ] && jstatus 'd["state"] == "RECLAIMED"' && ! ops_since | grep -q "$CK/results"; }; okc "spot_reclaimed: RECLAIMED goes out, and no results are uploaded"
  ok "...the state says the attempt was reclaimed" jstate 'd["attempts"][0]["ended"] == "RECLAIMED"'
  rm -f "$PD/PREEMPTED" "$PD/FINISHING" "$PD/RECLAIM_SENT"
  # a compiled file changed: the run fails, and stays failed with a deadline marker present
  echo "other bytes" > "$LIB/P/A.olean"; ops_mark
  spot_results_round 4; rc=$?
  { [ "$rc" = 2 ] && ! ops_since | grep -q "$CK/results" && [ -e "$PD/FAIL_IS_FINAL" ]; }; okc "a compiled file changed: the confirm says so (status 2) and nothing is uploaded"
  ok "...the difference is uploaded beside this attempt's logs" has "$RES/changed_confirm_lib.txt"
  touch "$PD/DEADLINE"
  ends deadline_check
  { [ "$RC" = 77 ] && jstatus 'd["state"] == "FAIL" and "changed while the checks ran" in d["message"]'; }; okc "...with a DEADLINE marker present, the run still ends FAIL, never PAUSED"
  ok "...and the state says the run is over, FAILed" jstate 'd["final"] is True and d["outcome"] == "FAIL"'
  # a sighting of the build user
  sealed_env c2; touch "$PD/build_user_seen_after_seal"
  ends spot_confirmed 4
  { [ "$RC" = 77 ] && jstatus 'd["state"] == "FAIL" and "build user appeared after the seal" in d["message"]' && jstate 'd["final"] is True'; }; okc "a process of the build user seen after the seal: the confirm ends the run FAIL"
  # a confirm that cannot be completed concludes nothing
  sealed_env c3; touch "$PD/DEADLINE"
  spot_confirm 4; rc=$?
  { [ "$rc" = 1 ] && [ ! -e "$PD/HARD_FAIL_MSG" ]; }; okc "a confirm while the deadline has begun: abandoned (status 1), nothing concluded"
}

case_cover() { # case 6: the cover check at the first seal
  local rc
  sealed_env eq; spot_ckpt_round loop >/dev/null
  lib_manifest > "$PD/lib_sha256.txt"; echo "a seal file" > "$PD/seal_src.txt"
  spot_seal_manifest >/dev/null; rc=$?
  { [ "$rc" = 0 ] && jstate 'd["parts_cover_seal"] is True and d["parts_cover_repair_files"] == 0' && [ "$(seqs)" = "1 " ]; }; okc "the parts reproduce the sealed files: passes, recorded, no repair"
  { has "$CK/seal/lib_sha256.txt.gz" && has "$CK/seal/seal_src.txt.gz"; }; okc "...the seal's manifests go up"
  sealed_env fix; spot_ckpt_round loop >/dev/null
  echo "rewritten after its part" > "$LIB/P/A.olean"; echo "written after its part" > "$LIB/P/B.olean.hash"
  lib_manifest > "$PD/lib_sha256.txt"
  spot_seal_manifest >/dev/null; rc=$?
  { [ "$rc/$(seqs)" = "0/1 2 " ] && jstate 'd["parts_cover_seal"] is True and d["parts_cover_repair_files"] == 2'; }; okc "files changed after their part: repaired by one more part, then equal (2 files)"
  { [ "$(gzip -dc "$SPD/members/2.gz" | cut -c67- | tr '\n' ' ')" = "lib/lean/P/A.olean lib/lean/P/B.olean.hash " ] && [ "$(grep -c 'spot_checkpoint.sh cut' "$SPOTTEST_FAKE/runuser.log")" = 1 ]; }; okc "...the repair part was cut by root, holding exactly those files"
  mkdir -p "$CD/fix_restore/b"
  for n in 1 2; do bash "$SPK" restore --build-dir "$CD/fix_restore/b" --part "$(bk "$(printf '%s/part-%06d.tar.zst' "$CK" "$n")")" \
    --sha256 "$(awk -F'\t' -v n="$n" '$1 == n {print $3}' "$(bk "$CK/manifest.tsv")")" 2>/dev/null; done
  { [ "$(cd "$CD/fix_restore/b/lib/lean" && lib_manifest_of .)" = "$(cat "$PD/lib_sha256.txt")" ]; }; okc "...and the two parts, restored in order, reproduce the sealed lib/lean exactly"
  sealed_env extra; spot_ckpt_round loop >/dev/null
  rm -f "$LIB/P/B.ilean.hash"; lib_manifest > "$PD/lib_sha256.txt"
  ends spot_seal_manifest
  { [ "$RC" = 77 ] && jstatus 'd["state"] == "FAIL" and "did not find" in d["message"]' && has "$RES/parts_cover.txt"; }; okc "a part holds a file the seal did not find: the run FAILs"
}
lib_manifest_of() { ( NMAX=2; manifest . ); }

case_status() { # case 7: status JSON in a Spot run
  new_env s full-attempt=3; s_spot_resume >/dev/null
  status build RUNNING "hello"
  ok "status carries the attempt and spot, and goes to the run's status.json" jstatus 'd["attempt"] == 3 and d["spot"] == 1 and d["state"] == "RUNNING" and d["phase"] == "build"'
  touch "$PD/PREEMPTED"
  status build RUNNING "later"; status build PAUSED "paused"; status build FAIL "an ordinary failure"
  ok "after PREEMPTED, RUNNING, PAUSED and an ordinary FAIL do not go out" jstatus 'd["message"] == "hello"'
  status build RECLAIMED "bye"
  ok "...RECLAIMED does, with the attempt" jstatus 'd["state"] == "RECLAIMED" and d["attempt"] == 3 and d["spot"] == 1'
  touch "$PD/FAIL_IS_FINAL"; status end FAIL "final"
  ok "...and so does a FAIL that ends the run whatever happens" jstatus 'd["state"] == "FAIL" and d["message"] == "final"'
  rm -f "$PD/PREEMPTED" "$PD/FAIL_IS_FINAL"
  touch "$PD/STARTED"; ends reboot_branch
  { [ "$RC" = 77 ] && jstatus 'd["phase"] == "reboot" and d["state"] == "RECLAIMED" and d["attempt"] == 3'; }; okc "the reboot branch: RECLAIMED, with the attempt"
  rm -f "$PD/STARTED"
  printf 'FALSE e1x\nTRUE e2y\n' > "$SPOTTEST_FAKE/preempt"
  trap 'echo TERM >> "$CD/term"' TERM
  ( spot_watch_preempted ) >/dev/null 2>&1
  trap - TERM
  ok "the preemption watcher: its first read waits for nothing, the next passes the ETag back" [ "$(grep '^MD preempted' "$SPOTTEST_FAKE/ops.log" | cut -d' ' -f3 | tr '\n' ' ')" = "- wait_for_change=true&timeout_sec=300&last_etag=e1x " ]
  { [ -e "$PD/PREEMPTED" ] && [ -e "$PD/RECLAIM_SENT" ] && [ -e "$CD/term" ] \
    && jstatus 'd["state"] == "RECLAIMED" and d["attempt"] == 3 and "Google took the machine back" in d["message"]' && jstate '[a for a in d["attempts"] if a["n"] == 3][0]["ended"] == "RECLAIMED"'; }; okc "...on TRUE: PREEMPTED, a TERM to the main script, RECLAIMED with the attempt, the state updated"
  # G4: an answer whose ETag cannot be passed back must not make the watcher ask again at once, over and over.
  # Sleeps here are a fifth of the time asked (5 s becomes 1 s), and the window is 3 s.
  rm -f "$PD/PREEMPTED" "$PD/RECLAIM_SENT"; printf 'FALSE "q1"\n' > "$SPOTTEST_FAKE/preempt"
  local n0 n1 wp; n0=$(grep -c '^MD preempted' "$SPOTTEST_FAKE/ops.log")
  ( SPOTTEST_SLEEP_SCALE=0.2; export SPOTTEST_SLEEP_SCALE; spot_watch_preempted ) >/dev/null 2>&1 & wp=$!
  /bin/sleep 3; kill "$wp" 2>/dev/null; pkill -P "$wp" 2>/dev/null; wait "$wp" 2>/dev/null
  n1=$(( $(grep -c '^MD preempted' "$SPOTTEST_FAKE/ops.log") - n0 ))
  { [ "$n1" -ge 1 ] && [ "$n1" -le 5 ] && not grep -q 'wait_for_change' <(tail -n "$n1" "$SPOTTEST_FAKE/ops.log"); }; okc "the watcher, given an unusable ETag: $n1 requests in 3 s (no more than 5), none waiting for a change"
  ok "...and spot.log says once that wait_for_change is not in use" [ "$(grep -c 'wait_for_change is not in use' "$PD/spot.log")" = 1 ]
}

case_kinds() { # K7: the kind of each pause, in the status (the launcher reads it) and in the attempt's state entry
  local k
  new_env pk; s_spot_resume >/dev/null
  ends spot_pause "trouble on the way"
  { [ "$RC" = 77 ] && jstatus 'd["state"] == "PAUSED" and d["pause"] == "retry" and d["message"].startswith("trouble on the way")' \
    && jstate 'd["attempts"][0]["ended"] == "PAUSED" and d["attempts"][0]["pause_kind"] == "retry"'; }; okc "spot_pause with no kind and no deadline marker: kind retry, in the status and the state"
  rm -f "$PD/FINISHING"; touch "$PD/DEADLINE"
  ends spot_pause "out of time"
  { [ "$RC" = 77 ] && jstatus 'd["pause"] == "deadline"' && jstate 'd["attempts"][0]["pause_kind"] == "deadline"'; }; okc "...with the deadline marker: kind deadline"
  rm -f "$PD/FINISHING" "$PD/DEADLINE"
  for k in stop parts-limit deadline; do
    ends spot_pause "a pause of kind $k" "$k"
    { [ "$RC" = 77 ] && jstatus "d['pause'] == '$k'" && jstate "d['attempts'][0]['pause_kind'] == '$k'"; }; okc "...given the kind $k: kind $k"
    rm -f "$PD/FINISHING"
  done
  ends finish DEADLINE "the build finished too close to the deadline to run any check"
  { [ "$RC" = 77 ] && jstatus 'd["state"] == "PAUSED" and d["pause"] == "deadline"'; }; okc "finish DEADLINE without the deadline marker: PAUSED of kind deadline"
  rm -f "$PD/FINISHING" "$PD/STOPPING"
  status c3 PAUSED "by hand"; ok "the status of a PAUSED with no kind given says deadline" jstatus 'd["pause"] == "deadline"'
  for k in RUNNING RECLAIMED FAIL DONE; do status c3 "$k" "x" retry; ok "...a $k status has no pause field" jstatus "d['state'] == '$k' and 'pause' not in d"; done
}

case_setup() { # G1: a setup step that needs the network ends only the attempt; any other is final, as at HEAD
  local f
  new_env st1                                    # before the state exists: no STATE_READY, no $SPD, no loops
  ends t_step elan false
  { [ "$RC" = 77 ] && jstatus 'd["state"] == "PAUSED" and d["pause"] == "retry" and d["message"].startswith("setup step failed: elan; a fresh machine tries again")'; }; okc "elan fails before the state exists: the attempt PAUSES, kind retry"
  { grep -q "^elan	[0-9]*	FAILED$" "$PD/setup.tsv" && has "$RES/setup.tsv" && has "$RT/facts.json" && [ -e "$PD/IDLED" ] && not has "$CK/state.json"; }; okc "...setup.tsv, facts and the PAUSED status uploaded, then idle; no state written"
  for f in packages source; do
    new_env "st_$f"; ends t_step "$f" false
    { [ "$RC" = 77 ] && jstatus "d['state'] == 'PAUSED' and d['pause'] == 'retry' and d['message'].startswith('setup step failed: $f;')"; }; okc "...and so does $f"
  done
  new_env st2; s_spot_resume >/dev/null          # after the state exists
  ends t_step mathlib_cache false
  { [ "$RC" = 77 ] && jstatus 'd["state"] == "PAUSED" and d["pause"] == "retry" and "mathlib_cache" in d["message"]' \
    && jstate 'd["attempts"][0]["ended"] == "PAUSED" and d["attempts"][0]["pause_kind"] == "retry" and d["final"] is False'; }; okc "mathlib_cache fails after the state exists: PAUSED, kind retry, recorded in the state, the run not final"
  new_env st3; s_spot_resume >/dev/null
  ends t_step disk false
  { [ "$RC" = 77 ] && jstatus 'd["state"] == "FAIL" and d["message"] == "setup step failed: disk"' && jstate 'd["final"] is True'; }; okc "a step that needs no network (disk) fails: the run FAILs, as at HEAD"
  new_env st4; ( SPOT=0; t_step elan false ); RC=$?
  { [ "$RC" = 77 ] && jstatus 'd["state"] == "FAIL" and d["message"] == "setup step failed: elan"'; }; okc "with SPOT=0, elan failing ends the run FAIL, as at HEAD"
  new_env st5; t_step elan true; RC=$?
  ok "a step that succeeds: status 0, a line ok in setup.tsv" [ "$RC/$(grep -c "^elan	[0-9]*	ok$" "$PD/setup.tsv")" = 0/1 ]
}

case_smoke() { # G9: root reads only its own copy of the build user's smoke log
  new_env sm; s_spot_resume >/dev/null
  echo P.A > "$SPD/restored.txt"; C1_STATE=built
  if [ -e /tmp/smoke.log ]; then ok "(skipped: this Mac has a /tmp/smoke.log)" true; return 0; fi
  spot_ckpt_final >/dev/null; local rc=$?
  { [ "$rc" = 0 ] && grep -q 'no smoke log: /tmp/smoke.log could not be copied as a plain file' "$PD/spot.log" && jstate 'd["attempts"][0]["restored_modules_compiled_again"] == 0'; }; okc "no smoke log to copy: noted in spot.log, and the check of the restored modules goes on (none compiled again)"
}

case_parts_max() { # case 8: the parts size limit (K1)
  local rc
  new_env big full-parts-max-bytes=100; s_spot_resume >/dev/null
  { [ "$PARTS_MAX" = 100 ] && grep -q 'full-parts-max-bytes=100 ' "$PD/env.txt"; }; okc "full-parts-max-bytes is read and written to env.txt"
  mkmod P/A; ops_mark
  spot_ckpt_round loop >/dev/null; rc=$?
  { [ "$rc/$(cat "$SPD/seq")" = 5/0 ] && [ -e "$SPD/TOO_BIG" ] && ! ops_since | grep -q 'part-' && [ "$(cat "$(bk "$CK/manifest.tsv")")" = "$HDR" ]; }; okc "a part that would pass the limit: not uploaded (status 5), number not used, TOO_BIG"
  ends spot_build_check
  { [ "$RC" = 77 ] && jstatus 'd["state"] == "PAUSED" and "the size the cap test allows" in d["message"] and d["pause"] == "parts-limit"' \
    && jstate '[a for a in d["attempts"] if a["n"] == 1][0]["pause_kind"] == "parts-limit"'; }; okc "...the build check then PAUSES the attempt, saying why, of kind parts-limit (status and state)"
  rm -f "$SPD/TOO_BIG"; C1_STATE=built
  ends spot_ckpt_final
  { [ "$RC" = 77 ] && [ -e "$SPD/TOO_BIG" ] && ! ops | grep -q 'PUT ckpt/full-spot-test/part-' && jstatus 'd["pause"] == "parts-limit"'; }; okc "...and so does the last cut after the build (kind parts-limit)"
  new_env roomy full-parts-max-bytes=100000000 full-confirm-every=junk; s_spot_resume >/dev/null; mkmod P/A
  spot_ckpt_round loop >/dev/null; rc=$?
  ok "a limit with room: the part goes up; a confirm interval that is not a number falls back to 1200" [ "$rc/$CONFIRM_EVERY" = 0/1200 ]
}

case_signals() { # a check ended by a signal, and a saved module compiled again (G5.7, G5.3)
  local rc n
  new_env sig full-ckpt-every=1; s_spot_resume >/dev/null
  spot_check_cut 124 $(( $(now) + 100 )); rc=$?
  ok "timeout's own status 124 is a result" [ "$rc" = 0 ]
  spot_check_cut 137 $(( $(now) - 5 )); rc=$?
  ok "a kill after the check's own time limit is a result" [ "$rc" = 0 ]
  spot_check_cut 0 $(( $(now) + 100 )); rc=$?
  ok "status 0 is a result" [ "$rc" = 0 ]
  ends spot_check_cut 143 $(( $(now) + 100 ))
  { [ "$RC" = 77 ] && jstatus 'd["state"] == "PAUSED" and "ended by a signal (status 143)" in d["message"]'; }; okc "a TERM before the time limit: the attempt PAUSES, the unit unrecorded"
  touch "$PD/PREEMPTED"; ends spot_check_cut '' $(( $(now) + 100 ))
  { [ "$RC" = 77 ] && jstatus 'd["state"] == "RECLAIMED"'; }; okc "...and with PREEMPTED, it is RECLAIMED"
  rm -f "$PD/PREEMPTED" "$PD/FINISHING" "$PD/RECLAIM_SENT" "$PD/STOPPING"
  mkmod P/A
  spot_ckpt_loop_start
  n=0; while [ "$n" -lt 100 ] && ! has "$CK/part-000001.tar.zst"; do /bin/sleep 0.1; n=$((n + 1)); done
  /bin/sleep 1; echo "compiled again" >> "$LIB/P/A.olean"
  n=0; while [ "$n" -lt 100 ] && [ ! -e "$SPD/CHANGED" ]; do /bin/sleep 0.1; n=$((n + 1)); done
  { has "$CK/part-000001.tar.zst" && [ -e "$SPD/CHANGED" ]; }; okc "the part loop: saves the module, then sees it compiled again and marks CHANGED"
  ends spot_build_check
  { [ "$RC" = 77 ] && jstatus 'd["state"] == "FAIL" and "compiled again a module that was already saved" in d["message"]'; }; okc "...the build check then ends the run FAIL at once"
  spot_stop_loops
}

case_c2() { # the axiom checks' summaries are saved with a checksum, and a check is recorded only once confirmed (G5.6, G1)
  local rc
  sealed_env save; mkdir -p "$PD/c2"; echo '{"verdict": "no failures"}' > "$PD/c2/plain.json"; C2_PLAIN_RC=0
  spot_c2_save plain c2_plain c2 C2_PLAIN_RC >/dev/null; rc=$?
  { [ "$rc" = 0 ] && spot_done c2_plain && cmp -s "$PD/c2/plain.json" "$(bk "$CK/c2/plain.json")" \
    && jstate "d['vars']['C2_PLAIN_JSON_SHA'] == '$(shaf "$PD/c2/plain.json")' and d['vars']['C2_PLAIN_RC'] == '0'"; }; okc "spot_c2_save after a confirm: the summary goes up, its SHA-256 is recorded with the unit"
  cp "$PD/c2/plain.json" "$CD/plain.json"; rm -f "$PD/c2/plain.json"; C2_PLAIN_RC=""; C2_PLAIN_JSON_SHA=""
  spot_c2_reload plain C2_PLAIN_RC >/dev/null
  { [ "$C2_PLAIN_RC" = 0 ] && cmp -s "$PD/c2/plain.json" "$CD/plain.json"; }; okc "spot_c2_reload: the recorded result and the summary come back, checked"
  rule get "$CK/c2/plain.json" corrupt 3
  ends spot_c2_reload plain C2_PLAIN_RC
  { [ "$RC" = 77 ] && jstatus 'd["state"] == "FAIL" and "not the one recorded with it" in d["message"]'; }; okc "...a summary that is not the one recorded: the run FAILs"
  sealed_env late; mkdir -p "$PD/c2"; echo '{}' > "$PD/c2/deep.json"; C2_DEEP_RC=0; touch "$PD/DEADLINE"
  ends spot_c2_save deep c2_deep c3 C2_DEEP_RC C2_DEEP_WHEN
  { [ "$RC" = 77 ] && jstatus 'd["state"] == "PAUSED"' && not spot_done c2_deep && not has "$CK/c2/deep.json"; }; okc "a check that ends as the deadline begins: no confirm possible, the attempt PAUSES, the unit unrecorded"
}

case_cutoff() { # G1 (round 4): the part loop stopped between the manifest upload and the state write, then a pause
  local rc
  new_env co; s_spot_resume >/dev/null
  echo $(( $(now) - 100 )) > "$PD/build_t0"; mkmod P/A
  # the loop's shell is stopped as its state write begins: the part and the manifest are up, the state is not
  ( spot_state() { exit 9; }; spot_ckpt_round loop >/dev/null ); rc=$?
  { [ "$rc" = 9 ] && [ "$(seqs)" = "1 " ] && [ ! -e "$SPD/pending.sha" ] && jstate 'd["parts_modules"] == 0 and d["vars"].get("TIMEBOX_USED", "0") == "0"'; }; okc "a part loop stopped at its state write: part 1 in the bucket's manifest, the state does not count it"
  ok "...(this shell's own TIMEBOX_USED is still 0: the loop's shell is another)" [ "$TIMEBOX_USED" = 0 ]
  ends spot_pause "out of time" deadline
  { [ "$RC" = 77 ] && jstate 'd["parts_modules"] == 1 and d["progress"] >= 1 and d["attempts"][0]["ended"] == "PAUSED"'; }; okc "the pause's state write counts the part: parts_modules 1, progress at least 1"
  ok "...and the time box's saved build time from the manifest's cut time (about 95 s)" jstate 'int(d["vars"]["TIMEBOX_USED"]) >= 90 and int(d["vars"]["TIMEBOX_USED"]) <= 110'
  rm -f "$PD/FINISHING"; bash "$SPK" state --file "$SPS" --var TIMEBOX_USED=500
  ends spot_pause "out of time again" deadline
  { [ "$RC" = 77 ] && jstate 'd["vars"]["TIMEBOX_USED"] == "500" and d["parts_modules"] == 1'; }; okc "...a pause never lowers what the state holds (500 stays 500)"
  new_env co2                                    # before $SPD exists: nothing to count, and nothing fails
  ends spot_pause "trouble" retry
  ok "a pause before the state and \$SPD exist still pauses" jstatus 'd["state"] == "PAUSED" and d["pause"] == "retry"'
}

case_logs() { # G2 (round 4): root counts failed job lines, and reads Built lines, only from its own copies of the logs
  local wp n rc want
  new_env lg0; mkdir -p "$LOGS"; printf '✖ [1/2] Building P.X\n' > "$LOGS/lake_build_1.log"; LAKE_N=1
  { [ "$(failed_lines)" = 0 ] && [ ! -e "$SPD" ]; }; okc "before \$SPD exists, failed_lines prints 0 (and makes nothing)"
  new_env lg; s_spot_resume >/dev/null; mkdir -p "$LOGS"
  printf 'ok\n✖ [3/9] Building P.X\nerror\n✖ [4/9] Building P.Y\n' > "$LOGS/lake_build_1.log"
  mkfifo "$LOGS/lake_build_2.log"
  printf '✖ a\n✖ b\n✖ c\n' > "$CD/elsewhere.log"; ln -s "$CD/elsewhere.log" "$LOGS/lake_build_3.log"
  printf '✖ [9/9] Building P.Z\n✔ [1/2] Built P.A (1s)\n' > "$LOGS/lake_build_4.log"
  LAKE_N=4
  ( failed_lines > "$CD/count" ) & wp=$!
  n=0; while [ "$n" -lt 100 ] && kill -0 "$wp" 2>/dev/null; do /bin/sleep 0.1; n=$((n + 1)); done
  kill "$wp" 2>/dev/null; wait "$wp" 2>/dev/null
  want=$(( $(grep -c '^✖ ' "$LOGS/lake_build_1.log") + $(grep -c '^✖ ' "$LOGS/lake_build_4.log") ))
  { [ "$n" -lt 100 ] && [ "$(cat "$CD/count")" = 3 ] && [ "$want" = 3 ]; }; okc "a log that is a pipe or a link neither blocks failed_lines nor is counted; the count from the copies equals the count in place (3)"
  { [ -f "$SPD/lakelogs/lake_build_1.log" ] && [ -f "$SPD/lakelogs/lake_build_4.log" ] && [ ! -e "$SPD/lakelogs/lake_build_2.log" ] && [ ! -e "$SPD/lakelogs/lake_build_3.log" ] && cmp -s "$SPD/lakelogs/lake_build_1.log" "$LOGS/lake_build_1.log"; }; okc "...the copies are root's own, of the plain logs only"
  echo P.A > "$SPD/restored.txt"; C1_STATE=built
  ( ends spot_ckpt_final; echo "$RC" > "$CD/final_rc" ) & wp=$!
  n=0; while [ "$n" -lt 150 ] && kill -0 "$wp" 2>/dev/null; do /bin/sleep 0.1; n=$((n + 1)); done
  kill "$wp" 2>/dev/null; wait "$wp" 2>/dev/null
  { [ "$(cat "$CD/final_rc" 2>/dev/null)" = 77 ] && jstatus 'd["state"] == "FAIL" and "compiled again 1 of the modules restored" in d["message"]' && grep -qx P.A "$PD/restored_compiled_again.txt"; }; okc "spot_ckpt_final reads the Built lines from root's copies (a restored module built again is found), past a pipe and a link"
}

# results_env <name>: a machine of a later attempt, with the bucket and the state the results case saved
results_env() {
  new_env "$1"; mkdir -p "$SPD/members" "$AN"
  rm -rf "${SPOTTEST_FAKE:?}/bucket"; cp -Rp "$TMPD/results_fx/bucket" "$SPOTTEST_FAKE/bucket"; cp "$TMPD/results_fx/state.json" "$SPS"; touch "$PD/STATE_READY"
}
case_results() { # the lead's finding (round 4): the saved replay results carry a recorded SHA-256 between machines
  local rc o1 o2
  sealed_env rs
  res_line P.A 0; res_line P.B 0; res_line P.C 1
  spot_results_round 4; rc=$?
  res_line P.D 0; res_line P.E 0
  spot_results_round 4; local rc2=$?
  o1="$CK/results/000000003.tsv.gz"; o2="$CK/results/000000005.tsv.gz"
  { [ "$rc/$rc2" = 0/0 ] && has "$o1" && has "$o2" && not has "$CK/results.tsv.gz"; }; okc "two results rounds: each upload under its count of lines (000000003, 000000005), the older one left in place, nothing under the old name"
  ok "...the state names the newer object with the SHA-256 of its compressed bytes" jstate "d['results_saved'] == 5 and d['results_object'] == '$o2' and d['results_sha256'] == '$(shaf "$(bk "$o2")")'"
  write_facts RUNNING "a test"
  ok "...and facts.json's spot block shows them" jtrue "$PD/facts.json" "d['spot']['results_object'] == '$o2' and d['spot']['results_sha256'] == '$(shaf "$(bk "$o2")")'"
  mkdir -p "$TMPD/results_fx" && cp -Rp "$SPOTTEST_FAKE/bucket" "$TMPD/results_fx/bucket" && cp "$SPS" "$TMPD/results_fx/state.json" && cp "$AN/kernel_replay/results.tsv" "$TMPD/results_fx/results.tsv" || exit 1
  # a later machine restores them
  results_env rs_ok; ops_mark
  spot_results_restore >/dev/null; rc=$?
  { [ "$rc" = 0 ] && cmp -s "$AN/kernel_replay/results.tsv" "$TMPD/results_fx/results.tsv"; }; okc "a restore from the object and the SHA-256 the state names: status 0, the 5 results back exactly"
  { [ "$(ops_since | awk '$1 == "GET" {print $2}' | tr '\n' ' ')" = "$o2 " ]; }; okc "...it fetched only the object the state names, never the older one left in the bucket"
  results_env rs_bad; rule get "$o2" corrupt 3
  ends spot_results_restore
  { [ "$RC" = 77 ] && jstatus 'd["state"] == "FAIL" and "not the ones the state records (three complete downloads)" in d["message"]' && [ "$(gets "$o2")" = 3 ]; }; okc "three complete downloads, each with another SHA-256: the run FAILs"
  results_env rs_bad1; rule get "$o2" corrupt 1
  spot_results_restore >/dev/null; rc=$?
  ok "one damaged download, then a good one: restored (status 0)" [ "$rc/$(gets "$o2")" = 0/2 ]
  results_env rs_cut; rule get "$o2" truncate 3
  ends spot_results_restore
  { [ "$RC" = 77 ] && jstatus 'd["state"] == "PAUSED" and "could not fetch the saved replay results" in d["message"] and d["pause"] == "retry"'; }; okc "downloads cut short three times: the attempt PAUSES (kind retry), the run is not failed"
  results_env rs_gone; rm -f "$(bk "$o2")"
  ends spot_results_restore
  { [ "$RC" = 77 ] && jstatus 'd["state"] == "FAIL" and "are not in the bucket" in d["message"]'; }; okc "the object the state names is not in the bucket: the run FAILs"
  results_env rs_noname; bash "$SPK" state --file "$SPS" --set results_object=
  ends spot_results_restore
  { [ "$RC" = 77 ] && jstatus 'd["state"] == "FAIL" and "names no object" in d["message"]' && not grep -q '^GET ' "$SPOTTEST_FAKE/ops.log"; }; okc "results saved but no object named in the state: the run FAILs, nothing fetched"
  results_env rs_short; bash "$SPK" state --file "$SPS" --results-saved 9
  ends spot_results_restore
  { [ "$RC" = 77 ] && jstatus 'd["state"] == "PAUSED" and "fewer lines than the state records" in d["message"]'; }; okc "an object with fewer lines than the state records: the attempt PAUSES (the line-count check stays)"
}

fnow() { python3 -I -c 'import time; print("%.2f" % time.time())'; }
case_stall() { # B17 (round 5): a stalled build-log upload costs a part round at most one try of 120 s (scaled)
  local rc t b d lim
  new_env st; s_spot_resume >/dev/null; mkdir -p "$LOGS"; printf 'ok\n✖ [3/9] Building P.X\n' > "$LOGS/lake_build_1.log"; LAKE_N=0
  mkmod P/A; t=$(fnow); spot_ckpt_round loop >/dev/null; rc=$?; b=$(awk -v a="$t" -v z="$(fnow)" 'BEGIN {print z - a}')
  ok "a round whose log upload goes through: status 0" [ "$rc" = 0 ]
  mkmod P/B; rule put "$RES/logs/lake_build_1.log.gz" stall 5; ops_mark
  t=$(fnow); spot_ckpt_round loop >/dev/null; rc=$?; d=$(awk -v a="$t" -v z="$(fnow)" 'BEGIN {print z - a}')
  lim=$(awk -v f="$SPOTTEST_SLEEP_SCALE" 'BEGIN {print 120 * f}')
  { [ "$rc/$(seqs)" = "0/1 2 " ] && jstate 'd["parts_modules"] == 2'; }; okc "a round whose log upload stalls: status 0, and the manifest and the state still go up (2 parts, 2 modules)"
  { [ "$(ops_since | grep -c "^PUT-STALL $RES/logs/lake_build_1.log.gz$")" = 1 ] && grep -q "stall 4" "$SPOTTEST_FAKE/rules"; }; okc "...one try of the log, not five"
  { awk -v d="$d" -v b="$b" -v l="$lim" 'BEGIN {exit !(d - b >= l * 0.5 && d - b <= l + 2.5)}'; }; okc "...the stall cost the round about the limit, no more ($d s against $b s without it; limit $lim s scaled)"
  { [ "$(ops_since | awk '$1 ~ /^PUT/ {print $2}' | grep -e '/part-' -e 'logs/lake_build_1' -e "$CK/manifest.tsv" -e "$CK/state.json" | tr '\n' ' ')" = "$CK/part-000002.tar.zst $RES/logs/lake_build_1.log.gz $CK/manifest.tsv $CK/state.json " ]; }; okc "...in the order part, log, manifest, state"
  ok "...spot.log has the WARNING" grep -q 'WARNING: the build log lake_build_1.log was not uploaded with this part (one try, at most 120 s)' "$PD/spot.log"
}

case_reclaim_pm() { # B18 (round 5): the RECLAIMED state writes count a part whose own state write was cut off
  local rc
  new_env rp; s_spot_resume >/dev/null; mkmod P/A; mkmod P/B
  ( spot_state() { exit 9; }; spot_ckpt_round loop >/dev/null ); rc=$?
  { [ "$rc" = 9 ] && [ "$(seqs)" = "1 " ] && jstate 'd["parts_modules"] == 0'; }; okc "a part round cut off between its manifest upload and its state write: the state does not count the part"
  ends spot_reclaimed "a test"
  { [ "$RC" = 77 ] && jstate 'd["parts_modules"] == 2 and d["progress"] >= 2 and d["attempts"][0]["ended"] == "RECLAIMED"'; }; okc "spot_reclaimed's state write counts it: parts_modules 2, progress at least 2, the attempt RECLAIMED"
  new_env rw; s_spot_resume >/dev/null; mkmod P/A
  ( spot_state() { exit 9; }; spot_ckpt_round loop >/dev/null ); rc=$?
  printf 'TRUE e1\n' > "$SPOTTEST_FAKE/preempt"
  trap 'echo TERM >> "$CD/term"' TERM
  ( spot_watch_preempted ) >/dev/null 2>&1
  trap - TERM
  { [ "$rc" = 9 ] && [ -e "$PD/RECLAIM_SENT" ] && jstate 'd["parts_modules"] == 1 and d["attempts"][0]["ended"] == "RECLAIMED"'; }; okc "...and so does the preemption watcher's (parts_modules 1)"
  new_env rn; s_spot_resume >/dev/null; rm -f "$SPD/manifest.tsv"
  { [ -z "$(spot_parts_arg)" ]; }; okc "with no local manifest, no --parts-modules is passed"
  ends spot_reclaimed "a test"
  { [ "$RC" = 77 ] && jstate 'd["parts_modules"] == 0 and d["attempts"][0]["ended"] == "RECLAIMED"'; }; okc "...and the RECLAIMED write still goes up"
}

# one case, in this process: called as "test_spot_guest.sh --case NAME TMPD"
if [ "${1:-}" = --case ]; then
  NAME=$2; TMPD=$3; CD="$TMPD/cases/$NAME"; CHK="$CD/checks"; mkdir -p "$CD"; : > "$CHK"
  PATH="$TMPD/shim:$PATH"; export PATH SPOTTEST_SLEEP_SCALE="${SPOTTEST_SLEEP_SCALE:-0.02}"
  BASHPID=$$                                     # bash 3.2 has no $BASHPID (see the top of this file)
  trap 'kill $(jobs -p) 2>/dev/null' EXIT
  exec >> "$CD/out.log" 2>&1
  "case_$NAME"
  exit 0
fi

# ================================================================ the parent: shims, extraction, then each case
TMPD=$(mktemp -d "${TMPDIR:-/tmp}/spotguest.XXXXXX") || exit 1
TMPD=$(cd "$TMPD" && pwd -P)
if [ "${SPOTTEST_KEEP:-0}" = 1 ]; then trap 'pkill -f "$TMPD" 2>/dev/null; echo "kept $TMPD"' EXIT
else trap 'pkill -f "$TMPD" 2>/dev/null; rm -rf "${TMPD:?}"' EXIT; fi
command -v zstd >/dev/null 2>&1 || { echo "SKIP  every case: zstd is not installed (scripts/spot_checkpoint.sh needs it)"; echo "0 cases, 0 failed"; exit 0; }
START=$(date +%s)
S="$TMPD/shim"; mkdir -p "$S"

cat > "$S/curl" <<'PY'
#!/usr/bin/env python3
# Fake curl: the bucket is the directory $SPOTTEST_FAKE/bucket, the metadata server is $SPOTTEST_FAKE/md and a few
# fixed answers. $SPOTTEST_FAKE/rules can make a request fail; every request is logged in $SPOTTEST_FAKE/ops.log.
import fcntl, fnmatch, os, sys, time, urllib.parse
F = os.environ["SPOTTEST_FAKE"]
WITH_VALUE = {"--connect-timeout", "--max-time", "--speed-limit", "--speed-time", "--retry", "--retry-delay", "-H", "-X", "-T", "-o", "-w", "-D"}
opt, hdrs, url, fail = {}, [], None, False
a = sys.argv[1:]; i = 0
while i < len(a):
    x = a[i]
    if x in WITH_VALUE:
        if x == "-H": hdrs.append(a[i + 1])
        else: opt[x] = a[i + 1]
        i += 2; continue
    if x.startswith("-") and not x.startswith("--"):
        fail = fail or "f" in x[1:]
    elif not x.startswith("--"):
        url = x
    i += 1
def log(s):
    with open(os.path.join(F, "ops.log"), "a") as fh: fh.write(s + "\n")
def rule(op, name):
    p = os.path.join(F, "rules")
    if not os.path.exists(p): return None
    with open(p, "r+") as fh:
        fcntl.flock(fh, fcntl.LOCK_EX)
        rows = [l.split() for l in fh.read().splitlines() if l.strip()]
        hit = None
        for r in rows:
            if hit is None and r[0] == op and fnmatch.fnmatchcase(name, r[1]) and int(r[3]) > 0:
                hit = r[2]; r[3] = str(int(r[3]) - 1)
        fh.seek(0); fh.truncate(); fh.write("".join(" ".join(r) + "\n" for r in rows if int(r[3]) > 0))
    return hit
def answer(code, body=b"", headers=(), rc=None):
    if "-D" in opt:
        with open(opt["-D"], "w") as fh: fh.write("HTTP/1.1 %d X\r\n" % code + "".join(h + "\r\n" for h in headers) + "\r\n")
    if rc is None: rc = 22 if (fail and code >= 400) else 0
    if body is not None and not (fail and code >= 400) and code != 0:
        out = opt.get("-o")
        if out:
            with open(out, "wb") as fh: fh.write(body)
        else:
            sys.stdout.buffer.write(body); sys.stdout.flush()
    if "-w" in opt: sys.stdout.write(opt["-w"].replace("%{http_code}", "%03d" % code)); sys.stdout.flush()
    sys.exit(rc)
if url is None: sys.exit("fake curl: no URL")
u = urllib.parse.urlsplit(url); q = urllib.parse.parse_qs(u.query)
if u.hostname == "metadata.google.internal":
    p = u.path
    if p.endswith("/service-accounts/default/token"): answer(200, b'{"access_token": "fake-token", "expires_in": 3599}')
    if "/attributes/" in p:
        k = p.rsplit("/attributes/", 1)[1]; f = os.path.join(F, "md", k)
        if os.path.isfile(f): answer(200, open(f, "rb").read())
        answer(404, b"not found")
    if p.endswith("/zone"): answer(200, b"projects/123/zones/fake-zone-a")
    if p.endswith("/preempted"):
        log("MD preempted " + (u.query or "-"))
        f = os.path.join(F, "preempt")
        rows = open(f).read().splitlines() if os.path.exists(f) else ["FALSE e0"]
        v, etag = (rows[0].split() + ["e0"])[:2]
        if len(rows) > 1: open(f, "w").write("\n".join(rows[1:]) + "\n")
        time.sleep(0.05)
        answer(200, v.encode(), ["ETag: " + etag])
    answer(404, b"")
if u.hostname != "storage.googleapis.com": log("REFUSED " + url); answer(0, None, rc=6)
if "Authorization: Bearer fake-token" not in hdrs: log("NO-TOKEN " + url); answer(401, b"")
bucket = open(os.path.join(F, "bucket_name")).read().strip()
def path_of(name):
    if not name or name.startswith("/") or ".." in name.split("/"): log("BAD-NAME " + name); answer(400, b"")
    return os.path.join(F, "bucket", name)
up = "/upload/storage/v1/b/%s/o" % bucket; down = "/storage/v1/b/%s/o/" % bucket
if u.path == up and q.get("uploadType") == ["media"] and "-T" in opt:
    name = q["name"][0]; dst = path_of(name)
    how = rule("put", name)
    if how == "fail": log("PUT-FAIL " + name); answer(503, b"")
    if how == "stall":   # no byte moves: curl gives up at --max-time (or after --speed-time), scaled as sleep is
        lim = float(opt.get("--max-time") or opt.get("--speed-time") or 600)
        time.sleep(lim * float(os.environ.get("SPOTTEST_SLEEP_SCALE", "0.02")))
        log("PUT-STALL " + name); answer(0, None, rc=28)
    data = open(opt["-T"], "rb").read()
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    with open(dst + ".tmp", "wb") as fh: fh.write(data)
    os.replace(dst + ".tmp", dst)
    log("PUT " + name); answer(200, b"{}")
if u.path.startswith(down) and q.get("alt") == ["media"]:
    name = urllib.parse.unquote(u.path[len(down):]); src = path_of(name)
    how = rule("get", name)
    if how == "fail": log("GET %s 000 fail" % name); answer(0, None, rc=7)
    if how == "404" or not os.path.isfile(src): log("GET %s 404 %s" % (name, how or "absent")); answer(404, b"no such object")
    data = open(src, "rb").read()
    if how == "truncate": log("GET %s 200 truncate" % name); answer(200, data[: len(data) // 2], rc=18)
    if how == "corrupt": log("GET %s 200 corrupt" % name); answer(200, bytes([data[0] ^ 1]) + data[1:] if data else b"x")
    log("GET %s 200 ok" % name); answer(200, data)
log("UNKNOWN " + url); answer(404, b"")
PY

cat > "$S/sha256sum" <<'PY'
#!/usr/bin/env python3
# GNU sha256sum's output: "<hash>  <name>", and "-" for the standard input.
import hashlib, sys
def h(fh):
    d = hashlib.sha256()
    for b in iter(lambda: fh.read(1 << 20), b""): d.update(b)
    return d.hexdigest()
names = [x for x in sys.argv[1:] if x != "--"]
if not names: print("%s  -" % h(sys.stdin.buffer)); sys.exit(0)
rc = 0
for n in names:
    try:
        with open(n, "rb") as fh: print("%s  %s" % (h(fh), n))
    except OSError as e: print("sha256sum: %s: %s" % (n, e.strerror), file=sys.stderr); rc = 1
sys.exit(rc)
PY

cat > "$S/stat" <<'PY'
#!/usr/bin/env python3
# GNU "stat -c FORMAT FILE..." (%s size, %Y modification time, %a mode, %n name); anything else: the system's stat.
import os, stat, sys
a = sys.argv[1:]
if len(a) < 3 or a[0] != "-c": os.execv("/usr/bin/stat", ["stat"] + a)
rc = 0
for f in a[2:]:
    try: st = os.lstat(f)
    except OSError as e: print("stat: cannot stat '%s': %s" % (f, e.strerror), file=sys.stderr); rc = 1; continue
    v = {"s": str(st.st_size), "Y": str(int(st.st_mtime)), "a": "%o" % stat.S_IMODE(st.st_mode), "n": f, "%": "%"}
    out, i, fmt = "", 0, a[1]
    while i < len(fmt):
        if fmt[i] == "%" and i + 1 < len(fmt):
            if fmt[i + 1] not in v: sys.exit("stat shim: %" + fmt[i + 1] + " is not supported")
            out += v[fmt[i + 1]]; i += 2
        else: out += fmt[i]; i += 1
    print(out)
sys.exit(rc)
PY

cat > "$S/find" <<'PY'
#!/usr/bin/env python3
# GNU find's -printf (%p %y %l %s, and \n \t), on top of the system's find; without -printf, the system's find.
import os, stat, subprocess, sys
a = sys.argv[1:]
if "-printf" not in a: os.execv("/usr/bin/find", ["find"] + a)
i = a.index("-printf"); fmt = a[i + 1]; b = a[:i] + ["-print0"] + a[i + 2:]
if "-printf" in b: sys.exit("find shim: only one -printf")
r = subprocess.run(["/usr/bin/find"] + b, stdout=subprocess.PIPE)
def kind(m):
    for t, c in ((stat.S_ISREG, "f"), (stat.S_ISDIR, "d"), (stat.S_ISLNK, "l"), (stat.S_ISFIFO, "p"), (stat.S_ISSOCK, "s"), (stat.S_ISCHR, "c"), (stat.S_ISBLK, "b")):
        if t(m): return c
    return "U"
for p in r.stdout.split(b"\0"):
    if not p: continue
    st = os.lstat(p); s = p.decode("utf-8", "surrogateescape"); out = ""; j = 0
    while j < len(fmt):
        c = fmt[j]
        if c == "%" and j + 1 < len(fmt):
            k = fmt[j + 1]; j += 2
            if k == "p": out += s
            elif k == "y": out += kind(st.st_mode)
            elif k == "l": out += os.readlink(p).decode("utf-8", "surrogateescape") if stat.S_ISLNK(st.st_mode) else ""
            elif k == "s": out += str(st.st_size)
            elif k == "%": out += "%"
            else: sys.exit("find shim: %" + k + " is not supported")
        elif c == "\\" and j + 1 < len(fmt):
            out += {"n": "\n", "t": "\t", "\\": "\\", "0": "\0"}[fmt[j + 1]]; j += 2
        else: out += c; j += 1
    sys.stdout.write(out)
sys.exit(r.returncode)
PY

cat > "$S/timeout" <<'PY'
#!/usr/bin/env python3
# GNU timeout: DURATION [--kill-after=D | -k D] [-s SIG]; status 124 when the time ran out, 128+N for a signal.
import os, signal, subprocess, sys
a = sys.argv[1:]; ka = None; sig = signal.SIGTERM
def secs(x): return float(x.rstrip("s"))
while a and a[0].startswith("-"):
    x = a.pop(0)
    if x.startswith("--kill-after="): ka = secs(x.split("=", 1)[1])
    elif x in ("-k", "--kill-after"): ka = secs(a.pop(0))
    elif x == "-s": n = a.pop(0); sig = getattr(signal, n if n.startswith("SIG") else "SIG" + n)
    elif x == "--": break
    else: sys.exit("timeout shim: unsupported option " + x)
d = secs(a.pop(0))
p = subprocess.Popen(a, close_fds=False)
signal.signal(signal.SIGTERM, lambda s, f: p.send_signal(s))
try:
    rc = p.wait(timeout=d if d > 0 else None)
except subprocess.TimeoutExpired:
    p.send_signal(sig)
    try: p.wait(timeout=ka)
    except subprocess.TimeoutExpired: p.kill(); p.wait(); sys.exit(137)
    sys.exit(124)
sys.exit(rc if rc >= 0 else 128 - rc)
PY

cat > "$S/flock" <<'PY'
#!/usr/bin/env python3
# util-linux flock: "flock [-w SECS] [-n] FD" locks an open file the caller holds (the lock stays with it after
# this exits, as with the real one); "flock [-w SECS] FILE COMMAND..." holds the lock while COMMAND runs.
import fcntl, os, sys, time
a = sys.argv[1:]; w = None; nb = False
while a and a[0].startswith("-"):
    x = a.pop(0)
    if x == "-w": w = float(a.pop(0))
    elif x == "-n": nb = True
    elif x in ("-x", "-e"): pass
    else: sys.exit("flock shim: unsupported option " + x)
if len(a) == 1 and a[0].isdigit(): fd = int(a[0]); cmd = None
else: fd = os.open(a[0], os.O_RDONLY | os.O_CREAT, 0o644); os.set_inheritable(fd, True); cmd = a[1:]
end = None if w is None else time.time() + w
while True:
    try: fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB); break
    except BlockingIOError:
        if nb or (end is not None and time.time() >= end): sys.exit(1)
        time.sleep(0.05)
if cmd: os.execvp(cmd[0], cmd)
PY

cat > "$S/pkill" <<'PY'
#!/usr/bin/env python3
# pkill: only "-P PID" is carried out (signals the children of PID). By name or user it only logs: nothing of the
# same name on this Mac is ever touched.
import os, signal, subprocess, sys
a = sys.argv[1:]; sig = signal.SIGTERM; ppid = None; rest = []
if os.environ.get("SPOTTEST_FAKE"):
    with open(os.path.join(os.environ["SPOTTEST_FAKE"], "pkill.log"), "a") as fh: fh.write("pkill " + " ".join(a) + "\n")
while a:
    x = a.pop(0)
    if x == "-P": ppid = int(a.pop(0))
    elif x.startswith("-") and x[1:].isdigit(): sig = int(x[1:])
    elif x.startswith("-") and x[1:].isupper(): sig = getattr(signal, "SIG" + x[1:])
    else: rest.append(x)
if ppid is None or rest: sys.exit(1)
out = subprocess.run(["ps", "-A", "-o", "pid=,ppid="], stdout=subprocess.PIPE, text=True).stdout
kids = [int(l.split()[0]) for l in out.splitlines() if len(l.split()) == 2 and int(l.split()[1]) == ppid]
for k in kids:
    try: os.kill(k, sig)
    except OSError: pass
sys.exit(0 if kids else 1)
PY

cat > "$S/date" <<'SH'
#!/bin/sh
# GNU "date -d @EPOCH" becomes BSD "date -r EPOCH"; everything else goes to the system's date unchanged.
n=$#; i=0
while [ "$i" -lt "$n" ]; do
  x=$1; shift; i=$((i + 1))
  if [ "$x" = -d ] && [ "$i" -lt "$n" ]; then
    y=$1; shift; i=$((i + 1))
    case "$y" in @*) set -- "$@" -r "${y#@}" ;; *) echo "date shim: only -d @EPOCH is supported" >&2; exit 1 ;; esac
  else set -- "$@" "$x"; fi
done
exec /bin/date "$@"
SH
cat > "$S/cp" <<'SH'
#!/bin/sh
# GNU "cp --no-dereference" becomes BSD "cp -P".
n=$#; i=0
while [ "$i" -lt "$n" ]; do x=$1; shift; i=$((i + 1)); if [ "$x" = --no-dereference ]; then set -- "$@" -P; else set -- "$@" "$x"; fi; done
exec /bin/cp "$@"
SH
cat > "$S/wc" <<'SH'
#!/bin/sh
# wc without the leading spaces BSD wc puts before a count (GNU wc reading its standard input has none).
/usr/bin/wc "$@" | sed 's/^ *//'
SH
cat > "$S/sleep" <<'SH'
#!/bin/sh
# sleep for a fraction (SPOTTEST_SLEEP_SCALE, default 0.02) of the time asked.
exec /bin/sleep "$(awk -v s="${1:-0}" -v f="${SPOTTEST_SLEEP_SCALE:-0.02}" 'BEGIN {printf "%.3f", s * f}')"
SH
cat > "$S/runuser" <<'SH'
#!/bin/sh
# runuser: runs the command as the current user; logs which user it was asked for.
echo "runuser $*" >> "$SPOTTEST_FAKE/runuser.log"
case "${1:-}" in
  -u) shift 2; [ "${1:-}" = -- ] && shift; exec "$@" ;;
  -l) shift 2; [ "${1:-}" = -c ] || exit 1; exec bash -c "$2" ;;
esac
echo "runuser shim: unsupported use" >&2; exit 1
SH
for t in usermod loginctl crontab chown; do
  printf '#!/bin/sh\n# %s: logs what it was asked and does nothing (it would need root).\necho "%s $*" >> "$SPOTTEST_FAKE/root.log"\nexit 0\n' "$t" "$t" > "$S/$t"
done
printf '#!/bin/sh\n# pgrep: finds nothing.\nexit 1\n' > "$S/pgrep"
printf '#!/bin/sh\n# id: the users pilot, chk2 and chk3 do not exist here.\ncase "${1:-}" in pilot|chk2|chk3) exit 1 ;; esac\nexec /usr/bin/id "$@"\n' > "$S/id"
chmod +x "$S"/*

# ---- the guest's code, extracted from the file as it is
FUNCS="now left say tok enc gcs_get gcs_put gz_put status sync_small sync_big stop_build kill_users idle_until_deleted manifest src_manifest
  tc_manifest pkgs_manifest lib_manifest plain safe_cp disk_facts phase_mark phases_end as_pilot as_chk lake_logs failed_lines put_logs c3_summary
  write_facts report checkpoint finish t_step on_signal deadline_check finished_modules n_finished built_in_log"
G="$TMPD/guest.sh"
{
  echo "# Made by scripts/dev/test_spot_guest.sh from cloud/gcp/full_guest.sh, which it is the code of; do not edit."
  echo "# 1. The settings at the top, from the machine's directory to the Spot settings, with the machine's fixed paths replaced."
  awk '/^PD=\/var\/pilot;/ {on = 1} on {print} on && /^SPOT=\$\(md full-spot 0\)$/ {s = 1} s && /^fi$/ {exit}' "$GUEST" \
    | sed -e '/^exec >/d' -e 's|^PD=/var/pilot;|PD=$HARNESS_PD;|' -e 's|^WORK=/mnt/work;|WORK=$HARNESS_WORK;|' -e 's|; TOOLS=/opt/rhv$|; TOOLS=$HARNESS_TOOLS|'
  echo "# 2. The functions the Spot block calls that are defined elsewhere in the file (the first definition of each name)."
  awk -v want=" $(echo $FUNCS) " '
    !inf && /^[a-z_][a-z_0-9]*\(\) *\{/ {
      n = substr($0, 1, index($0, "(") - 1)
      if (index(want, " " n " ") && !(n in got)) { got[n] = 1; print; if ($0 !~ /\}[ \t]*(#.*)?$/) { inf = 1; hd = 0 } }
      next
    }
    inf { print
          if (hd) { if ($0 ~ /^PY$/) hd = 0; next }
          if ($0 ~ /<<.PY.[ \t]*$/) { hd = 1; next }
          if ($0 ~ /^\}$/) inf = 0 }
    END { for (n in got) print n > "/dev/stderr" }' "$GUEST" 2> "$TMPD/got.txt"
  echo "# 3. The status phase and the variables facts.json reads."
  grep '^PHASE=boot$' "$GUEST"
  awk '/^C1_STATE=not_reached/ {on = 1} on {print} on && /^SECOND_WHY=/ {exit}' "$GUEST"
  echo "# 4. The Spot block."
  awk '/^# -+ Spot \(full-spot=1\) only/ {m = 1; next} m && !on && /^if \[ "\$SPOT" = 1 \]; then$/ {on = 1} on {print} on && /^fi$/ {exit}' "$GUEST"
  echo "# 5. The reboot branch, as a function."
  echo 'reboot_branch() {'; grep '^if \[ -e "\$PD/STARTED" \] && \[ "\$SPOT" = 1 \]' "$GUEST"; echo '}'
  cat <<'SH'
# ---- the harness's own replacements (not from the guest)
# On the real machine this never returns; here it ends the process with a status the cases look for.
idle_until_deleted() { echo "idle $(date +%s)" >> "$PD/IDLED"; exit 77; }
# The sealed toolchain is at /opt/lean-tc on the real machine; here it is a directory of the case's own.
eval "harness_real_$(declare -f tc_manifest)"
tc_manifest() { if [ "$1" = /opt/lean-tc ]; then harness_real_tc_manifest "$HARNESS_TC"; else harness_real_tc_manifest "$1"; fi; }
SH
} > "$G"

N=0; FAILS=0
line() { N=$((N + 1)); [ "$1" = PASS ] || FAILS=$((FAILS + 1)); printf '%s  %s\n' "$1" "$2"; }
# The extraction itself: every piece found, every replacement made, and the result is valid bash.
missing=""; for f in $FUNCS; do grep -qx "$f" "$TMPD/got.txt" || missing="$missing $f"; done
probs=""
[ -z "$missing" ] || probs="$probs; functions not found:$missing"
for p in 'PD=$HARNESS_PD;' 'WORK=$HARNESS_WORK;' 'TOOLS=$HARNESS_TOOLS'; do [ "$(grep -cF "$p" "$G")" = 1 ] || probs="$probs; not replaced once: $p"; done
grep -q '^spot_confirm() {' "$G" || probs="$probs; the Spot block was not found"
[ "$(grep -c '^if \[ -e "\$PD/STARTED" \] && \[ "\$SPOT" = 1 \]' "$G")" = 1 ] || probs="$probs; the reboot branch was not found"
/bin/bash -n "$G" 2> "$TMPD/n.err" || probs="$probs; bash -n: $(head -3 "$TMPD/n.err" | tr '\n' ' ')"
for f in "$GUEST" "$SPK_REAL" "$SELF"; do /bin/bash -n "$f" 2>/dev/null || probs="$probs; bash -n fails on $(basename "$f")"; done
if [ -z "$probs" ]; then line PASS "0. bash -n, and the guest's Spot block and the $(echo $FUNCS | wc -w | tr -d ' ') functions it needs extracted from the file ($(wc -l < "$G" | tr -d ' ') lines)"
else line FAIL "0. extraction${probs}"; echo "$N cases, $FAILS failed"; exit 1; fi

run_case() { # run_case <name> <title>
  local t0 rc nf np d="$TMPD/cases/$1"
  # SPOTTEST_CASES="name ...": only those cases (the two that start everything always run; resume and restore need the fixture)
  case " extract fixture ${SPOTTEST_CASES:-$1} " in *" $1 "*) ;; *) return 0 ;; esac
  t0=$(date +%s)
  "$S/timeout" 300 /bin/bash "$SELF" --case "$1" "$TMPD"; rc=$?
  pkill -f -- "--case $1 $TMPD" 2>/dev/null
  np=$(grep -c '^PASS' "$d/checks" 2>/dev/null); nf=$(grep -c '^FAIL' "$d/checks" 2>/dev/null)
  if [ "$rc" = 0 ] && [ "${nf:-0}" = 0 ] && [ "${np:-0}" -gt 0 ]; then line PASS "$2 ($np checks, $(( $(date +%s) - t0 )) s)"
  else
    line FAIL "$2 ($np passed, $nf failed, exit $rc$([ "$rc" = 124 ] && echo ': timed out'))"
    grep '^FAIL' "$d/checks" 2>/dev/null | cut -f2- | sed 's/^/        /'
    echo "        (output: $d/out.log; set SPOTTEST_KEEP=1 to keep it)"
  fi
}
run_case extract   "0a. the extracted code loads; metadata and the bucket go through the fake curl"
run_case fixture   "0b. attempt 1: a fresh state, its baselines, two parts (the run the next cases continue)"
run_case rounds    "1. a part round: part, manifest, state; the done list after the manifest; numbers never reused; pending files"
run_case resume    "2. s_spot_resume: wrong state, forged manifest row, downloads cut short, a state the controller did not see"
run_case restore   "3. spot_restore_all on real parts: count, bytes, a bad download fetched again, after the seal as root"
run_case record    "4. spot_record refused after PREEMPTED or DEADLINE; spot_load gives back quoted values"
run_case confirm   "5. spot_confirm: confirms, then results; a change or a sighting ends the run FAIL; reclaim uploads no results"
run_case cover     "6. the cover check at the first seal: equal, repaired by one more part, an extra file fails"
run_case status    "7. status JSON carries the attempt; after PREEMPTED only RECLAIMED; the reboot branch; the watcher's ETag"
run_case parts_max "8. the parts size limit (K1) pauses instead of uploading"
run_case signals   "9. a check ended by a signal pauses; a saved module compiled again ends the run at once"
run_case c2        "10. axiom-check summaries saved with a checksum and recorded only after a confirm"
run_case kinds     "11. the kind of each pause (K7) in the status and the state: retry, deadline, stop, parts-limit"
run_case setup     "12. a setup step that needs the network pauses (retry), before and after the state exists; others fail"
run_case smoke     "13. the smoke log is read from root's own copy; without one, spot.log says so"
run_case cutoff    "14. a part loop stopped between its manifest and its state write: the pause's state counts the part"
run_case logs      "15. failed job lines and Built lines read from root's own copies of the build logs; a pipe or link is skipped"
run_case results   "16. saved replay results: one object per count with its SHA-256 in the state; restore checks it"
run_case stall     "17. a stalled build-log upload costs a part round one try of at most 120 s; the manifest and state still go up"
run_case reclaim_pm "18. the RECLAIMED state writes (spot_reclaimed, the watcher) count a part whose own state write was cut off"
echo "$N cases, $FAILS failed ($(( $(date +%s) - START )) s)"
[ "$FAILS" = 0 ]
