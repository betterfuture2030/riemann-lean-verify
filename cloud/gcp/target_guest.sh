#!/bin/bash
# target_guest.sh - runs ON the cloud VM as its startup script (as root), in the modes `target` and
# `target-rehearsal`.
#
# What it does: runs this repository's numbered steps, as they are at one commit, for one target profile
# (targets/<name>/target.env) on a fresh machine, the way a person would by hand, and reports what each step
# said. It is the only cloud mode that is not written for the default target.
#   1. Prepares the machine: packages, a data disk, and an unprivileged user, `rhv`, who runs every step. That
#      user cannot reach the metadata server, which hands out the machine's access token, and the token is
#      never put on a command line (every user of a machine can read every process's command line).
#   2. Fetches the archive of this repository's scripts/, targets/ and analysis/ that the controller made from
#      one commit and put in the bucket, and checks its SHA-256. The files are root's: the steps can read them
#      and cannot change them.
#   3. As `rhv`, with RH_TARGET set and a working directory on the data disk: 00 (which installs elan), 01, 02,
#      03, the import graph, reproduce_findings.sh (which compares all of that with the target's records, if it
#      has any), and 04 (the toolchain, the packages, Mathlib's cache, a smoke build). These need the network,
#      so step 04's smoke build, which compiles the profile's smoke modules, runs with the network open.
#   4. Takes the network away from `rhv`: from here on nothing that user runs can open a connection to another
#      machine. Name lookups through the machine's own resolver are not blocked, so this is no connection, not
#      no channel at all; whether a lookup still succeeds is tried and recorded (user_can_look_up_names).
#   5. 05 (the build), 08 (the axiom check, then its --deep walk), 09 --c3 (leanchecker on every module).
#      The compiled files are hashed before 08 and after 09, and the two lists compared. So are the files of
#      the toolchain, after step 04 and after step 09.
#   6. Uploads every log and result file, a table of the steps (exit status, seconds, peak memory) and
#      target_facts.json, then a final status.
# The rehearsal is the same script on a small machine: its build is of the modules the controller names (the
# profile's smoke targets and any it adds), the axiom check is left out, since the root module is not compiled
# (08 --probe is run instead when a probe lemma is given, and its status recorded, not judged), and the replay
# is of a sample. It shows that the phases run; it says nothing about the proof.
#
# What this is not:
#   - The checks of export_guest.sh and kernel_guest.sh (an export, other kernels, Comparator). Those know
#     only the default target.
#   - A sealed run. One user, `rhv`, owns the toolchain (elan installs it in that user's home), the working
#     directory and the replay's results file, and runs the build and the checks. Steps 04, 05 and 08 run
#     whatever the archive and its packages make Lean and Lake run, with that user's rights; code that did so
#     could replace `lean` or `leanchecker`, or write the results step 09 reads, and every exit status from
#     step 04 on would be its word. What stands against that: step 03's audit of the sources against the
#     records, and three things done here that make such a change harder or visible, none of them a proof:
#     every process of the user is ended after step 04, after the build and after each run of a check; 08
#     and 09 are started without the user's login files and with the system's directories first on PATH; and
#     the toolchain's files are hashed by root after step 04 and after step 09. The default target's full run (full_guest.sh) separates the build's
#     user from the checks'; this script does not.
#
# How it ends: it uploads a final status and idles; it never powers the machine off, which would cancel
# Google's deletion at the maximum run time. The local `watch` deletes the VM when it sees the final status.
set -u
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a HOME=/root
PD=/var/pilot; mkdir -p "$PD"; chmod 700 "$PD"
# tee -p: if whatever reads this script's output goes away, tee keeps writing the log and the script is not
# killed by its next line of output.
exec > >(tee -p -a "$PD/pilot.log") 2>&1
T0=$(date +%s)
MDURL=http://metadata.google.internal/computeMetadata/v1/instance
md() { curl -sf --connect-timeout 5 --max-time 20 -H "Metadata-Flavor: Google" "$MDURL/attributes/$1" || echo "$2"; }
BUCKET=$(md pilot-bucket "")
MODE=$(md pilot-mode target)
NMAX=$(md pilot-nmax 16)
DEADLINE_MIN=$(md pilot-deadline-min 300)
RUNTAG=$(md pilot-runtag run)
TOOLS_COMMIT=$(md full-tools-commit unknown)
GUEST_SHA_WANT=$(md full-guest-sha "")
TARGET=$(md target-name "")                     # the profile: targets/<name>/target.env
REPO_OBJECT=$(md target-repo-object "")         # bucket object: the archive of scripts/, targets/ and analysis/
REPO_SHA=$(md target-repo-sha "")               # its SHA-256, as the controller computed it
BUILD_ARGS=$(md target-build-args "")           # arguments of '05_build.sh start'; empty builds everything
REPLAY_ARGS=$(md target-replay-args "--c3")     # arguments of 09_kernel_replay.sh
AXIOMS=$(md target-axioms deep)                 # deep: 08, then 08 --deep; full: 08 only; skip: neither
PROBE=$(md target-probe "")                     # a rehearsal only: "<module> <lemma>" for 08 --probe, or empty
JOBS=$(md target-jobs "")                       # RH_JOBS; empty: what 00_check_prereqs.sh recommends
GUEST_SHA=$(curl -sf --connect-timeout 5 --max-time 30 -H "Metadata-Flavor: Google" "$MDURL/attributes/startup-script" | sha256sum | cut -d' ' -f1)
MACHINE=$(curl -sf --connect-timeout 5 --max-time 20 -H "Metadata-Flavor: Google" "$MDURL/machine-type" | sed 's|.*/||')
DEADLINE=$(( T0 + DEADLINE_MIN * 60 ))
WORK=/mnt/work; RES="results/$RUNTAG"
REPO=$WORK/rhv          # the repository's files at the commit: root's, read by everyone
W=$WORK/w               # RH_WORKDIR: the user's
UT=$WORK/t              # the user's: the timing file of each step
UH=""                   # the user's home: set from the password file when the user is made (s_user)
RESERVE=420             # seconds kept back before the deadline for gathering and uploading

