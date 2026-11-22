#!/bin/bash
# Full run, guest side. Runs unattended as the VM's startup script (root, Ubuntu 24.04).
#
# What it does, in order:
#   setup   prepares the machine; fetches the proof tarball, this repository's scripts and the sampler from a
#           private bucket, each checked against a SHA-256 given at launch; installs the pinned Lean toolchain and
#           Mathlib's prebuilt cache; records a SHA-256 of every file of the source tree, the toolchain and
#           Mathlib's compiled files; blocks the build user from the metadata server and from opening any
#           connection off the machine; only then compiles anything.
#   build   `lake build` of every target, to completion (criterion C1). Early on it stops and restarts the build
#           tool twice, once as a control and once after deleting the setup files of finished modules, and ends the
#           run if either restart recompiles a finished module. After that it deletes the setup files of finished
#           modules every ten minutes, which keeps the disk under about 200 GB instead of about 1.3 TB.
#           If the build fails it is tried once more, with half as many jobs. A compiler process killed by a signal
#           is reported as such: by PREREGISTRATION.md, section 4, that is not a test of the module.
#   seal    The build user's account is locked as soon as the build ends. The script then confirms that the source
#           tree, the toolchain and Mathlib's compiled files are byte-for-byte what they were before any file of
#           the proof was compiled, symbolic links included; hands every file to root; copies the toolchain to a
#           directory only root has ever written; deletes and recreates the directories the checks will write to;
#           removes, and counts, the half-written files that killed compilers leave beside the compiled modules;
#           refuses any other file there that the build tool does not write for this project;
#           records a SHA-256 of every file there; and creates two fresh unprivileged users.
#   c2      scripts/08_check_axioms.sh, without and with --deep (criterion C2), as the user `chk2`. The deep
#           walk runs before the replay if the replay will still fit afterwards, otherwise after it, and is
#           skipped if no time is left; facts.json says which.
#   c3      scripts/09_kernel_replay.sh on every module (criterion C3), as the user `chk3`: `leanchecker`, the
#           tool the criterion names, one process a module, each with only the module's import closure on its
#           search path (docs/performance-notes.md, section 10). Short trials first measure how many modules a
#           second the replay manages; if that rate cannot cover the tree in the time left, the replay is given
#           an hour and the run goes on, and facts.json says so. Modules whose checker was killed or cut off are
#           tried again, with fewer at a time, up to twice. A module the tool rejects or crashes on is run twice
#           more as evidence and is never afterwards counted as passed.
#           With full-second-replay=rhv-replay, every module is then replayed again by the program in
#           scripts/verify/replay, which root builds during setup, before any file of the proof is compiled,
#           after comparing its copy of the replay function with the toolchain's source. That second replay is
#           not part of the criterion: its passes do not count towards it. A rejection or crash by it is kept
#           like any other, and while one stands the summary does not say that the criterion's conditions hold.
#   end     hashes the files beside the compiled modules, the toolchain and Mathlib again, and fails the run if
#           any changed.
#   report  uploads logs, measurements and a file of facts, facts.json. It does not issue a verdict: the outcome
#           is read off PREREGISTRATION.md, section 5, by a person.
#
# What the separation does and does not buy. Compiling Lean can run code, and so can importing: the axiom check
# runs the Lean frontend on a file that imports the proof, which executes any initialisation code the proof's
# modules declare. A text scan of the source found no file or process IO at all (CLAIMS.md, S7), so none of this
# is expected to matter; the separation is there so that the result does not rest on that scan alone. Nothing the
# build user leaves behind is used by the checks without having been compared, replaced or refused at the seal;
# the axiom check's user cannot write where the kernel replay writes, and root reads back from either only plain
# files; and the kernel replay itself (by either method) loads the compiled files as data and runs none of their code.
# What remains: the axiom check's own output comes from a process that has imported the proof; the three users
# share the system's temporary directories; and name lookups through the system resolver are not blocked, so
# "no network" means no connection, not no channel at all. The VM holds no secret worth sending: its credentials
# are behind the metadata server, which is blocked, and the proof source is public.
#
# With full-timebox set (the rehearsal), the build is stopped after that many seconds and the later phases run on
# whatever was built, with the axiom check in --probe mode. That exercises the build loop, both restart tests,
# pruning, the seal, both checks and the reports. It does not exercise a failed build or the completeness
# check, and it verifies nothing.
#
# How it ends: it does NOT power the machine off. A guest shutdown would clear the VM's scheduled deletion
# (--max-run-duration), leaving its disks billing. It uploads a final status and idles; the local `watch` deletes
# the VM within about a minute, and if nobody is watching, Google deletes it at max-run-duration.
set -u
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
PD=/var/pilot; mkdir -p "$PD"; chmod 755 "$PD"
exec > >(tee -a "$PD/pilot.log") 2>&1
T0=$(date +%s)

MDURL=http://metadata.google.internal/computeMetadata/v1/instance
md() { curl -sf --connect-timeout 5 --max-time 20 -H "Metadata-Flavor: Google" "$MDURL/attributes/$1" || echo "$2"; }
BUCKET=$(md pilot-bucket "")
MODE=$(md pilot-mode full)                       # full | full-rehearsal
NMAX=$(md pilot-nmax 32)                         # parallel compiler processes, and the most checker processes
DEADLINE_MIN=$(md pilot-deadline-min 2460)       # guest-side deadline, minutes after boot
TARBALL_SHA=$(md pilot-tarball-sha "")
SAMPLER_SHA=$(md pilot-sampler-sha "")
TOOLS_SHA=$(md full-tools-sha "")                # SHA-256 of the archive of this repository's scripts
TOOLS_COMMIT=$(md full-tools-commit unknown)     # the commit that archive, and this script, were taken from
GUEST_SHA_WANT=$(md full-guest-sha "")           # SHA-256 of this script as the controller sent it
RUNTAG=$(md pilot-runtag run)
TIMEBOX=$(md full-timebox 0)                     # seconds; 0 = build to completion
TARGETS=$(md full-targets "")                    # lake targets; empty = everything
PRUNE_AFTER=$(md full-prune-after 3000)          # run the restart tests once this many modules are built
C2_TIMEOUT=$(md full-c2-timeout 7200)            # most seconds allowed for each run of the axiom check
CHECK_TRIAL=$(md full-check-trial "16 24 32")    # checker job counts to try before the main replay; empty = use NMAX
TRIAL_SECS=$(md full-check-trial-secs 300)       # length of each such trial
FINAL_RESERVE=$(md full-final-reserve 1500)      # seconds kept back at the end for the last checks and uploads
WATCHDOG_WAIT=$(md full-watchdog-wait 600)       # seconds the watchdog gives the main script after the deadline
PRUNE_EVERY=$(md full-prune-every 600)           # seconds between prunings of setup files during the build
KEEP_MIN_LEFT=$(md full-keep-min-left 1200)      # the archive of compiled files is only started with this many seconds left
KEEP_OLEANS=$(md full-keep-oleans 0)             # 1 = also upload an archive of the compiled files
SECOND_REPLAY=$(md full-second-replay "")        # "rhv-replay": after leanchecker has checked every module, replay them all again with that program
C3_SHORT_CAP=$(md full-c3-short-cap 3600)        # seconds given to a replay that the trials show cannot finish in time
FINISH_WAIT=$(md full-watchdog-finish-wait 1800) # more seconds the watchdog gives a main script that has begun its report
DRIVER=""; DRIVER_SHA=""                         # the second replay's program, built by root during setup when it is asked for
GUEST_SHA=$(curl -sf --connect-timeout 5 --max-time 30 -H "Metadata-Flavor: Google" "$MDURL/attributes/startup-script" | sha256sum | cut -d' ' -f1)
DEADLINE=$(( T0 + DEADLINE_MIN * 60 ))
WORK=/mnt/work; PROJ=$WORK/extract/lean; LOGS=$WORK/logs; AN=$WORK/analysis; RES="results/$RUNTAG"; TOOLS=/opt/rhv
LIB=$PROJ/.lake/build/lib/lean
TC_BIN=""; TC_DIR=""                              # the pinned toolchain's bin directory and its parent, found during setup
# A Spot run (full-spot=1): this machine is one attempt of a run that Google may cut off at any moment, and that
# continues on a fresh machine from what is saved in the bucket under ckpt/RUNTAG (scripts/spot_checkpoint.sh).
# Without it, nothing below the "Spot" lines runs, and every value here is what it always was.
SPOT=$(md full-spot 0)
RT=$RES                                           # the latest status, heartbeat and facts.json
if [ "$SPOT" = 1 ]; then
  ATTEMPT=$(md full-attempt 1); CKPT_EVERY=$(md full-ckpt-every 600); HOLD=$(md full-spot-hold "")
  STATE_SHA_WANT=$(md full-state-sha ""); MANIFEST_SHA_WANT=$(md full-manifest-sha "")   # what the controller downloaded after the last attempt
  case "$ATTEMPT" in ''|*[!0-9]*|0) ATTEMPT=1 ;; esac; case "$CKPT_EVERY" in ''|*[!0-9]*|0) CKPT_EVERY=600 ;; esac
  # The most bytes all the parts together may hold (sent only for a zone outside the bucket's region; 0 = no
  # limit), and the seconds between confirmed uploads of the replay's results (see spot_confirm).
  PARTS_MAX=$(md full-parts-max-bytes 0); CONFIRM_EVERY=$(md full-confirm-every 1200)
  case "$PARTS_MAX" in ''|*[!0-9]*) PARTS_MAX=0 ;; esac; case "$CONFIRM_EVERY" in ''|*[!0-9]*|0) CONFIRM_EVERY=1200 ;; esac
  CK="ckpt/$RUNTAG"; RES="$RT/attempt-$ATTEMPT"   # no attempt may overwrite another attempt's logs
  KEEP_OLEANS=0                                   # the parts are the archive of the compiled files
  SPK=$TOOLS/scripts/spot_checkpoint.sh; SPS=$PD/state.json; SPD=$WORK/spot; SPOUT=$WORK/spot-out; SPIN=$WORK/spot-in
  SEAL_DONE=0; SKIP_BUILD=0; SPOT_LOCKED=0; TIMEBOX_USED=0; SEAL_LIB_SHA=""; BASE_SRC_SHA=""; BASE_TC_SHA=""; BASE_PKGS_SHA=""; SEEN_ATTEMPTS=""
  SPOT_CKPT_PID=""; SPOT_RES_PID=""; ZONE=""; C2_PLAIN_JSON_SHA=""; C2_DEEP_JSON_SHA=""; SPOT_END=0
  SPOT_LEFTOVERS_HERE=""; SPOT_LIB_OTHER_HERE=""     # this machine's own seal figures, on an attempt after the first seal
  # What a later attempt takes back from the state: the decisions and results that otherwise live only in this
  # script's variables (state-export accepts nothing else, and quotes what it prints).
  SPOT_VARS="TESTS_DONE RESTART_CONTROL RESTART_PRUNE RESTART_CONTROL_NEW RESTART_PRUNE_NEW TIMEBOX_USED C1_STATE LAKE_RC RETRIED
    SRC_SAME LIBS_SAME TC_COPY_SAME LEFTOVERS LIB_OTHER MANIFEST_SHA SEAL_LIB_SHA C2_PLAIN_RC C2_DEEP_RC C2_DEEP_WHEN
    CHECK_JOBS C3_RATE C3_NEED C3_EXPECT C3_FITS C3_RC C3_MAIN_T C3_PASSES SECOND_RC SECOND_WHY OLEANS_SAME_END LIBS_SAME_END
    BASE_SRC_SHA BASE_TC_SHA BASE_PKGS_SHA SEEN_ATTEMPTS C2_PLAIN_JSON_SHA C2_DEEP_JSON_SHA"
fi

now() { date +%s; }
left() { echo $(( DEADLINE - $(now) )); }
say() { echo "### $(date -u +%FT%TZ) +$(( $(now) - T0 ))s  $*"; }
tok() { curl -sf --connect-timeout 5 --max-time 20 -H "Metadata-Flavor: Google" "$MDURL/service-accounts/default/token" | python3 -c 'import sys,json; print(json.load(sys.stdin)["access_token"])'; }
enc() { python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1],safe=""))' "$1"; }
gcs_get() { curl -sf --connect-timeout 20 --speed-limit 1024 --speed-time 120 --retry 4 --retry-delay 3 -H "Authorization: Bearer $(tok)" "https://storage.googleapis.com/storage/v1/b/$BUCKET/o/$(enc "$1")?alt=media" -o "$2"; }
# gcs_put <file> <object>: streamed from disk. Five attempts, each with a fresh token; a stalled transfer is
# abandoned after two minutes. Status 1, and a line in the log, if it never succeeded.
gcs_put() {
  [ -e "$1" ] || return 0
  local i
  for i in 1 2 3 4 5; do
    curl -sf --connect-timeout 20 --speed-limit 1024 --speed-time 120 -X POST -H "Authorization: Bearer $(tok)" -H "Content-Type: application/octet-stream" \
      -T "$1" "https://storage.googleapis.com/upload/storage/v1/b/$BUCKET/o?uploadType=media&name=$(enc "$2")" -o /dev/null && return 0
    sleep $(( i * 5 ))
  done
  echo "### UPLOAD FAILED after 5 attempts: $2" >&2
  return 1
}
gz_put() { # gz_put <file> <object>   -- each call has a temporary file of its own
  [ -e "$1" ] || return 0
  local t rc; t=$(mktemp "$PD/.up.XXXXXX") || return 1
  gzip -c "$1" > "$t" && gcs_put "$t" "$2"; rc=$?
  rm -f "$t"; return "$rc"
}
PHASE=boot
status() { # status <phase> <state> <message>
  PHASE=$1
  python3 - "$PD/status.json" "$1" "$2" "${3:-}" "$T0" "$DEADLINE" "$MODE" "$NMAX" <<'PY'
import json, os, sys, time
p, phase, state, msg, t0, dl, mode, nmax = sys.argv[1:9]
json.dump({"phase": phase, "state": state, "message": msg, "elapsed_s": int(time.time()) - int(t0),
           "deadline_in_s": int(dl) - int(time.time()), "mode": mode, "nmax": int(nmax), "utc": time.strftime("%FT%TZ", time.gmtime())}, open(p + ".tmp", "w"))
os.replace(p + ".tmp", p)
PY
  gcs_put "$PD/status.json" "$RES/status.json"
}
sync_small() { local f; date +%s > "$PD/heartbeat"; for f in heartbeat pilot.log setup.tsv phases.tsv env.txt progress.tsv restart_tests.txt; do gcs_put "$PD/$f" "$RES/$f"; done; }
sync_big() { # measurements and results that grow with the run; compressed, and uploaded every ten minutes
  gz_put "$PD/modules.tsv" "$RES/modules.tsv.gz"; gz_put "$PD/system.tsv" "$RES/system.tsv.gz"
  plain "$AN/kernel_replay/results.tsv" && gz_put "$AN/kernel_replay/results.tsv" "$RES/c3/results.tsv.gz"
  return 0
}
stop_build() {
  pkill -TERM -x lake 2>/dev/null; pkill -TERM -x xargs 2>/dev/null; sleep 2
  pkill -KILL -x lean 2>/dev/null; pkill -KILL -x leanchecker 2>/dev/null; pkill -KILL -x rhv-replay 2>/dev/null; pkill -KILL -x lake 2>/dev/null
  local i; for i in 1 2 3 4 5 6 7 8 9 10; do pgrep -x lean >/dev/null || break; sleep 1; done
}
kill_users() { local u; for u in pilot chk2 chk3; do id "$u" >/dev/null 2>&1 && pkill -KILL -u "$u" 2>/dev/null; done; return 0; }
idle_until_deleted() { # stay RUNNING so the scheduled deletion remains armed; keep the final status visible
  trap '' TERM INT
  while true; do kill_users; gcs_put "$PD/status.json" "$RT/status.json" 2>/dev/null; sleep 60; done
}
# manifest <find arguments>: "sha256  path" for every regular file found, and one line for anything that is
# neither a regular file nor a directory (a symbolic link, with its target; a pipe; a device), sorted by path.
# Eight files per sha256sum process, so that each writes its lines in one piece and lines cannot interleave.
manifest() {
  { find "$@" -type f -print0 | xargs -0 -r -P "$NMAX" -n 8 sha256sum
    find "$@" ! -type f ! -type d -printf 'not-a-file:%y  %p -> %l\n'; } | LC_ALL=C sort -k2
}
src_manifest() { ( cd "$PROJ" && manifest . -path ./.lake -prune -o ); }                       # everything but .lake
tc_manifest() { ( cd "$1" && manifest . ); }                                                   # a whole toolchain directory
# Mathlib and the packages beneath it: every compiled file a check can read. The build tool's own bookkeeping
# beside them (.hash and .trace files) is left out: it rewrites some of those as it goes (seen in the first
# rehearsal: five .hash files of Mathlib, the same five on a Mac), and no check reads them.
pkgs_manifest() { ( cd "$PROJ/.lake/packages" && manifest . -path '*/.lake/build/lib/lean/*' ! -name '*.hash' ! -name '*.trace' ); }
lib_manifest() { ( cd "$LIB" && manifest . ); }                                                # everything beside the proof's compiled files
# Root reads files that another user could have written only if they are plain files, and never waits on them.
plain() { [ -f "$1" ] && [ ! -L "$1" ]; }
safe_cp() { plain "$1" && timeout 60 cp --no-dereference "$1" "$2" 2>/dev/null; }             # safe_cp <from> <to>
disk_facts() {
  [ -d "$PROJ/.lake/build" ] || return 0
  { echo "lib_bytes $(du -sb "$PROJ/.lake/build/lib" 2>/dev/null | cut -f1)"; echo "ir_bytes $(du -sb "$PROJ/.lake/build/ir" 2>/dev/null | cut -f1)"
    echo "oleans $(find "$LIB" -name '*.olean' 2>/dev/null | wc -l)"
    echo "setup_json_bytes $(find "$PROJ/.lake/build/ir" -name '*.setup.json' -printf '%s\n' 2>/dev/null | awk '{s+=$1} END{print s+0}')"
    echo "setup_json_files $(find "$PROJ/.lake/build/ir" -name '*.setup.json' 2>/dev/null | wc -l)"; df -B1 "$WORK" | tail -1; } > "$PD/disk.txt" 2>&1
}
phase_mark() { echo "$1" > "$PD/phase"; printf '%s\t%s\n' "$(now)" "$1" >> "$PD/phases.tsv"; say "PHASE $1"; }
phases_end() { printf '%s\t%s\t%s\t%s\n' "$(now)" "$1:end" "$2" "$3" >> "$PD/phases.tsv"; }
as_pilot() { runuser -l pilot -c "ulimit -n 1048576 2>/dev/null; export RH_WORKDIR=$WORK RH_JOBS=$NMAX; cd $PROJ && $1"; }
# as_chk <user> <command>: a clean environment (no login files, nothing inherited), with the sealed toolchain's
# directory first on the PATH.
as_chk() { runuser -u "$1" -- env -i HOME="/home/$1" LANG=C.UTF-8 PATH="$TC_BIN:/usr/bin:/bin" RH_WORKDIR="$WORK" RH_JOBS="$NMAX" RH_REPLAY_DRIVER="$DRIVER" RH_REPLAY_TRUSTED_SHA="$DRIVER_SHA" bash -c "ulimit -n 1048576 2>/dev/null; cd $PROJ && $2"; }

