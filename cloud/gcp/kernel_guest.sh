#!/bin/bash
# kernel_guest.sh - runs ON the cloud VM as its startup script (as root), in the modes `kernel-check` and
# `kernel-check-rehearsal`.
#
# What it does: gives the exported proof to the checkers that the published record of this formalization used and
# that this repository had not yet run (docs/related-work.md). It compiles nothing of the proof and needs neither
# the source nor the compiled files: its inputs are two text files.
#   1. Fetches the export of the challenge file that an earlier run of export_guest.sh left in the bucket, and the
#      export of the proof: from the bucket if it is kept there, else from the published copy, which is then kept
#      in the bucket. Both are checked against the SHA-256 values that this repository's own export had
#      (records/cloud/export-check/); a file with any other hash ends the run.
#   2. Installs the Lean v4.36.0 toolchain, which carries `lake comparator`, `leanchecker --from-export`,
#      `leanchecker-paranoid` and `nanoda_bin`, and builds con-ron from the commit in the published record.
#   3. Smoke tests, minutes long, before anything expensive: `lake comparator`, in its sandbox, on a three-line
#      challenge and solution, with one wrong solution that it must reject; and every checker on its own on that
#      small solution. If `lake comparator` does not behave as it should there, the long part of the run (it and
#      the paranoid kernel) is not started.
#   4. On the proof, at the same time: nanoda (a kernel written independently, in Rust); con-ron --compare (a Rust
#      port of con-leche; not independent of it); and `lake comparator` in its bubblewrap sandbox, which compares
#      the five statements and the axioms with the challenge and then runs Lean's own kernel over the export.
#      Once that kernel stage is running, Lean's "paranoid" build of the same kernel is started beside it, if the
#      memory is there.
#
# Two things here differ from the published runs, both to make the run affordable, and both are recorded:
#   - MIMALLOC_GENERIC_COLLECT=1000000. The published record shows Lean's kernel taking 48 hours on this export
#     with default settings and 9 with this allocator setting, same binary. `lake comparator` clears the
#     environment of the checkers it starts, so the setting is passed in by naming, as the sandbox program
#     (COMPARATOR_BWRAP), a wrapper that runs the real bwrap with lake's own arguments plus that one variable.
#     The wrapper logs every command line it runs.
#   - The configuration given to `lake comparator` is the community's without its two external kernels. Lake
#     runs kernels one after another; here the paranoid kernel and nanoda run on the same file beside it.
#
# What this is not: a sandboxed build (nothing is built), `lake comparator --paranoid` (the kernels bundled with
# v4.36.0 that it adds cannot read this export, according to the published record), or lean4lean.
#
# The rehearsal runs every step on small stand-ins and fetches, checks and keeps the proof's export without
# unpacking it to disk.
#
# How it ends: it uploads everything, then a final status, and idles. The local `watch` deletes the VM. If nobody
# does within kernel-poweroff-min minutes the machine powers itself off. That ends the charge for the machine, but
# it also cancels Google's deletion at the maximum run time: the stopped VM and its two disks stay, and the disks
# bill (about 1.4 USD a day, outside the ledger), until `watch` or `teardown` is run. A machine still running at
# its maximum run time is deleted by Google. Two watchdogs cover a script that has hung or died: see below.
set -u
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a HOME=/root
PD=/var/pilot; mkdir -p "$PD"; chmod 755 "$PD"
# tee -p: if whatever reads this script's output goes away (the service that runs startup scripts can be stopped
# by systemd when a process of the run is killed for lack of memory), tee keeps writing the log and the script
# is not killed by its next line of output.
exec > >(tee -p -a "$PD/pilot.log") 2>&1
T0=$(date +%s)
MDURL=http://metadata.google.internal/computeMetadata/v1/instance
md() { curl -sf --connect-timeout 5 --max-time 20 -H "Metadata-Flavor: Google" "$MDURL/attributes/$1" || echo "$2"; }
BUCKET=$(md pilot-bucket "")
MODE=$(md pilot-mode kernel-check)
NMAX=$(md pilot-nmax 32)
DEADLINE_MIN=$(md pilot-deadline-min 900)
TOOLS_COMMIT=$(md full-tools-commit unknown)
GUEST_SHA_WANT=$(md full-guest-sha "")
RUNTAG=$(md pilot-runtag run)
KFROM=$(md kernel-export-run "")                 # the export-check run whose hashes are the expected ones
WANT_SOLUTION=$(md kernel-solution-sha "")       # SHA-256 of the proof's export, as that run recorded it
WANT_CHALLENGE=$(md kernel-challenge-sha "")     # SHA-256 of the challenge's export, as that run recorded it
CH_OBJECT=$(md kernel-challenge-object "")       # bucket object: that run's challenge.ndjson.zst
SOL_OBJECT=$(md kernel-solution-object "")       # bucket object where the proof's export is kept, compressed
SOL_URL=$(md kernel-solution-url "https://math.mit.edu/~drew/grh/solution.ndjson.zst")
SOL_ZST_PUBLISHED=$(md kernel-solution-zst-sha 61a8938ad5f5e57397c1c0e3b954916af546d9004ade01c3555744a681b05381)
KERNEL_TC=$(md kernel-toolchain leanprover/lean4:v4.36.0)
CONRON_COMMIT=$(md kernel-con-ron-commit 3f22699b8fd370f97fa9a784f7df7c5decf8e100)
LONG=$(md kernel-long 1)                         # 0: nanoda and con-ron only
POWEROFF_MIN=$(md kernel-poweroff-min 20)
SWAP_GB=$(md kernel-swap-gb 64)
# Peak memory of the two Lean kernels on this export in the published record (kB), and a margin.
DEF_PEAK_KB=$(md kernel-default-peak-kb 86637124)
PAR_PEAK_KB=$(md kernel-paranoid-peak-kb 103614080)
MARGIN_KB=$(md kernel-margin-kb 6291456)
GUEST_SHA=$(curl -sf --connect-timeout 5 --max-time 30 -H "Metadata-Flavor: Google" "$MDURL/attributes/startup-script" | sha256sum | cut -d' ' -f1)
DEADLINE=$(( T0 + DEADLINE_MIN * 60 ))
REHEARSAL=0; [ "$MODE" = kernel-check-rehearsal ] && REHEARSAL=1
WORK=/mnt/work; RES="results/$RUNTAG"; OPT=/opt/kernels
X=$WORK/x        # the two exports and the configurations: written by root, read by everyone
XO=$WORK/out     # the checking user's own directory: the timing files
XC=$WORK/cmp     # the directory `lake comparator` is run from
XT=$WORK/tiny    # the three-line challenge and solutions of the smoke test
TUNE="MIMALLOC_GENERIC_COLLECT=1000000"
KTC=""; HC=""; CONRON=$OPT/con-ron/target/release/con-ron
G_NAN=0; G_RON=0; G_CMP=0; G_PAR=0

