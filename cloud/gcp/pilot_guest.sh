#!/bin/bash
# Calibration pilot, guest side. Runs unattended as the VM's startup script (root, Ubuntu 24.04).
#
# What it does: prepares the machine, fetches the proof tarball and inputs from a private bucket, installs the
# pinned Lean toolchain and Mathlib's prebuilt cache, then runs TIME-BOXED measurement phases of `lake build`
# and of the kernel checker, uploading small result files as it goes. It never builds the whole tree.
#
# How it ends: it does NOT power the machine off. A guest shutdown would clear the VM's scheduled deletion
# (--max-run-duration), leaving its disks billing. Instead it uploads a final status and idles; the local
# `watch` deletes the VM within about a minute, and if nobody is watching, Google deletes it at max-run-duration.
#
# The proof source is untrusted third-party code. It is compiled as the unprivileged user `pilot`, which is
# blocked from the metadata server (so it cannot obtain the VM's credentials) and, once the toolchain and
# Mathlib cache are in place, from all network access.
set -u
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
PD=/var/pilot; mkdir -p "$PD"; chmod 755 "$PD"
exec > >(tee -a "$PD/pilot.log") 2>&1
T0=$(date +%s)

md() { curl -sf -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/attributes/$1" || echo "$2"; }
BUCKET=$(md pilot-bucket "")
MODE=$(md pilot-mode pilot)                 # pilot | rehearsal
NMAX=$(md pilot-nmax 32)                    # largest job count to test
DEADLINE_MIN=$(md pilot-deadline-min 150)   # guest-side deadline, minutes after boot
W_COLD=$(md pilot-w-cold 600)               # seconds: cold whole-tree window
W_SWEEP=$(md pilot-w-sweep 360)             # seconds: each job-count sweep window
W_DEEP_A=$(md pilot-w-deep-a 6000)          # seconds: cap on deep target A
W_DEEP_B=$(md pilot-w-deep-b 0)             # seconds: cap on deep target B (0 = skip)
W_CHECK=$(md pilot-w-check 600)             # seconds: cap on the kernel-checker phase
RESERVE=$(md pilot-reserve 4500)            # seconds kept back after deep B for probe, sweep and checker
SWEEP=$(md pilot-sweep "16 32 16 32 24 8")  # job counts for the sweep, in order
TARGET_A=$(md pilot-target-a "")
TARGET_B=$(md pilot-target-b "")
TARBALL_SHA=$(md pilot-tarball-sha "")
SAMPLER_SHA=$(md pilot-sampler-sha "")
RUNTAG=$(md pilot-runtag run)
DEADLINE=$(( T0 + DEADLINE_MIN * 60 ))
WORK=/mnt/work; PROJ=$WORK/lean; RES="results/$RUNTAG"

now() { date +%s; }
left() { echo $(( DEADLINE - $(now) )); }
say() { echo "### $(date -u +%FT%TZ) +$(( $(now) - T0 ))s  $*"; }
tok() { curl -sf -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token" | python3 -c 'import sys,json; print(json.load(sys.stdin)["access_token"])'; }
enc() { python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1],safe=""))' "$1"; }
gcs_get() { curl -sf --retry 4 --retry-delay 3 -H "Authorization: Bearer $(tok)" "https://storage.googleapis.com/storage/v1/b/$BUCKET/o/$(enc "$1")?alt=media" -o "$2"; }
gcs_put() { [ -e "$1" ] || return 0; curl -sf --retry 4 --retry-delay 3 -X POST -H "Authorization: Bearer $(tok)" -H "Content-Type: application/octet-stream" --data-binary @"$1" "https://storage.googleapis.com/upload/storage/v1/b/$BUCKET/o?uploadType=media&name=$(enc "$2")" -o /dev/null; }
PHASE=boot
status() { # status <phase> <state> <message>
  PHASE=$1
  python3 - "$PD/status.json" "$1" "$2" "${3:-}" "$T0" "$DEADLINE" "$MODE" "$NMAX" <<'PY'
import json, sys, time
p, phase, state, msg, t0, dl, mode, nmax = sys.argv[1:9]
json.dump({"phase": phase, "state": state, "message": msg, "elapsed_s": int(time.time()) - int(t0),
           "deadline_in_s": int(dl) - int(time.time()), "mode": mode, "nmax": int(nmax), "utc": time.strftime("%FT%TZ", time.gmtime())}, open(p, "w"))
PY
  gcs_put "$PD/status.json" "$RES/status.json"
}
sync_results() { # small files only; safe to call often
  local f
  for f in pilot.log modules.tsv system.tsv setup.tsv import_only.tsv import_probe.tsv phases.tsv env.txt check_results.txt disk.txt; do gcs_put "$PD/$f" "$RES/$f"; done
}
stop_build() {
  pkill -TERM -x lake 2>/dev/null; pkill -TERM -x xargs 2>/dev/null; sleep 2
  pkill -KILL -x lean 2>/dev/null; pkill -KILL -x leanchecker 2>/dev/null; pkill -KILL -x lake 2>/dev/null
  local i; for i in 1 2 3 4 5 6 7 8 9 10; do pgrep -x lean >/dev/null || break; sleep 1; done
}
idle_until_deleted() { # stay RUNNING so the scheduled deletion remains armed; make sure nothing of the build survives
  trap '' TERM INT
  while true; do pkill -KILL -u pilot 2>/dev/null; sleep 60; done
}
finish() { # finish <state> <message>   -- the final status is uploaded LAST: it is the watcher's signal to delete this VM
  trap '' TERM INT
  say "FINISH $1: $2"
  stop_build
  [ -n "${SAMPLER_PID:-}" ] && kill "$SAMPLER_PID" 2>/dev/null
  [ -n "${SYNC_PID:-}" ] && kill "$SYNC_PID" 2>/dev/null
  if [ -d "$PROJ/.lake/build" ]; then
    { echo "lib_bytes $(du -sb "$PROJ/.lake/build/lib" 2>/dev/null | cut -f1)"; echo "ir_bytes $(du -sb "$PROJ/.lake/build/ir" 2>/dev/null | cut -f1)"
      echo "oleans $(find "$PROJ/.lake/build/lib" -name '*.olean' 2>/dev/null | wc -l)"
      echo "setup_json_bytes $(find "$PROJ/.lake/build/ir" -name '*.setup.json' -printf '%s\n' 2>/dev/null | awk '{s+=$1} END{print s+0}')"
      echo "setup_json_files $(find "$PROJ/.lake/build/ir" -name '*.setup.json' 2>/dev/null | wc -l)"; df -B1 "$WORK" | tail -1; } > "$PD/disk.txt" 2>&1
    local f; for f in "$PD"/lake_*.log; do [ -e "$f" ] && gzip -f "$f" && gcs_put "$f.gz" "$RES/$(basename "$f").gz"; done
  fi
  pkill -KILL -u pilot 2>/dev/null
  sync_results
  status "$PHASE" "$1" "$2"
  say "idle: waiting to be deleted"; sync
  idle_until_deleted
}
phase_mark() { echo "$1" > "$PD/phase"; printf '%s\t%s\n' "$(now)" "$1" >> "$PD/phases.tsv"; say "PHASE $1"; }
as_pilot() { runuser -l pilot -c "ulimit -n 1048576 2>/dev/null; cd $PROJ && $1"; }
t_step() { # t_step <name> <function>  -- time a setup step; a failed step ends the pilot
  local name=$1; shift; local s; s=$(now); say "setup: $name"
  if "$@"; then printf '%s\t%s\tok\n' "$name" "$(( $(now) - s ))" >> "$PD/setup.tsv"
  else printf '%s\t%s\tFAILED\n' "$name" "$(( $(now) - s ))" >> "$PD/setup.tsv"; finish FAIL "setup step failed: $name"; fi
}
on_signal() { if [ -e "$PD/DEADLINE" ]; then finish DEADLINE "guest deadline reached"; else finish FAIL "unexpected signal"; fi; }

