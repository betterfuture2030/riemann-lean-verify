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
#   c3      scripts/09_kernel_replay.sh on every module (criterion C3), as the user `chk3`. Short trials first
#           measure how many modules a second the replay manages; if that rate cannot cover the tree in the time
#           left, the replay is given an hour and the run goes on, and facts.json says so. Modules whose checker
#           was killed or cut off are tried again, with fewer at a time, up to twice.
#           The method is set at launch (full-replay-method). `leanchecker`: the stock tool, one process a module,
#           then its prefix pass. `rhv-replay`: the program in scripts/verify/replay, which root builds during
#           setup, before any file of the proof is compiled, after comparing its copy of the replay function with
#           the toolchain's source; then the stock tool again on a random sample of modules and on every prefix
#           module, so that the two can be compared on the same files (docs/performance-notes.md, section 10).
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
REPLAY_METHOD=$(md full-replay-method leanchecker)  # how the kernel replay covers the tree: leanchecker | rhv-replay
STOCK_SAMPLE=$(md full-stock-sample 2000)        # with rhv-replay: this many random modules are also checked by leanchecker
C3_SHORT_CAP=$(md full-c3-short-cap 3600)        # seconds given to a replay that the trials show cannot finish in time
FINISH_WAIT=$(md full-watchdog-finish-wait 1800) # more seconds the watchdog gives a main script that has begun its report
PREFIX_ALLOW=$(md full-prefix-allow 1200)        # with rhv-replay: seconds kept for the stock tool's prefix pass
DRIVER=""; DRIVER_SHA=""                         # the replay program, built by root during setup when the method needs it
GUEST_SHA=$(curl -sf --connect-timeout 5 --max-time 30 -H "Metadata-Flavor: Google" "$MDURL/attributes/startup-script" | sha256sum | cut -d' ' -f1)
DEADLINE=$(( T0 + DEADLINE_MIN * 60 ))
WORK=/mnt/work; PROJ=$WORK/extract/lean; LOGS=$WORK/logs; AN=$WORK/analysis; RES="results/$RUNTAG"; TOOLS=/opt/rhv
LIB=$PROJ/.lake/build/lib/lean
TC_BIN=""; TC_DIR=""                              # the pinned toolchain's bin directory and its parent, found during setup

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
  while true; do kill_users; gcs_put "$PD/status.json" "$RES/status.json" 2>/dev/null; sleep 60; done
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
as_chk() { runuser -u "$1" -- env -i HOME="/home/$1" LANG=C.UTF-8 PATH="$TC_BIN:/usr/bin:/bin" RH_WORKDIR="$WORK" RH_JOBS="$NMAX" RH_REPLAY_DRIVER="$DRIVER" bash -c "ulimit -n 1048576 2>/dev/null; cd $PROJ && $2"; }