# ---- facts.json: what happened, as numbers. Written whenever the run reports; fields not yet known are null.
C1_STATE=not_reached; LAKE_RC=""; RETRIED=0; RESTART_CONTROL=""; RESTART_PRUNE=""; RESTART_CONTROL_NEW=""; RESTART_PRUNE_NEW=""
FAILED_JOBS=""; KILLED_JOBS=""; CRASHED_JOBS=""; LIB_OTHER=""; KEEP_STATE=not_requested; LAKE_N=0; LEFTOVERS=""
C1_MISSING=""; C1_EXTRA=""; C1_SHADOW=""; SRC_SAME=""; LIBS_SAME=""; TC_COPY_SAME=""; MANIFEST_SHA=""
C2_PLAIN_RC=""; C2_DEEP_RC=""; C2_DEEP_WHEN=not_run; C3_RC=""; CHECK_JOBS=""; OLEANS_SAME_END=""; LIBS_SAME_END=""; KEEP_PARTS=""
C3_FITS=""; C3_EXPECT=""; C3_RATE=""; C3_MAIN_T=""; C3_PASSES=0; DRIVER_SAME=""; SECOND_RC=""
SECOND_WHY=""; [ "$SECOND_REPLAY" = rhv-replay ] && SECOND_WHY="the run ended before it was reached"
# The build tool's logs, by the names this script gave them. Before the seal they are in a directory the build
# user owns, after it in $PD; a file there that is not a plain file is ignored, and after the seal the first
# directory, which then belongs to a checker, is not looked at.
lake_logs() {
  local n=1 f
  while [ "$n" -le "$LAKE_N" ]; do
    f="$PD/lake_build_$n.log"; if plain "$f"; then echo "$f"; elif [ ! -e "$PD/SEALED" ] && plain "$LOGS/lake_build_$n.log"; then echo "$LOGS/lake_build_$n.log"; fi
    n=$((n + 1))
  done
}
failed_lines() { local f k c=0; for f in $(lake_logs); do k=$(grep -c '^✖ ' "$f"); c=$((c + k)); done; echo "$c"; }
put_logs() { local f; for f in $(lake_logs) "$PD"/c2_*.out "$PD"/c3_*.out; do plain "$f" && gz_put "$f" "$RES/logs/$(basename "$f").gz"; done; return 0; }
c3_summary() { # the replay's summary, recomputed by root from the results file (the replay may have been cut short)
  plain "$AN/kernel_replay/results.tsv" || return 0
  local rc trusted=""
  [ -n "$DRIVER_SHA" ] && trusted="--trusted-program $DRIVER_SHA"
  # shellcheck disable=SC2086
  timeout 900 python3 -I -B "$TOOLS/scripts/verify/rhv_tools.py" replay-summary --lib "$LIB" --src "$PROJ/src" --results "$AN/kernel_replay/results.tsv" $trusted --json "$PD/c3_summary.json.new" > "$PD/c3_summary.txt.new" 2> "$PD/c3_summary.err"
  rc=$?
  # 0, 1 and 3 are answers (nothing failed, something failed, not complete). Anything else is the summary itself
  # failing or being cut off: the last good pair of files is then kept, and the error is uploaded beside them.
  case "$rc" in
    0|1|3) if [ -s "$PD/c3_summary.json.new" ] && [ -s "$PD/c3_summary.txt.new" ]; then mv -f "$PD/c3_summary.json.new" "$PD/c3_summary.json"; mv -f "$PD/c3_summary.txt.new" "$PD/c3_summary.txt"; fi ;;
    *) say "WARNING: the replay summary could not be recomputed (status $rc); keeping the previous one"; gcs_put "$PD/c3_summary.err" "$RES/c3/summary_error.txt" ;;
  esac
  gcs_put "$PD/c3_summary.json" "$RES/c3/summary.json"; gcs_put "$PD/c3_summary.txt" "$RES/c3/summary.txt"
}
write_facts() { # write_facts <state> <message>
  F_STATE=$1 F_MSG=$2 F_T0=$T0 F_MODE=$MODE F_TIMEBOX=$TIMEBOX F_NMAX=$NMAX F_TARBALL=$TARBALL_SHA F_COMMIT=$TOOLS_COMMIT F_TOOLS=$TOOLS_SHA \
  F_GUEST=$GUEST_SHA F_GUEST_WANT=$GUEST_SHA_WANT F_C1=$C1_STATE F_NSRC=$(find "$PROJ/src" -name '*.lean' 2>/dev/null | wc -l) \
  F_NCOMP=$(find "$LIB" -name '*.olean' 2>/dev/null | wc -l) F_NFAIL=$(failed_lines) F_LAKE_RC=$LAKE_RC F_RETRIED=$RETRIED \
  F_RCONTROL=$RESTART_CONTROL F_RPRUNE=$RESTART_PRUNE F_RCONTROL_NEW=$RESTART_CONTROL_NEW F_RPRUNE_NEW=$RESTART_PRUNE_NEW \
  F_FAILED_JOBS=$FAILED_JOBS F_KILLED_JOBS=$KILLED_JOBS F_CRASHED_JOBS=$CRASHED_JOBS F_LIB_OTHER=$LIB_OTHER F_KEEP_STATE=$KEEP_STATE \
  F_MISSING=$C1_MISSING F_EXTRA=$C1_EXTRA F_SHADOW=$C1_SHADOW F_SRC_SAME=$SRC_SAME F_LIBS_SAME=$LIBS_SAME F_TC_COPY=$TC_COPY_SAME \
  F_MANIFEST=$MANIFEST_SHA F_C2P=$C2_PLAIN_RC F_C2D=$C2_DEEP_RC F_C2WHEN=$C2_DEEP_WHEN F_C3=$C3_RC F_CJOBS=$CHECK_JOBS \
  F_OLEANS_END=$OLEANS_SAME_END F_LIBS_END=$LIBS_SAME_END F_KEEP=$KEEP_PARTS F_PD=$PD \
  F_LEFTOVERS=$LEFTOVERS F_SECOND=$SECOND_REPLAY F_DRIVER_SHA=$DRIVER_SHA F_DRIVER_SAME=$DRIVER_SAME F_SECOND_RC=$SECOND_RC F_SECOND_WHY=$SECOND_WHY \
  F_C3_FITS=$C3_FITS F_C3_EXPECT=$C3_EXPECT F_C3_RATE=$C3_RATE F_C3_MAIN_T=$C3_MAIN_T F_C3_PASSES=$C3_PASSES \
  F_SPOT=$SPOT F_ATTEMPT=${ATTEMPT:-} F_SPOT_STATE=${SPS:-} F_SPD=${SPD:-} F_CONFIRM_EVERY=${CONFIRM_EVERY:-} \
  F_LEFTOVERS_HERE=${SPOT_LEFTOVERS_HERE:-} F_LIB_OTHER_HERE=${SPOT_LIB_OTHER_HERE:-} \
  python3 -I - "$PD/facts.json" <<'PY'
import json, os, sys, time
E = os.environ.get
def load(p):
    try: return json.load(open(p))
    except Exception: return None
def num(k):
    try: return int(E(k, ''))
    except ValueError: return None
def yes(k): return {'1': True, '0': False}.get(E(k, ''))
def axioms(name):
    d = load(os.path.join(E('F_PD'), 'c2', name))
    if not d: return None
    w = d.get('deep_walk') or {}
    return {'verdict': d.get('verdict'), 'failures': d.get('failures'), 'mode': d.get('mode'), 'compiled_modules': d.get('compiled_modules'),
            'theorem_axioms': {t: v.get('axioms') for t, v in (d.get('theorems') or {}).items()}, 'checks': d.get('checks'),
            'deep_walk': {k: w.get(k) for k in ('requested', 'visited', 'axiom_count', 'axioms', 'missing', 'modules_listed_completely',
                                              'project_modules_touched', 'project_constants_visited', 'library_modules_touched', 'library_constants_visited')}}
c3 = load(os.path.join(E('F_PD'), 'c3_summary.json'))
if c3:      # lists are cut to 50 names here; the summary itself, uploaded beside this file, has them in full
    c3 = {k: (v[:50] + ['... %d more' % (len(v) - 50)] if isinstance(v, list) and len(v) > 50 else v) for k, v in c3.items() if k != 'prefix_modules'}
seen = os.path.join(E('F_PD'), 'build_user_seen_after_seal')
facts = {
    'what': 'facts from one run of cloud/gcp/full_guest.sh; not a verdict (see PREREGISTRATION.md, section 5)',
    'state': E('F_STATE'), 'message': E('F_MSG'), 'written_utc': time.strftime('%FT%TZ', time.gmtime()),
    'elapsed_s': int(time.time()) - int(E('F_T0')), 'mode': E('F_MODE'), 'time_boxed_build': (num('F_TIMEBOX') or 0) > 0, 'jobs': num('F_NMAX'),
    'inputs': {'tarball_sha256': E('F_TARBALL'), 'tools_commit': E('F_COMMIT'), 'tools_archive_sha256': E('F_TOOLS'),
               'guest_script_sha256': E('F_GUEST'), 'guest_script_is_the_one_sent': bool(E('F_GUEST_WANT')) and E('F_GUEST') == E('F_GUEST_WANT')},
    'c1_build': {'state': E('F_C1'), 'source_modules': num('F_NSRC'), 'compiled_modules': num('F_NCOMP'),
                 'source_modules_not_compiled': num('F_MISSING'), 'compiled_modules_without_source': num('F_EXTRA'),
                 'compiled_modules_named_like_a_library': num('F_SHADOW'),
                 'failed_job_lines_in_all_logs': num('F_NFAIL'), 'last_lake_exit_status': num('F_LAKE_RC'), 'retried_after_failure': E('F_RETRIED') == '1',
                 'failed_jobs_in_last_pass': num('F_FAILED_JOBS'), 'of_which_compiler_killed_from_outside': num('F_KILLED_JOBS'),
                 'of_which_compiler_crashed': num('F_CRASHED_JOBS'),
                 'restart_tests': {'plain_restart': {'finished_modules_recompiled': num('F_RCONTROL'), 'new_modules_built': num('F_RCONTROL_NEW')},
                                   'restart_after_pruning': {'finished_modules_recompiled': num('F_RPRUNE'), 'new_modules_built': num('F_RPRUNE_NEW')}}},
    'seal': {'source_tree_unchanged_since_extraction': yes('F_SRC_SAME'),
             'toolchain_and_mathlib_unchanged_since_before_first_compile': yes('F_LIBS_SAME'),
             'sealed_copy_of_toolchain_matches': yes('F_TC_COPY'),
             'half_written_files_of_killed_compilers_removed': num('F_LEFTOVERS'),
             'files_beside_the_compiled_modules_that_the_build_does_not_write': num('F_LIB_OTHER'),
             'compiled_files_manifest_sha256': E('F_MANIFEST') or None},
    'c2_axioms': {'plain_exit_status': num('F_C2P'), 'deep_exit_status': num('F_C2D'), 'deep_walk_ran': E('F_C2WHEN'),
                  'plain': axioms('plain.json'), 'deep': axioms('deep.json')},
    # Criterion C3: leanchecker on every compiled module. 'conditions_all_hold' is the summary's own reading of
    # its four conditions; the summary, with every count behind them, is given whole below.
    'c3_kernel_replay': {'tool': 'leanchecker',
                         # how the tool was run, as each of its passes recorded it: 'import-closure-directory' is
                         # one process per module with only the module's import closure on the search path
                         'passes_by_how_the_tool_was_run': (c3 or {}).get('leanchecker_passes_by_how_it_was_run'),
                         'conditions': (c3 or {}).get('criterion_c3', {}).get('conditions'),
                         'conditions_all_hold': (c3 or {}).get('criterion_c3', {}).get('all_hold'),
                         'last_exit_status': num('F_C3'), 'jobs': num('F_CJOBS'),
                         # from the trials: modules a second at the chosen job count, the seconds the whole tree
                         # would then need, and whether that fitted in the time left (if not, the replay was cut short)
                         'trial_rate_modules_per_second': E('F_C3_RATE') or None, 'expected_seconds': num('F_C3_EXPECT'), 'expected_to_fit': yes('F_C3_FITS'),
                         # the time the main pass was allowed, and how many passes there were in all (the main one
                         # and any for modules whose checker was cut off); with expected_to_fit false, one short pass
                         'main_pass_seconds_allowed': num('F_C3_MAIN_T'), 'passes_after_the_trials': num('F_C3_PASSES'),
                         'summary': c3},
    # Not part of any criterion: the same replay by a second program, when it was asked for. Its passes count
    # for nothing above; a rejection or crash by it makes 'no_rejection_or_crash_recorded_by_any_tool' false.
    'second_replay': None if E('F_SECOND') != 'rhv-replay' else {
        'program': 'rhv-replay', 'sha256': E('F_DRIVER_SHA') or None, 'unchanged_since_it_was_built': yes('F_DRIVER_SAME'),
        'source_check': (open(os.path.join(E('F_PD'), 'driver_check.txt')).read().strip().splitlines()
                         if os.path.isfile(os.path.join(E('F_PD'), 'driver_check.txt')) else None),
        'exit_status': num('F_SECOND_RC'), 'not_run_because': E('F_SECOND_WHY') or None,
        # null when it did not run: the summary's two answers would then read as a failed check
        'result': (c3 or {}).get('second_replay_by_rhv_replay') if E('F_SECOND_RC') else None},
    'end': {'compiled_files_unchanged_since_seal': yes('F_OLEANS_END'), 'toolchain_and_mathlib_unchanged_since_seal': yes('F_LIBS_END'),
            'build_user_process_seen_after_seal': os.path.exists(seen)},
    'archive_of_compiled_files': {'state': E('F_KEEP_STATE'), 'objects_uploaded': num('F_KEEP')},
}
if E('F_SPOT') == '1':
    # A Spot run: this attempt, the run's attempts as the state records them (when each booted, where, how it
    # ended, the stage it reached, what it restored, whether its baselines matched the first attempt's), and
    # whether a process of the build user was seen after the seal, attempt by attempt.
    st = load(E('F_SPOT_STATE')) or {}
    att = st.get('attempts') or []
    for a in att:
        if str(a.get('n')) == E('F_ATTEMPT'): a['build_user_process_seen_after_seal'] = os.path.exists(seen)
    def spd(name):    # a number this attempt keeps in a file (the confirms run in a loop of their own)
        try: return int(open(os.path.join(E('F_SPD'), name)).read().split()[0])
        except Exception: return None
    # The run's count of failed job lines: every other attempt's, as its state entry records it, and this one's.
    if num('F_NFAIL') is not None:
        facts['c1_build']['failed_job_lines_in_all_logs'] = num('F_NFAIL') + sum(
            int(a.get('failed_job_lines') or 0) for a in att if str(a.get('n')) != E('F_ATTEMPT'))
    here = lambda k: num(k + '_HERE') if E(k + '_HERE') else num(k)
    facts['spot'] = {'attempt': num('F_ATTEMPT'), 'attempts': att, 'units_done': st.get('done'), 'progress': st.get('progress'),
                     'build_user_process_seen_after_seal': {str(a.get('n')): a.get('build_user_process_seen_after_seal') for a in att},
                     # the end check's comparison, made on this machine before any result left it (G1)
                     'confirm_every_s': num('F_CONFIRM_EVERY'), 'confirms': spd('confirms') or 0, 'last_confirm_seconds': spd('last_confirm_s'),
                     # at the first seal: whether the parts reproduce the sealed compiled files exactly, and how
                     # many files a repair part had to add for that
                     'parts_cover_seal': st.get('parts_cover_seal'), 'parts_cover_repair_files': st.get('parts_cover_repair_files'),
                     # saved compiled files the build tool wrote again with the very bytes saved (a new time only),
                     # and so saved again in a later part; any other change to a saved file ends the run
                     'files_rewritten_same_bytes': st.get('files_rewritten_same_bytes', 0),
                     # the saved replay results a later attempt restores: the object and the SHA-256 it must have
                     'results_object': st.get('results_object'), 'results_sha256': st.get('results_sha256'),
                     'per_attempt_files': 'files under attempt-N/ are that machine\'s logs and working copies; only what the state '
                                          'records, saved after a confirm, is carried between machines',
                     # this machine's own figures, where the ones above are the run's
                     'this_machine': {'failed_job_lines': num('F_NFAIL'),
                                      'half_written_files_of_killed_compilers_removed': here('F_LEFTOVERS'),
                                      'files_beside_the_compiled_modules_that_the_build_does_not_write': here('F_LIB_OTHER')}}
json.dump(facts, open(sys.argv[1], 'w'), indent=1)
PY
}
report() { # report <state> <message>   -- logs and facts.json. Safe to call more than once. Status of the facts upload.
  put_logs
  disk_facts; gcs_put "$PD/disk.txt" "$RES/disk.txt"
  c3_summary
  write_facts "$1" "$2"
  gcs_put "$PD/facts.json" "$RT/facts.json"
}
# checkpoint <message>: facts as they stand, so that a run cut short still leaves an account of how far it got.
checkpoint() { write_facts RUNNING "$1"; gcs_put "$PD/facts.json" "$RT/facts.json"; return 0; }
finish() { # finish <state> <message>   -- the final status is uploaded LAST: it is the watcher's signal to delete this VM
  trap '' TERM INT
  [ "$SPOT" = 1 ] && spot_not_final "$1" "$2"  # Spot: a deadline or a reclaim ends only this attempt (does not return then)
  touch "$PD/FINISHING"                      # tells the watchdog that the report is under way
  say "FINISH $1: $2"
  stop_build
  local p i
  for p in "${SAMPLER_PID:-}" "${SYNC_PID:-}" "${PROG_PID:-}" "${GUARD_PID:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done
  [ "$SPOT" = 1 ] && spot_stop_loops
  [ -n "${SYNC_PID:-}" ] && wait "$SYNC_PID" 2>/dev/null       # no RUNNING status or half-made upload may follow the final one
  [ -n "${PROG_PID:-}" ] && wait "$PROG_PID" 2>/dev/null
  kill_users
  for i in 1 2 3; do report "$1" "$2" && break; sleep 20; done
  sync_big; sync_small
  [ "$SPOT" = 1 ] && spot_final "$1" "$2"      # the state says the run is over before the status does
  status "$PHASE" "$1" "$2"
  say "idle: waiting to be deleted"; sync
  idle_until_deleted
}
t_step() { # t_step <name> <function>  -- time a setup step; a failed step ends the run
  # (Spot: a failed step that needs the network ends only this attempt; a fresh machine tries it again.)
  local name=$1; shift; local s; s=$(now); say "setup: $name"
  if "$@"; then printf '%s\t%s\tok\n' "$name" "$(( $(now) - s ))" >> "$PD/setup.tsv"
  elif [ "$SPOT" = 1 ] && case " packages elan source mathlib_cache " in *" $name "*) true ;; *) false ;; esac; then
    printf '%s\t%s\tFAILED\n' "$name" "$(( $(now) - s ))" >> "$PD/setup.tsv"; spot_pause "setup step failed: $name; a fresh machine tries again" retry
  else printf '%s\t%s\tFAILED\n' "$name" "$(( $(now) - s ))" >> "$PD/setup.tsv"; finish FAIL "setup step failed: $name"; fi
}
on_signal() { if [ -e "$PD/DEADLINE" ]; then finish DEADLINE "guest deadline reached during phase $PHASE"; else finish FAIL "unexpected signal"; fi; }
# The watchdog kills helper processes at the deadline, which can leave a half-written file behind. Nothing may be
# concluded from such a file: call this before judging any result that took time to produce.
deadline_check() { [ -e "$PD/DEADLINE" ] && finish DEADLINE "guest deadline reached during phase $PHASE"; return 0; }