[ -n "$BUCKET" ] || { echo "no bucket in metadata; idling until deleted"; idle_until_deleted; }
# A startup script runs on every boot. Never run the pilot twice on one VM.
if [ -e "$PD/STARTED" ]; then status reboot FAIL "VM restarted; the pilot does not run twice"; idle_until_deleted; fi
date -u +%FT%TZ > "$PD/STARTED"
trap on_signal TERM INT
status boot RUNNING "booted"
( while true; do sleep 60; sync_results; done ) & SYNC_PID=$!
# Deadline watchdog, independent of the phase logic. It unblocks any foreground command, signals the main
# script, and if the main script still has not finished, takes over: stops everything and reports.
MAIN=$$
( while [ "$(left)" -gt 0 ]; do sleep 20; done
  echo "### DEADLINE reached"; touch "$PD/DEADLINE"
  pkill -TERM -x lake; pkill -TERM -x xargs; pkill -TERM -x timeout; sleep 3; kill -TERM "$MAIN"
  sleep 240
  if ! grep -qE '"state": "(DONE|FAIL|DEADLINE)"' "$PD/status.json" 2>/dev/null; then
    echo "### main script did not finish; watchdog taking over"
    pkill -KILL -u pilot; sync_results; status watchdog DEADLINE "main script stuck; watchdog stopped the build"
    while true; do pkill -KILL -u pilot 2>/dev/null; sleep 30; done
  fi ) &