# ---- facts.json: what happened, as numbers. Written whenever the run reports; fields not yet known are null.
C1_STATE=not_reached; LAKE_RC=""; RETRIED=0; RESTART_CONTROL=""; RESTART_PRUNE=""; RESTART_CONTROL_NEW=""; RESTART_PRUNE_NEW=""
FAILED_JOBS=""; KILLED_JOBS=""; CRASHED_JOBS=""; LIB_OTHER=""; KEEP_STATE=not_requested; LAKE_N=0; LEFTOVERS=""
C1_MISSING=""; C1_EXTRA=""; C1_SHADOW=""; SRC_SAME=""; LIBS_SAME=""; TC_COPY_SAME=""; MANIFEST_SHA=""
C2_PLAIN_RC=""; C2_DEEP_RC=""; C2_DEEP_WHEN=not_run; C3_RC=""; CHECK_JOBS=""; OLEANS_SAME_END=""; LIBS_SAME_END=""; KEEP_PARTS=""
C3_STOCK_RC=""; C3_PREFIX_RC=""; C3_FITS=""; C3_EXPECT=""; C3_RATE=""; DRIVER_SAME=""; STOCK_SQUEEZED=0; C3_STOCK_WHY=""; C3_PREFIX_WHY=""
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
  local rc
  timeout 900 python3 -I -B "$TOOLS/scripts/verify/rhv_tools.py" replay-summary --lib "$LIB" --src "$PROJ/src" --results "$AN/kernel_replay/results.tsv" --json "$PD/c3_summary.json.new" > "$PD/c3_summary.txt.new" 2> "$PD/c3_summary.err"
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
  F_LEFTOVERS=$LEFTOVERS F_METHOD=$REPLAY_METHOD F_DRIVER_SHA=$DRIVER_SHA F_DRIVER_SAME=$DRIVER_SAME F_C3_STOCK=$C3_STOCK_RC F_C3_PREFIX=$C3_PREFIX_RC \
  F_C3_FITS=$C3_FITS F_C3_EXPECT=$C3_EXPECT F_C3_RATE=$C3_RATE F_STOCK_SAMPLE=$STOCK_SAMPLE F_SQUEEZED=$STOCK_SQUEEZED \
  F_STOCK_WHY=$C3_STOCK_WHY F_PREFIX_WHY=$C3_PREFIX_WHY \
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
json.dump({
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
    'c3_kernel_replay': {'method_for_the_whole_tree': E('F_METHOD'), 'last_exit_status': num('F_C3'), 'jobs': num('F_CJOBS'),
                         # from the trials: modules a second at the chosen job count, the seconds the whole tree
                         # would then need, and whether that fitted in the time left (if not, the replay was cut short)
                         'trial_rate_modules_per_second': E('F_C3_RATE') or None, 'expected_seconds': num('F_C3_EXPECT'), 'expected_to_fit': yes('F_C3_FITS'),
                         'replay_program': None if E('F_METHOD') != 'rhv-replay' else {
                             'sha256': E('F_DRIVER_SHA') or None, 'unchanged_since_it_was_built': yes('F_DRIVER_SAME'),
                             'source_check': (open(os.path.join(E('F_PD'), 'driver_check.txt')).read().strip().splitlines()
                                              if os.path.isfile(os.path.join(E('F_PD'), 'driver_check.txt')) else None),
                             'every_recorded_run_used_this_program': (None if not c3 or not c3.get('rhv_replay_programs_used') else
                                                                      all(p.get('sha256') == E('F_DRIVER_SHA') for p in c3['rhv_replay_programs_used'])),
                             'stock_sample_requested': num('F_STOCK_SAMPLE'), 'stock_sample_exit_status': num('F_C3_STOCK'),
                             'stock_sample_not_run_because': E('F_STOCK_WHY') or None,
                             'stock_prefix_pass_exit_status': num('F_C3_PREFIX'),
                             'stock_prefix_pass_not_run_because': E('F_PREFIX_WHY') or None,
                             # true when the plan let the main pass use time kept for the stock tool's passes;
                             # it does not say the main pass needed it
                             'main_pass_was_allowed_time_kept_for_the_stock_tool': E('F_SQUEEZED') == '1'},
                         'summary': c3},
    'end': {'compiled_files_unchanged_since_seal': yes('F_OLEANS_END'), 'toolchain_and_mathlib_unchanged_since_seal': yes('F_LIBS_END'),
            'build_user_process_seen_after_seal': os.path.exists(seen)},
    'archive_of_compiled_files': {'state': E('F_KEEP_STATE'), 'objects_uploaded': num('F_KEEP')},
}, open(sys.argv[1], 'w'), indent=1)
PY
}
report() { # report <state> <message>   -- logs and facts.json. Safe to call more than once. Status of the facts upload.
  put_logs
  disk_facts; gcs_put "$PD/disk.txt" "$RES/disk.txt"
  c3_summary
  write_facts "$1" "$2"
  gcs_put "$PD/facts.json" "$RES/facts.json"
}
# checkpoint <message>: facts as they stand, so that a run cut short still leaves an account of how far it got.
checkpoint() { write_facts RUNNING "$1"; gcs_put "$PD/facts.json" "$RES/facts.json"; return 0; }
finish() { # finish <state> <message>   -- the final status is uploaded LAST: it is the watcher's signal to delete this VM
  trap '' TERM INT
  touch "$PD/FINISHING"                      # tells the watchdog that the report is under way
  say "FINISH $1: $2"
  stop_build
  local p i
  for p in "${SAMPLER_PID:-}" "${SYNC_PID:-}" "${PROG_PID:-}" "${GUARD_PID:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done
  [ -n "${SYNC_PID:-}" ] && wait "$SYNC_PID" 2>/dev/null       # no RUNNING status or half-made upload may follow the final one
  [ -n "${PROG_PID:-}" ] && wait "$PROG_PID" 2>/dev/null
  kill_users
  for i in 1 2 3; do report "$1" "$2" && break; sleep 20; done
  sync_big; sync_small
  status "$PHASE" "$1" "$2"
  say "idle: waiting to be deleted"; sync
  idle_until_deleted
}
t_step() { # t_step <name> <function>  -- time a setup step; a failed step ends the run
  local name=$1; shift; local s; s=$(now); say "setup: $name"
  if "$@"; then printf '%s\t%s\tok\n' "$name" "$(( $(now) - s ))" >> "$PD/setup.tsv"
  else printf '%s\t%s\tFAILED\n' "$name" "$(( $(now) - s ))" >> "$PD/setup.tsv"; finish FAIL "setup step failed: $name"; fi
}
on_signal() { if [ -e "$PD/DEADLINE" ]; then finish DEADLINE "guest deadline reached during phase $PHASE"; else finish FAIL "unexpected signal"; fi; }
# The watchdog kills helper processes at the deadline, which can leave a half-written file behind. Nothing may be
# concluded from such a file: call this before judging any result that took time to produce.
deadline_check() { [ -e "$PD/DEADLINE" ] && finish DEADLINE "guest deadline reached during phase $PHASE"; return 0; }

