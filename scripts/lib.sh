#!/bin/bash
# Shared configuration and helpers. Source this from every script:
#   . "$(cd "$(dirname "$0")" && pwd)/lib.sh"      (adjust the relative path as needed)
# Works with bash 3.2 (macOS) and bash 5 (Linux).
#
# What it does: reads config.env, chooses the target (RH_TARGET; with none named, the default target alpoge-rh),
#   sets the TGT_ variables that describe the target and the RH_ paths derived from them, and stops the calling
#   script if the working directory belongs to another target. targets/README.md explains every setting.
#   It prints nothing on standard output.
# What it changes on disk: nothing when sourced. The function ensure_dirs creates download/, logs/ and analysis/
#   in the working directory and, if it is not there yet, the file .rh-target that names the target.
# How long it takes: no measurable time.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ---- Settings ---------------------------------------------------------------------------------------------
# Values already set in the environment win over config.env, so a test can be pointed at a scratch directory
# (for example: RH_WORKDIR=/tmp/scratch scripts/06_progress.sh) without touching a real working directory.
# RH_TARGET and every TGT_ variable are treated the same way, and they also win over the target's profile.
_rh_workdir_given="${RH_WORKDIR:+1}"
_rh_keep=""
for _v in RH_TARGET RH_WORKDIR RH_PART_URL_PREFIX RH_PART_COUNT RH_TARBALL_SHA256 RH_JOBS GCP_PROJECT GCP_BUCKET GCP_REGION GCP_ZONES GCP_MACHINE_TYPE GCP_SPEND_CAP_USD GCP_RATE_USD_PER_HOUR GCP_SECOND_REPLAY GCP_KEEP_OLEANS RH_REPLAY_METHOD ${!TGT_@}; do
  if eval "[ -n \"\${$_v+x}\" ]"; then eval "_rh_env_$_v=\"\${$_v}\""; _rh_keep="$_rh_keep $_v"; fi
done
_rh_env_wins() { for _v in $_rh_keep; do eval "$_v=\"\${_rh_env_$_v}\""; done; }
[ -f "$REPO_ROOT/config.env" ] && . "$REPO_ROOT/config.env"
_rh_env_wins
RH_JOBS="${RH_JOBS:-}"

log()  { printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }
is_macos() { [ "$(uname -s)" = Darwin ]; }
sha256_of() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }
ncpu() { if is_macos; then sysctl -n hw.ncpu; else nproc; fi; }
mem_gb() { if is_macos; then echo $(( $(sysctl -n hw.memsize) / 1073741824 )); else awk '/MemTotal/ {printf "%d", $2/1048576}' /proc/meminfo; fi; }

# ---- The target -------------------------------------------------------------------------------------------
# Everything that is a fact about one archive is in a TGT_ variable. targets/README.md lists them.
RH_TARGET="${RH_TARGET:-alpoge-rh}"
case "$RH_TARGET" in
  -*|*[!abcdefghijklmnopqrstuvwxyz0123456789-]*) die "RH_TARGET names a directory in targets/: lower-case letters, digits and '-' only, not starting with '-' (got '$RH_TARGET')" ;;
