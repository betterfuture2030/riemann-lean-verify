#!/bin/bash
# Local controller for the calibration pilot and for the full run. Run it with bash on your own machine (bash 3.2 or
# later).
#
#   stage              create the private bucket and upload inputs (storage only; no compute cost)
#   launch <mode>      Creates exactly one VM, which Google deletes at a fixed maximum run time. Modes:
#                        rehearsal        the pilot with short windows: about 17 minutes
#                        pilot            the calibration pilot: about 3 hours (pilot_guest.sh)
#                        full-rehearsal   the phases of the full run on a seven-minute build: about 20 minutes
#                        full             the whole tree: build, axiom checks, kernel replay (full_guest.sh;
#                                         docs/cloud-notes.md sections 8 and 9). An estimated 26 hours;
#                                         with GCP_SECOND_REPLAY=rhv-replay, a second replay of every module
#                                         by another program, about 6 hours more.
#                        export-check     on the compiled files a finished Spot run left in the bucket
#                                         (GCP_EXPORT_FROM=its run tag): export the proof, compare the
#                                         export with the published one, run independent kernels on it
#                                         (export_guest.sh). About 3 hours, at most 5; on demand.
#                        kernel-check     on the exported proof (GCP_KERNEL_FROM=the run tag of a finished
#                                         export-check): a second independent kernel, `lake comparator` in
#                                         its sandbox with Lean's own kernel, and Lean's paranoid kernel
#                                         (kernel_guest.sh). About 12 hours, at most 20; on demand.
#                        kernel-check-rehearsal  the same script on small stand-ins, on a 4-vCPU machine: about
#                                         25 minutes. It also fetches the proof's export, checks its hash and
#                                         keeps it in the bucket.
#                        target           the numbered steps 00 to 09 for ANOTHER target (GCP_TARGET=<name>, a
#                                         directory of targets/), as they are at the current commit, on a
#                                         16-vCPU machine: fetch, inspect, audit, toolchain, build, axiom
#                                         check, kernel replay (target_guest.sh). On demand; Google deletes
#                                         the VM at 6 hours (GCP_TARGET_MAX_HOURS).
#                        target-rehearsal the same script on an 8-vCPU machine, building only the profile's
#                                         smoke targets (and any modules GCP_TARGET_REHEARSAL_ALSO names),
#                                         running 08 --probe if there is a probe lemma, and replaying a
#                                         sample. The guest stops by 60 minutes. It shows that the phases
#                                         run and says nothing about the proof.
#                        full-spot        the full run on Spot machines, about half the price, as a chain of
#                                         attempts that survives Google taking the machine back (below)
#                        full-spot-rehearsal  the same chain on full-rehearsal's small tree, ending attempts on
#                                         purpose at the points GCP_SPOT_REHEARSAL_CUTS names
#   watch              follow the run through the bucket, then delete the VM and its disks
#   teardown           delete every VM and disk in the project, verify that nothing billable is left, close the ledger
#   abandon            end a paused Spot run: forget its state (its checkpoints stay in the bucket until you delete them)
#   ledger             show recorded machine-time and estimated spend against the cap
#
# A Spot run is a chain of attempts. Each attempt is a fresh Spot VM that Google deletes, with its disks, at the
# attempt's own maximum run time or whenever it takes the machine back; nothing is kept between attempts but the
# checkpoints the guest uploads to the bucket (ckpt/RUNTAG/), so between attempts nothing in Compute Engine bills.
# `watch` accounts for each attempt that ends and starts the next one, re-checking the cap every time; it pauses
# the run (exit status 3, nothing running, nothing lost) when the cap, the give-up time, the attempt limit or a lack
# of progress says so, or when the guest paused an attempt for a reason another attempt would meet again. Run
# `watch` again at any time to continue: it picks up from the state file, the ledger, the Compute API and the bucket.
# When a full-spot-rehearsal finishes with one of its configured cuts not done as configured, `watch` says so and
# exits with status 4 (the list is in results RUNTAG/cuts.txt): the rehearsal did not test what it was meant to.
# The four modes above do not use any of this.
#
# Safety design. (1) `launch` refuses to start a VM whose worst case would take recorded spend past GCP_SPEND_CAP_USD,
# and records the run in the ledger BEFORE creating anything. (2) The VM is created with --max-run-duration and
# --instance-termination-action=DELETE, and the guest never powers itself off, so that deletion stays armed even if
# this machine is asleep or offline. (The kernel-check modes are the exception: their guest powers the machine off
# twenty minutes after its final state if nobody has deleted it. That ends the charge for the machine but cancels
# Google's deletion, so the stopped VM's disks bill, about 1.4 USD a day, until `watch` or `teardown` is run.) (3) `watch` deletes the VM as soon as the guest reports a final state, and
# also if the guest never reports at all or falls silent for half an hour. Interrupting `watch` (Ctrl-C, a closed
# terminal) tears a pilot down at once; for a full run it only stops watching, because a day of work would be lost,
# and the VM stays protected by its maximum run time. `teardown` is then a separate, deliberate command.
# (4) `teardown` closes the ledger only after the Compute API has positively confirmed that no VM or disk remains.
#
# The cap decides whether a full run may start: its worst case is 42 hours of machine time, about 84 USD at the
# ledger's rate, so `launch full` is refused until GCP_SPEND_CAP_USD in config.env allows for that on top of what the
# ledger already records. Raising the cap is how you say go.
#
# Use a project dedicated to this work: `teardown` deletes every instance and disk in GCP_PROJECT.
set -u
. "$(cd "$(dirname "$0")" && pwd)/../../scripts/lib.sh"
# The cloud modes know only the default target: their guest scripts, ledger and spend cap are its own. The two
# target modes are the exception, and they are told their target with GCP_TARGET, not RH_TARGET: this controller
# itself always runs as the default target, whose working directory holds the one ledger.
[ "$RH_TARGET_IS_DEFAULT" = 1 ] || die "the cloud scripts know only the default target, alpoge-rh, and RH_TARGET is '$RH_TARGET' (see targets/README.md). To run another target's steps on a cloud machine, leave RH_TARGET unset and name the target with GCP_TARGET: bash $0 launch target"
[ -n "${GCP_PROJECT:-}" ] || die "set GCP_PROJECT in config.env (see config.example.env)"
[ -n "${GCP_BUCKET:-}" ]  || die "set GCP_BUCKET in config.env (see config.example.env)"
NP=$GCP_PROJECT
BUCKET=$GCP_BUCKET
REGION=${GCP_REGION:-us-central1}
ZONES=${GCP_ZONES:-us-central1-a us-central1-b us-central1-c us-central1-f}
MT=${GCP_MACHINE_TYPE:-n4d-highmem-32}
RATE=${GCP_RATE_USD_PER_HOUR:-2.00}      # machine plus disks, rounded up; used for the ledger and the cap check
CAP_USD=${GCP_SPEND_CAP_USD:-40}
# The kernel replay of a full run is leanchecker on every module (criterion C3). GCP_SECOND_REPLAY=rhv-replay
# adds a second replay of every module by the program in scripts/verify/replay, about six hours more, which is
# not part of the criterion. See docs/performance-notes.md, section 10.
SECOND_REPLAY=${GCP_SECOND_REPLAY:-}
case "$SECOND_REPLAY" in ''|rhv-replay) ;; *) die "GCP_SECOND_REPLAY must be empty or rhv-replay" ;; esac
HERE=$REPO_ROOT/cloud/gcp
SELF="$HERE/pilot_local.sh"
OUT=$RH_AN/pilot
LEDGER=$RH_AN/pilot_ledger.tsv
STATE=$RH_AN/pilot_state.env
TARBALL=$RH_DL/lean.tar.gz
TARGETS_JSON=$RECORDS/source/pilot_targets.json      # the build targets and probe modules used for the recorded pilot
mkdir -p "$OUT"
[ -e "$LEDGER" ] || printf 'runtag\tmode\tmachine\tusd_per_hour\tzone\tcreated_epoch\tended_epoch\tseconds\tusd\n' > "$LEDGER"
G="gcloud --project=$NP --quiet"

spent()    { awk -F'\t' 'NR>1 && $9!="" {s+=$9} END{printf "%.2f", s+0}' "$LEDGER"; }
open_run() { awk -F'\t' 'NR>1 && $7=="" {print $1}' "$LEDGER" | tail -1; }
close_run() { # close_run <runtag> <end_epoch> [zero] [max seconds]   -- fill in end time, seconds and cost for an open ledger row
  python3 -I - "$LEDGER" "$1" "$2" "${3:-}" "${4:-0}" "$$" <<'PY'
import fcntl, os, stat, sys
p, tag, end, zero, cap = os.path.realpath(sys.argv[1]), sys.argv[2], int(sys.argv[3]), sys.argv[4], int(sys.argv[5] or 0)
rows = [l.rstrip('\n').split('\t') for l in open(p)]
for r in rows[1:]:
    while len(r) < 9: r.append('')
    if r[0] == tag and r[6] == '':
        secs = 0 if zero else max(0, end - int(r[5]))
        if cap: secs = min(secs, cap)      # Google deletes the VM at its maximum run time, however late teardown is
        r[6] = str(end); r[7] = str(secs); r[8] = '%.2f' % (float(r[3]) * secs / 3600)
# Written to a new file and swapped in whole, so that an interruption or a power cut leaves the old ledger or the
# new one, never an empty or half-written one (which would make recorded spend look smaller than it is). A ledger
# that is a symbolic link is rewritten at its target, and the new file keeps the old one's permissions.
def sync(fd):    # to the disk itself: on macOS a plain fsync leaves the data in the drive's cache
    try: fcntl.fcntl(fd, fcntl.F_FULLFSYNC)
    except (AttributeError, OSError): os.fsync(fd)
tmp = os.path.join(os.path.dirname(p) or '.', 'ledger.tmp.' + sys.argv[6])
with open(tmp, 'w') as f:
    f.write('\n'.join('\t'.join(r) for r in rows) + '\n'); f.flush(); sync(f.fileno())
os.chmod(tmp, stat.S_IMODE(os.stat(p).st_mode))
os.replace(tmp, p)
d = os.open(os.path.dirname(p) or '.', os.O_RDONLY)
try: sync(d)
finally: os.close(d)
PY
}
# vm_state <name> <zone>: prints the instance status, GONE if the API positively reports it absent, UNKNOWN if the call failed.
vm_state() {
  local out
  if out=$($G compute instances list --filter="name=$1" --zones="$2" --format='value(status)' 2>>"$OUT/api_errors.log"); then echo "${out:-GONE}"; else echo UNKNOWN; fi
}

# ---------------------------------------------------------------------------------------------------------------
# Spot runs (launch full-spot | full-spot-rehearsal). Everything from here to the command list is used only by
# those two modes; the four older modes do not call any of it.
#
# Money rules, in order: (1) every attempt has an open ledger row before its VM is created, and at most one row is
# open; (2) an attempt is over only when the Compute API has positively confirmed that no instance and no disk is
# left in the project (both listings succeed and are empty); until then the row stays open and nothing new starts;
# (3) each attempt is sized so that, even if it runs to its maximum run time and the ledger adds its two minutes,
# recorded spend plus the worst cross-region transfer stays under the cap less GCP_SPOT_RESERVE_USD; (4) Google
# deletes every attempt's VM and disks at its maximum run time whatever this machine does. A failed or ambiguous
# API call stops the script with the row open and says what to run; it never starts anything. (5) Only one Spot
# command runs at a time: each holds a lock the kernel keeps on the file $STATE.lock (spot_lock), which ends with
# the command however it ends, so there is never a stale lock. (6) The ledger is never rewritten in place, and a ledger found holding fewer
# rows or less spend than the run last saw stops every start.
SPOT_RATE=${GCP_SPOT_RATE_USD_PER_HOUR:-1.20}       # ledger and cap rate for a Spot attempt: machine, disks, address
SPOT_GIVEUP_H=${GCP_SPOT_GIVEUP_HOURS:-120}         # no attempt starts later than this after the first launch
SPOT_MAX_ATTEMPTS=${GCP_SPOT_MAX_ATTEMPTS:-24}      # the run pauses when this many attempts have been started
SPOT_RESERVE=${GCP_SPOT_RESERVE_USD:-1.00}          # kept back from the cap for the parts' storage, not in the ledger
XREGION=${GCP_XREGION_USD_PER_GIB:-0.02}            # moving a GiB between the bucket's region and another region
PARTS_MAX_GIB=${GCP_SPOT_PARTS_MAX_GIB:-60}         # bound on all parts together, for the worst case out of region
MIRROR_DIR=${GCP_RESULTS_MIRROR_DIR:-}              # optional local folder that receives a copy of the small results
SPOT_KEYS="RUNTAG NAME ZONE MODE CREATED MAXRUN RATE SPOT ATTEMPT ACCOUNTED STARTING FIRST_CREATED GIVEUP_EPOCH TCOMMIT BUCKET_REGION STATE_SHA MANIFEST_SHA PARTS_BYTES PROGRESS NOPROGRESS RESULTS_SAVED LAST_SEEN SPENT_SEEN LEDGER_ROWS CUTS_DONE CUT_ATTEMPT CUT_ITEM CUT_AT PAUSED CREATE_SENT INPUT_BYTES PARTS_FULL PARTS_SENT PKIND PMSG"
SPOT_FINALS=" DONE FAIL DEADLINE BUILD_FAILED "
# Error wording from `instances create` that means Google refused the request and created nothing: no capacity in
# the zone, a quota, or a machine type or feature the zone does not offer. Only after one of these, and a listing
# of the whole project that shows no instance, does a start go on to the next zone. Any other error may hide a VM
# that was created after all, so no second zone is ever tried after it.
SPOT_NOCREATE='ZONE_RESOURCE_POOL_EXHAUSTED|does not have enough resources|QUOTA_EXCEEDED|Quota .* exceeded|quota exceeded|is not supported in|not available in zone|does not exist in zone|UNSUPPORTED_OPERATION'
SPOT_ABSENT='matched no objects|no urls matched'     # gcloud's own words for "no such object"; anything else is a failed fetch
SPOT_LOCK="$STATE.lock"