now() { date +%s; }
left() { echo $(( DEADLINE - $(now) )); }
say() { echo "### $(date -u +%FT%TZ) +$(( $(now) - T0 ))s  $*"; }
tok() { curl -sf --connect-timeout 5 --max-time 20 -H "Metadata-Flavor: Google" "$MDURL/service-accounts/default/token" | python3 -c 'import sys,json; print(json.load(sys.stdin)["access_token"])'; }
enc() { python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1],safe=""))' "$1"; }
gcs_get() { curl -sf --connect-timeout 20 --speed-limit 1024 --speed-time 120 --retry 4 --retry-delay 3 -H "Authorization: Bearer $(tok)" "https://storage.googleapis.com/storage/v1/b/$BUCKET/o/$(enc "$1")?alt=media" -o "$2"; }
gcs_put() {
  [ -e "$1" ] || return 0
  local i
  for i in 1 2 3 4 5; do
    curl -sf --connect-timeout 20 --speed-limit 1024 --speed-time 120 -X POST -H "Authorization: Bearer $(tok)" -H "Content-Type: application/octet-stream" \
      -T "$1" "https://storage.googleapis.com/upload/storage/v1/b/$BUCKET/o?uploadType=media&name=$(enc "$2")" -o /dev/null && return 0
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
# Every fact is one line "key<TAB>value" in facts.tsv; write_facts turns them into kernel_facts.json.
fact() { printf '%s\t%s\n' "$1" "$2" >> "$PD/facts.tsv"; say "FACT $1 = $2"; }
write_facts() { # write_facts <state> <message>
  python3 - "$PD/facts.tsv" "$PD/kernel_facts.json" "$1" "$2" "$T0" <<'PY'
import json, sys, time
src, out, state, msg, t0 = sys.argv[1:6]
d = {"what": "facts from one run of cloud/gcp/kernel_guest.sh; not a verdict", "state": state, "message": msg,
     "written_utc": time.strftime("%FT%TZ", time.gmtime()), "elapsed_s": int(time.time()) - int(t0), "facts": {}}
try:
    for line in open(src):
        k, _, v = line.rstrip("\n").partition("\t")
        d["facts"][k] = {"true": True, "false": False}.get(v, int(v) if v.lstrip("-").isdigit() else v)
except OSError:
    pass
json.dump(d, open(out, "w"), indent=1, sort_keys=True)
PY
}
sync_small() {
  local f
  for f in pilot.log setup.tsv phases.tsv env.txt facts.tsv; do gcs_put "$PD/$f" "$RES/$f"; done
  for f in "$PD"/logs/* "$XO"/*.time "$XC"/bwrap_calls.log "$XC"/*.json "$X"/*.json; do [ -f "$f" ] && gcs_put "$f" "$RES/logs/$(basename "$f")"; done
  return 0
}
# After the final status nothing is left to do here. The watcher deletes this machine; if it has not within
# POWEROFF_MIN minutes, the machine stops itself, which ends the charge for it (its disks stay until deleted).
idle_until_deleted() {
  trap '' TERM INT; local n=0
  while true; do
    pkill -KILL -u chk 2>/dev/null; gcs_put "$PD/status.json" "$RES/status.json" 2>/dev/null; sleep 60; n=$((n + 1))
    if [ "$n" -ge "$POWEROFF_MIN" ]; then say "nobody has deleted this machine in $POWEROFF_MIN minutes: powering off"; gcs_put "$PD/pilot.log" "$RES/pilot.log"; sync; systemctl poweroff || poweroff -f; sleep 900; fi
  done
}
finish() { # finish <state> <message>   -- the final status is uploaded LAST: it is the watcher's signal to delete this VM
  trap '' TERM INT
  [ -n "${HB_PID:-}" ] && kill "$HB_PID" 2>/dev/null
  say "FINISH $1: $2"; write_facts "$1" "$2"; sync_small; gcs_put "$PD/kernel_facts.json" "$RES/kernel_facts.json"; touch "$PD/FINAL"
  status "$PHASE" "$1" "$2"; idle_until_deleted
}
phase_mark() { PHASE=$1; printf '%s\t%s\n' "$(now)" "$1" >> "$PD/phases.tsv"; say "PHASE $1"; status "$1" RUNNING "${2:-}"; }
t_step() { local name=$1; shift; local s; s=$(now); say "step: $name"
  if "$@"; then printf '%s\t%s\tok\n' "$name" "$(( $(now) - s ))" >> "$PD/setup.tsv"
  else printf '%s\t%s\tFAILED\n' "$name" "$(( $(now) - s ))" >> "$PD/setup.tsv"; finish FAIL "step failed: $name"; fi; }
# A step whose failure costs one checker, not the run.
soft_step() { local name=$1; shift; local s; s=$(now); say "step: $name"
  if "$@"; then printf '%s\t%s\tok\n' "$name" "$(( $(now) - s ))" >> "$PD/setup.tsv"; return 0
  else printf '%s\t%s\tFAILED\n' "$name" "$(( $(now) - s ))" >> "$PD/setup.tsv"; say "step failed (the run goes on): $name"; return 1; fi; }
# A startup script runs at every boot. A second boot of this machine must not start the run again, which would
# write over the first run's facts: it powers off, and the watcher takes a stopped machine as the end.
if [ -e "$PD/STARTED" ]; then say "this VM was restarted: the run does not start twice"; sync; systemctl poweroff; sleep 900; exit 0; fi
date -u +%FT%TZ > "$PD/STARTED"
mkdir -p "$PD/logs" "$PD/run"; : > "$PD/facts.tsv"
trap 'finish FAIL "unexpected signal"' TERM INT
# The guest's own deadline: whatever is running then is stopped and the run reports what it has. And a watchdog:
# if there is still no final state ten minutes later (the script is stuck in a step that is root's, which the
# deadline does not stop), it reports that and powers the machine off.
( sleep $(( DEADLINE_MIN * 60 )); touch "$PD/DEADLINE"; pkill -KILL -u chk 2>/dev/null; sleep 600; [ -e "$PD/FINAL" ] && exit 0
  echo "### watchdog: no final state ten minutes after the deadline" >> "$PD/pilot.log"; sync_small
  status watchdog FAIL "the script had not finished ten minutes after its deadline; see pilot.log"; sleep 120; systemctl poweroff ) &
# A heartbeat every minute, for the watcher; the small files every five. It is the second watchdog: if the main
# script is gone without a final state, it says so and powers the machine off.
( n=0; while kill -0 $$ 2>/dev/null; do date +%s > "$PD/heartbeat"; gcs_put "$PD/heartbeat" "$RES/heartbeat" 2>/dev/null; n=$((n + 1)); [ $(( n % 5 )) = 0 ] && sync_small; sleep 60; done
  [ -e "$PD/FINAL" ] && exit 0
  echo "### the main script is gone without a final state" >> "$PD/pilot.log"; sync_small
  status gone FAIL "the main script ended without a final state; see pilot.log"; sleep 120; systemctl poweroff ) & HB_PID=$!

phase_mark setup "installing"
{ echo "mode=$MODE nmax=$NMAX deadline_min=$DEADLINE_MIN tools_commit=$TOOLS_COMMIT guest_sha256=$GUEST_SHA export_run=$KFROM long=$LONG"; nproc; lscpu | grep -E "Model name|Thread|Core|Socket"; uname -r; free -g | head -2; head -2 /etc/os-release; systemctl show google-startup-scripts.service -p ExecStart -p KillMode -p OOMPolicy 2>&1 | cut -c1-300; } > "$PD/env.txt" 2>&1
[ -n "$BUCKET" ] && [ -n "$WANT_SOLUTION" ] && [ -n "$WANT_CHALLENGE" ] && [ -n "$CH_OBJECT" ] && [ -n "$SOL_OBJECT" ] || finish FAIL "metadata is incomplete"
[ -z "$GUEST_SHA_WANT" ] || [ "$GUEST_SHA" = "$GUEST_SHA_WANT" ] || finish FAIL "this script is not the one the controller sent"
fact guest_script_is_the_one_sent true; fact tools_commit "$TOOLS_COMMIT"; fact mode "$MODE"; fact export_run "$KFROM"

# The checking user: no network, and nothing it can write but its own directories.
as_chk() { runuser -u chk -- env -i HOME="$HC" LANG=C.UTF-8 PATH="$KTC/bin:/usr/bin:/bin" bash -c "$1"; }
# The command line every checker is run with, as the checking user: no core dumps, timed by GNU time into
# $XO/<label>.time, stopped after <seconds>.   kcmd <label> <seconds> <directory> <environment> <command>
kcmd() { runuser -u chk -- env -i HOME="$HC" LANG=C.UTF-8 PATH="$KTC/bin:/usr/bin:/bin" LEAN_ABORT_ON_PANIC=1 $4 bash -c "ulimit -c 0; cd $3 && exec /usr/bin/time -v -o $XO/$1.time timeout -k 30 $2 $5" > "$PD/logs/$1.out" 2> "$PD/logs/$1.err"; }
# runk: in the foreground. Records exit status and seconds as facts and returns the exit status.
runk() { local t0 rc; t0=$(now); rm -f "$XO/$1.time"
  kcmd "$@"; rc=$?
  fact "${1}_exit_status" "$rc"; fact "${1}_seconds" "$(( $(now) - t0 ))"; return "$rc"; }
# launch: in the background. $PD/run/<label>.rc appears, holding "<exit status> <seconds>", when it has ended.
launch() { local l=$1
  rm -f "$PD/run/$l.rc" "$XO/$l.time"; date +%s > "$PD/run/$l.started"
  ( t0=$(now); kcmd "$@"; rc=$?; echo "$rc $(( $(now) - t0 ))" > "$PD/run/$l.rc.tmp"; mv "$PD/run/$l.rc.tmp" "$PD/run/$l.rc" ) &
  say "started $l: $5"; }
started() { [ -e "$PD/run/$1.started" ]; }
ended() { [ -e "$PD/run/$1.rc" ]; }
running() { started "$1" && ! ended "$1"; }
max_rss() { awk '/Maximum resident set size/ {print $NF}' "$XO/$1.time" 2>/dev/null | tail -n 1; }
rss_kb() { awk '/^VmRSS:|^VmSwap:/ {s += $2} END {if (NR) print s + 0}' "/proc/$1/status" 2>/dev/null; }   # in memory and in swap
env_tuned() { tr '\0' '\n' < "/proc/$1/environ" 2>/dev/null | grep -qx "$TUNE"; }
env_readable() { [ -n "$(tr '\0' '\n' < "/proc/$1/environ" 2>/dev/null | head -c 1)" ]; }

s_sysctl() { sysctl -w vm.swappiness=10 >/dev/null; sysctl -w kernel.apparmor_restrict_unprivileged_userns=0 > "$PD/logs/sysctl.log" 2>&1; return 0; }
s_pkgs() { apt-get update -qq && apt-get install -y -qq --no-install-recommends git curl xfsprogs iptables ca-certificates zstd build-essential bubblewrap time procps python3 >/dev/null; }
s_disk() { mkdir -p "$WORK"; [ -e /dev/disk/by-id/google-pilot-data ] || return 1; mkfs.xfs -q -f /dev/disk/by-id/google-pilot-data && mount -o noatime /dev/disk/by-id/google-pilot-data "$WORK"; }
s_users() {
  useradd -m -s /bin/bash chk || return 1
  printf 'chk\n' >> /etc/cron.deny
  HC=$(getent passwd chk | cut -d: -f6); [ -d "$HC" ] || return 1
  mkdir -p "$X" "$XO" "$XC" "$XT" && chmod 755 "$WORK" "$X" && chown chk:chk "$XO" "$XC" "$XT" || return 1
  iptables -I OUTPUT 1 -m owner --uid-owner chk -d 169.254.169.254 -j REJECT && iptables -A OUTPUT -m owner --uid-owner chk ! -o lo -j REJECT || return 1
  if runuser -u chk -- curl -s -m 4 -o /dev/null https://storage.googleapis.com/; then echo "user chk still has network access"; return 1; fi
}
# Swap, as a cushion. How much memory `lake comparator`'s own process needs while it parses the 61.6 GB export
# has not been published, and it does that beside nanoda and con-ron; later the two Lean kernels together come
# to about 181 GiB of the 251. Idle pages may then go to disk rather than end a ten-hour run.
s_swap() {
  [ "$SWAP_GB" -gt 0 ] || return 0
  dd if=/dev/zero of="$WORK/swapfile" bs=16M count=$(( SWAP_GB * 64 )) oflag=direct status=none && chmod 600 "$WORK/swapfile" && mkswap -q "$WORK/swapfile" && swapon "$WORK/swapfile"
}
# The Lean toolchain that carries the checkers, installed for root only and readable by everyone.
s_toolchain() {
  export ELAN_HOME=/opt/elan
  curl -sSf --max-time 120 https://raw.githubusercontent.com/leanprover/elan/master/elan-init.sh | timeout 600 sh -s -- -y --no-modify-path --default-toolchain none > "$PD/logs/kernel_toolchain.log" 2>&1 || { tail -3 "$PD/logs/kernel_toolchain.log" | cut -c1-500; return 1; }
  timeout 1800 /opt/elan/bin/elan toolchain install "$KERNEL_TC" >> "$PD/logs/kernel_toolchain.log" 2>&1 || { tail -3 "$PD/logs/kernel_toolchain.log" | cut -c1-500; return 1; }
  KTC=$(/opt/elan/bin/elan run "$KERNEL_TC" lean --print-prefix 2>> "$PD/logs/kernel_toolchain.log" | tail -1)
  [ -n "$KTC" ] && [ -x "$KTC/bin/lean" ] && [ -x "$KTC/bin/lake" ] || { echo "kernel toolchain not found: $KTC"; return 1; }
  chmod -R a+rX,go-w /opt/elan
  "$KTC/bin/lean" --version >> "$PD/env.txt"; ls "$KTC/bin" | tr '\n' ' ' >> "$PD/env.txt"; echo >> "$PD/env.txt"; bwrap --version >> "$PD/env.txt" 2>&1
  fact kernel_toolchain "$KERNEL_TC"; fact lean_version "$("$KTC/bin/lean" --version | head -n 1)"
  local b
  for b in lake leanchecker leanchecker-paranoid nanoda_bin leanexport; do
    if [ -x "$KTC/bin/$b" ]; then fact "sha256_$(echo "$b" | tr '-' '_')" "$(sha256sum "$KTC/bin/$b" | cut -d' ' -f1)"; else fact "sha256_$(echo "$b" | tr '-' '_')" missing; fi
  done
  [ -x "$KTC/bin/leanchecker" ] && [ -x "$KTC/bin/leanexport" ]
}
# The helpers. The wrapper is the one change to how `lake comparator` runs its checkers: see the header.
s_helpers() {
  mkdir -p "$OPT" || return 1
  cat > "$OPT/bwrap-mimalloc" <<'SH'
#!/bin/bash
# Runs the real bwrap with the arguments it was given, plus one: MIMALLOC_GENERIC_COLLECT=1000000 is set inside
# the sandbox. The variable is added just before the "--" that ends bwrap's options, so after its --clearenv.
# Every command line is logged.
a=(); seen=0
for x in "$@"; do
  if [ "$seen" = 0 ] && [ "$x" = "--" ]; then a+=(--setenv MIMALLOC_GENERIC_COLLECT 1000000); seen=1; fi
  a+=("$x")
done
{ printf '%s' "$(/usr/bin/date -u +%FT%TZ)"; printf ' %q' /usr/bin/bwrap "${a[@]}"; printf '\n'; } >> __LOG__ 2>/dev/null
exec /usr/bin/bwrap "${a[@]}"
SH
  sed -i "s|__LOG__|$XC/bwrap_calls.log|" "$OPT/bwrap-mimalloc" || return 1
  # A stand-in "kernel" for the smoke test: accepts if, and only if, the allocator setting reached the sandbox.
  printf '#!/bin/sh\n[ "${MIMALLOC_GENERIC_COLLECT:-}" = 1000000 ] && exit 0\nexit 7\n' > "$OPT/envprobe.sh"
  cat > "$OPT/hc.py" <<'PY'
# Reads standard input to its end; prints its SHA-256 and its length. With an argument, also writes it there.
import hashlib, sys
h = hashlib.sha256(); n = 0
out = open(sys.argv[1], "wb") if len(sys.argv) > 1 else None
while True:
    b = sys.stdin.buffer.read(1 << 24)
    if not b: break
    h.update(b); n += len(b)
    if out: out.write(b)
if out: out.close()
print(h.hexdigest(), n)
PY
  chmod 755 "$OPT" "$OPT/bwrap-mimalloc" "$OPT/envprobe.sh" && chmod 644 "$OPT/hc.py" && [ -x /usr/bin/bwrap ] && [ -x /usr/bin/time ]
}
# con-ron, from the commit in the published record, built by root with a current stable Rust.
s_conron() {
  export RUSTUP_HOME=/opt/rust/rustup CARGO_HOME=/opt/rust/cargo
  curl --proto '=https' --tlsv1.2 -sSf --max-time 120 https://sh.rustup.rs | timeout 900 sh -s -- -y --profile minimal --default-toolchain stable --no-modify-path > "$PD/logs/con_ron_build.log" 2>&1 || { tail -3 "$PD/logs/con_ron_build.log" | cut -c1-500; return 1; }
  fact rustc_version "$(/opt/rust/cargo/bin/rustc --version 2>/dev/null)"
  cd "$OPT" && timeout 600 git clone -q https://github.com/leanprover/con-ron && cd con-ron && git checkout -q "$CONRON_COMMIT" || return 1
  fact con_ron_commit "$(git rev-parse HEAD)"
  PATH="/opt/rust/cargo/bin:$PATH" timeout 2400 /opt/rust/cargo/bin/cargo build --release >> "$PD/logs/con_ron_build.log" 2>&1 || { tail -5 "$PD/logs/con_ron_build.log" | cut -c1-500; return 1; }
  [ -x "$CONRON" ] || return 1
  chmod -R a+rX,go-w "$OPT/con-ron"
  fact con_ron_binary_sha256 "$(sha256sum "$CONRON" | cut -d' ' -f1)"
  "$CONRON" --help > "$PD/logs/con_ron_help.txt" 2>&1 || return 1
  fact con_ron_help_last_line "$(tail -n 1 "$PD/logs/con_ron_help.txt")"
}

t_step sysctl s_sysctl; t_step packages s_pkgs; t_step disk s_disk; t_step users s_users
( s_swap; echo $? > "$PD/run/swap.rc" ) &
t_step toolchain s_toolchain; t_step helpers s_helpers
( soft_step con_ron_build s_conron; echo $? > "$PD/run/con_ron_build.rc" ) > "$PD/logs/con_ron_step.log" 2>&1 &

# ---------------------------------------------------------------- the two exports
phase_mark inputs "fetching the two exports and checking their hashes"
# hashed <command that writes the file's bytes to standard output> [<file to write them to>]: prints "sha256 bytes".
s_challenge() {
  local r
  gcs_get "$CH_OBJECT" "$WORK/challenge.ndjson.zst" || { echo "could not fetch $CH_OBJECT"; return 1; }
  r=$(set -o pipefail; zstd -dc --long=27 "$WORK/challenge.ndjson.zst" | python3 "$OPT/hc.py" "$X/challenge.ndjson") || { echo "could not unpack the challenge export"; return 1; }
  fact challenge_sha256 "${r%% *}"; fact challenge_bytes "${r##* }"; fact challenge_sha256_expected "$WANT_CHALLENGE"
  if [ "${r%% *}" = "$WANT_CHALLENGE" ]; then fact challenge_is_the_export_checked_before true; else fact challenge_is_the_export_checked_before false; return 1; fi
  chmod 644 "$X/challenge.ndjson"
}
s_solution() {
  local z=$WORK/solution.ndjson.zst src=bucket r zs t0; t0=$(now)
  if ! gcs_get "$SOL_OBJECT" "$z"; then
    rm -f "$z"; src=published_copy
    say "the proof's export is not in the bucket yet: fetching the published copy"
    # Each attempt is a new curl, so that -C - carries on from the bytes already on disk (within one curl, a
    # retry starts again from nothing). The hash check below guards the result.
    local i got=0; : > "$PD/logs/solution_fetch.err"
    for i in 1 2 3 4 5 6 7 8 9; do
      curl -sSfL -C - --connect-timeout 30 --speed-limit 100000 --speed-time 180 --max-time 3000 -o "$z" "$SOL_URL" 2>> "$PD/logs/solution_fetch.err" && { got=1; break; }
      [ "$(left)" -gt 1200 ] || break; sleep 15
    done
    fact solution_fetch_attempts "$i"
    [ "$got" = 1 ] || { tail -3 "$PD/logs/solution_fetch.err" | cut -c1-500; return 1; }
  fi
  zs=$(sha256sum "$z" | cut -d' ' -f1)
  fact solution_source "$src"; fact solution_zst_bytes "$(stat -c %s "$z")"; fact solution_zst_sha256 "$zs"; fact solution_fetch_seconds "$(( $(now) - t0 ))"
  if [ "$src" = published_copy ]; then
    fact solution_zst_sha256_published "$SOL_ZST_PUBLISHED"
    if [ "$zs" = "$SOL_ZST_PUBLISHED" ]; then fact solution_zst_matches_published true; else fact solution_zst_matches_published false; fi
  fi
  status inputs RUNNING "unpacking and hashing the proof's export"
  t0=$(now)
  if [ "$REHEARSAL" = 1 ]; then r=$(set -o pipefail; zstd -dc --long=30 "$z" | python3 "$OPT/hc.py") || { echo "could not unpack the proof's export"; return 1; }
  else r=$(set -o pipefail; zstd -dc --long=30 "$z" | python3 "$OPT/hc.py" "$X/solution.ndjson") || { echo "could not unpack the proof's export"; return 1; }; chmod 644 "$X/solution.ndjson"; fi
  fact solution_sha256 "${r%% *}"; fact solution_bytes "${r##* }"; fact solution_sha256_expected "$WANT_SOLUTION"; fact solution_unpack_seconds "$(( $(now) - t0 ))"
  if [ "${r%% *}" = "$WANT_SOLUTION" ]; then fact solution_is_the_export_checked_before true; else fact solution_is_the_export_checked_before false; return 1; fi
  # Keep it. Only a file whose contents have just been shown to be the right ones is put in the bucket.
  if [ "$src" = published_copy ]; then
    printf '{"object": "%s", "zst_sha256": "%s", "zst_bytes": %s, "ndjson_sha256": "%s", "ndjson_bytes": %s, "unpack": "zstd -d --long=30", "fetched_from": "%s", "kept_utc": "%s", "by_run": "%s"}\n' \
      "$SOL_OBJECT" "$zs" "$(stat -c %s "$z")" "${r%% *}" "${r##* }" "$SOL_URL" "$(date -u +%FT%TZ)" "$RUNTAG" > "$PD/solution_kept.json"
    if gcs_put "$z" "$SOL_OBJECT" && gcs_put "$PD/solution_kept.json" "$SOL_OBJECT.json"; then fact solution_kept_in_bucket true; else fact solution_kept_in_bucket false; fi
  else fact solution_kept_in_bucket true; fi
  return 0
}
t_step challenge s_challenge
t_step solution s_solution
sync_small

# ---------------------------------------------------------------- smoke tests
phase_mark smoke "running every checker on a small input first"
TINY_TARGETS="comm propext Quot.sound Classical.choice Quot Quot.mk Quot.lift Quot.ind Nat.add Nat.sub Nat.mul Nat.pow Nat.gcd Nat.div Nat.mod Nat.beq Nat.ble Nat.land Nat.lor Nat.xor Nat.shiftLeft Nat.shiftRight String.ofList Char.ofNat List eagerReduce Nat String String.mk Char optParam autoParam semiOutParam outParam"
# Configuration files, written by root. nanoda_config <file> <export> <threads> <axiom>...
nanoda_config() { python3 - "$@" <<'PY'
import json, sys
out, export, threads = sys.argv[1], sys.argv[2], int(sys.argv[3])
json.dump({"export_file_path": export, "use_stdin": False, "num_threads": threads, "permitted_axioms": sys.argv[4:],
           "unpermitted_axiom_hard_error": False, "nat_extension": True, "string_extension": True,
           "pp_to_stdout": True, "print_success_message": True}, open(out, "w"), indent=1)
PY
}
# comparator_config <file> <challenge module> <solution module> <external kernels: 0|1|0s> <theorem>...
# "0s" is "0" with sorryAx permitted: for the rehearsal, whose stand-in for the solution is the challenge itself.
comparator_config() { python3 - "$@" <<'PY'
import json, sys
out, ch, sol, ext = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
d = {"challenge_module": ch, "solution_module": sol, "theorem_names": sys.argv[5:],
     "permitted_axioms": ["propext", "Quot.sound", "Classical.choice"] + (["sorryAx"] if ext == "0s" else [])}
if ext == "1":
    d["external_kernels"] = {"Lean paranoid": ["leanchecker-paranoid", "--silent", "--from-export"],
                             "nanoda": ["nanoda_bin"], "envprobe": ["/opt/kernels/envprobe.sh"]}
else:
    d["enable_nanoda"] = False
json.dump(d, open(out, "w"), indent=1)
PY
}
s_tiny() {
  printf 'name = "checktest"\nversion = "0.1.0"\n\n[[lean_lib]]\nname = "Solution"\n\n[[lean_lib]]\nname = "Challenge"\n\n[[lean_lib]]\nname = "Wrong"\n' > "$XT/lakefile.toml"
  printf 'theorem comm (n m : Nat) : n + m = m + n := by\n  sorry\n' > "$XT/Challenge.lean"
  printf 'theorem comm (n m : Nat) : n + m = m + n := by\n  grind\n' > "$XT/Solution.lean"
  printf 'theorem comm (n m : Nat) : n + m = n + m := rfl\n' > "$XT/Wrong.lean"
  printf '%s\n' "$KERNEL_TC" > "$XT/lean-toolchain"; printf '%s\n' "$KERNEL_TC" > "$XC/lean-toolchain"
  chown chk:chk "$XT"/* "$XC/lean-toolchain"
  as_chk "cd $XT && timeout 600 lake build Challenge Solution Wrong" > "$PD/logs/tiny_build.log" 2>&1 || { tail -5 "$PD/logs/tiny_build.log"; return 1; }
  local m
  for m in Challenge Solution Wrong; do
    as_chk "cd $XT && timeout 300 lake env leanexport $m -- $TINY_TARGETS > $XT/$m.export" 2>> "$PD/logs/tiny_build.log" || { tail -5 "$PD/logs/tiny_build.log"; return 1; }
    [ -s "$XT/$m.export" ] || return 1
  done
  comparator_config "$XC/tiny.json" Challenge Solution 1 comm && comparator_config "$XC/tiny_plain.json" Challenge Solution 0 comm && chmod 644 "$XC"/*.json
}
# `lake comparator`, in its sandbox, through the wrapper: must accept the right solution, with every kernel
# including the stand-in that tests the allocator setting, and must reject the wrong one for the right reason.
smoke_comparator() {
  local c="$KTC/bin/lake comparator" e="$TUNE COMPARATOR_BWRAP=$OPT/bwrap-mimalloc" ok=1
  [ -x "$KTC/bin/leanchecker-paranoid" ] && [ -x "$KTC/bin/nanoda_bin" ] || { echo "the toolchain lacks a checker this test names"; return 1; }
  runk smoke_comparator 900 "$XC" "$e" "$c --config tiny.json --challenge-from-export $XT/Challenge.export --solution-from-export $XT/Solution.export" || ok=0
  grep -q 'Your solution is okay!' "$PD/logs/smoke_comparator.out" || ok=0
  grep -q 'envprobe kernel accepts the solution' "$PD/logs/smoke_comparator.out" || ok=0
  grep -q 'Lean default kernel accepts the solution' "$PD/logs/smoke_comparator.out" || ok=0
  if [ "$ok" = 1 ]; then fact smoke_comparator_accepts_right_solution true; else fact smoke_comparator_accepts_right_solution false; fi
  runk smoke_comparator_wrong 900 "$XC" "$e" "$c --config tiny.json --challenge-from-export $XT/Challenge.export --solution-from-export $XT/Wrong.export"
  if [ "$?" = 1 ] && cat "$PD/logs/smoke_comparator_wrong.out" "$PD/logs/smoke_comparator_wrong.err" | grep -q 'do not match'; then fact smoke_comparator_rejects_wrong_solution true
  else fact smoke_comparator_rejects_wrong_solution false; ok=0; fi
  # The configuration shape used on the proof: no external kernels.
  runk smoke_comparator_plain 900 "$XC" "$e" "$c --config tiny_plain.json --challenge-from-export $XT/Challenge.export --solution-from-export $XT/Solution.export" || ok=0
  grep -q 'Your solution is okay!' "$PD/logs/smoke_comparator_plain.out" || ok=0
  if grep -q -- '--setenv MIMALLOC_GENERIC_COLLECT 1000000' "$XC/bwrap_calls.log" 2>/dev/null; then fact smoke_wrapper_logged_its_calls true; else fact smoke_wrapper_logged_its_calls false; ok=0; fi
  [ "$ok" = 1 ]
}
# The standalone checkers on the three-line solution's export: seconds each. These do not decide what is run on
# the proof (a checker that fails there costs nothing, since it runs beside the others); they are there to be
# read after a rehearsal.
smoke_small() {
  local ok=1
  nanoda_config "$X/nanoda_smoke.json" "$XT/Solution.export" "$NMAX" propext Classical.choice Quot.sound && chmod 644 "$X/nanoda_smoke.json" || return 1
  if [ -x "$KTC/bin/nanoda_bin" ] && runk smoke_nanoda 600 "$X" "" "$KTC/bin/nanoda_bin $X/nanoda_smoke.json" && grep -Eq '^Checked [1-9][0-9]* declarations with no errors' "$PD/logs/smoke_nanoda.out"; then fact smoke_passed_nanoda true; else fact smoke_passed_nanoda false; ok=0; fi
  if runk smoke_leanchecker 600 "$X" "$TUNE" "$KTC/bin/leanchecker --silent --from-export $XT/Solution.export"; then fact smoke_passed_lean_kernel true; else fact smoke_passed_lean_kernel false; ok=0; fi
  if [ -x "$KTC/bin/leanchecker-paranoid" ] && runk smoke_paranoid 600 "$X" "$TUNE" "$KTC/bin/leanchecker-paranoid --silent --from-export $XT/Solution.export"; then fact smoke_passed_lean_paranoid_kernel true; else fact smoke_passed_lean_paranoid_kernel false; ok=0; fi
  [ "$ok" = 1 ]
}
smoke_conron() {
  if runk smoke_con_ron 600 "$X" "" "$CONRON --verified --jobs=$NMAX $XT/Solution.export"; then fact smoke_passed_con_ron true; else fact smoke_passed_con_ron false; return 1; fi
}
# Rehearsal only: Lean's two kernels on the challenge's export (350 MB; its five theorems are `sorry`, which a
# kernel takes as an axiom). While the first runs, the way the long run will find the kernel that `lake
# comparator` starts, and read its environment, is tried on it.
smoke_challenge() {
  local rc ok=1 pp
  rm -f "$PD/run/probe.txt" "$PD/run/probe.stop"
  ( while [ ! -e "$PD/run/probe.stop" ]; do kp=$(pgrep -u chk -x leanchecker | head -n 1)
      if [ -n "$kp" ] && env_readable "$kp"; then if env_tuned "$kp"; then echo tuned; else echo untuned; fi > "$PD/run/probe.txt"; break; fi
      sleep 0.2; done ) & pp=$!
  runk smoke_leanchecker_challenge 1800 "$X" "$TUNE" "$KTC/bin/leanchecker --silent --from-export $X/challenge.ndjson"; rc=$?
  touch "$PD/run/probe.stop"; wait "$pp" 2>/dev/null
  fact smoke_leanchecker_challenge_max_rss_kb "$(max_rss smoke_leanchecker_challenge)"
  fact smoke_found_the_kernel_process "$([ -s "$PD/run/probe.txt" ] && echo true || echo false)"
  fact smoke_read_the_kernel_environment "$(cat "$PD/run/probe.txt" 2>/dev/null || echo not_read)"
  [ "$rc" = 0 ] && [ "$(cat "$PD/run/probe.txt" 2>/dev/null)" = tuned ] || ok=0
  if [ -x "$KTC/bin/leanchecker-paranoid" ]; then runk smoke_paranoid_challenge 1800 "$X" "$TUNE" "$KTC/bin/leanchecker-paranoid --silent --from-export $X/challenge.ndjson" || ok=0; fi
  [ "$ok" = 1 ]
}

# What decides the long part of the run: `lake comparator`, sandbox and wrapper included, behaving as it should
# on the small pair. Its configuration there names the paranoid kernel, so that is covered by the same test.
soft_step tiny s_tiny && TINY=1 || TINY=0
if [ "$TINY" = 1 ] && soft_step smoke_comparator smoke_comparator; then G_CMP=1; [ -x "$KTC/bin/leanchecker-paranoid" ] && G_PAR=1; fi
[ "$TINY" = 1 ] && soft_step smoke_small smoke_small
[ -x "$KTC/bin/nanoda_bin" ] && G_NAN=1
[ "$REHEARSAL" = 1 ] && soft_step smoke_challenge smoke_challenge
status smoke RUNNING "waiting for con-ron to finish building"
CRW=$(( $(now) + 2700 ))    # cargo has 40 minutes; this wait ends five minutes after that at the latest
while [ ! -e "$PD/run/con_ron_build.rc" ] && [ "$(now)" -lt "$CRW" ] && [ "$(left)" -gt 600 ]; do sleep 5; done
cat "$PD/logs/con_ron_step.log" 2>/dev/null
if [ "$(cat "$PD/run/con_ron_build.rc" 2>/dev/null)" = 0 ]; then G_RON=1; [ "$TINY" = 1 ] && soft_step smoke_con_ron smoke_conron; fi
while [ ! -e "$PD/run/swap.rc" ] && [ "$(left)" -gt 600 ]; do sleep 5; done
fact swap_kb "$(awk '/^SwapTotal:/ {print $2}' /proc/meminfo)"
for g in G_CMP:lake_comparator_and_paranoid_kernel G_NAN:nanoda G_RON:con_ron; do
  v=${g%%:*}; if [ "${!v}" = 1 ]; then fact "will_run_${g##*:}" true; else fact "will_run_${g##*:}" false; fi
done
write_facts RUNNING "smoke tests done"; gcs_put "$PD/kernel_facts.json" "$RES/kernel_facts.json"; sync_small

# ---------------------------------------------------------------- the checkers, on the proof
# In the rehearsal the same code runs on a stand-in: the challenge's export (350 MB) in the place of the proof's,
# with `sorry` permitted as an axiom, so that `lake comparator` compares it with itself and its kernel stage
# lasts long enough for the code below to find that kernel and start the paranoid one beside it. con-ron
# declines any use of `sorry`, so it is given the three-line pair, in the same form of command.
phase_mark kernels "the checkers, on the proof's export"
if [ "$REHEARSAL" = 1 ]; then
  SOLX=$X/challenge.ndjson; AX="propext Classical.choice Quot.sound sorryAx"
  comparator_config "$XC/rehearsal.json" Challenge Challenge 0s riemannHypothesis riemannZeta_eq_zero_re LFunction_ne_zero_of_half_lt_re LFunction_eq_zero_re LFunction_eq_zero_re_of_isPrimitive && chmod 644 "$XC/rehearsal.json" || G_CMP=0
  CMP_ARGS="--config rehearsal.json --challenge-from-export $SOLX --solution-from-export $SOLX"
  RON_ARGS="--jobs=$NMAX --progress=10% --compare -- $XT/Challenge.export $XT/Solution.export"
else
  SOLX=$X/solution.ndjson; AX="propext Classical.choice Quot.sound"
  comparator_config "$XC/rh.json" Challenge Main 0 riemannHypothesis riemannZeta_eq_zero_re LFunction_ne_zero_of_half_lt_re LFunction_eq_zero_re LFunction_eq_zero_re_of_isPrimitive && chmod 644 "$XC/rh.json" || G_CMP=0
  fact comparator_config_sha256 "$(sha256sum "$XC/rh.json" 2>/dev/null | cut -d' ' -f1)"
  CMP_ARGS="--config rh.json --challenge-from-export $X/challenge.ndjson --solution-from-export $SOLX"
  RON_ARGS="--jobs=$NMAX --progress=10% --compare -- $X/challenge.ndjson $SOLX"
fi
# shellcheck disable=SC2086
nanoda_config "$X/nanoda.json" "$SOLX" "$NMAX" $AX && chmod 644 "$X/nanoda.json" || G_NAN=0
fact nanoda_threads "$NMAX"
budget() { local s=$(( $(left) - 600 )); [ "$s" -gt 60 ] && echo "$s" || echo 60; }
# The two short checkers get three hours and one, not the whole run: the paranoid kernel waits for them.
capped() { local s; s=$(budget); [ "$s" -gt "$1" ] && echo "$1" || echo "$s"; }
[ "$G_NAN" = 1 ] && launch nanoda "$(capped 10800)" "$X" "" "$KTC/bin/nanoda_bin $X/nanoda.json"
[ "$G_RON" = 1 ] && launch con_ron "$(capped 3600)" "$X" "" "$CONRON $RON_ARGS"
BW0=$(wc -l < "$XC/bwrap_calls.log" 2>/dev/null || echo 0)
if [ "$LONG" = 1 ] && [ "$G_CMP" = 1 ]; then launch comparator "$(budget)" "$XC" "$TUNE COMPARATOR_BWRAP=$OPT/bwrap-mimalloc" "$KTC/bin/lake comparator $CMP_ARGS"; fi

# The paranoid kernel waits for three things: nanoda and con-ron have ended (memory; the rehearsal, whose inputs
# are small, does not wait for them); `lake comparator` has got as far as starting Lean's kernel, which shows
# that its comparison of statements and axioms passed; and that kernel has the allocator setting, without which
# it would run for two days.
PAR=waiting; PAR_WHY=""; UNTUNED=0; tick=0
if [ "$LONG" != 1 ]; then PAR=skipped; PAR_WHY="the long checkers were not asked for"
elif ! started comparator; then PAR=skipped; PAR_WHY="lake comparator was not started"
elif [ "$G_PAR" != 1 ]; then PAR=skipped; PAR_WHY="its smoke test did not pass"; fi
snapshot() { { echo "== $(date -u +%FT%TZ) +$(( $(now) - T0 ))s"; grep -E '^(MemTotal|MemAvailable|SwapTotal|SwapFree):' /proc/meminfo | tr -s ' ' | tr '\n' ' '; echo; ps -u chk -o pid=,ppid=,etimes=,rss=,time=,comm=,args= 2>/dev/null | cut -c1-260; } >> "$PD/logs/procs.log"; }
describe() { local l m=""
  for l in nanoda con_ron comparator paranoid; do
    if running "$l"; then m="$m $l: running $(( ( $(now) - $(cat "$PD/run/$l.started") ) / 60 )) min;"; elif ended "$l"; then m="$m $l: ended with status $(cut -d' ' -f1 "$PD/run/$l.rc");"; fi
  done
  echo "${m:- nothing running}"; }
while running nanoda || running con_ron || running comparator || running paranoid; do
  sleep "$([ "$REHEARSAL" = 1 ] && echo 3 || echo 30)"; tick=$((tick + 1))
  # What has ended is recorded at once, not only at the end of the run.
  for l in nanoda con_ron comparator paranoid; do
    if ended "$l" && [ ! -e "$PD/run/$l.noted" ]; then touch "$PD/run/$l.noted"
      fact "${l}_exit_status" "$(cut -d' ' -f1 "$PD/run/$l.rc")"; fact "${l}_seconds" "$(cut -d' ' -f2 "$PD/run/$l.rc")"
      write_facts RUNNING "$(describe)"; gcs_put "$PD/kernel_facts.json" "$RES/kernel_facts.json"; sync_small; fi
  done
  # GNU time cannot see the kernel that `lake comparator` starts (bwrap does not wait for it), so its peak
  # memory is read here, each time round.
  kq=$(pgrep -u chk -x leanchecker | head -n 1)
  [ -n "$kq" ] && awk '/^VmHWM:/ {print $2}' "/proc/$kq/status" > "$PD/run/kernel_hwm.tmp" 2>/dev/null && [ -s "$PD/run/kernel_hwm.tmp" ] && mv "$PD/run/kernel_hwm.tmp" "$PD/run/kernel_hwm_kb"
  [ -e "$PD/DEADLINE" ] && { say "the guest's deadline has passed: the checkers still running were stopped"; fact deadline_reached true; sleep 45; break; }
  if [ "$PAR" = waiting ] && { [ "$REHEARSAL" = 1 ] || { ! running nanoda && ! running con_ron; }; }; then
    if ended comparator; then PAR=skipped; PAR_WHY="lake comparator ended before its kernel stage was seen"
    else
      kp=$(pgrep -u chk -x leanchecker | head -n 1)
      if [ -n "$kp" ] && env_readable "$kp"; then
        if env_tuned "$kp"; then
          lp=$(pgrep -u chk -x lake | head -n 1); prss=$(rss_kb "${lp:-0}"); prss=${prss:-0}
          mt=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo); st=$(awk '/^SwapTotal:/ {print $2}' /proc/meminfo)
          fact comparator_kernel_has_allocator_setting true; fact comparator_parent_rss_kb_when_kernel_seen "$prss"
          ke=$(ps -o etimes= -p "$kp" 2>/dev/null | tr -d ' ')
          fact comparator_seconds_to_kernel_stage "$(( $(now) - $(cat "$PD/run/comparator.started") - ${ke:-0} ))"
          if [ $(( DEF_PEAK_KB + PAR_PEAK_KB + MARGIN_KB )) -le "$mt" ] && [ $(( DEF_PEAK_KB + PAR_PEAK_KB + MARGIN_KB + prss )) -le $(( mt + st * 9 / 10 )) ]; then
            launch paranoid "$(budget)" "$X" "$TUNE" "$KTC/bin/leanchecker-paranoid --silent --from-export $SOLX"; PAR=started
          else PAR=skipped; PAR_WHY="not enough memory beside lake comparator (its own process held $prss kB)"; fi
        else
          UNTUNED=$((UNTUNED + 1))
          if [ "$UNTUNED" -ge 4 ]; then
            say "the kernel that lake comparator started does not have the allocator setting: stopping it, since it would take two days"
            fact comparator_kernel_has_allocator_setting false
            pkill -KILL -u chk -x leanchecker; sleep 2; pkill -TERM -u chk -x lake
            PAR=skipped; PAR_WHY="lake comparator's kernel did not have the allocator setting"
          fi
        fi
      fi
    fi
    [ "$PAR" = skipped ] && say "the paranoid kernel is not started: $PAR_WHY"
  fi
  [ $(( tick % 10 )) = 0 ] && { snapshot; status kernels RUNNING "$(describe)"; }
done
snapshot
[ "$PAR" = waiting ] && { PAR=skipped; PAR_WHY="the other checkers ended before it could be started"; }
fact paranoid_started "$([ "$PAR" = started ] && echo true || echo false)"; [ -n "$PAR_WHY" ] && fact paranoid_not_started_because "$PAR_WHY"

# ---------------------------------------------------------------- what each one said
for l in nanoda con_ron comparator paranoid; do
  if ended "$l"; then
    fact "${l}_exit_status" "$(cut -d' ' -f1 "$PD/run/$l.rc")"; fact "${l}_seconds" "$(cut -d' ' -f2 "$PD/run/$l.rc")"
    # For lake comparator, GNU time's figure is the lake process alone; its kernel's peak is the one sampled.
    if [ "$l" = comparator ]; then fact comparator_lake_process_max_rss_kb "$(max_rss "$l")"; fact comparator_kernel_peak_rss_kb_sampled "$(cat "$PD/run/kernel_hwm_kb" 2>/dev/null)"
    else fact "${l}_max_rss_kb" "$(max_rss "$l")"; fi
    grep -E 'Command terminated by signal|Elapsed|Percent of CPU|Exit status' "$XO/$l.time" > "$PD/logs/$l.time.txt" 2>/dev/null
  elif started "$l"; then fact "${l}_exit_status" not_finished
  else fact "${l}_exit_status" not_run; fi
done
if ended nanoda; then
  fact nanoda_success_line "$(grep -E '^Checked [0-9]+ declarations with no errors' "$PD/logs/nanoda.out" | tail -n 1)"
  fact nanoda_checked_declarations "$(grep -E '^Checked [0-9]+ declarations with no errors' "$PD/logs/nanoda.out" | tail -n 1 | awk '{print $2}')"
fi
if ended con_ron; then
  fact con_ron_theorems_justified "$(grep -Ec '^con-ron: theorem .* justified by the solution$' "$PD/logs/con_ron.out")"
  fact con_ron_accept_line "$(grep -E 'accepted [0-9]+ declarations' "$PD/logs/con_ron.out" | tail -n 1 | cut -c1-300)"
fi
if ended comparator; then
  fact comparator_says_solution_is_okay "$(grep -q 'Your solution is okay!' "$PD/logs/comparator.out" && echo true || echo false)"
  fact comparator_lean_kernel_accepts "$(grep -q 'Lean default kernel accepts the solution' "$PD/logs/comparator.out" && echo true || echo false)"
  fact comparator_sandbox_calls "$(( $(wc -l < "$XC/bwrap_calls.log" 2>/dev/null || echo 0) - ${BW0:-0} ))"
  # A kernel that was killed reads, in lake's output, like one that rejected: its own error line tells them apart.
  fact comparator_error_line "$(grep -h -E '^error:' "$PD/logs/comparator.err" 2>/dev/null | tail -n 1 | cut -c1-300)"
fi
dmesg 2>/dev/null | grep -iE 'out of memory|oom-kill|killed process' | cut -c1-300 > "$PD/logs/oom.txt"
fact processes_killed_for_memory "$(awk '/^oom_kill / {print $2}' /proc/vmstat 2>/dev/null)"
for f in "$PD"/logs/*.out "$PD"/logs/*.err; do [ -f "$f" ] && [ "$(stat -c %s "$f")" -gt 200000 ] && { tail -c 20000 "$f" > "$f.tail.txt"; gzip -f "$f"; }; done
finish DONE "all steps ran; read kernel_facts.json"