esac
if [ "$RH_TARGET" = alpoge-rh ]; then
  RH_TARGET_IS_DEFAULT=1
  # The default target's values are built in, so that this file works with no profile beside it (tests copy it
  # alone into a scratch tree). targets/alpoge-rh/target.env repeats them and is not read; to change a value,
  # change it in both places. A value that is already set, even to nothing, is left as it is.
  : "${TGT_SOURCE_KIND=tarball-parts}"
  : "${TGT_PART_URL_PREFIX=https://alpo.ge/lean.tar.gz.part}"
  : "${TGT_PART_COUNT=14}"
  : "${TGT_TARBALL_SHA256=9631b4f020199e580ba86178cb56c6e9b09f690c2369a80dc4334aa93f49c7fc}"
  : "${TGT_TARBALL_NAME=lean.tar.gz}"
  : "${TGT_ARCHIVE_PREFIX=lean/}"
  : "${TGT_SRC_DIR=src}"
  : "${TGT_ARCHIVE_ALLOW_EXEC=0}"
  : "${TGT_RECORDS_DIR=records/source}"
  : "${TGT_ROOT_MODULE=Main}"
  : "${TGT_THEOREMS=riemannHypothesis riemannZeta_eq_zero_re LFunction_ne_zero_of_half_lt_re LFunction_eq_zero_re LFunction_eq_zero_re_of_isPrimitive}"
  : "${TGT_PRIMARY_THEOREM=riemannHypothesis}"
  : "${TGT_STATEMENT_CONST=RiemannHypothesis}"
  : "${TGT_STATEMENT_CONST_MODULE=Mathlib.NumberTheory.LSeries.RiemannZeta}"
  : "${TGT_REPORT_CONSTS=RiemannHypothesis riemannZeta DirichletCharacter.LFunction}"
  : "${TGT_PROTECTED_NAMES=RiemannHypothesis riemannZeta LFunction}"
  : "${TGT_SMOKE_TARGETS=Statements Formalism.GammaFactorNonvanishing.RhOfRight}"
  : "${TGT_PROBE_MODULE=Formalism.GammaFactorNonvanishing.RhOfRight}"
  : "${TGT_PROBE_THEOREM=Formalism.VW.rh_of_right}"
  : "${TGT_MATHLIB_TAG=v4.33.1}"
  : "${TGT_S10_PATTERN=kexactB|kc%|kcopy|tr_via|tr_clause|cpt_copy_thms}"
  : "${TGT_S10_COUNT=77}"
else
  RH_TARGET_IS_DEFAULT=0
  # Any other target is described by its profile and by nothing else: TGT_ values from config.env are dropped
  # before it is read, and the default target's values are not inherited. The profile is sourced as shell
  # code, so it must hold assignments to TGT_ variables only.
  [ -f "$REPO_ROOT/targets/$RH_TARGET/target.env" ] || die "target '$RH_TARGET' has no profile: $REPO_ROOT/targets/$RH_TARGET/target.env not found (see targets/README.md)"
  unset ${!TGT_@}
  . "$REPO_ROOT/targets/$RH_TARGET/target.env"
  _rh_env_wins
  # The optional settings that have a value when a profile leaves them out.
  if [ "${TGT_SOURCE_KIND:-}" = git ]; then : "${TGT_TARBALL_NAME:=source.tar}"; else : "${TGT_TARBALL_NAME:=source.tar.gz}"; fi
  # The audit looks for declarations by the last component of a name (the default target lists LFunction,
  # not DirichletCharacter.LFunction), so the protected name that follows from the statement constant is
  # its last component.
  : "${TGT_ARCHIVE_ALLOW_EXEC:=0}" "${TGT_REPORT_CONSTS:=${TGT_STATEMENT_CONST:-}}"
  _rh_last="${TGT_STATEMENT_CONST:-}"; : "${TGT_PROTECTED_NAMES:=${_rh_last##*.}}"
fi
# From here on every TGT_ variable is set, some of them to nothing.
for _v in TGT_SOURCE_KIND TGT_PART_URL_PREFIX TGT_PART_COUNT TGT_TARBALL_SHA256 TGT_GIT_URL TGT_GIT_COMMIT TGT_GIT_SUBDIR TGT_TARBALL_NAME TGT_ARCHIVE_PREFIX TGT_SRC_DIR TGT_ARCHIVE_ALLOW_EXEC TGT_RECORDS_DIR TGT_ROOT_MODULE TGT_THEOREMS TGT_PRIMARY_THEOREM TGT_STATEMENT_CONST TGT_STATEMENT_CONST_MODULE TGT_REPORT_CONSTS TGT_PROTECTED_NAMES TGT_SMOKE_TARGETS TGT_PROBE_MODULE TGT_PROBE_THEOREM TGT_MATHLIB_TAG TGT_S10_PATTERN TGT_S10_COUNT; do
  eval ": \"\${$_v=}\""
