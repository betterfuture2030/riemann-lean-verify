#!/bin/bash
# export_guest.sh - runs ON the cloud VM as its startup script (as root), in the mode `export-check`.
#
# What it does: takes the compiled files that a finished full run on Spot machines left in the bucket
# (ckpt/RUNTAG/, see full_guest.sh and scripts/spot_checkpoint.sh), and makes the checks that the Lean reference
# calls the gold standard and that the three pre-registered criteria of this repository do not include
# (docs/related-work.md):
#   1. restores every part, each checked against its SHA-256 in the manifest, and shows that the restored
#      directory is, file for file, the one the full run sealed;
#   2. compiles a challenge file that imports only Mathlib and states the five theorems with `sorry`, and exports
#      it with lean4export;
#   3. exports the proof (module Main) with lean4export, and compares the SHA-256 of both exports with the ones
#      published at https://math.mit.edu/~drew/grh/ ;
#   4. runs con-leche, a kernel written independently of Lean's own and proven sound, on the exported proof, and
#      its --compare mode, which checks that the five statements proved are exactly the challenge's;
#   5. if time allows, runs nanoda, a second independent kernel, on the exported proof.
# Nothing is compiled except the challenge file and the two tools. The export and the kernels run as a user with
# no network, on files that user cannot write.
#
# What this is not: `lake comparator` end to end. That also runs Lean's own kernel over the export, which is
# single-threaded and took between 9 and 48 hours where it has been timed. And the build whose files are checked
# here was not made in a sandbox.
#
# The challenge file below is the one in https://github.com/leanprover-community/riemann-hypothesis
# (src/Challenge.lean), and the export targets are that repository's export-targets.txt.
#
# How it ends: as full_guest.sh does. It uploads a final status and idles; the local `watch` deletes the VM, and
# if nobody is watching Google deletes it at its maximum run time.
set -u
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a HOME=/root
PD=/var/pilot; mkdir -p "$PD"; chmod 755 "$PD"
exec > >(tee -a "$PD/pilot.log") 2>&1
T0=$(date +%s)
MDURL=http://metadata.google.internal/computeMetadata/v1/instance
md() { curl -sf --connect-timeout 5 --max-time 20 -H "Metadata-Flavor: Google" "$MDURL/attributes/$1" || echo "$2"; }
BUCKET=$(md pilot-bucket "")
MODE=$(md pilot-mode export-check)
NMAX=$(md pilot-nmax 32)
DEADLINE_MIN=$(md pilot-deadline-min 280)
TARBALL_SHA=$(md pilot-tarball-sha "")
TOOLS_SHA=$(md full-tools-sha "")
TOOLS_COMMIT=$(md full-tools-commit unknown)
GUEST_SHA_WANT=$(md full-guest-sha "")
RUNTAG=$(md pilot-runtag run)
SRC_RUNTAG=$(md export-src-runtag "")            # the full run whose compiled files are checked
MANIFEST_SHA_WANT=$(md export-manifest-sha "")   # SHA-256 of that run's manifest.tsv, as the controller holds it
SEAL_SHA_WANT=$(md export-seal-sha "")           # SHA-256 of that run's manifest of compiled files (facts.json: seal)
WANT_SOLUTION=$(md export-solution-sha 5ea74b912147c5c93cc2b6d70cc727cf908df2f62ac6a20480a3fa02f6be244e)    # published
WANT_CHALLENGE=$(md export-challenge-sha bd484ac9886a96f26b1d9a7a59ebd45b7a70d102c015d4f31f9302bbdd6ab2b9)  # published
EXPORTER_REF=$(md export-lean4export-ref 15f6055e)   # leanprover/lean4export, tag v4.33.0
CONLECHE_MASTER=$(md export-con-leche-master cd2eceab)
CONLECHE_COMPARE=$(md export-con-leche-compare 5dc36dc1)
KERNEL_TC=$(md export-kernel-toolchain leanprover/lean4:v4.36.0)
NANODA_SECS=$(md export-nanoda-secs 7200)
GUEST_SHA=$(curl -sf --connect-timeout 5 --max-time 30 -H "Metadata-Flavor: Google" "$MDURL/attributes/startup-script" | sha256sum | cut -d' ' -f1)
DEADLINE=$(( T0 + DEADLINE_MIN * 60 ))
WORK=/mnt/work; PROJ=$WORK/extract/lean; RES="results/$RUNTAG"; TOOLS=/opt/rhv; CK="ckpt/$SRC_RUNTAG"
LIB=$PROJ/.lake/build/lib/lean; SPK=$TOOLS/scripts/spot_checkpoint.sh; X=$WORK/export; OPT=/opt/kernels
TC_BIN=""; TC_DIR=""; LP=""

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
# Every fact is one line "key<TAB>value" in facts.tsv; write_facts turns them into export_facts.json.
fact() { printf '%s\t%s\n' "$1" "$2" >> "$PD/facts.tsv"; say "FACT $1 = $2"; }
write_facts() { # write_facts <state> <message>
  python3 - "$PD/facts.tsv" "$PD/export_facts.json" "$1" "$2" "$T0" <<'PY'
import json, sys, time
src, out, state, msg, t0 = sys.argv[1:6]
d = {"what": "facts from one run of cloud/gcp/export_guest.sh; not a verdict", "state": state, "message": msg,
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
sync_small() { local f; for f in pilot.log setup.tsv phases.tsv env.txt facts.tsv spot.log; do gcs_put "$PD/$f" "$RES/$f"; done; for f in "$PD"/logs/*; do [ -f "$f" ] && gcs_put "$f" "$RES/logs/$(basename "$f")"; done; return 0; }
idle_until_deleted() { trap '' TERM INT; while true; do pkill -KILL -u chk 2>/dev/null; gcs_put "$PD/status.json" "$RES/status.json" 2>/dev/null; sleep 60; done; }
finish() { # finish <state> <message>   -- the final status is uploaded LAST: it is the watcher's signal to delete this VM
  trap '' TERM INT
  [ -n "${HB_PID:-}" ] && kill "$HB_PID" 2>/dev/null
  say "FINISH $1: $2"; write_facts "$1" "$2"; sync_small; gcs_put "$PD/export_facts.json" "$RES/export_facts.json"
  status "$PHASE" "$1" "$2"; idle_until_deleted
}
phase_mark() { PHASE=$1; printf '%s\t%s\n' "$(now)" "$1" >> "$PD/phases.tsv"; say "PHASE $1"; status "$1" RUNNING "${2:-}"; }
t_step() { local name=$1; shift; local s; s=$(now); say "step: $name"
  if "$@"; then printf '%s\t%s\tok\n' "$name" "$(( $(now) - s ))" >> "$PD/setup.tsv"
  else printf '%s\t%s\tFAILED\n' "$name" "$(( $(now) - s ))" >> "$PD/setup.tsv"; finish FAIL "step failed: $name"; fi; }
trap 'finish FAIL "unexpected signal"' TERM INT
# The guest's own deadline: whatever is running then is stopped and the run reports what it has.
( sleep $(( DEADLINE_MIN * 60 )); touch "$PD/DEADLINE"; pkill -KILL -u chk 2>/dev/null ) &
( while true; do sleep 300; sync_small; done ) & HB_PID=$!
mkdir -p "$PD/logs"; : > "$PD/facts.tsv"

phase_mark setup "installing"
{ echo "mode=$MODE nmax=$NMAX deadline_min=$DEADLINE_MIN tools_commit=$TOOLS_COMMIT guest_sha256=$GUEST_SHA src_runtag=$SRC_RUNTAG"; nproc; lscpu | grep -E "Model name|Thread|Core|Socket"; uname -r; free -g | head -2; head -2 /etc/os-release; } > "$PD/env.txt" 2>&1
[ -n "$BUCKET" ] && [ -n "$SRC_RUNTAG" ] && [ -n "$MANIFEST_SHA_WANT" ] && [ -n "$SEAL_SHA_WANT" ] || finish FAIL "metadata is incomplete"
[ -z "$GUEST_SHA_WANT" ] || [ "$GUEST_SHA" = "$GUEST_SHA_WANT" ] || finish FAIL "this script is not the one the controller sent"
fact guest_script_is_the_one_sent true; fact tools_commit "$TOOLS_COMMIT"; fact source_run "$SRC_RUNTAG"; fact tarball_sha256 "$TARBALL_SHA"

manifest() {
  { find "$@" -type f -print0 | xargs -0 -r -P "$NMAX" -n 8 sha256sum
    find "$@" ! -type f ! -type d -printf 'not-a-file:%y  %p -> %l\n'; } | LC_ALL=C sort -k2
}
as_pilot() { runuser -l pilot -c "ulimit -n 1048576 2>/dev/null; cd $PROJ && $1"; }
# The checking user: no network, and nothing it can write but its own output directory.
as_chk() { runuser -u chk -- env -i HOME=/home/chk LANG=C.UTF-8 PATH="$TC_BIN:/usr/bin:/bin" LEAN_PATH="$LP" LEAN_SYSROOT="$TC_DIR" LEAN_ABORT_ON_PANIC=1 bash -c "ulimit -n 1048576 2>/dev/null; ulimit -s unlimited 2>/dev/null; $1"; }
fetch_checked() { gcs_get "$1" "$2" || { echo "could not fetch $1"; return 1; }; local got; got=$(sha256sum "$2" | cut -d' ' -f1); [ -n "$3" ] && [ "$got" = "$3" ] || { echo "$1: sha256 $got, expected $3"; return 1; }; }

s_sysctl() { sysctl -w fs.file-max=50000000 vm.max_map_count=16777216 fs.nr_open=4194304 >/dev/null; }
s_pkgs() { apt-get update -qq && apt-get install -y -qq --no-install-recommends git curl xfsprogs iptables ca-certificates zstd build-essential >/dev/null; }
s_disk() { mkdir -p "$WORK"; [ -e /dev/disk/by-id/google-pilot-data ] || return 1; mkfs.xfs -q -f /dev/disk/by-id/google-pilot-data && mount -o noatime /dev/disk/by-id/google-pilot-data "$WORK"; }
s_users() {
  useradd -m -s /bin/bash pilot && useradd -m -s /bin/bash chk || return 1
  printf 'pilot\nchk\n' >> /etc/cron.deny
  mkdir -p "$WORK/extract" "$X" && chown pilot:pilot "$WORK/extract" && chown chk:chk "$X" || return 1
  iptables -I OUTPUT 1 -m owner --uid-owner pilot -d 169.254.169.254 -j REJECT || return 1
  iptables -I OUTPUT 1 -m owner --uid-owner chk -d 169.254.169.254 -j REJECT && iptables -A OUTPUT -m owner --uid-owner chk ! -o lo -j REJECT || return 1
  if runuser -u chk -- curl -s -m 4 -o /dev/null https://storage.googleapis.com/; then echo "user chk still has network access"; return 1; fi
}
s_elan() { runuser -l pilot -c 'curl -sSf https://raw.githubusercontent.com/leanprover/elan/master/elan-init.sh | sh -s -- -y --default-toolchain none >/dev/null 2>&1; grep -q elan ~/.profile || echo "export PATH=\$HOME/.elan/bin:\$PATH" >> ~/.profile; ~/.elan/bin/elan --version'; }
s_source() {
  fetch_checked "inputs/lean.tar.gz" "$WORK/lean.tar.gz" "$TARBALL_SHA" || return 1
  tar -xzf "$WORK/lean.tar.gz" -C "$WORK/extract" && rm -f "$WORK/lean.tar.gz" && chown -R pilot:pilot "$PROJ" || return 1
  fetch_checked "inputs/rhv_tools.tar.gz" "$PD/rhv_tools.tar.gz" "$TOOLS_SHA" || return 1
  rm -rf "$TOOLS" && mkdir -p "$TOOLS" && tar -xzf "$PD/rhv_tools.tar.gz" -C "$TOOLS" --strip-components=1 && chown -R root:root "$TOOLS" && chmod -R a+rX,go-w "$TOOLS" && [ -f "$SPK" ]
}
s_cache() { as_pilot "timeout 1500 lake exe cache get > /tmp/cache_get.log 2>&1; rc=\$?; tail -2 /tmp/cache_get.log; exit \$rc"; }
s_toolchain() {
  TC_BIN=$(dirname "$(as_pilot 'elan which lean' | tail -1)"); TC_DIR=$(dirname "$TC_BIN")
  [ -x "$TC_BIN/lean" ] || return 1
  as_pilot 'lean --version' | tail -1 >> "$PD/env.txt"
  # From here on the build user has no network, and everything it owns is handed to root: nothing run below
  # can change the source tree, the toolchain or Mathlib's compiled files.
  iptables -A OUTPUT -m owner --uid-owner pilot ! -o lo -j REJECT || return 1
  pkill -KILL -u pilot 2>/dev/null; chown -R root:root "$PROJ" /home/pilot/.elan && chmod -R a+rX,go-w "$PROJ" /home/pilot/.elan && chmod 755 /home/pilot || return 1
  local d; LP=""
  for d in "$PROJ"/.lake/packages/*/.lake/build/lib/lean; do [ -d "$d" ] && LP="$LP${LP:+:}$d"; done
  [ -n "$LP" ] || { echo "no compiled packages found"; return 1; }
  ( cd "$PROJ/.lake/packages" && manifest . -path '*/.lake/build/lib/lean/*' ! -name '*.hash' ! -name '*.trace' ) > "$PD/pkgs_sha256.txt" || return 1
  fact mathlib_and_packages_manifest_sha256 "$(sha256sum "$PD/pkgs_sha256.txt" | cut -d' ' -f1)"
  fact mathlib_and_packages_files "$(wc -l < "$PD/pkgs_sha256.txt")"
  fact mathlib_revision "$(git -C "$PROJ/.lake/packages/mathlib" rev-parse HEAD 2>/dev/null || echo unknown)"
}
# lean4export, built by root with the pinned toolchain, from the commit named above.
s_exporter() {
  mkdir -p "$OPT" && cd "$OPT" && git clone -q https://github.com/leanprover/lean4export && cd lean4export && git checkout -q "$EXPORTER_REF" || return 1
  fact lean4export_commit "$(git rev-parse HEAD)"
  cat "$PROJ/lean-toolchain" > lean-toolchain
  PATH="$TC_BIN:$PATH" timeout 1200 "$TC_BIN/lake" build > "$PD/logs/lean4export_build.log" 2>&1 || { tail -5 "$PD/logs/lean4export_build.log"; return 1; }
  EXPORTER=$(find "$OPT/lean4export/.lake/build/bin" -maxdepth 1 -type f -perm -u+x | head -1); [ -x "$EXPORTER" ] || return 1
  fact lean4export_binary_sha256 "$(sha256sum "$EXPORTER" | cut -d' ' -f1)"
}
# The independent kernels: Lean v4.36.0 (for nanoda_bin and to build con-leche), installed for root only.
s_kernels() {
  export ELAN_HOME=/opt/elan
  curl -sSf https://raw.githubusercontent.com/leanprover/elan/master/elan-init.sh | sh -s -- -y --no-modify-path --default-toolchain none > "$PD/logs/kernel_toolchain.log" 2>&1 || { tail -3 "$PD/logs/kernel_toolchain.log"; return 1; }
  /opt/elan/bin/elan toolchain install "$KERNEL_TC" >> "$PD/logs/kernel_toolchain.log" 2>&1 || { tail -3 "$PD/logs/kernel_toolchain.log"; return 1; }
  KTC=$(/opt/elan/bin/elan run "$KERNEL_TC" lean --print-prefix 2>> "$PD/logs/kernel_toolchain.log" | tail -1)
  [ -n "$KTC" ] && [ -x "$KTC/bin/lean" ] && [ -x "$KTC/bin/lake" ] || { echo "kernel toolchain not found: $KTC"; return 1; }
  "$KTC/bin/lean" --version >> "$PD/env.txt"; ls "$KTC/bin" | tr '\n' ' ' >> "$PD/env.txt"; echo >> "$PD/env.txt"
  local b
  for b in master compare; do
    cd "$OPT" && git clone -q https://github.com/leanprover/con-leche "con-leche-$b" && cd "con-leche-$b" || return 1
    if [ "$b" = master ]; then git checkout -q "$CONLECHE_MASTER"; else git checkout -q "$CONLECHE_COMPARE"; fi || return 1
    fact "con_leche_${b}_commit" "$(git rev-parse HEAD)"
    PATH="$KTC/bin:$PATH" timeout 1500 "$KTC/bin/lake" build con-leche > "$PD/logs/con_leche_${b}_build.log" 2>&1 || { tail -5 "$PD/logs/con_leche_${b}_build.log"; return 1; }
    [ -x "$OPT/con-leche-$b/.lake/build/bin/con-leche" ] || return 1
  done
  chmod -R a+rX,go-w /opt/elan "$OPT"
  fact kernel_toolchain "$KERNEL_TC"
}
TARGETS_X="Quot Quot.mk Quot.lift Quot.ind riemannHypothesis riemannZeta_eq_zero_re LFunction_ne_zero_of_half_lt_re LFunction_eq_zero_re LFunction_eq_zero_re_of_isPrimitive propext Quot.sound Classical.choice Nat.add Nat.sub Nat.mul Nat.pow Nat.gcd Nat.div Nat.mod Nat.beq Nat.ble Nat.land Nat.lor Nat.xor Nat.shiftLeft Nat.shiftRight String.ofList Char.ofNat List eagerReduce Nat String String.mk Char optParam autoParam semiOutParam outParam"
# The challenge: the five statements with `sorry`, in a file that imports only Mathlib. Compiled by the checking
# user against Mathlib's compiled files alone; nothing of the proof is on its search path.
s_challenge() {
  mkdir -p "$X/challenge" && chown chk:chk "$X/challenge" || return 1
  cat > "$X/challenge/Challenge.lean" <<'LEAN'
import Mathlib

def RiemannZetaZerosOnLine : Prop :=
  ∀ s : ℂ, riemannZeta s = 0 → (¬∃ n : ℕ, s = -2 * ((n : ℂ) + 1)) → s ≠ 1 → s.re = 1 / 2

def DirichletLNonvanishingRightOfHalf : Prop :=
  ∀ (N : ℕ) [NeZero N] (χ : DirichletCharacter ℂ N) (s : ℂ),
    1 / 2 < s.re → (χ ≠ 1 ∨ s ≠ 1) → DirichletCharacter.LFunction χ s ≠ 0

def DirichletLZerosOnLine : Prop :=
  ∀ (N : ℕ) [NeZero N] (χ : DirichletCharacter ℂ N) (s : ℂ),
    0 < s.re → s.re < 1 → DirichletCharacter.LFunction χ s = 0 → s.re = 1 / 2

def PrimitiveDirichletLZerosOnLine : Prop :=
  ∀ (N : ℕ) [NeZero N] (χ : DirichletCharacter ℂ N), χ.IsPrimitive →
    ∀ s : ℂ, 0 < s.re → s.re < 1 → DirichletCharacter.LFunction χ s = 0 → s.re = 1 / 2

/-- The headline claim, stated with Mathlib's definition only. -/
theorem riemannHypothesis : RiemannHypothesis := by sorry

theorem riemannZeta_eq_zero_re : RiemannZetaZerosOnLine := by sorry

theorem LFunction_ne_zero_of_half_lt_re : DirichletLNonvanishingRightOfHalf := by sorry

theorem LFunction_eq_zero_re : DirichletLZerosOnLine := by sorry

theorem LFunction_eq_zero_re_of_isPrimitive : PrimitiveDirichletLZerosOnLine := by sorry
LEAN
  fact challenge_source_sha256 "$(sha256sum "$X/challenge/Challenge.lean" | cut -d' ' -f1)"
  as_chk "cd $X/challenge && timeout 1800 lean --root=. -o Challenge.olean -i Challenge.ilean Challenge.lean" > "$PD/logs/challenge_compile.log" 2>&1 || { tail -5 "$PD/logs/challenge_compile.log"; return 1; }
  as_chk "cd $X/challenge && LEAN_PATH=$X/challenge:\$LEAN_PATH timeout 1800 $EXPORTER Challenge -- $TARGETS_X > $X/challenge.ndjson 2> $X/challenge_export.err" || { tail -5 "$X/challenge_export.err"; return 1; }
  CH_SHA=$(sha256sum "$X/challenge.ndjson" | cut -d' ' -f1)
  fact challenge_export_bytes "$(stat -c %s "$X/challenge.ndjson")"; fact challenge_export_sha256 "$CH_SHA"; fact challenge_export_sha256_published "$WANT_CHALLENGE"
  if [ "$CH_SHA" = "$WANT_CHALLENGE" ]; then fact challenge_export_matches_published true; else fact challenge_export_matches_published false; fi
  zstd -q -T0 -10 --long=27 -c "$X/challenge.ndjson" > "$PD/challenge.ndjson.zst" && gcs_put "$PD/challenge.ndjson.zst" "$RES/challenge.ndjson.zst"
  return 0
}

t_step sysctl s_sysctl; t_step packages s_pkgs; t_step disk s_disk; t_step users s_users; t_step elan s_elan
t_step source s_source; t_step mathlib_cache s_cache; t_step toolchain s_toolchain
t_step exporter s_exporter; t_step kernels s_kernels
phase_mark challenge "compiling and exporting the challenge file"
t_step challenge s_challenge
sync_small

# ---------------------------------------------------------------- the compiled files of the full run
phase_mark restore "restoring the full run's compiled files from the bucket"
s_restore() {
  local seq obj sha bytes mods ep att n=0 b=0 i ok got t0; t0=$(now)
  mkdir -p "$WORK/in" "$PD/members" "$PROJ/.lake/build" || return 1
  gcs_get "$CK/manifest.tsv" "$PD/manifest.tsv" || { echo "could not fetch the manifest"; return 1; }
  [ "$(sha256sum "$PD/manifest.tsv" | cut -d' ' -f1)" = "$MANIFEST_SHA_WANT" ] || { echo "the bucket's manifest is not the one the controller holds"; return 1; }
  while IFS=$'\t' read -r seq obj sha bytes mods ep att; do
    [ "$seq" = seq ] && continue
    ok=0
    for i in 1 2 3; do
      if gcs_get "$obj" "$WORK/in/part" && [ "$(stat -c %s "$WORK/in/part")" = "$bytes" ]; then
        got=$(sha256sum "$WORK/in/part" | cut -d' ' -f1); [ "$got" = "$sha" ] && { ok=1; break; }
        echo "$obj: download $i has sha256 $got, expected $sha"
      fi
      sleep $(( i * 5 ))
    done
    [ "$ok" = 1 ] || { echo "could not fetch $obj as the manifest records it"; return 1; }
    bash "$SPK" restore --build-dir "$PROJ/.lake/build" --part "$WORK/in/part" --sha256 "$sha" --members-out "$PD/members/$seq.gz" --done-out "$PD/part.done" >> "$PD/spot.log" 2>&1 || { echo "could not restore $obj"; tail -3 "$PD/spot.log"; return 1; }
    rm -f "$WORK/in/part" "$PD/part.done"; n=$((n + 1)); b=$((b + bytes))
    [ $(( n % 10 )) = 0 ] && status restore RUNNING "restored $n parts, $b bytes"
  done < "$PD/manifest.tsv"
  fact parts_restored "$n"; fact parts_bytes "$b"; fact restore_seconds "$(( $(now) - t0 ))"
  chown -R root:root "$PROJ/.lake/build" && chmod -R a+rX,go-w "$PROJ/.lake/build"
}
t_step restore s_restore
phase_mark seal_check "hashing the restored files against the full run's seal"
s_seal() {
  local t0; t0=$(now)
  gcs_get "$CK/seal/lib_sha256.txt.gz" "$PD/seal_lib.txt.gz" && gunzip -c "$PD/seal_lib.txt.gz" > "$PD/seal_lib.txt" || { echo "could not fetch the seal's manifest"; return 1; }
  [ "$(sha256sum "$PD/seal_lib.txt" | cut -d' ' -f1)" = "$SEAL_SHA_WANT" ] || { echo "the bucket's seal manifest is not the one facts.json records"; return 1; }
  ( cd "$LIB" && manifest . ) > "$PD/lib_sha256.txt" || return 1
  fact compiled_files "$(wc -l < "$PD/lib_sha256.txt")"; fact compiled_oleans "$(grep -c '\.olean$' "$PD/lib_sha256.txt")"
  fact compiled_files_manifest_sha256 "$(sha256sum "$PD/lib_sha256.txt" | cut -d' ' -f1)"; fact seal_check_seconds "$(( $(now) - t0 ))"
  if cmp -s "$PD/lib_sha256.txt" "$PD/seal_lib.txt"; then fact restored_files_are_the_sealed_files true
  else fact restored_files_are_the_sealed_files false; diff "$PD/seal_lib.txt" "$PD/lib_sha256.txt" | head -100 > "$PD/logs/seal_diff.txt"; return 1; fi
  fact main_olean_sha256 "$(grep '  \./Main\.olean$' "$PD/lib_sha256.txt" | cut -d' ' -f1)"
}
t_step seal_check s_seal
sync_small

# ---------------------------------------------------------------- the export of the proof
phase_mark export "exporting the proof with lean4export (single-threaded; about an hour and a half elsewhere)"
LPX="$LIB:$LP"
s_export() {
  local t0 rc; t0=$(now)
  ( while sleep 300; do status export RUNNING "export: $(stat -c %s "$X/solution.ndjson" 2>/dev/null || echo 0) bytes written of about 61570595788"; done ) & local pp=$!
  as_chk "cd $PROJ && LEAN_PATH=$LPX timeout $(( $(left) - 1800 > 600 ? $(left) - 1800 : 600 )) /usr/bin/env $EXPORTER Main -- $TARGETS_X > $X/solution.ndjson 2> $X/solution_export.err"; rc=$?
  kill "$pp" 2>/dev/null; wait "$pp" 2>/dev/null
  head -c 20000 "$X/solution_export.err" > "$PD/logs/solution_export.err" 2>/dev/null
  fact solution_export_exit_status "$rc"; fact solution_export_seconds "$(( $(now) - t0 ))"; fact solution_export_bytes "$(stat -c %s "$X/solution.ndjson" 2>/dev/null || echo 0)"
  [ "$rc" = 0 ] || { tail -5 "$X/solution_export.err"; return 1; }
  SOL_SHA=$(sha256sum "$X/solution.ndjson" | cut -d' ' -f1)
  fact solution_export_sha256 "$SOL_SHA"; fact solution_export_sha256_published "$WANT_SOLUTION"
  if [ "$SOL_SHA" = "$WANT_SOLUTION" ]; then fact solution_export_matches_published true; else fact solution_export_matches_published false; fi
  chown root:root "$X/solution.ndjson" "$X/challenge.ndjson" && chmod 644 "$X/solution.ndjson" "$X/challenge.ndjson"
}
t_step export s_export
write_facts RUNNING "export made"; gcs_put "$PD/export_facts.json" "$RES/export_facts.json"; sync_small

# ---------------------------------------------------------------- independent kernels, on the export alone
# From here on nothing reads the compiled files: the kernels see two text files.
kernel() { # kernel <label> <seconds> <command>   -- records exit status and time; never ends the run
  local t0 rc; t0=$(now)
  [ "$(left)" -gt 300 ] || { fact "${1}_exit_status" not_run_no_time_left; return 0; }
  status kernels RUNNING "$1"
  runuser -u chk -- env -i HOME=/home/chk LANG=C.UTF-8 PATH="$KTC/bin:/usr/bin:/bin" bash -c "ulimit -s unlimited 2>/dev/null; cd $X && timeout $2 $3" > "$PD/logs/$1.log" 2>&1; rc=$?
  fact "${1}_exit_status" "$rc"; fact "${1}_seconds" "$(( $(now) - t0 ))"
  tail -c 3000 "$PD/logs/$1.log" > "$PD/logs/$1.tail.txt"; gzip -f "$PD/logs/$1.log"
  sync_small; return 0
}
phase_mark kernels "con-leche on the exported proof"
kernel con_leche_compare 3600 "$OPT/con-leche-compare/.lake/build/bin/con-leche --compare challenge.ndjson solution.ndjson"
kernel con_leche_master 3600 "$OPT/con-leche-master/.lake/build/bin/con-leche solution.ndjson"
write_facts RUNNING "con-leche done"; gcs_put "$PD/export_facts.json" "$RES/export_facts.json"
if [ -x "$KTC/bin/nanoda_bin" ]; then
  n=$(( $(left) - 900 )); [ "$n" -gt "$NANODA_SECS" ] && n=$NANODA_SECS
  if [ "$n" -gt 1800 ]; then kernel nanoda "$n" "$KTC/bin/nanoda_bin solution.ndjson"; else fact nanoda_exit_status not_run_no_time_left; fi
else fact nanoda_exit_status not_run_no_binary; fi
finish DONE "all steps ran; read export_facts.json"
