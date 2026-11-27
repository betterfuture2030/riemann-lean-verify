#!/bin/bash
# Tests for the modes `target` and `target-rehearsal` of cloud/gcp/pilot_local.sh: what `launch` refuses, what it
# asks Google for, and that `watch` ends such a run as it ends the others.
#
#   bash scripts/dev/test_target_launcher.sh          (bash 3.2 on macOS, or bash 5; python3 and git needed)
#
# No network and no cloud: a stand-in `gcloud` on PATH records what it is asked and plays a project with at most
# one VM, and a bucket that is a directory. git is the real one, on a scratch repository made from this tree's
# scripts/, cloud/, targets/ and analysis/ with two made-up targets added, so the rule that ties a run to a commit
# is the real rule. The scratch repository has no config.env, so the owner's private settings are never read.
# The guest script itself (target_guest.sh) is only checked for syntax here; scripts/dev/test_target_guest.sh runs
# a copy of it with stand-ins.
# Prints ok or FAIL per check; exits 1 if any check failed. TEST_SCRATCH=<dir> keeps the scratch files there.
REPO=${TEST_REPO:-"$(cd "$(dirname "$0")/../.." && pwd)"}
WORK=${TEST_SCRATCH:-$(mktemp -d "${TMPDIR:-/tmp}/target_launcher_test.XXXXXX")}
mkdir -p "$WORK" || exit 2
WORK=$(cd "$WORK" && pwd -P) || exit 2
PY3=$(command -v python3) || { echo "python3 is needed"; exit 2; }
GIT=$(command -v git) || { echo "git is needed"; exit 2; }
SYSPATH="$(dirname "$PY3"):$(dirname "$GIT"):/usr/bin:/bin:/usr/sbin:/sbin"
STUBS="$WORK/stubs"; R="$WORK/repo"; mkdir -p "$STUBS" "$R" "$WORK/home"
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf 'ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL  %s: %s\n' "$1" "$2"; }
res() { if [ "$2" = 0 ]; then ok "$1"; else bad "$1" "${3:-}"; fi; }   # res <text> <status> [detail]
sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }

# ---- the scratch repository ------------------------------------------------------------------------------------
for d in scripts cloud targets analysis; do cp -R "$REPO/$d" "$R/$d" || exit 2; done
find "$R" \( -name config.env -o -name .private-patterns -o -name __pycache__ -o -name .lake \) -prune -exec rm -rf {} + 2>/dev/null
mkdir -p "$R/targets/fix" "$R/targets/fixbad"
cat > "$R/targets/fix/target.env" <<'EOF'
TGT_SOURCE_KIND=git
TGT_GIT_URL=https://example.invalid/fix
TGT_GIT_COMMIT=0123456789abcdef0123456789abcdef01234567
TGT_ARCHIVE_PREFIX=fix/
TGT_SRC_DIR=src
TGT_RECORDS_DIR=targets/fix/records
TGT_ROOT_MODULE=Main
TGT_THEOREMS="t"
TGT_PRIMARY_THEOREM=t
TGT_STATEMENT_CONST=C
TGT_STATEMENT_CONST_MODULE=M
TGT_SMOKE_TARGETS="A B.C"
EOF
sed 's/^TGT_SMOKE_TARGETS=.*/TGT_SMOKE_TARGETS="A;B"/' "$R/targets/fix/target.env" > "$R/targets/fixbad/target.env"
( cd "$R" && "$GIT" init -q . && "$GIT" add -A && "$GIT" -c user.name=test -c user.email=test@example.com commit -q -m "scratch" ) || { echo "could not make the scratch repository"; exit 2; }
HEAD=$("$GIT" -C "$R" rev-parse HEAD)
L="$R/cloud/gcp/pilot_local.sh"
/bin/bash -n "$L"; res "pilot_local.sh has no syntax error" $?
/bin/bash -n "$R/cloud/gcp/target_guest.sh"; res "target_guest.sh has no syntax error" $?

