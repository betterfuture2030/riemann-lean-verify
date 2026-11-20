#!/bin/bash
# Calibration pilot, local controller. Run it with bash on your own machine (bash 3.2 or later).
#
#   stage              create the private bucket and upload inputs (storage only; no compute cost)
#   launch <mode>      mode = rehearsal | pilot. Creates exactly one VM, which Google deletes at a fixed maximum run time
#   watch              follow the run through the bucket, then delete the VM and its disks
#   teardown           delete every VM and disk in the project, verify that nothing billable is left, close the ledger
#   ledger             show recorded machine-time and estimated spend against the cap
#
# Safety design. (1) `launch` refuses to start a VM whose worst case would take recorded spend past GCP_SPEND_CAP_USD,
# and records the run in the ledger BEFORE creating anything. (2) The VM is created with --max-run-duration and
# --instance-termination-action=DELETE, and the guest never powers itself off, so that deletion stays armed even if
# this machine is asleep or offline. (3) `watch` deletes the VM as soon as the guest reports a final state.
# (4) `teardown` closes the ledger only after the Compute API has positively confirmed that no VM or disk remains.
#
# Use a project dedicated to this pilot: `teardown` deletes every instance and disk in GCP_PROJECT.
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
close_run() { # close_run <runtag> <end_epoch> [zero]   -- fill in end time, seconds and cost for an open ledger row
  python3 -I - "$LEDGER" "$1" "$2" "${3:-}" <<'PY'
import sys
p, tag, end, zero = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
rows = [l.rstrip('\n').split('\t') for l in open(p)]
for r in rows[1:]:
    while len(r) < 9: r.append('')
    if r[0] == tag and r[6] == '':
        secs = 0 if zero else max(0, end - int(r[5]))
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
  $G storage ls -l "gs://$BUCKET/inputs/"
  ;;
launch)
  MODE=${2:-}; [ "$MODE" = pilot ] || [ "$MODE" = rehearsal ] || die "usage: $0 launch <rehearsal|pilot>"
  [ -z "$(open_run)" ] || die "a run is still open in the ledger: $(open_run). Run teardown first."
  existing=$($G compute instances list --format='value(name)') || die "could not list instances; not launching"
  [ -z "$existing" ] || die "an instance already exists in the project ($existing); refusing to create another"
  RUNTAG="$MODE-$(date +%Y%m%d-%H%M%S)"; NAME="lean-$MODE"
  jget() { python3 -I -c "import json,sys; print(json.load(open('$TARGETS_JSON'))[sys.argv[1]])" "$1"; }
  if [ "$MODE" = pilot ]; then
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
        --labels=purpose=lean-pilot \
        --metadata="pilot-bucket=$BUCKET,pilot-mode=$MODE,pilot-deadline-min=$DEADLINE_MIN,pilot-runtag=$RUNTAG,pilot-tarball-sha=$RH_TARBALL_SHA256,pilot-sampler-sha=$SSHA,pilot-target-a=$TA,pilot-target-b=$TB,$MD" \
        --metadata-from-file=startup-script="$HERE/pilot_guest.sh" 2> "$OUT/create_$RUNTAG.err"; then
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
  trap 'echo "watch interrupted: tearing down"; exec /bin/bash "$SELF" teardown' INT TERM HUP
  LOCAL_DEADLINE=$(( CREATED + MAXRUN + 300 )); last=""; apifail=0
  while true; do
    cur=$($G storage cat "gs://$BUCKET/results/$RUNTAG/status.json" 2>/dev/null | python3 -I -c 'import sys,json
try:
    d=json.load(sys.stdin); print(d["phase"], d["state"], d["elapsed_s"], d["message"])
except Exception: print("no-status none 0 -")')
    [ "$cur" = "$last" ] || { echo "$(date +%H:%M:%S) $cur"; last=$cur; }
    state=$(echo "$cur" | awk '{print $2}')
    vm=$(vm_state "$NAME" "$ZONE")
    if [ "$vm" = UNKNOWN ]; then apifail=$((apifail+1)); echo "$(date +%H:%M:%S) Compute API call failed ($apifail in a row); keeping the VM and retrying"; else apifail=0; fi
    if [ "$state" = DONE ] || [ "$state" = FAIL ] || [ "$state" = DEADLINE ]; then echo "guest reported $state"; break; fi
    if [ "$vm" = GONE ]; then echo "VM no longer exists"; break; fi
    if [ "$vm" = TERMINATED ] || [ "$vm" = STOPPED ] || [ "$vm" = SUSPENDED ]; then echo "VM is $vm"; break; fi
    if [ "$(date +%s)" -ge "$LOCAL_DEADLINE" ]; then echo "LOCAL DEADLINE reached"; break; fi
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
  [ -n "$RUNTAG" ] && [ "$(open_run)" = "$RUNTAG" ] && close_run "$RUNTAG" "$(date +%s)"
  rm -f "$STATE"
  echo "--- other billable compute resources (should be empty):"
  $G compute addresses list --format='table(name,region.basename(),status)' 2>/dev/null
  $G compute snapshots list --format='table(name,diskSizeGb)' 2>/dev/null
  /bin/bash "$SELF" ledger
  ;;
ledger)
  column -t -s "$(printf '\t')" "$LEDGER"
  echo "estimated spend so far: \$$(spent) of \$$CAP_USD cap (machine-time x $RATE USD/h, rounded up; the bill is authoritative)"
  ;;
*) echo "usage: bash $0 stage | launch <rehearsal|pilot> | watch | teardown | ledger"; exit 2 ;;
esac