# ---------------------------------------------------------------- Spot (full-spot=1) only
# Google may take a Spot machine back at any moment, with at most about thirty seconds' notice and possibly none.
# The run therefore keeps, in the bucket under ckpt/RUNTAG, everything a fresh machine needs to carry on: archives
# of finished modules ("parts") with a manifest of their checksums, and a state file of every decision and result
# so far. Upload order is always part, then manifest, then state, so that whatever is in the bucket after a cut
# is consistent: a part the manifest does not list is ignored, and a unit the state does not record as complete
# is run again in full. Two non-final states end only this attempt: RECLAIMED (the machine is being taken back)
# and PAUSED (this attempt's own deadline, or trouble a fresh machine may not have; the status says which kind,
# see spot_pause). The controller then starts the next attempt, unless the kind says another would end the same way.
if [ "$SPOT" = 1 ]; then
SPOT_WATCH_PID=""
status() { # status <phase> <state> <message> [pause kind]   -- as above, plus the attempt and, for PAUSED, the kind
  # of pause (deadline, retry, parts-limit or stop; see spot_pause). Once Google has said it is taking the machine
  # back, only RECLAIMED goes out (and a failure that ends the run whatever else happens: see spot_confirm).
  PHASE=$1
  [ -e "$PD/PREEMPTED" ] && [ "$2" != RECLAIMED ] && ! { [ "$2" = FAIL ] && [ -e "$PD/FAIL_IS_FINAL" ]; } && return 0
  python3 - "$PD/status.json" "$1" "$2" "${3:-}" "$T0" "$DEADLINE" "$MODE" "$NMAX" "$ATTEMPT" "${4:-}" <<'PY'
import json, os, sys, time
p, phase, state, msg, t0, dl, mode, nmax, att, kind = sys.argv[1:11]
d = {"phase": phase, "state": state, "message": msg, "elapsed_s": int(time.time()) - int(t0),
     "deadline_in_s": int(dl) - int(time.time()), "mode": mode, "nmax": int(nmax), "utc": time.strftime("%FT%TZ", time.gmtime()),
     "attempt": int(att), "spot": 1}
if state == "PAUSED": d["pause"] = kind or "deadline"
json.dump(d, open(p + ".tmp", "w"))
os.replace(p + ".tmp", p)
PY
  gcs_put "$PD/status.json" "$RT/status.json"
}
# The heartbeat is the run's (the controller watches one); the logs are this attempt's.
sync_small() { local f; date +%s > "$PD/heartbeat"; gcs_put "$PD/heartbeat" "$RT/heartbeat"; for f in pilot.log setup.tsv phases.tsv env.txt progress.tsv restart_tests.txt spot.log; do gcs_put "$PD/$f" "$RES/$f"; done; }
# Root reads the build tool's logs only as copies of its own: spot_lake_copies makes, afresh, a copy of each log
# lake_logs names (safe_cp: a plain file, never through a link, in limited time) in $SPD/lakelogs, and prints the
# copies' paths; a log that cannot be copied is skipped, with a line in spot.log. The count of failed job lines is
# taken from those copies (0 before $SPD exists), so that a log the build user swaps for a pipe never blocks root.
spot_lake_copies() {
  local f c t d=$SPD/lakelogs
  [ -d "$SPD" ] || return 0
  mkdir -p "$d" || return 0
  for f in $(lake_logs); do
    c="$d/$(basename "$f")"; t=$(mktemp "$c.XXXXXX") || continue
    if safe_cp "$f" "$t" && plain "$t"; then mv -f "$t" "$c" && echo "$c"
    else rm -f "$t"; spot_log "the build log $(basename "$f") could not be copied as a plain file; not read"; fi
  done
  return 0
}
failed_lines() { local f k c=0; [ -d "$SPD" ] || { echo 0; return 0; }; for f in $(spot_lake_copies); do k=$(grep -c '^✖ ' "$f"); c=$((c + k)); done; echo "$c"; }
# A terminate signal without the deadline marker is the operating system shutting down: Google is taking the
# machine back (with or without the notice the watcher below waits for).
on_signal() { if [ -e "$PD/DEADLINE" ]; then finish DEADLINE "guest deadline reached during phase $PHASE"; else spot_reclaimed "the operating system is shutting down"; fi; }
deadline_check() {
  [ -e "$PD/HARD_FAIL_MSG" ] && finish FAIL "$(cat "$PD/HARD_FAIL_MSG")"     # a confirm found a change (final)
  [ -e "$PD/PREEMPTED" ] && spot_reclaimed "Google is taking the machine back"
  [ -e "$PD/DEADLINE" ] && finish DEADLINE "guest deadline reached during phase $PHASE"; return 0
}
# spot_state <arguments for "spot_checkpoint.sh state">: change the local state file, then upload it whole. One
# writer at a time (the main script, the loops and the watcher all write it). Status 1 if either step failed;
# the local file then still holds the change, and the next upload carries it.
spot_state() {
  [ -e "$PD/STATE_READY" ] || return 1
  ( flock -w "${SPOT_LOCK_WAIT:-600}" 9 || exit 1
    bash "$SPK" state --file "$SPS" --attempt "$ATTEMPT" "$@" 2>> "$PD/spot.log" && gcs_put "$SPS" "$CK/state.json" ) 9> "$PD/state.lock"
}
# spot_record <unit or -> <stage or -> NAME...: remember these variables and, if a unit is named, that it is
# complete. Refused once the deadline or a reclaim has begun: what was running then may have been cut short.
spot_record() {
  { [ -e "$PD/PREEMPTED" ] || [ -e "$PD/DEADLINE" ]; } && return 1
  local u=$1 st=$2 n seen=false a=(); shift 2
  if [ -e "$PD/build_user_seen_after_seal" ]; then
    seen=true; case " $SEEN_ATTEMPTS " in *" $ATTEMPT "*) ;; *) SEEN_ATTEMPTS="${SEEN_ATTEMPTS:+$SEEN_ATTEMPTS }$ATTEMPT" ;; esac
  fi
  for n in "$@" SEEN_ATTEMPTS; do a+=(--var "$n=${!n-}"); done
  [ "$u" = - ] || a+=(--done "$u")
  [ "$st" = - ] || a+=(--set "stage=$st" --attempt-set "stage_reached=$st")
  spot_state "${a[@]}" --attempt-set-json "build_user_process_seen_after_seal=$seen" --attempt-set-json "failed_job_lines=$(failed_lines)" && return 0
  say "WARNING: the state was not saved (unit ${u}); it is uploaded again with the next change"; return 1
}
# spot_load [NAME...]: set these variables (by default every name the state may hold) from the state. Only
# names from that list are asked for, and the helper prints each value quoted for the shell.
spot_load() { local s; s=$(bash "$SPK" state-export --file "$SPS" ${*:-$SPOT_VARS} 2>> "$PD/spot.log") || return 1; eval "$s"; }
spot_done() { bash "$SPK" state-get --file "$SPS" --done "$1" 2>/dev/null; }
spot_saved() { local v; v=$(bash "$SPK" state-get --file "$SPS" --key "$1" 2>/dev/null); case "$v" in ''|*[!0-9]*) echo 0 ;; *) echo "$v" ;; esac; }
# spot_fetch <object> <file>: status 0 fetched whole, 4 there is no such object, 1 any other failure. curl's own
# status counts as well as the server's: a transfer cut off after the headers has code 200 and a short file.
spot_fetch() {
  local code rc
  code=$(curl -s --connect-timeout 20 --speed-limit 1024 --speed-time 120 --retry 4 --retry-delay 3 -w '%{http_code}' -H "Authorization: Bearer $(tok)" \
    "https://storage.googleapis.com/storage/v1/b/$BUCKET/o/$(enc "$1")?alt=media" -o "$2"); rc=$?
  [ "$rc" = 0 ] && [ "$code" = 200 ] && return 0
  rm -f "$2"
  [ "$rc" = 0 ] && [ "$code" = 404 ] && return 4
  return 1
}
# spot_fetch_checked <object> <file> <sha256> [bytes] [gz]: up to three downloads, each checked against the
# SHA-256 (of the file, or with "gz" of its uncompressed content) and, if given, the size. Status 0 one matched;
# 4 the object is not there; 1 the downloads failed or had the wrong size (trouble on the way: worth trying again
# on another machine); 2 three complete downloads of the right size, every one with the wrong checksum (the
# object really is not the one recorded).
spot_fetch_checked() {
  local i rc got trouble=0
  for i in 1 2 3; do
    spot_fetch "$1" "$2"; rc=$?
    [ "$rc" = 4 ] && return 4
    if [ "$rc" != 0 ]; then trouble=1
    elif [ -n "${4:-}" ] && [ "$(stat -c %s "$2")" != "$4" ]; then trouble=1
    else
      if [ "${5:-}" = gz ]; then got=$(gunzip -c "$2" 2>/dev/null | sha256sum | cut -d' ' -f1); else got=$(sha256sum < "$2" | cut -d' ' -f1); fi
      [ "$got" = "$3" ] && return 0
      echo "$(date -u +%FT%TZ) $1: download $i has sha256 $got, expected $3" >> "$PD/spot.log"
    fi
    [ "$i" = 3 ] || sleep $(( i * 5 ))
  done
  rm -f "$2"
  [ "$trouble" = 0 ] && return 2
  return 1
}
spot_stop_loops() { # spot_stop_loops [gently]: the part loop (allowed to finish the round it is in) and the results loop
  local p w=0
  if [ "${1:-}" = gently ] && [ -n "$SPOT_CKPT_PID" ]; then
    touch "$SPD/STOP"; while kill -0 "$SPOT_CKPT_PID" 2>/dev/null && [ "$w" -lt 120 ]; do sleep 2; w=$((w + 2)); done
  fi
  touch "$SPD/STOP" 2>/dev/null
  for p in "$SPOT_CKPT_PID" "$SPOT_RES_PID"; do [ -n "$p" ] && { pkill -TERM -P "$p" 2>/dev/null; kill "$p" 2>/dev/null; wait "$p" 2>/dev/null; }; done
  SPOT_CKPT_PID=""; SPOT_RES_PID=""
  return 0
}
# A cut (reclaim or deadline) ends only this attempt; any other outcome is the run's. A failure a confirm or the
# end check found (FAIL_IS_FINAL) is the run's whatever markers exist: it is never turned into PAUSED or RECLAIMED.
spot_not_final() { # spot_not_final <state> <message>   -- does not return if this attempt is to pause or is being reclaimed
  if [ "$1" = FAIL ] && [ -e "$PD/FAIL_IS_FINAL" ]; then
    [ -n "$SPOT_WATCH_PID" ] && kill "$SPOT_WATCH_PID" 2>/dev/null
    touch "$PD/STOPPING"
    SPOT_LOCK_WAIT=60 spot_state --set-json final=true --set outcome=FAIL --attempt-set ended=FAIL || say "WARNING: the final state was not uploaded"
    return 0
  fi
  [ -e "$PD/PREEMPTED" ] && spot_reclaimed "$2"
  [ "$1" = DONE ] && { touch "$PD/STOPPING"; return 0; }
  { [ "$1" = DEADLINE ] || [ -e "$PD/DEADLINE" ]; } && spot_pause "$2" deadline
  touch "$PD/STOPPING"; return 0              # the run is ending: a confirm still running proves nothing now
}
spot_final() { # the run is over: the state says so before the final status does
  [ -n "$SPOT_WATCH_PID" ] && kill "$SPOT_WATCH_PID" 2>/dev/null
  spot_state --set-json final=true --set "outcome=$1" --attempt-set "ended=$1" --attempt-set-json "failed_job_lines=$(failed_lines)" \
    || say "WARNING: the final state was not uploaded"
  return 0
}
# This attempt ends here, the run does not: save what can be saved, then stop. The status and this attempt's
# entry in the state say what kind of pause it is, so that the controller knows whether another attempt helps:
#   deadline     this attempt ran out of its own time (the default when the deadline marker exists)
#   retry        trouble a fresh machine may not have: a fetch or an upload that failed, results that could not
#                be confirmed and saved, a check ended by a signal, a setup step that needs the network (the
#                default otherwise)
#   parts-limit  the parts would pass full-parts-max-bytes (spot_too_big_msg)
#   stop         another attempt would end the same way (a state exists that the controller did not see)
spot_pause() { # spot_pause <message> [kind]   -- does not return
  trap '' TERM INT
  [ -e "$PD/PREEMPTED" ] && spot_reclaimed "$1"
  local kind=${2:-}
  [ -n "$kind" ] || { if [ -e "$PD/DEADLINE" ]; then kind=deadline; else kind=retry; fi; }
  touch "$PD/FINISHING"; say "PAUSE ($kind): $1"
  local p cutting=0
  [ -n "$SPOT_CKPT_PID" ] && cutting=1
  spot_stop_loops gently                    # the part loop may finish the round it is in
  stop_build
  for p in "${SAMPLER_PID:-}" "${PROG_PID:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done
  kill_users                                # nothing of the build user runs while the last part is cut
  # The build was running: one last part of what finished before it was stopped, in limited time.
  [ "$cutting" = 1 ] && SPOT_CUT_LIMIT=300 spot_ckpt_round pause >/dev/null
  # The replay's results, if a confirm can still be completed (not once the deadline or a reclaim has begun).
  spot_results_round "$NMAX"; [ "$?" = 2 ] && finish FAIL "$(cat "$PD/HARD_FAIL_MSG")"
  # The state write that ends the attempt also carries the work the manifest lists as saved, so that a part whose
  # own state write was cut off (the part loop stopped after the manifest went up) still counts as progress.
  local pm=0
  [ -f "$SPD/manifest.tsv" ] && pm=$(awk -F'\t' 'NR > 1 {s += $5} END {print s + 0}' "$SPD/manifest.tsv")
  spot_state --attempt-set ended=PAUSED --attempt-set "pause_kind=$kind" --attempt-set "ended_why=$1" --attempt-set-json "failed_job_lines=$(failed_lines)" \
    --parts-modules "$pm" --var "TIMEBOX_USED=$(spot_timebox_saved)"
  kill_users
  put_logs; write_facts PAUSED "$1"; gcs_put "$PD/facts.json" "$RT/facts.json"; sync_big; sync_small
  local after="the run continues on the next attempt"
  case "$kind" in
    stop) after="the run is paused until you have looked" ;;
    parts-limit) after="the run continues on an attempt in the bucket's own region" ;;
  esac
  status "$PHASE" PAUSED "$1; $after" "$kind"
  [ -n "$SPOT_WATCH_PID" ] && kill "$SPOT_WATCH_PID" 2>/dev/null
  say "idle: waiting to be deleted"; sync
  idle_until_deleted
}
# "--parts-modules N", N the modules the local manifest lists (it is moved into place only once uploaded), or
# nothing when there is no manifest: the RECLAIMED state writes count a part whose own state write was cut off.
spot_parts_arg() { [ -f "$SPD/manifest.tsv" ] && awk -F'\t' 'NR > 1 {s += $5} END {print "--parts-modules", s + 0}' "$SPD/manifest.tsv" 2>/dev/null; return 0; }
# Google is taking the machine back: within seconds, and nothing that takes long. The watcher below has usually
# done this already; the main script repeats only what it has not. No results go up: there is no time to confirm
# them, and the next attempt checks again whatever was not confirmed.
spot_reclaimed() { # spot_reclaimed <why>   -- does not return
  trap '' TERM INT
  touch "$PD/PREEMPTED" "$PD/FINISHING"; say "RECLAIMED: $1"
  pkill -KILL -x lean 2>/dev/null; pkill -KILL -x leanchecker 2>/dev/null; pkill -KILL -x rhv-replay 2>/dev/null; pkill -KILL -x lake 2>/dev/null
  spot_stop_loops
  if [ ! -e "$PD/RECLAIM_SENT" ]; then
    # shellcheck disable=SC2046
    SPOT_LOCK_WAIT=5 spot_state --attempt-set ended=RECLAIMED $(spot_parts_arg)
    status "$PHASE" RECLAIMED "$1; the run continues on the next attempt"; touch "$PD/RECLAIM_SENT"
  fi
  idle_until_deleted
}
# Waits on the metadata server for Google's notice. It cannot be relied on (a machine can go with no notice at
# all), so nothing depends on it: it only stops the work in flight a little sooner. Each answer's ETag is passed
# back with the next wait, as Google's documentation of the metadata server asks, so that a change between two
# requests is not missed. Without a usable ETag (or without an answer) there is no wait: it asks again every
# five seconds instead, so that it never spins.
spot_watch_preempted() {
  local v etag="" q told=0
  while true; do
    q=""; [ -n "$etag" ] && q="?wait_for_change=true&timeout_sec=300&last_etag=$etag"
    v=$(curl -sf --connect-timeout 5 --max-time 330 -D "$PD/preempt.hdr" -H "Metadata-Flavor: Google" "$MDURL/preempted$q" 2>/dev/null)
    [ "$v" = TRUE ] && break
    etag=$(awk 'tolower($1) == "etag:" {print $2; exit}' "$PD/preempt.hdr" 2>/dev/null | tr -d '\r')
    case "$etag" in *[!0-9A-Za-z]*) etag="" ;; esac
    [ -n "$v" ] || etag=""                    # no answer: ask again shortly, from the start
    if [ -z "$etag" ]; then
      [ "$told" = 1 ] || { spot_log "preemption watcher: no answer or no usable ETag from the metadata server; wait_for_change is not in use, asking every 5 s"; told=1; }
      sleep 5
    fi
  done
  touch "$PD/PREEMPTED"; say "Google is taking the machine back"
  kill -TERM "$$" 2>/dev/null
  pkill -KILL -x lean 2>/dev/null; pkill -KILL -x leanchecker 2>/dev/null; pkill -KILL -x rhv-replay 2>/dev/null; pkill -TERM -x lake 2>/dev/null
  # shellcheck disable=SC2046
  SPOT_LOCK_WAIT=5 spot_state --attempt-set ended=RECLAIMED $(spot_parts_arg)
  status "$(cat "$PD/phase" 2>/dev/null || echo "$PHASE")" RECLAIMED "Google took the machine back; the run continues on the next attempt"
  touch "$PD/RECLAIM_SENT"
}
spot_log() { echo "$(date -u +%FT%TZ) $*" >> "$PD/spot.log"; }

# ---- confirming: nothing that is evidence leaves this machine unless this machine shows that nothing changed
# spot_confirm [jobs]: what the end check computes (the fingerprints of the compiled files, of Mathlib's compiled
# files and of the sealed toolchain), now, compared with the seal's; and no process of the build user seen. With
# at most <jobs> hashing processes (4 while a check is running). Status 0 all as sealed; 1 abandoned, nothing
# concluded (a reclaim, the deadline or the end of the run began while it ran: the hashing may have been cut
# off); 2 a difference or a sighting: that ends the run, whatever else happens. The message is then in
# $PD/HARD_FAIL_MSG and $PD/FAIL_IS_FINAL exists; this function does not end the run itself (it also runs in the
# results loop), so the main script's next deadline_check does, or spot_confirmed below.
spot_confirm() {
  local j=${1:-4} t0 rc
  [ -s "$PD/lib_sha256.txt" ] || return 1
  spot_cut_begun && return 1
  t0=$(now)
  ( flock -w 3600 7 || exit 1
    spot_sighted && exit 2
    for try in 1 2; do
      ( NMAX=$j; lib_manifest > "$SPD/confirm_lib.txt"; pkgs_manifest > "$SPD/confirm_pkgs.txt"; tc_manifest /opt/lean-tc > "$SPD/confirm_tc.txt" )
      spot_cut_begun && exit 1
      cmp -s "$PD/lib_sha256.txt" "$SPD/confirm_lib.txt" && cmp -s "$PD/baseline_pkgs.txt" "$SPD/confirm_pkgs.txt" && cmp -s "$PD/baseline_tc.txt" "$SPD/confirm_tc.txt" && break
      # A difference. Something outside may have cut the hashing short: look at the markers again, then hash
      # once more before concluding anything.
      sleep 2; spot_cut_begun && exit 1
      if [ "$try" = 2 ]; then
        diff "$PD/lib_sha256.txt" "$SPD/confirm_lib.txt" | head -200 > "$PD/changed_confirm_lib.txt"
        diff "$PD/baseline_pkgs.txt" "$SPD/confirm_pkgs.txt" | head -200 > "$PD/changed_confirm_pkgs.txt"
        diff "$PD/baseline_tc.txt" "$SPD/confirm_tc.txt" | head -200 > "$PD/changed_confirm_tc.txt"
        for f in lib pkgs tc; do [ -s "$PD/changed_confirm_$f.txt" ] && gcs_put "$PD/changed_confirm_$f.txt" "$RES/changed_confirm_$f.txt"; done
        echo "files the checks rely on changed while the checks ran; their results cannot be used" > "$PD/HARD_FAIL_MSG.new"
        touch "$PD/FAIL_IS_FINAL"; mv -f "$PD/HARD_FAIL_MSG.new" "$PD/HARD_FAIL_MSG"
        exit 2
      fi
    done
    spot_sighted && exit 2
    exit 0 ) 7> "$PD/confirm.lock"
  rc=$?
  if [ "$rc" = 0 ]; then
    echo $(( $(cat "$SPD/confirms" 2>/dev/null || echo 0) + 1 )) > "$SPD/confirms"; echo $(( $(now) - t0 )) > "$SPD/last_confirm_s"
    spot_log "confirm: as sealed, in $(( $(now) - t0 )) s with $j hashing processes"
  else
    spot_log "confirm: status $rc after $(( $(now) - t0 )) s"
  fi
  return "$rc"
}
spot_cut_begun() { [ -e "$PD/PREEMPTED" ] || [ -e "$PD/DEADLINE" ] || [ -e "$PD/STOPPING" ]; }
spot_sighted() { # a process of the build user seen after the seal: HEAD's end-check message, final
  [ -e "$PD/build_user_seen_after_seal" ] || return 1
  echo "a process of the build user appeared after the seal; the checks' results cannot be used" > "$PD/HARD_FAIL_MSG.new"
  touch "$PD/FAIL_IS_FINAL"; mv -f "$PD/HARD_FAIL_MSG.new" "$PD/HARD_FAIL_MSG"
}
spot_confirmed() { # main script only: spot_confirm, and the end of the run on a difference. Status 0 or 1 as spot_confirm.
  spot_confirm "$@"
  case "$?" in 0) return 0 ;; 2) finish FAIL "$(cat "$PD/HARD_FAIL_MSG")" ;; esac
  return 1
}
# spot_check_cut <status> <epoch its time limit ends>: a check ended by a signal (129, 130, 137, 143, or no status
# at all, 99 here) before its own time limit is not a result: wait a moment, look at the markers (a deadline or a
# reclaim acts), and otherwise stop this attempt without recording the unit; the next attempt runs it again. A
# check its own time limit stopped is a result like any other (timeout's 124, or 137 after --kill-after).
spot_check_cut() {
  case "$1" in 129|130|137|143|99|'') ;; *) return 0 ;; esac
  [ "$(now)" -ge $(( $2 - 1 )) ] && return 0
  sleep 2; deadline_check
  spot_pause "a check was ended by a signal (status $1) before its own time limit; it runs again on the next attempt"
}