# ---- the stand-in gcloud ---------------------------------------------------------------------------------------
# State in $FAKE: calls.log (one line per call), bucket/ (the objects), vm (the one VM's "name,zone", if there is
# one), sent_guest.sh (the startup script of the last create). cp_fail makes an upload fail.
cat > "$STUBS/gcloud" <<'EOF'
#!/bin/bash
{ printf '%q ' "$@"; printf '\n'; } >> "$FAKE/calls.log"
a=(); for x in "$@"; do case "$x" in --project=*|--quiet) ;; *) a+=("$x") ;; esac; done
obj() { printf '%s' "$FAKE/bucket/${1#gs://*/}"; }
case "${a[0]:-} ${a[1]:-} ${a[2]:-}" in
  "compute instances list")
    [ -s "$FAKE/vm" ] || exit 0
    IFS=, read -r n z < "$FAKE/vm"
    case " ${a[*]} " in
      *"csv[no-heading](name,zone.basename())"*) echo "$n,$z" ;;
      *"value(status)"*) echo RUNNING ;;
      *"value(name,zone.basename(),status)"*) echo "$n $z RUNNING" ;;
      *) echo "$n" ;;
    esac ;;
  "compute instances create")
    z=""; for x in "${a[@]}"; do case "$x" in --zone=*) z=${x#--zone=} ;; --metadata-from-file=startup-script=*) cp "${x#--metadata-from-file=startup-script=}" "$FAKE/sent_guest.sh" ;; esac; done
    echo "${a[3]},$z" > "$FAKE/vm" ;;
  "compute instances delete") rm -f "$FAKE/vm" ;;
  "compute disks list"|"compute addresses list"|"compute snapshots list") ;;
  "storage cp "*)
    if [ "${a[2]}" = -r ]; then
      src=$(obj "${a[3]%/\*}"); [ -d "$src" ] || exit 1; cp -R "$src/." "${a[4]}"
    else
      [ ! -e "$FAKE/cp_fail" ] || { echo "ERROR: upload refused" >&2; exit 1; }
      d=$(obj "${a[3]}"); mkdir -p "$(dirname "$d")" && cp "${a[2]}" "$d"
    fi ;;
  "storage cat "*) f=$(obj "${a[2]}"); [ -f "$f" ] || { echo "ERROR: (gcloud.storage.cat) The following URLs matched no objects" >&2; exit 1; }; cat "$f" ;;
  "storage ls "*) f=$(obj "${a[2]}"); [ -e "$f" ] || exit 1 ;;
  *) ;;
esac
exit 0
EOF
chmod +x "$STUBS/gcloud"

# run <n> [VAR=value ...] -- <launcher arguments>: one launcher command in the world $WORK/w<n>; output in out<n>.
# Each world starts with an empty ledger, which the target modes refuse unless GCP_NEW_LEDGER is set: it is set
# here, and emptied (GCP_NEW_LEDGER=) in the checks of that refusal.
run() {
  local n=$1; shift; local envs=()
  while [ "$1" != -- ]; do envs+=("$1"); shift; done; shift
  FAKE="$WORK/w$n"; mkdir -p "$FAKE/bucket" "$FAKE/work"
  env -i PATH="$STUBS:$SYSPATH" HOME="$WORK/home" FAKE="$FAKE" RH_WORKDIR="$FAKE/work" GCP_PROJECT=proj GCP_BUCKET=bkt \
    GCP_SPEND_CAP_USD=100 GCP_ZONES="zone-a zone-b" PILOT_CAFFEINATED=1 GCP_NEW_LEDGER=1 "${envs[@]}" /bin/bash "$L" "$@" > "$WORK/out$n" 2>&1
}
creates() { local n; n=$(grep -c 'compute instances create' "$WORK/w$1/calls.log" 2>/dev/null); echo "${n:-0}"; }
rows()    { awk 'NR > 1' "$WORK/w$1/work/analysis/pilot_ledger.tsv" 2>/dev/null | wc -l | tr -d ' '; }
# refused <n> <text> <words of the message>: the command failed, said so, created nothing and left no ledger row.
refused() {
  local rc=$?
  if [ "$rc" != 0 ] && grep -q -- "$3" "$WORK/out$1" && [ "$(creates "$1")" = 0 ] && [ "$(rows "$1")" = 0 ]; then ok "$2"
  else bad "$2" "status $rc, creates $(creates "$1"), ledger rows $(rows "$1"): $(tail -n 2 "$WORK/out$1" | tr '\n' ' ' | cut -c1-300)"; fi
}
created() { grep 'compute instances create' "$WORK/w$1/calls.log" | tail -n 1; }
has() { case "$(created "$1")" in *"$2"*) return 0 ;; esac; return 1; }   # has <n> <text in the create call>

