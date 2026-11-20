#!/bin/bash
# Shared configuration and helpers. Source this from every script:
#   . "$(cd "$(dirname "$0")" && pwd)/lib.sh"      (adjust the relative path as needed)
# Works with bash 3.2 (macOS) and bash 5 (Linux).
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Values already set in the environment win over config.env, so a test can be pointed at a scratch directory
# (for example: RH_WORKDIR=/tmp/scratch scripts/06_progress.sh) without touching a real working directory.
_rh_keep=""
for _v in RH_WORKDIR RH_PART_URL_PREFIX RH_PART_COUNT RH_TARBALL_SHA256 RH_JOBS GCP_PROJECT GCP_BUCKET GCP_REGION GCP_ZONES GCP_MACHINE_TYPE GCP_SPEND_CAP_USD GCP_RATE_USD_PER_HOUR; do
  if eval "[ -n \"\${$_v+x}\" ]"; then eval "_rh_env_$_v=\"\${$_v}\""; _rh_keep="$_rh_keep $_v"; fi
done
[ -f "$REPO_ROOT/config.env" ] && . "$REPO_ROOT/config.env"
for _v in $_rh_keep; do eval "$_v=\"\${_rh_env_$_v}\""; done
unset _v _rh_keep
RH_WORKDIR="${RH_WORKDIR:-$REPO_ROOT/work}"
RH_PART_URL_PREFIX="${RH_PART_URL_PREFIX:-https://alpo.ge/lean.tar.gz.part}"
RH_PART_COUNT="${RH_PART_COUNT:-14}"
RH_TARBALL_SHA256="${RH_TARBALL_SHA256:-9631b4f020199e580ba86178cb56c6e9b09f690c2369a80dc4334aa93f49c7fc}"
RH_JOBS="${RH_JOBS:-}"
RH_DL="$RH_WORKDIR/download"          # tarball parts and the reassembled tarball
RH_PROJ="$RH_WORKDIR/extract/lean"    # the extracted Lean project (lakefile.toml lives here)
RH_LOGS="$RH_WORKDIR/logs"
RH_AN="$RH_WORKDIR/analysis"          # derived data (import graph, timings)
RECORDS="$REPO_ROOT/records"

log()  { printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }
is_macos() { [ "$(uname -s)" = Darwin ]; }
sha256_of() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }
ncpu() { if is_macos; then sysctl -n hw.ncpu; else nproc; fi; }
mem_gb() { if is_macos; then echo $(( $(sysctl -n hw.memsize) / 1073741824 )); else awk '/MemTotal/ {printf "%d", $2/1048576}' /proc/meminfo; fi; }
# LEAN_PATH for running lean / leanchecker directly, without going through lake.
lean_path() { local p="$RH_PROJ/.lake/build/lib/lean" d; for d in "$RH_PROJ"/.lake/packages/*/.lake/build/lib/lean; do p="$p:$d"; done; printf '%s' "$p"; }
ensure_dirs() { mkdir -p "$RH_DL" "$RH_LOGS" "$RH_AN"; }