# ---------------------------------------------------------------- Phase 0: setup
phase_mark setup; status setup RUNNING "installing"
{ echo "mode=$MODE nmax=$NMAX deadline_min=$DEADLINE_MIN"; nproc; lscpu | grep -E "Model name|Thread|Core|Socket|NUMA|MHz"; uname -r; free -g | head -2; head -2 /etc/os-release; } > "$PD/env.txt" 2>&1
s_sysctl() { sysctl -w fs.file-max=50000000 vm.max_map_count=1048576 fs.nr_open=2097152 >/dev/null && printf 'pilot soft nofile 1048576\npilot hard nofile 1048576\n' > /etc/security/limits.d/pilot.conf; }
s_pkgs() { apt-get update -qq && apt-get install -y -qq --no-install-recommends git curl xfsprogs mdadm iptables ca-certificates >/dev/null; }
s_disk() {
  mkdir -p "$WORK"
  mapfile -t SSD < <(ls /dev/disk/by-id/google-local-nvme-ssd-* 2>/dev/null)
  if [ -e /dev/disk/by-id/google-pilot-data ]; then      # attached persistent data disk (the planned full-run layout)
    mkfs.xfs -q -f /dev/disk/by-id/google-pilot-data && mount -o noatime /dev/disk/by-id/google-pilot-data "$WORK" || return 1
  elif [ "${#SSD[@]}" -ge 2 ]; then
    mdadm --create /dev/md0 --level=0 --raid-devices="${#SSD[@]}" "${SSD[@]}" --run >/dev/null 2>&1 && mkfs.xfs -q -f /dev/md0 && mount -o noatime,discard /dev/md0 "$WORK" || return 1
  elif [ "${#SSD[@]}" -eq 1 ]; then
    mkfs.xfs -q -f "${SSD[0]}" && mount -o noatime,discard "${SSD[0]}" "$WORK" || return 1
  else
    echo "no data disk found: using the boot disk"
  fi
  echo "work filesystem: $(df -h "$WORK" | tail -1)" >> "$PD/env.txt"
}
s_user() {
  id pilot >/dev/null 2>&1 || useradd -m -s /bin/bash pilot
  chown pilot:pilot "$WORK"
  # The build user must never reach the metadata server (it would hand out the VM's credentials).
  iptables -I OUTPUT 1 -m owner --uid-owner pilot -d 169.254.169.254 -j REJECT || return 1
  if runuser -u pilot -- curl -s -m 4 -o /dev/null -H "Metadata-Flavor: Google" http://169.254.169.254/computeMetadata/v1/instance/id; then echo "pilot user can still reach the metadata server"; return 1; fi
}
s_elan() { runuser -l pilot -c 'curl -sSf https://raw.githubusercontent.com/leanprover/elan/master/elan-init.sh | sh -s -- -y --default-toolchain none >/dev/null 2>&1; grep -q elan ~/.profile || echo "export PATH=\$HOME/.elan/bin:\$PATH" >> ~/.profile; ~/.elan/bin/elan --version'; }
s_source() {
  gcs_get "inputs/lean.tar.gz" "$WORK/lean.tar.gz" || return 1
  local got; got=$(sha256sum "$WORK/lean.tar.gz" | cut -d' ' -f1)
  [ -n "$TARBALL_SHA" ] && [ "$got" = "$TARBALL_SHA" ] || { echo "tarball sha mismatch or no expected value: $got"; return 1; }
  tar -xzf "$WORK/lean.tar.gz" -C "$WORK" && rm -f "$WORK/lean.tar.gz" && chown -R pilot:pilot "$PROJ" || return 1
  gcs_get "inputs/sampler.py" "$PD/sampler.py" || return 1
  got=$(sha256sum "$PD/sampler.py" | cut -d' ' -f1)
  [ -n "$SAMPLER_SHA" ] && [ "$got" = "$SAMPLER_SHA" ] || { echo "sampler sha mismatch or no expected value: $got"; return 1; }
  gcs_get "inputs/nonprefix_modules.txt.gz" "$PD/nonprefix_modules.txt.gz" && gunzip -f "$PD/nonprefix_modules.txt.gz" || return 1
  gcs_get "inputs/probe_modules.txt" "$PD/probe_modules.txt" || : > "$PD/probe_modules.txt"
}
s_cache() { as_pilot "timeout 1500 lake exe cache get > /tmp/cache_get.log 2>&1; rc=\$?; tail -2 /tmp/cache_get.log; exit \$rc"; }
s_smoke() { # proves the toolchain works and the Mathlib cache is accepted (no Mathlib rebuild)
  as_pilot "timeout 900 lake build +Statements > /tmp/smoke.log 2>&1; rc=\$?; tail -3 /tmp/smoke.log; exit \$rc" || return 1
  local n; n=$(grep -cE 'Built Mathlib\.' /tmp/smoke.log)
  [ "$n" -eq 0 ] || { echo "Mathlib was rebuilt ($n modules): cache not accepted"; return 1; }
}
s_lockdown() { # from here on the build user has no network at all
  iptables -A OUTPUT -m owner --uid-owner pilot ! -o lo -j REJECT || return 1
  if runuser -u pilot -- curl -s -m 4 -o /dev/null https://storage.googleapis.com/; then echo "pilot user still has network access"; return 1; fi
}
t_step sysctl s_sysctl
t_step packages s_pkgs
t_step disk s_disk
t_step user s_user
t_step elan s_elan
t_step source s_source
t_step mathlib_cache s_cache
t_step smoke_build s_smoke
t_step lockdown s_lockdown
LEAN_PATH_VALUE=$(as_pilot "lake env printenv LEAN_PATH" | tail -1)
echo "ulimit_n_pilot=$(as_pilot 'ulimit -n' | tail -1) lean=$(as_pilot 'lean --version' | tail -1)" >> "$PD/env.txt"
[ -n "$LEAN_PATH_VALUE" ] || finish FAIL "could not determine LEAN_PATH"
python3 "$PD/sampler.py" "$PD" & SAMPLER_PID=$!
sync_results