# ---- what launch refuses ---------------------------------------------------------------------------------------
run 1 -- launch target;                                   refused 1 "launch target with no GCP_TARGET is refused" "set GCP_TARGET"
run 2 GCP_TARGET=alpoge-rh -- launch target;              refused 2 "...and with the default target" "other than the default one"
run 3 GCP_TARGET=nosuch -- launch target;                 refused 3 "...and with a target the commit has no profile for" "has no targets/nosuch/target.env"
run 4 GCP_TARGET=Bad_Name -- launch target;               refused 4 "...and with a name that is not a target's" "is not the name of a target"
run 5 GCP_TARGET=fix GCP_SPEND_CAP_USD=1 -- launch target; refused 5 "...and when its worst case would pass the cap" "REFUSED"
run 6 GCP_TARGET=fix GCP_TARGET_MAX_HOURS=x -- launch target; refused 6 "...and with GCP_TARGET_MAX_HOURS that is not a number" "GCP_TARGET_MAX_HOURS"
run 7 GCP_TARGET=fix GCP_TARGET_AXIOMS=none -- launch target; refused 7 "...and with GCP_TARGET_AXIOMS other than deep or full" "GCP_TARGET_AXIOMS"
mkdir -p "$WORK/w8"; : > "$WORK/w8/cp_fail"
run 8 GCP_TARGET=fix -- launch target;                    refused 8 "...and when the archive of the repository's files cannot be uploaded" "could not upload"
run 9 GCP_TARGET=fixbad -- launch target-rehearsal;       refused 9 "launch target-rehearsal is refused when the profile's smoke targets are not plain module names" "TGT_SMOKE_TARGETS"
run 10 RH_TARGET=fix GCP_TARGET=fix -- launch target;     refused 10 "RH_TARGET naming another target still stops the controller, which now points to GCP_TARGET" "name the target with GCP_TARGET"
: > "$R/targets/fix/untracked.txt"
run 11 GCP_TARGET=fix -- launch target;                   refused 11 "launch target is refused while targets/ has an untracked file" "tied to a commit"
rm -f "$R/targets/fix/untracked.txt"
echo "# changed" >> "$R/scripts/lib.sh"
run 12 GCP_TARGET=fix -- launch target;                   refused 12 "...and while scripts/ has an uncommitted change" "tied to a commit"
"$GIT" -C "$R" checkout -q -- scripts/lib.sh
run 13 GCP_TARGET=fix GCP_NEW_LEDGER= -- launch target
refused 13 "launch target is refused when the ledger has no run in it and GCP_NEW_LEDGER is not set (spend would be counted from 0)" "has no run in it"
[ ! -e "$WORK/w13/bucket/inputs" ]; res "...before anything is uploaded" $? "$(ls "$WORK/w13/bucket" 2>&1 | tr '\n' ' ')"
run 14 GCP_TARGET=fix GCP_TARGET_MAX_HOURS=0 -- launch target;  refused 14 "launch target is refused with GCP_TARGET_MAX_HOURS=0" "GCP_TARGET_MAX_HOURS"
run 15 GCP_TARGET=fix GCP_TARGET_MAX_HOURS=08 -- launch target; refused 15 "...and with a leading zero (08), which the shell would read as octal" "without a leading zero"
run 16 GCP_TARGET=fix GCP_TARGET_RATE=abc -- launch target;     refused 16 "...and with a rate that is not a number" "the rate for this machine"
run 17 GCP_TARGET=fix GCP_TARGET_RATE=0 -- launch target;       refused 17 "...or is zero" "the rate for this machine"
run 18 GCP_TARGET=fix GCP_TARGET_MACHINE=n4d-standard-32 -- launch target; refused 18 "...and with a machine named without its rate" "without GCP_TARGET_RATE"
run 19 GCP_TARGET=fix GCP_TARGET_REHEARSAL_ALSO='X;Y' -- launch target-rehearsal; refused 19 "launch target-rehearsal is refused when GCP_TARGET_REHEARSAL_ALSO is not plain module names" "GCP_TARGET_REHEARSAL_ALSO"
run 23 GCP_TARGET=fix GCP_TARGET_REHEARSAL_PROBE=OnlyOne -- launch target-rehearsal; refused 23 "...and when the probe lemma is not given as a module and a lemma" "<module> <lemma>"
run 24 GCP_TARGET=fix GCP_TARGET_REHEARSAL_MACHINE=n4d-standard-16 -- launch target-rehearsal; refused 24 "...and with its machine named without its rate" "without GCP_TARGET_REHEARSAL_RATE"
run 27 GCP_TARGET=fix GCP_TARGET_REHEARSAL_RATE=abc -- launch target-rehearsal; refused 27 "...and with a rate that is not a number" "the rate for this machine"
run 28 GCP_TARGET=fix GCP_TARGET_REHEARSAL_PROBE='P.Q some;lemma' -- launch target-rehearsal; refused 28 "...and with a probe lemma that is not plain names" "both plain names"
run 29 GCP_TARGET=fix GCP_TARGET_REHEARSAL_PROBE='A ' -- launch target-rehearsal; refused 29 "...or that names a module and no lemma" "<module> <lemma>"