spot_state_exists() { [ -e "$STATE" ] && grep -q "^SPOT='1'\$" "$STATE"; }
spot_load() { # read the state file; every key has a value afterwards, so `set -u` cannot trip on an old or short file
  local k; for k in $SPOT_KEYS; do eval "$k=''"; done
  . "$STATE"
  : "${ATTEMPT:=0}" "${ACCOUNTED:=0}" "${PARTS_BYTES:=0}" "${PROGRESS:=0}" "${NOPROGRESS:=0}" "${CUT_ATTEMPT:=0}" "${CUT_AT:=0}" "${MAXRUN:=0}" "${CREATED:=0}" "${GIVEUP_EPOCH:=0}" "${RESULTS_SAVED:=0}" "${LAST_SEEN:=0}" "${CREATE_SENT:=0}" "${PARTS_FULL:=0}" "${PARTS_SENT:=0}"
}
# spot_sync <file>...: make the files, and the folders that hold them, survive a power cut: F_FULLFSYNC where the
# system has it (macOS, where a plain fsync leaves the data in the drive's cache), else fsync. Used before every
# create, not at every save.
spot_sync() {
  python3 -I - "$@" <<'PY'
import fcntl, os, sys
def sync(fd):
    try: fcntl.fcntl(fd, fcntl.F_FULLFSYNC)
    except (AttributeError, OSError): os.fsync(fd)
for p in sys.argv[1:]:
    for q in (p, os.path.dirname(os.path.realpath(p)) or '.'):
        fd = os.open(q, os.O_RDONLY)
        try: sync(fd)
        finally: os.close(fd)
PY
}
spot_save() { # rewrite the whole state file atomically: a reader, or a watch started after a crash, sees the old or the new file
  local k v tmp="$STATE.tmp.$$"
  # (sed is run only for a value that holds a quote: the state is saved at every poll, so this stays cheap)
  { for k in $SPOT_KEYS; do eval "v=\${$k:-}"; case "$v" in *"'"*) v=$(printf '%s' "$v" | sed "s/'/'\\\\''/g") ;; esac; printf "%s='%s'\n" "$k" "$v"; done; } > "$tmp" || die "could not write $tmp"
  mv -f "$tmp" "$STATE" || die "could not replace $STATE"
}
# spot_lock <command>: one Spot command at a time. Two at once undo each other's work: a teardown run while a watch
# runs would be followed at once by the watch starting the next attempt, and two watches would delete each other's
# VMs. The lock is the kernel's (flock) on the regular file $SPOT_LOCK, which is never removed. It belongs to the
# open file, which this shell keeps open on descriptor 9 for as long as it lives; the kernel releases it when the
# process ends, however it ends (Ctrl-C, kill -9, a crash, a power cut), so there is no stale lock and nothing to
# take over. A child process inherits descriptor 9 and so keeps the lock alive after its parent is gone: every
# sleep in the Spot code is started with it closed (spot_sleep); a gcloud child can outlive its parent by a few
# minutes. Old-mode `launch` and `teardown` take the lock too, but only when its file already exists (a Spot command
# has run in this work directory); otherwise they do what they always did. $SPOT_LOCK.info names the holder, for the
# refusal message only; nothing is decided from it.
# No Spot command starts another lock-taking command through $SELF while it holds the lock (`ledger` takes none).
spot_lock() {
  local rc pid cmd
  [ ! -d "$SPOT_LOCK" ] || die "the lock file $SPOT_LOCK is a directory, left by an earlier version of this script, so no Spot command can take the lock; nothing has been done. It can be removed (rm -r \"$SPOT_LOCK\") when no Spot command is running"
  exec 9>>"$SPOT_LOCK" || die "could not open the lock file $SPOT_LOCK; nothing has been done"
  python3 -I -c 'import errno, fcntl, sys
try:
    fcntl.flock(9, fcntl.LOCK_EX | fcntl.LOCK_NB)
except OSError as e:
    sys.exit(1 if e.errno in (errno.EWOULDBLOCK, errno.EAGAIN) else 3)'
  rc=$?
  if [ "$rc" = 1 ]; then
    exec 9>&-
    pid=$(sed -n 1p "$SPOT_LOCK.info" 2>/dev/null); cmd=$(sed -n 2p "$SPOT_LOCK.info" 2>/dev/null)
    case "$pid" in ''|*[!0-9]*) pid="" ;; esac
    if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then
      die "the lock of this Spot run is held: the command that took it, '${cmd:-unknown}' (process $pid), has itself ended, but a child process of it (usually gcloud) still holds the lock and will release it when it finishes, usually within a few minutes. Two commands at once would undo each other's work, so this one does nothing. Try again in a few minutes; to see which process holds the lock: lsof \"$SPOT_LOCK\""
    fi
    die "another command of this Spot run is running: '${cmd:-unknown}' (process ${pid:-unknown}). Two at once would undo each other's work, so this one does nothing. If you want to stop the run, stop that command first (Ctrl-C in its terminal, or: kill ${pid:-<its process number>}), then run: bash $SELF teardown. A command that has only just been stopped can hold the lock for a few minutes more (a child process of it still running): if so, try again in a few minutes"
  elif [ "$rc" != 0 ]; then
    exec 9>&-
    die "could not take the lock on $SPOT_LOCK (status $rc). The work directory $(dirname "$SPOT_LOCK") must be on a filesystem that supports file locks; nothing has been done, and no Spot command runs without the lock"
  fi
  { printf '%s\n%s\n%s\n' "$$" "$1" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$SPOT_LOCK.info.tmp.$$" && mv -f "$SPOT_LOCK.info.tmp.$$" "$SPOT_LOCK.info"; } 2>/dev/null \
    || echo "WARNING: could not write $SPOT_LOCK.info (it only names the holder in other commands' refusals); the lock is held, carrying on"
}
spot_sleep() { sleep "$1" 9>&-; }    # a sleeping child must not keep the lock (above)
spot_isnum() { case "$1" in ''|.|*[!0-9.]*|*.*.*) return 1 ;; esac; }
spot_params() { # per-mode settings, and a check of every Spot setting before anything is created
  local v k
  # The guest stops DMARGIN seconds before Google deletes the VM, which leaves room for its watchdog's two waits
  # (at most 420 + 300 s in full-spot, 300 + 480 s in the rehearsal) plus a margin.
  DMARGIN=900
  case "$MODE" in
    full-spot)
      SPOT_LIMIT=151200; SPOT_MIN=${GCP_SPOT_MIN_ATTEMPT_SECONDS:-5400}; CKPT_EVERY=${GCP_SPOT_CKPT_EVERY:-600}; CONFIRM=${GCP_SPOT_CONFIRM_EVERY:-1200}
      GMODE=full; HOLD=""; CUTS=""
      DATA="name=$NAME-data,device-name=pilot-data,type=hyperdisk-balanced,size=440GB,provisioned-iops=6000,provisioned-throughput=300,auto-delete=yes"
      MD="pilot-nmax=32,full-timebox=0,full-prune-after=3000,full-keep-oleans=${GCP_KEEP_OLEANS:-0},full-second-replay=$SECOND_REPLAY,full-watchdog-wait=420,full-watchdog-finish-wait=300" ;;
    full-spot-rehearsal)
      # full-rehearsal's settings, but no archive of compiled files (the parts are the archive), and a hold of 90 s
      # after the seal begins so that the watcher can cut the attempt there.
      SPOT_LIMIT=4500; SPOT_MIN=${GCP_SPOT_MIN_ATTEMPT_SECONDS:-2400}; CKPT_EVERY=${GCP_SPOT_CKPT_EVERY:-120}; CONFIRM=${GCP_SPOT_CONFIRM_EVERY:-45}
      GMODE=full-rehearsal; HOLD=",full-spot-hold=seal:90"; CUTS=${GCP_SPOT_REHEARSAL_CUTS-build:simulate seal:delete c3:reset}
      DATA="name=$NAME-data,device-name=pilot-data,type=hyperdisk-balanced,size=100GB,auto-delete=yes"
      MD="pilot-nmax=32,full-timebox=420,full-prune-after=300,full-prune-every=120,full-c2-timeout=900,full-check-trial=16 32,full-check-trial-secs=90,full-final-reserve=300,full-watchdog-wait=300,full-watchdog-finish-wait=480,full-keep-oleans=0,full-keep-min-left=420,full-second-replay=rhv-replay,full-c3-short-cap=300" ;;
    *) die "not a Spot mode: $MODE" ;;
  esac
  for k in SPOT_RATE SPOT_GIVEUP_H SPOT_RESERVE XREGION PARTS_MAX_GIB; do eval "v=\$$k"; spot_isnum "$v" || die "Spot setting $k is not a number: '$v'"; done
  for k in SPOT_MAX_ATTEMPTS SPOT_MIN CKPT_EVERY CONFIRM; do eval "v=\$$k"; case "$v" in ''|*[!0-9]*) die "Spot setting $k is not a whole number: '$v'" ;; esac; done
  [ "$(echo "$SPOT_RATE > 0" | bc)" = 1 ] || die "GCP_SPOT_RATE_USD_PER_HOUR must be above zero"
  [ "$SPOT_MIN" -ge $((DMARGIN + 600)) ] || die "GCP_SPOT_MIN_ATTEMPT_SECONDS is $SPOT_MIN; it must be at least $((DMARGIN + 600)): the guest stops $DMARGIN s before Google deletes the VM, and an attempt needs at least ten minutes of work besides"
  [ "$CONFIRM" -ge 30 ] || die "GCP_SPOT_CONFIRM_EVERY is $CONFIRM; it must be a whole number of seconds, at least 30"
  for v in $CUTS; do
    case "$v" in build:simulate|build:delete|build:reset|seal:simulate|seal:delete|seal:reset|c2:simulate|c2:delete|c2:reset|c3:simulate|c3:delete|c3:reset|end:simulate|end:delete|end:reset) ;;
      *) die "GCP_SPOT_REHEARSAL_CUTS: '$v' is not phase:how with phase build, seal, c2, c3 or end and how simulate, delete or reset" ;; esac
  done
  # The guest stops saving parts before they pass this size on an attempt outside the bucket's region, which is
  # what the worst-case transfer of the cap test rests on.
  PARTS_MAX_BYTES=$(python3 -I -c 'import sys; from decimal import Decimal as D; print(int(D(sys.argv[1]) * 2**30))' "$PARTS_MAX_GIB") || die "could not work out GCP_SPOT_PARTS_MAX_GIB in bytes"
}
spot_bucket_region() { # sets BUCKET_REGION from the bucket itself. Status 1, with SPOT_WHY, unless it is one region.
  local loc
  loc=$($G storage buckets describe "gs://$BUCKET" --format='value(location)' 2>>"$OUT/api_errors.log") || { SPOT_WHY="could not read the location of gs://$BUCKET; try again when the storage API answers"; return 1; }
  loc=$(printf '%s' "$loc" | tr 'A-Z' 'a-z' | tr -d ' \r\n')
  # A single region looks like us-central1 or europe-west4; a multi-region (us, eu) or a dual-region (nam4) does
  # not, and with one of those nobody can say which zones are free of transfer charges.
  if ! printf '%s\n' "$loc" | grep -qE '^[a-z]+-[a-z]+[0-9]+$'; then
    SPOT_WHY="the bucket gs://$BUCKET is in '$loc', which is not a single region. A Spot run needs a bucket in one region (for example $REGION), so that the cost of moving checkpoints between the bucket and each zone is known"
    return 1
  fi
  BUCKET_REGION=$loc
}
spot_ready() { # watch and teardown: the region of the bucket and the size of the inputs must be known before anything is accounted
  [ -n "$BUCKET_REGION" ] && [ -n "$INPUT_BYTES" ] && return 0
  if [ -z "$BUCKET_REGION" ]; then spot_bucket_region || die "$SPOT_WHY"; fi
  if [ -z "$INPUT_BYTES" ]; then spot_input_bytes || die "$SPOT_WHY"; fi
  spot_save
}
# spot_input_bytes: sets INPUT_BYTES, the size of gs://BUCKET/inputs/, which every attempt downloads (a transfer
# between regions when the attempt runs outside the bucket's region). Status 1, with SPOT_WHY, if it cannot be read.
spot_input_bytes() {
  local b
  b=$($G storage du -s "gs://$BUCKET/inputs/" 2>>"$OUT/api_errors.log" | awk 'NR == 1 {print $1}')
  case "$b" in ''|*[!0-9]*) SPOT_WHY="could not measure the size of gs://$BUCKET/inputs/, which every attempt downloads; try again when the storage API answers"; return 1 ;; esac
  INPUT_BYTES=$b
}
spot_ledger_rows() { awk 'NR > 1' "$LEDGER" | wc -l | tr -d ' '; }
spot_ledger_check() { # status 0 if the ledger still holds at least the rows and the spend this run last saw in it
  [ -n "$LEDGER_ROWS" ] || return 0
  [ "$(spot_ledger_rows)" -ge "$LEDGER_ROWS" ] && [ "$(echo "$(spent) >= ${SPENT_SEEN:-0}" | bc)" = 1 ]
}
spot_ledger_lost() {
  echo "the ledger $LEDGER has lost rows: it holds $(spot_ledger_rows) rows and \$$(spent) of recorded spend, but this run last saw $LEDGER_ROWS rows and \$$SPENT_SEEN. Nothing is started, because the cap test would rest on a ledger that counts too little. Put the missing rows back (from a backup of the file), then run: bash $SELF watch"
}
spot_ledger_seen() { # after every row added and every accounting: remember what the ledger holds now
  spot_ledger_check || die "$(spot_ledger_lost)"
  LEDGER_ROWS=$(spot_ledger_rows); SPENT_SEEN=$(spent); spot_save
}
# spot_size <zone>: prints "MAXRUN XWORST REASON" for an attempt started now in that zone (section 1.4 of the
# design). REASON says what set MAXRUN: ok (the mode's own limit), cap, giveup, or parts (outside the bucket's
# region, the checkpoint parts are at the limit an attempt there may carry: no attempt may start in that zone).
spot_size() {
  local out=0; [ "${1%-*}" = "$BUCKET_REGION" ] || out=1
  python3 -I - "$CAP_USD" "$(spent)" "$SPOT_RESERVE" "$SPOT_RATE" "$XREGION" "$PARTS_MAX_GIB" "$out" "$SPOT_LIMIT" "$(( GIVEUP_EPOCH - $(date +%s) ))" "$PARTS_BYTES" "${INPUT_BYTES:-0}" "${PARTS_FULL:-0}" <<'PY'
import sys
from decimal import Decimal as D, ROUND_CEILING, ROUND_FLOOR
cap, spent, reserve, rate, xr, pmax = (D(a) for a in sys.argv[1:7])
out, limit, left, pbytes, ibytes, pfull = (int(a or 0) for a in sys.argv[7:13])
# The worst transfer out of region (every part, and the inputs each attempt downloads) is taken as a whole number
# of cents, so that the transfer row (rounded UP to a cent) can never exceed it; the attempt's own row is rounded
# to the nearest cent, which the 0.01 covers.
xworst = (xr * (pmax + D(ibytes) / 2**30)).quantize(D('0.01'), rounding=ROUND_CEILING) if out else D('0.00')
avail = cap - spent - reserve - D('0.01') - xworst
bycap = int((D(3600) * avail / rate).to_integral_value(rounding=ROUND_FLOOR)) - 120
m = min(limit, left, bycap)
why = 'ok' if m == limit else ('giveup' if m == left and left < bycap else 'cap')
if out and (pfull or D(pbytes) * 10 > pmax * 2**30 * 9):
    # The guest stopped at the bound, or the parts already fill more than 90 % of it: the worst case rests on that
    # bound, so no attempt starts out of region.
    m, why = min(m, -1), 'parts'
print(m, xworst, why)
PY
}
spot_commit_ok() { # the commit rule of `full`, for every attempt, plus: the commit must be attempt 1's. Sets GUEST_FILE and XMD.
  local tsha tc head
  [ -f "$OUT/rhv_tools.id" ] || { SPOT_WHY="run 'bash $SELF stage' first: the archive of this repository's scripts has not been uploaded"; return 1; }
  read -r tsha tc < "$OUT/rhv_tools.id"
  head=$(git -C "$REPO_ROOT" rev-parse HEAD) || { SPOT_WHY="could not read the current commit"; return 1; }
  [ "$tc" = "$head" ] || { SPOT_WHY="the staged scripts are from commit $tc, not the current one ($head); run 'bash $SELF stage' again"; return 1; }
  [ -z "$(git -C "$REPO_ROOT" status --porcelain --untracked-files=all -- scripts cloud)" ] || { SPOT_WHY="scripts/ or cloud/ has uncommitted or untracked files; the run is tied to commit ${TCOMMIT:-$head}"; return 1; }
  if [ -z "${TCOMMIT:-}" ]; then TCOMMIT=$tc
  elif [ "$tc" != "$TCOMMIT" ]; then SPOT_WHY="this run began at commit $TCOMMIT and the current commit is $tc. Every attempt must come from the same commit: check out $TCOMMIT and stage it again, or abandon the run"; return 1
  fi
  GUEST_FILE="$OUT/full_guest_$RUNTAG.sh"
  git -C "$REPO_ROOT" show HEAD:cloud/gcp/full_guest.sh > "$GUEST_FILE" || { SPOT_WHY="could not read cloud/gcp/full_guest.sh from the current commit"; return 1; }
  XMD="full-tools-sha=$tsha,full-tools-commit=$tc,full-guest-sha=$(sha256_of "$GUEST_FILE")"
}
spot_ledger_zone() { # fill in the zone of this run's OPEN row only (earlier attempts share the runtag); the file is swapped in whole, as in close_run
  python3 -I - "$LEDGER" "$RUNTAG" "$1" "$$" <<'PY'
import fcntl, os, stat, sys
p, t, z = os.path.realpath(sys.argv[1]), sys.argv[2], sys.argv[3]
def sync(fd):
    try: fcntl.fcntl(fd, fcntl.F_FULLFSYNC)
    except (AttributeError, OSError): os.fsync(fd)
L = [l.rstrip('\n').split('\t') for l in open(p)]
for r in L[1:]:
    if r[0] == t and len(r) > 6 and r[6] == '' and r[4] == 'pending': r[4] = z
tmp = os.path.join(os.path.dirname(p) or '.', 'ledger.tmp.' + sys.argv[4])
with open(tmp, 'w') as f:
    f.write('\n'.join('\t'.join(r) for r in L) + '\n'); f.flush(); sync(f.fileno())
os.chmod(tmp, stat.S_IMODE(os.stat(p).st_mode))
os.replace(tmp, p)
d = os.open(os.path.dirname(p) or '.', os.O_RDONLY)
try: sync(d)
finally: os.close(d)
PY
}
# spot_vm: the current attempt's VM, looked for by name in EVERY zone (a create that reported an error may have made
# it somewhere unexpected). Sets SPOT_VM to its status, GONE if the API positively reports no instance of that name,
# or UNKNOWN if the call failed; and SPOT_VM_ZONE to its zone.
spot_vm() {
  local out
  SPOT_VM_ZONE=""
  if out=$($G compute instances list --filter="name=$NAME" --format='value(status,zone.basename())' 2>>"$OUT/api_errors.log"); then
    if [ -z "$out" ]; then SPOT_VM=GONE; return 0; fi
    set -- $(printf '%s\n' "$out" | head -1); SPOT_VM=${1:-UNKNOWN}; SPOT_VM_ZONE=${2:-}
    [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 1 ] || echo "WARNING: more than one instance is named $NAME: $(printf '%s ' $out). The end of this attempt deletes them all."
  else
    SPOT_VM=UNKNOWN
  fi
}
spot_vm_present() { case "$SPOT_VM" in GONE|UNKNOWN) return 1 ;; esac; return 0; }
# spot_create_unclear: `instances create` reported an error that does not show that nothing was created. Google may
# have accepted the request all the same, and the VM may not be listed yet. Look once more, in every zone, after
# 30 s: a VM of this name found anywhere is this attempt; if none is found the script stops with the row open
# (`watch` finds out later and accounts for the attempt). It never tries another zone, which could make a second VM.
spot_create_unclear() {
  local rows row n zz st
  echo "  that error does not show that nothing was created; looking for $NAME in every zone in 30 s"
  spot_sleep 30
  if rows=$($G compute instances list --format='csv[no-heading](name,zone.basename(),status)'); then
    for row in $rows; do
      n=${row%%,*}; zz=${row#*,}; st=${zz#*,}; zz=${zz%%,*}
      if [ "$n" = "$NAME" ]; then
        ZONE=$zz; spot_save; spot_ledger_zone "$zz"
        echo "$NAME exists in $zz (status $st) although create reported an error; watching it as attempt $ATTEMPT"; return 0
      fi
    done
  fi
  die "cannot confirm whether $NAME was created for attempt $ATTEMPT. The ledger row stays open and no other zone is tried, so that there can never be two VMs. Run 'bash $SELF watch' in a few minutes: it looks for the VM in every zone and accounts for the attempt"
}
# spot_start: start attempt ATTEMPT+1 in the first zone, in the configured order, where an attempt of at least
# SPOT_MIN seconds fits under the cap and there is capacity. Returns 0 when a VM was created, 2 when no zone had
# capacity (nothing exists and the row opened for it is closed at zero), 3 when the cap, the give-up time, the
# commit rule or a damaged ledger forbids a start (reason in SPOT_WHY). It exits, leaving the row open, when it
# cannot tell whether a VM exists.
# spot_refuse <sentence>: a refusal made before anything was created. During a launch (SPOT_EARLY=1: the run's state
# was written at once, before any call to the cloud) it removes that state first, so that no run is left behind.
spot_refuse() {
  [ "${SPOT_EARLY:-0}" != 1 ] || spot_forget_own_state
  die "$1"
}
# The state file is removed only while it is still this launch's own (a Spot state carrying this run's tag): an
# old-mode launch that started in the same instant may have written its own state there since, and that one stays.
spot_forget_own_state() {
  if spot_state_exists && grep -q "^RUNTAG='$RUNTAG'\$" "$STATE" 2>/dev/null; then rm -f "${STATE:?}"; fi
}
spot_start() {
  local N=$((ATTEMPT + 1)) Z m xw why best="" bestwhy="" nparts=0 rownow="" existing DL SSHA PMD issued=0 pA=$ATTEMPT pZ=$ZONE pC=$CREATED pM=$MAXRUN
  SPOT_WHY=""
  [ -z "$(open_run)" ] || spot_refuse "a ledger row is open ($(open_run)); not starting attempt $N. Run: bash $SELF watch"
  spot_ledger_check || { SPOT_WHY=$(spot_ledger_lost); return 3; }
  # The owner's remedy for the parts limit: a larger GCP_SPOT_PARTS_MAX_GIB than the limit the guest stopped at.
  if [ "$PARTS_FULL" != 0 ] && [ "$PARTS_MAX_BYTES" -gt "$PARTS_FULL" ]; then
    echo "GCP_SPOT_PARTS_MAX_GIB ($PARTS_MAX_GIB GiB) is now above the limit an earlier attempt stopped at; attempts outside the bucket's region $BUCKET_REGION may start again"
    PARTS_FULL=0; spot_save
  fi
  existing=$($G compute instances list --format='value(name)') || spot_refuse "could not list instances; not starting attempt $N. Run 'bash $SELF watch' again when the Compute API answers"
  [ -z "$existing" ] || spot_refuse "an instance exists in the project ($existing); refusing to create another. Run: bash $SELF teardown"
  existing=$($G compute disks list --format='value(name)') || spot_refuse "could not list disks; not starting attempt $N. Run 'bash $SELF watch' again when the Compute API answers"
  [ -z "$existing" ] || spot_refuse "a disk exists in the project ($existing); refusing to create anything. Run: bash $SELF teardown"
  spot_commit_ok || return 3
  SSHA=$(sha256_of "$HERE/sampler.py")
  for Z in $ZONES; do
    set -- $(spot_size "$Z"); m=${1:-}; xw=${2:-}; why=${3:-}
    case "$m" in ''|*[!0-9-]*) [ -n "$rownow" ] || spot_refuse "could not size an attempt in $Z"; die "could not size an attempt in $Z" ;; esac
    if [ "$m" -lt "$SPOT_MIN" ]; then
      case "$why" in
        parts) nparts=$((nparts + 1))
          echo "  $Z: the checkpoint parts ($(spot_gib "$PARTS_BYTES") GiB) are at the limit GCP_SPOT_PARTS_MAX_GIB allows for an attempt outside the bucket's region $BUCKET_REGION; no attempt may start in $Z"
          continue ;;
        giveup) echo "  $Z: the give-up time (GCP_SPOT_GIVEUP_HOURS after the first launch) leaves room for an attempt of only $m s (the minimum is $SPOT_MIN s)" ;;
        *) echo "  $Z: the cap leaves room for an attempt of only $m s here (the minimum is $SPOT_MIN s)" ;;
      esac
      if [ -z "$best" ] || [ "$m" -gt "$best" ]; then best=$m; bestwhy=$why; fi
      continue
    fi
    if [ -z "$rownow" ]; then
      # The state names the new attempt BEFORE its row is written, with STARTING=N saying that no create has been
      # sent for it yet; so a watch that died anywhere in here finds the attempt and knows whether a VM can exist.
      # (From here on a launch's refusals keep the state: it names an attempt, and later a row.)
      rownow=$(date +%s); SPOT_EARLY=0
      ATTEMPT=$N; STARTING=$N; ZONE=$Z; CREATED=$rownow; MAXRUN=$m; RATE=$SPOT_RATE; LAST_SEEN=0; CREATE_SENT=0; PARTS_SENT=0; CUT_ITEM=""; CUT_AT=0; spot_save
      spot_sync "$STATE" || die "could not flush the state file $STATE to disk; attempt $N is not started and nothing has been created for it. Run 'bash $SELF watch' when the disk is writable again: it carries on"
      # Record the attempt BEFORE creating anything, so that a VM can never exist without a ledger row; and make
      # the row survive a power cut of this machine before the create is sent.
      printf '%s\t%s\t%s\t%s\t%s\t%s\t\t\t\n' "$RUNTAG" "$MODE#$N" "$MT" "$SPOT_RATE" "pending" "$rownow" >> "$LEDGER" || die "could not write the ledger; not starting attempt $N"
      spot_sync "$LEDGER" || die "could not flush the ledger $LEDGER to disk; attempt $N is not started. Its row is open with nothing created: run 'bash $SELF watch' to close it and carry on"
      spot_ledger_seen
    fi
    # From the first create on, a VM may exist: the marker goes BEFORE the request is sent, on disk.
    # PARTS_SENT: the parts limit this create gives the guest (0: none), which a parts-limit pause refers to.
    PARTS_SENT=0; [ "${Z%-*}" = "$BUCKET_REGION" ] || PARTS_SENT=$PARTS_MAX_BYTES
    ZONE=$Z; MAXRUN=$m; [ "$issued" = 1 ] || STARTING=""; CREATE_SENT=$(date +%s); spot_save
    if ! spot_sync "$STATE"; then
      [ "$issued" = 1 ] || { STARTING=$N; spot_save; }     # no create was sent for this attempt: say so again
      die "could not flush the state file $STATE to disk; the create for attempt $N in $Z is not sent. Run 'bash $SELF watch' when the disk is writable again: it accounts for the attempt and carries on"
    fi
    issued=1
    DL=$(( (m - DMARGIN) / 60 ))
    PMD=""; [ "$PARTS_SENT" = 0 ] || PMD=",full-parts-max-bytes=$PARTS_SENT"
    echo "attempt $N: $NAME ($MT, Spot) in $Z for at most $m s; worst case \$$(printf '%.2f' "$(echo "scale=4; $SPOT_RATE * ($m + 120) / 3600 + 0.01" | bc)") plus transfer \$$xw; recorded spend so far \$$(spent) of \$$CAP_USD"
    if $G compute instances create "$NAME" --zone="$Z" --machine-type="$MT" --provisioning-model=SPOT \
        --max-run-duration="${m}s" --instance-termination-action=DELETE \
        --boot-disk-type=hyperdisk-balanced --boot-disk-size=50GB --create-disk="$DATA" \
        --network-interface=network=default,nic-type=GVNIC,stack-type=IPV4_ONLY \
        --image-family=ubuntu-2404-lts-amd64 --image-project=ubuntu-os-cloud \
        --scopes=https://www.googleapis.com/auth/devstorage.read_write \
        --labels=purpose=lean-verify \
        --metadata="pilot-bucket=$BUCKET,pilot-mode=$GMODE,pilot-deadline-min=$DL,pilot-runtag=$RUNTAG,pilot-tarball-sha=$RH_TARBALL_SHA256,pilot-sampler-sha=$SSHA,pilot-target-a=none,pilot-target-b=,$MD,$XMD,full-spot=1,full-attempt=$N,full-ckpt-every=$CKPT_EVERY,full-confirm-every=$CONFIRM,full-state-sha=$STATE_SHA,full-manifest-sha=$MANIFEST_SHA$PMD$HOLD" \
        --metadata-from-file=startup-script="$GUEST_FILE" 2> "$OUT/create_$RUNTAG-$N.err"; then
      spot_ledger_zone "$Z"
      echo "CREATED attempt $N of $RUNTAG: $NAME in $Z"; return 0
    fi
    echo "create failed in $Z: $(tail -3 "$OUT/create_$RUNTAG-$N.err" | tr '\n' ' ' | cut -c1-500)"
    # A refused request can still leave one of its disks behind, so both listings must succeed and be empty.
    if grep -qiE "$SPOT_NOCREATE" "$OUT/create_$RUNTAG-$N.err" && existing=$($G compute instances list --format='value(name,zone.basename())') && [ -z "$existing" ] \
        && existing=$($G compute disks list --format='value(name,zone.basename())') && [ -z "$existing" ]; then
      continue      # Google refused, and the whole project is confirmed empty: try the next zone
    fi
    [ -z "$existing" ] || echo "  the project is not empty after that refusal: $(echo $existing)"
    spot_create_unclear; return 0
  done
  if [ -n "$rownow" ]; then
    # No zone created anything (each refusal was confirmed by two empty listings). The state goes back to the last
    # attempt FIRST, with STARTING still naming the row, so that a watch that dies here closes that row at zero.
    ATTEMPT=$pA; ZONE=$pZ; CREATED=$pC; MAXRUN=$pM; STARTING=$N; spot_save
    close_run "$RUNTAG" "$rownow" zero
    STARTING=""; spot_ledger_seen
    return 2
  fi
  if [ -z "$best" ] && [ "$nparts" -gt 0 ]; then
    SPOT_WHY="the checkpoint parts ($(spot_gib "$PARTS_BYTES") GiB) are at the limit GCP_SPOT_PARTS_MAX_GIB ($PARTS_MAX_GIB GiB) allows for an attempt outside the bucket's region $BUCKET_REGION, and no zone in GCP_ZONES is in that region, so no attempt may start. Either add zones of region $BUCKET_REGION to GCP_ZONES, or raise GCP_SPOT_PARTS_MAX_GIB (each attempt outside the region is then sized for the larger transfer); raising GCP_SPEND_CAP_USD does not help. Then run: bash $SELF watch"
  elif [ "$bestwhy" = giveup ]; then
    SPOT_WHY="the give-up time (GCP_SPOT_GIVEUP_HOURS after the first launch) leaves room for an attempt of only $best s, less than the minimum of $SPOT_MIN s"
  else
    SPOT_WHY="the cap leaves room for an attempt of only ${best:-0} s in the best zone, less than the minimum of $SPOT_MIN s (spent \$$(spent) of \$$CAP_USD, \$$SPOT_RESERVE held back for checkpoint storage)"
  fi
  [ "$(date +%s)" -lt "$GIVEUP_EPOCH" ] || SPOT_WHY="the give-up time has passed (GCP_SPOT_GIVEUP_HOURS after the first launch)"
  return 3
}
spot_gib() { python3 -I -c 'import sys; print("%.1f" % (int(sys.argv[1] or 0) / 2**30))' "$1"; }
spot_purge_delete() { # ask for every instance and disk in the project to be deleted; a refused delete is not fatal here
  local rows row n z
  if rows=$($G compute instances list --format='csv[no-heading](name,zone.basename())'); then
    for row in $rows; do n=${row%%,*}; z=${row##*,}; SPOT_PURGE_FOUND=1; echo "deleting instance $n in $z"; $G compute instances delete "$n" --zone="$z" --delete-disks=all; done
  fi
  if rows=$($G compute disks list --format='csv[no-heading](name,zone.basename())'); then
    for row in $rows; do n=${row%%,*}; z=${row##*,}; echo "deleting leftover disk $n in $z"; $G compute disks delete "$n" --zone="$z"; done
  fi
}
# spot_purge: delete every instance and disk in the project, then positively verify that none is left (as teardown).
# A VM that Google is deleting itself (after taking it back) can stay listed for a few minutes, and a delete sent
# meanwhile can fail; so the listings are repeated every 15 s for up to 10 minutes, asking again for the deletes
# once a minute, before the attempt is declared NOT VERIFIED.
spot_purge() {
  local vok left_i left_d w0 i=0
  SPOT_PURGE_FOUND=0
  spot_purge_delete
  w0=$(date +%s)
  while true; do
    vok=1
    left_i=$($G compute instances list --format='value(name,zone.basename(),status)') || vok=0
    left_d=$($G compute disks list --format='value(name,zone.basename(),sizeGb)') || vok=0
    if [ "$vok" = 1 ] && [ -z "$left_i$left_d" ]; then echo "verified: no instances and no disks remain in the project"; return 0; fi
    if [ $(( $(date +%s) - w0 )) -ge 600 ]; then
      echo "NOT VERIFIED that attempt $ATTEMPT is gone. instances: [$left_i] disks: [$left_d]. Something may still be billing; the ledger row stays OPEN and nothing new is started." >&2
      echo "Restore network or gcloud access, then re-run: bash $SELF watch     (or: bash $SELF teardown)" >&2
      return 1
    fi
    [ "$i" != 0 ] || echo "waiting for the deletions to finish (instances: [$(echo $left_i)] disks: [$(echo $left_d)]$([ "$vok" = 1 ] || echo '; a listing failed'))"
    spot_sleep 15; i=$((i + 1))
    [ $((i % 4)) != 0 ] || spot_purge_delete
  done
}
spot_fetch() { # spot_fetch <object> <file>: 0 fetched, 1 the bucket says there is no such object, 2 the fetch failed
  rm -f "${2:?}"
  if $G storage cp "gs://$BUCKET/$1" "$2" >/dev/null 2>"$OUT/ckpt_fetch.err"; then return 0; fi
  rm -f "${2:?}"
  if grep -qiE "$SPOT_ABSENT" "$OUT/ckpt_fetch.err"; then return 1; fi
  return 2
}
spot_mirror() { # copy the run's small result files to GCP_RESULTS_MIRROR_DIR; a failure is reported and changes nothing else
  [ -n "$MIRROR_DIR" ] || return 0
  [ -d "$MIRROR_DIR" ] || { echo "mirror: $MIRROR_DIR is not an existing directory; nothing mirrored"; return 0; }
  { mkdir -p "$MIRROR_DIR/$RUNTAG" && cp -R "$OUT/$RUNTAG/." "$MIRROR_DIR/$RUNTAG/"; } 2>/dev/null || echo "mirror: could not copy $OUT/$RUNTAG to $MIRROR_DIR/$RUNTAG (carrying on)"
  return 0
}
spot_mirror_live() { # while an attempt runs: fetch the latest small files and mirror them
  local f
  [ -n "$MIRROR_DIR" ] && [ -d "$MIRROR_DIR" ] || return 0
  mkdir -p "$OUT/$RUNTAG/attempt-$ATTEMPT"
  for f in status.json facts.json heartbeat; do $G storage cp "gs://$BUCKET/results/$RUNTAG/$f" "$OUT/$RUNTAG/$f" >/dev/null 2>&1; done
  for f in pilot.log phases.tsv setup.tsv progress.tsv; do $G storage cp "gs://$BUCKET/results/$RUNTAG/attempt-$ATTEMPT/$f" "$OUT/$RUNTAG/attempt-$ATTEMPT/$f" >/dev/null 2>&1; done
  spot_mirror
}
spot_status() { # prints "phase state attempt elapsed message" from a status.json on stdin
  python3 -I -c 'import sys,json
try:
    d=json.load(sys.stdin); print(d["phase"], d["state"], d.get("attempt", "-"), d["elapsed_s"], d["message"])
except Exception: print("unreadable-status unknown - 0 -")'
}
# spot_pause_read <status.json text>: when it is this attempt's PAUSED, sets SPOT_PKIND to the kind of pause the
# guest gives ("pause"; none given counts as deadline) and SPOT_PMSG to its message. Kinds: deadline (the attempt
# ran out of its own time), retry (trouble a fresh machine may not have), parts-limit (the parts reached the limit
# an attempt outside the bucket's region may carry), stop (another attempt would end the same way).
spot_pause_read() {
  local info
  info=$(printf '%s' "$1" | python3 -I -c 'import json,sys
try:
    d = json.load(sys.stdin)
    if d.get("state") == "PAUSED" and str(d.get("attempt")) == sys.argv[1]:
        print((str(d.get("pause") or "").split() or ["deadline"])[0], " ".join(str(d.get("message", "")).split()))
except Exception: pass' "$ATTEMPT") || return 0
  [ -n "$info" ] || return 0
  SPOT_PKIND=${info%% *}; SPOT_PMSG=${info#* }
}
# spot_kind_rank <kind>: how cautious a kind of pause is: stop > parts-limit > retry > deadline > none. A kind this
# launcher does not know pauses the run (spot_watch), so it ranks above them all.
spot_kind_rank() { case "$1" in '') echo 0 ;; deadline) echo 1 ;; retry) echo 2 ;; parts-limit) echo 3 ;; stop) echo 4 ;; *) echo 5 ;; esac; }
spot_status_attempt() { # status 0 if the bucket's status.json was written by the current attempt
  local raw
  raw=$($G storage cat "gs://$BUCKET/results/$RUNTAG/status.json" 2>/dev/null) || return 1
  set -- $(printf '%s' "$raw" | spot_status)
  [ "${3:-}" = "$ATTEMPT" ]
}
spot_seen_now() { # the poll has just seen the VM: remember when, for the note on over-counting in spot_account
  if spot_vm_present; then
    LAST_SEEN=$(date +%s)
    if [ -n "$SPOT_VM_ZONE" ] && [ "$SPOT_VM_ZONE" != "$ZONE" ]; then echo "$NAME is in $SPOT_VM_ZONE, not $ZONE; following it there"; ZONE=$SPOT_VM_ZONE; fi
    spot_save
  fi
}
# spot_cut_due <phase>: the gates of the rehearsal's cuts, so that each one cuts where it tests something. A build
# cut waits until this attempt has saved a part (the manifest has a row with this attempt's number), so that the
# next attempt resumes a build half done; a c3 cut waits until the guest has saved replay results the launcher had
# not seen yet, so that the next attempt restores them. The two objects are fetched only while such a cut waits.
spot_cut_due() {
  case "$1" in
    build) $G storage cat "gs://$BUCKET/ckpt/$RUNTAG/manifest.tsv" 2>/dev/null | awk -F'\t' -v a="$ATTEMPT" 'NR > 1 && $7 == a {f = 1} END {exit !f}' ;;
    c3) $G storage cat "gs://$BUCKET/ckpt/$RUNTAG/state.json" 2>/dev/null | python3 -I -c 'import json,sys
