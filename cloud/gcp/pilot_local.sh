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
#                                         docs/cloud-notes.md sections 8 and 9). How long depends on how the
#                                         kernel replay covers the tree, GCP_REPLAY_METHOD in config.env:
#                                           leanchecker  the default and the method PREREGISTRATION.md names.
#                                                        An estimated 63 hours, which does NOT fit the 42-hour
#                                                        limit: the run builds, runs the axiom checks, finds
#                                                        that the replay cannot cover the tree, gives it one
#                                                        hour and ends without a result for criterion C3
#                                                        (about 20 hours).
#                                           rhv-replay   an estimated 24 hours. Counts towards criterion C3
#                                                        only under a dated amendment to PREREGISTRATION.md.
#   watch              follow the run through the bucket, then delete the VM and its disks
#   teardown           delete every VM and disk in the project, verify that nothing billable is left, close the ledger
#   ledger             show recorded machine-time and estimated spend against the cap
#
# Safety design. (1) `launch` refuses to start a VM whose worst case would take recorded spend past GCP_SPEND_CAP_USD,
# and records the run in the ledger BEFORE creating anything. (2) The VM is created with --max-run-duration and
# --instance-termination-action=DELETE, and the guest never powers itself off, so that deletion stays armed even if
# this machine is asleep or offline. (3) `watch` deletes the VM as soon as the guest reports a final state, and
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
[ -n "${GCP_PROJECT:-}" ] || die "set GCP_PROJECT in config.env (see config.example.env)"
[ -n "${GCP_BUCKET:-}" ]  || die "set GCP_BUCKET in config.env (see config.example.env)"
NP=$GCP_PROJECT
BUCKET=$GCP_BUCKET
REGION=${GCP_REGION:-us-central1}
ZONES=${GCP_ZONES:-us-central1-a us-central1-b us-central1-c us-central1-f}
MT=${GCP_MACHINE_TYPE:-n4d-highmem-32}
RATE=${GCP_RATE_USD_PER_HOUR:-2.00}      # machine plus disks, rounded up; used for the ledger and the cap check
CAP_USD=${GCP_SPEND_CAP_USD:-40}
# How a full run covers the tree in the kernel replay: leanchecker (the stock tool, one process a module), or
# rhv-replay (scripts/verify/replay, with the stock tool on a random sample of GCP_STOCK_SAMPLE modules and on
# every prefix module afterwards). See docs/performance-notes.md, section 10.
REPLAY_METHOD=${GCP_REPLAY_METHOD:-leanchecker}
STOCK_SAMPLE=${GCP_STOCK_SAMPLE:-2000}
case "$REPLAY_METHOD" in leanchecker|rhv-replay) ;; *) die "GCP_REPLAY_METHOD must be leanchecker or rhv-replay" ;; esac
case "$STOCK_SAMPLE" in ''|*[!0-9]*) die "GCP_STOCK_SAMPLE must be a number" ;; esac
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
  python3 -I - "$LEDGER" "$1" "$2" "${3:-}" "${4:-0}" <<'PY'
import sys
p, tag, end, zero, cap = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4], int(sys.argv[5] or 0)
rows = [l.rstrip('\n').split('\t') for l in open(p)]
for r in rows[1:]:
    while len(r) < 9: r.append('')
    if r[0] == tag and r[6] == '':
        secs = 0 if zero else max(0, end - int(r[5]))
        if cap: secs = min(secs, cap)      # Google deletes the VM at its maximum run time, however late teardown is
        r[6] = str(end); r[7] = str(secs); r[8] = '%.2f' % (float(r[3]) * secs / 3600)