# ---- launch target ---------------------------------------------------------------------------------------------
run 20 GCP_TARGET=fix -- launch target; rc=$?
[ "$rc" = 0 ] && [ "$(creates 20)" = 1 ] && grep -q '^CREATED lean-target in zone-a' "$WORK/out20"
res "launch target creates exactly one VM, in the first zone" $? "status $rc: $(tail -n 2 "$WORK/out20" | tr '\n' ' ' | cut -c1-300)"
has 20 "--machine-type=n4d-standard-16" && has 20 "--provisioning-model=STANDARD" && has 20 "--max-run-duration=21600s" && has 20 "--instance-termination-action=DELETE"
res "...a 16-vCPU machine on demand that Google deletes at 6 hours" $? "$(created 20 | cut -c1-400)"
has 20 "pilot-mode=target" && has 20 "pilot-deadline-min=330" && has 20 "target-name=fix" && has 20 "target-axioms=deep" && has 20 "target-replay-args=--c3" && has 20 "pilot-bucket=bkt"
res "...told its mode, its target, a deadline half an hour before that, the --deep axiom walk and the replay of every module" $? "$(created 20 | cut -c1-600)"
A="$WORK/w20/bucket/inputs/target/rhv-$HEAD.tar.gz"
[ -f "$A" ] && has 20 "target-repo-object=inputs/target/rhv-$HEAD.tar.gz" && has 20 "target-repo-sha=$(sha "$A")" && has 20 "full-tools-commit=$HEAD"
res "...and the commit, the bucket object of the archive made from it and that archive's SHA-256" $? "$(ls "$WORK/w20/bucket/inputs/target" 2>&1)"
tar -tzf "$A" > "$WORK/a20.list" 2>/dev/null
grep -qx 'rhv/scripts/lib.sh' "$WORK/a20.list" && grep -qx 'rhv/targets/fix/target.env' "$WORK/a20.list" && grep -qx 'rhv/analysis/import_graph.py' "$WORK/a20.list" \
  && ! grep -v -E '^rhv/((scripts|targets|analysis)(/.*)?)?$' "$WORK/a20.list" | grep -q . && ! grep -q 'config\.env' "$WORK/a20.list"