try: n = int(json.load(sys.stdin).get("results_saved", 0))
except Exception: n = -1
sys.exit(0 if n > int(sys.argv[1]) else 1)' "$RESULTS_SAVED" ;;
    *) return 0 ;;
  esac
}
# spot_wait_gone: after the guest has said Google is taking the machine back, Google still shuts it down and
# deletes it, which takes up to a few minutes. Wait for that (at most 5 minutes) rather than race it with a delete.
spot_wait_gone() {
  local w0; w0=$(date +%s)
  spot_vm; spot_seen_now
  while [ "$SPOT_VM" != GONE ] && [ $(( $(date +%s) - w0 )) -lt 300 ]; do
    echo "$(date +%H:%M:%S) waiting for Google to finish deleting $NAME (status $SPOT_VM)"
    spot_sleep 15; spot_vm; spot_seen_now
  done
}
# spot_poll: step 2 of the watch loop. Returns with SPOT_END=final (the guest reported a final state: the run is
# over) or SPOT_END=over (only this attempt is over), and SPOT_REASON. It never deletes anything itself.
spot_poll() {
  local raw cur last="" st ph att apifail=0 stale=0 seen=0 absent=0 hb every=45 ldl lastmirror cut_at="" cut_item="" item p h t zfixed=0 gone=0 sent=$CREATE_SENT
  [ "$MODE" = full-spot-rehearsal ] && every=20
  # The clocks of this attempt start when its create was sent (a create can take minutes to be answered, and
  # earlier zones may have refused first); CREATED, when the row was opened, only for an older state.
  [ "${sent:-0}" -gt 0 ] || sent=$CREATED
  ldl=$(( sent + MAXRUN + 300 )); lastmirror=$(date +%s)
  # This attempt's cut, from the state, so that a watch started again carries on where the last one stopped: a
  # delete cut not yet verified ends the attempt at once (spot_account deletes and verifies); a simulate keeps its
  # send time, from which the fallback is timed.
  if [ "$CUT_ATTEMPT" = "$ATTEMPT" ] && [ -n "$CUT_ITEM" ] && spot_cut_pending "$CUT_ITEM"; then
    case "${CUT_ITEM#*:}" in
      delete) SPOT_END=over; SPOT_REASON="rehearsal cut $CUT_ITEM (its deletion is not verified yet)"; return 0 ;;
      simulate) cut_item=$CUT_ITEM; [ "${CUT_AT:-0}" = 0 ] || cut_at=$CUT_AT ;;
    esac
  fi
  while true; do
    if raw=$($G storage cat "gs://$BUCKET/results/$RUNTAG/status.json" 2>"$OUT/watch_fetch.err"); then
      cur=$(printf '%s' "$raw" | spot_status); att=$(echo "$cur" | awk '{print $3}')
      # status.json outlives its attempt: one left by an earlier attempt says nothing about this one.
      if [ "$att" = "$ATTEMPT" ]; then seen=1; absent=0; else cur="earlier-attempt-status none $att 0 -"; absent=$((absent + 1)); fi
    elif grep -qiE "$SPOT_ABSENT" "$OUT/watch_fetch.err"; then
      cur="no-status none - 0 -"; absent=$((absent + 1))
    else
      cur="fetch-failed unknown - 0 $(head -c 120 "$OUT/watch_fetch.err" | tr '\n' ' ')"; absent=0
    fi
    [ "$cur" = "$last" ] || { echo "$(date +%H:%M:%S) attempt $ATTEMPT: $cur"; last=$cur; }
    ph=$(echo "$cur" | awk '{print $1}'); st=$(echo "$cur" | awk '{print $2}')
    spot_vm
    if [ "$SPOT_VM" = UNKNOWN ]; then apifail=$((apifail+1)); echo "$(date +%H:%M:%S) Compute API call failed ($apifail in a row); keeping the VM and retrying"; else apifail=0; fi
    spot_seen_now
    if [ "$zfixed" = 0 ] && spot_vm_present && [ -n "$SPOT_VM_ZONE" ]; then spot_ledger_zone "$SPOT_VM_ZONE"; zfixed=1; fi    # only a row still 'pending' changes
    t=$(date +%s)
    case "$SPOT_FINALS" in *" $st "*) SPOT_END=final; SPOT_REASON="the guest reported $st"; return 0 ;; esac
    if [ "$st" = RECLAIMED ]; then spot_cut_seen reclaimed; spot_wait_gone; SPOT_END=over; SPOT_REASON="the guest reported RECLAIMED"; return 0; fi
    if [ "$st" = PAUSED ]; then
      spot_pause_read "$raw"
      SPOT_END=over; SPOT_REASON="the guest reported PAUSED ($SPOT_PKIND$([ "$SPOT_PKIND" = deadline ] || echo ": $SPOT_PMSG"))"; return 0
    fi
    # A VM nobody has seen yet, and that has reported nothing, may simply not be listed yet after a create that
    # reported an error: it is taken as gone only once 5 minutes have passed since that create was sent AND two
    # listings in a row since then have shown no such VM.
    if [ "$SPOT_VM" = GONE ] && [ $(( t - sent )) -ge 300 ]; then gone=$((gone + 1)); elif [ "$SPOT_VM" != UNKNOWN ]; then gone=0; fi
    if [ "$SPOT_VM" = GONE ] && { [ "$LAST_SEEN" != 0 ] || [ "$seen" = 1 ] || [ "$gone" -ge 2 ]; }; then spot_cut_seen gone; SPOT_END=over; SPOT_REASON="the VM no longer exists"; return 0; fi
    if [ "$SPOT_VM" = TERMINATED ] || [ "$SPOT_VM" = STOPPED ] || [ "$SPOT_VM" = SUSPENDED ]; then spot_cut_seen gone; SPOT_END=over; SPOT_REASON="the VM is $SPOT_VM"; return 0; fi
    if [ "$t" -ge "$ldl" ]; then SPOT_END=over; SPOT_REASON="the local deadline passed"; return 0; fi
    if [ "$seen" = 0 ] && [ "$absent" -ge 3 ] && [ "$(( t - sent ))" -gt 1500 ]; then SPOT_END=over; SPOT_REASON="the guest has reported nothing for this attempt in 25 minutes"; return 0; fi
    # Only a heartbeat written during this attempt counts; the file outlives its attempt as status.json does.
    hb=$($G storage cat "gs://$BUCKET/results/$RUNTAG/heartbeat" 2>/dev/null | tr -cd '0-9')
    if [ -n "$hb" ] && [ "$hb" -ge "$CREATED" ] && [ "$(( t - hb ))" -gt 1800 ]; then stale=$((stale + 1)); else stale=0; fi
    if [ "$stale" -ge 3 ]; then SPOT_END=over; SPOT_REASON="the guest's last heartbeat is more than 30 minutes old"; return 0; fi
    # Rehearsal cuts: end the attempt on purpose, at most once per attempt, at each phase:how not yet done. What
    # was actually done goes into CUTS_DONE: "build:simulate>pending" (with CUT_ATTEMPT and CUT_ITEM) before
    # anything is sent, and "build:simulate" only once the cut has been seen to take effect: a reset once its
    # command has returned, a delete once spot_account has verified the VM gone, a simulate once the attempt has
    # ended by the guest's RECLAIMED or the VM going (spot_cut_seen); or "build:simulate>delete" when it fell back.
    # An entry still pending is never cut again, and is reported NOT DONE if it is still pending at the end.
    if [ -n "$cut_at" ] && [ "$(( t - cut_at ))" -ge 300 ]; then
      # Google accepted the simulated reclaim, but it did not take effect: the attempt ends by a delete.
      spot_cut_set "$cut_item" "$cut_item>delete"
      SPOT_END=over; SPOT_REASON="the VM was still there 5 minutes after the simulated reclaim (deleting instead)"; return 0
    fi
    if [ -n "${CUTS:-}" ] && [ -z "$cut_at" ] && [ "$st" = RUNNING ] && [ "$CUT_ATTEMPT" != "$ATTEMPT" ]; then
      for item in $CUTS; do
        p=${item%%:*}; h=${item#*:}
        case " $CUTS_DONE " in *" $item "*|*" $item>"*) continue ;; esac
        [ "$p" = "$ph" ] || continue
        spot_cut_due "$p" || continue
        echo "$(date +%H:%M:%S) rehearsal cut $item in attempt $ATTEMPT"
        case "$h" in
        esac
        CUTS_DONE="${CUTS_DONE:+$CUTS_DONE }$item>pending"; CUT_ATTEMPT=$ATTEMPT; CUT_ITEM=$item; CUT_AT=0; spot_save     # recorded first: never cut twice
        case "$h" in
          delete)
            # No command is sent here: the attempt ends, and spot_account deletes the VM and verifies it gone,
            # which is when the cut is done (a watch that stops before that ends the attempt at once next time).
            SPOT_END=over; SPOT_REASON="rehearsal cut $item"; return 0 ;;
          reset)
            # A hard reset: the machine stops at once with no shutdown and no notice, as if its power were cut.
            # The attempt is over at once; the VM, which reboots, is deleted with the rest.
            if $G compute instances reset "$NAME" --zone="$ZONE"; then spot_cut_set "$item" "$item"
            else spot_cut_set "$item" "$item>delete"; echo "the reset was refused; deleting instead"
            fi
            SPOT_END=over; SPOT_REASON="rehearsal cut $item"; return 0 ;;
        esac
        # simulate: Google's own forced reclaim, with its notice. --async returns as soon as Google has the request.
        # Accepted, it stays pending until it is seen to take effect; CUT_AT times the fallback, across watches.
        if $G compute instances simulate-maintenance-event "$NAME" --zone="$ZONE" --async; then cut_at=$(date +%s); cut_item=$item; CUT_AT=$cut_at; spot_save
        else
          spot_vm
          case "$SPOT_VM" in
            STOPPING|TERMINATED|GONE|SUSPENDING|SUSPENDED) cut_at=$(date +%s); cut_item=$item; CUT_AT=$cut_at; spot_save; echo "the simulated reclaim reported an error, but $NAME is $SPOT_VM: it is going" ;;
            *) spot_cut_set "$item" "$item>delete"
               SPOT_END=over; SPOT_REASON="rehearsal cut $item (the simulated reclaim was refused, $NAME is $SPOT_VM; deleting instead)"; return 0 ;;
          esac
        fi
        break
      done
    fi
    if [ "$(( t - lastmirror ))" -ge 600 ]; then spot_mirror_live; lastmirror=$t; fi
    spot_sleep "$every"
  done
}
spot_cut_pending() { case " $CUTS_DONE " in *" $1>pending "*) return 0 ;; esac; return 1; }   # spot_cut_pending <item>
# spot_cut_seen reclaimed|gone: the attempt is ending by the guest's RECLAIMED (reclaimed) or by the VM going (gone,
# which includes RECLAIMED): this attempt's simulate still pending, and on RECLAIMED its reset, took effect.
spot_cut_seen() {
  [ "$CUT_ATTEMPT" = "$ATTEMPT" ] && [ -n "$CUT_ITEM" ] && spot_cut_pending "$CUT_ITEM" || return 0
  case "${CUT_ITEM#*:}:$1" in simulate:*|reset:reclaimed) spot_cut_set "$CUT_ITEM" "$CUT_ITEM" ;; esac
}
spot_cut_set() { # spot_cut_set <item> <entry>: give <item>'s entry in CUTS_DONE its final form, and save
  local e out=""
  for e in $CUTS_DONE; do case "$e" in "$1"|"$1>"*) e=$2 ;; esac; out="${out:+$out }$e"; done
  CUTS_DONE=$out; spot_save
}
spot_ckpt_vals() { # spot_ckpt_vals <state.json> <manifest.tsv>: prints "progress final total_bytes results_saved"; absent files count as zero
  python3 -I - "$1" "$2" <<'PY'
import json, os, sys
s, m = sys.argv[1:3]
prog, final, total, rs = 0, 0, 0, 0
if os.path.exists(s):
    try:
        j = json.load(open(s)); prog = int(j.get("progress", 0)); final = 1 if j.get("final") is True else 0
        rs = int(j.get("results_saved", 0))
    except Exception: pass
if os.path.exists(m):
    rows = [l.rstrip("\n").split("\t") for l in open(m) if l.strip()]
    if rows and "bytes" in rows[0]:
        i = rows[0].index("bytes")
        total = sum(int(r[i]) for r in rows[1:] if len(r) > i and r[i].isdigit())
print(prog, final, total, rs)
PY
}
# spot_account: step 3. Safe to run again after any interruption: every step before the final state write either
# changes nothing the second time (delete, verify, close, copy) or checks first (the transfer row, the progress
# count, which is touched only while ACCOUNTED is not yet this attempt); the state file is written last.
spot_account() {
  local raw d="$OUT/$RUNTAG/ckpt" a="$OUT/$RUNTAG/attempt-$ATTEMPT" rc1 rc2 vals ssha="" msha="" bytes=0 prog=0 sfinal=0 rs=0 usd t ref pk pm
  SPOT_FINAL=0
  spot_purge || exit 1
  # This attempt's delete cut is done now that nothing is left of it.
  if [ "$CUT_ATTEMPT" = "$ATTEMPT" ] && [ "${CUT_ITEM#*:}" = delete ] && spot_cut_pending "$CUT_ITEM"; then spot_cut_set "$CUT_ITEM" "$CUT_ITEM"; fi
  # STARTING=N means the state was saved for attempt N but no create was ever sent (the watcher died in between).
  # Nothing can have run, which the listing, the last poll and the bucket all confirm: close its row at zero and
  # use the attempt number again, without counting an attempt that made no progress.
  if [ -n "$STARTING" ] && [ "$STARTING" = "$ATTEMPT" ] && [ "$SPOT_PURGE_FOUND" = 0 ] && [ "$LAST_SEEN" = 0 ] && ! spot_status_attempt; then
    echo "attempt $ATTEMPT was never created (the watcher stopped before asking Google for its machine); its row is closed at zero and its number will be used again"
    [ "$(open_run)" = "$RUNTAG" ] && close_run "$RUNTAG" "$CREATED" zero
    ATTEMPT=$ACCOUNTED; STARTING=""; spot_ledger_seen
    return 0
  fi
  if [ "$(open_run)" = "$RUNTAG" ]; then
    t=$(date +%s); ref=$LAST_SEEN; [ "$ref" -gt 0 ] || ref=$CREATED
    if [ $(( t - ref )) -gt 600 ]; then
      echo "note: nobody saw attempt $ATTEMPT's VM during the last $(( (t - ref) / 60 )) minutes before its row was closed, so the row may count up to that long more than the VM ran. The ledger is kept on the safe side; the bill is authoritative."
    fi
    close_run "$RUNTAG" "$t" "" "$(( MAXRUN + 120 ))"
  fi
  STARTING=""; spot_ledger_seen
  # Only this attempt's logs and the top-level files: the earlier attempts' were copied when they ended.
  mkdir -p "$d" "$a"
  $G storage cp "gs://$BUCKET/results/$RUNTAG/*" "$OUT/$RUNTAG/" >/dev/null 2>&1
  $G storage cp -r "gs://$BUCKET/results/$RUNTAG/attempt-$ATTEMPT/*" "$a/" >/dev/null 2>&1
  rmdir "$a" 2>/dev/null       # kept only when something came
  # Three outcomes, as in spot_poll: read; positively absent (nothing to read); failed, which is an accounting
  # failure: the row is closed and nothing is running, and `watch` again accounts for the attempt.
  pk=${SPOT_PKIND:-}; pm=${SPOT_PMSG:-}; SPOT_PKIND=""; SPOT_PMSG=""
  if raw=$($G storage cat "gs://$BUCKET/results/$RUNTAG/status.json" 2>"$OUT/account_fetch.err"); then
    set -- $(printf '%s' "$raw" | spot_status)
    if [ "${3:-}" = "$ATTEMPT" ]; then case "$SPOT_FINALS" in *" ${2:-} "*) SPOT_FINAL=1 ;; esac; fi
    spot_pause_read "$raw"        # also when nobody was watching as the attempt paused itself
  elif ! grep -qiE "$SPOT_ABSENT" "$OUT/account_fetch.err"; then
    echo "could not read the guest's status.json from the bucket ($(head -c 200 "$OUT/account_fetch.err" | tr '\n' ' ')). Nothing is running and the row is closed; run 'bash $SELF watch' again when the bucket answers" >&2
    exit 1
  fi
  # A kind is never weakened: of what the poll saw and what this read gives, the more cautious one is kept.
  if [ "$(spot_kind_rank "$pk")" -gt "$(spot_kind_rank "$SPOT_PKIND")" ]; then SPOT_PKIND=$pk; SPOT_PMSG=$pm; fi
  # The VM is gone, so nothing can change the checkpoints while they are read.
  spot_fetch "ckpt/$RUNTAG/state.json" "$d/state.json"; rc1=$?
  spot_fetch "ckpt/$RUNTAG/manifest.tsv" "$d/manifest.tsv"; rc2=$?
  if [ "$rc1" = 2 ] || [ "$rc2" = 2 ]; then
    echo "could not read the run's checkpoints from the bucket ($(head -c 200 "$OUT/ckpt_fetch.err" | tr '\n' ' ')). Nothing is running and the row is closed; run 'bash $SELF watch' again when the bucket answers" >&2
    exit 1
  fi
  [ "$rc1" = 0 ] && ssha=$(sha256_of "$d/state.json")
  [ "$rc2" = 0 ] && msha=$(sha256_of "$d/manifest.tsv")
  vals=$(spot_ckpt_vals "$d/state.json" "$d/manifest.tsv") || die "could not read the downloaded checkpoints in $d"
  set -- $vals; prog=$1; sfinal=$2; bytes=$3; rs=${4:-0}
  [ "$sfinal" = 1 ] && SPOT_FINAL=1
  if [ "${ZONE%-*}" != "$BUCKET_REGION" ] && ! awk -F'\t' -v t="$RUNTAG" -v m="$MODE#$ATTEMPT-transfer" '$1==t && $2==m {f=1} END{exit !f}' "$LEDGER"; then
    # GiB restored at the attempt's start plus GiB of parts added during it plus the inputs every attempt
    # downloads, priced and rounded up to a cent.
    usd=$(python3 -I -c 'import sys; from decimal import Decimal as D, ROUND_CEILING; a,b,i,x=int(sys.argv[1]),int(sys.argv[2]),int(sys.argv[3]),D(sys.argv[4]); print((x*D(a+max(0,b-a)+i)/D(2**30)).quantize(D("0.01"),rounding=ROUND_CEILING))' "$PARTS_BYTES" "$bytes" "${INPUT_BYTES:-0}" "$XREGION")
    t=$(date +%s)
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$RUNTAG" "$MODE#$ATTEMPT-transfer" transfer 0 "$ZONE" "$t" "$t" 0 "$usd" >> "$LEDGER" || die "could not write the ledger"
    spot_sync "$LEDGER" || echo "WARNING: could not flush the ledger to disk after the transfer row; the next start flushes it again"
    spot_ledger_seen
    echo "attempt $ATTEMPT ran outside the bucket's region $BUCKET_REGION: transfer recorded as \$$usd"
  fi
  if [ "$ACCOUNTED" != "$ATTEMPT" ]; then
    if [ "$prog" -gt "$PROGRESS" ]; then PROGRESS=$prog; NOPROGRESS=0; else NOPROGRESS=$((NOPROGRESS + 1)); fi
  fi
  # The kind of pause is kept in the state until the watch loop has acted on it, so that a watch that stops in
  # between still acts on it.
  STATE_SHA=$ssha; MANIFEST_SHA=$msha; PARTS_BYTES=$bytes; RESULTS_SAVED=$rs; ACCOUNTED=$ATTEMPT; PKIND=${SPOT_PKIND:-}; PMSG=${SPOT_PMSG:-}
  spot_save
  echo "attempt $ATTEMPT accounted for: progress $PROGRESS (attempts in a row without progress: $NOPROGRESS), parts $PARTS_BYTES bytes, replay results saved $RESULTS_SAVED; recorded spend \$$(spent) of \$$CAP_USD"
  spot_mirror
}
# spot_settle: a start that was interrupted on the no-capacity path. Every zone had refused and nothing existed, but
# the row opened for it may still be open: close it at zero. (STARTING equal to ATTEMPT is spot_account's case.)
spot_settle() {
  [ -n "$STARTING" ] || return 0
  if [ "$STARTING" != "$ATTEMPT" ]; then
    echo "closing at zero the row of attempt $STARTING, for which every zone refused and nothing was created"
    [ "$(open_run)" = "$RUNTAG" ] && close_run "$RUNTAG" "$(date +%s)" zero
    STARTING=""; spot_ledger_seen
  else
    SPOT_REASON="interrupted start"; spot_account
  fi
}
spot_ckpt_note() { # what the run's checkpoints in the bucket hold and cost: they bill until somebody deletes them
  local b
  b=$($G storage du -s "gs://$BUCKET/ckpt/$RUNTAG/" 2>/dev/null | awk 'NR == 1 {print $1}')
  case "$b" in
    ''|*[!0-9]*) echo "the run's checkpoints are in gs://$BUCKET/ckpt/$RUNTAG/ (their size could not be measured); bucket storage bills until they are deleted" ;;
    *) python3 -I -c 'import sys; b = int(sys.argv[1]); g = b / 2**30