# Helper scripts run as the build user.
cat > "$PD/time_lean.sh" <<'EOS'
#!/bin/bash
# usage: time_lean.sh <n> <file.lean>   run n concurrent `lean <file>`; print n, wall, user, sys, failures
n=$1; f=$2; TIMEFORMAT='%R %U %S'; rm -f /tmp/tl.fail
{ time bash -c "for i in \$(seq 1 $n); do ( lean '$f' >/dev/null 2>&1 || echo x >> /tmp/tl.fail ) & done; wait" ; } 2> /tmp/tl.time
read -r real user sys < <(tail -1 /tmp/tl.time)
printf '%s\t%s\t%s\t%s\t%s\n' "$n" "$real" "$user" "$sys" "$( [ -e /tmp/tl.fail ] && wc -l < /tmp/tl.fail || echo 0 )"
EOS
cat > "$PD/check_one.sh" <<'EOS'
#!/bin/bash
leanchecker "$1" >/dev/null 2>&1; echo "$1 $?"
EOS
chmod 755 "$PD/time_lean.sh" "$PD/check_one.sh"

# ---------------------------------------------------------------- Phase 1: import-only scaling (no Lake)
phase_mark import_only; status import_only RUNNING "import-only scaling"
printf 'import Mathlib\n' > "$PROJ/ImportOnly.lean"; chown pilot:pilot "$PROJ/ImportOnly.lean"
printf 'n\twall_s\tuser_s\tsys_s\tfailures\n' > "$PD/import_only.tsv"
for n in 1 1 1 $(echo "$SWEEP" | tr ' ' '\n' | sort -n | uniq | tr '\n' ' '); do
  [ "$n" -le "$NMAX" ] || continue; [ "$(left)" -gt 900 ] || break
  as_pilot "export LEAN_PATH='$LEAN_PATH_VALUE'; bash $PD/time_lean.sh $n ImportOnly.lean" | tail -1 >> "$PD/import_only.tsv"
