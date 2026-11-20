#!/bin/bash
# 00_check_prereqs.sh - check that this machine can run the verification.
#
# What it does: checks for curl, tar, git, python3 and the Lean tool manager (elan, which
#   provides lake and lean); reports free disk space for RH_WORKDIR, memory and CPU cores; and
#   prints a recommended value for RH_JOBS, the number of parallel compiler processes.
# What it changes on disk: nothing. Only with --install-elan does it download the elan installer
#   to RH_WORKDIR/download/elan-init.sh (kept there so you can read what was run) and run it;
#   the installer writes to ~/.elan and adds one line to your shell profile.
# How long it takes: a few seconds. The elan install, if requested, takes about a minute.
#
# Usage: scripts/00_check_prereqs.sh [--install-elan] [--print-jobs]
#   --install-elan  download and run the elan installer (no default toolchain is installed)
#   --print-jobs    print only the recommended job count and exit
# Exit status: 0 if every required tool is present, 1 otherwise.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"
. "$HERE/common.sh"

ELAN_INIT_URL="${ELAN_INIT_URL:-https://raw.githubusercontent.com/leanprover/elan/master/elan-init.sh}"
INSTALL_ELAN=0
for arg in "$@"; do
  case "$arg" in
    --install-elan) INSTALL_ELAN=1 ;;
    --print-jobs) recommended_jobs; exit 0 ;;
    -h|--help) show_help; exit 0 ;;
    *) die "unknown argument: $arg (try --help)" ;;
  esac
done

missing=0
have() { command -v "$1" >/dev/null 2>&1; }
check_required() {  # check_required <command> <purpose>
  if have "$1"; then printf '  ok       %-10s %s\n' "$1" "$(command -v "$1")"
  else printf '  MISSING  %-10s needed for: %s\n' "$1" "$2"; missing=$((missing + 1)); fi
}
check_optional() {  # check_optional <command> <purpose>
  if have "$1"; then printf '  ok       %-10s %s\n' "$1" "$(command -v "$1")"
  else printf '  absent   %-10s optional: %s\n' "$1" "$2"; fi
}

install_elan() {
  have curl || die "curl is needed to download the elan installer"
  mkdir -p "$RH_DL" || die "cannot create $RH_DL"
  local script="$RH_DL/elan-init.sh" rc
  log "downloading the elan installer from $ELAN_INIT_URL"
  curl -sSfL --connect-timeout 30 -o "$script" "$ELAN_INIT_URL" || die "download failed"
  log "running $script (no default toolchain; step 04 installs the pinned one)"
  sh "$script" -y --default-toolchain none
  rc=$?
  [ "$rc" -eq 0 ] || die "the elan installer exited with status $rc"
  # Make elan visible to the rest of this script; a new shell picks it up from the profile.
  if [ -d "$HOME/.elan/bin" ]; then PATH="$HOME/.elan/bin:$PATH"; export PATH; fi
}

echo "== Required tools"
check_required curl    "downloading the source parts"
check_required tar     "extracting the source"
check_required git     "fetching Mathlib and its dependencies (used by lake)"
check_required python3 "inspecting the tarball, the source audit and the result summaries"
check_required awk     "text processing"
check_required find    "counting files"
check_required xargs   "running kernel checks in parallel"
if have sha256sum || have shasum; then
  printf '  ok       %-10s %s\n' "sha256" "$(command -v sha256sum 2>/dev/null || command -v shasum)"
else
  printf '  MISSING  %-10s needed for: verifying downloads (sha256sum or shasum)\n' "sha256"; missing=$((missing + 1))
fi
if have python3 && ! python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 6) else 1)' 2>/dev/null; then
  printf '  MISSING  %-10s python3 is older than 3.6\n' "python3"; missing=$((missing + 1))
fi

echo "== Lean tools"
if ! have elan && [ "$INSTALL_ELAN" -eq 1 ]; then install_elan; fi
if have elan; then
  printf '  ok       %-10s %s (%s)\n' "elan" "$(command -v elan)" "$(elan --version 2>/dev/null | head -n 1)"