print("the run'"'"'s checkpoints in %s hold %.2f GiB; at 0.020 USD per GiB-month they cost about %.2f USD a month, and they bill until they are deleted" % (sys.argv[2], g, g * 0.020))' "$b" "gs://$BUCKET/ckpt/$RUNTAG/" ;;
  esac
  echo "to delete them: gcloud --project=$NP storage rm -r gs://$BUCKET/ckpt/$RUNTAG/"
}
# spot_cuts_report: what each of the rehearsal's configured cuts (CUTS) actually did, from CUTS_DONE: printed, and
# written to the results folder as cuts.txt (and so to the mirror). Sets SPOT_CUTS_MISSED to the number of cuts not
# done as configured. Does nothing when no cut is configured.
spot_cuts_report() {
  local item how lines=""
  SPOT_CUTS_MISSED=0
  [ -n "${CUTS:-}" ] || return 0
  for item in $CUTS; do
    case " $CUTS_DONE " in
      *" $item "*) how="done as configured" ;;
      *" $item>pending "*) how="NOT DONE (interrupted, or never seen to take effect)"; SPOT_CUTS_MISSED=$((SPOT_CUTS_MISSED + 1)) ;;
      *" $item>"*) how=" $CUTS_DONE "; how=${how#*" $item>"}; how="done by fallback (${how%% *})"; SPOT_CUTS_MISSED=$((SPOT_CUTS_MISSED + 1)) ;;
      *) how="NOT DONE"; SPOT_CUTS_MISSED=$((SPOT_CUTS_MISSED + 1)) ;;
    esac
    lines="$lines$item: $how