done
sync_results

run_window() { # run_window <label> <jobs> <seconds> <lake targets or empty>  -- time-boxed build, always stopped at the end
  local label=$1 jobs=$2 secs=$3 targets=${4:-}
  [ "$secs" -gt 0 ] || return 1
  [ "$(left)" -gt $(( secs + 420 )) ] || { say "skip $label: not enough time left ($(left)s)"; return 1; }
  phase_mark "$label:N=$jobs"; status "$label" RUNNING "N=$jobs for up to ${secs}s"
  as_pilot "LEAN_NUM_THREADS=$jobs timeout --signal=TERM $secs lake build $targets > /tmp/lake_$label.log 2>&1; echo rc=\$? >> /tmp/lake_$label.log" &
  wait $!
  stop_build; cp "/tmp/lake_$label.log" "$PD/lake_$label.log" 2>/dev/null
  printf '%s\t%s\t%s\t%s\n' "$(now)" "$label:end" "$(grep -cE '^(✔|⚠) \[[0-9]+/[0-9]+\] Built ' "$PD/lake_$label.log" 2>/dev/null)" "$(grep -c '^✖ ' "$PD/lake_$label.log" 2>/dev/null)" >> "$PD/phases.tsv"
  phase_mark idle; sync_results; return 0
}
probe_imports() { # direct measurement of import cost and checker cost against import-closure size, one process at a time
  [ -s "$PD/probe_modules.txt" ] || return 0
  [ "$(left)" -gt 1500 ] || { say "skip import probe: not enough time left"; return 0; }
  phase_mark "probe:$1"; status probe RUNNING "import and checker probes ($1)"
  [ -e "$PD/import_probe.tsv" ] || printf 'round\tmodule\tkind\twall_s\tuser_s\tsys_s\tfailures\n' > "$PD/import_probe.tsv"
  mkdir -p "$PROJ/.probe"; chown pilot:pilot "$PROJ/.probe"
  local m rel i r
  while read -r m; do
    [ -n "$m" ] || continue
    rel=$(echo "$m" | tr '.' '/')
    [ -e "$PROJ/.lake/build/lib/lean/$rel.olean" ] || continue
    grep -qxF "$m" "$PD/probed.txt" 2>/dev/null && continue
    [ "$(left)" -gt 1200 ] || break
    i=$(echo "$m" | md5sum | cut -c1-10); printf 'import %s\n' "$m" > "$PROJ/.probe/P_$i.lean"; chown pilot:pilot "$PROJ/.probe/P_$i.lean"
    for r in 1 2 3; do
      as_pilot "export LEAN_PATH='$LEAN_PATH_VALUE'; bash $PD/time_lean.sh 1 .probe/P_$i.lean" < /dev/null | tail -1 | awk -v m="$m" -v ro="$1" 'BEGIN{FS=OFS="\t"} {print ro, m, "import", $2, $3, $4, $5}' >> "$PD/import_probe.tsv"
    done
    if grep -qxF "$m" "$PD/nonprefix_modules.txt"; then
      as_pilot "export LEAN_PATH='$LEAN_PATH_VALUE'; TIMEFORMAT='%R %U %S'; { time leanchecker '$m' >/dev/null 2>&1; } 2> /tmp/ck.time; echo \"\$? \$(tail -1 /tmp/ck.time)\"" < /dev/null | tail -1 | awk -v m="$m" -v ro="$1" '{printf "%s\t%s\tchecker\t%s\t%s\t%s\t%s\n", ro, m, $2, $3, $4, $1}' >> "$PD/import_probe.tsv"
    fi
    echo "$m" >> "$PD/probed.txt"
  done < "$PD/probe_modules.txt"
  phase_mark idle; sync_results
}