# ---- parts
# spot_ckpt_round <loop|final|pause|repair>: one part of the finished modules not yet saved, uploaded, then the
# manifest, then the state. Status 0 a part was saved, 3 nothing was due, 4 a saved module was compiled again,
# 5 the part would take all the parts past full-parts-max-bytes (not uploaded), 1 a failure (the next round tries
# again; nothing is lost). The cut runs as the build user, on its own tree, with the archive on its standard
# output, which root has opened onto a file of its own: root never opens a path the build user can write. Root
# then reads its own copy for what the part holds (each file with its size, time and SHA-256). A repair part
# (at the first seal, the build user locked) is cut by root, of exactly the files in $SPD/cover_fix.txt.
spot_ckpt_round() {
  [ -e "$PD/PREEMPTED" ] && return 1
  local t ep args rc seq obj sha bytes mods files sum tc tu same LAKE_N
  if [ -e "$SPD/pending.sha" ]; then spot_apply_pending || return 1; fi
  t=$(now)
  case "$1" in
    loop) ep=$(( t - 5 )); args=(--settle-before "$ep") ;;    # a trace older than this was written whole
    pause) ep=$t; args=(--settle-before "$ep") ;;             # the build tool has just been stopped
    repair) ep=$t; args=(--paths-from "$SPD/cover_fix.txt") ;;
    *) ep=$t; args=(--all) ;;                                 # the build has ended: everything that is left
  esac
  rm -f "$SPD/part" "$SPD/part.done" "$SPD/part.members.gz" "$SPD/cut.err"
  if [ "$1" = repair ]; then
    timeout "${SPOT_CUT_LIMIT:-900}" bash "$SPK" cut --build-dir "$PROJ/.lake/build" "${args[@]}" --out - > "$SPD/part" 2> "$SPD/cut.err"; rc=$?
  else
    rm -rf "${WORK:?}/spot-out" && mkdir -m 700 "$SPOUT" && cp "$SPD/done.txt" "$SPOUT/done.txt" && chown -R pilot:pilot "$SPOUT" || return 1
    timeout "${SPOT_CUT_LIMIT:-900}" runuser -u pilot -- bash "$SPK" cut --build-dir "$PROJ/.lake/build" --done "$SPOUT/done.txt" "${args[@]}" --out - > "$SPD/part" 2> "$SPD/cut.err"
    rc=$?
    rm -rf "${WORK:?}/spot-out"
  fi
  head -c 100000 "$SPD/cut.err" >> "$PD/spot.log"
  # Saved files the build tool wrote again with the very bytes saved (only their time is new): they go into this
  # part again. The count, from the cut's own summary line, is added up in the state once the part is saved.
  same=$(sed -n 's/.*; \([0-9][0-9]*\) files written again with the same bytes.*/\1/p' "$SPD/cut.err" | tail -1); same=${same:-0}
  case "$rc" in 0) ;; 3|4) rm -f "$SPD/part"; return "$rc" ;; *) rm -f "$SPD/part"; return 1 ;; esac
  bash "$SPK" list --part "$SPD/part" --members-out "$SPD/part.members.gz" --done-out "$SPD/part.done" 2>> "$PD/spot.log" \
    || { rm -f "$SPD/part" "$SPD/part.done" "$SPD/part.members.gz"; return 1; }
  tc=$(( $(now) - t ))
  sha=$(sha256sum "$SPD/part" | cut -d' ' -f1); bytes=$(stat -c %s "$SPD/part")
  # Its modules: the .trace files it holds that no earlier part holds (a repair part may hold one again), so that
  # the manifest's count is the count of distinct modules a restore finds.
  mods=$(awk -F'\t' 'FILENAME == ARGV[1] { s[$1] = 1; next } $1 ~ /^lib\/lean\/.+\.trace$/ && !($1 in s)' "$SPD/done.txt" "$SPD/part.done" | wc -l)
  files=$(wc -l < "$SPD/part.done")
  if [ "$PARTS_MAX" -gt 0 ]; then
    sum=$(awk -F'\t' 'NR > 1 {s += $4} END {printf "%d", s + 0}' "$SPD/manifest.tsv")
    if [ $(( sum + bytes )) -gt "$PARTS_MAX" ]; then
      rm -f "$SPD/part" "$SPD/part.done" "$SPD/part.members.gz"; touch "$SPD/TOO_BIG"
      spot_log "part not uploaded: $bytes bytes would take the parts from $sum past $PARTS_MAX bytes"; return 5
    fi
  fi
  seq=$(( $(cat "$SPD/seq") + 1 )); echo "$seq" > "$SPD/seq"     # never used twice, even if this round fails
  obj=$(printf '%s/part-%06d.tar.zst' "$CK" "$seq")
  t=$(now)
  gcs_put "$SPD/part" "$obj" || { rm -f "$SPD/part" "$SPD/part.done" "$SPD/part.members.gz"; spot_log "part $seq: upload failed after $(( $(now) - t )) s"; return 1; }
  tu=$(( $(now) - t ))
  rm -f "$SPD/part"
  # What an attempt cut off without notice would otherwise lose: the build tool's logs so far, uploaded with the
  # part, before the manifest. The part loop runs in a shell started before the build tool, so the logs are
  # counted here (lake_logs reads this local LAKE_N), not taken from that shell's copy of the count.
  LAKE_N=$(spot_lake_n)
  spot_put_lake_logs
  spot_log "part $seq ($1): $mods modules, $files files, $bytes bytes, $same files written again with the same bytes; cut and listed in $tc s, uploaded in $tu s"
  { cat "$SPD/manifest.tsv"; printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$seq" "$obj" "$sha" "$bytes" "$mods" "$ep" "$ATTEMPT"; } > "$SPD/manifest.new" || return 1
  mv -f "$SPD/part.done" "$SPD/pending.list" && mv -f "$SPD/part.members.gz" "$SPD/pending.members.gz" && echo "$seq" > "$SPD/pending.seq" \
    && echo "$ep" > "$SPD/pending.t" && echo "$same" > "$SPD/pending.same" && sha256sum < "$SPD/manifest.new" | cut -d' ' -f1 > "$SPD/pending.sha" || return 1
  spot_apply_pending || return 1
  say "part $seq: $mods modules, $bytes bytes"
}
# The new manifest goes up; only once it is there do the part's files count as saved. An upload that failed is
# tried again the next round, with the same manifest: the part it lists is already in the bucket. A round cut off
# after the manifest was moved into place leaves only the pending files, which are then cleared.
spot_apply_pending() {
  local tu want same LAKE_N
  want=$(cat "$SPD/pending.sha" 2>/dev/null)
  if [ ! -e "$SPD/manifest.new" ]; then
    if [ -n "$want" ] && [ "$(sha256sum < "$SPD/manifest.tsv" | cut -d' ' -f1)" = "$want" ]; then spot_log "pending part already applied; clearing"
    else spot_log "WARNING: pending files without a new manifest, and the manifest is not the pending one; clearing them (that part is not listed, and is never restored)"; fi
    rm -f "$SPD/pending.list" "$SPD/pending.members.gz" "$SPD/pending.seq" "$SPD/pending.sha" "$SPD/pending.t" "$SPD/pending.same"
    return 0
  fi
  gcs_put "$SPD/manifest.new" "$CK/manifest.tsv" || return 1
  if [ -e "$SPD/pending.members.gz" ]; then mv -f "$SPD/pending.members.gz" "$SPD/members/$(cat "$SPD/pending.seq").gz" || return 1; fi
  cat "$SPD/pending.list" >> "$SPD/done.txt" && mv -f "$SPD/manifest.new" "$SPD/manifest.tsv" || return 1
  tu=$(( $(cat "$SPD/pending.t") - $(cat "$PD/build_t0" 2>/dev/null || cat "$SPD/pending.t") ))
  same=$(cat "$SPD/pending.same" 2>/dev/null); case "$same" in ''|*[!0-9]*) same=0 ;; esac
  rm -f "$SPD/pending.list" "$SPD/pending.seq" "$SPD/pending.sha" "$SPD/pending.t" "$SPD/pending.same"
  # A rehearsal's time box counts only the build time whose work is saved.
  [ "$tu" -gt "${TIMEBOX_USED:-0}" ] && TIMEBOX_USED=$tu
  # The build tool's count of failed job lines so far (its logs went up with the part), from logs counted here, as
  # in spot_ckpt_round (lake_logs reads this local LAKE_N).
  LAKE_N=$(spot_lake_n)
  spot_state --parts-modules "$(awk -F'\t' 'NR > 1 {s += $5} END {print s + 0}' "$SPD/manifest.tsv")" --var "TIMEBOX_USED=$TIMEBOX_USED" \
    --set-int "files_rewritten_same_bytes=$(( $(spot_saved files_rewritten_same_bytes) + same ))" --attempt-set-json "failed_job_lines=$(failed_lines)" || return 0
}
# The number of the build tool's last log on this machine: the count this shell knows, or more if the main script
# has started the build tool again since (its logs are numbered 1, 2, ... with no gap).
spot_lake_n() { local n=${LAKE_N:-0}; while [ -e "$LOGS/lake_build_$((n + 1)).log" ] || [ -e "$PD/lake_build_$((n + 1)).log" ]; do n=$((n + 1)); done; echo "$n"; }
# The build tool's logs so far, from root's own copies (spot_lake_copies), uploaded compressed under the names
# put_logs gives them. A failed upload is noted and does no harm. Each log gets one try, of at most two minutes
# in all (not gcs_put's five), so that a stalled upload cannot hold the manifest back for long.
spot_put_lake_logs() {
  local c t
  for c in $(spot_lake_copies); do
    t=$(mktemp "$PD/.up.XXXXXX") || continue
    if ! { gzip -c "$c" > "$t" && curl -sf --connect-timeout 20 --max-time 120 -X POST -H "Authorization: Bearer $(tok)" -H "Content-Type: application/octet-stream" \
             -T "$t" "https://storage.googleapis.com/upload/storage/v1/b/$BUCKET/o?uploadType=media&name=$(enc "$RES/logs/$(basename "$c").gz")" -o /dev/null; }; then
      spot_log "WARNING: the build log $(basename "$c") was not uploaded with this part (one try, at most 120 s)"
    fi
    rm -f "$t"
  done
  return 0
}
# spot_timebox_saved: a rehearsal's time box counts only the build time whose work is saved. The largest of the
# value the state holds, this shell's, and that of the parts the manifest lists from this attempt (each part's cut
# time against the build's start): a pause never lowers it, and counts a part whose own state write was cut off.
spot_timebox_saved() {
  local s t0 m=0
  s=$(bash "$SPK" state-export --file "$SPS" TIMEBOX_USED 2>/dev/null | sed -n "s/^TIMEBOX_USED='\{0,1\}\([0-9][0-9]*\)'\{0,1\}$/\1/p")
  t0=$(cat "$PD/build_t0" 2>/dev/null); case "$t0" in ''|*[!0-9]*) t0="" ;; esac
  if [ -n "$t0" ] && [ -f "$SPD/manifest.tsv" ]; then
    m=$(awk -F'\t' -v a="$ATTEMPT" -v t0="$t0" 'NR > 1 && $7 == a && $6 - t0 > m {m = $6 - t0} END {printf "%d", m + 0}' "$SPD/manifest.tsv")
  fi
  case "${TIMEBOX_USED:-0}" in *[!0-9]*) ;; *) [ "${TIMEBOX_USED:-0}" -gt "$m" ] && m=${TIMEBOX_USED:-0} ;; esac
  [ -n "$s" ] && [ "$s" -gt "$m" ] && m=$s
  echo "$m"
}
spot_ckpt_loop_start() { # every CKPT_EVERY seconds while the build runs; a failed round never stops the build
  rm -f "$SPD/STOP"
  ( trap - TERM INT
    while true; do
      w=0; while [ "$w" -lt "$CKPT_EVERY" ]; do [ -e "$SPD/STOP" ] && exit 0; sleep 5; w=$((w + 5)); done
      spot_ckpt_round loop >/dev/null
      case "$?" in
        4) touch "$SPD/CHANGED"; spot_log "a module already saved in a part was compiled again"; exit 0 ;;
        5) exit 0 ;;                                         # TOO_BIG: the main script stops the attempt
      esac
    done ) & SPOT_CKPT_PID=$!
}
# Called by the build's monitor every twenty seconds: what the part loop found is acted on at once.
spot_build_check() {
  [ -e "$SPD/CHANGED" ] && finish FAIL "the build tool compiled again a module that was already saved in a part. This says nothing about the proof"
  [ -e "$SPD/TOO_BIG" ] && spot_pause "$(spot_too_big_msg)" parts-limit
  return 0
}
spot_too_big_msg() { echo "the parts would pass the size the cap test allows for an attempt outside the bucket's region ($PARTS_MAX bytes)"; }
# After the build: the restored modules must not have been compiled again, and what is left goes into the last
# part(s). A failed build is final, so nothing more is saved then.
spot_ckpt_final() {
  [ "$SEAL_DONE" = 1 ] && return 0
  local again=0 tries=0 rc f
  if [ -s "$SPD/restored.txt" ]; then
    # The smoke build's log is the build user's: root reads only its own copy (made in limited time, never
    # through a link); if that cannot be made, there is no smoke log to read, and spot.log says so. The same for
    # the build tool's logs (spot_lake_copies).
    rm -f "$SPD/smoke.log"
    safe_cp /tmp/smoke.log "$SPD/smoke.log" && plain "$SPD/smoke.log" || { rm -f "$SPD/smoke.log"; spot_log "no smoke log: /tmp/smoke.log could not be copied as a plain file"; }
    { built_in_log "$SPD/smoke.log"; for f in $(spot_lake_copies); do built_in_log "$f"; done; } | LC_ALL=C sort -u | LC_ALL=C comm -12 - "$SPD/restored.txt" > "$PD/restored_compiled_again.txt"
    again=$(wc -l < "$PD/restored_compiled_again.txt")
    spot_state --attempt-set-json "restored_modules_compiled_again=$again"
    [ "$again" = 0 ] || { gcs_put "$PD/restored_compiled_again.txt" "$RES/restored_compiled_again.txt"
      finish FAIL "the build tool compiled again $again of the modules restored from the parts; see restored_compiled_again.txt. This says nothing about the proof"; }
  fi
  [ -e "$SPD/CHANGED" ] && finish FAIL "the build tool compiled again a module that was already saved in a part. This says nothing about the proof"
  [ -e "$SPD/TOO_BIG" ] && spot_pause "$(spot_too_big_msg)" parts-limit
  [ "$C1_STATE" = failed ] && return 0
  status build RUNNING "saving the last compiled modules"
  while true; do
    spot_ckpt_round final; rc=$?
    case "$rc" in
      0) tries=0 ;;
      3) return 0 ;;
      4) finish FAIL "the build tool compiled again a module that was already saved in a part. This says nothing about the proof" ;;
      5) spot_pause "$(spot_too_big_msg)" parts-limit ;;
      *) tries=$((tries + 1)); [ "$tries" -ge 5 ] && spot_pause "the last part of the build could not be saved"; sleep 30 ;;
    esac
  done
}

# ---- replay results
# spot_results_round <jobs> [always]: a copy of the replay's results, trimmed to whole lines, taken FIRST; then a
# confirm; only then is that copy compressed (into a file of root's own), uploaded as $CK/results/NNNNNNNNN.tsv.gz
# (NNNNNNNNN its count of result lines; the header is not counted), and, in one state write, the count, the
# object's name and the SHA-256 of the compressed file recorded. Earlier objects are left where they are; only the
# one the state names is ever read. Lines written during the confirm wait for the next round. Without "always",
# nothing is done unless the copy holds more lines than are saved. One round at a time. Status 0 done (or nothing
# to do), 1 not confirmed or not uploaded (nothing is recorded; the lines are checked again later), 2 as spot_confirm.
spot_results_round() {
  plain "$AN/kernel_replay/results.tsv" || return 0
  [ -e "$PD/STATE_READY" ] || return 0
  local f="$SPD/results.snap.$BASHPID.tsv" n rc
  safe_cp "$AN/kernel_replay/results.tsv" "$f" && bash "$SPK" trim --file "$f" || { rm -f "$f"; return 1; }
  n=$(( $(wc -l < "$f") - 1 )); [ "$n" -ge 0 ] || n=0
  if [ "$n" -le "$(spot_saved results_saved)" ] && [ "${2:-}" != always ]; then rm -f "$f"; return 0; fi
  spot_confirm "$1"; rc=$?
  if [ "$rc" = 0 ] && [ "$n" -gt "$(spot_saved results_saved)" ]; then
    ( flock -w "${SPOT_LOCK_WAIT:-600}" 8 || exit 1
      # under the lock, again: a round that saved more lines meanwhile is never followed by an older object
      [ "$n" -gt "$(spot_saved results_saved)" ] || exit 0
      z="$f.gz"; obj=$(printf '%s/results/%09d.tsv.gz' "$CK" "$n")
      gzip -n -c < "$f" > "$z" && sha=$(sha256sum < "$z" | cut -d' ' -f1) && [ -n "$sha" ] && gcs_put "$z" "$obj" \
        && spot_state --results-saved "$n" --set "results_object=$obj" --set "results_sha256=$sha"; rc=$?
      rm -f "$z"; exit "$rc" ) 8> "$PD/results.lock"
    rc=$?; [ "$rc" = 0 ] && spot_log "results: $n lines confirmed and saved"
  fi
  rm -f "$f"; return "$rc"
}
# The results loop: every CONFIRM_EVERY seconds a round, and at once when a new line is a rejection or a crash
# (any status but a pass or one of the replay's not-run statuses, 96 97 98 129 130 137 143; or a damaged line):
# such a line must not wait twenty minutes to be saved. A confirm that finds a change stops the checks at once.
spot_res_loop_start() {
  ( trap - TERM INT
    last=$(now); seen=1
    while sleep 10; do
      [ -e "$PD/HARD_FAIL_MSG" ] && exit 0
      urgent=0
      if safe_cp "$AN/kernel_replay/results.tsv" "$SPD/results.peek" && bash "$SPK" trim --file "$SPD/results.peek"; then
        n=$(wc -l < "$SPD/results.peek")
        if [ "$n" -gt "$seen" ]; then
          awk -F'\t' -v s="$seen" 'NR > s && NR > 1 { if (NF < 8 || $2 !~ /^[0-9]+$/ || $2 !~ /^(0|96|97|98|129|130|137|143)$/) bad = 1 } END { exit !bad }' "$SPD/results.peek" && urgent=1
          seen=$n
        fi
      fi
      if [ "$urgent" = 1 ] || [ $(( $(now) - last )) -ge "$CONFIRM_EVERY" ]; then
        [ "$urgent" = 1 ] && spot_log "results: a rejection, crash or damaged line; confirming now"
        spot_results_round 4; [ "$?" = 2 ] && { kill_users; exit 0; }     # the main script's deadline_check ends the run
        last=$(now)
      fi
    done ) & SPOT_RES_PID=$!
}
spot_res_loop_stop() { # the loop stopped, then one last round, which always confirms. Status 0 confirmed and saved, 1 not.
  local rc
  if [ -n "$SPOT_RES_PID" ]; then pkill -TERM -P "$SPOT_RES_PID" 2>/dev/null; kill "$SPOT_RES_PID" 2>/dev/null; wait "$SPOT_RES_PID" 2>/dev/null; fi
  SPOT_RES_PID=""
  spot_results_round "$NMAX" always; rc=$?
  [ "$rc" = 2 ] && finish FAIL "$(cat "$PD/HARD_FAIL_MSG")"
  return "$rc"
}
# After a unit of checks: its results confirmed and saved before the unit is recorded, or this attempt stops and
# the next one does the unit again.
spot_unit_confirmed() {
  spot_res_loop_stop && return 0
  deadline_check
  spot_pause "the results of this step could not be confirmed on this machine and saved"
}
# On an attempt after the seal: the saved results go where the replay script reads them, so that it skips every
# module already passed (and keeps every rejection). The object, and the SHA-256 it must have, are the state's.
spot_results_restore() {
  local n rc obj sha
  n=$(spot_saved results_saved); [ "$n" -gt 0 ] || return 0
  obj=$(bash "$SPK" state-get --file "$SPS" --key results_object 2>/dev/null)
  sha=$(bash "$SPK" state-get --file "$SPS" --key results_sha256 2>/dev/null)
  [ -n "$obj" ] && [ -n "$sha" ] || finish FAIL "the state records $n saved replay results but names no object that holds them (or no SHA-256 for it)"
  spot_fetch_checked "$obj" "$SPD/results.tsv.gz" "$sha"; rc=$?
  case "$rc" in
    0) ;;
    2) finish FAIL "the saved replay results are not the ones the state records (three complete downloads)" ;;
    4) finish FAIL "the saved replay results the state records ($obj) are not in the bucket" ;;
    *) spot_pause "could not fetch the saved replay results (status $rc)" ;;
  esac
  gunzip -c "$SPD/results.tsv.gz" > "$PD/results_restored.tsv" && bash "$SPK" trim --file "$PD/results_restored.tsv" || spot_pause "the saved replay results could not be read"
  [ $(( $(wc -l < "$PD/results_restored.tsv") - 1 )) -ge "$n" ] || spot_pause "the saved replay results hold fewer lines than the state records"
  chmod 644 "$PD/results_restored.tsv"
  as_chk chk3 "mkdir -p $AN/kernel_replay && cp $PD/results_restored.tsv $AN/kernel_replay/results.tsv" || finish FAIL "could not put the saved replay results where the replay reads them"
  say "restored $(( $(wc -l < "$PD/results_restored.tsv") - 1 )) replay results"
}