open(p, 'w').write('\n'.join('\t'.join(r) for r in rows) + '\n')
PY
}
# vm_state <name> <zone>: prints the instance status, GONE if the API positively reports it absent, UNKNOWN if the call failed.
vm_state() {
  local out
  if out=$($G compute instances list --filter="name=$1" --zones="$2" --format='value(status)' 2>>"$OUT/api_errors.log"); then echo "${out:-GONE}"; else echo UNKNOWN; fi
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
  MODE=${2:-}
  case "$MODE" in pilot|rehearsal|full|full-rehearsal) ;; *) die "usage: $0 launch <rehearsal|pilot|full-rehearsal|full>" ;; esac
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
      MD="pilot-nmax=32,full-timebox=0,full-prune-after=3000,full-keep-oleans=${GCP_KEEP_OLEANS:-0},full-replay-method=$REPLAY_METHOD,full-stock-sample=$STOCK_SAMPLE"
    else
      # full-rehearsal: about 35 minutes are expected. The guest stops by 55 min, its watchdog takes over 13 min
      # later at the latest (5 min, and 8 more if the report had begun), and Google deletes the VM at 75 min. The build is boxed at seven minutes, not counting
      # the two restart tests; setup files are pruned every two minutes; and the archive of compiled files is
      # asked for, so that those paths are exercised on a small tree.
      DEADLINE_MIN=55; MAXRUN=4500
      DATA="name=$NAME-data,device-name=pilot-data,type=hyperdisk-balanced,size=100GB,auto-delete=yes"
      MD="pilot-nmax=32,full-timebox=420,full-prune-after=300,full-prune-every=120,full-c2-timeout=900,full-check-trial=16 32,full-check-trial-secs=90,full-final-reserve=300,full-watchdog-wait=300,full-watchdog-finish-wait=480,full-keep-oleans=1,full-keep-min-left=420,full-replay-method=$REPLAY_METHOD,full-stock-sample=150,full-prefix-allow=180,full-c3-short-cap=300"
    fi
    XMD="full-tools-sha=$TSHA,full-tools-commit=$TCOMMIT,full-guest-sha=$(sha256_of "$GUEST_FILE")"
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
  # Refuse to start if the worst case for this VM would break the cap.
  WORST=$(echo "scale=2; $RATE * $MAXRUN / 3600" | bc); SP=$(spent)
  [ "$(echo "$SP + $WORST > $CAP_USD" | bc)" = 0 ] || die "REFUSED: spent \$$SP + worst case \$$WORST would exceed the \$$CAP_USD cap"
  echo "launching $NAME ($MT): worst case \$$WORST, recorded spend so far \$$SP of \$$CAP_USD"
  case "$MODE" in full*) echo "kernel replay of the whole tree by: $REPLAY_METHOD" ;; esac
  if [ "$MODE" = full ] && [ "$REPLAY_METHOD" = leanchecker ]; then
    echo "NOTE: with leanchecker for the whole tree the kernel replay is estimated at about 46 hours, more than this run's"
    echo "      42-hour limit allows after the build. The run will build, run the axiom checks, give the replay one hour"
    echo "      and end without a result for criterion C3. See docs/cloud-notes.md, section 8.5."
  fi
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
watch)
  [ -e "$STATE" ] || die "no run state found; nothing to watch"
  if is_macos && [ -z "${PILOT_CAFFEINATED:-}" ] && command -v caffeinate >/dev/null 2>&1; then
    PILOT_CAFFEINATED=1 exec caffeinate -i /bin/bash "$SELF" watch       # keep this machine awake while watching
  fi
  . "$STATE"
  case "$MODE" in
    full*) trap 'echo; echo "watch stopped. The VM is still running and Google deletes it at its maximum run time ($(( (CREATED + MAXRUN - $(date +%s)) / 60 )) minutes from now)."; echo "To resume: bash $SELF watch     To end the run now and lose what has not been uploaded: bash $SELF teardown"; exit 130' INT TERM HUP ;;
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
    case "$MODE" in full*)
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
  RUNTAG=""; [ -e "$STATE" ] && . "$STATE"
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
  rm -f "$STATE"
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
*) echo "usage: bash $0 stage | launch <rehearsal|pilot|full-rehearsal|full> | watch | teardown | ledger"; exit 2 ;;
esac