done
# Three settings had RH_ names before there were profiles. For the default target a value given under the old
# name still wins, as it did, and an empty one still means the built-in value. For any other target only the
# TGT_ value counts. Either way both names hold the value in force from here on.
if [ "$RH_TARGET_IS_DEFAULT" = 1 ]; then
  TGT_PART_URL_PREFIX="${RH_PART_URL_PREFIX:-$TGT_PART_URL_PREFIX}"
  TGT_PART_COUNT="${RH_PART_COUNT:-$TGT_PART_COUNT}"
  TGT_TARBALL_SHA256="${RH_TARBALL_SHA256:-$TGT_TARBALL_SHA256}"
fi
RH_PART_URL_PREFIX="$TGT_PART_URL_PREFIX"; RH_PART_COUNT="$TGT_PART_COUNT"; RH_TARBALL_SHA256="$TGT_TARBALL_SHA256"

# What must be set, and the form of the values that become paths or name a commit.
_rh_need="TGT_SOURCE_KIND TGT_ARCHIVE_PREFIX TGT_SRC_DIR TGT_RECORDS_DIR TGT_ROOT_MODULE TGT_THEOREMS TGT_PRIMARY_THEOREM TGT_STATEMENT_CONST TGT_STATEMENT_CONST_MODULE TGT_SMOKE_TARGETS"
case "$TGT_SOURCE_KIND" in
  tarball-parts) _rh_need="$_rh_need TGT_PART_URL_PREFIX TGT_PART_COUNT TGT_TARBALL_SHA256" ;;
  git) _rh_need="$_rh_need TGT_GIT_URL TGT_GIT_COMMIT" ;;
  '') ;;
  *) die "target '$RH_TARGET': TGT_SOURCE_KIND must be tarball-parts or git (got '$TGT_SOURCE_KIND')" ;;
esac
for _v in $_rh_need; do
  eval "[ -n \"\$$_v\" ]" || die "target '$RH_TARGET': $_v is required and is not set (see targets/README.md)"
done
# _rh_bad_path <value>: true unless the value is a relative path of plain components: none of them empty,
# '.' or starting with '-', no '..' anywhere (not even inside a component), no slash at either end, no
# backslash, no control character. This is the rule rhv_tools.py applies to the names it is given
# (dir_arg_problem), and a little stricter.
_rh_bad_path() {
  case "$1" in ''|/*|*/|*//*|*..*|-*|*/-*|*\\*|*[[:cntrl:]]*) return 0 ;; esac
  case "/$1/" in */./*) return 0 ;; esac
  return 1
}
case "$TGT_ARCHIVE_PREFIX" in
  */) _rh_bad_path "${TGT_ARCHIVE_PREFIX%/}" && _rh_len=bad || _rh_len=ok ;;
  *) _rh_len=bad ;;