now() { date +%s; }
left() { echo $(( DEADLINE - $(now) )); }
say() { echo "### $(date -u +%FT%TZ) +$(( $(now) - T0 ))s  $*"; }
tok() { curl -sf --connect-timeout 5 --max-time 20 -H "Metadata-Flavor: Google" "$MDURL/service-accounts/default/token" | python3 -c 'import sys,json; print(json.load(sys.stdin)["access_token"])'; }
enc() { python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1],safe=""))' "$1"; }
# The token and the bucket's name go to curl on its standard input (-K -), never on a command line: every user
# of the machine, rhv included, can read every process's command line. printf is the shell's own.
auth() { printf 'header = "Authorization: Bearer %s"\nurl = "%s"\n' "$(tok)" "$1"; }
gcs_get() { auth "https://storage.googleapis.com/storage/v1/b/$BUCKET/o/$(enc "$1")?alt=media" | curl -sf --connect-timeout 20 --speed-limit 1024 --speed-time 120 --retry 4 --retry-delay 3 -K - -o "$2"; }
gcs_put() {
  [ -f "$1" ] && [ ! -L "$1" ] || return 0
  local i
  for i in 1 2 3 4 5; do
    auth "https://storage.googleapis.com/upload/storage/v1/b/$BUCKET/o?uploadType=media&name=$(enc "$2")" \
      | curl -sf --connect-timeout 20 --speed-limit 1024 --speed-time 120 -X POST -H "Content-Type: application/octet-stream" -T "$1" -K - -o /dev/null && return 0
    sleep $(( i * 5 ))
  done
  echo "### UPLOAD FAILED after 5 attempts: $2" >&2; return 1
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
# Every fact is one line "key<TAB>value" in facts.tsv; write_facts turns them into target_facts.json.
fact() { printf '%s\t%s\n' "$1" "$2" >> "$PD/facts.tsv"; say "FACT $1 = $2"; }
write_facts() { # write_facts <state> <message>
  python3 - "$PD/facts.tsv" "$PD/steps.tsv" "$PD/target_facts.json" "$1" "$2" "$T0" <<'PY'
import json, re, sys, time
src, steps, out, state, msg, t0 = sys.argv[1:7]
d = {"what": "facts from one run of cloud/gcp/target_guest.sh; not a verdict. One user ran the build and the checks "
             "and owns the toolchain, so every status from step 04 on is that user's word: see 'Another target' in "
             "cloud/gcp/README.md", "state": state, "message": msg,
     "written_utc": time.strftime("%FT%TZ", time.gmtime()), "elapsed_s": int(time.time()) - int(t0), "facts": {}, "steps": []}
try:
    for line in open(src, errors="replace"):
        k, _, v = line.rstrip("\n").partition("\t")
        d["facts"][k] = {"true": True, "false": False}.get(v, int(v) if re.fullmatch(r"-?[0-9]{1,18}", v) else v)
except OSError:
    pass
try:
    for line in open(steps, errors="replace"):
        f = line.rstrip("\n").split("\t")
        if len(f) == 5:
            d["steps"].append({"step": f[0], "exit_status": int(f[1]), "seconds": int(f[2]),
                               "peak_memory_kb": int(f[3]) if re.fullmatch(r"[0-9]{1,18}", f[3]) else None, "command": f[4]})
except (OSError, ValueError):
    pass
json.dump(d, open(out, "w"), indent=1, sort_keys=True)
PY
}
sync_small() {
  local f
  for f in pilot.log steps.tsv phases.tsv env.txt facts.tsv; do gcs_put "$PD/$f" "$RES/$f"; done
  for f in "$PD"/logs/*; do gcs_put "$f" "$RES/logs/$(basename "$f")"; done
  return 0
}
# The user's files that root reads or copies: a regular file only, never through a link. The user owns the
# directories they are in, so this is a test made a moment before the read, not a guarantee.
rfile() { [ -f "$1" ] && [ ! -L "$1" ]; }
keep() { rfile "$1" && cp -- "$1" "$PD/logs/${2:-$(basename "$1" | sed 's/^\.//')}" 2>/dev/null; return 0; }  # keep <file> [<name in logs/>]
# The steps' own logs and records, from the user's working directory into logs/. Called while the build runs,
# when it ends and from finish, so that every ending has them; only ever from the main script.
gather() {
  local f
  for f in "$W/extract.from" "$W/download/"*.from "$W/.rh-target" "$W/analysis/import_graph_summary.json" "$W"/logs/download.log \
           "$W"/logs/reproduce_*.log "$W"/logs/setup-*.log "$W"/logs/axioms-*.log "$W"/logs/axioms-*.modules.tsv "$W"/logs/build-status.txt; do keep "$f"; done
  for f in "$W"/logs/build-2*.log; do
    rfile "$f" || continue
    timeout 120 gzip -c "$f" > "$PD/build.log.gz.tmp" 2>/dev/null && mv -f "$PD/build.log.gz.tmp" "$PD/logs/$(basename "$f").gz"
  done
  return 0
}
stop_user() { pkill -KILL -u rhv 2>/dev/null; return 0; }
# After the final status nothing is left to do here: the watcher deletes this machine, and Google does at its
# maximum run time if nobody is watching. Nothing of the build is left running meanwhile.
idle_until_deleted() {
  trap '' TERM INT
  while true; do stop_user; gcs_put "$PD/status.json" "$RES/status.json" 2>/dev/null; sleep 60; done
}
finish() { # finish <state> <message>   -- the final status is uploaded LAST: it is the watcher's signal to delete this VM
  trap '' TERM INT
  [ -n "${HB_PID:-}" ] && kill "$HB_PID" 2>/dev/null
  say "FINISH $1: $2"; stop_user; gather
  fact total_seconds "$(( $(now) - T0 ))"
  write_facts "$1" "$2"; sync_small; gcs_put "$PD/target_facts.json" "$RES/target_facts.json"; touch "$PD/FINAL"
  status "$PHASE" "$1" "$2"; idle_until_deleted
}
phase_mark() { PHASE=$1; printf '%s\t%s\n' "$(now)" "$1" >> "$PD/phases.tsv"; say "PHASE $1"; status "$1" RUNNING "${2:-}"; }
# A step of the machine's own setup, as root. A failure ends the run.
t_step() { local name=$1; shift; local s; s=$(now); say "setup: $name"
  if "$@"; then printf '%s\t0\t%s\t\t(setup)\n' "$name" "$(( $(now) - s ))" >> "$PD/steps.tsv"
  else printf '%s\t1\t%s\t\t(setup)\n' "$name" "$(( $(now) - s ))" >> "$PD/steps.tsv"; finish FAIL "setup step failed: $name"; fi; }
# The environment and directory a step of the repository is run in, as the user. Two ways of starting one:
#   as_user        a login shell (the user's own login files are read). Steps 00 to 05.
#   as_user_clean  no login files, an empty environment but for what is named here, and the system's
#                  directories before elan's on PATH. Steps 08 and 09, which run after the archive's code has.
# The single quotes keep $HOME and $PATH for the user's shell.
step_env() { printf 'export PATH="$HOME/.elan/bin:$PATH" LANG=C.UTF-8 RH_TARGET=%s RH_WORKDIR=%s%s; cd %s' "$TARGET" "$W" "${JOBS:+ RH_JOBS=$JOBS}" "$REPO"; }
as_user() { runuser -l rhv -c "ulimit -n 1048576 2>/dev/null; $(step_env) && $1"; }
as_user_clean() {
  # shellcheck disable=SC2086
  runuser -u rhv -- env -i HOME="$UH" LANG=C.UTF-8 PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$UH/.elan/bin" \
    RH_TARGET="$TARGET" RH_WORKDIR="$W" ${JOBS:+RH_JOBS=$JOBS} bash --noprofile --norc -c "ulimit -n 1048576 2>/dev/null; cd $REPO && $1"
}
# run_step <name> <command line> [clean]: one step of the repository, as the user, with what is left before the
# deadline (less RESERVE) as its time limit. Its output goes to logs/<name>.log; its exit status, seconds and
# peak memory to steps.tsv. Returns the exit status (124 or 137 when the time limit ended it, and then, or when
# no time was left to start it, OUT_OF_TIME is 1).
OUT_OF_TIME=0
run_step() {
  local name=$1 cmd=$2 how=${3:-login} t0 rc limit rss
  limit=$(( $(left) - RESERVE ))
  if [ "$limit" -le 60 ]; then
    OUT_OF_TIME=1; say "no time left for step $name"; echo "not started: no time was left before the guest's deadline" > "$PD/logs/$name.log"
    printf '%s\t124\t0\t\t%s\n' "$name" "$cmd" >> "$PD/steps.tsv"; return 124
  fi
  t0=$(now); say "step $name: $cmd"; status "$name" RUNNING "$cmd"
  rm -f "$UT/$name.time"
  if [ "$how" = clean ]; then as_user_clean "exec /usr/bin/time -v -o $UT/$name.time timeout -k 30 $limit $cmd" > "$PD/logs/$name.log" 2>&1; rc=$?
  else as_user "exec /usr/bin/time -v -o $UT/$name.time timeout -k 30 $limit $cmd" > "$PD/logs/$name.log" 2>&1; rc=$?; fi
  case "$rc" in 124|137) [ "$(( $(now) - t0 ))" -ge "$(( limit - 2 ))" ] && OUT_OF_TIME=1 ;; esac
  rss=""; rfile "$UT/$name.time" && rss=$(awk '/Maximum resident set size/ {print $NF}' "$UT/$name.time" 2>/dev/null | tail -n 1)
  printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$rc" "$(( $(now) - t0 ))" "$rss" "$cmd" >> "$PD/steps.tsv"
  say "step $name ended with status $rc after $(( $(now) - t0 )) s; its last lines:"; tail -n 4 "$PD/logs/$name.log" | cut -c1-400
  gcs_put "$PD/logs/$name.log" "$RES/logs/$name.log"; gcs_put "$PD/steps.tsv" "$RES/steps.tsv"
  return "$rc"
}
out_of_time() { [ -e "$PD/DEADLINE" ] || [ "$OUT_OF_TIME" = 1 ]; }
# must <name> <command line>: a step whose failure ends the run.
must() { run_step "$1" "$2" || { local rc=$?
    out_of_time && finish DEADLINE "the guest's time limit ended step $1 (it stops a step $RESERVE s before its deadline)"
    finish FAIL "step $1 ended with status $rc; see logs/$1.log"; }; }

[ -n "$BUCKET" ] || { echo "no bucket in metadata; idling until deleted"; idle_until_deleted; }
# A startup script runs at every boot. A second boot of this machine must not start the run again.
if [ -e "$PD/STARTED" ]; then
  # A restart after the run's final state must not replace that state: idle uploads the status again as it is.
  grep -q -E '"state": "(DONE|FAIL|DEADLINE|BUILD_FAILED)"' "$PD/status.json" 2>/dev/null || status reboot FAIL "the VM was restarted; the run does not start twice"
  idle_until_deleted
fi
date -u +%FT%TZ > "$PD/STARTED"
mkdir -p "$PD/logs"; : > "$PD/facts.tsv"; : > "$PD/steps.tsv"
trap 'finish FAIL "unexpected signal"' TERM INT
# The guest's own deadline: whatever the user is running then is ended, and the step that was running reports
# it. A watchdog: if there is still no final state ten minutes later, it reports that itself.
( sleep $(( DEADLINE_MIN * 60 )); touch "$PD/DEADLINE"; stop_user; sleep 600; [ -e "$PD/FINAL" ] && exit 0
  echo "### watchdog: no final state ten minutes after the deadline" >> "$PD/pilot.log"; sync_small
  status watchdog DEADLINE "the script had not finished ten minutes after its deadline; see pilot.log"
  while true; do stop_user; sleep 30; done ) &
# A heartbeat every minute, for the watcher; the small files every five. If the main script is gone without a
# final state, it says so.
( n=0; while kill -0 $$ 2>/dev/null; do date +%s > "$PD/heartbeat"; gcs_put "$PD/heartbeat" "$RES/heartbeat" 2>/dev/null; n=$((n + 1)); [ $(( n % 5 )) = 0 ] && sync_small; sleep 60; done
  [ -e "$PD/FINAL" ] && exit 0
  echo "### the main script is gone without a final state" >> "$PD/pilot.log"; sync_small
  status gone FAIL "the main script ended without a final state; see pilot.log"
  while true; do stop_user; sleep 30; done ) & HB_PID=$!

# ---------------------------------------------------------------- the machine
phase_mark setup "preparing the machine"
{ echo "mode=$MODE target=$TARGET machine=$MACHINE nmax=$NMAX deadline_min=$DEADLINE_MIN tools_commit=$TOOLS_COMMIT guest_sha256=$GUEST_SHA"; nproc; lscpu | grep -E "Model name|Thread|Core|Socket"; uname -r; free -g | head -2; head -2 /etc/os-release; } > "$PD/env.txt" 2>&1
case "$TARGET" in ''|-*|*[!abcdefghijklmnopqrstuvwxyz0123456789-]*) finish FAIL "metadata names no target, or one that is not a directory name of targets/" ;; esac
case "$REPO_SHA" in *[!0-9a-f]*|'') finish FAIL "metadata gives no SHA-256 for the archive of the repository's files" ;; esac
[ -n "$REPO_OBJECT" ] || finish FAIL "metadata names no archive of the repository's files"
# These are put on a command line that a shell reads: only the characters their values need.
case "$BUILD_ARGS" in *[!A-Za-z0-9_.+\ -]*) finish FAIL "target-build-args has a character other than letters, digits, '_', '.', '+', '-' and space" ;; esac
case "$REPLAY_ARGS" in *[!A-Za-z0-9\ -]*) finish FAIL "target-replay-args has a character other than letters, digits, '-' and space" ;; esac
case "$PROBE" in *[!A-Za-z0-9_.\ ]*) finish FAIL "target-probe has a character other than letters, digits, '_', '.' and space" ;; esac
PROBE_MODULE=${PROBE%% *}; PROBE_LEMMA=${PROBE##* }
[ -z "$PROBE" ] || { [ -n "$PROBE_LEMMA" ] && [ "$PROBE" = "$PROBE_MODULE $PROBE_LEMMA" ]; } || finish FAIL "target-probe is not '<module> <lemma>'"
case "$JOBS" in *[!0-9]*) finish FAIL "target-jobs is not a number" ;; esac
case "$AXIOMS" in deep|full|skip) ;; *) finish FAIL "target-axioms must be deep, full or skip" ;; esac
[ -z "$GUEST_SHA_WANT" ] || [ "$GUEST_SHA" = "$GUEST_SHA_WANT" ] || finish FAIL "this script is not the one the controller sent"
fact guest_script_is_the_one_sent true; fact tools_commit "$TOOLS_COMMIT"; fact mode "$MODE"; fact target "$TARGET"
fact machine_type "$MACHINE"; fact cpus "$(nproc)"; fact memory_kb "$(awk '/MemTotal/ {print $2}' /proc/meminfo)"

s_sysctl() { sysctl -w fs.file-max=50000000 vm.max_map_count=1048576 fs.nr_open=2097152 >/dev/null && printf 'rhv soft nofile 1048576\nrhv hard nofile 1048576\n' > /etc/security/limits.d/rhv.conf; }
# The image's own first-boot jobs can hold the package lock for a while: wait for it.
s_pkgs() { apt-get -o DPkg::Lock::Timeout=300 update -qq && apt-get -o DPkg::Lock::Timeout=300 install -y -qq --no-install-recommends git curl xfsprogs iptables ca-certificates time procps python3 >/dev/null; }
s_disk() { mkdir -p "$WORK"; [ -e /dev/disk/by-id/google-pilot-data ] || return 1; mkfs.xfs -q -f /dev/disk/by-id/google-pilot-data && mount -o noatime /dev/disk/by-id/google-pilot-data "$WORK"; }
s_user() {
  useradd -m -s /bin/bash rhv || return 1
  UH=$(getent passwd rhv | cut -d: -f6); case "$UH" in /home/*) ;; *) echo "the user's home is '$UH'"; return 1 ;; esac
  printf 'rhv\n' >> /etc/cron.deny
  mkdir -p "$W" "$UT" && chmod 755 "$WORK" && chown rhv:rhv "$W" "$UT" || return 1
  # The user must never reach the metadata server: it would hand out this machine's credentials.
  iptables -I OUTPUT 1 -m owner --uid-owner rhv -d 169.254.169.254 -j REJECT || return 1
  if runuser -u rhv -- curl -s -m 4 -o /dev/null -H "Metadata-Flavor: Google" http://169.254.169.254/computeMetadata/v1/instance/id; then echo "the user rhv can still reach the metadata server"; return 1; fi
}
# This repository's files at the commit the controller archived: fetched and unpacked by root, so that the user,
# and whatever the archive under test makes the user run, can read them and cannot change them.
s_repo() {
  gcs_get "$REPO_OBJECT" "$WORK/rhv.tar.gz" || { echo "could not fetch $REPO_OBJECT from the bucket"; return 1; }
  local got; got=$(sha256sum "$WORK/rhv.tar.gz" | cut -d' ' -f1)
  [ "$got" = "$REPO_SHA" ] || { echo "the archive of the repository's files has SHA-256 $got, not the $REPO_SHA the controller gave"; return 1; }
  mkdir -p "$REPO" && tar -xzf "$WORK/rhv.tar.gz" -C "$REPO" --strip-components=1 --no-same-owner && rm -f "$WORK/rhv.tar.gz" || return 1
  chown -R root:root "$REPO" && chmod -R a+rX,go-w "$REPO" || return 1
  [ -f "$REPO/scripts/lib.sh" ] && [ -f "$REPO/targets/$TARGET/target.env" ] || { echo "the archive has no scripts/lib.sh or no targets/$TARGET/target.env"; return 1; }
  [ ! -e "$REPO/config.env" ] || { echo "the archive holds a config.env"; return 1; }
}
# From here on the user can open no connection to another machine. The machine's own resolver still answers it.
s_lockdown() {
  iptables -A OUTPUT -m owner --uid-owner rhv ! -o lo -j REJECT || return 1
  if runuser -u rhv -- curl -s -m 4 -o /dev/null https://storage.googleapis.com/; then echo "the user rhv can still open a connection to another machine"; return 1; fi
}
# Whether the user can still have a name looked up, by either way of asking the machine's resolver.
user_can_look_up_names() {
  runuser -u rhv -- timeout 15 getent hosts storage.googleapis.com >/dev/null 2>&1 && return 0
  command -v resolvectl >/dev/null 2>&1 && runuser -u rhv -- timeout 15 resolvectl query storage.googleapis.com >/dev/null 2>&1
}
# Every file of the user's toolchains and of elan's own programs, read by root: for each regular file its
# SHA-256 and mode, for a link its target, and anything else by its kind. No link is followed. Taken while no
# process of the user runs.
toolchain_list() {
  timeout 900 python3 - "$UH/.elan" > "$1" 2>/dev/null <<'PY'
import hashlib, os, stat, sys
top, rows = sys.argv[1], []
for sub in ("toolchains", "bin"):
    for dirpath, dirs, files in os.walk(os.path.join(top, sub)):
        for n in dirs + files:
            p = os.path.join(dirpath, n)
            st, rel = os.lstat(p), ascii(os.path.relpath(p, top))
            if stat.S_ISREG(st.st_mode):
                h = hashlib.sha256()
                with open(p, "rb") as fh:
                    for block in iter(lambda: fh.read(1 << 20), b""):
                        h.update(block)
                rows.append("%s  %o  %s" % (h.hexdigest(), stat.S_IMODE(st.st_mode), rel))
            elif stat.S_ISLNK(st.st_mode):
                rows.append("link  %s -> %s" % (rel, ascii(os.readlink(p))))
            elif not stat.S_ISDIR(st.st_mode):
                rows.append("other  %o  %s" % (st.st_mode, rel))
sys.stdout.write("".join(r + "\n" for r in sorted(rows)))
PY
}
t_step sysctl s_sysctl
t_step packages s_pkgs
t_step disk s_disk
t_step user s_user
t_step repository s_repo
fact repository_archive_sha256 "$REPO_SHA"
sync_small

# ---------------------------------------------------------------- the steps that need the network
phase_mark source "steps 00 to 03"
must 00_prereqs "bash scripts/00_check_prereqs.sh --install-elan"
must 01_fetch "bash scripts/01_fetch.sh"
must 01_check "bash scripts/01_fetch.sh --check-only"
must 02_inspect "bash scripts/02_inspect_and_extract.sh"
must 03_audit "bash scripts/03_audit_source.sh"
must import_graph "python3 analysis/import_graph.py"
must reproduce "bash scripts/reproduce_findings.sh"
PROJ=$(as_user "bash -c '. scripts/lib.sh && printf %s \"\$RH_PROJ\"'" 2>/dev/null | tail -n 1)
case "$PROJ" in "$W"/extract/*) ;; *) finish FAIL "could not learn the project's directory from scripts/lib.sh (got '$PROJ')" ;; esac
[ -d "$PROJ" ] && [ ! -L "$PROJ" ] || finish FAIL "the project's directory $PROJ is not there after step 02"
fact lean_files_in_the_project "$(find "$PROJ" -name .lake -prune -o -type f -name '*.lean' -print | wc -l)"
fact has_recorded_values "$( [ -f "$REPO/targets/$TARGET/records/expected.json" ] && echo true || echo false )"

phase_mark toolchain "step 04: the toolchain, the packages, Mathlib's cache, a smoke build"
must 04_setup "bash scripts/04_setup_toolchain.sh"
fact lean_version "$(as_user "cd $PROJ && timeout 120 lean --version" 2>/dev/null | head -n 1 | LC_ALL=C tr -c '[:print:]\n' '?' | cut -c1-200)"
rfile "$PROJ/lean-toolchain" && fact toolchain_line "$(head -n 1 "$PROJ/lean-toolchain" | LC_ALL=C tr -d '\r\n' | LC_ALL=C tr -c '[:print:]' '?' | cut -c1-100)"
stop_user
t_step lockdown s_lockdown
fact user_cannot_connect_to_another_machine true
fact user_can_look_up_names "$(user_can_look_up_names && echo true || echo false)"
toolchain_list "$PD/toolchain_after_04.sha256"
fact toolchain_files_listed "$(wc -l < "$PD/toolchain_after_04.sha256" | tr -d ' ')"
fact toolchain_files_list_sha256 "$(sha256sum "$PD/toolchain_after_04.sha256" | cut -d' ' -f1)"
gzip -c "$PD/toolchain_after_04.sha256" > "$PD/logs/toolchain_files_after_step_04.sha256.gz"

# ---------------------------------------------------------------- the build
phase_mark build "step 05"
tb=$(now)
must 05_start "bash scripts/05_build.sh start $BUILD_ARGS"
PHASE=build
BS=$W/logs/build-status.txt; n=0; brc=""; idle=0
build_ended() { local last; last=$(rfile "$BS" && timeout 10 tail -n 1 "$BS" 2>/dev/null); case "$last" in END\ *rc=*) brc=${last##*rc=}; return 0 ;; esac; return 1; }
while ! build_ended; do
  if [ -e "$PD/DEADLINE" ] || [ "$(left)" -le "$RESERVE" ]; then
    say "the deadline is near: stopping the build"; as_user "timeout 120 bash scripts/05_build.sh stop" > "$PD/logs/05_stop.log" 2>&1
    as_user "timeout 300 bash scripts/06_progress.sh" > "$PD/logs/06_progress.log" 2>&1; finish DEADLINE "the guest's deadline was reached during the build; see logs/06_progress.log"
  fi
  # Not running by the step's own account AND by root's: three times in a row before it is believed, since one
  # failed look (a session that could not be opened, a fork that failed) must not end a build that is running.
  if ! as_user "timeout 120 bash scripts/05_build.sh status" >/dev/null 2>&1 && ! pgrep -u rhv -x lake >/dev/null 2>&1; then
    idle=$((idle + 1)); sleep 5; build_ended && break
    [ "$idle" -lt 3 ] || finish FAIL "the build is not running (three looks) and its status file has no END line; see logs/05_start.log and the build log"
  else idle=0; fi
  n=$((n + 1))
  if [ $(( n % 10 )) = 0 ]; then
    as_user "timeout 300 bash scripts/06_progress.sh" > "$PD/logs/06_progress.log" 2>&1
    status build RUNNING "$(grep -m 1 '^compiled:' "$PD/logs/06_progress.log" | cut -c1-100)"
    gather; sync_small     # the build log so far reaches the bucket now, not at the heartbeat's next turn
  fi
  sleep 30
done
PHASE=build
case "$brc" in ''|*[!0-9]*) brc=1 ;; esac
printf '%s\t%s\t%s\t\t%s\n' 05_build "$brc" "$(( $(now) - tb ))" "lake build $BUILD_ARGS (started by 05_build.sh)" >> "$PD/steps.tsv"
fact build_exit_status "$brc"; fact build_seconds "$(( $(now) - tb ))"
as_user "timeout 300 bash scripts/06_progress.sh" > "$PD/logs/06_progress.log" 2>&1
stop_user                  # the build has ended: nothing of the user's is left running into the checks
gather
fact compiled_olean_files "$(find "$PROJ/.lake/build/lib" -type f -name '*.olean' 2>/dev/null | wc -l)"
fact build_directory_bytes "$(du -sb "$PROJ/.lake/build" 2>/dev/null | cut -f1)"
sync_small
[ "$brc" = 0 ] || finish BUILD_FAILED "lake build ended with status $brc; see logs/06_progress.log and the build log"

# ---------------------------------------------------------------- the checks
# The compiled files of the project, hashed before the checks and again after them.
olean_list() { ( cd "$PROJ/.lake/build/lib" 2>/dev/null && find . -type f \( -name '*.olean' -o -name '*.olean.*' \) -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum ) > "$1" 2>/dev/null; }
olean_list "$PD/logs/compiled_before.sha256"
fact compiled_files_list_sha256 "$(sha256sum "$PD/logs/compiled_before.sha256" | cut -d' ' -f1)"
# Only step 09 makes its results directory. One that is there already was made by something else, and what
# step 09 then reported could not be told from it.
[ ! -e "$W/analysis/kernel_replay" ] && [ ! -L "$W/analysis/kernel_replay" ] || finish FAIL "analysis/kernel_replay is there before step 09 was run: only step 09 makes it"
a_rc=skipped; d_rc=skipped; p_rc=skipped; pl_rc=skipped
if [ "$AXIOMS" != skip ]; then
  phase_mark axioms "step 08"
  run_step 08_axioms "bash scripts/08_check_axioms.sh" clean; a_rc=$?
  keep "$W/logs/axioms-full-latest.json" axioms-full.json
  stop_user
  if [ "$AXIOMS" = deep ]; then
    run_step 08_axioms_deep "bash scripts/08_check_axioms.sh --deep" clean; d_rc=$?
    # 08 writes the summary of either run under one name: this copy is the --deep run's.
    keep "$W/logs/axioms-full-latest.json" axioms-full-deep.json
  fi
elif [ "$MODE" = target-rehearsal ] && [ -n "$PROBE" ]; then
  # A rehearsal cannot run 08 (the root module is not compiled). Its --probe runs the same check file on one
  # compiled lemma, which shows whether that file elaborates on this toolchain. The status is recorded, not
  # judged: the lemma is not the theorem, and the probe says so.
  phase_mark probe "step 08 --probe on $PROBE_MODULE, lemma $PROBE_LEMMA"
  run_step 08_probe "env TGT_PROBE_MODULE=$PROBE_MODULE TGT_PROBE_THEOREM=$PROBE_LEMMA bash scripts/08_check_axioms.sh --probe" clean; p_rc=$?
  # 08 ends with status 1 for a lemma that is not the theorem, and also when lean could not read the check file:
  # lean's own status, from 08's summary, tells the two apart.
  keep "$W/logs/axioms-probe-latest.json" axioms-probe.json
  pl_rc=$(python3 -c 'import json,sys; print(int(json.load(open(sys.argv[1]))["lean_exit_status"]))' "$PD/logs/axioms-probe.json" 2>/dev/null) || pl_rc=unknown
fi
fact axioms_exit_status "$a_rc"; fact axioms_deep_exit_status "$d_rc"; fact axioms_probe_exit_status "$p_rc"; fact axioms_probe_lean_exit_status "$pl_rc"
stop_user
# Step 08 ran the archive's code as well (lean runs the initialize declarations of what it imports): look again,
# now that nothing of the user's is running.
[ ! -e "$W/analysis/kernel_replay" ] && [ ! -L "$W/analysis/kernel_replay" ] || finish FAIL "analysis/kernel_replay is there before step 09 was run: only step 09 makes it"
phase_mark replay "step 09 $REPLAY_ARGS"
r_rc=notrun; tries=0; max_tries=1
# Over everything (--c3), status 3 means nothing was rejected and the run is not complete yet: 09 says to run
# it again. For a sample there is no "complete", so it is run once.
[ "$MODE" = target ] && max_tries=3
while { [ "$tries" = 0 ] || [ "$r_rc" = 3 ]; } && [ "$tries" -lt "$max_tries" ] && ! out_of_time; do
  stop_user
  tries=$((tries + 1)); run_step "09_replay_$tries" "bash scripts/09_kernel_replay.sh $REPLAY_ARGS" clean; r_rc=$?
done
fact replay_exit_status "$r_rc"; fact replay_runs "$tries"
as_user_clean "timeout 600 bash scripts/09_kernel_replay.sh --summary" > "$PD/logs/09_summary.log" 2>&1; fact replay_summary_exit_status "$?"
stop_user
keep "$W/analysis/kernel_replay/summary.json" replay_summary.json
keep "$W/analysis/kernel_replay/results.tsv" replay_results.tsv
# What the checker said about each module that did not pass (09 keeps one file a module in out/): without them a
# rejection could be read only by building again. Read as the user, who can read no more than its own files.
runuser -u rhv -- timeout 120 tar -czf - -C "$W/analysis/kernel_replay" out > "$PD/replay_out.tgz.tmp" 2>/dev/null && mv -f "$PD/replay_out.tgz.tmp" "$PD/logs/replay_out.tar.gz"
stop_user
[ -f "$PD/logs/replay_results.tsv" ] && gzip -f "$PD/logs/replay_results.tsv"
np=$(python3 -c 'import json,sys; print(int(json.load(open(sys.argv[1]))["passed_by_leanchecker"]))' "$PD/logs/replay_summary.json" 2>/dev/null) || np=0
fact replay_modules_passed_by_leanchecker "$np"
olean_list "$PD/logs/compiled_after.sha256"
if cmp -s "$PD/logs/compiled_before.sha256" "$PD/logs/compiled_after.sha256" && [ -s "$PD/logs/compiled_before.sha256" ]; then same=true; else same=false; fi
fact compiled_files_unchanged_during_the_checks "$same"
toolchain_list "$PD/toolchain_at_end.sha256"
if cmp -s "$PD/toolchain_after_04.sha256" "$PD/toolchain_at_end.sha256" && [ -s "$PD/toolchain_after_04.sha256" ]; then tsame=true; else
  tsame=false; diff "$PD/toolchain_after_04.sha256" "$PD/toolchain_at_end.sha256" 2>&1 | head -n 200 > "$PD/logs/toolchain_files_changed.diff"; fi
fact toolchain_files_unchanged_from_step_04_to_the_end "$tsame"

# ---------------------------------------------------------------- how it ends
phase_mark gather "gathering the result files"
df -B1 "$WORK" | tail -n 1 > "$PD/logs/disk.txt" 2>&1
out_of_time && finish DEADLINE "the guest's time limit was reached during the checks (08: $a_rc, 08 --deep: $d_rc, 09: $r_rc)"
if [ "$MODE" = target-rehearsal ]; then
  [ "$r_rc" = 0 ] || finish FAIL "rehearsal: the replay ended with status $r_rc; see logs/09_replay_$tries.log and, for what the checker said, logs/replay_out.tar.gz"
  [ "$np" -ge 1 ] || finish FAIL "rehearsal: the replay ended with status 0 but leanchecker passed no module; see logs/09_replay_$tries.log and, for what the checker said, logs/replay_out.tar.gz"
  finish DONE "rehearsal: the phases ran (build status $brc, 08 --probe: $p_rc with lean's own status $pl_rc, $np sampled modules replayed and passed, compiled files unchanged: $same, toolchain unchanged: $tsame); this says nothing about the proof"
fi
[ "$a_rc" = 0 ] || [ "$AXIOMS" = skip ] || finish FAIL "the axiom check (08) ended with status $a_rc; see logs/08_axioms.log"
[ "$d_rc" = 0 ] || [ "$d_rc" = skipped ] || finish FAIL "the --deep axiom walk (08) ended with status $d_rc; see logs/08_axioms_deep.log"
[ "$r_rc" = 0 ] || finish FAIL "the kernel replay (09) ended with status $r_rc; see logs/09_summary.log and, for what the checker said, logs/replay_out.tar.gz"
[ "$same" = true ] || finish FAIL "the compiled files changed between the build and the end of the checks"
[ "$tsame" = true ] || finish FAIL "the toolchain's files changed between step 04 and the end of the checks; see logs/toolchain_files_changed.diff"
finish DONE "every step ended with status 0: build, axiom check${AXIOMS:+ ($AXIOMS)} and kernel replay ($REPLAY_ARGS). One user ran the build and the checks, so this is that user's word (cloud/gcp/README.md): read the logs for what each step says"