# ---- setup, on every attempt
# The run's state and manifest: fresh on the first attempt, or as the controller last saw them.
s_spot_resume() {
  local rc
  [ -f "$SPK" ] || { echo "spot_checkpoint.sh is missing from the tools archive"; return 1; }
  mkdir -p "$SPD" "$SPD/members" && chmod 700 "$SPD" || return 1
  ZONE=$(curl -sf --connect-timeout 5 --max-time 20 -H "Metadata-Flavor: Google" "$MDURL/zone" | sed 's|.*/||')
  echo "spot: full-parts-max-bytes=$PARTS_MAX full-confirm-every=$CONFIRM_EVERY full-ckpt-every=$CKPT_EVERY" >> "$PD/env.txt"
  if [ -z "$STATE_SHA_WANT" ]; then
    # The controller saw no state. Only if there is really none may the run start afresh: a state it did not see
    # is never overwritten, and neither is the manifest beside it.
    spot_fetch "$CK/state.json" "$SPD/state.json"; rc=$?
    case "$rc" in
      4) ;;
      0) spot_pause "a state exists that the controller did not see" stop ;;
      *) spot_pause "could not find out whether the run already has a state (status $rc)" ;;
    esac
    # Nothing to continue: start afresh (keeping the attempt number). A manifest left from before is replaced at
    # once, so that no part made on a machine not compared with this one can ever be restored.
    rm -f "$SPS"; printf 'seq\tobject\tsha256\tbytes\tmodules\tcut_epoch\tattempt\n' > "$SPD/manifest.tsv"
    gcs_put "$SPD/manifest.tsv" "$CK/manifest.tsv" || spot_pause "could not write the run's manifest"
    touch "$PD/STATE_READY"
    spot_state --runtag "$RUNTAG" --set stage=build --attempt-set "boot_utc=$(date -u -d "@$T0" +%FT%TZ)" --attempt-set "zone=$ZONE" || spot_pause "could not write the run's state"
  else
    spot_fetch_checked "$CK/state.json" "$SPD/state.json" "$STATE_SHA_WANT"; rc=$?
    case "$rc" in
      0) ;;
      4) echo "the run's state is missing from the bucket"; return 1 ;;
      2) echo "the run's state is not the one the controller saw"; return 1 ;;
      *) spot_pause "could not fetch the run's state" ;;
    esac
    [ "$(bash "$SPK" state-get --file "$SPD/state.json" --key runtag)" = "$RUNTAG" ] || { echo "the state belongs to another run"; return 1; }
    if [ -n "$MANIFEST_SHA_WANT" ]; then
      spot_fetch_checked "$CK/manifest.tsv" "$SPD/manifest.tsv" "$MANIFEST_SHA_WANT"; rc=$?
      case "$rc" in
        0) ;;
        4) echo "the run's manifest is missing from the bucket"; return 1 ;;
        2) echo "the run's manifest is not the one the controller saw"; return 1 ;;
        *) spot_pause "could not fetch the run's manifest" ;;
      esac
    else
      spot_fetch "$CK/manifest.tsv" "$SPD/manifest.tsv"; rc=$?
      [ "$rc" = 4 ] || { [ "$rc" = 0 ] && { echo "a manifest exists that the controller did not see"; return 1; }; spot_pause "could not fetch the run's manifest"; }
      printf 'seq\tobject\tsha256\tbytes\tmodules\tcut_epoch\tattempt\n' > "$SPD/manifest.tsv"
    fi
    # Every row as this script writes it: the object name is made from the row's number, nothing else.
    awk -F'\t' -v p="$CK/part-" 'NR == 1 { if ($0 != "seq\tobject\tsha256\tbytes\tmodules\tcut_epoch\tattempt") bad = 1; next }
      { if (NF != 7 || $1 !~ /^[0-9]+$/ || $2 != sprintf("%s%06d.tar.zst", p, $1) || length($3) != 64 || $3 ~ /[^0-9a-f]/ ||
            $4 !~ /^[0-9]+$/ || $5 !~ /^[0-9]+$/ || $1 + 0 <= last) bad = 1; last = $1 + 0 }
      END { exit bad }' "$SPD/manifest.tsv" || { echo "the run's manifest is malformed"; return 1; }
    cp "$SPD/state.json" "$SPS" && touch "$PD/STATE_READY" || return 1
    spot_state --close-open-attempts "no report: cut without notice" --attempt-set "boot_utc=$(date -u -d "@$T0" +%FT%TZ)" --attempt-set "zone=$ZONE" \
      || say "WARNING: the state could not be uploaded at the start of this attempt"
    spot_load || { echo "could not read the variables in the run's state"; return 1; }
  fi
  case "$TIMEBOX_USED" in ''|*[!0-9]*) TIMEBOX_USED=0 ;; esac
  spot_done seal && SEAL_DONE=1
  if spot_done build || [ "$SEAL_DONE" = 1 ]; then SKIP_BUILD=1
  elif [ "$TIMEBOX" -gt 0 ] && [ "$TIMEBOX_USED" -ge "$TIMEBOX" ]; then SKIP_BUILD=1; C1_STATE=time_boxed; LAKE_RC=124
  fi
  awk -F'\t' 'NR > 1 && $1 + 0 > m {m = $1 + 0} END {print m + 0}' "$SPD/manifest.tsv" > "$SPD/seq"
  : > "$SPD/done.txt"
  echo "spot: attempt $ATTEMPT in zone ${ZONE:-unknown}; $(( $(wc -l < "$SPD/manifest.tsv") - 1 )) parts saved; seal done: $SEAL_DONE; build skipped: $SKIP_BUILD" >> "$PD/env.txt"
}
s_spot_baselines() { # the first attempt's records are the run's; every later machine must match them exactly
  local f s rc same=1
  if [ -z "$BASE_SRC_SHA" ]; then
    [ "$(wc -l < "$SPD/manifest.tsv")" -le 1 ] || { echo "the manifest lists parts but the state holds no baselines"; return 1; }
    for f in src tc pkgs; do gz_put "$PD/baseline_$f.txt" "$CK/baseline_$f.txt.gz" || spot_pause "could not save the baselines"; done
    BASE_SRC_SHA=$(sha256sum < "$PD/baseline_src.txt" | cut -d' ' -f1); BASE_TC_SHA=$(sha256sum < "$PD/baseline_tc.txt" | cut -d' ' -f1)
    BASE_PKGS_SHA=$(sha256sum < "$PD/baseline_pkgs.txt" | cut -d' ' -f1)
    # No part may be saved before the baselines it rests on are recorded.
    spot_state --var "BASE_SRC_SHA=$BASE_SRC_SHA" --var "BASE_TC_SHA=$BASE_TC_SHA" --var "BASE_PKGS_SHA=$BASE_PKGS_SHA" --attempt-set baselines_same=first \
      || spot_pause "could not record the baselines in the state"
    return 0
  fi
  for f in src tc pkgs; do
    case "$f" in src) s=$BASE_SRC_SHA ;; tc) s=$BASE_TC_SHA ;; *) s=$BASE_PKGS_SHA ;; esac
    spot_fetch_checked "$CK/baseline_$f.txt.gz" "$SPD/first_$f.txt.gz" "$s" "" gz; rc=$?
    case "$rc" in
      0) ;;
      4) echo "the first attempt's baseline_$f is missing from the bucket"; return 1 ;;
      2) echo "the first attempt's baseline_$f is not the one the state records"; return 1 ;;
      *) spot_pause "could not fetch the first attempt's baselines" ;;
    esac
    gunzip -c "$SPD/first_$f.txt.gz" > "$SPD/first_$f.txt" || return 1
    if ! cmp -s "$SPD/first_$f.txt" "$PD/baseline_$f.txt"; then
      same=0; diff "$SPD/first_$f.txt" "$PD/baseline_$f.txt" | head -200 > "$PD/changed_baseline_$f.txt"; gcs_put "$PD/changed_baseline_$f.txt" "$RES/changed_baseline_$f.txt"
    fi
  done
  spot_state --attempt-set-json "baselines_same=$([ "$same" = 1 ] && echo true || echo false)"
  [ "$same" = 1 ] || finish FAIL "this machine's source tree, toolchain or library files differ from the first attempt's; see changed_baseline_*.txt. This says nothing about the proof"
}
# spot_restore_all <pilot|root>: every part the manifest lists, in order, fetched, checked and extracted into the
# build directory. Before the seal as the build user, into its own tree; after it as root, into a tree root made.
# Root keeps, for each part, what it holds (the files with sizes and times, and with their SHA-256): before the
# seal read by root from its own copy of the part, after it written by root's own restore. The count of modules
# is taken from those lists, not from what is on disk; then the tree is checked against them, file by file.
spot_restore_all() {
  local seq obj sha bytes mods ep att rc t0 n=0 b=0 got want
  t0=$(now)
  rm -rf "${WORK:?}/spot-in" && mkdir -m 755 "$SPIN" || return 1
  : > "$SPD/restored_done.txt"
  while IFS=$'\t' read -r seq obj sha bytes mods ep att; do
    [ "$seq" = seq ] && continue
    spot_fetch_checked "$obj" "$SPIN/part" "$sha" "$bytes"; rc=$?
    case "$rc" in
      0) ;;
      4) finish FAIL "a part the manifest lists is missing from the bucket: $obj" ;;
      2) finish FAIL "$obj does not match the checksum in the manifest (three complete downloads)" ;;
      *) spot_pause "could not fetch $obj" ;;
    esac
    chmod 644 "$SPIN/part"
    if [ "$1" = pilot ]; then
      bash "$SPK" list --part "$SPIN/part" --members-out "$SPD/members/$seq.gz" --done-out "$SPD/part.done" 2>> "$PD/spot.log" \
        && runuser -u pilot -- bash "$SPK" restore --build-dir "$PROJ/.lake/build" --part "$SPIN/part" --sha256 "$sha" >> "$PD/spot.log" 2>&1
    else
      bash "$SPK" restore --build-dir "$PROJ/.lake/build" --part "$SPIN/part" --sha256 "$sha" --members-out "$SPD/members/$seq.gz" --done-out "$SPD/part.done" >> "$PD/spot.log" 2>&1
    fi || finish FAIL "could not restore $obj; see spot.log"
    cat "$SPD/part.done" >> "$SPD/restored_done.txt"; rm -f "$SPIN/part" "$SPD/part.done"; n=$((n + 1)); b=$((b + bytes))
  done < "$SPD/manifest.tsv"
  rm -rf "${WORK:?}/spot-in"
  # The modules the parts hold, by their .trace files: one per module.
  cut -f1 "$SPD/restored_done.txt" | grep -E '^lib/lean/.+\.trace$' | sed -e 's|^lib/lean/||' -e 's|\.trace$||' -e 's|/|.|g' | LC_ALL=C sort -u > "$SPD/restored.txt"
  want=$(awk -F'\t' 'NR > 1 {s += $5} END {print s + 0}' "$SPD/manifest.tsv"); got=$(wc -l < "$SPD/restored.txt")
  spot_state --attempt-set-json "restore={\"parts\": $n, \"modules\": $got, \"bytes\": $b, \"seconds\": $(( $(now) - t0 ))}"
  [ "$got" = "$want" ] || finish FAIL "the $n restored parts hold $got modules; the manifest lists $want"
  # Every restored file must now be on disk exactly as the parts say (size and time): checked by the cut's own
  # rule, writing nothing. From here on a change to any of them is a module compiled again.
  cp "$SPD/restored_done.txt" "$SPD/done.txt" || return 1
  if [ "$1" = pilot ]; then
    rm -rf "${WORK:?}/spot-out" && mkdir -m 700 "$SPOUT" && cp "$SPD/done.txt" "$SPOUT/done.txt" && chown -R pilot:pilot "$SPOUT" || return 1
    runuser -u pilot -- bash "$SPK" cut --build-dir "$PROJ/.lake/build" --done "$SPOUT/done.txt" --dry-run --all > "$SPD/restore_check.txt" 2>> "$PD/spot.log"; rc=$?
    rm -rf "${WORK:?}/spot-out"
  else
    bash "$SPK" cut --build-dir "$PROJ/.lake/build" --done "$SPD/done.txt" --dry-run --all > "$SPD/restore_check.txt" 2>> "$PD/spot.log"; rc=$?
  fi
  case "$rc" in
    3) ;;
    0) spot_log "after the restore, $(wc -l < "$SPD/restore_check.txt") files on disk that no part holds; the next part saves them" ;;
    4) finish FAIL "a file restored from the parts is not on disk as the parts hold it; see spot.log. This says nothing about the proof" ;;
    *) finish FAIL "could not check the restored files (status $rc); see spot.log" ;;
  esac
  say "restored $n parts: $got modules, $b bytes, in $(( $(now) - t0 )) s"
}
s_spot_restore() { # before the seal: the parts, into the build user's tree, before the build tool first runs
  [ "$SEAL_DONE" = 0 ] && [ "$(wc -l < "$SPD/manifest.tsv")" -gt 1 ] || return 0
  spot_restore_all pilot
}
# An attempt that starts after the seal: the build user is locked out, exactly as the seal does it, before any
# compiled file of the proof is on this machine; then root restores the parts into a tree only root has written.
spot_after_seal_restore() {
  local d
  status setup RUNNING "the seal was done by an earlier attempt: locking the build user, then restoring the compiled files"
  stop_build; kill_users
  crontab -r -u pilot 2>/dev/null; usermod -L -s /usr/sbin/nologin pilot || finish FAIL "could not lock the build user's account"
  loginctl disable-linger pilot 2>/dev/null; kill_users
  ( while true; do if pgrep -u pilot >/dev/null 2>&1; then date -u +%FT%TZ >> "$PD/build_user_seen_after_seal"; pkill -KILL -u pilot; fi; sleep 5; done ) & GUARD_PID=$!
  SPOT_LOCKED=1
  rm -rf "${PROJ:?}/.lake/build"
  for d in "$WORK" "$WORK/extract" "$PROJ" "$PROJ/.lake"; do
    [ -d "$d" ] && [ ! -L "$d" ] && chown root:root "$d" || finish FAIL "$d is not a plain directory"
  done
  [ ! -e "$PROJ/.lake/build" ] || finish FAIL "could not clear the build directory"
  spot_restore_all root || finish FAIL "could not restore the compiled files"
}

# ---- after the build
spot_hold() { # full-spot-hold=seal:N: a rehearsal's watcher cuts the attempt here
  local n
  case "$HOLD" in seal:*) n=${HOLD#seal:}; case "$n" in ''|*[!0-9]*) return 0 ;; esac; say "holding $n s for the rehearsal"; sleep "$n" & wait $! ;; esac
  return 0
}
# The first seal only: the parts, restored in order (a later part's copy of a file wins), must reproduce exactly
# the compiled files the seal has just fingerprinted. What they lack or hold differently goes into one repair
# part, cut by root (the build user is locked); then they must match. Proved here, on the sealing machine, and
# not discovered after the next reclaim.
spot_cover() {
  local seq m=() rc tries=0 fix
  for seq in $(awk -F'\t' 'NR > 1 {print $1}' "$SPD/manifest.tsv"); do
    [ -s "$SPD/members/$seq.gz" ] || finish FAIL "this machine has no list of what part $seq holds, so the parts cannot be shown to reproduce the sealed files. This says nothing about the proof"
    m+=(--members "$SPD/members/$seq.gz")
  done
  bash "$SPK" cover --lib-manifest "$PD/lib_sha256.txt" --prefix lib/lean "${m[@]}" > "$PD/parts_cover.txt" 2>> "$PD/spot.log"; rc=$?
  fix=0
  if [ "$rc" = 3 ]; then
    grep -q '^extra' "$PD/parts_cover.txt" && { gcs_put "$PD/parts_cover.txt" "$RES/parts_cover.txt"
      finish FAIL "the parts hold compiled files the seal did not find; they do not reproduce the sealed files (see parts_cover.txt). This says nothing about the proof"; }
    cut -f2 "$PD/parts_cover.txt" > "$SPD/cover_fix.txt"; fix=$(wc -l < "$SPD/cover_fix.txt")
    say "seal: $fix compiled files are not in the parts as sealed; saving them in a repair part"
    while true; do
      spot_ckpt_round repair; rc=$?
      case "$rc" in
        0) break ;;
        5) spot_pause "$(spot_too_big_msg)" parts-limit ;;
        *) tries=$((tries + 1)); [ "$tries" -ge 5 ] && spot_pause "the repair part could not be saved"; sleep 30 ;;
      esac
    done
    m+=(--members "$SPD/members/$(awk -F'\t' 'NR > 1 {s = $1} END {print s}' "$SPD/manifest.tsv").gz")
    bash "$SPK" cover --lib-manifest "$PD/lib_sha256.txt" --prefix lib/lean "${m[@]}" > "$PD/parts_cover.txt" 2>> "$PD/spot.log"; rc=$?
  fi
  [ "$rc" = 0 ] || { gcs_put "$PD/parts_cover.txt" "$RES/parts_cover.txt"
    finish FAIL "the parts do not reproduce the sealed files (status $rc; see parts_cover.txt). This says nothing about the proof"; }
  spot_state --set-json parts_cover_seal=true --set-int "parts_cover_repair_files=$fix" || spot_pause "could not record in the state that the parts reproduce the sealed files"
}
spot_seal_manifest() { # the first seal's manifests are kept; every later seal must reproduce the compiled files' exactly
  local f
  if [ "$SEAL_DONE" = 1 ]; then
    [ "$MANIFEST_SHA" = "$SEAL_LIB_SHA" ] && return 0
    spot_fetch "$CK/seal/lib_sha256.txt.gz" "$SPD/first_lib.txt.gz" && gunzip -c "$SPD/first_lib.txt.gz" > "$SPD/first_lib.txt" \
      && { diff "$SPD/first_lib.txt" "$PD/lib_sha256.txt" | head -200 > "$PD/changed_lib_restored.txt"; gcs_put "$PD/changed_lib_restored.txt" "$RES/changed_lib_restored.txt"; }
    finish FAIL "the compiled files restored from the parts are not byte for byte those the first seal recorded (manifest sha256 $MANIFEST_SHA, first seal $SEAL_LIB_SHA). This says nothing about the proof"
  fi
  spot_cover
  for f in lib_sha256 seal_src seal_tc seal_pkgs seal_tc_copy; do gz_put "$PD/$f.txt" "$CK/seal/$f.txt.gz" || spot_pause "could not save the seal's manifests"; done
}
spot_after_seal() {
  if [ "$SEAL_DONE" = 0 ]; then
    # Only once the seal's manifests are in the bucket is the seal recorded; until then a later attempt seals afresh.
    SEAL_LIB_SHA=$MANIFEST_SHA
    spot_record seal c2 SRC_SAME LIBS_SAME TC_COPY_SAME LEFTOVERS LIB_OTHER MANIFEST_SHA SEAL_LIB_SHA || spot_pause "could not record the seal in the state"
    SEAL_DONE=1
  else
    spot_results_restore
  fi
}
# spot_c2_save <label> <unit> <stage> NAME...: once the check has ended, a confirm; then the check's summary goes
# up, with its SHA-256 recorded beside the unit. If the confirm cannot be completed, or the summary not uploaded,
# the unit is not recorded (the next attempt, if there is one, runs it again).
spot_c2_save() {
  local l=$1 u=$2 st=$3 sha="" v; shift 3
  spot_confirmed || { deadline_check; say "WARNING: the axiom check ($l) could not be confirmed; it is not recorded"; return 0; }
  if [ -f "$PD/c2/$l.json" ]; then
    sha=$(sha256sum < "$PD/c2/$l.json" | cut -d' ' -f1)
    gcs_put "$PD/c2/$l.json" "$CK/c2/$l.json" || { say "WARNING: the axiom check's summary ($l) was not saved; the check is not recorded"; return 0; }
  fi
  case "$l" in plain) C2_PLAIN_JSON_SHA=$sha; v=C2_PLAIN_JSON_SHA ;; *) C2_DEEP_JSON_SHA=$sha; v=C2_DEEP_JSON_SHA ;; esac
  spot_record "$u" "$st" "$@" "$v"
  return 0
}
spot_c2_reload() { # spot_c2_reload <label> NAME...: a check an earlier attempt completed, with its recorded result
  local l=$1 sha rc; shift
  spot_load "$@" C2_PLAIN_JSON_SHA C2_DEEP_JSON_SHA
  case "$l" in plain) sha=$C2_PLAIN_JSON_SHA ;; *) sha=$C2_DEEP_JSON_SHA ;; esac
  rm -f "$PD/c2/$l.json"
  if [ -n "$sha" ]; then
    spot_fetch_checked "$CK/c2/$l.json" "$PD/c2/$l.json" "$sha"; rc=$?
    case "$rc" in
      0) ;;
      2) finish FAIL "the saved summary of the axiom check ($l) is not the one recorded with it" ;;
      *) spot_pause "could not fetch the saved summary of the axiom check ($l, status $rc)" ;;
    esac
  fi
  say "axiom check ($l): completed by an earlier attempt"
}
fi

[ -n "$BUCKET" ] || { echo "no bucket in metadata; idling until deleted"; idle_until_deleted; }
# A startup script runs on every boot. Never run twice on one VM. (In a Spot run that ends only this attempt.)
if [ -e "$PD/STARTED" ] && [ "$SPOT" = 1 ]; then status reboot RECLAIMED "VM restarted; this attempt is over"; idle_until_deleted; fi
if [ -e "$PD/STARTED" ]; then status reboot FAIL "VM restarted; the run does not start twice"; idle_until_deleted; fi
date -u +%FT%TZ > "$PD/STARTED"
trap on_signal TERM INT
# If the bucket cannot be written to, nothing this run does could ever be collected: do no work at all.
status boot RUNNING "booted" || { echo "cannot write to the bucket; idling until deleted"; idle_until_deleted; }
[ "$SPOT" = 1 ] && { spot_watch_preempted & SPOT_WATCH_PID=$!; }
( n=0; while true; do sleep 60; sync_small; n=$((n+1)); [ $((n % 10)) -eq 0 ] && sync_big; done ) & SYNC_PID=$!
# Deadline watchdog, independent of the phase logic. It signals the main script first, then unblocks whatever the
# main script is waiting on; if the main script still has not finished, it takes over and reports.
MAIN=$$
( while [ "$(left)" -gt 0 ]; do sleep 20; done
  echo "### DEADLINE reached"; touch "$PD/DEADLINE"
  kill -TERM "$MAIN"; sleep 1
  # Unblock whatever the main script is waiting on, unless it is already writing its report (which runs a
  # time-limited command of its own that must not be cut off).
  if [ ! -e "$PD/FINISHING" ]; then pkill -TERM -x lake; pkill -TERM -x xargs; pkill -TERM -x timeout; pkill -TERM -x tar; pkill -TERM -x zstd; fi
  sleep "$WATCHDOG_WAIT"
  final_state() { grep -qE '"state": "(DONE|FAIL|DEADLINE|BUILD_FAILED|PAUSED|RECLAIMED)"' "$PD/status.json" 2>/dev/null; }   # the last two: Spot only
  # A main script that has begun its report is given longer: on the whole tree the report alone (hashing done,
  # but summaries to recompute and logs to upload) can take more than the first wait.
  w=0; while ! final_state && [ -e "$PD/FINISHING" ] && [ "$w" -lt "$FINISH_WAIT" ]; do sleep 20; w=$((w + 20)); done
  if ! final_state; then
    echo "### main script did not finish; watchdog taking over"
    kill_users
    for f in "$PD"/lake_build_*.log "$PD"/c2_*.out "$PD"/c3_*.out; do plain "$f" && gz_put "$f" "$RES/logs/$(basename "$f").gz"; done
    if [ ! -e "$PD/SEALED" ]; then for f in "$LOGS"/lake_build_*.log; do plain "$f" && gz_put "$f" "$RES/logs/$(basename "$f").gz"; done; fi
    gcs_put "$PD/facts.json" "$RT/facts.json"; sync_big; sync_small
    if [ "$SPOT" = 1 ] && [ -e "$PD/FAIL_IS_FINAL" ] && [ -e "$PD/HARD_FAIL_MSG" ]; then   # Spot: a confirm found a change; that ends the run
      status watchdog FAIL "$(cat "$PD/HARD_FAIL_MSG") (the main script was stuck; the watchdog stopped the run)"
    elif [ "$SPOT" = 1 ]; then   # in a Spot run the deadline ends only this attempt: the run goes on from what is saved
      status watchdog PAUSED "main script stuck at the attempt's deadline; the watchdog stopped this attempt (facts.json is from the last checkpoint)" deadline
    else
    status watchdog DEADLINE "main script stuck at the deadline; the watchdog stopped the run (facts.json is from the last checkpoint)"
    fi
    while true; do kill_users; gcs_put "$PD/status.json" "$RT/status.json" 2>/dev/null; sleep 60; done
  fi ) &