esac
[ "$_rh_len" = ok ] || die "target '$RH_TARGET': TGT_ARCHIVE_PREFIX must be a relative directory name of plain components with its closing slash: no '..' anywhere, no '.' component, none starting with '-' (got '$TGT_ARCHIVE_PREFIX')"
# TGT_SRC_DIR may be '.', the project directory itself (Lake's default when the lakefile names no srcDir).
[ "$TGT_SRC_DIR" = . ] || ! _rh_bad_path "$TGT_SRC_DIR" || die "target '$RH_TARGET': TGT_SRC_DIR must be '.' or a relative path of plain components with no slash at either end: no '..' anywhere, no '.' component, none starting with '-' (got '$TGT_SRC_DIR')"
! _rh_bad_path "$TGT_RECORDS_DIR" || die "target '$RH_TARGET': TGT_RECORDS_DIR must be a relative path of plain components with no slash at either end: no '..' anywhere, no '.' component, none starting with '-' (got '$TGT_RECORDS_DIR')"
case "$TGT_TARBALL_NAME" in
  ''|*/*|.|..) die "target '$RH_TARGET': TGT_TARBALL_NAME must be a file name (got '$TGT_TARBALL_NAME')" ;;
esac
case "$TGT_ARCHIVE_ALLOW_EXEC" in
  0|1) ;;
  *) die "target '$RH_TARGET': TGT_ARCHIVE_ALLOW_EXEC must be 0 or 1 (got '$TGT_ARCHIVE_ALLOW_EXEC')" ;;
esac
if [ "$TGT_SOURCE_KIND" = git ]; then
  case "$TGT_GIT_COMMIT" in *[!0123456789abcdef]*) _rh_len=0 ;; *) _rh_len=${#TGT_GIT_COMMIT} ;; esac
  [ "$_rh_len" = 40 ] || die "target '$RH_TARGET': TGT_GIT_COMMIT must be a commit's 40 hexadecimal characters in lower case; a branch or tag name is refused (got '$TGT_GIT_COMMIT')"
fi

# ---- Paths ------------------------------------------------------------------------------------------------
# One working directory per target. The default target's is RH_WORKDIR, as before. Any other target's is
# RH_WORKDIR with -<name> added, unless RH_WORKDIR was given in the environment: then it is used as given.
RH_WORKDIR="${RH_WORKDIR:-$REPO_ROOT/work}"
if [ "$RH_TARGET_IS_DEFAULT" = 0 ] && [ -z "$_rh_workdir_given" ]; then
  while [ "${RH_WORKDIR%/}" != "$RH_WORKDIR" ] && [ -n "${RH_WORKDIR%/}" ]; do RH_WORKDIR="${RH_WORKDIR%/}"; done
  RH_WORKDIR="$RH_WORKDIR-$RH_TARGET"
fi
RH_DL="$RH_WORKDIR/download"          # the source as fetched: the parts and the tarball, or a clone and its tar file
RH_PROJ="$RH_WORKDIR/extract/${TGT_ARCHIVE_PREFIX%/}"   # the extracted Lean project (lakefile.toml lives here)
RH_SRC="$RH_PROJ/$TGT_SRC_DIR"        # the project's Lean sources
[ "$TGT_SRC_DIR" = . ] && RH_SRC="$RH_PROJ"
RH_LOGS="$RH_WORKDIR/logs"
RH_AN="$RH_WORKDIR/analysis"          # derived data (import graph, timings)
RECORDS="$REPO_ROOT/records"
RH_RECORDS_SRC="$REPO_ROOT/$TGT_RECORDS_DIR"       # recorded facts about this target's source
RH_TARBALL="$RH_DL/$TGT_TARBALL_NAME"              # the archive file that is inspected and extracted
RH_PART_BASENAME="$TGT_TARBALL_NAME.part"          # local part files are <basename>NN
RH_EXPECTED="$RH_RECORDS_SRC/expected.json"        # recorded facts about the source, if present
RH_PARTS_RECORD="$RH_RECORDS_SRC/parts.sha256"     # recorded SHA-256 of each part, if present
RH_GIT_DIR="$RH_DL/repo.git"                       # the clone of a git source (nothing is checked out in it)
RH_TOOLS="$REPO_ROOT/scripts/verify/rhv_tools.py"

# LEAN_PATH for running lean / leanchecker directly, without going through lake.
lean_path() { local p="$RH_PROJ/.lake/build/lib/lean" d; for d in "$RH_PROJ"/.lake/packages/*/.lake/build/lib/lean; do p="$p:$d"; done; printf '%s' "$p"; }