[ -n "$BUCKET" ] || { echo "no bucket in metadata; idling until deleted"; idle_until_deleted; }
# A startup script runs on every boot. Never run twice on one VM.
if [ -e "$PD/STARTED" ]; then status reboot FAIL "VM restarted; the run does not start twice"; idle_until_deleted; fi
date -u +%FT%TZ > "$PD/STARTED"
trap on_signal TERM INT
# If the bucket cannot be written to, nothing this run does could ever be collected: do no work at all.
status boot RUNNING "booted" || { echo "cannot write to the bucket; idling until deleted"; idle_until_deleted; }
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
  final_state() { grep -qE '"state": "(DONE|FAIL|DEADLINE|BUILD_FAILED)"' "$PD/status.json" 2>/dev/null; }
  # A main script that has begun its report is given longer: on the whole tree the report alone (hashing done,
  # but summaries to recompute and logs to upload) can take more than the first wait.
  w=0; while ! final_state && [ -e "$PD/FINISHING" ] && [ "$w" -lt "$FINISH_WAIT" ]; do sleep 20; w=$((w + 20)); done
  if ! final_state; then
    echo "### main script did not finish; watchdog taking over"
    kill_users
    for f in "$PD"/lake_build_*.log "$PD"/c2_*.out "$PD"/c3_*.out; do plain "$f" && gz_put "$f" "$RES/logs/$(basename "$f").gz"; done
    if [ ! -e "$PD/SEALED" ]; then for f in "$LOGS"/lake_build_*.log; do plain "$f" && gz_put "$f" "$RES/logs/$(basename "$f").gz"; done; fi
    gcs_put "$PD/facts.json" "$RES/facts.json"; sync_big; sync_small
    status watchdog DEADLINE "main script stuck at the deadline; the watchdog stopped the run (facts.json is from the last checkpoint)"
    while true; do kill_users; gcs_put "$PD/status.json" "$RES/status.json" 2>/dev/null; sleep 60; done
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
# The replay program, when the method needs it. Root builds it here, before any file of the proof has been
# compiled, in a directory only root can write. It is not built with the toolchain where the build user keeps
# it: root first makes its own copy of the toolchain, proves the copy identical to the record just taken, and
# builds with that. The program's copy of replayFromImports is compared, character for character, with the
# source in that same copy.
s_driver() {
  [ "$REPLAY_METHOD" = rhv-replay ] || return 0
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
t_step mathlib_cache s_cache
t_step baseline s_baseline
t_step replay_program s_driver
t_step lockdown s_lockdown
t_step smoke_build s_smoke
t_step replay_program_test s_driver_test
LEAN_VERSION=$(as_pilot 'lean --version' | tail -1)
echo "ulimit_n_pilot=$(as_pilot 'ulimit -n' | tail -1) max_map_count=$(cat /proc/sys/vm/max_map_count) lean=$LEAN_VERSION" >> "$PD/env.txt"
[ "$GUEST_SHA" = "$GUEST_SHA_WANT" ] || say "NOTE: this script's sha256 ($GUEST_SHA) is not the one the controller announced ($GUEST_SHA_WANT)"
NSRC=$(find "$PROJ/src" -name '*.lean' | wc -l)
python3 "$PD/sampler.py" "$PD" & SAMPLER_PID=$!
sync_small

# ---------------------------------------------------------------- build (criterion C1)
finished_modules() { ( cd "$LIB" 2>/dev/null && find . -name '*.trace' | sed -e 's|^\./||' -e 's|\.trace$||' -e 's|/|.|g' | LC_ALL=C sort ); }
n_finished() { find "$LIB" -name '*.trace' 2>/dev/null | wc -l; }
built_in_log() { plain "$1" || return 0; grep -E '^[^ ]+ \[[0-9]+/[0-9]+\] Built ' "$1" 2>/dev/null | sed -E 's/^[^ ]+ \[[0-9]+\/[0-9]+\] Built ([^ ]+).*/\1/' | LC_ALL=C sort -u; }
prune() { RH_WORKDIR=$WORK bash "$TOOLS/scripts/prune_setup_files.sh" --delete --min-age "$1" --project "$PROJ" 2>&1 | tr '\n' ' '; echo; }
LAKELOG=""; LAKE_JOB=""; BUILD_JOBS=$NMAX; BUILD_T0=$(now); TESTS_DONE=0; RESTART_RESULT=""; RESTART_NEW=""
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
}
monitor_build() { # watches the running build tool until it exits: the restart tests (once), pruning, disk space, progress
  local n free_gb nf last_prune last_status=0
  last_prune=$(now)
  while kill -0 "$LAKE_JOB" 2>/dev/null; do
    sleep 20
    [ -e "$PD/DEADLINE" ] && break
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

phase_mark "build:N=$NMAX"; status build RUNNING "starting the build of $NSRC modules"
printf 't\tphase\tfinished\tfailed_lines\tdisk_free_gb\n' > "$PD/progress.tsv"
BUILD_T0=$(now)
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
stop_build; kill_users
# The build user's work is over. Its account is locked now, before anything it left behind is examined, and any
# process of it that appears from here on is killed and recorded.
crontab -r -u pilot 2>/dev/null; usermod -L -s /usr/sbin/nologin pilot || finish FAIL "could not lock the build user's account"
loginctl disable-linger pilot 2>/dev/null; kill_users
( while true; do if pgrep -u pilot >/dev/null 2>&1; then date -u +%FT%TZ >> "$PD/build_user_seen_after_seal"; pkill -KILL -u pilot; fi; sleep 5; done ) & GUARD_PID=$!
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

# ---------------------------------------------------------------- seal
# From here on nothing runs as the build user. What it could have altered is compared with the records taken
# before any file of the proof was compiled, then handed to root, and the checks run as two fresh users.
[ "$(left)" -gt $(( FINAL_RESERVE + 600 )) ] || finish DEADLINE "the build finished too close to the deadline to run any check"
phase_mark seal; status seal RUNNING "$NCOMP modules compiled; sealing and hashing"
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
gz_put "$PD/lib_sha256.txt" "$RES/lib_sha256.txt.gz" || say "WARNING: the manifest of compiled files was not uploaded"
gz_put "$PD/baseline_tc.txt" "$RES/toolchain_sha256.txt.gz"; gz_put "$PD/baseline_pkgs.txt" "$RES/libraries_sha256.txt.gz"
disk_facts; gcs_put "$PD/disk.txt" "$RES/disk_after_build.txt"
sync_small; checkpoint "sealed; the checks are next"

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
}
C2_ARGS=""; [ "$TIMEBOX" -gt 0 ] && C2_ARGS="--probe"
t=$(( $(left) - FINAL_RESERVE )); [ "$t" -gt "$C2_TIMEOUT" ] && t=$C2_TIMEOUT
if [ "$t" -ge 300 ]; then
  phase_mark c2_plain; status c2 RUNNING "axiom and statement check"
  touch "$PD/c2_start"; sleep 1
  C2_PLAIN_RC=$(run_c2 plain "$C2_ARGS" "$t"); say "axiom check exit status: $C2_PLAIN_RC"; deadline_check