# ---------------------------------------------------------------- setup
phase_mark setup; status setup RUNNING "installing"
{ echo "mode=$MODE nmax=$NMAX deadline_min=$DEADLINE_MIN tools_commit=$TOOLS_COMMIT guest_sha256=$GUEST_SHA"; nproc; lscpu | grep -E "Model name|Thread|Core|Socket|NUMA|MHz"; uname -r; free -g | head -2; head -2 /etc/os-release; } > "$PD/env.txt" 2>&1
# The last module maps about 240,000 files (records/mac-build/mapped-files-sample.txt); the limit is set far above that.
s_sysctl() { sysctl -w fs.file-max=50000000 vm.max_map_count=16777216 fs.nr_open=4194304 >/dev/null && printf 'pilot soft nofile 1048576\npilot hard nofile 1048576\n' > /etc/security/limits.d/pilot.conf; }
s_pkgs() { apt-get update -qq && apt-get install -y -qq --no-install-recommends git curl xfsprogs iptables ca-certificates zstd >/dev/null; }
s_disk() {
  mkdir -p "$WORK"
  [ -e /dev/disk/by-id/google-pilot-data ] || { echo "no data disk attached"; return 1; }
  mkfs.xfs -q -f /dev/disk/by-id/google-pilot-data && mount -o noatime /dev/disk/by-id/google-pilot-data "$WORK" || return 1
  echo "work filesystem: $(df -h "$WORK" | tail -1)" >> "$PD/env.txt"
}
no_network() { # no_network <user>   -- cut a user off from the metadata server (the VM's credentials) and from everything else
  iptables -I OUTPUT 1 -m owner --uid-owner "$1" -d 169.254.169.254 -j REJECT && iptables -A OUTPUT -m owner --uid-owner "$1" ! -o lo -j REJECT || return 1
  if runuser -u "$1" -- curl -s -m 4 -o /dev/null https://storage.googleapis.com/; then echo "user $1 still has network access"; return 1; fi
  if runuser -u "$1" -- curl -s -m 4 -o /dev/null -H "Metadata-Flavor: Google" "$MDURL/id"; then echo "user $1 can still reach the metadata server"; return 1; fi
}
s_user() {
  printf 'pilot\nchk2\nchk3\n' >> /etc/cron.deny       # none of these users may schedule anything
  id pilot >/dev/null 2>&1 || useradd -m -s /bin/bash pilot
  mkdir -p "$WORK/extract" "$LOGS" && chown pilot:pilot "$WORK/extract" "$LOGS" || return 1
  # The build user must never reach the metadata server (it would hand out the VM's credentials).
  iptables -I OUTPUT 1 -m owner --uid-owner pilot -d 169.254.169.254 -j REJECT || return 1
  if runuser -u pilot -- curl -s -m 4 -o /dev/null -H "Metadata-Flavor: Google" "$MDURL/id"; then echo "pilot user can still reach the metadata server"; return 1; fi
}
s_elan() { runuser -l pilot -c 'curl -sSf https://raw.githubusercontent.com/leanprover/elan/master/elan-init.sh | sh -s -- -y --default-toolchain none >/dev/null 2>&1; grep -q elan ~/.profile || echo "export PATH=\$HOME/.elan/bin:\$PATH" >> ~/.profile; ~/.elan/bin/elan --version'; }
fetch_checked() { # fetch_checked <object> <file> <expected sha256>
  gcs_get "$1" "$2" || { echo "could not fetch $1"; return 1; }
  local got; got=$(sha256sum "$2" | cut -d' ' -f1)
  [ -n "$3" ] && [ "$got" = "$3" ] || { echo "$1: sha256 mismatch or no expected value: $got"; return 1; }
}
s_source() {
  fetch_checked "inputs/lean.tar.gz" "$WORK/lean.tar.gz" "$TARBALL_SHA" || return 1
  tar -xzf "$WORK/lean.tar.gz" -C "$WORK/extract" && rm -f "$WORK/lean.tar.gz" && chown -R pilot:pilot "$PROJ" || return 1
  # The source tree as extracted, before anything is compiled: every file except the build tool's own directory.
  src_manifest > "$PD/baseline_src.txt" || return 1
  [ "$(wc -l < "$PD/baseline_src.txt")" -eq "$(cd "$PROJ" && find . -path ./.lake -prune -o -type f -print | wc -l)" ] && [ -s "$PD/baseline_src.txt" ] || { echo "source manifest is incomplete"; return 1; }
  fetch_checked "inputs/sampler.py" "$PD/sampler.py" "$SAMPLER_SHA" || return 1
  # This repository's scripts, owned by root so that nothing run as another user can change them.
  fetch_checked "inputs/rhv_tools.tar.gz" "$PD/rhv_tools.tar.gz" "$TOOLS_SHA" || return 1
  rm -rf "$TOOLS" && mkdir -p "$TOOLS" && tar -xzf "$PD/rhv_tools.tar.gz" -C "$TOOLS" --strip-components=1 && chown -R root:root "$TOOLS" && chmod -R a+rX,go-w "$TOOLS" || return 1
  [ -f "$TOOLS/scripts/09_kernel_replay.sh" ] && [ -f "$TOOLS/scripts/08_check_axioms.sh" ] && [ -f "$TOOLS/scripts/prune_setup_files.sh" ] || { echo "scripts missing from the tools archive"; return 1; }
}
s_cache() { as_pilot "timeout 1500 lake exe cache get > /tmp/cache_get.log 2>&1; rc=\$?; tail -2 /tmp/cache_get.log; exit \$rc"; }
# What the checks will trust besides the proof's own compiled files: the toolchain, and the compiled files of
# Mathlib and the packages beneath it. Recorded here, before any file of the proof has been compiled.
s_baseline() {
  TC_BIN=$(dirname "$(as_pilot 'elan which lean' | tail -1)"); TC_DIR=$(dirname "$TC_BIN")
  [ -x "$TC_BIN/lean" ] && [ -x "$TC_BIN/leanchecker" ] || { echo "toolchain not found at $TC_BIN"; return 1; }
  tc_manifest "$TC_DIR" > "$PD/baseline_tc.txt" && pkgs_manifest > "$PD/baseline_pkgs.txt" || return 1
  [ "$(wc -l < "$PD/baseline_tc.txt")" -gt 2000 ] && [ "$(wc -l < "$PD/baseline_pkgs.txt")" -gt 20000 ] && [ "$(grep -c '\.olean$' "$PD/baseline_pkgs.txt")" -gt 8000 ] \
    || { echo "library manifests are implausibly short: $(wc -l < "$PD/baseline_tc.txt") and $(wc -l < "$PD/baseline_pkgs.txt") files"; return 1; }
  echo "toolchain: $TC_DIR ($(wc -l < "$PD/baseline_tc.txt") files, manifest sha256 $(sha256sum "$PD/baseline_tc.txt" | cut -d' ' -f1)); library files: $(wc -l < "$PD/baseline_pkgs.txt") (manifest sha256 $(sha256sum "$PD/baseline_pkgs.txt" | cut -d' ' -f1))" >> "$PD/env.txt"
}
# The second replay's program, when it is asked for. Root builds it here, before any file of the proof has been
# compiled, in a directory only root can write. It is not built with the toolchain where the build user keeps
# it: root first makes its own copy of the toolchain, proves the copy identical to the record just taken, and
# builds with that. The program's copy of replayFromImports is compared, character for character, with the
# source in that same copy.
s_driver() {
  [ "$SECOND_REPLAY" = rhv-replay ] || return 0
  local src="$TOOLS/scripts/verify/replay" lib bad
  kill_users                                  # nothing of the build user may be running while the copy is made
  rm -rf /opt/lean-tc && cp -a "$TC_DIR" /opt/lean-tc && chown -R root:root /opt/lean-tc && chmod -R go-w /opt/lean-tc || { echo "could not copy the toolchain"; return 1; }
  tc_manifest /opt/lean-tc > "$PD/driver_tc.txt"
  cmp -s "$PD/baseline_tc.txt" "$PD/driver_tc.txt" || { echo "root's copy of the toolchain differs from the toolchain as recorded"; return 1; }
  [ -z "$(find /opt/lean-tc -type l -print0 | xargs -0 -r -n 1 realpath -m 2>/dev/null | grep -v -e '^/opt/lean-tc/' -e '^/opt/lean-tc$' | head -1)" ] \
    || { echo "the toolchain contains a symbolic link that leads outside it"; return 1; }
  [ -f "$src/RhvReplay.lean" ] && [ -f /opt/lean-tc/src/lean/LeanChecker.lean ] || { echo "the replay program's source, or the toolchain's source of leanchecker, is missing"; return 1; }
  python3 -I -B "$TOOLS/scripts/verify/rhv_tools.py" replay-driver-check --driver-src "$src/RhvReplay.lean" --toolchain-src /opt/lean-tc/src/lean/LeanChecker.lean > "$PD/driver_check.txt" 2>&1 \
    || { cat "$PD/driver_check.txt"; return 1; }
  cat "$PD/driver_check.txt" >> "$PD/env.txt"
  rm -rf /opt/rhv-replay && mkdir -p /opt/rhv-replay && cp "$src/RhvReplay.lean" "$src/lakefile.toml" "$src/lean-toolchain" /opt/rhv-replay/ || return 1
  ( cd /opt/rhv-replay && HOME=/root PATH="/opt/lean-tc/bin:/usr/bin:/bin" timeout 900 /opt/lean-tc/bin/lake build > "$PD/driver_build.log" 2>&1 ) || { echo "building the replay program failed:"; tail -8 "$PD/driver_build.log"; return 1; }
  chown -R root:root /opt/rhv-replay && chmod -R a+rX,go-w /opt/rhv-replay || return 1
  DRIVER=/opt/rhv-replay/.lake/build/bin/rhv-replay
  [ -x "$DRIVER" ] || { echo "the replay program was not built"; return 1; }
  DRIVER_SHA=$(sha256sum "$DRIVER" | cut -d' ' -f1)
  { echo "replay program: $DRIVER, $(stat -c %s "$DRIVER") bytes, sha256 $DRIVER_SHA; shared libraries it loads:"; ldd "$DRIVER" 2>&1 | sed 's/^/  /'; } >> "$PD/env.txt"
  # It may load shared libraries only from the system's own directories or from root's copy of the toolchain.
  bad=$(ldd "$DRIVER" 2>&1 | awk '/not found/ {print; next} /=>/ {print $3} /^[[:space:]]*\// {print $1}' | grep -v -e '^/lib/' -e '^/lib64/' -e '^/usr/lib/' -e '^/usr/lib64/' -e '^/opt/lean-tc/' | head -3)
  [ -z "$bad" ] || { echo "the replay program would load a library from an unexpected place: $bad"; return 1; }
}
s_driver_test() { # the replay program must pass the two modules the smoke build has just compiled
  [ -n "$DRIVER" ] || return 0
  local lp=$PROJ/.lake/build/lib/lean d; for d in "$PROJ"/.lake/packages/*/.lake/build/lib/lean; do lp="$lp:$d"; done
  as_pilot "LEAN_NUM_THREADS=1 LEAN_PATH='$lp' timeout 300 $DRIVER Statements Formalism.GammaFactorNonvanishing.RhOfRight" > "$PD/driver_test.txt" 2>&1
  [ "$(grep -cE '^REPLAY_OK (Statements|Formalism\.GammaFactorNonvanishing\.RhOfRight) [0-9]+$' "$PD/driver_test.txt")" = 2 ] \
    || { echo "the replay program did not pass the two modules of the smoke build: $(head -c 400 "$PD/driver_test.txt" | tr '\n' ' ')"; return 1; }
  cat "$PD/driver_test.txt" >> "$PD/env.txt"
}
s_lockdown() { # from here on the build user has no network at all; nothing of the proof has been compiled yet
  iptables -A OUTPUT -m owner --uid-owner pilot ! -o lo -j REJECT || return 1
  if runuser -u pilot -- curl -s -m 4 -o /dev/null https://storage.googleapis.com/; then echo "pilot user still has network access"; return 1; fi
}
s_smoke() { # proves the toolchain works offline and the Mathlib cache is accepted (no Mathlib rebuild)
  # Statements imports only Mathlib. RhOfRight is the reduction lemma the --probe axiom check reads (rehearsal).
  as_pilot "timeout 900 lake build +Statements +Formalism.GammaFactorNonvanishing.RhOfRight > /tmp/smoke.log 2>&1; rc=\$?; tail -3 /tmp/smoke.log; exit \$rc" || return 1
  local n; n=$(grep -cE 'Built Mathlib\.' /tmp/smoke.log)
  [ "$n" -eq 0 ] || { echo "Mathlib was rebuilt ($n modules): cache not accepted"; return 1; }
  # Building must leave the library files alone. If it does not, the seal would fail after the whole build: stop now.
  pkgs_manifest > "$PD/smoke_pkgs.txt"; cmp -s "$PD/baseline_pkgs.txt" "$PD/smoke_pkgs.txt" || { echo "the smoke build changed files under the packages' lib directories"; diff "$PD/baseline_pkgs.txt" "$PD/smoke_pkgs.txt" | head -20; return 1; }
}
t_step sysctl s_sysctl
ulimit -n 1048576 2>/dev/null || say "NOTE: could not raise this shell's open-file limit (it is $(ulimit -n))"   # inherited by everything started below
t_step packages s_pkgs
t_step disk s_disk
t_step user s_user
t_step elan s_elan
t_step source s_source
[ "$SPOT" = 1 ] && t_step spot_state s_spot_resume
t_step mathlib_cache s_cache
t_step baseline s_baseline
[ "$SPOT" = 1 ] && t_step spot_baselines s_spot_baselines
t_step replay_program s_driver
t_step lockdown s_lockdown
[ "$SPOT" = 1 ] && t_step restore_parts s_spot_restore
if [ "$SPOT" = 1 ] && [ "$SEAL_DONE" = 1 ]; then
  say "setup: no smoke build: the seal was done by an earlier attempt, and nothing of the proof is compiled after it"
else
t_step smoke_build s_smoke
t_step replay_program_test s_driver_test
fi
LEAN_VERSION=$(as_pilot 'lean --version' | tail -1)
echo "ulimit_n_pilot=$(as_pilot 'ulimit -n' | tail -1) max_map_count=$(cat /proc/sys/vm/max_map_count) lean=$LEAN_VERSION" >> "$PD/env.txt"
[ "$GUEST_SHA" = "$GUEST_SHA_WANT" ] || say "NOTE: this script's sha256 ($GUEST_SHA) is not the one the controller announced ($GUEST_SHA_WANT)"
NSRC=$(find "$PROJ/src" -name '*.lean' | wc -l)
python3 "$PD/sampler.py" "$PD" & SAMPLER_PID=$!
sync_small
[ "$SPOT" = 1 ] && [ "$SEAL_DONE" = 1 ] && spot_after_seal_restore

# ---------------------------------------------------------------- build (criterion C1)
finished_modules() { ( cd "$LIB" 2>/dev/null && find . -name '*.trace' | sed -e 's|^\./||' -e 's|\.trace$||' -e 's|/|.|g' | LC_ALL=C sort ); }
n_finished() { find "$LIB" -name '*.trace' 2>/dev/null | wc -l; }
built_in_log() { plain "$1" || return 0; grep -E '^[^ ]+ \[[0-9]+/[0-9]+\] Built ' "$1" 2>/dev/null | sed -E 's/^[^ ]+ \[[0-9]+\/[0-9]+\] Built ([^ ]+).*/\1/' | LC_ALL=C sort -u; }
prune() { RH_WORKDIR=$WORK bash "$TOOLS/scripts/prune_setup_files.sh" --delete --min-age "$1" --project "$PROJ" 2>&1 | tr '\n' ' '; echo; }
LAKELOG=""; LAKE_JOB=""; BUILD_JOBS=$NMAX; BUILD_T0=$(now); TESTS_DONE=0; RESTART_RESULT=""; RESTART_NEW=""
[ "$SPOT" = 1 ] && spot_load TESTS_DONE            # the restart tests run once a run, not once an attempt
start_lake() { # starts the build tool in the background with BUILD_JOBS jobs; time-boxed in a rehearsal
  LAKE_N=$((LAKE_N + 1)); LAKELOG="$LOGS/lake_build_$LAKE_N.log"
  local pre="" rest
  if [ "$TIMEBOX" -gt 0 ]; then rest=$(( TIMEBOX - ($(now) - BUILD_T0) )); [ "$rest" -lt 30 ] && rest=30; pre="timeout --signal=TERM $rest "; fi
  as_pilot "LEAN_NUM_THREADS=$BUILD_JOBS ${pre}lake build $TARGETS > $LAKELOG 2>&1; rc=\$?; echo rc=\$rc >> $LAKELOG; exit \$rc" &
  LAKE_JOB=$!
}
restart_test() { # restart_test <label> <prune: 0|1>  -- sets RESTART_RESULT to the number of finished modules compiled again.
  # Not to be called in a command substitution: it restarts the build tool and must update LAKE_JOB in this shell.
  local label=$1 before="$PD/restart_$1_before.txt" t n0 t_in
  t_in=$(now)
  stop_build; wait "$LAKE_JOB" 2>/dev/null
  finished_modules > "$before"
  [ "$2" = 1 ] && say "restart test $label: $(prune 0)"
  n0=$(wc -l < "$before"); start_lake; t=$(now)
  # Give the build tool long enough to walk the whole graph and compile a few hundred new modules.
  while kill -0 "$LAKE_JOB" 2>/dev/null && [ $(( $(now) - t )) -lt 240 ] && [ $(( $(n_finished) - n0 )) -lt 300 ]; do sleep 5; done
  built_in_log "$LAKELOG" | LC_ALL=C comm -12 - "$before" > "$PD/restart_${label}_recompiled.txt"
  RESTART_RESULT=$(wc -l < "$PD/restart_${label}_recompiled.txt"); RESTART_NEW=$(( $(n_finished) - n0 ))
  BUILD_T0=$(( BUILD_T0 + $(now) - t_in ))        # a rehearsal's time box does not count the time a test takes
  if [ "$SPOT" = 1 ]; then echo "$BUILD_T0" > "$PD/build_t0"; fi
}
monitor_build() { # watches the running build tool until it exits: the restart tests (once), pruning, disk space, progress
  local n free_gb nf last_prune last_status=0
  last_prune=$(now)
  while kill -0 "$LAKE_JOB" 2>/dev/null; do
    sleep 20
    [ -e "$PD/DEADLINE" ] && break
    [ "$SPOT" = 1 ] && spot_build_check        # Spot: a saved module compiled again, or parts too big, stops the build now
    n=$(n_finished); free_gb=$(( $(df -B1 --output=avail "$WORK" | tail -1) / 1000000000 ))
    if [ "$TESTS_DONE" = 0 ] && [ "$n" -ge "$PRUNE_AFTER" ]; then
      status build RUNNING "restart tests at $n modules"
      restart_test control 0; RESTART_CONTROL=$RESTART_RESULT; RESTART_CONTROL_NEW=$RESTART_NEW
      restart_test prune 1; RESTART_PRUNE=$RESTART_RESULT; RESTART_PRUNE_NEW=$RESTART_NEW
      [ -e "$PD/DEADLINE" ] && break
      echo "plain restart: $RESTART_CONTROL finished modules compiled again, $RESTART_CONTROL_NEW new ones built; after deleting setup files: $RESTART_PRUNE compiled again, $RESTART_PRUNE_NEW new ones built" | tee "$PD/restart_tests.txt"
      gcs_put "$PD/restart_control_recompiled.txt" "$RES/restart_control_recompiled.txt"; gcs_put "$PD/restart_prune_recompiled.txt" "$RES/restart_prune_recompiled.txt"
      if [ "$RESTART_CONTROL" != 0 ] || [ "$RESTART_PRUNE" != 0 ]; then
        C1_STATE=stopped_by_restart_test
        finish FAIL "a restart made the build tool compile finished modules again (plain: $RESTART_CONTROL, after pruning: $RESTART_PRUNE); stopping rather than filling the disk. This says nothing about the proof"
      fi
      # A test in which the build tool built almost nothing new shows nothing: it never got far enough to recompile.
      if [ "$RESTART_CONTROL_NEW" -lt 50 ] || [ "$RESTART_PRUNE_NEW" -lt 50 ]; then
        C1_STATE=restart_test_inconclusive
        finish FAIL "a restart test was inconclusive: the build tool built only $RESTART_CONTROL_NEW and $RESTART_PRUNE_NEW new modules after its restarts. This says nothing about the proof"
      fi
      TESTS_DONE=1; last_prune=$(now)
      if [ "$SPOT" = 1 ]; then spot_record tests - TESTS_DONE RESTART_CONTROL RESTART_PRUNE RESTART_CONTROL_NEW RESTART_PRUNE_NEW; fi
    fi
    if [ "$TESTS_DONE" = 1 ] && [ $(( $(now) - last_prune )) -ge "$PRUNE_EVERY" ]; then say "prune: $(prune 5)"; last_prune=$(now); fi
    if [ "$free_gb" -lt 25 ]; then C1_STATE=stopped_disk_full; finish FAIL "only $free_gb GB of disk left at $n modules. This says nothing about the proof"; fi
    if [ $(( $(now) - last_status )) -ge 300 ]; then
      nf=$(failed_lines)
      printf '%s\tbuild\t%s\t%s\t%s\n' "$(now)" "$n" "$nf" "$free_gb" >> "$PD/progress.tsv"
      status build RUNNING "built $n of $NSRC with $BUILD_JOBS jobs; failed job lines $nf; $free_gb GB free"; last_status=$(now)
    fi
  done
  wait "$LAKE_JOB" 2>/dev/null; LAKE_RC=$?        # the build tool's own exit status (124 if a rehearsal's time box ended it)
  deadline_check
}

# Spot: a build an earlier attempt completed (or whose time box it used up) is not run again.
if [ "$SPOT" = 1 ] && [ "$SKIP_BUILD" = 1 ]; then
  say "build: not run on this attempt (state: $C1_STATE); $(n_finished) modules restored"
else
phase_mark "build:N=$NMAX"; status build RUNNING "starting the build of $NSRC modules"
printf 't\tphase\tfinished\tfailed_lines\tdisk_free_gb\n' > "$PD/progress.tsv"
BUILD_T0=$(now)
[ "$SPOT" = 1 ] && { BUILD_T0=$(( BUILD_T0 - TIMEBOX_USED )); echo "$BUILD_T0" > "$PD/build_t0"; }   # the time box spans the attempts
[ "$SPOT" = 1 ] && spot_ckpt_loop_start
start_lake; monitor_build
say "build tool exited with status $LAKE_RC; $(n_finished) modules finished"
if [ "$TIMEBOX" -gt 0 ]; then
  C1_STATE=time_boxed                     # rehearsal: the build was never meant to finish
elif [ "$LAKE_RC" = 0 ]; then
  C1_STATE=built
else
  # Once more, with half as many jobs in case the failure was a compiler killed for lack of memory. The build tool
  # only redoes what failed or was never reached, which can be most of the tree, so it is watched like the first pass.
  RETRIED=1; safe_cp "$LAKELOG" "$PD/first_failure.log"; gz_put "$PD/first_failure.log" "$RES/logs/first_failure.log.gz"
  [ "$TESTS_DONE" = 1 ] && say "prune before the second pass: $(prune 0)"
  BUILD_JOBS=$(( NMAX / 2 )); [ "$BUILD_JOBS" -ge 1 ] || BUILD_JOBS=1
  status build RUNNING "build tool exited with status $LAKE_RC; second pass with $BUILD_JOBS jobs"
  phase_mark "build_retry:N=$BUILD_JOBS"
  start_lake; monitor_build
  if [ "$LAKE_RC" = 0 ]; then C1_STATE=built_on_second_pass; else C1_STATE=failed; fi
fi
fi
[ "$SPOT" = 1 ] && spot_stop_loops gently
stop_build; kill_users
[ "$SPOT" = 1 ] && spot_ckpt_final            # the last parts are cut as the build user, before its account is locked
# The build user's work is over. Its account is locked now, before anything it left behind is examined, and any
# process of it that appears from here on is killed and recorded.
if [ "$SPOT" = 1 ] && [ "$SPOT_LOCKED" = 1 ]; then
  say "the build user was locked before the compiled files were restored"
else
crontab -r -u pilot 2>/dev/null; usermod -L -s /usr/sbin/nologin pilot || finish FAIL "could not lock the build user's account"
loginctl disable-linger pilot 2>/dev/null; kill_users
( while true; do if pgrep -u pilot >/dev/null 2>&1; then date -u +%FT%TZ >> "$PD/build_user_seen_after_seal"; pkill -KILL -u pilot; fi; sleep 5; done ) & GUARD_PID=$!
fi
[ "$SPOT" = 1 ] && SPOT_LOCKED=1
phases_end build "$(n_finished)" "$(failed_lines)"
put_logs                                   # the evidence for C1, uploaded now
if [ "$C1_STATE" = failed ]; then
  # Evidence: each failed job line with the compiler output that follows it, from the last pass.
  if plain "$LAKELOG"; then awk '/^✖ /{p=1} /^(✔|⚠|ℹ) \[/{p=0} p' "$LAKELOG" > "$PD/build_failures.txt"; grep '^✖ ' "$LAKELOG" | sort -u > "$PD/build_failed_jobs.txt"; else : > "$PD/build_failures.txt"; : > "$PD/build_failed_jobs.txt"; fi
  FAILED_JOBS=$(wc -l < "$PD/build_failed_jobs.txt")
  # 137 and 143 are a compiler killed from outside (out of memory, or a signal from this script). Any other status
  # of 128 or more is a compiler that crashed by itself, which may well happen again however much memory there is.
  KILLED_JOBS=$(grep -cE 'Lean exited with code (137|143)$' "$PD/build_failures.txt")
  CRASHED_JOBS=$(( $(grep -cE 'Lean exited with code (12[89]|1[3-9][0-9]|2[0-9][0-9])$' "$PD/build_failures.txt") - KILLED_JOBS ))
  gz_put "$PD/build_failures.txt" "$RES/build_failures.txt.gz"; gcs_put "$PD/build_failed_jobs.txt" "$RES/build_failed_jobs.txt"
  if [ "$FAILED_JOBS" -eq 0 ] || [ "$LAKE_RC" -ge 128 ]; then
    C1_STATE=build_tool_failed
    finish FAIL "the build tool itself ended with status $LAKE_RC on both passes ($FAILED_JOBS failed job lines in the last). That is a failure of the run, not a result about any module"
  fi
  if [ "$KILLED_JOBS" -gt 0 ]; then
    C1_STATE=failed_with_killed_compilers
    finish BUILD_FAILED "the build failed twice: $FAILED_JOBS failed job lines, of which $KILLED_JOBS were compiler processes killed from outside. A killed compiler is not a test of its module (PREREGISTRATION.md, section 4): re-run with more memory or fewer jobs"
  fi
  finish BUILD_FAILED "the build failed twice: $FAILED_JOBS failed job lines, of which $CRASHED_JOBS were crashes of the compiler and the rest Lean errors; see build_failures.txt.gz. Whether criterion C1 has failed is for a person to confirm (PREREGISTRATION.md, section 4)"
fi
# Compared by name, not by count: every source module must be compiled, nothing else may be, and no compiled
# file may carry the name of a library module (it would be found before the real one).
c1_names() {
  python3 -I - "$PROJ/src" "$LIB" "$PD/c1_modules.txt" <<'PY'
import os, sys
def mods(root, ext):
    out = set()
    for d, _dirs, files in os.walk(root):
        for f in files:
            if f.endswith(ext): out.add(os.path.relpath(os.path.join(d, f), root)[:-len(ext)].replace(os.sep, '.'))
    return out
ROOTS = {'Init', 'Std', 'Lean', 'Lake', 'Mathlib', 'Batteries', 'Aesop', 'Qq', 'ProofWidgets', 'Plausible', 'ImportGraph', 'LeanSearchClient', 'Cli'}
src, comp = mods(sys.argv[1], '.lean'), mods(sys.argv[2], '.olean')
missing, extra = sorted(src - comp), sorted(comp - src)
shadow = sorted(m for m in comp if m.split('.')[0] in ROOTS)
with open(sys.argv[3], 'w') as fh:
    for label, L in (('not_compiled', missing), ('no_source', extra), ('named_like_a_library', shadow)):
        for m in L[:500]: fh.write('%s\t%s\n' % (label, m))
print(len(missing), len(extra), len(shadow))
PY
}
read -r C1_MISSING C1_EXTRA C1_SHADOW <<< "$(c1_names)"
gcs_put "$PD/c1_modules.txt" "$RES/c1_modules.txt"
NCOMP=$(find "$LIB" -name '*.olean' | wc -l)
if [ "${C1_EXTRA:-1}" != 0 ] || [ "${C1_SHADOW:-1}" != 0 ]; then C1_STATE=unexpected_compiled_files; finish FAIL "compiled files that correspond to no source module: ${C1_EXTRA:-unknown}; named like a library module: ${C1_SHADOW:-unknown}"; fi
if [ "$TIMEBOX" = 0 ] && [ "${C1_MISSING:-1}" != 0 ]; then C1_STATE=incomplete; finish FAIL "the build tool reported success but ${C1_MISSING:-an unknown number} of $NSRC source modules are not compiled"; fi
say "final prune: $(prune 0)"
checkpoint "the build has ended; the seal is next"
[ "$SPOT" = 1 ] && [ "$SEAL_DONE" = 0 ] && spot_record build seal C1_STATE LAKE_RC RETRIED

# ---------------------------------------------------------------- seal
# From here on nothing runs as the build user. What it could have altered is compared with the records taken
# before any file of the proof was compiled, then handed to root, and the checks run as two fresh users.
[ "$(left)" -gt $(( FINAL_RESERVE + 600 )) ] || finish DEADLINE "the build finished too close to the deadline to run any check"
phase_mark seal; status seal RUNNING "$NCOMP modules compiled; sealing and hashing"
[ "$SPOT" = 1 ] && spot_hold
kill_users
same() { # same <label> <baseline> <current>   -- prints 1 if identical, else 0, and uploads the difference
  if cmp -s "$2" "$3"; then echo 1; else diff "$2" "$3" | head -200 > "$PD/changed_$1.txt"; gcs_put "$PD/changed_$1.txt" "$RES/changed_$1.txt"; echo 0; fi
}
src_manifest > "$PD/seal_src.txt"; tc_manifest "$TC_DIR" > "$PD/seal_tc.txt"; pkgs_manifest > "$PD/seal_pkgs.txt"
deadline_check
SRC_SAME=$(same src "$PD/baseline_src.txt" "$PD/seal_src.txt")
LIBS_SAME=1; [ "$(same tc "$PD/baseline_tc.txt" "$PD/seal_tc.txt")" = 1 ] && [ "$(same pkgs "$PD/baseline_pkgs.txt" "$PD/seal_pkgs.txt")" = 1 ] || LIBS_SAME=0
[ "$SRC_SAME" = 1 ] || finish FAIL "the source tree changed during the build; see changed_src.txt"
[ "$LIBS_SAME" = 1 ] || finish FAIL "the toolchain or Mathlib's compiled files changed during the build; see changed_tc.txt and changed_pkgs.txt"
# The toolchain the checks will use: a copy under a directory only root has ever written, proved identical.
rm -rf /opt/lean-tc && cp -a "$TC_DIR" /opt/lean-tc && chown -R root:root /opt/lean-tc && chmod -R go-w /opt/lean-tc || finish FAIL "could not copy the toolchain"
tc_manifest /opt/lean-tc > "$PD/seal_tc_copy.txt"; deadline_check
TC_COPY_SAME=$(same tc_copy "$PD/baseline_tc.txt" "$PD/seal_tc_copy.txt")
[ "$TC_COPY_SAME" = 1 ] || finish FAIL "the sealed copy of the toolchain differs from the toolchain as installed"
# No link in the copy may lead out of it (a library found through such a link would be loaded by the checkers).
[ -z "$(find /opt/lean-tc -type l -print0 | xargs -0 -r -n 1 realpath -m 2>/dev/null | grep -v -e '^/opt/lean-tc/' -e '^/opt/lean-tc$' | head -1)" ] \
  || finish FAIL "the toolchain contains a symbolic link that leads outside it"
TC_BIN=/opt/lean-tc/bin
# The project, with Mathlib inside it, goes to root; the build logs leave the directory a checker will own; and
# the directories the checks write to are made afresh, so that nothing in them predates the seal.
for f in $(lake_logs); do case "$f" in "$LOGS"/*) safe_cp "$f" "$PD/$(basename "$f")" ;; esac; done
touch "$PD/SEALED"                          # from now on only the copies in $PD are the build's logs
rm -rf "$LOGS" "$AN" "$WORK/download" || finish FAIL "could not clear the working directories"
# Mathlib's cache is unpacked readable by its owner only, so read permission for everyone is added here: the
# second rehearsal's checks all failed with "Permission denied" for want of it.
chown -R root:root "$WORK" && chmod -R a+rX,go-w "$WORK" || finish FAIL "could not hand the project to root"
[ -z "$(find "$WORK" ! -user root -print -quit)" ] || finish FAIL "a file under the working directory is still not owned by root"
[ -z "$(find "$WORK/extract" \( -type f ! -perm -o=r -o -type d ! -perm -o=rx \) -print -quit)" ] || finish FAIL "a file or directory of the project is not readable by the checkers"
[ -z "$(find "$PROJ/.lake" -type f -links +1 -path '*/lib/lean/*' -print -quit)" ] || finish FAIL "a compiled file has more than one hard link"
# A compiler killed while it was writing leaves the half-written file behind, named <module>.olean.tmp.<pid>
# (the fourth rehearsal: one such file, from the compile the time box cut off). The restart tests of a full run
# kill compilers too. The build tool compiles such a module again under its proper name and nothing ever reads
# the leftover, so these, and only these, are listed, removed and counted here: regular files whose name ends
# in .olean.tmp.<digits> or .ilean.tmp.<digits>.
# A rehearsal plants one, so that this step is exercised whether or not a compiler happened to be cut off in mid-write.
[ "$TIMEBOX" -gt 0 ] && : > "$LIB/RehearsalStandIn.olean.tmp.1"
find "$LIB" -type f -regextype posix-extended -regex '.*\.(olean|ilean)\.tmp\.[0-9]+' -print -delete > "$PD/compiler_leftovers.txt" 2>/dev/null
LEFTOVERS=$(wc -l < "$PD/compiler_leftovers.txt")
if [ "$TIMEBOX" -gt 0 ] && { [ "$LEFTOVERS" -lt 1 ] || [ -e "$LIB/RehearsalStandIn.olean.tmp.1" ]; }; then finish FAIL "the stand-in for a killed compiler's half-written file was not removed"; fi
[ "$LEFTOVERS" = 0 ] || { say "seal: removed $LEFTOVERS half-written files left by killed compilers"; gcs_put "$PD/compiler_leftovers.txt" "$RES/compiler_leftovers.txt"; }
# Beside the compiled modules there may be only what the build tool writes for this project: .olean, .ilean,
# their .hash files and .trace. In particular no .olean.server or .olean.private: the kernel replay would read
# those in place of the .olean that the axiom check and every importing module read.
find "$LIB" ! -type d \( ! -type f -o ! \( -name '*.olean' -o -name '*.olean.hash' -o -name '*.ilean' -o -name '*.ilean.hash' -o -name '*.trace' \) \) -print > "$PD/unexpected_lib_files.txt"
LIB_OTHER=$(wc -l < "$PD/unexpected_lib_files.txt")
if [ "$LIB_OTHER" != 0 ]; then gcs_put "$PD/unexpected_lib_files.txt" "$RES/unexpected_lib_files.txt"; finish FAIL "$LIB_OTHER files beside the compiled modules are of a kind the build does not write; see unexpected_lib_files.txt"; fi
# Spot, an attempt after the first seal: the run's figures are the first seal's; this machine's go under "spot".
if [ "$SPOT" = 1 ] && [ "$SEAL_DONE" = 1 ]; then SPOT_LEFTOVERS_HERE=$LEFTOVERS; SPOT_LIB_OTHER_HERE=$LIB_OTHER; spot_load LEFTOVERS LIB_OTHER; fi
for u in chk2 chk3; do
  id "$u" >/dev/null 2>&1 || useradd -m -s /bin/bash "$u" || finish FAIL "could not create the user $u"
  no_network "$u" || finish FAIL "could not cut the user $u off from the network"
done
mkdir "$LOGS" "$AN" "$WORK/download" && chown chk2:chk2 "$LOGS" && chown chk3:chk3 "$AN" && chmod 755 "$LOGS" "$AN" || finish FAIL "could not prepare the checkers' directories"
for u in chk2 chk3; do
  [ "$(as_chk "$u" 'lean --version' | tail -1)" = "$LEAN_VERSION" ] || finish FAIL "the user $u does not see the pinned toolchain"
  if as_chk "$u" "touch $LIB/.w 2>/dev/null || touch $TC_BIN/.w 2>/dev/null || touch $PROJ/.lake/packages/.w 2>/dev/null || touch $TOOLS/.w 2>/dev/null || touch /opt/rhv-replay/.w 2>/dev/null"; then finish FAIL "the user $u can write to files the checks rely on"; fi
done
if [ -n "$DRIVER" ]; then
  # The replay program: still the file root built before the first compile, and still only root's to change.
  DRIVER_SAME=0; [ "$(sha256sum "$DRIVER" | cut -d' ' -f1)" = "$DRIVER_SHA" ] && [ -z "$(find /opt/rhv-replay \( ! -user root -o -perm /go+w \) -print -quit)" ] && DRIVER_SAME=1
  [ "$DRIVER_SAME" = 1 ] || finish FAIL "the replay program changed after it was built, or is not root's alone"
fi
if as_chk chk2 "touch $AN/.w 2>/dev/null"; then finish FAIL "the axiom check's user can write to the kernel replay's directory"; fi
# Both checks must be able to run here at all. Statements imports only Mathlib and was compiled during setup:
# the axiom check's user elaborates a file that imports it, and the replay's user replays it. A failure here is
# a fault of this environment and ends the run before anything could be mistaken for a result.
SEAL_LP=$PROJ/.lake/build/lib/lean; for d in "$PROJ"/.lake/packages/*/.lake/build/lib/lean; do SEAL_LP="$SEAL_LP:$d"; done
printf 'import Statements\n' > "$PD/seal_test.lean"; chmod 644 "$PD/seal_test.lean"
as_chk chk2 "LEAN_PATH='$SEAL_LP' timeout 300 lean $PD/seal_test.lean" > "$PD/seal_test_chk2.txt" 2>&1 \
  || { gcs_put "$PD/seal_test_chk2.txt" "$RES/seal_test_chk2.txt"; finish FAIL "the axiom check's user cannot elaborate a file that imports a compiled module: $(head -c 300 "$PD/seal_test_chk2.txt" | tr '\n' ' ')"; }
as_chk chk3 "LEAN_PATH='$SEAL_LP' timeout 300 leanchecker Statements" > "$PD/seal_test_chk3.txt" 2>&1 \
  || { gcs_put "$PD/seal_test_chk3.txt" "$RES/seal_test_chk3.txt"; finish FAIL "the replay's user cannot replay a compiled module: $(head -c 300 "$PD/seal_test_chk3.txt" | tr '\n' ' ')"; }
# The replay gives each leanchecker process a directory of hard links to the compiled files it needs, and to
# nothing else of the project. The replay's user does not own those files, and this system by default lets a
# user hard-link only files it owns. A hard link gives no way to change a file one cannot already change, and
# this machine does nothing but this run, so the restriction is lifted. The import graph the directories are
# made from is read from the sealed source tree here, once.
sysctl -w fs.protected_hardlinks=0 >/dev/null || finish FAIL "could not allow hard links to the sealed files"
as_chk chk3 "mkdir -p $AN/kernel_replay && ln $LIB/Statements.olean $AN/kernel_replay/.probe.olean && rm -f $AN/kernel_replay/.probe.olean" \
  || finish FAIL "the replay's user cannot hard-link a compiled file into its own directory"
as_chk chk3 "timeout 900 python3 -I -B $TOOLS/scripts/verify/rhv_tools.py import-graph --src $PROJ/src --out $AN/kernel_replay/import_graph.json" > "$PD/import_graph.txt" 2>&1 \
  || finish FAIL "could not read the import graph from the source tree: $(head -c 300 "$PD/import_graph.txt" | tr '\n' ' ')"
cat "$PD/import_graph.txt" >> "$PD/env.txt"
if [ -n "$DRIVER" ]; then
  as_chk chk3 "LEAN_NUM_THREADS=1 LEAN_PATH='$SEAL_LP' timeout 300 $DRIVER Statements" > "$PD/seal_test_driver.txt" 2>&1
  grep -qE '^REPLAY_OK Statements [0-9]+$' "$PD/seal_test_driver.txt" \
    || { gcs_put "$PD/seal_test_driver.txt" "$RES/seal_test_driver.txt"; finish FAIL "the replay's user cannot replay a compiled module with the replay program: $(head -c 300 "$PD/seal_test_driver.txt" | tr '\n' ' ')"; }
fi
kill_users
# A fingerprint of every file beside the compiled modules, and so of every compiled module.
lib_manifest > "$PD/lib_sha256.txt"; deadline_check
[ "$(grep -c '\.olean$' "$PD/lib_sha256.txt")" -eq "$NCOMP" ] && [ "$(wc -l < "$PD/lib_sha256.txt")" -eq "$(find "$LIB" -type f | wc -l)" ] \
  || finish FAIL "the hash manifest does not list every file beside the $NCOMP compiled modules"
MANIFEST_SHA=$(sha256sum "$PD/lib_sha256.txt" | cut -d' ' -f1)
[ "$SPOT" = 1 ] && spot_seal_manifest
gz_put "$PD/lib_sha256.txt" "$RES/lib_sha256.txt.gz" || say "WARNING: the manifest of compiled files was not uploaded"
gz_put "$PD/baseline_tc.txt" "$RES/toolchain_sha256.txt.gz"; gz_put "$PD/baseline_pkgs.txt" "$RES/libraries_sha256.txt.gz"
disk_facts; gcs_put "$PD/disk.txt" "$RES/disk_after_build.txt"
sync_small; checkpoint "sealed; the checks are next"
[ "$SPOT" = 1 ] && spot_after_seal

# ---------------------------------------------------------------- criterion C2: statement and axioms (user chk2)
mkdir -p "$PD/c2"
run_c2() { # run_c2 <label> <arguments for 08_check_axioms.sh> <seconds>   -- prints the script's exit status
  local rc kind=full f i
  case "$2" in *--probe*) kind=probe ;; esac
  as_chk chk2 "timeout --signal=TERM $3 bash $TOOLS/scripts/08_check_axioms.sh $2 > $LOGS/c2_$1.out 2>&1; echo \$? > $LOGS/c2_$1.rc"
  # The process that just ran imported the proof. Before anything it wrote is read, nothing of its user may be running.
  crontab -r -u chk2 2>/dev/null; for i in 1 2 3 4 5; do pkill -KILL -u chk2 2>/dev/null; pgrep -u chk2 >/dev/null 2>&1 || break; sleep 1; done
  rm -f "$PD/c2/$1.json" "$PD/c2_$1.rc" "$PD/c2_$1.out"
  safe_cp "$LOGS/c2_$1.rc" "$PD/c2_$1.rc"; safe_cp "$LOGS/c2_$1.out" "$PD/c2_$1.out"
  rc=$(cat "$PD/c2_$1.rc" 2>/dev/null); case "$rc" in ''|*[!0-9]*) rc=99 ;; esac
  gz_put "$PD/c2_$1.out" "$RES/logs/c2_$1.out.gz"
  # The summary and the log are taken only if this run of the script wrote them: plain files newer than the marker.
  f=$(find "$LOGS" -maxdepth 1 -type f -name "axioms-$kind-latest.json" -newer "$PD/c2_start" 2>/dev/null | head -1)
  [ -n "$f" ] && safe_cp "$f" "$PD/c2/$1.json"
  f=$(find "$LOGS" -maxdepth 1 -type f -name "axioms-$kind-2*.log" -newer "$PD/c2_start" 2>/dev/null | LC_ALL=C sort | tail -1)
  if [ -n "$f" ]; then
    safe_cp "$f" "$PD/c2/$1.log" && gz_put "$PD/c2/$1.log" "$RES/c2/$1.log.gz"
    safe_cp "${f%.log}.modules.tsv" "$PD/c2/$1.modules.tsv" && gcs_put "$PD/c2/$1.modules.tsv" "$RES/c2/$1.modules.tsv"
  fi
  gcs_put "$PD/c2/$1.json" "$RES/c2/$1.json"
  echo "$rc"
}
c2_deep() { # c2_deep <seconds> <when>
  phase_mark c2_deep; status c2 RUNNING "axiom check with the deep walk"
  touch "$PD/c2_start"; sleep 1
  C2_DEEP_RC=$(run_c2 deep "$C2_ARGS --deep" "$1"); C2_DEEP_WHEN=$2
  say "deep axiom check exit status: $C2_DEEP_RC"; deadline_check
  if [ "$SPOT" = 1 ]; then
    spot_check_cut "$C2_DEEP_RC" $(( $(stat -c %Y "$PD/c2_start") + $1 )); spot_c2_save deep c2_deep c3 C2_DEEP_RC C2_DEEP_WHEN
  fi
}
C2_ARGS=""; [ "$TIMEBOX" -gt 0 ] && C2_ARGS="--probe"
t=$(( $(left) - FINAL_RESERVE )); [ "$t" -gt "$C2_TIMEOUT" ] && t=$C2_TIMEOUT
[ "$SPOT" = 1 ] && t=$C2_TIMEOUT                 # Spot: the attempt's time left is no reason for a shorter check
[ "$SPOT" = 1 ] && spot_done c2_plain && { spot_c2_reload plain C2_PLAIN_RC; t=0; }
if [ "$t" -ge 300 ]; then
  phase_mark c2_plain; status c2 RUNNING "axiom and statement check"
  touch "$PD/c2_start"; sleep 1
  C2_PLAIN_RC=$(run_c2 plain "$C2_ARGS" "$t"); say "axiom check exit status: $C2_PLAIN_RC"; deadline_check
  if [ "$SPOT" = 1 ]; then spot_check_cut "$C2_PLAIN_RC" $(( $(stat -c %Y "$PD/c2_start") + t )); spot_c2_save plain c2_plain c2 C2_PLAIN_RC; fi