else
  printf '  MISSING  %-10s the Lean toolchain manager\n' "elan"; missing=$((missing + 1))
fi
if have lake; then
  printf '  ok       %-10s %s\n' "lake" "$(command -v lake)"
else
  printf '  MISSING  %-10s the Lean build tool (installed by elan)\n' "lake"; missing=$((missing + 1))
fi
if have lake && ! have elan; then
  echo "  NOTE: lake was found without elan. The project pins an exact Lean version in its"
  echo "        lean-toolchain file; without elan you must make sure that exact version is used."
fi
if ! have elan; then
  cat <<EOF

  elan is not installed. It is the official tool for installing and selecting Lean versions.
  Instructions: https://github.com/leanprover/elan#installation
            and https://lean-lang.org/install/
  On macOS and Linux the documented method is to download elan-init.sh and run it, e.g.
      curl -sSfL $ELAN_INIT_URL -o elan-init.sh
      sh elan-init.sh -y --default-toolchain none
  then open a new shell (or add ~/.elan/bin to PATH). Read the script before running it if
  you prefer. To let this script do exactly those two steps, re-run it with --install-elan.
  Nothing is installed unless you pass that flag.
EOF
fi
if [ -f "$RH_PROJ/lean-toolchain" ]; then
  echo "  pinned toolchain (from the extracted project): $(head -n 1 "$RH_PROJ/lean-toolchain")"
fi

echo "== Optional tools"
check_optional rg "ripgrep makes the source audit (step 03) much faster; grep is used otherwise"
if is_macos; then
  check_optional caffeinate "keeps the Mac awake during the build"
  check_optional lsof "identifies which project a running lake process belongs to"
fi

echo "== Machine"
cores=$(ncpu); mem=$(mem_gb); rec=$(recommended_jobs)
free_kb=$(disk_free_kb "$RH_WORKDIR"); free_kb=${free_kb:-0}
free_gb=$((free_kb / 1048576))
echo "  system:            $(uname -s) $(uname -m), bash ${BASH_VERSION}"
echo "  CPU cores:         $cores"
echo "  memory:            $mem GB"
echo "  open-file limit:   $(ulimit -n) (hard limit: $(ulimit -Hn))"
echo "  work directory:    $RH_WORKDIR"
echo "  free disk there:   $free_gb GB"
echo "  recommended RH_JOBS: $rec   (min(cores, (memory_GB - 8) / 2), at least 1)"
case "$RH_JOBS" in
  '') echo "  configured RH_JOBS:  (not set; the recommended value will be used)" ;;
  *[!0-9]*) echo "  configured RH_JOBS:  '$RH_JOBS' is not a number; the recommended value will be used" ;;
  *) echo "  configured RH_JOBS:  $RH_JOBS"
     if [ "$RH_JOBS" -gt "$rec" ]; then
       echo "  NOTE: RH_JOBS is above the recommendation. Too many jobs for the available memory"
       echo "        makes the machine swap and the build slower, not faster."
     fi ;;
esac

echo "== Disk space"
echo "  download and extraction:   about 2 GB (parts and tarball 0.5 GB, 175,187 source files 1.0 GB)"
echo "  Mathlib and its cache:     about 8 GB"
echo "  full build:                roughly 1.5 TB. This is an extrapolation from a partial build"
echo "                             (2026-11-20, first 10,000 modules: about 0.7 MB of compiled"
echo "                             output and 6 MB of Lake setup data per module); no complete"
echo "                             build had been finished when this was written."
if [ "$free_gb" -lt 12 ]; then
  echo "  WARNING: less than 12 GB free: not enough even for the download and Mathlib."
elif [ "$free_gb" -lt 1500 ]; then
  echo "  WARNING: $free_gb GB free is less than the estimated need of a full build. Steps 01 to 04"
  echo "           will work; the build (05) is likely to run out of space before it finishes."
fi

echo
if [ "$missing" -gt 0 ]; then
  echo "RESULT: $missing required item(s) missing. Install them and run this script again."
  exit 1
fi
echo "RESULT: all required tools are present."
exit 0