fi
phase_mark idle; sync_small; checkpoint "the plain axiom check has run"

# ---------------------------------------------------------------- criterion C3: kernel replay of every module (user chk3)
# The whole tree is covered by REPLAY_METHOD. With rhv-replay, a random sample and every prefix module are then
# checked again by the stock tool, so that the two can be compared on the same compiled files.
replay() { # replay <label> <jobs> <seconds> <arguments for 09_kernel_replay.sh>   -- resumable; whatever finishes is kept. Prints the script's exit status.
  local rc
  as_chk chk3 "timeout --signal=TERM $3 bash $TOOLS/scripts/09_kernel_replay.sh --jobs $2 $4 > $AN/c3_$1.out 2>&1; echo \$? > $AN/c3_$1.rc"
  pkill -KILL -x leanchecker 2>/dev/null; pkill -KILL -x rhv-replay 2>/dev/null; pkill -KILL -u chk3 2>/dev/null
  rm -f "$PD/c3_$1.rc"; safe_cp "$AN/c3_$1.out" "$PD/c3_$1.out"; safe_cp "$AN/c3_$1.rc" "$PD/c3_$1.rc"
  rc=$(cat "$PD/c3_$1.rc" 2>/dev/null); case "$rc" in ''|*[!0-9]*) rc=99 ;; esac
  echo "$rc"
}
n_checked() { local f=$AN/kernel_replay/results.tsv; if plain "$f"; then echo $(( $(wc -l < "$f") - 1 )); else echo 0; fi; }
n_passed() { local f=$AN/kernel_replay/results.tsv; if plain "$f"; then awk -F'\t' 'NR>1 && $2==0 {n++} END{print n+0}' "$f"; else echo 0; fi; }
c3_left() { python3 -I -c 'import json,sys
try:
    d = json.load(open(sys.argv[1])); print(d["remaining_that_another_run_could_check"])
except Exception: print(-1)' "$PD/c3_summary.json"; }
CHECK_JOBS=$NMAX; METHOD_ARGS="--method $REPLAY_METHOD"
# Time kept back for the stock tool's second look, which only follows rhv-replay: about a second a module for
# the sample on the whole tree, and PREFIX_ALLOW seconds (twenty minutes on the whole tree) for the prefix pass.
STOCK_NEED=0; [ "$REPLAY_METHOD" = rhv-replay ] && STOCK_NEED=$(( STOCK_SAMPLE + PREFIX_ALLOW ))
C3_NEED=$(( NCOMP / 3 ))                  # seconds the replay is taken to need if no trial measures it
n_trials=$(echo $CHECK_TRIAL | wc -w)
if [ "$n_trials" -gt 0 ] && [ "$(left)" -gt $(( n_trials * TRIAL_SECS + FINAL_RESERVE + 600 )) ]; then
  # A short run at each job count; every result is kept. The rate is counted after a warm-up (a third of the
  # trial, at most 90 seconds), which goes on planning the run and on start-up. The modules arrive in a fixed
  # shuffled order, so each trial sees a similar mix.
  best=0; warm=$(( TRIAL_SECS / 3 )); [ "$warm" -gt 90 ] && warm=90
  for j in $CHECK_TRIAL; do
    [ "$j" -le "$NMAX" ] || continue
    phase_mark "check_trial:N=$j"; status c3 RUNNING "kernel replay, trial at $j at a time"
    t=$(now); replay "trial$j" "$j" "$TRIAL_SECS" "$METHOD_ARGS" >/dev/null; deadline_check
    rate=0; plain "$AN/kernel_replay/results.tsv" && rate=$(awk -F'\t' -v a=$((t + warm)) -v b="$(now)" 'NR>1 && $5>=a && $5<=b && ($2==0 || $2==1) {n++} END{print n+0}' "$AN/kernel_replay/results.tsv")
    phases_end "check_trial" "${rate:-0}" "$j"; say "replay trial: $j at a time finished ${rate:-0} modules in the counted window"
    [ "${rate:-0}" -gt "$best" ] && { best=$rate; CHECK_JOBS=$j; }
  done
  # What the trials say about the whole tree. Every module is compiled by now, so the rate measured here is the
  # rate the rest of the replay will have. No result at all in a trial means a rate too low to finish.
  togo=$(( NCOMP - $(n_passed) )); [ "$togo" -gt 0 ] || togo=0
  if [ "$best" -gt 0 ]; then
    C3_RATE=$(awk -v n="$best" -v s=$(( TRIAL_SECS - warm )) 'BEGIN{printf "%.2f", n / s}')
    C3_NEED=$(awk -v m="$togo" -v n="$best" -v s=$(( TRIAL_SECS - warm )) 'BEGIN{printf "%d", m * s / n + 1}')
  else
    C3_RATE=0; C3_NEED=$(( togo * TRIAL_SECS ))
  fi
  C3_EXPECT=$C3_NEED
  # Whether the tree can be covered is a question about the main pass alone. The stock tool's second look
  # comes after it and takes what time is left.
  if [ "$C3_NEED" -le $(( $(left) - FINAL_RESERVE )) ]; then C3_FITS=1; else C3_FITS=0; fi
  say "replay: $C3_RATE modules a second at $CHECK_JOBS at a time; $togo modules to go need about $C3_NEED s; $(left) s left; fits: $C3_FITS"
fi
checkpoint "the replay's rate has been measured"
# The deep walk of the axiom check runs now if the replay will still fit afterwards; otherwise after it, if time remains.
t=$(( $(left) - FINAL_RESERVE - C3_NEED - STOCK_NEED )); [ "$t" -gt "$C2_TIMEOUT" ] && t=$C2_TIMEOUT
if [ "$C3_FITS" != 0 ] && [ "$t" -ge 900 ]; then c2_deep "$t" before_replay; else C2_DEEP_WHEN=deferred; fi
phase_mark "check:N=$CHECK_JOBS"; status c3 RUNNING "kernel replay by $REPLAY_METHOD, $CHECK_JOBS at a time; $(n_checked) results so far"
( while true; do sleep 300; printf '%s\tcheck\t%s\t\t\n' "$(now)" "$(n_checked)" >> "$PD/progress.tsv"; status c3 RUNNING "kernel replay: $(n_checked) results of $NCOMP modules"; done ) & PROG_PID=$!
t=$(( $(left) - FINAL_RESERVE - STOCK_NEED ))
# If holding back the stock tool's time would leave the main pass short, the main pass comes first: it is the
# criterion, and the second look is a comparison.
need=$(( C3_NEED + C3_NEED / 8 + 300 ))
if [ "$t" -lt "$need" ]; then
  t=$need; [ "$t" -le $(( $(left) - FINAL_RESERVE )) ] || t=$(( $(left) - FINAL_RESERVE ))
  [ "$STOCK_NEED" -gt 0 ] && { STOCK_SQUEEZED=1; say "kernel replay: little time; the main pass may use time kept for the stock tool's second look, which gets what is left"; }
fi
[ "$t" -gt 60 ] || t=60
if [ "$C3_FITS" = 0 ]; then
  # It cannot finish. Hours more of it would not change what can be said about criterion C3, so it is given a
  # bounded time: the modules are taken in a fixed shuffled order, so what it reaches is a random sample.
  [ "$t" -gt "$C3_SHORT_CAP" ] && t=$C3_SHORT_CAP
  say "kernel replay: it cannot cover the tree in the time left (about $C3_NEED s needed); running it for $t s only"
fi
C3_RC=$(replay main "$CHECK_JOBS" "$t" "$METHOD_ARGS"); deadline_check
c3_summary
# Modules whose checker was killed, or that a time limit cut off, are tried again with a quarter of the jobs.
pass=1; before=-2
while [ "$C3_FITS" != 0 ] && [ "$(c3_left)" != 0 ] && [ "$(c3_left)" != "$before" ] && [ "$pass" -le 2 ] && [ "$(left)" -gt $(( FINAL_RESERVE + 600 )) ]; do
  before=$(c3_left)                       # a pass that changes nothing is not followed by another
  j=$(( CHECK_JOBS / 4 )); [ "$j" -ge 2 ] || j=2
  say "kernel replay: $before modules without a result that could have one; pass $((pass + 1)) at $j at a time"
  C3_RC=$(replay "again$pass" "$j" "$(( $(left) - FINAL_RESERVE ))" "$METHOD_ARGS"); deadline_check
  c3_summary; pass=$((pass + 1))
done
if [ "$REPLAY_METHOD" = rhv-replay ]; then
  # The stock tool on a random sample (fixed seed: anyone can list the same modules), and on every prefix module
  # with the modules beneath it.
  t=$(( $(left) - FINAL_RESERVE - PREFIX_ALLOW )); [ "$t" -ge 120 ] || t=$(( ($(left) - FINAL_RESERVE) / 2 ))   # the prefix pass keeps its share
  if [ "$STOCK_SAMPLE" -le 0 ]; then C3_STOCK_WHY="no sample was asked for"
  elif [ "$t" -lt 120 ]; then C3_STOCK_WHY="under two minutes were left for it"
  else
    phase_mark "check_stock:N=$NMAX"; status c3 RUNNING "kernel replay: $STOCK_SAMPLE random modules again, by leanchecker"
    C3_STOCK_RC=$(replay stock "$NMAX" "$t" "--method leanchecker --sample $STOCK_SAMPLE"); deadline_check
    phases_end check_stock "$(n_checked)" "$C3_STOCK_RC"
  fi
  t=$(( $(left) - FINAL_RESERVE ))
  if [ "$t" -lt 120 ]; then C3_PREFIX_WHY="under two minutes were left for it"
  else
    phase_mark "check_prefix:N=8"; status c3 RUNNING "kernel replay: the prefix modules again, by leanchecker"
    C3_PREFIX_RC=$(replay prefix "$NMAX" "$t" "--method leanchecker --prefix-modules"); deadline_check
    phases_end check_prefix "$(n_checked)" "$C3_PREFIX_RC"
  fi
  say "stock tool: sample exit status ${C3_STOCK_RC:-not run}, prefix pass exit status ${C3_PREFIX_RC:-not run}"
  c3_summary
fi
kill "$PROG_PID" 2>/dev/null; wait "$PROG_PID" 2>/dev/null; PROG_PID=""
phases_end check "$(n_checked)" "$(plain "$AN/kernel_replay/results.tsv" && awk -F'\t' 'NR>1 && $2!=0' "$AN/kernel_replay/results.tsv" | wc -l)"
say "kernel replay: last exit status $C3_RC, $(n_checked) result lines"; cat "$PD/c3_summary.txt" 2>/dev/null
# The checker's own output for failed modules and for the prefix pass: plain files only, links not followed.
( cd "$AN/kernel_replay" 2>/dev/null && find out -maxdepth 1 -type f -print0 | timeout 600 tar -czf "$PD/c3_out.tar.gz" --null -T - 2>/dev/null ) && gcs_put "$PD/c3_out.tar.gz" "$RES/c3/out.tar.gz"
put_logs; checkpoint "the kernel replay has run"
if [ "$C2_DEEP_WHEN" = deferred ]; then
  t=$(( $(left) - FINAL_RESERVE )); [ "$t" -gt "$C2_TIMEOUT" ] && t=$C2_TIMEOUT
  if [ "$t" -ge 600 ]; then c2_deep "$t" after_replay; else C2_DEEP_WHEN=skipped_for_lack_of_time; fi
fi

# ---------------------------------------------------------------- end: nothing the checks relied on may have changed
phase_mark end_check; status end RUNNING "hashing the compiled files again"
kill_users
lib_manifest > "$PD/end_lib_sha256.txt"; pkgs_manifest > "$PD/end_pkgs.txt"; tc_manifest /opt/lean-tc > "$PD/end_tc.txt"; deadline_check
OLEANS_SAME_END=$(same lib_end "$PD/lib_sha256.txt" "$PD/end_lib_sha256.txt")
LIBS_SAME_END=1; [ "$(same tc_end "$PD/baseline_tc.txt" "$PD/end_tc.txt")" = 1 ] && [ "$(same pkgs_end "$PD/baseline_pkgs.txt" "$PD/end_pkgs.txt")" = 1 ] || LIBS_SAME_END=0
[ "$OLEANS_SAME_END" = 1 ] && [ "$LIBS_SAME_END" = 1 ] || finish FAIL "files the checks rely on changed while the checks ran; their results cannot be used"
[ ! -e "$PD/build_user_seen_after_seal" ] || finish FAIL "a process of the build user appeared after the seal; the checks' results cannot be used"
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