# The file .rh-target in a working directory names the target the directory belongs to. A directory with files
# in it and no such file is from before these files were written and belongs to the default target.
# target_guard stops the script if the working directory is another target's. It only reads, and prints nothing.
target_guard() {
  local marker="$RH_WORKDIR/.rh-target" owner=""
  if [ -e "$marker" ]; then
    IFS= read -r owner 2>/dev/null < "$marker" || true
    [ "$owner" = "$RH_TARGET" ] || die "the working directory $RH_WORKDIR belongs to target '$owner' (its file .rh-target says so) and this command is for target '$RH_TARGET'. Every target has a working directory of its own: see targets/README.md"
  elif [ "$RH_TARGET_IS_DEFAULT" = 0 ] && [ -d "$RH_WORKDIR" ] && [ -n "$(ls -A -- "$RH_WORKDIR" 2>/dev/null)" ]; then
    die "the working directory $RH_WORKDIR has files in it and no .rh-target file, so it is taken to belong to the default target, alpoge-rh. Target '$RH_TARGET' will not use it: give it another RH_WORKDIR (see targets/README.md)"
  fi
  return 0
}
# Create the working directory and, if it has none, its .rh-target file. A script that writes into the working
# directory without calling ensure_dirs calls this first.
claim_workdir() {
  mkdir -p "$RH_WORKDIR" || return
  [ -e "$RH_WORKDIR/.rh-target" ] || (set -C; printf '%s\n' "$RH_TARGET" > "$RH_WORKDIR/.rh-target") 2>/dev/null
  target_guard
}
# Create the working directory's three subdirectories and, if it has none, its .rh-target file. A script calls
# this before it writes anything into the working directory.
ensure_dirs() {
  claim_workdir || return
  mkdir -p "$RH_DL" "$RH_LOGS" "$RH_AN"
}
# source_record <sha256>: the line that names an archive. Its SHA-256 and, for a git source, the address,
# commit, directory and prefix it is written from. 01_fetch.sh writes it beside the tar file of a git source
# (<tar file>.from); 02_inspect_and_extract.sh writes it beside the tree it extracts for a target other than
# the default one (RH_WORKDIR/extract.from).
source_record() {
  if [ "$TGT_SOURCE_KIND" = git ]; then
    printf 'sha256 %s git %s commit %s subdir %s prefix %s\n' "$1" "$TGT_GIT_URL" "$TGT_GIT_COMMIT" "${TGT_GIT_SUBDIR:-.}" "$TGT_ARCHIVE_PREFIX"
  else
    printf 'sha256 %s\n' "$1"
  fi
}
# For a target other than the default one: stop the script if there is an extracted tree and its extract.from
# is not the line the profile gives now. The whole line is compared, pinned or not: the SHA-256 (the pinned one,
# or with none pinned the one in the line) and, for a git source, the address, commit, directory and prefix. A
# change to any of them means extracting again, even one that leaves the archive the same byte for byte.
# Changing the profile then cannot leave a step at work on the tree of another archive. Nothing is checked for
# the default target, as before there were targets.
require_extract_from() {
  local from="" sha want
  [ "$RH_TARGET_IS_DEFAULT" = 1 ] && return 0
  [ -d "$RH_WORKDIR/extract" ] || return 0
  [ -f "$RH_WORKDIR/extract.from" ] && IFS= read -r from < "$RH_WORKDIR/extract.from"
  sha=${from#sha256 }; sha=${sha%% *}
  if [ -n "$RH_TARBALL_SHA256" ]; then want=$(source_record "$RH_TARBALL_SHA256"); else want=$(source_record "$sha"); fi
  [ -n "$from" ] && [ "$from" = "$want" ] && return 0
  die "the tree in $RH_WORKDIR/extract is not recorded as extracted from the source that the profile of target '$RH_TARGET' names now: $RH_WORKDIR/extract.from says '${from:-nothing}', and the profile gives '$want'. Any difference counts, even one that leaves the archive the same byte for byte. Move the tree aside, or delete it, then run 01_fetch.sh and 02_inspect_and_extract.sh again."
}

unset _v _rh_keep _rh_need _rh_len _rh_last _rh_workdir_given; unset -f _rh_env_wins _rh_bad_path
target_guard