res "the archive holds scripts/, targets/ and analysis/ of the commit and nothing else" $? "$(grep -v -E '^rhv/((scripts|targets|analysis)(/.*)?)?$' "$WORK/a20.list" | head -n 3 | tr '\n' ' ')"
"$GIT" -C "$R" show HEAD:cloud/gcp/target_guest.sh > "$WORK/head_guest.sh"
cmp -s "$WORK/head_guest.sh" "$WORK/w20/sent_guest.sh" && has 20 "full-guest-sha=$(sha "$WORK/head_guest.sh")"
res "the startup script sent is the commit's target_guest.sh, and its SHA-256 is in the metadata" $?
row=$(awk -F'\t' 'NR == 2 {print $2 "|" $3 "|" $4 "|" $5 "|" $7}' "$WORK/w20/work/analysis/pilot_ledger.tsv")
[ "$(rows 20)" = 1 ] && [ "$row" = "target|n4d-standard-16|0.75|zone-a|" ]
res "the ledger has one open row for it: mode target, the machine, 0.75 USD an hour, the zone" $? "$row"
grep -q 'worst case \$4.53' "$WORK/out20"; res "the worst case it was checked against the cap with is 6 hours and 2 minutes at that rate, and a cent (4.53 USD)" $? "$(grep 'worst case' "$WORK/out20")"
run 20 GCP_TARGET=fix -- launch target; rc=$?
[ "$rc" != 0 ] && [ "$(creates 20)" = 1 ] && grep -q 'still open in the ledger' "$WORK/out20"
res "a second launch while that row is open is refused" $? "status $rc: $(tail -n 1 "$WORK/out20" | cut -c1-200)"

# ---- watch ends it ---------------------------------------------------------------------------------------------
RT=$(awk -F'\t' 'NR == 2 {print $1}' "$WORK/w20/work/analysis/pilot_ledger.tsv")
mkdir -p "$WORK/w20/bucket/results/$RT/logs"
printf '{"phase": "gather", "state": "DONE", "elapsed_s": 5, "message": "every step ended with status 0"}' > "$WORK/w20/bucket/results/$RT/status.json"
echo '{"state": "DONE"}' > "$WORK/w20/bucket/results/$RT/target_facts.json"; echo x > "$WORK/w20/bucket/results/$RT/logs/04_setup.log"
run 20 -- watch; rc=$?
[ "$rc" = 0 ] && grep -q 'guest reported DONE' "$WORK/out20" && grep -q 'verified: no instances and no disks remain' "$WORK/out20" && [ ! -e "$WORK/w20/vm" ]
res "watch sees the guest's final state, deletes the VM and verifies that nothing is left" $? "status $rc: $(tail -n 3 "$WORK/out20" | tr '\n' ' ' | cut -c1-300)"
[ -f "$WORK/w20/work/analysis/pilot/$RT/target_facts.json" ] && [ -f "$WORK/w20/work/analysis/pilot/$RT/logs/04_setup.log" ]
res "...having first copied the run's results from the bucket" $? "$(ls "$WORK/w20/work/analysis/pilot/$RT" 2>&1 | tr '\n' ' ')"
row=$(awk -F'\t' 'NR == 2 {print ($7 != "") "|" ($9 != "")}' "$WORK/w20/work/analysis/pilot_ledger.tsv")
[ "$row" = "1|1" ] && [ ! -e "$WORK/w20/work/analysis/pilot_state.env" ]
res "...and closes the ledger row with a cost" $? "$row"
run 20 GCP_TARGET=fix GCP_NEW_LEDGER= -- launch target-rehearsal; rc=$?
[ "$rc" = 0 ] && [ "$(creates 20)" = 2 ] && grep -q 'worst case \$\.52' "$WORK/out20"
res "with a run in the ledger a launch needs no GCP_NEW_LEDGER; a rehearsal's worst case is 77 minutes at 0.40 USD an hour, and a cent (0.52 USD)" $? "status $rc: $(grep -E 'worst case|REFUSED|ERROR' "$WORK/out20" | tr '\n' ' ' | cut -c1-300)"