"
  done
  echo "rehearsal cuts of $RUNTAG (configured: $CUTS):"
  printf '%s' "$lines" | sed 's/^/  /'
  { mkdir -p "$OUT/$RUNTAG" && printf '%s' "$lines" > "$OUT/$RUNTAG/cuts.txt"; } 2>/dev/null || echo "could not write $OUT/$RUNTAG/cuts.txt"
  spot_mirror
}
spot_finish() { # the run is over: everything is already deleted, verified and accounted for. Sets SPOT_RC (0, or 4: see the header)
  SPOT_RC=0
  spot_cuts_report
  rm -f "$STATE"
  echo "the Spot run $RUNTAG is over after $ATTEMPT attempt(s); results are in $OUT/$RUNTAG"
  spot_ckpt_note
  echo "--- other billable compute resources (should be empty):"
  $G compute addresses list --format='table(name,region.basename(),status)' 2>/dev/null
  $G compute snapshots list --format='table(name,diskSizeGb)' 2>/dev/null
  /bin/bash "$SELF" ledger
  if [ "$SPOT_CUTS_MISSED" -gt 0 ]; then
    echo "THE REHEARSAL DID NOT EXERCISE WHAT IT WAS CONFIGURED TO: $SPOT_CUTS_MISSED of its cuts ($CUTS) were not done as configured (see above, and $OUT/$RUNTAG/cuts.txt). Exit status 4."
    SPOT_RC=4
  fi
}
spot_pause() {
  PAUSED=$1; spot_save
  spot_cuts_report
  echo "PAUSED: $1"
  echo "Nothing is running and nothing in Compute Engine bills. The checkpoints are kept in the bucket, and bucket storage still bills:"
  spot_ckpt_note
  echo "To continue: bash $SELF watch    To end the run: bash $SELF abandon"
  exit 3
}
spot_launch() {
  local existing rc
  MODE=$1; NAME="lean-$MODE"; spot_params
  spot_lock "launch $MODE"
  [ ! -e "$STATE" ] || die "a run state already exists in $STATE: 'bash $SELF watch' continues it, 'bash $SELF abandon' ends it"
  [ -z "$(open_run)" ] || die "a run is still open in the ledger: $(open_run). Run teardown first."
  # The run's state is written at once, before any call to the cloud or to git, so that from here on every other
  # command takes the Spot path, and so the lock. A launch killed from here on leaves a run with no attempt, which
  # `watch` continues and `abandon` ends; each refusal below removes it first (SPOT_EARLY, spot_refuse).
  RUNTAG="$MODE-$(date +%Y%m%d-%H%M%S)"; ZONE=""; CREATED=0; MAXRUN=0; RATE=$SPOT_RATE; SPOT=1; ATTEMPT=0; ACCOUNTED=0; STARTING=""
  FIRST_CREATED=$(date +%s); GIVEUP_EPOCH=$(( FIRST_CREATED + $(echo "$SPOT_GIVEUP_H * 3600 / 1" | bc) ))
  TCOMMIT=""; STATE_SHA=""; MANIFEST_SHA=""; PARTS_BYTES=0; PROGRESS=0; NOPROGRESS=0; RESULTS_SAVED=0; LAST_SEEN=0
  CUTS_DONE=""; CUT_ATTEMPT=0; CUT_ITEM=""; CUT_AT=0; PAUSED=""; BUCKET_REGION=""; LEDGER_ROWS=""; SPENT_SEEN=""
  CREATE_SENT=0; INPUT_BYTES=""; PARTS_FULL=0; PARTS_SENT=0; PKIND=""; PMSG=""
  spot_save; SPOT_EARLY=1
  existing=$($G compute instances list --format='value(name)') || spot_refuse "could not list instances; not launching"
  [ -z "$existing" ] || spot_refuse "an instance already exists in the project ($existing); refusing to create another"
  spot_bucket_region || spot_refuse "REFUSED: $SPOT_WHY"
  spot_input_bytes || spot_refuse "REFUSED: $SPOT_WHY; nothing has been created"
  spot_commit_ok || spot_refuse "$SPOT_WHY"
  case "$MODE" in full-spot) echo "kernel replay: leanchecker on every module${SECOND_REPLAY:+; then a second replay by $SECOND_REPLAY}" ;; esac
  spot_save; spot_ledger_seen
  spot_start; rc=$?
  case "$rc" in
    0) echo "Now run: bash $SELF watch"; exit 0 ;;
    2) spot_pause "no zone had capacity at launch; 'watch' keeps trying every 10 minutes" ;;
    *) spot_forget_own_state; die "REFUSED: $SPOT_WHY" ;;
  esac
}
spot_teardown() { # teardown during a Spot run: delete, verify and account as at the end of an attempt, but keep the run
  spot_lock teardown
  spot_state_exists || die "the Spot run's state is gone (another command ended the run meanwhile); run teardown again"
  spot_load; spot_params; spot_ready; spot_settle
  SPOT_PKIND=""; SPOT_PMSG=""
  if [ "$(open_run)" = "$RUNTAG" ] || [ "$ACCOUNTED" != "$ATTEMPT" ]; then SPOT_REASON="manual teardown"; spot_account
  else spot_purge || exit 1; SPOT_FINAL=0
  fi
  if [ "$SPOT_FINAL" = 1 ]; then spot_finish; return "$SPOT_RC"; fi
  PAUSED="manual teardown"; spot_save
  echo "the run's state is kept in $STATE (paused). To continue: bash $SELF watch    To end it: bash $SELF abandon"
  /bin/bash "$SELF" ledger
}
spot_watch() {
  local force=0 rc o why
  # The lock is taken here, after `watch` has started again under caffeinate, by the process that keeps it.
  spot_lock watch
  spot_load; spot_params; spot_ready
  trap 'echo; if [ -n "$(open_run)" ]; then echo "watch stopped. Attempt $ATTEMPT is still running and Google deletes it at its maximum run time ($(( (CREATED + MAXRUN - $(date +%s)) / 60 )) minutes from now)."; else echo "watch stopped; nothing is running."; fi; echo "To resume: bash $SELF watch     To end the attempt now: bash $SELF teardown"; exit 130' INT TERM HUP
  spot_settle
  while true; do
    if [ -n "$PAUSED" ]; then echo "continuing the paused run $RUNTAG (it was paused: $PAUSED)"; PAUSED=""; spot_save; force=1; fi
    o=$(open_run)
    [ -z "$o" ] || [ "$o" = "$RUNTAG" ] || die "the ledger row of another run is open ($o); not touching it"
    SPOT_PKIND=""; SPOT_PMSG=""
    if [ "$o" = "$RUNTAG" ]; then
      echo "watching attempt $ATTEMPT of $RUNTAG ($NAME in $ZONE)"
      spot_poll
      echo "attempt $ATTEMPT is over: $SPOT_REASON"
      spot_account
      if [ "$SPOT_END" = final ] || [ "$SPOT_FINAL" = 1 ]; then spot_finish; return "$SPOT_RC"; fi
    elif [ "$ACCOUNTED" != "$ATTEMPT" ]; then
      echo "attempt $ATTEMPT ended while nobody was watching; accounting for it now"
      SPOT_REASON="found ended"; spot_account
      if [ "$SPOT_FINAL" = 1 ]; then spot_finish; return "$SPOT_RC"; fi
      [ -z "$PKIND" ] || echo "attempt $ATTEMPT had been paused by the guest ($PKIND$([ "$PKIND" = deadline ] || echo ": $PMSG"))"
    fi
    # What the guest's pause says about the next attempt (kept in the state until it has been acted on).
    case "$PKIND" in
      ''|deadline|retry) PKIND=""; PMSG="" ;;
      parts-limit)
        # The limit this attempt was given, not the setting in force now (it may have been raised meanwhile); an
        # attempt given none (it should not pause so) counts as stopped at the setting in force.
        PARTS_FULL=$PARTS_SENT; [ "$PARTS_FULL" != 0 ] || PARTS_FULL=$PARTS_MAX_BYTES
        PKIND=""; PMSG=""; spot_save
        echo "attempt $ATTEMPT stopped at the limit on checkpoint parts outside the bucket's region it was given ($(spot_gib "$PARTS_FULL") GiB); until GCP_SPOT_PARTS_MAX_GIB is above that, attempts start only in zones of $BUCKET_REGION" ;;
      stop) why=$PMSG; PKIND=""; PMSG=""
        spot_pause "the guest stopped attempt $ATTEMPT and says another attempt would end the same way: $why" ;;
      *) why="$PKIND: $PMSG"; PKIND=""; PMSG=""
        spot_pause "the guest paused attempt $ATTEMPT with a kind of pause this launcher does not know ($why); nothing more is started until you have looked" ;;
    esac
    # Step 4: the pause rules. A `watch` run by hand after a pause starts one more attempt whatever they say; the
    # cap and the give-up time still apply to it, in spot_start.
    if [ "$force" = 0 ]; then
      why=""
      [ "$NOPROGRESS" -ge 3 ] && why="$NOPROGRESS attempts in a row saved no progress"
      [ "$(date +%s)" -ge "$GIVEUP_EPOCH" ] && why="the give-up time has passed (GCP_SPOT_GIVEUP_HOURS after the first launch)"
      [ "$ATTEMPT" -ge "$SPOT_MAX_ATTEMPTS" ] && why="$ATTEMPT attempts have been started (GCP_SPOT_MAX_ATTEMPTS)"
      [ -z "$why" ] || spot_pause "$why"
    fi
    spot_start; rc=$?
    case "$rc" in
      0) force=0 ;;
      2) echo "$(date +%H:%M:%S) no zone has capacity for attempt $((ATTEMPT + 1)); nothing exists and nothing bills; trying again in 10 minutes"; spot_sleep 600 ;;
      *) spot_pause "$SPOT_WHY" ;;
    esac
  done
}