# ---------------------------------------------------------------- Phase 2: cold whole-tree window at NMAX
run_window cold "$NMAX" "$W_COLD" ""

# ---------------------------------------------------------------- Phase 3: deep targets, then direct probes
[ -n "$TARGET_A" ] && run_window deepA "$NMAX" "$W_DEEP_A" "+$TARGET_A"
probe_imports afterA
if [ -n "$TARGET_B" ] && [ "$W_DEEP_B" -gt 0 ]; then
  capB=$(( $(left) - RESERVE )); [ "$capB" -gt "$W_DEEP_B" ] && capB=$W_DEEP_B
  [ "$capB" -gt 600 ] && run_window deepB "$NMAX" "$capB" "+$TARGET_B"
  probe_imports afterB
fi

# ---------------------------------------------------------------- Phase 4: job-count sweep on the whole tree
i=0; for n in $SWEEP; do i=$((i+1)); [ "$n" -le "$NMAX" ] || continue; run_window "sweep$i" "$n" "$W_SWEEP" "" || break; done

# ---------------------------------------------------------------- Phase 5: kernel checker, one process per module
if [ "$(left)" -gt $(( W_CHECK + 300 )) ]; then
  phase_mark "check:N=$NMAX"; status check RUNNING "kernel checker"
  ( cd "$PROJ/.lake/build/lib/lean" && find . -name '*.olean' | sed -e 's|^\./||' -e 's|\.olean$||' -e 's|/|.|g' | LC_ALL=C sort > "$PD/built.txt" )
  LC_ALL=C sort "$PD/nonprefix_modules.txt" | LC_ALL=C comm -12 - "$PD/built.txt" | python3 -c 'import random,sys; L=sys.stdin.read().split(); random.seed(20261120); random.shuffle(L); print("\n".join(L[:20000]))' > "$PD/check_list.txt"
  chmod 644 "$PD/check_list.txt"
  as_pilot "export LEAN_PATH='$LEAN_PATH_VALUE'; timeout --signal=TERM $W_CHECK xargs -a $PD/check_list.txt -P $NMAX -n 1 $PD/check_one.sh > /tmp/check_results.txt 2>/dev/null; true"
  stop_build; cp /tmp/check_results.txt "$PD/check_results.txt" 2>/dev/null
  printf '%s\t%s\t%s\t%s\n' "$(now)" "check:end" "$(wc -l < "$PD/check_results.txt")" "$(awk '$2!=0' "$PD/check_results.txt" | wc -l)" >> "$PD/phases.tsv"
  phase_mark idle
fi

finish DONE "all phases complete"