fi
phase_mark idle; sync_small; checkpoint "the plain axiom check has run"

# ---------------------------------------------------------------- criterion C3: kernel replay of every module (user chk3)
# leanchecker, the tool the criterion names, on every compiled module, each with only its import closure on the
# search path (scripts/09_kernel_replay.sh). If SECOND_REPLAY is set, rhv-replay then replays every module too,
# as a second opinion from a different program; it is not part of the criterion.
replay() { # replay <label> <jobs> <seconds> <arguments for 09_kernel_replay.sh>   -- resumable; whatever finishes is kept. Prints the script's exit status.
  local rc
  # The script cleans up and stops when it is told to terminate; if it has not gone a minute later, it is killed.
  as_chk chk3 "timeout --signal=TERM --kill-after=60 $3 bash $TOOLS/scripts/09_kernel_replay.sh --jobs $2 $4 > $AN/c3_$1.out 2>&1; echo \$? > $AN/c3_$1.rc"
  pkill -KILL -x leanchecker 2>/dev/null; pkill -KILL -x rhv-replay 2>/dev/null; pkill -KILL -u chk3 2>/dev/null
  rm -f "$PD/c3_$1.rc"; safe_cp "$AN/c3_$1.out" "$PD/c3_$1.out"; safe_cp "$AN/c3_$1.rc" "$PD/c3_$1.rc"
  rc=$(cat "$PD/c3_$1.rc" 2>/dev/null); case "$rc" in ''|*[!0-9]*) rc=99 ;; esac
  echo "$rc"
}
n_checked() { local f=$AN/kernel_replay/results.tsv; if plain "$f"; then echo $(( $(wc -l < "$f") - 1 )); else echo 0; fi; }
n_passed() { local f=$AN/kernel_replay/results.tsv; if plain "$f"; then awk -F'\t' 'NR>1 && $2==0 && $6=="leanchecker" {n++} END{print n+0}' "$f"; else echo 0; fi; }
c3_left() { python3 -I -c 'import json,sys
try:
    print(int(json.load(open(sys.argv[1]))["leanchecker_still_to_check"]))      # what the plan would still select
except Exception: print(-1)' "$PD/c3_summary.json"; }
CHECK_JOBS=$NMAX
C3_NEED=$(( NCOMP / 3 ))                  # seconds the replay is taken to need if no trial measures it
n_trials=$(echo $CHECK_TRIAL | wc -w)
[ "$SPOT" = 1 ] && spot_done trials && { spot_load CHECK_JOBS C3_RATE C3_NEED C3_EXPECT C3_FITS; n_trials=0; say "replay trials: completed by an earlier attempt"; }
if [ "$n_trials" -gt 0 ] && { [ "$SPOT" = 1 ] || [ "$(left)" -gt $(( n_trials * TRIAL_SECS + FINAL_RESERVE + 600 )) ]; }; then
  # A short run at each job count; every result is kept. The rate is counted after a warm-up (a third of the
  # trial, at most 90 seconds), which goes on planning the run and on start-up. The modules arrive in a fixed
  # shuffled order, so each trial sees a similar mix. Only modules that were really checked count.
  best=0; warm=$(( TRIAL_SECS / 3 )); [ "$warm" -gt 90 ] && warm=90
  [ "$SPOT" = 1 ] && spot_res_loop_start      # Spot: trial results are real results, and are kept like any other
  for j in $CHECK_TRIAL; do
    [ "$j" -le "$NMAX" ] || continue
    phase_mark "check_trial:N=$j"; status c3 RUNNING "kernel replay, trial at $j at a time"
    t=$(now); replay "trial$j" "$j" "$TRIAL_SECS" "--method leanchecker" >/dev/null; deadline_check
    [ "$SPOT" = 1 ] && spot_check_cut "$(cat "$PD/c3_trial$j.rc" 2>/dev/null || echo 99)" $(( t + TRIAL_SECS ))
    rate=0; plain "$AN/kernel_replay/results.tsv" && rate=$(awk -F'\t' -v a=$((t + warm)) -v b="$(now)" 'NR>1 && $5>=a && $5<=b && ($2==0 || $2==1) {n++} END{print n+0}' "$AN/kernel_replay/results.tsv")
    phases_end "check_trial" "${rate:-0}" "$j"; say "replay trial: $j at a time finished ${rate:-0} modules in the counted window"
    [ "${rate:-0}" -gt "$best" ] && { best=$rate; CHECK_JOBS=$j; }
  done
  # What the trials say about the whole tree. No result at all in a trial means a rate too low to finish. The
  # modules arrive in a shuffled order, so the trials see the tree's mix of small and large import closures.
  togo=$(( NCOMP - $(n_passed) )); [ "$togo" -gt 0 ] || togo=0
  if [ "$best" -gt 0 ]; then
    C3_RATE=$(awk -v n="$best" -v s=$(( TRIAL_SECS - warm )) 'BEGIN{printf "%.2f", n / s}')
    C3_NEED=$(awk -v m="$togo" -v n="$best" -v s=$(( TRIAL_SECS - warm )) 'BEGIN{printf "%d", m * s / n + 1}')
  else
    C3_RATE=0; C3_NEED=$(( togo * TRIAL_SECS ))
  fi
  C3_EXPECT=$C3_NEED
  if [ "$C3_NEED" -le $(( $(left) - FINAL_RESERVE )) ]; then C3_FITS=1; else C3_FITS=0; fi
  [ "$SPOT" = 1 ] && C3_FITS=1               # Spot: decided as if time were unlimited; the next attempt carries on
  say "replay: $C3_RATE modules a second at $CHECK_JOBS at a time; $togo modules to go need about $C3_NEED s; $(left) s left; fits: $C3_FITS"
fi
if [ "$SPOT" = 1 ] && ! spot_done trials; then spot_unit_confirmed; spot_record trials c3 CHECK_JOBS C3_RATE C3_NEED C3_EXPECT C3_FITS; fi
checkpoint "the replay's rate has been measured"
# The deep walk of the axiom check runs now if the replay will still fit afterwards; otherwise after it, if time remains.
t=$(( $(left) - FINAL_RESERVE - C3_NEED - C3_NEED / 8 )); [ "$t" -gt "$C2_TIMEOUT" ] && t=$C2_TIMEOUT
[ "$SPOT" = 1 ] && t=$C2_TIMEOUT
if [ "$SPOT" = 1 ] && spot_done c2_deep; then spot_c2_reload deep C2_DEEP_RC C2_DEEP_WHEN
elif [ "$C3_FITS" != 0 ] && [ "$t" -ge 900 ]; then c2_deep "$t" before_replay; else C2_DEEP_WHEN=deferred; fi
# A line of progress every five minutes while a replay runs; stopped while anything else has the machine.
c3_progress_start() { ( while true; do sleep 300; printf '%s\tcheck\t%s\t\t\n' "$(now)" "$(n_checked)" >> "$PD/progress.tsv"; status c3 RUNNING "kernel replay: $(n_checked) results of $NCOMP modules"; done ) & PROG_PID=$!; }
c3_progress_stop() { if [ -n "${PROG_PID:-}" ]; then kill "$PROG_PID" 2>/dev/null; wait "$PROG_PID" 2>/dev/null; fi; PROG_PID=""; }
# Spot: the main replay, if an earlier attempt completed it, is not run again (its results were restored).
if [ "$SPOT" = 1 ] && spot_done main; then
  spot_load C3_RC C3_MAIN_T C3_PASSES; c3_summary; say "kernel replay: completed by an earlier attempt"
else
phase_mark "check:N=$CHECK_JOBS"; status c3 RUNNING "kernel replay by leanchecker, $CHECK_JOBS at a time; $(n_checked) results so far"
c3_progress_start
[ "$SPOT" = 1 ] && spot_res_loop_start
t=$(( $(left) - FINAL_RESERVE )); [ "$t" -gt 60 ] || t=60
if [ "$C3_FITS" = 0 ]; then
  # It cannot finish. Hours more of it would not change what can be said about criterion C3, so it is given a
  # bounded time: the modules are taken in a fixed shuffled order, so what it reaches is a random sample.
  [ "$t" -gt "$C3_SHORT_CAP" ] && t=$C3_SHORT_CAP
  say "kernel replay: it cannot cover the tree in the time left (about $C3_NEED s needed); running it for $t s only"
fi
C3_MAIN_T=$t; C3_PASSES=1
[ "$SPOT" = 1 ] && SPOT_END=$(( $(now) + t ))
C3_RC=$(replay main "$CHECK_JOBS" "$t" "--method leanchecker"); deadline_check
[ "$SPOT" = 1 ] && spot_check_cut "$C3_RC" "$SPOT_END"
c3_summary
# Modules whose checker was killed, or that a time limit cut off, are tried again with a quarter of the jobs; and
# a module the tool rejected or crashed on gets the further runs it is owed. A pass that changes nothing is not
# followed by another.
pass=1; before=-2
while [ "$C3_FITS" != 0 ] && [ "$(c3_left)" != 0 ] && [ "$(c3_left)" != "$before" ] && [ "$pass" -le 2 ] && [ "$(left)" -gt $(( FINAL_RESERVE + 600 )) ]; do
  before=$(c3_left)
  j=$(( CHECK_JOBS / 4 )); [ "$j" -ge 2 ] || j=2
  say "kernel replay: $before modules still to check; pass $((pass + 1)) at $j at a time"
  C3_RC=$(replay "again$pass" "$j" "$(( $(left) - FINAL_RESERVE ))" "--method leanchecker"); deadline_check
  [ "$SPOT" = 1 ] && spot_check_cut "$C3_RC" $(( DEADLINE - FINAL_RESERVE ))    # its time limit ends there
  c3_summary; pass=$((pass + 1)); C3_PASSES=$pass
done
if [ "$SPOT" = 1 ]; then
  spot_unit_confirmed                      # the results confirmed and saved before the unit is recorded
  # Modules still to check and no time to check them: the next attempt carries on from the saved results.
  if [ "$(c3_left)" != 0 ] && [ "$(left)" -le $(( FINAL_RESERVE + 600 )) ]; then c3_progress_stop; spot_pause "the kernel replay has $(c3_left) modules still to check" deadline; fi
  spot_record main c3 C3_RC C3_MAIN_T C3_PASSES
fi
c3_progress_stop
fi
# The deep walk of the axiom check, if it was put off: it is part of criterion C2, so it comes before the
# optional second replay, which no criterion needs.
if [ "$C2_DEEP_WHEN" = deferred ]; then
  t=$(( $(left) - FINAL_RESERVE )); [ "$t" -gt "$C2_TIMEOUT" ] && t=$C2_TIMEOUT
  [ "$SPOT" = 1 ] && t=$C2_TIMEOUT
  if [ "$t" -ge 600 ]; then c2_deep "$t" after_replay; else C2_DEEP_WHEN=skipped_for_lack_of_time; fi
fi
# The optional second replay, by a different program. It runs only once leanchecker has had its whole turn, and
# not at all if leanchecker could not cover the tree: hours of a second opinion would then add nothing.
if [ "$SPOT" = 1 ] && spot_done second; then
  spot_load SECOND_RC SECOND_WHY; c3_summary; say "second replay: completed by an earlier attempt"
elif [ -n "$DRIVER" ]; then
  t=$(( $(left) - FINAL_RESERVE ))
  [ "$SPOT" = 1 ] && [ "$t" -lt 300 ] && spot_pause "under five minutes were left for the second replay" deadline
  if [ "$C3_FITS" = 0 ]; then SECOND_WHY="the replay by leanchecker could not cover the tree in the time there was"
  elif [ "$t" -lt 300 ]; then SECOND_WHY="under five minutes were left for it"
  else
    SECOND_WHY=""
    phase_mark "check_second:N=$NMAX"; status c3 RUNNING "second replay, by rhv-replay"; c3_progress_start
    [ "$SPOT" = 1 ] && { spot_res_loop_start; SPOT_END=$(( $(now) + t )); }
    SECOND_RC=$(replay second "$NMAX" "$t" "--method rhv-replay"); c3_progress_stop; deadline_check
    if [ "$SPOT" = 1 ]; then
      spot_check_cut "$SECOND_RC" "$SPOT_END"; spot_unit_confirmed
      # Cut off by the attempt's time, not finished; the next attempt carries on from the saved results.
      { [ "$SECOND_RC" = 124 ] || [ "$(left)" -le $(( FINAL_RESERVE + 60 )) ]; } && spot_pause "the second replay ran out of this attempt's time" deadline
    fi
    phases_end check_second "$(n_checked)" "$SECOND_RC"
    say "second replay, by rhv-replay: exit status $SECOND_RC"
  fi
  c3_summary
  if [ "$SPOT" = 1 ]; then spot_record second end SECOND_RC SECOND_WHY; fi
elif [ "$SECOND_REPLAY" = rhv-replay ]; then
  SECOND_WHY="the program was not built"
fi
c3_progress_stop
phases_end check "$(n_checked)" "$(plain "$AN/kernel_replay/results.tsv" && awk -F'\t' 'NR>1 && $2!=0' "$AN/kernel_replay/results.tsv" | wc -l)"
say "kernel replay: last exit status $C3_RC, $(n_checked) result lines"; cat "$PD/c3_summary.txt" 2>/dev/null
# The checker's own output for failed modules and for the prefix pass: plain files only, links not followed.
( cd "$AN/kernel_replay" 2>/dev/null && find out -maxdepth 1 -type f -print0 | timeout 600 tar -czf "$PD/c3_out.tar.gz" --null -T - 2>/dev/null ) && gcs_put "$PD/c3_out.tar.gz" "$RES/c3/out.tar.gz"
put_logs; checkpoint "the kernel replay has run"

# ---------------------------------------------------------------- end: nothing the checks relied on may have changed
# Spot: on the finishing attempt always, whatever an earlier attempt recorded; and what it finds ends the run.
phase_mark end_check; status end RUNNING "hashing the compiled files again"
kill_users
lib_manifest > "$PD/end_lib_sha256.txt"; pkgs_manifest > "$PD/end_pkgs.txt"; tc_manifest /opt/lean-tc > "$PD/end_tc.txt"; deadline_check
[ "$SPOT" = 1 ] && touch "$PD/FAIL_IS_FINAL"
OLEANS_SAME_END=$(same lib_end "$PD/lib_sha256.txt" "$PD/end_lib_sha256.txt")
LIBS_SAME_END=1; [ "$(same tc_end "$PD/baseline_tc.txt" "$PD/end_tc.txt")" = 1 ] && [ "$(same pkgs_end "$PD/baseline_pkgs.txt" "$PD/end_pkgs.txt")" = 1 ] || LIBS_SAME_END=0
[ "$OLEANS_SAME_END" = 1 ] && [ "$LIBS_SAME_END" = 1 ] || finish FAIL "files the checks rely on changed while the checks ran; their results cannot be used"
[ ! -e "$PD/build_user_seen_after_seal" ] || finish FAIL "a process of the build user appeared after the seal; the checks' results cannot be used"
# Spot: and on no earlier attempt either.
[ "$SPOT" = 1 ] && [ -n "$SEEN_ATTEMPTS" ] && finish FAIL "a process of the build user appeared after the seal on attempt(s) $SEEN_ATTEMPTS; the checks' results cannot be used"
[ "$SPOT" = 1 ] && spot_record end end OLEANS_SAME_END LIBS_SAME_END
phase_mark idle

# ---------------------------------------------------------------- optional: keep the compiled files
[ "$KEEP_OLEANS" = 1 ] && KEEP_STATE=skipped_for_lack_of_time
if [ "$KEEP_OLEANS" = 1 ] && [ "$(left)" -gt "$KEEP_MIN_LEFT" ]; then
  KEEP_STATE=started
  phase_mark keep; status keep RUNNING "all checks ran; archiving the compiled files"
  report CHECKS_DONE "all checks ran; the archive of compiled files was still being made when this was written"
  rm -rf "$WORK/keep"; mkdir -p "$WORK/keep"
  # In 2 GB parts, so that each upload is short and is retried on its own.
  if ( set -o pipefail; timeout "$(( $(left) - 600 ))" tar -C "$PROJ/.lake/build" -cf - lib | zstd -T0 -3 -q | split -b 2G -d -a 4 - "$WORK/keep/oleans.tar.zst.part" ); then
    ( cd "$WORK/keep" && sha256sum oleans.tar.zst.part* > SHA256SUMS ); KEEP_PARTS=0
    for f in "$WORK"/keep/oleans.tar.zst.part* "$WORK/keep/SHA256SUMS"; do
      [ "$(left)" -gt 420 ] || { say "no time left to upload the rest of the archive"; break; }
      gcs_put "$f" "keep/$RUNTAG/$(basename "$f")" && KEEP_PARTS=$((KEEP_PARTS + 1))
    done
    KEEP_STATE=made; [ "$KEEP_PARTS" -eq "$(ls "$WORK/keep" | wc -l)" ] || KEEP_STATE=partly_uploaded
    say "compiled files archived: $KEEP_PARTS objects uploaded, $(du -sh "$WORK/keep" | cut -f1)"
  else
    KEEP_STATE=failed_or_out_of_time
    say "archiving the compiled files failed or ran out of time"
  fi
  phase_mark idle
fi

finish DONE "all phases ran; read facts.json against PREREGISTRATION.md section 5"