case "${1:-}" in
stage)
  [ -f "$TARBALL" ] || die "tarball not found at $TARBALL (run scripts/01_fetch.sh first)"
  [ "$(sha256_of "$TARBALL")" = "$RH_TARBALL_SHA256" ] || die "local tarball does not match RH_TARBALL_SHA256"
  [ -f "$RH_AN/nonprefix_modules.txt" ] || die "missing $RH_AN/nonprefix_modules.txt (run: python3 analysis/import_graph.py)"
  [ -f "$TARGETS_JSON" ] || die "missing $TARGETS_JSON"
  $G storage buckets describe "gs://$BUCKET" >/dev/null 2>&1 || $G storage buckets create "gs://$BUCKET" --location="$REGION" --uniform-bucket-level-access --public-access-prevention
  SA="$($G projects describe "$NP" --format='value(projectNumber)')-compute@developer.gserviceaccount.com"
  $G storage buckets add-iam-policy-binding "gs://$BUCKET" --member="serviceAccount:$SA" --role=roles/storage.objectAdmin >/dev/null && echo "bucket access granted to the VM service account"
  $G storage ls "gs://$BUCKET/inputs/lean.tar.gz" >/dev/null 2>&1 || $G storage cp "$TARBALL" "gs://$BUCKET/inputs/lean.tar.gz"
  gzip -c "$RH_AN/nonprefix_modules.txt" > "$OUT/nonprefix_modules.txt.gz"
  python3 -I -c "import json; d=json.load(open('$TARGETS_JSON')); print('\n'.join([p['module'] for p in d['probes']] + [d['rehearsal_target']]))" > "$OUT/probe_modules.txt"
  $G storage cp "$OUT/nonprefix_modules.txt.gz" "gs://$BUCKET/inputs/nonprefix_modules.txt.gz"
  $G storage cp "$OUT/probe_modules.txt" "gs://$BUCKET/inputs/probe_modules.txt"
  $G storage cp "$HERE/sampler.py" "gs://$BUCKET/inputs/sampler.py"
  # This repository's scripts, as committed, for the full run to use on the VM.
  git -C "$REPO_ROOT" diff --quiet HEAD -- scripts || echo "NOTE: scripts/ has uncommitted changes; the archive is made from the last commit and will not include them"
  git -C "$REPO_ROOT" archive --format=tar.gz --prefix=rhv/ -o "$OUT/rhv_tools.tar.gz" HEAD scripts || die "could not archive scripts/ from git"
  rm -f "$OUT/rhv_tools.id"
  $G storage cp "$OUT/rhv_tools.tar.gz" "gs://$BUCKET/inputs/rhv_tools.tar.gz" || die "could not upload the scripts archive"
  printf '%s %s\n' "$(sha256_of "$OUT/rhv_tools.tar.gz")" "$(git -C "$REPO_ROOT" rev-parse HEAD)" > "$OUT/rhv_tools.id"
  $G storage ls -l "gs://$BUCKET/inputs/"
  ;;