# ---- launch target with other settings, and the rehearsal ------------------------------------------------------
run 21 GCP_TARGET=fix GCP_TARGET_MAX_HOURS=2 GCP_TARGET_AXIOMS=full GCP_TARGET_MACHINE=n4d-standard-8 GCP_TARGET_RATE=0.40 -- launch target; rc=$?
[ "$rc" = 0 ] && has 21 "--max-run-duration=7200s" && has 21 "pilot-deadline-min=90" && has 21 "target-axioms=full" && has 21 "--machine-type=n4d-standard-8" \
  && [ "$(awk -F'\t' 'NR == 2 {print $4}' "$WORK/w21/work/analysis/pilot_ledger.tsv")" = 0.40 ]
res "GCP_TARGET_MAX_HOURS, GCP_TARGET_AXIOMS, GCP_TARGET_MACHINE and GCP_TARGET_RATE change the run time, the deadline, the axiom check, the machine and the ledger's rate" $? "status $rc: $(created 21 | cut -c1-400)"
! has 21 "target-probe=" && ! has 21 "target-build-args="; res "a run in mode target is sent no probe lemma and no build arguments, so that it builds everything" $? "$(created 21 | cut -c1-600)"
run 22 GCP_TARGET=fix -- launch target-rehearsal; rc=$?
[ "$rc" = 0 ] && [ "$(creates 22)" = 1 ] && has 22 "--machine-type=n4d-standard-8" && has 22 "--max-run-duration=4500s" && has 22 "pilot-deadline-min=60" && has 22 "pilot-mode=target-rehearsal"
res "launch target-rehearsal creates one 8-vCPU VM that Google deletes at 75 minutes" $? "status $rc: $(tail -n 2 "$WORK/out22" | tr '\n' ' ' | cut -c1-300)"
has 22 "target-axioms=skip" && has 22 "target-replay-args=--sample\\ 2" && has 22 "target-build-args=+A\\ +B.C\\," && has 22 "target-name=fix" && ! has 22 "target-probe="
res "...told to build the profile's smoke targets only, to leave out the axiom check and to replay a sample of two; with no probe lemma, none is sent" $? "$(created 22 | cut -c1-700)"
[ "$(awk -F'\t' 'NR == 2 {print $2 "|" $4}' "$WORK/w22/work/analysis/pilot_ledger.tsv")" = "target-rehearsal|0.40" ]
res "...with a ledger row at the small machine's rate" $?
run 25 GCP_TARGET=fix GCP_TARGET_REHEARSAL_ALSO="D.E A" GCP_TARGET_REHEARSAL_PROBE="P.Q some_lemma" -- launch target-rehearsal; rc=$?
[ "$rc" = 0 ] && has 25 "target-build-args=+A\\ +B.C\\ +D.E\\ +P.Q\\," && has 25 "target-probe=P.Q\\ some_lemma"
res "GCP_TARGET_REHEARSAL_ALSO adds modules to the rehearsal's build, and GCP_TARGET_REHEARSAL_PROBE a probe lemma whose module is built too, each module named once" $? "status $rc: $(created 25 | cut -c1-700)"
sed 's/^TGT_SMOKE_TARGETS=.*/&\nTGT_PROBE_MODULE=B.C\nTGT_PROBE_THEOREM=c_lemma/' "$R/targets/fix/target.env" > "$R/targets/fix/target.env.new" && mv "$R/targets/fix/target.env.new" "$R/targets/fix/target.env"
( cd "$R" && "$GIT" add -A && "$GIT" -c user.name=test -c user.email=test@example.com commit -q -m "a probe lemma in the profile" ) || { echo "could not commit the profile with a probe"; exit 2; }
run 26 GCP_TARGET=fix -- launch target-rehearsal; rc=$?
[ "$rc" = 0 ] && has 26 "target-build-args=+A\\ +B.C\\," && has 26 "target-probe=B.C\\ c_lemma"
res "with no GCP_TARGET_REHEARSAL_PROBE, the probe lemma is the profile's (TGT_PROBE_MODULE and TGT_PROBE_THEOREM at the commit)" $? "status $rc: $(created 26 | cut -c1-700)"

echo "$PASS passed, $FAIL failed"
[ -n "${TEST_SCRATCH:-}" ] || rm -rf "$WORK"
[ "$FAIL" = 0 ]