launch)
  case "${2:-}" in full-spot|full-spot-rehearsal) spot_launch "$2"; exit $? ;; esac
  # Under the Spot lock (to the end of this command), but only when a Spot command has ever run here (spot_lock).
  [ ! -e "$SPOT_LOCK" ] || spot_lock "launch ${2:-}"
  spot_state_exists && die "a paused Spot run has its state in $STATE: 'bash $SELF watch' continues it, 'bash $SELF abandon' ends it"
  MODE=${2:-}
  case "$MODE" in pilot|rehearsal|full|full-rehearsal|export-check|kernel-check|kernel-check-rehearsal|target|target-rehearsal) ;; *) die "usage: $0 launch <rehearsal|pilot|full-rehearsal|full|export-check|kernel-check|kernel-check-rehearsal|target|target-rehearsal>" ;; esac
  [ -z "$(open_run)" ] || die "a run is still open in the ledger: $(open_run). Run teardown first."
  existing=$($G compute instances list --format='value(name)') || die "could not list instances; not launching"
  [ -z "$existing" ] || die "an instance already exists in the project ($existing); refusing to create another"
  RUNTAG="$MODE-$(date +%Y%m%d-%H%M%S)"; NAME="lean-$MODE"
  jget() { python3 -I -c "import json,sys; print(json.load(open('$TARGETS_JSON'))[sys.argv[1]])" "$1"; }
  GUEST_FILE="$HERE/pilot_guest.sh"; XMD=""
  if [ "$MODE" = full ] || [ "$MODE" = full-rehearsal ]; then
    # A full run is tied to one commit: the scripts archive and the guest script both come from HEAD, not from
    # the working tree, and nothing under scripts/ or cloud/ may be modified or untracked.
    [ -f "$OUT/rhv_tools.id" ] || die "run '$0 stage' first: the archive of this repository's scripts has not been uploaded"
    read -r TSHA TCOMMIT < "$OUT/rhv_tools.id"
    [ "$TCOMMIT" = "$(git -C "$REPO_ROOT" rev-parse HEAD)" ] || die "the staged scripts are from commit $TCOMMIT, not the current one; run '$0 stage' again"
    [ -z "$(git -C "$REPO_ROOT" status --porcelain --untracked-files=all -- scripts cloud)" ] || die "scripts/ or cloud/ has uncommitted or untracked files; commit them and run '$0 stage' again, so that the run is tied to a commit"
    GUEST_FILE="$OUT/full_guest_$RUNTAG.sh"
    git -C "$REPO_ROOT" show HEAD:cloud/gcp/full_guest.sh > "$GUEST_FILE" || die "could not read cloud/gcp/full_guest.sh from the current commit"
    TA=none; TB=""
    if [ "$MODE" = full ]; then
      DEADLINE_MIN=2460; MAXRUN=151200  # the guest stops by 41 h; Google deletes the VM at 42 h whatever happens
      DATA="name=$NAME-data,device-name=pilot-data,type=hyperdisk-balanced,size=440GB,provisioned-iops=6000,provisioned-throughput=300,auto-delete=yes"
      MD="pilot-nmax=32,full-timebox=0,full-prune-after=3000,full-keep-oleans=${GCP_KEEP_OLEANS:-0},full-second-replay=$SECOND_REPLAY"
    else
      # full-rehearsal: about 35 minutes are expected. The guest stops by 55 min, its watchdog takes over 13 min
      # later at the latest (5 min, and 8 more if the report had begun), and Google deletes the VM at 75 min. The build is boxed at seven minutes, not counting
      # the two restart tests; setup files are pruned every two minutes; and the archive of compiled files is
      # asked for, so that those paths are exercised on a small tree.
      DEADLINE_MIN=55; MAXRUN=4500
      DATA="name=$NAME-data,device-name=pilot-data,type=hyperdisk-balanced,size=100GB,auto-delete=yes"
      MD="pilot-nmax=32,full-timebox=420,full-prune-after=300,full-prune-every=120,full-c2-timeout=900,full-check-trial=16 32,full-check-trial-secs=90,full-final-reserve=300,full-watchdog-wait=300,full-watchdog-finish-wait=480,full-keep-oleans=1,full-keep-min-left=420,full-second-replay=rhv-replay,full-c3-short-cap=300"
    fi
    XMD="full-tools-sha=$TSHA,full-tools-commit=$TCOMMIT,full-guest-sha=$(sha256_of "$GUEST_FILE")"
  elif [ "$MODE" = export-check ]; then
    # The checks of export_guest.sh on the compiled files a finished Spot run left in the bucket. Like a full run
    # it is tied to one commit. GCP_EXPORT_FROM names that run; its manifest and facts.json must be in the
    # results directory on this machine, where `watch` put them.
    [ -f "$OUT/rhv_tools.id" ] || die "run '$0 stage' first: the archive of this repository's scripts has not been uploaded"
    read -r TSHA TCOMMIT < "$OUT/rhv_tools.id"
    [ "$TCOMMIT" = "$(git -C "$REPO_ROOT" rev-parse HEAD)" ] || die "the staged scripts are from commit $TCOMMIT, not the current one; run '$0 stage' again"
    [ -z "$(git -C "$REPO_ROOT" status --porcelain --untracked-files=all -- scripts cloud)" ] || die "scripts/ or cloud/ has uncommitted or untracked files; commit them and run '$0 stage' again, so that the run is tied to a commit"
    XFROM=${GCP_EXPORT_FROM:-}; [ -n "$XFROM" ] || die "set GCP_EXPORT_FROM to the run tag of the finished Spot run whose compiled files are to be checked"
    case "$XFROM" in *[!A-Za-z0-9-]*) die "GCP_EXPORT_FROM is not a run tag" ;; esac
    [ -f "$OUT/$XFROM/ckpt/manifest.tsv" ] && [ -f "$OUT/$XFROM/facts.json" ] || die "no manifest and facts.json of $XFROM under $OUT/$XFROM"
    XSEAL=$(python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["seal"]["compiled_files_manifest_sha256"] if d.get("state") == "DONE" else "")' "$OUT/$XFROM/facts.json") || XSEAL=""
    case "$XSEAL" in *[!0-9a-f]*|'') die "facts.json of $XFROM does not record a finished run with a seal" ;; esac
    GUEST_FILE="$OUT/export_guest_$RUNTAG.sh"
    git -C "$REPO_ROOT" show HEAD:cloud/gcp/export_guest.sh > "$GUEST_FILE" || die "could not read cloud/gcp/export_guest.sh from the current commit"
    TA=none; TB=""
    DEADLINE_MIN=280; MAXRUN=18000      # the guest stops by 4 h 40 min; Google deletes the VM at 5 h whatever happens
    DATA="name=$NAME-data,device-name=pilot-data,type=hyperdisk-balanced,size=440GB,provisioned-iops=6000,provisioned-throughput=300,auto-delete=yes"
    MD="pilot-nmax=32,export-src-runtag=$XFROM,export-manifest-sha=$(sha256_of "$OUT/$XFROM/ckpt/manifest.tsv"),export-seal-sha=$XSEAL"
    XMD="full-tools-sha=$TSHA,full-tools-commit=$TCOMMIT,full-guest-sha=$(sha256_of "$GUEST_FILE")"
  elif [ "$MODE" = kernel-check ] || [ "$MODE" = kernel-check-rehearsal ]; then
    # The checks of kernel_guest.sh on the exported proof. Like a full run it is tied to one commit, but it
    # needs nothing that `stage` uploads. GCP_KERNEL_FROM names a finished export-check run: the two hashes
    # that run recorded are the ones the guest will insist on, and its challenge export is the one fetched.
    [ -z "$(git -C "$REPO_ROOT" status --porcelain --untracked-files=all -- scripts cloud)" ] || die "scripts/ or cloud/ has uncommitted or untracked files; commit them first, so that the run is tied to a commit"
    TCOMMIT=$(git -C "$REPO_ROOT" rev-parse HEAD) || die "could not read the current commit"
    KFROM=${GCP_KERNEL_FROM:-}; [ -n "$KFROM" ] || die "set GCP_KERNEL_FROM to the run tag of a finished export-check run"
    case "$KFROM" in *[!A-Za-z0-9-]*) die "GCP_KERNEL_FROM is not a run tag" ;; esac
    [ -f "$OUT/$KFROM/export_facts.json" ] || die "no export_facts.json of $KFROM under $OUT/$KFROM"
    KV=$(python3 -I -c 'import json,sys
d=json.load(open(sys.argv[1])); f=d.get("facts",{})
if d.get("state")=="DONE" and f.get("solution_export_matches_published") is True and f.get("challenge_export_matches_published") is True:
    print(f["solution_export_sha256"], f["challenge_export_sha256"])' "$OUT/$KFROM/export_facts.json") || KV=""
    KSOL=${KV%% *}; KCH=${KV##* }
    case "$KSOL" in *[!0-9a-f]*|'') die "export_facts.json of $KFROM does not record a finished run whose two exports matched the published ones" ;; esac
    case "$KCH" in *[!0-9a-f]*|'') die "export_facts.json of $KFROM does not record the challenge export's hash" ;; esac
    [ "${#KSOL}" = 64 ] && [ "${#KCH}" = 64 ] || die "the hashes in export_facts.json of $KFROM are not SHA-256 values"
    $G storage ls "gs://$BUCKET/results/$KFROM/challenge.ndjson.zst" >/dev/null 2>&1 || die "the bucket does not hold the challenge export of $KFROM (results/$KFROM/challenge.ndjson.zst)"
    # The long run should find the proof's export in the bucket, where the rehearsal puts it: fetching 7.7 GB
    # from the published copy is work for the small machine.
    if [ "$MODE" = kernel-check ] && [ -z "${GCP_KERNEL_FETCH_OK:-}" ]; then
      $G storage ls "gs://$BUCKET/keep/exports/solution-$KSOL.ndjson.zst" >/dev/null 2>&1 || die "the bucket does not hold the proof's export (keep/exports/solution-$KSOL.ndjson.zst): run kernel-check-rehearsal first, which fetches and keeps it, or set GCP_KERNEL_FETCH_OK=1 to let the large machine fetch the published copy"
    fi
    GUEST_FILE="$OUT/kernel_guest_$RUNTAG.sh"
    git -C "$REPO_ROOT" show HEAD:cloud/gcp/kernel_guest.sh > "$GUEST_FILE" || die "could not read cloud/gcp/kernel_guest.sh from the current commit"
    TA=none; TB=""
    if [ "$MODE" = kernel-check ]; then
      # Lean's kernel took 9 hours on this export in the published record, its paranoid build 10, on another
      # machine; the one job timed on both was 11% slower here. About 12 hours are expected. The guest stops
      # by 19 h, and Google deletes a VM still running at 20 h.
      DEADLINE_MIN=1140; MAXRUN=72000
      DATA="name=$NAME-data,device-name=pilot-data,type=hyperdisk-balanced,size=200GB,provisioned-iops=6000,provisioned-throughput=300,auto-delete=yes"
      MD="pilot-nmax=32,kernel-long=${GCP_KERNEL_LONG:-1},kernel-swap-gb=64"
    else
      # The rehearsal needs four cores and little memory: a small machine, at its own rate (machine plus
      # disks, rounded up). The guest stops by 90 min; Google deletes the VM at 100 min.
      MT=${GCP_KERNEL_REHEARSAL_MACHINE:-n4d-highmem-4}; RATE=${GCP_KERNEL_REHEARSAL_RATE:-0.30}
      DEADLINE_MIN=90; MAXRUN=6000
      DATA="name=$NAME-data,device-name=pilot-data,type=hyperdisk-balanced,size=100GB,auto-delete=yes"
      MD="pilot-nmax=4,kernel-long=1,kernel-swap-gb=2,kernel-default-peak-kb=3000000,kernel-paranoid-peak-kb=3000000,kernel-margin-kb=1000000"
    fi
    MD="$MD,kernel-export-run=$KFROM,kernel-solution-sha=$KSOL,kernel-challenge-sha=$KCH,kernel-challenge-object=results/$KFROM/challenge.ndjson.zst,kernel-solution-object=keep/exports/solution-$KSOL.ndjson.zst"
    XMD="full-tools-commit=$TCOMMIT,full-guest-sha=$(sha256_of "$GUEST_FILE")"
  elif [ "$MODE" = target ] || [ "$MODE" = target-rehearsal ]; then
    # The numbered steps for one target profile on a fresh machine (target_guest.sh). Like a full run it is tied
    # to one commit: the guest script and the archive of scripts/, targets/ and analysis/ that the guest runs both
    # come from HEAD. GCP_TARGET names the profile. The archive is uploaded here, before the cap is checked: if
    # the launch is then refused, a file of well under a megabyte is left in the bucket.
    [ -z "$(git -C "$REPO_ROOT" status --porcelain --untracked-files=all -- scripts cloud targets analysis)" ] || die "scripts/, cloud/, targets/ or analysis/ has uncommitted or untracked files; commit them first, so that the run is tied to a commit"
    TCOMMIT=$(git -C "$REPO_ROOT" rev-parse HEAD) || die "could not read the current commit"
    TNAME=${GCP_TARGET:-}; [ -n "$TNAME" ] || die "set GCP_TARGET to the name of the target whose steps are to be run (a directory of targets/)"
    case "$TNAME" in -*|*[!abcdefghijklmnopqrstuvwxyz0123456789-]*) die "GCP_TARGET is not the name of a target: lower-case letters, digits and '-' only, not starting with '-'" ;; esac
    [ "$TNAME" != alpoge-rh ] || die "the mode $MODE is for a target other than the default one; the default target's modes are full and full-spot"
    git -C "$REPO_ROOT" cat-file -e "HEAD:targets/$TNAME/target.env" 2>/dev/null || die "the current commit has no targets/$TNAME/target.env"
    # The cap is tested against the ledger in this checkout's working directory. These modes are launched from
    # whichever checkout holds the commit to run, which need not be the one earlier runs were launched from:
    # a ledger with no run in it would have the cap tested against nothing spent, without a word.
    [ "$(wc -l < "$LEDGER" | tr -d ' ')" -gt 1 ] || [ -n "${GCP_NEW_LEDGER:-}" ] || die "the ledger $LEDGER has no run in it, so recorded spend would start at 0. If earlier runs were launched from another checkout, give this one the same RH_WORKDIR; to start a new ledger on purpose, set GCP_NEW_LEDGER=1"
    # A value of the profile at the current commit, as a plain assignment on one line gives it.
    tprof() { git -C "$REPO_ROOT" show "HEAD:targets/$TNAME/target.env" | sed -n "s/^$1=//p" | tail -n 1 | tr -d "\"'"; }
    # A machine named without its rate would be counted, in the ledger and against the cap, at another machine's.
    trate() { spot_isnum "$1" && [ "$(echo "$1 > 0" | bc)" = 1 ] || die "the rate for this machine must be a number above zero, in USD an hour (got '$1')"; }
    GUEST_FILE="$OUT/target_guest_$RUNTAG.sh"
    git -C "$REPO_ROOT" show HEAD:cloud/gcp/target_guest.sh > "$GUEST_FILE" || die "could not read cloud/gcp/target_guest.sh from the current commit"
    TREPO="$OUT/target_repo_$RUNTAG.tar.gz"; TOBJ="inputs/target/rhv-$TCOMMIT.tar.gz"
    git -C "$REPO_ROOT" archive --format=tar.gz --prefix=rhv/ -o "$TREPO" HEAD scripts targets analysis || die "could not archive scripts/, targets/ and analysis/ from the current commit"
    $G storage cp "$TREPO" "gs://$BUCKET/$TOBJ" >/dev/null 2>"$OUT/target_upload_$RUNTAG.err" || die "could not upload the archive of the repository's files to gs://$BUCKET/$TOBJ: $(tail -n 2 "$OUT/target_upload_$RUNTAG.err" | tr '\n' ' ' | cut -c1-300)"
    TA=none; TB=""
    if [ "$MODE" = target ]; then
      # About 16 vCPUs and 64 GB at the on-demand rate, with its two disks, rounded up. The guest stops half an
      # hour before Google deletes the VM.
      MT=${GCP_TARGET_MACHINE:-n4d-standard-16}; RATE=${GCP_TARGET_RATE:-0.75}
      [ -z "${GCP_TARGET_MACHINE:-}" ] || [ -n "${GCP_TARGET_RATE:-}" ] || die "GCP_TARGET_MACHINE is set without GCP_TARGET_RATE: the ledger would count that machine at the default machine's rate"
      trate "$RATE"
      THOURS=${GCP_TARGET_MAX_HOURS:-6}
      case "$THOURS" in ''|*[!0-9]*|0*) die "GCP_TARGET_MAX_HOURS must be a whole number of hours, at least 1, written without a leading zero" ;; esac
      MAXRUN=$(( THOURS * 3600 )); DEADLINE_MIN=$(( THOURS * 60 - 30 ))
      DATA="name=$NAME-data,device-name=pilot-data,type=hyperdisk-balanced,size=100GB,auto-delete=yes"
      TAX=${GCP_TARGET_AXIOMS:-deep}
      case "$TAX" in deep|full) ;; *) die "GCP_TARGET_AXIOMS must be deep (08, then 08 --deep) or full (08 only)" ;; esac
      MD="pilot-nmax=16,target-axioms=$TAX,target-replay-args=--c3"
    else
      # The rehearsal builds the profile's smoke targets (TGT_SMOKE_TARGETS at this commit) and replays a sample
      # of two. Step 04 has compiled the smoke targets by the time step 05 is asked for them, so
      # GCP_TARGET_REHEARSAL_ALSO can name further modules: step 05 then compiles something, after the network
      # is taken away. The axiom check needs the root module and is left out; 08 --probe is run instead on a
      # probe lemma, "<module> <lemma>" in GCP_TARGET_REHEARSAL_PROBE or else the profile's TGT_PROBE_MODULE
      # and TGT_PROBE_THEOREM, if there is one. The guest stops by 60 min; Google deletes the VM at 75 min.
      MT=${GCP_TARGET_REHEARSAL_MACHINE:-n4d-standard-8}; RATE=${GCP_TARGET_REHEARSAL_RATE:-0.40}
      [ -z "${GCP_TARGET_REHEARSAL_MACHINE:-}" ] || [ -n "${GCP_TARGET_REHEARSAL_RATE:-}" ] || die "GCP_TARGET_REHEARSAL_MACHINE is set without GCP_TARGET_REHEARSAL_RATE: the ledger would count that machine at the default machine's rate"
      trate "$RATE"
      DEADLINE_MIN=60; MAXRUN=4500
      DATA="name=$NAME-data,device-name=pilot-data,type=hyperdisk-balanced,size=100GB,auto-delete=yes"
      TSMOKE=$(tprof TGT_SMOKE_TARGETS)
      case "$TSMOKE" in ''|*[!A-Za-z0-9_.\ ]*) die "targets/$TNAME/target.env at the current commit gives no TGT_SMOKE_TARGETS of plain module names on one line, which the rehearsal builds" ;; esac
      TALSO=${GCP_TARGET_REHEARSAL_ALSO:-}
      case "$TALSO" in *[!A-Za-z0-9_.\ ]*) die "GCP_TARGET_REHEARSAL_ALSO must be plain module names, separated by spaces" ;; esac
      TPROBE=${GCP_TARGET_REHEARSAL_PROBE:-}
      [ -n "$TPROBE" ] || { TPM=$(tprof TGT_PROBE_MODULE); TPT=$(tprof TGT_PROBE_THEOREM); [ -z "$TPM" ] || [ -z "$TPT" ] || TPROBE="$TPM $TPT"; }
      case "$TPROBE" in *[!A-Za-z0-9_.\ ]*) die "the probe lemma must be given as '<module> <lemma>', both plain names (got '$TPROBE')" ;; esac
      TPM=${TPROBE%% *}; TPT=${TPROBE##* }
      [ -z "$TPROBE" ] || { [ -n "$TPT" ] && [ "$TPROBE" = "$TPM $TPT" ]; } || die "the probe lemma must be given as '<module> <lemma>' (got '$TPROBE')"
      # Each module once: the smoke targets, the further ones, and the probe's module, which 08 --probe needs compiled.
      TBUILD=""; for m in $TSMOKE $TALSO ${TPROBE:+$TPM}; do case " $TBUILD " in *" +$m "*) ;; *) TBUILD="$TBUILD${TBUILD:+ }+$m" ;; esac; done
      MD="pilot-nmax=8,target-axioms=skip,target-replay-args=--sample 2,target-build-args=$TBUILD${TPROBE:+,target-probe=$TPROBE}"
    fi
    MD="$MD,target-name=$TNAME,target-repo-object=$TOBJ,target-repo-sha=$(sha256_of "$TREPO")"
    XMD="full-tools-commit=$TCOMMIT,full-guest-sha=$(sha256_of "$GUEST_FILE")"
  elif [ "$MODE" = pilot ]; then
    DEADLINE_MIN=330; MAXRUN=21600      # the guest finishes by 5.5 h; Google deletes the VM at 6 h whatever happens
    DATA="name=$NAME-data,device-name=pilot-data,type=hyperdisk-balanced,size=440GB,provisioned-iops=6000,provisioned-throughput=300,auto-delete=yes"
    MD="pilot-nmax=32,pilot-w-cold=600,pilot-w-sweep=360,pilot-w-deep-a=6000,pilot-w-deep-b=9000,pilot-reserve=4800,pilot-w-check=600,pilot-sweep=16 32 16 32 24 8"
    TA=$(jget deep_target_a); TB=$(jget deep_target_b)
  else
    DEADLINE_MIN=40; MAXRUN=3000        # rehearsal: the guest finishes by 40 min; Google deletes the VM at 50 min
    DATA="name=$NAME-data,device-name=pilot-data,type=hyperdisk-balanced,size=100GB,auto-delete=yes"
    MD="pilot-nmax=32,pilot-w-cold=180,pilot-w-sweep=120,pilot-w-deep-a=300,pilot-w-deep-b=0,pilot-reserve=600,pilot-w-check=90,pilot-sweep=16 32"
    TA=$(jget rehearsal_target); TB=""
  fi
  [ -n "$TA" ] || die "no build target found in $TARGETS_JSON"
  SSHA=$(sha256_of "$HERE/sampler.py")
  # Refuse to start if the worst case for this VM would break the cap. The ledger can record up to 120 seconds
  # past the maximum run time (teardown, below), so they are counted here, and the figure is rounded up to a cent.
  WORST=$(echo "scale=2; $RATE * ($MAXRUN + 120) / 3600 + 0.01" | bc); SP=$(spent)
  [ "$(echo "$SP + $WORST > $CAP_USD" | bc)" = 0 ] || die "REFUSED: spent \$$SP + worst case \$$WORST would exceed the \$$CAP_USD cap"
  echo "launching $NAME ($MT): worst case \$$WORST, recorded spend so far \$$SP of \$$CAP_USD"
  case "$MODE" in full) echo "kernel replay: leanchecker on every module${SECOND_REPLAY:+; then a second replay by $SECOND_REPLAY}" ;; esac
  # Record the run BEFORE creating anything, so that a VM can never exist without a ledger row.
  NOW=$(date +%s)
  printf '%s\t%s\t%s\t%s\t%s\t%s\t\t\t\n' "$RUNTAG" "$MODE" "$MT" "$RATE" "pending" "$NOW" >> "$LEDGER" || die "could not write the ledger; not launching"
  for Z in $ZONES; do
    printf 'RUNTAG=%s\nNAME=%s\nZONE=%s\nMODE=%s\nCREATED=%s\nMAXRUN=%s\nRATE=%s\n' "$RUNTAG" "$NAME" "$Z" "$MODE" "$NOW" "$MAXRUN" "$RATE" > "$STATE"
    if $G compute instances create "$NAME" --zone="$Z" --machine-type="$MT" --provisioning-model=STANDARD \
        --max-run-duration="${MAXRUN}s" --instance-termination-action=DELETE \
        --boot-disk-type=hyperdisk-balanced --boot-disk-size=50GB --create-disk="$DATA" \
        --network-interface=network=default,nic-type=GVNIC,stack-type=IPV4_ONLY \
        --image-family=ubuntu-2404-lts-amd64 --image-project=ubuntu-os-cloud \
        --scopes=https://www.googleapis.com/auth/devstorage.read_write \
        --labels=purpose=lean-verify \
        --metadata="pilot-bucket=$BUCKET,pilot-mode=$MODE,pilot-deadline-min=$DEADLINE_MIN,pilot-runtag=$RUNTAG,pilot-tarball-sha=$RH_TARBALL_SHA256,pilot-sampler-sha=$SSHA,pilot-target-a=$TA,pilot-target-b=$TB,$MD${XMD:+,$XMD}" \
        --metadata-from-file=startup-script="$GUEST_FILE" 2> "$OUT/create_$RUNTAG.err"; then
      python3 -I -c "import sys; p,t,z=sys.argv[1:4]; L=[l.rstrip('\n').split('\t') for l in open(p)]; [r.__setitem__(4,z) for r in L[1:] if r[0]==t]; open(p,'w').write('\n'.join('\t'.join(r) for r in L)+'\n')" "$LEDGER" "$RUNTAG" "$Z"
      echo "CREATED $NAME in $Z as $RUNTAG. Now run: bash $SELF watch"; exit 0
    fi
    echo "create failed in $Z: $(tail -3 "$OUT/create_$RUNTAG.err" | tr '\n' ' ' | cut -c1-500)"
    st=$(vm_state "$NAME" "$Z")
    case "$st" in
      GONE) ;;                                                    # confirmed absent: try the next zone
      UNKNOWN) die "cannot confirm whether $NAME exists in $Z. The ledger row stays open; run: bash $SELF teardown" ;;
      *) die "$NAME exists in $Z (status $st) although create reported an error. Run: bash $SELF watch   or   teardown" ;;
    esac
  done
  close_run "$RUNTAG" "$NOW" zero; rm -f "$STATE"
  die "could not create the VM in any zone; nothing was created and nothing is billed"
  ;;
abandon)
  [ -e "$STATE" ] || die "no run state found; nothing to abandon"
  spot_load
  [ "${SPOT:-}" = 1 ] || die "abandon ends a paused Spot run; this state is for a $MODE run. Use teardown"
  spot_lock abandon
  spot_state_exists || die "the Spot run's state is gone (another command ended the run meanwhile); nothing to abandon"
  spot_load
  [ -z "$(open_run)" ] || die "a ledger row is open ($(open_run)): an attempt may be running. Run 'bash $SELF teardown' first (it keeps the run's state), then abandon"
  existing=$($G compute instances list --format='value(name)') || die "could not list instances; not abandoning"
  [ -z "$existing" ] || die "an instance exists in the project ($existing). Run 'bash $SELF teardown' first"
  existing=$($G compute disks list --format='value(name)') || die "could not list disks; not abandoning"
  [ -z "$existing" ] || die "a disk exists in the project ($existing). Run 'bash $SELF teardown' first"
  [ "$ACCOUNTED" = "$ATTEMPT" ] || die "attempt $ATTEMPT has not been accounted for yet. Run 'bash $SELF teardown' first"
  spot_params; spot_cuts_report
  rm -f "$STATE"
  echo "abandoned $RUNTAG after $ATTEMPT attempt(s); its state file is removed and nothing is running"
  spot_ckpt_note
  ;;
watch)
  [ -e "$STATE" ] || die "no run state found; nothing to watch"
  if is_macos && [ -z "${PILOT_CAFFEINATED:-}" ] && command -v caffeinate >/dev/null 2>&1; then
    PILOT_CAFFEINATED=1 exec caffeinate -i /bin/bash "$SELF" watch       # keep this machine awake while watching
  fi
  . "$STATE"
  case "$MODE" in full-spot|full-spot-rehearsal) spot_watch; exit $? ;; esac
  case "$MODE" in
    full*) trap 'echo; echo "watch stopped. The VM is still running and Google deletes it at its maximum run time ($(( (CREATED + MAXRUN - $(date +%s)) / 60 )) minutes from now)."; echo "To resume: bash $SELF watch     To end the run now and lose what has not been uploaded: bash $SELF teardown"; exit 130' INT TERM HUP ;;
    kernel-check*) trap 'echo; echo "watch stopped. The VM is still running. Google deletes it if it is still running at its maximum run time ($(( (CREATED + MAXRUN - $(date +%s)) / 60 )) minutes from now). If the guest finishes before that with nobody watching, it powers the machine off twenty minutes later: a stopped VM is not deleted by Google, and its disks bill until watch or teardown is run."; echo "To resume: bash $SELF watch     To end the run now and lose what has not been uploaded: bash $SELF teardown"; exit 130' INT TERM HUP ;;
    target) trap 'echo; echo "watch stopped. The VM is still running and Google deletes it at its maximum run time ($(( (CREATED + MAXRUN - $(date +%s)) / 60 )) minutes from now)."; echo "To resume: bash $SELF watch     To end the run now and lose what it has built: bash $SELF teardown"; exit 130' INT TERM HUP ;;
    *)     trap 'echo "watch interrupted: tearing down"; exec /bin/bash "$SELF" teardown' INT TERM HUP ;;
  esac
  LOCAL_DEADLINE=$(( CREATED + MAXRUN + 300 )); last=""; apifail=0; stale=0; seen=0; absent=0
  while true; do
    # Three outcomes are kept apart: a status was read; the bucket says there is no status object; the fetch
    # failed for some other reason (this machine's network, a storage error), which says nothing about the guest.
    if raw=$($G storage cat "gs://$BUCKET/results/$RUNTAG/status.json" 2>"$OUT/watch_fetch.err"); then
      cur=$(printf '%s' "$raw" | python3 -I -c 'import sys,json
try:
    d=json.load(sys.stdin); print(d["phase"], d["state"], d["elapsed_s"], d["message"])
except Exception: print("unreadable-status unknown 0 -")')
      seen=1; absent=0
    elif grep -qiE 'matched no objects|no urls matched|not found|404' "$OUT/watch_fetch.err"; then
      cur="no-status none 0 -"; absent=$((absent + 1))
    else
      cur="fetch-failed unknown 0 $(head -c 120 "$OUT/watch_fetch.err" | tr '\n' ' ')"; absent=0
    fi
    [ "$cur" = "$last" ] || { echo "$(date +%H:%M:%S) $cur"; last=$cur; }
    state=$(echo "$cur" | awk '{print $2}')
    vm=$(vm_state "$NAME" "$ZONE")
    if [ "$vm" = UNKNOWN ]; then apifail=$((apifail+1)); echo "$(date +%H:%M:%S) Compute API call failed ($apifail in a row); keeping the VM and retrying"; else apifail=0; fi
    if [ "$state" = DONE ] || [ "$state" = FAIL ] || [ "$state" = DEADLINE ] || [ "$state" = BUILD_FAILED ]; then echo "guest reported $state"; break; fi
    if [ "$vm" = GONE ]; then echo "VM no longer exists"; break; fi
    if [ "$vm" = TERMINATED ] || [ "$vm" = STOPPED ] || [ "$vm" = SUSPENDED ]; then echo "VM is $vm"; break; fi
    if [ "$(date +%s)" -ge "$LOCAL_DEADLINE" ]; then echo "LOCAL DEADLINE reached"; break; fi
    # A guest that never reports, or stops reporting, is billing for nothing. The full run's guest uploads a
    # heartbeat every minute. Only a heartbeat that was fetched and is old counts; a failed fetch is this
    # machine's problem, not the guest's.
    # Only if no status has ever been read in this session, the bucket has just said three times running that
    # there is none, and 25 minutes have passed since the VM was created.
    if [ "$seen" = 0 ] && [ "$absent" -ge 3 ] && [ "$(( $(date +%s) - CREATED ))" -gt 1500 ]; then echo "the guest has reported nothing in 25 minutes"; break; fi
    case "$MODE" in full*|kernel-check*|target*)
      hb=$($G storage cat "gs://$BUCKET/results/$RUNTAG/heartbeat" 2>/dev/null | tr -cd '0-9')
      if [ -n "$hb" ] && [ "$(( $(date +%s) - hb ))" -gt 1800 ]; then stale=$((stale + 1)); else stale=0; fi
      if [ "$stale" -ge 3 ]; then echo "the guest's last heartbeat is more than 30 minutes old"; break; fi ;;
    esac
    sleep 45
  done
  trap - INT TERM HUP
  exec /bin/bash "$SELF" teardown
  ;;
teardown)
  spot_state_exists && { spot_teardown; exit $?; }
  [ ! -e "$SPOT_LOCK" ] || spot_lock teardown       # as in old-mode launch
  SPOT=""
  RUNTAG=""; [ -e "$STATE" ] && . "$STATE"
  # A Spot run whose state appeared in the instant since the first line (its very first launch, before any lock
  # file existed): tearing it down is its own teardown's work, under its lock.
  if [ "$SPOT" = 1 ]; then spot_teardown; exit $?; fi
  if [ -n "$RUNTAG" ]; then
    mkdir -p "$OUT/$RUNTAG"; $G storage cp -r "gs://$BUCKET/results/$RUNTAG/*" "$OUT/$RUNTAG/" >/dev/null 2>&1
    echo "results copied to $OUT/$RUNTAG: $(ls "$OUT/$RUNTAG" 2>/dev/null | tr '\n' ' ')"
  fi
  if rows=$($G compute instances list --format='csv[no-heading](name,zone.basename())'); then
    for row in $rows; do n=${row%%,*}; z=${row##*,}; echo "deleting instance $n in $z"; $G compute instances delete "$n" --zone="$z" --delete-disks=all; done
  fi
  if rows=$($G compute disks list --format='csv[no-heading](name,zone.basename())'); then
    for row in $rows; do n=${row%%,*}; z=${row##*,}; echo "deleting leftover disk $n in $z"; $G compute disks delete "$n" --zone="$z"; done
  fi
  # Positive verification: both listings must SUCCEED and be EMPTY before the ledger row is closed.
  vok=1
  left_i=$($G compute instances list --format='value(name,zone.basename(),status)') || vok=0
  left_d=$($G compute disks list --format='value(name,zone.basename(),sizeGb)') || vok=0
  if [ "$vok" != 1 ] || [ -n "$left_i$left_d" ]; then
    echo "TEARDOWN NOT VERIFIED. instances: [$left_i] disks: [$left_d]. Something may still be billing; the ledger row stays OPEN." >&2
    echo "Restore network or gcloud access, then re-run: bash $SELF teardown" >&2
    exit 1
  fi
  echo "verified: no instances and no disks remain in the project"
  [ -n "$RUNTAG" ] && [ "$(open_run)" = "$RUNTAG" ] && close_run "$RUNTAG" "$(date +%s)" "" "$(( ${MAXRUN:-0} + 120 ))"
  if spot_state_exists; then echo "a Spot run was launched meanwhile: its state in $STATE is kept"; else rm -f "$STATE"; fi
  if $G storage ls "gs://$BUCKET/keep/" >/dev/null 2>&1; then
    echo "--- archives of compiled files kept in the bucket (they cost storage until you delete them):"
    $G storage du -s -r "gs://$BUCKET/keep/" 2>/dev/null
  fi
  echo "--- other billable compute resources (should be empty):"
  $G compute addresses list --format='table(name,region.basename(),status)' 2>/dev/null
  $G compute snapshots list --format='table(name,diskSizeGb)' 2>/dev/null
  /bin/bash "$SELF" ledger
  ;;
ledger)
  column -t -s "$(printf '\t')" "$LEDGER"
  echo "estimated spend so far: \$$(spent) of \$$CAP_USD cap (machine-time x $RATE USD/h, rounded up; the bill is authoritative)"
  ;;
*) echo "usage: bash $0 stage | launch <rehearsal|pilot|full-rehearsal|full|full-spot|full-spot-rehearsal|export-check|kernel-check|kernel-check-rehearsal|target|target-rehearsal> | watch | teardown | abandon | ledger"
   echo "  in a Spot run, watch exits 0 when the run is over, 3 when it is paused, and 4 when a rehearsal is over but did not do all its cuts as configured"; exit 2 ;;
esac
