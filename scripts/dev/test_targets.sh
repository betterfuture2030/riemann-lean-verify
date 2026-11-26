#!/bin/bash
# test_targets.sh - an offline test of the target profiles (targets/README.md): scripts/lib.sh, the scripts and the
#   tool that read a profile, and the default target's behaviour compared with the last commit before profiles.
#
# What it does: works in a scratch copy of the repository's scripts, analysis, records/source and targets (the files
#   git tracks there, and targets/ whether git tracks it or not; never a config.env or .private-patterns file), so
#   that it can add made-up profiles and a config.env of its own. The base commit (TARGETS_TEST_BASE; by default
#   5c2cc89, the last commit before profiles, which was main when this was written) is read with git archive. Cases,
#   numbered as in the output:
#    1  targets/alpoge-rh/target.env and the values built into scripts/lib.sh agree for every TGT_ name in the table
#       of targets/README.md; the profile assigns nothing else; read as a profile, it gives the same settings.
#    2  With no target named, lib.sh and common.sh set every variable the base commit's set, to the same value: with
#       no config.env; config.env setting RH_WORKDIR, RH_PART_COUNT and GCP_ values; RH_WORKDIR and
#       RH_TARBALL_SHA256 in the environment over config.env; empty values in the environment; config.example.env.
#    3  Sourcing lib.sh (alone and with common.sh) prints nothing on standard output: the default target, with a
#       config.env, and a made-up target.
#    4  A made-up git source: a repository made here (a Lake project in proj/ with two sources, a name that is not
#       ASCII, an empty file and a name longer than 100 bytes, and a file outside proj/) and a profile for it.
#       01_fetch.sh writes the tar file and says NOT PINNED with the line that pins it; a second run and --redownload
#       give the same SHA-256; the tar holds the commit's files of proj/, sorted, with no times or owners; pinned, it
#       is verified; pinned wrong, status 1. 02 --write-expected extracts work-<name>/extract/proj byte for byte as
#       the commit has it and records what it saw; a second run compares with the record; --verify-tree passes and
#       notices a changed file.
#    5  Refusals, each with a non-zero status and a message that names the problem: RH_TARGET with an upper-case
#       letter, a leading '-' or '../x'; a target with no profile; a profile missing a required variable;
#       TGT_GIT_COMMIT a branch name, 39 characters or upper case; TGT_ARCHIVE_PREFIX without its closing slash, with
#       '..', or absolute; an unknown TGT_SOURCE_KIND; a commit with a symbolic link; a commit with a submodule; an
#       executable file (02 refuses it unless TGT_ARCHIVE_ALLOW_EXEC=1); 04 refuses a lakefile.lean before it runs
#       anything.
#    6  The working directory and its marker .rh-target: the first script that writes names the target in it (the
#       default target's too); a default-target command stops in a directory marked for another target; another
#       target refuses a directory that has files and no marker, or another target's marker; RH_WORKDIR given in the
#       environment is used as given; otherwise another target's directory is RH_WORKDIR with -<name> added; the
#       paths derived from it; analysis/rhpaths.py says the same and stops the same way.
#    7  The axiom check file: rhv_tools.py axioms-body with the default names prints the body file byte for byte, and
#       with others differs from it in the four lines that name constants and nowhere else. With a stand-in lean
#       (which only answers --version) and a fake compiled module, 08_check_axioms.sh writes the same .lean file as
#       the base commit's 08 (full, --deep, --probe); for a made-up target, the file is that target's, the log names
#       the target and the summary its commit; --probe with no probe lemma in the profile stops.
#    8  rhv_tools.py tar-inspect with none of its new arguments, against the base commit's, on made-up gzipped
#       tarballs under lean/: the same output and status (a clean one, and one with every kind of entry refused);
#       the same --write-expected JSON; the same --verify-tree report. The one line that says nothing was recorded is
#       in capitals now, on purpose (the interface says so); that line is compared apart. audit-literals is unchanged.
#    9  reproduce_findings.sh for made-up targets: with empty TGT_MATHLIB_TAG and TGT_S10_PATTERN and nothing
#       recorded, S5, S9, S10 (and S2-S4, S6-S8) are n/a, and the run does not fail; with a record,
#       S2-S4 pass; S10 with a pattern and no count is n/a, with the right count passes.
#   10  Values in the environment win over config.env and over the profile (RH_TARGET, RH_WORKDIR, a TGT_ variable);
#       a TGT_ value in config.env does not reach another target's settings.
#   11  The default target's 01 (with the tarball present, and --check-only), 02 (extracting, again, --verify-tree)
#       and 03 on a made-up tarball, against the base commit's: the same output apart from times and paths, the
#       same status, the same extracted files.
#   12  A profile whose sources are the project directory itself (TGT_SRC_DIR=.), which lib.sh accepts and 03 has
#       code for: 01, 02 and 03 work on it, and 03 leaves out .lake.
#   13  No stand-in for the network or the toolchain was called.
#   14  rhv_tools.py git-export on commits made here with git mktree. Each of these is refused with status 1, a
#       message that names it and no file written: a '.git' component (proj/.git/config, one further down, .GIT,
#       '.g<U+200C>it' with a character macOS leaves out of names, git~1, '.git.', '.git '), a '.lake' component
#       (proj/.lake/build/x.olean), and names that are one name on macOS (Foo.lean and foo.lean; e-acute in NFC
#       and in NFD; directories A/ and a/ with different files). Near misses (.gitignore, .github/, git~2,
#       .lakefile, ...) are written. 01_fetch.sh stops on a commit with proj/.git/config and writes no tar file.
#   15  rhv_tools.py tar-inspect on gzipped tarballs under lean/ made here with Python's tarfile: the same
#       refusals (status 1, the reason, nothing recorded). With the arguments 02 now gives it for the default
#       target (--prefix lean/ --src-dir src), the base commit's output, byte for byte, on the clean tarball and on
#       one of near misses. --src-dir . counts the Lean files under the prefix.
#   16  TGT_SRC_DIR=. end to end, with the .lake directory case 12 made after extraction: 01 again; count_sources; 02
#       --write-expected (which creates the records directory) and 02 again; 03 --write-expected, then 03 with rg
#       and with grep against that record; 02 --verify-tree; import_graph.py and closure_stats.py with no
#       arguments; reproduce_findings.sh, whose S10 counts a hidden file and an ignored one and not one in .lake
#       (with rg, and with grep when rg can be left off the PATH).
#   17  lib.sh refuses TGT_SRC_DIR './src', 'src/.', 'src/', '/src', 'a//b', '..' and 'a\b' (and './src' for the
#       default target too), TGT_RECORDS_DIR '.', 'records/./x', '/x' and 'x/', TGT_ARCHIVE_PREFIX 'a/./' and
#       'a//'; it accepts TGT_SRC_DIR '.' (RH_SRC is the project) and 'src/Sub', and TGT_ARCHIVE_PREFIX 'a/b/'.
#   18  extract.from: 02 writes it for a git target. After a change of commit 01 says to use --redownload, and
#       02, with the tree moved aside, does not extract the first commit's tar file, which is still there, for the
#       second commit. After 01 --redownload 02 stops with 'not extracted from the archive' and changes nothing; with
#       the tree moved aside it extracts the new commit; a tree with no extract.from is not used. The default
#       target's 02 writes none.
#   19  cloud/gcp/pilot_local.sh with a made-up target stops before anything else ('launch pilot', 'ledger',
#       'teardown'): a stand-in gcloud first on the PATH is not called and nothing is written. With the default
#       target it gets past that line: 'ledger' shows an empty ledger.
#   20  00_check_prereqs.sh --install-elan, with stand-ins for curl and sh and no elan on the PATH: .rh-target
#       names the target (a made-up one, and the default one), and the installer is fetched into it and run.
#   21  06_progress.sh on a made-up build log with a job line marked U+2139 (information): for the default target
#       it is not counted, and the output is the base commit's; for a made-up target it is counted.
#   22  reproduce_findings.sh for the default target on a made-up tarball, the Mathlib tag answered by a repository
#       made here (url.<path>.insteadOf, so nothing leaves the machine). With records/source/import_graph_summary.json
#       removed: S9 FAIL and status 1, as with the base commit's script. With a record: every claim reproduces. With
#       TGT_S10_PATTERN empty: an S10 row that is n/a, no 'All tier-S claims reproduced.', and none failed.
#   23  TGT_PROTECTED_NAMES defaults to the last component of TGT_STATEMENT_CONST (Foo.Bar gives Bar; a profile's
#       own value is kept), and 03 then lists the 'def Bar' inside 'namespace Foo', with rg and with grep.
#   24  rhv_tools.py axioms-body refuses 'caf<e-acute>' and '<lambda>x' (status 2, nothing on standard output, the
#       name said once). 08_check_axioms.sh with such a statement constant stops before it runs lean.
#   25  analysis/rhpaths.py: with RH_PROJ, RH_AN and RH_LOGS in the environment and RH_TARGET unset,
#       import_graph.py works although RH_WORKDIR is marked for another target, without asking lib.sh (a stand-in
#       bash first on the PATH is not called), and its root module is Main; another target with TGT_SRC_DIR and
#       TGT_ROOT_MODULE in the environment too is not asked either; without RH_PROJ, the stand-in bash is called
#       (and the default layout is refused), and with the real bash lib.sh is asked and stops.
#   26  tar-inspect refuses a file where another entry needs a directory, '.git::$INDEX_ALLOCATION', 'LAKE~1' and an
#       unassigned code point, and '--src-dir src/'; it takes '--src-dir .'. rhv_tools.py import-graph does not walk
#       the .lake directory of a project directory. 01 writes source.tar.from (also when the pinned SHA-256 is wrong);
#       02 and 01 --check-only refuse an unpinned tar file without it, and 02 one whose profile names another
#       directory; extract.from then names the archive, and 09 stops once the profile pins another SHA-256.
#   27  tar-inspect refuses an archive with data after its end (a damaged header or one empty block before more
#       entries, gzipped or not; a second gzip member after the end blocks), one that cannot be read to its end
#       (bytes after the last gzip member, a truncated file), a component over 255 bytes and a name over 1024 (40,000
#       components, refused at once); it accepts zero bytes after the end, and reports directory entries once each.
#       git-export refuses a component over 255 bytes. --check-extracted passes what tar wrote and refuses a file
#       that is not an entry (also in .lake), links, an executable bit, a missing entry, an empty directory and a
#       hard link. 02 with a stand-in tar that plants a file in .lake stops and puts nothing in place. With a pin left
#       over from an earlier commit, 01 --check-only and 02 refuse the old commit's file; a clone made from another
#       address is refused until --redownload.
#   28  Cases 14 to 27 called no stand-in for the network or the toolchain either (nor gcloud).
# What it changes on disk: only a temporary directory of its own under TMPDIR, removed at the end (kept with
#   TARGETS_TEST_KEEP=1). The repository is only read.
# No network and no Lean: every command runs with a clean environment (env -i) whose PATH starts with stand-ins for
#   curl, wget, lean, lake, elan, leanchecker, ps and lsof, and git may use local repositories only
#   (GIT_ALLOW_PROTOCOL=file). The stand-in lean answers --version and runs nothing; the others log the call and fail.
#   From case 14 on, some commands get a narrower PATH in which python3 and git are reached through small wrappers
#   and their own directories are left out, so that an elan, gcloud or rg installed beside them is not found; cases
#   19, 20 and 25 put further stand-ins (gcloud; curl and sh; bash) first on the PATH.
# How long it takes: about 40 seconds.
# Requires: bash 3.2 or later, git, python3, tar, gzip.
# Usage: scripts/dev/test_targets.sh        Prints ok or FAIL for each check, with its case number, then the count.
#   TARGETS_TEST_BASE=<commit>  compare the default target with this commit instead
# Exit status: 0 if every check passed, 1 otherwise.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/../.." && pwd)"
BASE="${TARGETS_TEST_BASE:-5c2cc8957e93cfb2f2ad2f07177ed8e570efdb04}"
TMPD=$(mktemp -d "${TMPDIR:-/tmp}/targets_test.XXXXXX") || exit 1
TMPD=$(cd "$TMPD" && pwd -P) || exit 1
if [ "${TARGETS_TEST_KEEP:-0}" = 1 ]; then trap 'echo "kept $TMPD"' EXIT; else trap 'rm -rf "${TMPD:?}"' EXIT; fi
START=$(date +%s)
N=0; FAILS=0; SKIPS=0; C=0
section() { C=$1; echo "-- $1. $2"; }
ok()   { N=$((N + 1)); printf 'ok    %-3s %s\n' "$C" "$1"; }
fail() { N=$((N + 1)); FAILS=$((FAILS + 1)); printf 'FAIL  %-3s %s\n' "$C" "$1${2:+: $2}"; }
skip() { SKIPS=$((SKIPS + 1)); printf 'SKIP  %-3s %s\n' "$C" "$1"; }
res()  { if [ "$2" = 0 ]; then ok "$1"; else fail "$1" "${3:-}"; fi; }    # res <description> <status of the test> [detail]
# (Arguments are expanded left to right, so a $(...) in the description runs before $? is read: then pass the status
# in a variable. A $(...) in the detail, after $?, is harmless.)
sha()  { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }
tailof() { tail -n "${2:-3}" "$1" 2>/dev/null | tr '\n' ' ' | cut -c1-400; }     # the last lines of a file, on one line

PY3=$(command -v python3) || { echo "python3 is needed"; exit 2; }
GIT=$(command -v git) || { echo "git is needed"; exit 2; }

# ---------------------------------------------------------------- stand-ins and the clean environment
STUB="$TMPD/stub"; STUBLOG="$TMPD/stub.log"; mkdir -p "$STUB" "$TMPD/home" "$TMPD/tmp"; : > "$STUBLOG"
for t in curl wget lake elan leanchecker; do
  printf '#!/bin/sh\n# stand-in made by test_targets.sh: logs the call and fails\necho "%s $*" >> "%s"\nexit 1\n' "$t" "$STUBLOG" > "$STUB/$t"
done
printf '#!/bin/sh\n# stand-in: no processes, so that nothing running on this machine is looked at\nexit 0\n' > "$STUB/ps"
printf '#!/bin/sh\nexit 1\n' > "$STUB/lsof"
cat > "$STUB/lean" <<EOF
#!/bin/sh
# stand-in made by test_targets.sh: answers --version as the pinned lean does, and runs nothing
if [ "\${1:-}" = --version ]; then echo "Lean (version 4.33.1, test stand-in, Release)"; exit 0; fi
echo "lean \$*" >> "$STUBLOG.lean"
exit 0
EOF
chmod +x "$STUB"/*
CPATH="$STUB:$(dirname "$PY3"):$(dirname "$GIT"):/usr/bin:/bin:/usr/sbin:/sbin"
cenv() { env -i HOME="$TMPD/home" PATH="$CPATH" TMPDIR="$TMPD/tmp" GIT_ALLOW_PROTOCOL=file GIT_CONFIG_NOSYSTEM=1 \
           GIT_TERMINAL_PROMPT=0 PYTHONDONTWRITEBYTECODE=1 "$@"; }

# dump.sh <file to source>... -- <name>...: sources the files, then prints NAME=[value], or NAME unset, for each name.
DUMP="$TMPD/dump.sh"
cat > "$DUMP" <<'EOF'
while [ $# -gt 0 ] && [ "$1" != -- ]; do . "$1" || exit 99; shift; done
[ $# -gt 0 ] && shift
for _n in "$@"; do
  if eval "[ -n \"\${$_n+x}\" ]"; then eval "printf '%s=[%s]\n' \"\$_n\" \"\$$_n\""; else printf '%s unset\n' "$_n"; fi
done
EOF
# libvar <NAME> [VAR=value ...]: the value the scratch copy's lib.sh gives NAME with these variables in the environment
libvar() { local n=$1; shift; cenv "$@" /bin/bash "$DUMP" "$NEW/scripts/lib.sh" -- "$n" 2>/dev/null | sed -n "s/^$n=\[\(.*\)\]\$/\1/p"; }
# record <target> <sha256>: the line lib.sh's source_record gives for that target's profile as it is now
record() { cenv RH_TARGET="$1" /bin/bash -c '. "$1/scripts/lib.sh" && source_record "$2"' _ "$NEW" "$2" 2>&1; }
# refused <description> <text the output must contain> [VAR=value ...] <command...>: a non-zero status and that text
refused() {
  local d=$1 want=$2 rc; shift 2
  cenv "$@" > "$TMPD/refused.out" 2>&1; rc=$?
  [ "$rc" != 0 ] && grep -q -- "$want" "$TMPD/refused.out"
  res "$d" $? "status $rc: $(tailof "$TMPD/refused.out")"
}
# norm <file> <path>=<word> ...: the file without the times at the start of log lines, with each path replaced
norm() {
  local f=$1 a s=""; shift
  for a in "$@"; do s="$s -e s#${a%%=*}#${a#*=}#g"; done
  # shellcheck disable=SC2086
  sed -e 's/^[0-9]\{4\}-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]  //' $s "$f"
}

# ---------------------------------------------------------------- the scratch copy and the base commit
NEW="$TMPD/new"; MAIN="$TMPD/base"; mkdir -p "$NEW" "$MAIN"
if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  ( cd "$ROOT" && { git ls-files -z -- scripts analysis records/source config.example.env; [ -d targets ] && find targets -type f -print0; } )
else
  ( cd "$ROOT" && find scripts analysis records/source targets config.example.env -type f -print0 2>/dev/null )
fi | "$PY3" -I -B -c '
import os, shutil, sys
src, dst = sys.argv[1], sys.argv[2]
names = [n for n in sys.stdin.buffer.read().decode("utf-8", "surrogateescape").split("\0") if n]
for n in sorted(set(names)):
    if os.path.basename(n) in ("config.env", ".private-patterns"):
        continue
    s = os.path.join(src, n)
    if not os.path.isfile(s) or os.path.islink(s):
        continue
    d = os.path.join(dst, n)
    os.makedirs(os.path.dirname(d), exist_ok=True)
    shutil.copy2(s, d)
' "$ROOT" "$NEW"
for f in scripts/lib.sh scripts/common.sh scripts/verify/rhv_tools.py targets/README.md targets/alpoge-rh/target.env; do
  [ -f "$NEW/$f" ] || { echo "the scratch copy has no $f; is $ROOT this repository?"; exit 2; }
done
HAVE_BASE=0
if git -C "$ROOT" rev-parse --verify --quiet "$BASE^{commit}" >/dev/null 2>&1 \
   && git -C "$ROOT" archive --format=tar "$BASE" -- scripts analysis records/source 2>/dev/null | tar -xf - -C "$MAIN" 2>/dev/null \
   && [ -f "$MAIN/scripts/lib.sh" ]; then
  HAVE_BASE=1
  echo "INFO  base commit for the comparisons: $(git -C "$ROOT" rev-parse --short "$BASE")"
  grep -q RH_TARGET "$MAIN/scripts/lib.sh" && echo "INFO  that commit already has target profiles: the comparisons with it do not show behaviour from before them"
else
  echo "INFO  the base commit $BASE cannot be read from $ROOT: the comparisons with it are skipped"
fi
setcfg() { printf '%s\n' "$1" > "$NEW/config.env"; }      # the scratch copy's config.env
nocfg() { rm -f "$NEW/config.env"; }

# ---------------------------------------------------------------- made-up sources
FX="$TMPD/fx"; REPO="$FX/repo"; mkdir -p "$REPO"
g() { cenv GIT_AUTHOR_DATE=1700000000 GIT_COMMITTER_DATE=1700000000 git -C "$REPO" -c user.name=test -c user.email=test@example.com \
        -c commit.gpgsign=false -c core.hooksPath=/dev/null "$@"; }
MLREV=0123456789abcdef0123456789abcdef01234567
NONASCII=$(printf 'caf\303\251.md')
LONGNAME="src/Deep/$(printf '%070d' 0 | tr 0 d)/$(printf '%040d' 0 | tr 0 e).lean"
mkproject() { # mkproject <dir> <sources dir, or . >: a small Lake project
  local p=$1 s=$2
  mkdir -p "$p/$s/B" "$p/notes"
  printf 'name = "fixture"\ndefaultTargets = ["A"]\n\n[[require]]\nname = "mathlib"\ngit = "https://example.invalid/mathlib4"\nrev = "%s"\n\n[[lean_lib]]\nname = "A"\nsrcDir = "%s"\n' "$MLREV" "$s" > "$p/lakefile.toml"
  printf '{"version": "1.1.0",\n "packagesDir": ".lake/packages",\n "packages":\n [{"url": "https://example.invalid/mathlib4",\n   "type": "git",\n   "rev": "%s",\n   "name": "mathlib",\n   "inherited": false}],\n "name": "fixture",\n "lakeDir": ".lake"}\n' "$MLREV" > "$p/lake-manifest.json"
  echo 'leanprover/lean4:v4.33.1' > "$p/lean-toolchain"
  printf 'import B.C\n\n-- the root module of the made-up project\ntheorem a_thm : True := trivial\n' > "$p/$s/A.lean"
  printf 'def c : Nat := 1\ntheorem c_thm : c = 1 := rfl\n' > "$p/$s/B/C.lean"
  printf 'a note whose name is not ASCII\n' > "$p/notes/$NONASCII"
  : > "$p/EMPTY"
}
mkproject "$REPO/proj" src
mkdir -p "$REPO/proj/$(dirname "$LONGNAME")"; printf -- '-- a file whose name is longer than 100 bytes\n' > "$REPO/proj/$LONGNAME"
mkproject "$REPO/proj2" .
echo 'not part of the project' > "$REPO/README.md"
g init -q -b main . >/dev/null 2>&1 || { g init -q . && g symbolic-ref HEAD refs/heads/main; }
g add -A && g commit -q -m fixture || { echo "could not make the fixture repository"; exit 2; }
C_MAIN=$(g rev-parse HEAD)
# branch <name> <mode> <path> <contents or object id>: a commit on top of main with one more entry, made without a checkout
branch() {
  local obj=$2 t c
  case "$2" in 160000) obj=$4 ;; *) obj=$(printf '%s' "$4" | g hash-object -w --stdin) ;; esac
  g read-tree "$C_MAIN" && g update-index --add --cacheinfo "$2,$obj,$3" && t=$(g write-tree) \
    && c=$(g commit-tree "$t" -p "$C_MAIN" -m "$1") && g update-ref "refs/heads/$1" "$c" && g read-tree "$C_MAIN" && echo "$c"
}
C_LINK=$(branch link 120000 proj/src/Link.lean A.lean)
C_SUB=$(branch sub 160000 proj/sub 1111111111111111111111111111111111111111)
C_EXEC=$(branch exec 100755 proj/run.sh "$(printf '#!/bin/sh\necho run\n')")
[ -n "$C_LINK" ] && [ -n "$C_SUB" ] && [ -n "$C_EXEC" ] || { echo "could not make the fixture branches"; exit 2; }

fixprof() { # the made-up target's profile: a git source, the Lake project in proj/
  cat <<EOF
TGT_SOURCE_KIND=git
TGT_GIT_URL="$REPO"
TGT_GIT_COMMIT=$C_MAIN
TGT_GIT_SUBDIR=proj
TGT_TARBALL_SHA256=
TGT_ARCHIVE_PREFIX=proj/
TGT_SRC_DIR=src
TGT_RECORDS_DIR=targets/$1/records
TGT_ROOT_MODULE=A
TGT_THEOREMS="a_thm c_thm"
TGT_PRIMARY_THEOREM=a_thm
TGT_STATEMENT_CONST=Fixture.Statement
TGT_STATEMENT_CONST_MODULE=Fixture.Defs
TGT_SMOKE_TARGETS="A"
TGT_MATHLIB_TAG=
EOF
}
# prof <name> [VAR=value | VAR-] ...: write targets/<name>/target.env, the made-up profile with these lines set or removed
prof() {
  local name=$1 a f; shift
  f="$NEW/targets/$name/target.env"; mkdir -p "$NEW/targets/$name"
  fixprof "$name" > "$f.tmp"
  for a in "$@"; do
    case "$a" in
      *=*) grep -v "^${a%%=*}=" "$f.tmp" > "$f.tmp2"; printf '%s\n' "$a" >> "$f.tmp2" ;;
      *-) grep -v "^${a%-}=" "$f.tmp" > "$f.tmp2" ;;
    esac
    mv "$f.tmp2" "$f.tmp"
  done
  { echo "# made by scripts/dev/test_targets.sh"; cat "$f.tmp"; } > "$f"; rm -f "$f.tmp"
}
prof fix-git

# Made-up gzipped tarballs under lean/ (cases 6, 8, 11): a clean one (and the same uncompressed), and one with every
# kind of entry tar-inspect refuses.
TB="$FX/tarballs"; mkdir -p "$TB"
"$PY3" -I -B - "$TB" "$MLREV" <<'PY'
import gzip, io, os, sys, tarfile
out, rev = sys.argv[1], sys.argv[2]
files = [
    ("lean/lakefile.toml", 'name = "rh"\n\n[[require]]\nname = "mathlib"\ngit = "https://example.invalid/mathlib4"\nrev = "%s"\n' % rev),
    ("lean/lake-manifest.json", '{"packages": [{"name": "mathlib", "rev": "%s", "type": "git"}], "name": "rh"}\n' % rev),
    ("lean/lean-toolchain", "leanprover/lean4:v4.33.1\n"),
    ("lean/src/Main.lean", "import Statements\n-- sorry is only a word in this comment\ntheorem riemannHypothesis : True := trivial\n"),
    ("lean/src/Statements.lean", "set_option maxHeartbeats 400000\ndef S : Prop := True\n"),
    ("lean/src/B/C.lean", "def c : Nat := 1\n"),
    ("lean/README.md", "made up\n"),
    ("lean/docs/notes.txt", ""),
]
def add(tf, name, data, mode=0o644, kind=tarfile.REGTYPE, link=""):
    ti = tarfile.TarInfo(name); ti.mode = mode; ti.mtime = 1700000000; ti.type = kind; ti.linkname = link
    b = data.encode()
    ti.size = len(b) if kind == tarfile.REGTYPE else 0
    tf.addfile(ti, io.BytesIO(b) if kind == tarfile.REGTYPE else None)
def write(path, extra):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w", format=tarfile.GNU_FORMAT) as tf:
        for n, d in files:
            add(tf, n, d)
        for e in extra:
            add(tf, *e)
    raw = buf.getvalue()
    if path.endswith(".gz"):
        with open(path, "wb") as fh:
            fh.write(gzip.compress(raw, mtime=0))
    else:
        with open(path, "wb") as fh:
            fh.write(raw)
write(os.path.join(out, "good.tar.gz"), [])
write(os.path.join(out, "good.tar"), [])
write(os.path.join(out, "bad.tar.gz"), [
    ("lean/src/Link.lean", "", 0o644, tarfile.SYMTYPE, "Main.lean"),
    ("lean/run.sh", "#!/bin/sh\n", 0o755),
    ("other/x.txt", "outside\n"),
    ("lean/src/../escape.txt", "dots\n"),
    ("lean/README.md", "a second entry of this name\n"),
    ("lean/dir/", "", 0o755, tarfile.DIRTYPE),
    ("lean/suid", "s\n", 0o4644),
    ("lean/a\\b.txt", "backslash\n"),
])
PY
GOODSHA=$(sha "$TB/good.tar.gz")
[ -n "$GOODSHA" ] && [ -f "$TB/bad.tar.gz" ] || { echo "could not make the fixture tarballs"; exit 2; }

# ================================================================ 1
section 1 "targets/alpoge-rh/target.env and the values built into scripts/lib.sh"
TABLE=$(awk -F'|' '/^\| *`TGT_/ { print $2 }' "$NEW/targets/README.md" | grep -o 'TGT_[A-Z0-9_]*' | LC_ALL=C sort -u | tr '\n' ' ')
ntab=$(echo $TABLE | wc -w | tr -d ' ')
[ "$ntab" -ge 20 ]; res "the table of targets/README.md names $ntab TGT_ settings" $? "$TABLE"
nocfg
# shellcheck disable=SC2086
cenv /bin/bash "$DUMP" "$NEW/scripts/lib.sh" -- $TABLE > "$TMPD/c1.lib" 2>&1
# shellcheck disable=SC2086
cenv /bin/bash "$DUMP" "$NEW/targets/alpoge-rh/target.env" -- $TABLE > "$TMPD/c1.prof" 2>&1
differ=""
for v in $TABLE; do
  a=$(grep "^$v[= ]" "$TMPD/c1.lib"); b=$(grep "^$v[= ]" "$TMPD/c1.prof")
  [ -n "$a" ] && [ "$a" = "$b" ] || differ="$differ $v (lib.sh: ${a:-nothing}; profile: ${b:-nothing});"
done
[ -z "$differ" ]; res "every one of them has the same value in lib.sh and in targets/alpoge-rh/target.env, variable by variable" $? "$differ"
assigned=$(cenv /bin/bash -c 'a=$(compgen -v | LC_ALL=C sort); . "$1" || exit 9; compgen -v | LC_ALL=C sort | LC_ALL=C comm -13 <(printf "%s\n" "$a") -' _ "$NEW/targets/alpoge-rh/target.env" \
           | grep -v -x -e a -e '_' -e 'BASH.*' -e PIPESTATUS | tr '\n' ' ')
stray=""; for v in $assigned; do case " $TABLE " in *" $v "*) ;; *) stray="$stray $v" ;; esac; done
[ -n "$assigned" ] && [ -z "$stray" ]; res "the profile assigns no variable that is not in the table" $? "not in the table:$stray"
builtin=$(cenv /bin/bash -c '. "$1" && compgen -v TGT_' _ "$NEW/scripts/lib.sh" 2>/dev/null | LC_ALL=C sort -u | tr '\n' ' ')
[ "$builtin" = "$TABLE" ]; res "lib.sh sets exactly the TGT_ variables of the table" $? "lib.sh: $builtin"
cp -R "$NEW/targets/alpoge-rh" "$NEW/targets/alpoge-copy"
C1N="$TABLE RH_PART_URL_PREFIX RH_PART_COUNT RH_TARBALL_SHA256"
# shellcheck disable=SC2086
cenv /bin/bash "$DUMP" "$NEW/scripts/lib.sh" -- $C1N > "$TMPD/c1.a" 2>&1
# shellcheck disable=SC2086
cenv RH_TARGET=alpoge-copy /bin/bash "$DUMP" "$NEW/scripts/lib.sh" -- $C1N > "$TMPD/c1.b" 2>&1
cmp -s "$TMPD/c1.a" "$TMPD/c1.b"; res "read as the profile of another target, the file gives the same settings" $? "$(diff "$TMPD/c1.a" "$TMPD/c1.b" | grep '^[<>]' | head -4 | tr '\n' ' ')"
rm -rf "${NEW:?}/targets/alpoge-copy"

# ================================================================ 2
section 2 "with no target named, lib.sh and common.sh set what the base commit's set"
C2NAMES="RH_WORKDIR RH_DL RH_PROJ RH_LOGS RH_AN RECORDS RH_TARBALL RH_PART_BASENAME RH_EXPECTED RH_PARTS_RECORD RH_TOOLS
 RH_PART_URL_PREFIX RH_PART_COUNT RH_TARBALL_SHA256 RH_JOBS GCP_PROJECT GCP_BUCKET GCP_REGION GCP_ZONES GCP_MACHINE_TYPE
 GCP_SPEND_CAP_USD GCP_RATE_USD_PER_HOUR GCP_SECOND_REPLAY GCP_KEEP_OLEANS RH_REPLAY_METHOD REPO_ROOT MARK_OK MARK_WARN MARK_FAIL"
inv() { # inv <description> [VAR=value ...]: the base commit's lib.sh and common.sh against the new ones, same inputs
  local d=$1 names; shift
  names=$(cenv "$@" /bin/bash -c '. "$1" && . "$2" && compgen -v' _ "$NEW/scripts/base_lib.sh" "$NEW/scripts/base_common.sh" 2>/dev/null | grep -E '^(RH_|GCP_)')
  # shellcheck disable=SC2086
  names=$(printf '%s\n' $C2NAMES $names | LC_ALL=C sort -u | tr '\n' ' ')
  # shellcheck disable=SC2086
  cenv "$@" /bin/bash "$DUMP" "$NEW/scripts/base_lib.sh" "$NEW/scripts/base_common.sh" -- $names > "$TMPD/c2.base" 2>&1
  # shellcheck disable=SC2086
  cenv "$@" /bin/bash "$DUMP" "$NEW/scripts/lib.sh" "$NEW/scripts/common.sh" -- $names > "$TMPD/c2.new" 2>&1
  cmp -s "$TMPD/c2.base" "$TMPD/c2.new"; rc=$?    # the status first: a $(...) in the description would reset $?
  res "$d: the same $(echo $names | wc -w | tr -d ' ') variables, the same values" "$rc" "$(diff "$TMPD/c2.base" "$TMPD/c2.new" | grep '^[<>]' | head -6 | tr '\n' ' ')"
}
if [ "$HAVE_BASE" = 1 ]; then
  # The base commit's files sit beside the new ones, so that both see the same REPO_ROOT and the same config.env.
  cp "$MAIN/scripts/lib.sh" "$NEW/scripts/base_lib.sh"; cp "$MAIN/scripts/common.sh" "$NEW/scripts/base_common.sh"
  nocfg
  inv "no config.env, nothing in the environment"
  t=$(cenv /bin/bash "$DUMP" "$NEW/scripts/lib.sh" -- RH_TARGET RH_TARGET_IS_DEFAULT 2>&1 | tr '\n' ' ')
  [ "$t" = "RH_TARGET=[alpoge-rh] RH_TARGET_IS_DEFAULT=[1] " ]; res "and the target is the default one" $? "$t"
  setcfg 'RH_WORKDIR="$REPO_ROOT/cfgwork"
RH_PART_COUNT=3
RH_JOBS=6
GCP_PROJECT=proj-x
GCP_ZONES="z-a z-b"
GCP_SPOT_MAX_ATTEMPTS=3'
  inv "config.env setting RH_WORKDIR, RH_PART_COUNT, RH_JOBS and GCP_ values"
  printf 'RH_TARBALL_SHA256=%s\nRH_PART_URL_PREFIX=https://example.invalid/cfg.part\n' "$(printf '%064d' 1)" >> "$NEW/config.env"
  inv "RH_WORKDIR and RH_TARBALL_SHA256 in the environment over config.env" RH_WORKDIR="$TMPD/envwork" RH_TARBALL_SHA256="$(printf '%064d' 2)"
  inv "empty values in the environment over config.env" RH_WORKDIR= RH_PART_COUNT= RH_TARBALL_SHA256= RH_PART_URL_PREFIX=
  cp "$NEW/config.example.env" "$NEW/config.env"
  inv "config.env copied from config.example.env"
  nocfg
  rm -f "$NEW/scripts/base_lib.sh" "$NEW/scripts/base_common.sh"
else
  skip "no base commit to compare with"
fi

# ================================================================ 3
section 3 "sourcing lib.sh prints nothing on standard output"
quiet() { # quiet <description> <files to source...> -- [VAR=value ...]
  local d=$1 files="" rc; shift
  while [ $# -gt 0 ] && [ "$1" != -- ]; do files="$files $1"; shift; done; [ $# -gt 0 ] && shift
  # shellcheck disable=SC2086
  cenv "$@" /bin/bash -c 'for f in "$@"; do . "$f" || exit 9; done' _ $files > "$TMPD/c3.out" 2> "$TMPD/c3.err"; rc=$?
  [ "$rc" = 0 ] && [ ! -s "$TMPD/c3.out" ]; res "$d" $? "status $rc; stdout: $(tailof "$TMPD/c3.out") stderr: $(tailof "$TMPD/c3.err")"
}
nocfg
quiet "the default target, no config.env" "$NEW/scripts/lib.sh" --
quiet "the default target, lib.sh and common.sh" "$NEW/scripts/lib.sh" "$NEW/scripts/common.sh" --
setcfg "RH_WORKDIR=\"$TMPD/c3work\""
quiet "the default target, with a config.env" "$NEW/scripts/lib.sh" "$NEW/scripts/common.sh" --
nocfg
quiet "a made-up target (git source)" "$NEW/scripts/lib.sh" -- RH_TARGET=fix-git
quiet "a made-up target, lib.sh and common.sh" "$NEW/scripts/lib.sh" "$NEW/scripts/common.sh" -- RH_TARGET=fix-git
quiet "the profile grh-compact of this repository" "$NEW/scripts/lib.sh" -- RH_TARGET=grh-compact

# ================================================================ 4
section 4 "a made-up git source: 01_fetch.sh and 02_inspect_and_extract.sh"
W4="$NEW/work-fix-git"; TAR4="$W4/download/source.tar"
cenv RH_TARGET=fix-git /bin/bash "$NEW/scripts/01_fetch.sh" > "$TMPD/c4.a" 2>&1; rc=$?
H1=""; [ -f "$TAR4" ] && H1=$(sha "$TAR4")
[ "$rc" = 0 ] && [ -n "$H1" ]; res "01: status 0 and the tar file is written to work-fix-git/download/source.tar" $? "status $rc: $(tailof "$TMPD/c4.a")"
grep -q 'NOT PINNED' "$TMPD/c4.a"; res "01: says in capitals that the SHA-256 is NOT PINNED" $? "$(tailof "$TMPD/c4.a" 5)"
pin=$(sed -n 's/^TGT_TARBALL_SHA256=\([0-9a-f]\{64\}\)$/\1/p' "$TMPD/c4.a")
[ -n "$H1" ] && [ "$pin" = "$H1" ]; res "01: prints the line TGT_TARBALL_SHA256=<the file's SHA-256>" $? "printed '$pin', file $H1"
nfiles=$(g ls-tree -r --name-only "$C_MAIN" -- proj/ | wc -l | tr -d ' ')
grep -q "^sha256 $H1 entries $nfiles\$" "$TMPD/c4.a"; res "01: git-export's closing line gives that SHA-256 and the $nfiles files of proj/" $? "$(grep '^sha256 ' "$TMPD/c4.a")"
cenv RH_TARGET=fix-git /bin/bash "$NEW/scripts/01_fetch.sh" > "$TMPD/c4.b" 2>&1; rc=$?
[ "$rc" = 0 ] && [ "$(sha "$TAR4")" = "$H1" ] && grep -q 'clone already present' "$TMPD/c4.b"; res "01 again: the clone is used as it is, and the same SHA-256" $? "status $rc: $(tailof "$TMPD/c4.b")"
cenv RH_TARGET=fix-git /bin/bash "$NEW/scripts/01_fetch.sh" --redownload > "$TMPD/c4.c" 2>&1; rc=$?
[ "$rc" = 0 ] && [ "$(sha "$TAR4")" = "$H1" ] && grep -q 'cloning ' "$TMPD/c4.c"; res "01 --redownload: a new clone, and the same SHA-256" $? "status $rc: $(tailof "$TMPD/c4.c")"
cenv "$PY3" -I -B - "$TAR4" "$REPO" "$C_MAIN" <<'PY' > "$TMPD/c4.tar" 2>&1
import subprocess, sys, tarfile
tar, repo, commit = sys.argv[1:4]
want = [p for p in subprocess.run(["git", "-C", repo, "ls-tree", "-r", "-z", "--name-only", commit, "--", "proj/"],
                                  stdout=subprocess.PIPE, check=True).stdout.split(b"\0") if p]
bad = []
with tarfile.open(tar, mode="r:") as tf:
    ms = tf.getmembers()
names = [m.name.encode("utf-8", "surrogateescape") for m in ms]
if names != want:
    bad.append("names %r, want %r" % (names[:4], want[:4]))
if names != sorted(names):
    bad.append("not in sorted order")
for m in ms:
    if not m.isreg() or m.mtime != 0 or m.uid != 0 or m.gid != 0 or m.uname or m.gname or m.mode != 0o644:
        bad.append("%s: type %r mode %o time %d owner %d/%d %r/%r" % (m.name, m.type, m.mode, m.mtime, m.uid, m.gid, m.uname, m.gname))
for m in ms:
    with tarfile.open(tar, mode="r:") as tf:
        data = tf.extractfile(m.name).read()
    blob = subprocess.run(["git", "-C", repo, "cat-file", "blob", "%s:%s" % (commit, m.name)], stdout=subprocess.PIPE, check=True).stdout
    if data != blob:
        bad.append("contents of %s" % m.name)
print("\n".join(bad) or "same")
sys.exit(1 if bad else 0)
PY
res "the tar holds the files of proj/ in the commit, sorted, under proj/, with their bytes, time 0, owner 0, mode 644" $? "$(tailof "$TMPD/c4.tar")"
cenv RH_TARGET=fix-git /bin/bash "$NEW/scripts/01_fetch.sh" --check-only > "$TMPD/c4.d" 2>&1; rc=$?
[ "$rc" = 0 ] && grep -q 'not pinned' "$TMPD/c4.d"; res "01 --check-only: status 0, the archive is there and not pinned" $? "status $rc: $(tailof "$TMPD/c4.d")"
prof fix-git "TGT_TARBALL_SHA256=$H1"
cenv RH_TARGET=fix-git /bin/bash "$NEW/scripts/01_fetch.sh" > "$TMPD/c4.e" 2>&1; rc=$?
[ "$rc" = 0 ] && grep -q 'archive verified' "$TMPD/c4.e" && ! grep -q 'NOT PINNED' "$TMPD/c4.e"; res "01 with that SHA-256 pinned in the profile: verified, status 0" $? "status $rc: $(tailof "$TMPD/c4.e")"
first=${H1%"${H1#?}"}; if [ "$first" = 0 ]; then WRONG="1${H1#?}"; else WRONG="0${H1#?}"; fi
prof fix-git "TGT_TARBALL_SHA256=$WRONG"
cenv RH_TARGET=fix-git /bin/bash "$NEW/scripts/01_fetch.sh" > "$TMPD/c4.f" 2>&1; rc=$?
[ "$rc" = 1 ] && grep -q 'but TGT_TARBALL_SHA256' "$TMPD/c4.f"; res "01 with another SHA-256 pinned: status 1, and the message says so" $? "status $rc: $(tailof "$TMPD/c4.f")"
cenv RH_TARGET=fix-git /bin/bash "$NEW/scripts/01_fetch.sh" --check-only > "$TMPD/c4.g" 2>&1; rc=$?
[ "$rc" = 1 ] && grep -q 'MISMATCH' "$TMPD/c4.g"; res "01 --check-only with another SHA-256 pinned: status 1, MISMATCH" $? "status $rc: $(tailof "$TMPD/c4.g")"
# 02, first with nothing pinned (the first run of a new target), then pinned.
prof fix-git
REC4="$NEW/targets/fix-git/records/expected.json"
cenv RH_TARGET=fix-git /bin/bash "$NEW/scripts/02_inspect_and_extract.sh" --write-expected "$REC4" > "$TMPD/c4.h" 2>&1; rc=$?
[ "$rc" = 0 ] && [ -f "$W4/extract/proj/lakefile.toml" ]; res "02 --write-expected <records>/expected.json: status 0, extracted under work-fix-git/extract/proj" $? "status $rc: $(tailof "$TMPD/c4.h")"
grep -q 'THE ARCHIVE IS NOT PINNED' "$TMPD/c4.h" && grep -q 'NO RECORDED VALUES TO COMPARE WITH' "$TMPD/c4.h"
res "02: says in capitals that the archive is not pinned and that nothing was recorded to compare with" $? "$(grep -i 'pinned\|recorded' "$TMPD/c4.h" | tr '\n' ' ')"
cenv "$PY3" -I -B - "$REPO" "$C_MAIN" proj "$W4/extract" <<'PY' > "$TMPD/c4.x" 2>&1
import os, subprocess, sys
repo, commit, sub, ext = sys.argv[1:5]
out = subprocess.run(["git", "-C", repo, "ls-tree", "-r", "-z", commit, "--", sub + "/"], stdout=subprocess.PIPE, check=True).stdout
want, bad = set(), []
for rec in out.split(b"\0"):
    if not rec:
        continue
    meta, path = rec.split(b"\t", 1)
    want.add(path)
    blob = subprocess.run(["git", "-C", repo, "cat-file", "blob", meta.split()[2].decode()], stdout=subprocess.PIPE, check=True).stdout
    p = os.path.join(os.fsencode(ext), path)
    if not os.path.isfile(p):
        bad.append("missing: %r" % path)
    elif open(p, "rb").read() != blob:
        bad.append("differs: %r" % path)
have = set()
for d, dirs, files in os.walk(os.fsencode(ext)):
    for f in files:
        have.add(os.path.relpath(os.path.join(d, f), os.fsencode(ext)))
bad += ["not in the commit: %r" % p for p in sorted(have - want)]
print("%d files; " % len(want) + ("; ".join(bad[:5]) or "all the same"))
sys.exit(1 if bad else 0)
PY
res "the extracted files are the commit's files of proj/, byte for byte, and nothing else" $? "$(tailof "$TMPD/c4.x")"
[ -f "$REC4" ] && "$PY3" -I -B -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if "tarball" in d and "project" in d else 1)' "$REC4"
res "02 recorded the tarball and project sections in targets/fix-git/records/expected.json" $? "$(head -c 300 "$REC4" 2>/dev/null)"
prof fix-git "TGT_TARBALL_SHA256=$H1"
cenv RH_TARGET=fix-git /bin/bash "$NEW/scripts/02_inspect_and_extract.sh" > "$TMPD/c4.i" 2>&1; rc=$?
[ "$rc" = 0 ] && grep -q 'tarball SHA-256 ok' "$TMPD/c4.i" && grep -q 'tarball listing: matches the recorded values' "$TMPD/c4.i" \
  && grep -q 'project files: matches the recorded values' "$TMPD/c4.i" && ! grep -q 'NO RECORDED VALUES' "$TMPD/c4.i"
res "02 again, pinned: the SHA-256 checked, and the listing and the project files compared with the record" $? "status $rc: $(grep -i 'recorded\|sha-256' "$TMPD/c4.i" | tr '\n' ' ')"
cenv RH_TARGET=fix-git /bin/bash "$NEW/scripts/02_inspect_and_extract.sh" --verify-tree > "$TMPD/c4.j" 2>&1; rc=$?
[ "$rc" = 0 ] && grep -q 'byte-for-byte' "$TMPD/c4.j"; res "02 --verify-tree: the extracted files are the archive's" $? "status $rc: $(tailof "$TMPD/c4.j")"
cp "$W4/extract/proj/src/A.lean" "$TMPD/A.lean.saved"; echo '-- changed' >> "$W4/extract/proj/src/A.lean"
cenv RH_TARGET=fix-git /bin/bash "$NEW/scripts/02_inspect_and_extract.sh" --verify-tree > "$TMPD/c4.k" 2>&1; rc=$?
cp "$TMPD/A.lean.saved" "$W4/extract/proj/src/A.lean"
[ "$rc" = 1 ] && grep -q 'content differs: proj/src/A.lean' "$TMPD/c4.k"; res "02 --verify-tree notices a changed file (status 1)" $? "status $rc: $(tailof "$TMPD/c4.k")"

# ================================================================ 5
section 5 "refusals"
nocfg
refused "RH_TARGET with an upper-case letter" "RH_TARGET names a directory" RH_TARGET=Fix-git /bin/bash "$NEW/scripts/01_fetch.sh" --check-only
refused "RH_TARGET with a leading '-'" "RH_TARGET names a directory" RH_TARGET=-fix /bin/bash "$NEW/scripts/01_fetch.sh" --check-only
refused "RH_TARGET '../x'" "RH_TARGET names a directory" RH_TARGET=../x /bin/bash "$NEW/scripts/01_fetch.sh" --check-only
refused "a target with no profile" "has no profile" RH_TARGET=no-such-target /bin/bash "$NEW/scripts/01_fetch.sh" --check-only
prof fix-bad TGT_STATEMENT_CONST-
refused "a profile without TGT_STATEMENT_CONST" "TGT_STATEMENT_CONST is required" RH_TARGET=fix-bad /bin/bash "$NEW/scripts/01_fetch.sh" --check-only
prof fix-bad TGT_GIT_COMMIT-
refused "a git profile without TGT_GIT_COMMIT" "TGT_GIT_COMMIT is required" RH_TARGET=fix-bad /bin/bash "$NEW/scripts/01_fetch.sh" --check-only
prof fix-bad TGT_ARCHIVE_PREFIX-
refused "a profile without TGT_ARCHIVE_PREFIX" "TGT_ARCHIVE_PREFIX is required" RH_TARGET=fix-bad /bin/bash "$NEW/scripts/01_fetch.sh" --check-only
prof fix-bad TGT_GIT_COMMIT=main
refused "TGT_GIT_COMMIT a branch name" "TGT_GIT_COMMIT must be" RH_TARGET=fix-bad /bin/bash "$NEW/scripts/01_fetch.sh" --check-only
prof fix-bad "TGT_GIT_COMMIT=${C_MAIN%?}"
refused "TGT_GIT_COMMIT of 39 characters" "TGT_GIT_COMMIT must be" RH_TARGET=fix-bad /bin/bash "$NEW/scripts/01_fetch.sh" --check-only
prof fix-bad "TGT_GIT_COMMIT=$(printf '%s' "$C_MAIN" | tr 'a-f' 'A-F')"
refused "TGT_GIT_COMMIT in upper case" "TGT_GIT_COMMIT must be" RH_TARGET=fix-bad /bin/bash "$NEW/scripts/01_fetch.sh" --check-only
for p in proj ../proj/ proj/../x/ /proj/ ./proj/; do
  prof fix-bad "TGT_ARCHIVE_PREFIX=$p"
  refused "TGT_ARCHIVE_PREFIX '$p'" "TGT_ARCHIVE_PREFIX must be" RH_TARGET=fix-bad /bin/bash "$NEW/scripts/01_fetch.sh" --check-only
done
prof fix-bad TGT_SOURCE_KIND=zip
refused "TGT_SOURCE_KIND unknown" "TGT_SOURCE_KIND must be" RH_TARGET=fix-bad /bin/bash "$NEW/scripts/01_fetch.sh" --check-only
prof fix-bad TGT_ARCHIVE_ALLOW_EXEC=yes
refused "TGT_ARCHIVE_ALLOW_EXEC not 0 or 1" "TGT_ARCHIVE_ALLOW_EXEC must be" RH_TARGET=fix-bad /bin/bash "$NEW/scripts/01_fetch.sh" --check-only
[ ! -e "$NEW/work-fix-bad" ]; res "none of these refusals left a working directory behind" $? "$(ls "$NEW/work-fix-bad" 2>&1)"
prof fix-link "TGT_GIT_COMMIT=$C_LINK"
refused "01 on a commit with a symbolic link" "symbolic link" RH_TARGET=fix-link /bin/bash "$NEW/scripts/01_fetch.sh"
[ ! -e "$NEW/work-fix-link/download/source.tar" ] && [ ! -e "$NEW/work-fix-link/download/source.tar.tmp" ]; res "...and no tar file was written" $?
prof fix-sub "TGT_GIT_COMMIT=$C_SUB"
refused "01 on a commit with a submodule (a gitlink entry)" "submodule" RH_TARGET=fix-sub /bin/bash "$NEW/scripts/01_fetch.sh"
[ ! -e "$NEW/work-fix-sub/download/source.tar" ]; res "...and no tar file was written" $?
prof fix-exec "TGT_GIT_COMMIT=$C_EXEC"
cenv RH_TARGET=fix-exec /bin/bash "$NEW/scripts/01_fetch.sh" > "$TMPD/c5.a" 2>&1; rc=$?
[ "$rc" = 0 ] && grep -q '1 of the files with an executable bit' "$TMPD/c5.a"; res "01 on a commit with an executable file: written, and the bit counted" $? "status $rc: $(tailof "$TMPD/c5.a")"
refused "02 refuses the executable file" "executable bit set" RH_TARGET=fix-exec /bin/bash "$NEW/scripts/02_inspect_and_extract.sh"
[ ! -e "$NEW/work-fix-exec/extract" ]; res "...and extracts nothing" $?
cenv RH_TARGET=fix-exec TGT_ARCHIVE_ALLOW_EXEC=1 /bin/bash "$NEW/scripts/02_inspect_and_extract.sh" > "$TMPD/c5.b" 2>&1; rc=$?
[ "$rc" = 0 ] && grep -q 'accepted because of --allow-exec: 1' "$TMPD/c5.b" && [ -x "$NEW/work-fix-exec/extract/proj/run.sh" ]
res "02 with TGT_ARCHIVE_ALLOW_EXEC=1 accepts it, says so, and extracts it executable" $? "status $rc: $(tailof "$TMPD/c5.b")"
lakes=$(grep -c '^lake ' "$STUBLOG")
: > "$W4/extract/proj/lakefile.lean"
refused "04 refuses a project that has a lakefile.lean" "lakefile.lean exists" RH_TARGET=fix-git /bin/bash "$NEW/scripts/04_setup_toolchain.sh"
rm -f "$W4/extract/proj/lakefile.lean"
[ "$(grep -c '^lake ' "$STUBLOG")" = "$lakes" ] && [ ! -e "$W4/logs/setup-"* ] 2>/dev/null; res "...before it runs lake or writes a log" $?

# ================================================================ 6
section 6 "the working directory and its marker .rh-target"
[ "$(cat "$W4/.rh-target" 2>/dev/null)" = fix-git ]; res "01, the first script that wrote in work-fix-git, wrote .rh-target naming fix-git" $? "$(cat "$W4/.rh-target" 2>&1)"
W6="$TMPD/w6default"; mkdir -p "$W6/download"; cp "$TB/good.tar.gz" "$W6/download/lean.tar.gz"
cenv RH_WORKDIR="$W6" RH_TARBALL_SHA256="$GOODSHA" /bin/bash "$NEW/scripts/01_fetch.sh" > "$TMPD/c6.a" 2>&1; rc=$?
[ "$rc" = 0 ] && grep -q 'tarball already present with the expected SHA-256' "$TMPD/c6.a" && [ "$(cat "$W6/.rh-target" 2>/dev/null)" = alpoge-rh ]
res "the default target's 01 (tarball present) writes .rh-target naming alpoge-rh in a directory that had none" $? "status $rc: $(tailof "$TMPD/c6.a") marker: $(cat "$W6/.rh-target" 2>&1)"
refused "a default-target command (01 --check-only) in work-fix-git stops" "belongs to target 'fix-git'" RH_WORKDIR="$W4" /bin/bash "$NEW/scripts/01_fetch.sh" --check-only
refused "so does a read-only one (06_progress.sh)" "belongs to target 'fix-git'" RH_WORKDIR="$W4" /bin/bash "$NEW/scripts/06_progress.sh"
setcfg "RH_WORKDIR=\"$W4\""
refused "and with the directory named in config.env instead" "belongs to target 'fix-git'" /bin/bash "$NEW/scripts/01_fetch.sh" --check-only
nocfg
refused "target fix-git in the default target's marked directory stops" "belongs to target 'alpoge-rh'" RH_TARGET=fix-git RH_WORKDIR="$W6" /bin/bash "$NEW/scripts/01_fetch.sh" --check-only
mkdir -p "$TMPD/w6unmarked"; echo old > "$TMPD/w6unmarked/a-file"
refused "target fix-git refuses a directory with files and no marker" "no .rh-target file" RH_TARGET=fix-git RH_WORKDIR="$TMPD/w6unmarked" /bin/bash "$NEW/scripts/01_fetch.sh" --check-only
mkdir -p "$TMPD/w6other"; echo fix-other > "$TMPD/w6other/.rh-target"
refused "target fix-git refuses a directory marked for another made-up target" "belongs to target 'fix-other'" RH_TARGET=fix-git RH_WORKDIR="$TMPD/w6other" /bin/bash "$NEW/scripts/01_fetch.sh" --check-only
E6="$TMPD/w6given"
cenv RH_TARGET=fix-git RH_WORKDIR="$E6" /bin/bash "$NEW/scripts/01_fetch.sh" > "$TMPD/c6.b" 2>&1; rc=$?
[ "$rc" = 0 ] && [ -d "$E6/download/repo.git" ] && [ "$(cat "$E6/.rh-target" 2>/dev/null)" = fix-git ] && [ ! -e "$E6-fix-git" ] && grep -q "work directory: $E6\$" "$TMPD/c6.b"
res "RH_WORKDIR given in the environment is used as given by another target, and marked for it" $? "status $rc: $(tailof "$TMPD/c6.b")"
t=$(libvar RH_WORKDIR RH_TARGET=fix-git); [ "$t" = "$NEW/work-fix-git" ]; res "with no RH_WORKDIR anywhere, target fix-git works in <repository>/work-fix-git" $? "$t"
setcfg "RH_WORKDIR=\"$TMPD/cfgw\""
t=$(libvar RH_WORKDIR RH_TARGET=fix-git); [ "$t" = "$TMPD/cfgw-fix-git" ]; res "with RH_WORKDIR from config.env, it is that with -fix-git added" $? "$t"
t=$(libvar RH_WORKDIR); [ "$t" = "$TMPD/cfgw" ]; res "...while the default target's is RH_WORKDIR itself" $? "$t"
setcfg "RH_WORKDIR=\"$TMPD/cfgw/\""
t=$(libvar RH_WORKDIR RH_TARGET=fix-git); [ "$t" = "$TMPD/cfgw-fix-git" ]; res "...also when config.env writes it with a closing slash" $? "$t"
nocfg
cenv RH_TARGET=fix-git /bin/bash "$DUMP" "$NEW/scripts/lib.sh" -- RH_TARGET_IS_DEFAULT RH_DL RH_PROJ RH_SRC RH_TARBALL RH_GIT_DIR RH_RECORDS_SRC RH_EXPECTED RH_PARTS_RECORD > "$TMPD/c6.c" 2>&1
printf '%s\n' "RH_TARGET_IS_DEFAULT=[0]" "RH_DL=[$W4/download]" "RH_PROJ=[$W4/extract/proj]" "RH_SRC=[$W4/extract/proj/src]" \
  "RH_TARBALL=[$W4/download/source.tar]" "RH_GIT_DIR=[$W4/download/repo.git]" "RH_RECORDS_SRC=[$NEW/targets/fix-git/records]" \
  "RH_EXPECTED=[$NEW/targets/fix-git/records/expected.json]" "RH_PARTS_RECORD=[$NEW/targets/fix-git/records/parts.sha256]" > "$TMPD/c6.c.want"
cmp -s "$TMPD/c6.c" "$TMPD/c6.c.want"; res "the paths derived for target fix-git" $? "$(diff "$TMPD/c6.c.want" "$TMPD/c6.c" | grep '^[<>]' | tr '\n' ' ')"
RHP='import sys; sys.path.insert(0, sys.argv[1]); import rhpaths; print(rhpaths.src_dir()); print(rhpaths.analysis_dir()); print(rhpaths.logs_dir())'
t=$(cenv RH_TARGET=fix-git "$PY3" -I -B -c "$RHP" "$NEW/analysis" 2>&1 | tr '\n' ' ')
[ "$t" = "$W4/extract/proj/src $W4/analysis $W4/logs " ]; res "analysis/rhpaths.py gives the same directories for target fix-git" $? "$t"
t=$(cenv "$PY3" -I -B -c "$RHP" "$NEW/analysis" 2>&1 | tr '\n' ' ')
[ "$t" = "$NEW/work/extract/lean/src $NEW/work/analysis $NEW/work/logs " ]; res "...and for the default target" $? "$t"
cenv RH_WORKDIR="$W4" "$PY3" -I -B -c "$RHP" "$NEW/analysis" > "$TMPD/c6.d" 2>&1; rc=$?
[ "$rc" != 0 ] && grep -q "belongs to target 'fix-git'" "$TMPD/c6.d"; res "...and stops, with lib.sh's message, for the default target in work-fix-git" $? "status $rc: $(tailof "$TMPD/c6.d")"

# ================================================================ 7
section 7 "the axiom check file (rhv_tools.py axioms-body, 08_check_axioms.sh with a stand-in lean)"
BODY="$NEW/scripts/verify/axioms_check_body.lean"; TOOLS="$NEW/scripts/verify/rhv_tools.py"
cenv "$PY3" -I -B "$TOOLS" axioms-body --body "$BODY" > "$TMPD/c7.a" 2>&1; rc=$?
[ "$rc" = 0 ] && cmp -s "$TMPD/c7.a" "$BODY"; res "axioms-body with the default names prints the body file byte for byte" $? "status $rc $(cmp "$TMPD/c7.a" "$BODY" 2>&1)"
cenv "$PY3" -I -B "$TOOLS" axioms-body --body "$BODY" --statement-const RiemannHypothesis --report-consts "RiemannHypothesis riemannZeta DirichletCharacter.LFunction" > "$TMPD/c7.b" 2>&1; rc=$?
[ "$rc" = 0 ] && cmp -s "$TMPD/c7.b" "$BODY"; res "...and with the default names given explicitly" $? "status $rc"
sed -e 's/mkConst `RiemannHypothesis$/mkConst `GRH/' -e 's/statement_is_constant_RiemannHypothesis /statement_is_constant_GRH /' \
    -e 's/for c in \[`RiemannHypothesis, `riemannZeta, `DirichletCharacter.LFunction\] do/for c in [`GRH, `Foo.bar] do/' \
    -e 's/if c == `RiemannHypothesis then/if c == `GRH then/' "$BODY" > "$TMPD/c7.want"
ndiff=$(diff "$BODY" "$TMPD/c7.want" | grep -c '^>')
cenv "$PY3" -I -B "$TOOLS" axioms-body --body "$BODY" --statement-const GRH --report-consts "GRH Foo.bar" > "$TMPD/c7.c" 2>&1; rc=$?
[ "$rc" = 0 ] && [ "$ndiff" = 4 ] && cmp -s "$TMPD/c7.c" "$TMPD/c7.want"; res "with another constant: the body with those four lines changed and nothing else" $? "status $rc, $ndiff lines; $(diff "$TMPD/c7.want" "$TMPD/c7.c" | head -4 | tr '\n' ' ')"
cenv "$PY3" -I -B "$TOOLS" axioms-body --body "$BODY" --statement-const GRH --report-consts "Foo.bar" > "$TMPD/c7.d" 2>&1; rc=$?
[ "$rc" = 0 ] && cmp -s "$TMPD/c7.d" "$TMPD/c7.want"; res "...and the statement constant is put in front of a list that lacks it" $? "status $rc"
cenv "$PY3" -I -B "$TOOLS" axioms-body --body "$BODY" --statement-const 'GRH x' > "$TMPD/c7.e" 2> "$TMPD/c7.e2"; rc=$?
[ "$rc" = 2 ] && [ ! -s "$TMPD/c7.e" ]; res "a name that is not a plain Lean name: status 2, nothing printed" $? "status $rc"
lean_file() { ls "$1"/logs/axioms-"$2"-*.lean 2>/dev/null | head -n 1; }    # lean_file <workdir> <mode>
mk08() { # mk08 <workdir> <project dir under extract/> <root module> [more modules]: a made-up extracted project, compiled
  local w=$1 p="$1/extract/$2" m; shift 2
  mkdir -p "$p/src" "$p/.lake/build/lib/lean"; echo 'leanprover/lean4:v4.33.1' > "$p/lean-toolchain"
  for m in "$@"; do
    mkdir -p "$(dirname "$p/src/$(printf '%s' "$m" | tr . /).lean")" "$(dirname "$p/.lake/build/lib/lean/$(printf '%s' "$m" | tr . /)")"
    echo 'theorem t : True := trivial' > "$p/src/$(printf '%s' "$m" | tr . /).lean"
    echo 'not a compiled module' > "$p/.lake/build/lib/lean/$(printf '%s' "$m" | tr . /).olean"
  done
}
if [ "$HAVE_BASE" = 1 ]; then
  for mode in full deep probe; do
    case "$mode" in full) arg="" ;; deep) arg=--deep ;; probe) arg=--probe ;; esac
    for side in base new; do
      w="$TMPD/w7-$mode-$side"; mk08 "$w" lean Main Formalism.GammaFactorNonvanishing.RhOfRight
      if [ "$side" = base ]; then s="$MAIN/scripts"; else s="$NEW/scripts"; fi
      # shellcheck disable=SC2086
      cenv RH_WORKDIR="$w" /bin/bash "$s/08_check_axioms.sh" $arg > "$TMPD/c7.$mode.$side" 2>&1
    done
    m=full; [ "$mode" = probe ] && m=probe
    fb=$(lean_file "$TMPD/w7-$mode-base" "$m"); fn=$(lean_file "$TMPD/w7-$mode-new" "$m")
    [ -n "$fb" ] && [ -n "$fn" ] && cmp -s "$fb" "$fn"; res "08 ${arg:-(full)}: the generated .lean file is the base commit's, byte for byte" $? "base: ${fb:-none} ($(tailof "$TMPD/c7.$mode.base" 2)) new: ${fn:-none} ($(tailof "$TMPD/c7.$mode.new" 2))"
  done
  fn=$(lean_file "$TMPD/w7-full-new" full)
  { echo "import Main"; cat "$BODY"; echo; echo "-- Footer generated by scripts/08_check_axioms.sh (full mode)."
    for t in riemannHypothesis riemannZeta_eq_zero_re LFunction_ne_zero_of_half_lt_re LFunction_eq_zero_re LFunction_eq_zero_re_of_isPrimitive; do echo "#print axioms $t"; done
    echo 'run_cmd RHVerifyCheck.run "full" false `riemannHypothesis [`riemannHypothesis, `riemannZeta_eq_zero_re, `LFunction_ne_zero_of_half_lt_re, `LFunction_eq_zero_re, `LFunction_eq_zero_re_of_isPrimitive]'
  } > "$TMPD/c7.full.want"
  [ -n "$fn" ] && cmp -s "$fn" "$TMPD/c7.full.want"; res "...and it is the import, the body file as it is, and the footer for the five theorems" $? "$(diff "$TMPD/c7.full.want" "$fn" 2>&1 | head -3 | tr '\n' ' ')"
else
  skip "08 against the base commit's: no base commit"
fi
mk08 "$W4" proj A
cenv RH_TARGET=fix-git /bin/bash "$NEW/scripts/08_check_axioms.sh" > "$TMPD/c7.fix" 2>&1
fn=$(lean_file "$W4" full)
{ echo "import A"; cenv "$PY3" -I -B "$TOOLS" axioms-body --body "$BODY" --statement-const Fixture.Statement --report-consts Fixture.Statement
  echo; echo "-- Footer generated by scripts/08_check_axioms.sh (full mode)."; echo "#print axioms a_thm"; echo "#print axioms c_thm"
  echo 'run_cmd RHVerifyCheck.run "full" false `a_thm [`a_thm, `c_thm]'; } > "$TMPD/c7.fix.want"
[ -n "$fn" ] && cmp -s "$fn" "$TMPD/c7.fix.want" && grep -q 'Fixture.Statement' "$fn" && ! grep -q 'RiemannHypothesis' "$fn"
res "08 for target fix-git: its root module, theorems and statement constant, and no default name" $? "$(tailof "$TMPD/c7.fix") $(diff "$TMPD/c7.fix.want" "$fn" 2>&1 | head -3 | tr '\n' ' ')"
fl="${fn%.lean}.log"; fj="${fn%.lean}.json"
grep -q '^### target=fix-git$' "$fl" 2>/dev/null; res "...its log names the target" $? "$(head -n 3 "$fl" 2>&1 | tr '\n' ' ')"
"$PY3" -I -B -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d.get("source_id") == sys.argv[2] and d.get("target") == "fix-git" else 1)' "$fj" "$REPO commit $C_MAIN directory proj" 2>/dev/null
res "...and its summary names the target and is identified by repository, commit and directory (source_id)" $? "$(head -c 200 "$fj" 2>&1)"
refused "08 --probe for a target whose profile names no probe lemma stops" "names no probe lemma" RH_TARGET=fix-git /bin/bash "$NEW/scripts/08_check_axioms.sh" --probe
[ -s "$STUBLOG.lean" ]; res "(the stand-in lean was what ran)" $?

# ================================================================ 8
section 8 "rhv_tools.py tar-inspect with no new argument, against the base commit's"
if [ "$HAVE_BASE" = 1 ]; then
  OLDT="$MAIN/scripts/verify/rhv_tools.py"
  ti() { # ti <label> <arguments...>: tar-inspect with both tools; outputs in c8.<label>.base / .new, statuses in RB, RN
    local l=$1; shift
    cenv "$PY3" -I -B "$OLDT" tar-inspect "$@" > "$TMPD/c8.$l.base" 2>&1; RB=$?
    cenv "$PY3" -I -B "$TOOLS" tar-inspect "$@" > "$TMPD/c8.$l.new" 2>&1; RN=$?
  }
  same() { # same <description> <label>: the same output and status
    cmp -s "$TMPD/c8.$2.base" "$TMPD/c8.$2.new" && [ "$RB" = "$RN" ]
    res "$1 (status $RN)" $? "status $RB/$RN; $(diff "$TMPD/c8.$2.base" "$TMPD/c8.$2.new" | grep '^[<>]' | head -4 | tr '\n' ' ')"
  }
  ti plain "$TB/good.tar.gz"
  grep -v -i 'no recorded values' "$TMPD/c8.plain.base" > "$TMPD/c8.p.b"; grep -v -i 'no recorded values' "$TMPD/c8.plain.new" > "$TMPD/c8.p.n"
  cmp -s "$TMPD/c8.p.b" "$TMPD/c8.p.n" && [ "$RB" = "$RN" ] && [ "$(grep -c -i 'no recorded values' "$TMPD/c8.plain.base")" = 1 ] \
    && [ "$(grep -c 'NO RECORDED VALUES TO COMPARE WITH' "$TMPD/c8.plain.new")" = 1 ]
  res "a clean tarball, no record: the same output and status ($RN) but for the line that says nothing was recorded" $? "$(diff "$TMPD/c8.plain.base" "$TMPD/c8.plain.new" | grep '^[<>]' | head -4 | tr '\n' ' ')"
  echo "INFO  that line was: $(grep -i 'no recorded values' "$TMPD/c8.plain.base")"
  echo "INFO  and now is:    $(grep 'NO RECORDED VALUES' "$TMPD/c8.plain.new")"
  cenv "$PY3" -I -B "$OLDT" tar-inspect "$TB/good.tar.gz" --sha256 "$GOODSHA" --write-expected "$TMPD/c8.expected.base" > /dev/null 2>&1; RB=$?
  cenv "$PY3" -I -B "$TOOLS" tar-inspect "$TB/good.tar.gz" --sha256 "$GOODSHA" --write-expected "$TMPD/c8.expected.new" > /dev/null 2>&1; RN=$?
  [ "$RB" = 0 ] && [ "$RN" = 0 ] && cmp -s "$TMPD/c8.expected.base" "$TMPD/c8.expected.new"; res "--write-expected: the same JSON" $? "status $RB/$RN; $(diff "$TMPD/c8.expected.base" "$TMPD/c8.expected.new" 2>&1 | head -4 | tr '\n' ' ')"
  ti rec "$TB/good.tar.gz" --sha256 "$GOODSHA" --expected "$TMPD/c8.expected.base"
  same "--expected (a record that matches): the same output" rec
  ti other "$TB/good.tar.gz" --sha256 "$(printf '%064d' 7)" --expected "$TMPD/c8.expected.base"
  same "--expected (a record that does not match): the same output" other
  ti bad "$TB/bad.tar.gz" --expected "$TMPD/c8.expected.base"
  same "a tarball with every kind of entry that is refused: the same output" bad
  mkdir -p "$TMPD/c8x"; tar -xzf "$TB/good.tar.gz" -C "$TMPD/c8x"
  ti tree "$TB/good.tar.gz" --expected "$TMPD/c8.expected.base" --verify-tree "$TMPD/c8x"
  same "--verify-tree on a matching extraction: the same output" tree
  echo changed >> "$TMPD/c8x/lean/src/B/C.lean"; echo extra > "$TMPD/c8x/lean/extra.txt"
  ti tree2 "$TB/good.tar.gz" --expected "$TMPD/c8.expected.base" --verify-tree "$TMPD/c8x"
  same "--verify-tree on a changed extraction: the same output" tree2
  ti quiet "$TB/good.tar.gz" --quiet --expected "$TMPD/c8.expected.base" --verify-tree "$TMPD/c8x"
  same "--quiet --verify-tree: the same output" quiet
  cenv "$PY3" -I -B "$OLDT" audit-literals > "$TMPD/c8.lit.base" 2>&1; RB=$?
  cenv "$PY3" -I -B "$TOOLS" audit-literals > "$TMPD/c8.lit.new" 2>&1; RN=$?
  same "audit-literals with no argument: the same strings" lit
else
  skip "no base commit to compare with"
fi
cenv "$PY3" -I -B "$TOOLS" tar-inspect "$TB/good.tar.gz" --sha256 x > "$TMPD/c8.gz" 2>&1
cenv "$PY3" -I -B "$TOOLS" tar-inspect "$TB/good.tar" --sha256 x > "$TMPD/c8.tar" 2>&1; rc=$?
[ "$rc" = 0 ] && cmp -s "$TMPD/c8.gz" "$TMPD/c8.tar"; res "the same tarball uncompressed gives the same listing" $? "status $rc $(diff "$TMPD/c8.gz" "$TMPD/c8.tar" | head -2 | tr '\n' ' ')"

# ================================================================ 9
section 9 "reproduce_findings.sh for made-up targets"
nocfg
row() { sed -n "s/^$2  *\([^ ]*\)  .*/\1/p" "$1" | head -n 1; }    # row <output> <claim>: that claim's result
prof fix-repro
cenv RH_TARGET=fix-repro /bin/bash "$NEW/scripts/reproduce_findings.sh" > "$TMPD/c9.a" 2>&1; rc=$?
[ "$rc" = 0 ]; res "a target with nothing recorded, no Mathlib tag and no S10 pattern: status 0" $? "status $rc: $(tailof "$TMPD/c9.a" 4)"
t="S1=$(row "$TMPD/c9.a" S1) S2-S4=$(row "$TMPD/c9.a" S2-S4) S5=$(row "$TMPD/c9.a" S5) S6-S8=$(row "$TMPD/c9.a" S6-S8) S9=$(row "$TMPD/c9.a" S9) S10=$(row "$TMPD/c9.a" S10)"
[ "$t" = "S1=PASS S2-S4=n/a S5=n/a S6-S8=n/a S9=n/a S10=n/a" ]; res "S1 passes; S5, S9 and S10 (and S2-S4, S6-S8, with nothing recorded) are n/a" $? "$t"
grep -q 'not applicable' "$TMPD/c9.a" && grep -q 'None failed' "$TMPD/c9.a" && ! grep -q 'did NOT reproduce' "$TMPD/c9.a"
res "...and the closing line says they were not applicable, and that none failed" $? "$(tailof "$TMPD/c9.a" 1)"
grep -q 'TGT_MATHLIB_TAG is empty' "$TMPD/c9.a" && grep -q 'import graph: nothing recorded' "$TMPD/c9.a"; res "...with the reason for S5 and for S9" $? "$(grep 'n/a' "$TMPD/c9.a" | tr '\n' ' ')"
cenv RH_TARGET=fix-git /bin/bash "$NEW/scripts/reproduce_findings.sh" > "$TMPD/c9.b" 2>&1; rc=$?
t="S1=$(row "$TMPD/c9.b" S1) S2-S4=$(row "$TMPD/c9.b" S2-S4) S5=$(row "$TMPD/c9.b" S5) S6-S8=$(row "$TMPD/c9.b" S6-S8) S9=$(row "$TMPD/c9.b" S9) S10=$(row "$TMPD/c9.b" S10)"
[ "$rc" = 0 ] && [ "$t" = "S1=PASS S2-S4=PASS S5=n/a S6-S8=n/a S9=n/a S10=n/a" ]; res "target fix-git, pinned and with its record from case 4: S1 and S2-S4 pass" $? "status $rc: $t"
cenv RH_TARGET=fix-git TGT_S10_PATTERN='trivial|rfl' TGT_S10_COUNT= /bin/bash "$NEW/scripts/reproduce_findings.sh" > "$TMPD/c9.c" 2>&1; rc=$?
[ "$rc" = 0 ] && [ "$(row "$TMPD/c9.c" S10)" = "n/a" ]; res "an S10 pattern with no count: S10 is n/a" $? "status $rc: $(grep '^S10' "$TMPD/c9.c")"
cenv RH_TARGET=fix-git TGT_S10_PATTERN='trivial|rfl' TGT_S10_COUNT=2 /bin/bash "$NEW/scripts/reproduce_findings.sh" > "$TMPD/c9.d" 2>&1; rc=$?
[ "$rc" = 0 ] && [ "$(row "$TMPD/c9.d" S10)" = "PASS" ]; res "an S10 pattern with the right count (2 files): S10 passes" $? "status $rc: $(grep '^S10' "$TMPD/c9.d")"
cenv RH_TARGET=fix-git TGT_S10_PATTERN='trivial|rfl' TGT_S10_COUNT=5 /bin/bash "$NEW/scripts/reproduce_findings.sh" > "$TMPD/c9.e" 2>&1; rc=$?
[ "$rc" = 1 ] && [ "$(row "$TMPD/c9.e" S10)" = "FAIL" ]; res "...with a wrong count: S10 fails, status 1" $? "status $rc: $(grep '^S10' "$TMPD/c9.e")"

# ================================================================ 10
section 10 "values in the environment win over config.env and over the profile"
setcfg 'RH_TARGET=no-such-target'
t=$(libvar RH_TARGET RH_TARGET=fix-git); [ "$t" = fix-git ]; res "RH_TARGET in the environment over RH_TARGET in config.env" $? "$t"
setcfg 'RH_TARGET=fix-git'
t=$(libvar RH_TARGET); [ "$t" = fix-git ]; res "RH_TARGET in config.env alone names the target" $? "$t"
t=$(libvar RH_PROJ RH_TARGET=alpoge-rh); [ "$t" = "$NEW/work/extract/lean" ]; res "RH_TARGET=alpoge-rh in the environment over another target in config.env" $? "$t"
setcfg "RH_TARGET=fix-git
RH_WORKDIR=\"$TMPD/cfg10\""
t=$(libvar RH_WORKDIR RH_WORKDIR="$TMPD/env10"); [ "$t" = "$TMPD/env10" ]; res "RH_WORKDIR in the environment over config.env, used as given" $? "$t"
nocfg
t=$(libvar TGT_ROOT_MODULE RH_TARGET=fix-git); [ "$t" = A ]; res "the profile's TGT_ROOT_MODULE (A)" $? "$t"
t=$(libvar TGT_ROOT_MODULE RH_TARGET=fix-git TGT_ROOT_MODULE=Env.Root); [ "$t" = Env.Root ]; res "TGT_ROOT_MODULE in the environment over the profile" $? "$t"
setcfg 'TGT_ROOT_MODULE=Cfg.Root'
t=$(libvar TGT_ROOT_MODULE RH_TARGET=fix-git); [ "$t" = A ]; res "TGT_ROOT_MODULE in config.env does not reach another target's settings" $? "$t"
t=$(libvar TGT_ROOT_MODULE RH_TARGET=fix-git TGT_ROOT_MODULE=Env.Root); [ "$t" = Env.Root ]; res "...and the environment wins over both" $? "$t"
nocfg
t=$(libvar TGT_TARBALL_SHA256 RH_TARGET=fix-git "TGT_TARBALL_SHA256=$(printf '%064d' 3)"); [ "$t" = "$(printf '%064d' 3)" ]; res "TGT_TARBALL_SHA256 in the environment over the profile's" $? "$t"
t=$(libvar TGT_STATEMENT_CONST TGT_STATEMENT_CONST=Env.Const); [ "$t" = Env.Const ]; res "a TGT_ value in the environment for the default target too" $? "$t"
t=$(cenv RH_PART_COUNT=5 /bin/bash "$DUMP" "$NEW/scripts/lib.sh" -- TGT_PART_COUNT RH_PART_COUNT 2>&1 | tr '\n' ' ')
[ "$t" = "TGT_PART_COUNT=[5] RH_PART_COUNT=[5] " ]; res "the old name RH_PART_COUNT still works for the default target, and both names hold it" $? "$t"
t=$(libvar TGT_PART_COUNT RH_TARGET=fix-git RH_PART_COUNT=5); [ -z "$t" ]; res "...and does nothing for another target" $? "TGT_PART_COUNT=[$t]"

# ================================================================ 11
section 11 "the default target's 01, 02 and 03 on a made-up tarball, against the base commit's"
if [ "$HAVE_BASE" = 1 ]; then
  nocfg
  # The made-up tarball's own record, made with the base commit's 02 and 03, is the record of both trees.
  for t in "$MAIN" "$NEW"; do mv "$t/records/source/expected.json" "$t/records/source/expected.json.real" 2>/dev/null; done
  WX="$TMPD/w11-record"; mkdir -p "$WX/download"; cp "$TB/good.tar.gz" "$WX/download/lean.tar.gz"
  cenv RH_WORKDIR="$WX" RH_TARBALL_SHA256="$GOODSHA" /bin/bash "$MAIN/scripts/02_inspect_and_extract.sh" --write-expected "$TMPD/c11.rec" > "$TMPD/c11.rec.out" 2>&1 \
    && cenv RH_WORKDIR="$WX" RH_TARBALL_SHA256="$GOODSHA" /bin/bash "$MAIN/scripts/03_audit_source.sh" --write-expected "$TMPD/c11.rec" > "$TMPD/c11.rec.out3" 2>&1
  res "(the base commit's 02 and 03 recorded the made-up tarball)" $? "$(tailof "$TMPD/c11.rec.out") $(tailof "$TMPD/c11.rec.out3")"
  cp "$TMPD/c11.rec" "$MAIN/records/source/expected.json"; cp "$TMPD/c11.rec" "$NEW/records/source/expected.json"
  WB="$TMPD/w11-base"; WN="$TMPD/w11-new"
  for w in "$WB" "$WN"; do mkdir -p "$w/download"; cp "$TB/good.tar.gz" "$w/download/lean.tar.gz"; done
  cmp11() { # cmp11 <description> <label> <script and arguments...>: both trees, RH_WORKDIR and RH_TARBALL_SHA256 given
    local d=$1 l=$2 rb rn; shift 2
    cenv RH_WORKDIR="$WB" RH_TARBALL_SHA256="$GOODSHA" ${C11ENV:-} /bin/bash "$MAIN/scripts/$@" > "$TMPD/c11.$l.base" 2>&1; rb=$?
    cenv RH_WORKDIR="$WN" RH_TARBALL_SHA256="$GOODSHA" ${C11ENV:-} /bin/bash "$NEW/scripts/$@" > "$TMPD/c11.$l.new" 2>&1; rn=$?
    norm "$TMPD/c11.$l.base" "$WB=<WD>" "$MAIN=<REPO>" > "$TMPD/c11.$l.b"; norm "$TMPD/c11.$l.new" "$WN=<WD>" "$NEW=<REPO>" > "$TMPD/c11.$l.n"
    cmp -s "$TMPD/c11.$l.b" "$TMPD/c11.$l.n" && [ "$rb" = "$rn" ]
    res "$d: the same output and status ($rn)" $? "status $rb/$rn; $(diff "$TMPD/c11.$l.b" "$TMPD/c11.$l.n" | grep '^[<>]' | head -6 | tr '\n' ' ')"
  }
  C11ENV=""
  cmp11 "01 with the tarball present" 01 01_fetch.sh
  C11ENV="RH_PART_COUNT=2"
  cmp11 "01 --check-only, RH_PART_COUNT=2 and no parts on disk" 01c 01_fetch.sh --check-only
  C11ENV=""
  cmp11 "02 (lists, extracts, checks the project files)" 02 02_inspect_and_extract.sh
  ( cd "$WB/extract" && find . -type f | LC_ALL=C sort | while IFS= read -r f; do echo "$(sha "$f") $f"; done ) > "$TMPD/c11.tree.b"
  ( cd "$WN/extract" && find . -type f | LC_ALL=C sort | while IFS= read -r f; do echo "$(sha "$f") $f"; done ) > "$TMPD/c11.tree.n"
  [ -s "$TMPD/c11.tree.b" ] && cmp -s "$TMPD/c11.tree.b" "$TMPD/c11.tree.n"; res "...the same extracted files, with the same bytes" $? "$(diff "$TMPD/c11.tree.b" "$TMPD/c11.tree.n" | head -4 | tr '\n' ' ')"
  cmp11 "02 again (already extracted)" 02b 02_inspect_and_extract.sh
  cmp11 "02 --verify-tree" 02v 02_inspect_and_extract.sh --verify-tree
  cmp11 "03 --show 2" 03 03_audit_source.sh --show 2
  grep -q 'matches the recorded values' "$TMPD/c11.02.new"; res "(02 compared with the record there)" $? "$(tailof "$TMPD/c11.02.new")"
  for t in "$MAIN" "$NEW"; do mv "$t/records/source/expected.json.real" "$t/records/source/expected.json" 2>/dev/null; done
else
  skip "no base commit to compare with"
fi

# ================================================================ 12
section 12 "a profile whose sources are the project directory itself (TGT_SRC_DIR=.)"
prof fix-flat TGT_GIT_SUBDIR=proj2 TGT_ARCHIVE_PREFIX=proj2/ TGT_SRC_DIR=.
W12="$NEW/work-fix-flat"
t=$(libvar RH_SRC RH_TARGET=fix-flat); [ "$t" = "$W12/extract/proj2" ]; res "lib.sh accepts TGT_SRC_DIR=. (RH_SRC is the project directory)" $? "$t"
cenv RH_TARGET=fix-flat /bin/bash "$NEW/scripts/01_fetch.sh" > "$TMPD/c12.a" 2>&1; rc=$?
[ "$rc" = 0 ]; res "01 writes its tar file" $? "status $rc: $(tailof "$TMPD/c12.a")"
cenv RH_TARGET=fix-flat /bin/bash "$NEW/scripts/02_inspect_and_extract.sh" > "$TMPD/c12.b" 2>&1; rc=$?
[ "$rc" = 0 ] && [ -f "$W12/extract/proj2/A.lean" ] && grep -q 'Lean files under proj2/: 2' "$TMPD/c12.b"
res "02 lists, counts 2 Lean sources under proj2/, and extracts" $? "status $rc: $(tailof "$TMPD/c12.b" 2)"
if [ ! -d "$W12/extract/proj2" ]; then      # so that 03 can be tried all the same
  mkdir -p "$W12/extract" && tar -xmf "$W12/download/source.tar" -C "$W12/extract"
  echo "INFO  (extracted with tar for the next check, since 02 did not)"
fi
mkdir -p "$W12/extract/proj2/.lake/packages/dep"; printf 'theorem d : True := sorry\n' > "$W12/extract/proj2/.lake/packages/dep/D.lean"
cenv RH_TARGET=fix-flat /bin/bash "$NEW/scripts/03_audit_source.sh" --show 0 > "$TMPD/c12.c" 2>&1; rc=$?
[ "$rc" = 0 ] && grep -q 'scanning 2 Lean files' "$TMPD/c12.c" && grep -q 'its .lake directory is not scanned' "$TMPD/c12.c" && ! grep -q '^sorry  *[1-9]' "$TMPD/c12.c"
res "03 scans the 2 sources and leaves out .lake" $? "status $rc: $(grep -i 'scanning\|lake\|^sorry' "$TMPD/c12.c" | tr '\n' ' ')"

# ================================================================ 13
section 13 "nothing reached for the network or the toolchain"
[ ! -s "$STUBLOG" ]; res "no stand-in of curl, wget, lake, elan or leanchecker was called" $? "$(tailof "$STUBLOG" 5)"

# ---------------------------------------------------------------- helpers for the cases from 14 on
nocfg
# A narrower PATH: the stand-ins, python3 and git through wrappers, and the system's directories. The directories
# python3 and git come from are left out, so that an elan, gcloud or rg installed there is not found.
PYBIN="$TMPD/pybin"; mkdir -p "$PYBIN"
printf '#!/bin/sh\nexec "%s" "$@"\n' "$PY3" > "$PYBIN/python3"; printf '#!/bin/sh\nexec "%s" "$@"\n' "$GIT" > "$PYBIN/git"
chmod +x "$PYBIN"/*
NPATH="$STUB:$PYBIN:/usr/bin:/bin:/usr/sbin:/sbin"
HAVE_RG=0; cenv /bin/sh -c 'command -v rg' > /dev/null 2>&1 && HAVE_RG=1
NPATH_RG=0; cenv PATH="$NPATH" /bin/sh -c 'command -v rg' > /dev/null 2>&1 && NPATH_RG=1
# PYRUN: run one of the scripts in analysis/ with python3 -I -B, which leaves the script's own directory off
# sys.path; it is put back, as running the script plainly would. Usage: "$PY3" -I -B -c "$PYRUN" <script> [args]
PYRUN='import os, runpy, sys; s = sys.argv[1]; sys.path.insert(0, os.path.dirname(os.path.abspath(s))); sys.argv = sys.argv[1:]; runpy.run_path(s, run_name="__main__")'
# jsonok <file> <python expression on d>: true if the file is JSON and the expression holds for it
jsonok() { "$PY3" -I -B -c 'import json, sys; d = json.load(open(sys.argv[1], encoding="utf-8")); sys.exit(0 if eval(sys.argv[2]) else 1)' "$1" "$2" 2>/dev/null; }
TAB=$(printf '\t')
OK_MARK=$(printf '\342\234\224'); WARN_MARK=$(printf '\342\232\240'); INFO_MARK=$(printf '\342\204\271')
NFC_E=$(printf '\303\251'); NFD_E=$(printf 'e\314\201'); ZWNJ=$(printf '\342\200\214')

# ================================================================ 14
section 14 "rhv_tools.py git-export refuses .git and .lake components and names that are one on macOS"
blob() { printf '%s' "$1" | g hash-object -w --stdin; }
tree() { printf '%s\n' "$@" | g mktree; }      # tree <'mode type object<TAB>name'>...: git does not check the names
# withproj <branch> <entry>...: a commit on top of main whose proj/ has these entries as well; sets LASTC to it
withproj() {
  local b=$1 p r; shift; LASTC=""
  p=$( { g ls-tree "$C_MAIN:proj"; printf '%s\n' "$@"; } | g mktree ) || return 1
  r=$( { g ls-tree "$C_MAIN" | awk -F'\t' '$2 != "proj"'; printf '040000 tree %s\tproj\n' "$p"; } | g mktree ) || return 1
  LASTC=$(g commit-tree "$r" -p "$C_MAIN" -m "$b") && g update-ref "refs/heads/$b" "$LASTC"
}
ge() { # ge <label> <commit>: git-export of proj/ of the commit, as 01_fetch.sh asks for it; the status in GE
  cenv "$PY3" -I -B "$TOOLS" git-export --git-dir "$REPO/.git" --commit "$2" --subdir proj --prefix proj/ \
    --out "$TMPD/c14.$1.tar" > "$TMPD/c14.$1.out" 2>&1; GE=$?
}
gexp() { # gexp <description> <label> <text of the message> <entry>...: refused, with that text, and no file written
  local d=$1 l=$2 want=$3; shift 3
  if ! withproj "c14-$l" "$@" || [ -z "$LASTC" ]; then fail "$d" "could not make the commit"; return; fi
  ge "$l" "$LASTC"
  [ "$GE" = 1 ] && grep -q 'git-export: REFUSED: ' "$TMPD/c14.$l.out" && grep -q -F -- "$want" "$TMPD/c14.$l.out" \
    && grep -q 'nothing was written to' "$TMPD/c14.$l.out" && [ ! -e "$TMPD/c14.$l.tar" ] && [ ! -e "$TMPD/c14.$l.tar.tmp" ]
  res "$d: status 1, the message, no file" $? "status $GE: $(tailof "$TMPD/c14.$l.out" 3)"
}
B14a=$(blob one); B14b=$(blob two)
CFG14=$(tree "100644 blob $B14a${TAB}config")
DOTGIT="a '.git' component"
gexp "proj/.git/config" dotgit "$DOTGIT (git's own directory, refused in any spelling): '.git'" "040000 tree $CFG14${TAB}.git"
C14DOT=$LASTC
gexp "proj/deep/.git/config, further down" deep "$DOTGIT (git's own directory, refused in any spelling): 'deep/.git'" \
  "040000 tree $(tree "040000 tree $CFG14${TAB}.git")${TAB}deep"
gexp "proj/.GIT/x" upper "$DOTGIT" "040000 tree $(tree "100644 blob $B14a${TAB}x")${TAB}.GIT"
gexp "proj/.g<U+200C>it/config (a character macOS leaves out of names)" hfs "$DOTGIT" "040000 tree $CFG14${TAB}.g${ZWNJ}it"
gexp "proj/git~1/config (the short name Windows may give .git)" short "$DOTGIT" "040000 tree $CFG14${TAB}git~1"
gexp "proj/.git./config" dot "$DOTGIT" "040000 tree $CFG14${TAB}.git."
gexp "'proj/.git /config' (a space at the end)" space "$DOTGIT" "040000 tree $CFG14${TAB}.git "
gexp "proj/.lake/build/x.olean" lake "a '.lake' component (Lake's directory of build products and packages): '.lake'" \
  "040000 tree $(tree "040000 tree $(tree "100644 blob $B14a${TAB}x.olean")${TAB}build")${TAB}.lake"
NAMES_ONE="two names that are one where case and Unicode normalisation are ignored, as on macOS"
gexp "Foo.lean and foo.lean" case "$NAMES_ONE: Foo.lean and foo.lean" "100644 blob $B14a${TAB}Foo.lean" "100644 blob $B14b${TAB}foo.lean"
gexp "e-acute.lean in NFC and in NFD" nfd "$NAMES_ONE" "100644 blob $B14a${TAB}$NFC_E.lean" "100644 blob $B14b${TAB}$NFD_E.lean"
gexp "directories A/ and a/ with different files" dirs "$NAMES_ONE: A and a" \
  "040000 tree $(tree "100644 blob $B14a${TAB}x.lean")${TAB}A" "040000 tree $(tree "100644 blob $B14b${TAB}y.lean")${TAB}a"
n14=$(g ls-tree -r --name-only "$C_MAIN" -- proj/ | wc -l | tr -d ' ')
if withproj c14-near "100644 blob $B14a${TAB}.gitignore" "040000 tree $(tree "100644 blob $B14a${TAB}ci.yml")${TAB}.github" \
     "100644 blob $B14a${TAB}git~2" "040000 tree $(tree "100644 blob $B14a${TAB}y")${TAB}.gitx" \
     "040000 tree $(tree "100644 blob $B14a${TAB}z")${TAB}lake" "100644 blob $B14a${TAB}.lakefile" \
     "100644 blob $B14a${TAB}$NFC_E.lean" "100644 blob $B14b${TAB}Foo.lean" && [ -n "$LASTC" ]; then
  ge near "$LASTC"
  [ "$GE" = 0 ] && grep -q "^sha256 [0-9a-f]\{64\} entries $((n14 + 8))\$" "$TMPD/c14.near.out" && [ -s "$TMPD/c14.near.tar" ]
  res "near misses (.gitignore, .github/, git~2, .gitx/, lake/, .lakefile, e-acute.lean once, Foo.lean alone): written, $((n14 + 8)) files" $? "status $GE: $(tailof "$TMPD/c14.near.out" 3)"
else
  fail "near misses" "could not make the commit"
fi
prof fix-dotgit "TGT_GIT_COMMIT=$C14DOT"
refused "01 on the commit with proj/.git/config stops" "$DOTGIT" RH_TARGET=fix-dotgit /bin/bash "$NEW/scripts/01_fetch.sh"
[ ! -e "$NEW/work-fix-dotgit/download/source.tar" ] && [ ! -e "$NEW/work-fix-dotgit/download/source.tar.tmp" ]; res "...and writes no tar file" $?

# ================================================================ 15
section 15 "rhv_tools.py tar-inspect: the same refusals in tarballs, and the base commit's output on clean ones"
"$PY3" -I -B - "$TB/good.tar" "$TB" <<'PY'
import gzip, io, os, sys, tarfile
src, out = sys.argv[1], sys.argv[2]
with tarfile.open(src) as tf:
    base = [(m, tf.extractfile(m).read()) for m in tf.getmembers()]
def write(label, extra):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w", format=tarfile.GNU_FORMAT) as tf:
        for m, d in base:
            tf.addfile(m, io.BytesIO(d))
        for name, data in extra:
            ti = tarfile.TarInfo(name); ti.mode = 0o644; ti.mtime = 1700000000
            b = data.encode(); ti.size = len(b)
            tf.addfile(ti, io.BytesIO(b))
    with open(os.path.join(out, "c15-%s.tar.gz" % label), "wb") as fh:
        fh.write(gzip.compress(buf.getvalue(), mtime=0))
write("dotgit", [("lean/.git/config", "x\n")])
write("deep", [("lean/src/deep/.git/config", "x\n")])
write("upper", [("lean/.GIT/x", "x\n")])
write("hfs", [("lean/.g‌it/config", "x\n")])
write("short", [("lean/git~1/config", "x\n")])
write("dot", [("lean/.git./config", "x\n")])
write("space", [("lean/.git /config", "x\n")])
write("lake", [("lean/.lake/build/x.olean", "x\n")])
write("case", [("lean/src/Foo.lean", "one\n"), ("lean/src/foo.lean", "two\n")])
write("nfd", [("lean/src/é.lean", "one\n"), ("lean/src/é.lean", "two\n")])
write("dirs", [("lean/A/x.lean", "one\n"), ("lean/a/y.lean", "two\n")])
write("near", [("lean/.gitignore", "x\n"), ("lean/.github/ci.yml", "x\n"), ("lean/git~2", "x\n"), ("lean/.gitx/y", "x\n"),
               ("lean/lake/z", "x\n"), ("lean/.lakefile", "x\n"), ("lean/src/é.lean", "one\n"), ("lean/src/Foo.lean", "two\n")])
PY
[ -f "$TB/c15-near.tar.gz" ]; res "(the tarballs were made)" $?
tinsp() { # tinsp <description> <label> <text>: tar-inspect as 02 runs it refuses c15-<label>: status 1, the reason, no record
  local d=$1 l=$2 want=$3 rc
  cenv "$PY3" -I -B "$TOOLS" tar-inspect "$TB/c15-$l.tar.gz" --prefix lean/ --src-dir src --write-expected "$TMPD/c15.$l.json" \
    > "$TMPD/c15.$l.out" 2>&1; rc=$?
  [ "$rc" = 1 ] && grep -q '^UNSAFE OR UNEXPECTED ENTRIES: 1 ' "$TMPD/c15.$l.out" && grep -q -F -- "$want" "$TMPD/c15.$l.out" && [ ! -e "$TMPD/c15.$l.json" ]
  res "$d: status 1, the reason, nothing recorded" $? "status $rc: $(grep -A2 '^UNSAFE' "$TMPD/c15.$l.out" | tr '\n' ' ')"
}
TGIT="a '.git' component (git's own directory, refused in any spelling): lean/"
tinsp "lean/.git/config" dotgit "${TGIT}.git/config"
tinsp "lean/src/deep/.git/config" deep "${TGIT}src/deep/.git/config"
tinsp "lean/.GIT/x" upper "${TGIT}.GIT/x"
tinsp "lean/.g<U+200C>it/config" hfs "${TGIT}.g${ZWNJ}it/config"
tinsp "lean/git~1/config" short "${TGIT}git~1/config"
tinsp "lean/.git./config" dot "${TGIT}.git./config"
tinsp "'lean/.git /config'" space "${TGIT}.git /config"
tinsp "lean/.lake/build/x.olean" lake "a '.lake' component (Lake's directory of build products and packages): lean/.lake/build/x.olean"
TONE="one name where case and Unicode normalisation are ignored, as on macOS"
tinsp "lean/src/Foo.lean and lean/src/foo.lean" case "$TONE: lean/src/Foo.lean and lean/src/foo.lean"
tinsp "lean/src/e-acute.lean in NFC and in NFD" nfd "$TONE: lean/src/"
tinsp "directories lean/A/ and lean/a/ with different files" dirs "$TONE: lean/A and lean/a"
if [ "$HAVE_BASE" = 1 ]; then
  OLDT="$MAIN/scripts/verify/rhv_tools.py"
  c15same() { # c15same <description> <tarball> <record>: the base tool without the new arguments, the new one with them
    local d=$1 t=$2 r=$3 rb rn
    cenv "$PY3" -I -B "$OLDT" tar-inspect "$t" --sha256 "$(sha "$t")" --expected "$r" > "$TMPD/c15.same.base" 2>&1; rb=$?
    cenv "$PY3" -I -B "$TOOLS" tar-inspect "$t" --prefix lean/ --src-dir src --sha256 "$(sha "$t")" --expected "$r" > "$TMPD/c15.same.new" 2>&1; rn=$?
    [ "$rb" = 0 ] && [ "$rn" = 0 ] && cmp -s "$TMPD/c15.same.base" "$TMPD/c15.same.new" && grep -q 'tarball listing: matches the recorded values' "$TMPD/c15.same.new"
    res "$d: the base commit's output, byte for byte" $? "status $rb/$rn; $(diff "$TMPD/c15.same.base" "$TMPD/c15.same.new" | grep '^[<>]' | head -4 | tr '\n' ' ')"
  }
  c15same "the clean gzipped tarball under lean/, with --prefix lean/ --src-dir src" "$TB/good.tar.gz" "$TMPD/c8.expected.base"
  cenv "$PY3" -I -B "$OLDT" tar-inspect "$TB/c15-near.tar.gz" --sha256 "$(sha "$TB/c15-near.tar.gz")" --write-expected "$TMPD/c15.near.rec" > /dev/null 2>&1
  c15same "the tarball of near misses (.gitignore, .github/, git~2, .gitx/, lake/, .lakefile, e-acute.lean once)" "$TB/c15-near.tar.gz" "$TMPD/c15.near.rec"
  cenv "$PY3" -I -B "$OLDT" tar-inspect "$TB/bad.tar.gz" > "$TMPD/c15.bad.base" 2>&1; rb=$?
  cenv "$PY3" -I -B "$TOOLS" tar-inspect "$TB/bad.tar.gz" --prefix lean/ --src-dir src > "$TMPD/c15.bad.new" 2>&1; rn=$?
  # With nothing to compare with, the one accepted change: that line is now in capitals (see case 8).
  grep -v -i 'no recorded values' "$TMPD/c15.bad.base" > "$TMPD/c15.bad.b"; grep -v -i 'no recorded values' "$TMPD/c15.bad.new" > "$TMPD/c15.bad.n"
  cmp -s "$TMPD/c15.bad.b" "$TMPD/c15.bad.n" && [ "$rb" = "$rn" ] && [ "$(grep -c -i 'no recorded values' "$TMPD/c15.bad.base")" = 1 ] \
    && [ "$(grep -c 'NO RECORDED VALUES TO COMPARE WITH' "$TMPD/c15.bad.new")" = 1 ]
  res "the tarball of case 8 with every older refusal, with the new arguments: the same output but for the line in capitals (status $rn)" $? "$(diff "$TMPD/c15.bad.b" "$TMPD/c15.bad.n" | grep '^[<>]' | head -4 | tr '\n' ' ')"
else
  skip "comparisons with the base commit's tar-inspect: no base commit"
fi
cenv "$PY3" -I -B "$TOOLS" tar-inspect "$TB/good.tar.gz" --prefix lean/ --src-dir . > "$TMPD/c15.dot" 2>&1; rc=$?
[ "$rc" = 0 ] && grep -q '^Lean files under lean/: 3$' "$TMPD/c15.dot"; res "--src-dir . counts the Lean files under the prefix itself (3)" $? "status $rc: $(grep 'Lean files' "$TMPD/c15.dot")"

# ================================================================ 16
section 16 "TGT_SRC_DIR=. end to end: the records, the counts and the import graph leave out .lake"
W16P="$W12/extract/proj2"; REC16="$NEW/targets/fix-flat/records/expected.json"
if [ ! -f "$W16P/.lake/packages/dep/D.lean" ]; then
  mkdir -p "$W16P/.lake/packages/dep"; printf 'theorem d : True := sorry\n' > "$W16P/.lake/packages/dep/D.lean"
fi
cenv RH_TARGET=fix-flat /bin/bash "$NEW/scripts/01_fetch.sh" > "$TMPD/c16.0" 2>&1; rc=$?
[ "$rc" = 0 ] && grep -q 'clone already present' "$TMPD/c16.0" && grep -q 'the clone holds commit' "$TMPD/c16.0"
res "01 again (case 12 ran it first): the clone is used, and the tar file written again" $? "status $rc: $(tailof "$TMPD/c16.0" 2)"
t=$(cenv RH_TARGET=fix-flat /bin/bash -c '. "$1" && . "$2" && count_sources' _ "$NEW/scripts/lib.sh" "$NEW/scripts/common.sh" 2>&1)
[ "$t" = 2 ]; res "count_sources: 2, not the .lean file in the .lake directory made after extraction" $? "$t"
rm -rf "${NEW:?}/targets/fix-flat/records"
cenv RH_TARGET=fix-flat /bin/bash "$NEW/scripts/02_inspect_and_extract.sh" --write-expected "$REC16" > "$TMPD/c16.a" 2>&1; rc=$?
[ "$rc" = 0 ] && grep -q "created $NEW/targets/fix-flat/records" "$TMPD/c16.a" && grep -q 'already extracted: .* (2 Lean source files)' "$TMPD/c16.a" \
  && jsonok "$REC16" 'd["tarball"]["source_lean_files"] == 2 and "project" in d'
res "02 --write-expected: creates the records directory, records 2 sources; 'already extracted' counts 2" $? "status $rc: $(grep -i 'created\|already\|recorded' "$TMPD/c16.a" | tr '\n' ' ')"
cenv RH_TARGET=fix-flat /bin/bash "$NEW/scripts/03_audit_source.sh" --show 0 --write-expected "$REC16" > "$TMPD/c16.b" 2>&1; rc=$?
[ "$rc" = 0 ] && jsonok "$REC16" 'd["audit"]["lean_files"] == 2 and d["audit"]["categories"]["sorry"]["lines"] == 0 and "tarball" in d'
res "03 --write-expected: records 2 files and no sorry (the one in .lake is left out), keeping 02's sections" $? "status $rc: $(tailof "$TMPD/c16.b" 2)"
cenv RH_TARGET=fix-flat /bin/bash "$NEW/scripts/03_audit_source.sh" --show 0 > "$TMPD/c16.c" 2>&1; rc=$?
[ "$rc" = 0 ] && grep -q 'scanning 2 Lean files' "$TMPD/c16.c" && grep -q 'comparison: matches the recorded values' "$TMPD/c16.c"
res "03 again ($( [ "$HAVE_RG" = 1 ] && echo rg || echo grep )): 2 files, and it matches that record" $? "status $rc: $(tailof "$TMPD/c16.c" 2)"
cenv RH_TARGET=fix-flat /bin/bash "$NEW/scripts/03_audit_source.sh" --tool grep --show 0 > "$TMPD/c16.d" 2>&1; rc=$?
[ "$rc" = 0 ] && grep -q 'scanning 2 Lean files with grep' "$TMPD/c16.d" && grep -q 'comparison: matches the recorded values' "$TMPD/c16.d"
res "03 --tool grep leaves .lake out the same way and matches the record" $? "status $rc: $(tailof "$TMPD/c16.d" 2)"
cenv RH_TARGET=fix-flat /bin/bash "$NEW/scripts/02_inspect_and_extract.sh" --verify-tree > "$TMPD/c16.e" 2>&1; rc=$?
[ "$rc" = 0 ] && grep -q 'byte-for-byte' "$TMPD/c16.e" && grep -q 'tarball listing: matches the recorded values' "$TMPD/c16.e"
res "02 --verify-tree with .lake there: the files are the archive's, and the listing matches the record" $? "status $rc: $(tailof "$TMPD/c16.e" 3)"
cenv RH_TARGET=fix-flat "$PY3" -I -B -c "$PYRUN" "$NEW/analysis/import_graph.py" > "$TMPD/c16.f" 2>&1; rc=$?
[ "$rc" = 0 ] && jsonok "$W12/analysis/import_graph_summary.json" 'd["modules_total"] == 2 and d["root"] == "A" and d["main_closure_modules"] == 2' \
  && jsonok "$W12/analysis/import_graph.json" 'sorted(d) == ["A", "B.C"]'
res "import_graph.py with no arguments: the target's sources and root module A; 2 modules, none from .lake" $? "status $rc: $(tailof "$TMPD/c16.f" 2)"
cenv RH_TARGET=fix-flat "$PY3" -I -B -c "$PYRUN" "$NEW/analysis/closure_stats.py" > "$TMPD/c16.g" 2>&1; rc=$?
[ "$rc" = 0 ] && jsonok "$W12/analysis/closure_stats.json" 'd["key_module_closures"] == {"A": 1}'
res "closure_stats.py with no --key reports the root module A" $? "status $rc: $(tailof "$TMPD/c16.g" 2)"
cp "$W12/analysis/import_graph_summary.json" "$NEW/targets/fix-flat/records/"
# For S10: only .lean files are searched, and not those in .lake. Below: hidden ones, and ones that ignore files name,
# are searched too.
printf 'zzmark\n' > "$W16P/.lake/packages/dep/marker.lean"; printf 'zzmark\n' > "$W16P/notes.txt"
rows16() { echo "S1=$(row "$1" S1) S2-S4=$(row "$1" S2-S4) S5=$(row "$1" S5) S6-S8=$(row "$1" S6-S8) S9=$(row "$1" S9) S10=$(row "$1" S10)"; }
cenv RH_TARGET=fix-flat TGT_S10_PATTERN=zzmark TGT_S10_COUNT=0 /bin/bash "$NEW/scripts/reproduce_findings.sh" > "$TMPD/c16.h" 2>&1; rc=$?
t=$(rows16 "$TMPD/c16.h")
[ "$rc" = 0 ] && [ "$t" = "S1=PASS S2-S4=PASS S5=n/a S6-S8=PASS S9=PASS S10=PASS" ]
res "reproduce_findings.sh ($( [ "$HAVE_RG" = 1 ] && echo rg || echo grep )): S2-S4, S6-S8 and S9 pass against the record; S10 counts neither the .lean file in .lake nor a .txt file" $? "status $rc: $t; $(grep '^S10' "$TMPD/c16.h")"
printf 'zzmark\n' > "$W16P/.hidden.lean"; printf 'zzmark\n' > "$W16P/ignored.lean"
for f in .ignore .rgignore .gitignore; do printf 'ignored.lean\n.hidden.lean\n' > "$W16P/$f"; done
cenv RH_TARGET=fix-flat TGT_S10_PATTERN=zzmark TGT_S10_COUNT=2 /bin/bash "$NEW/scripts/reproduce_findings.sh" > "$TMPD/c16.h2" 2>&1
t=$(row "$TMPD/c16.h2" S10); [ "$t" = PASS ]
res "...and S10 counts a hidden .lean file and one that the ignore files name (2)" $? "$(grep '^S10' "$TMPD/c16.h2")"
if [ "$NPATH_RG" = 0 ]; then
  cenv PATH="$NPATH" RH_TARGET=fix-flat TGT_S10_PATTERN=zzmark TGT_S10_COUNT=2 /bin/bash "$NEW/scripts/reproduce_findings.sh" > "$TMPD/c16.i" 2>&1
  t=$(row "$TMPD/c16.i" S10); [ "$t" = PASS ]
  res "...and the same with grep (no rg on the PATH)" $? "$(grep '^S10' "$TMPD/c16.i")"
else
  skip "S10 with grep: rg is on the narrower PATH too"
fi
rm -f "$W16P/.hidden.lean" "$W16P/ignored.lean" "$W16P/notes.txt" "$W16P/.ignore" "$W16P/.rgignore" "$W16P/.gitignore" "$W16P/.lake/packages/dep/marker.lean"

# ================================================================ 17
section 17 "lib.sh: the paths of a profile, component by component"
for v in ./src src/. src/ /src a//b .. src/../x -x a/-b a..b; do
  prof fix-bad "TGT_SRC_DIR=$v"
  refused "TGT_SRC_DIR '$v' is refused" "TGT_SRC_DIR must be" RH_TARGET=fix-bad /bin/bash "$NEW/scripts/01_fetch.sh" --check-only
done
prof fix-bad "TGT_SRC_DIR='a\\b'"
refused "TGT_SRC_DIR 'a\\b' (a backslash) is refused" "TGT_SRC_DIR must be" RH_TARGET=fix-bad /bin/bash "$NEW/scripts/01_fetch.sh" --check-only
refused "TGT_SRC_DIR './src' in the environment is refused for the default target too" "TGT_SRC_DIR must be" \
  RH_WORKDIR="$TMPD/w17" TGT_SRC_DIR=./src /bin/bash "$NEW/scripts/01_fetch.sh" --check-only
for v in . records/./x /x x/; do
  prof fix-bad "TGT_RECORDS_DIR=$v"
  refused "TGT_RECORDS_DIR '$v' is refused" "TGT_RECORDS_DIR must be" RH_TARGET=fix-bad /bin/bash "$NEW/scripts/01_fetch.sh" --check-only
done
for v in a/./ a//; do
  prof fix-bad "TGT_ARCHIVE_PREFIX=$v"
  refused "TGT_ARCHIVE_PREFIX '$v' is refused" "TGT_ARCHIVE_PREFIX must be" RH_TARGET=fix-bad /bin/bash "$NEW/scripts/01_fetch.sh" --check-only
done
WB17="$NEW/work-fix-bad/extract"
prof fix-bad TGT_SRC_DIR=.
t=$(cenv RH_TARGET=fix-bad /bin/bash "$DUMP" "$NEW/scripts/lib.sh" -- RH_PROJ RH_SRC 2>&1 | tr '\n' ' ')
[ "$t" = "RH_PROJ=[$WB17/proj] RH_SRC=[$WB17/proj] " ]; res "TGT_SRC_DIR '.' is accepted, and RH_SRC is the project directory" $? "$t"
prof fix-bad TGT_SRC_DIR=src/Sub
t=$(cenv RH_TARGET=fix-bad /bin/bash "$DUMP" "$NEW/scripts/lib.sh" -- RH_SRC 2>&1 | tr '\n' ' ')
[ "$t" = "RH_SRC=[$WB17/proj/src/Sub] " ]; res "TGT_SRC_DIR 'src/Sub' is accepted" $? "$t"
prof fix-bad TGT_ARCHIVE_PREFIX=a/b/
t=$(cenv RH_TARGET=fix-bad /bin/bash "$DUMP" "$NEW/scripts/lib.sh" -- RH_PROJ 2>&1 | tr '\n' ' ')
[ "$t" = "RH_PROJ=[$WB17/a/b] " ]; res "TGT_ARCHIVE_PREFIX 'a/b/' is accepted" $? "$t"
[ ! -e "$NEW/work-fix-bad" ] && [ ! -e "$TMPD/w17" ]; res "none of these left a working directory behind" $?

# ================================================================ 18
section 18 "extract.from: which archive an extracted tree came from (every target but the default one)"
prof fix-from; W18="$NEW/work-fix-from"
cenv RH_TARGET=fix-from /bin/bash "$NEW/scripts/01_fetch.sh" > "$TMPD/c18.a" 2>&1 \
  && cenv RH_TARGET=fix-from /bin/bash "$NEW/scripts/02_inspect_and_extract.sh" > "$TMPD/c18.b" 2>&1; rc=$?
H18=""; [ -f "$W18/download/source.tar" ] && H18=$(sha "$W18/download/source.tar")
R18=$(record fix-from "$H18")
[ "$rc" = 0 ] && [ -n "$H18" ] && [ "$(cat "$W18/extract.from" 2>/dev/null)" = "$R18" ] \
  && [ "$R18" = "sha256 $H18 git $REPO commit $C_MAIN subdir proj prefix proj/" ] && [ "$(cat "$W18/download/source.tar.from" 2>/dev/null)" = "$R18" ]
res "01 and 02 for a git target: 01 writes source.tar.from and 02 extract.from, 'sha256 <SHA-256> git <address> commit <commit> subdir proj prefix proj/'" $? \
  "status $rc: $(cat "$W18/extract.from" 2>&1) $(tailof "$TMPD/c18.b")"
refused "03 stops if the tree has no extract.from" "is not recorded as extracted from the source that the profile" \
  RH_TARGET=fix-from /bin/bash -c 'mv "$1/extract.from" "$1/x"; /bin/bash "$2/scripts/03_audit_source.sh" --show 0; rc=$?; mv "$1/x" "$1/extract.from"; exit $rc' _ "$W18" "$NEW"
cenv RH_TARGET=fix-from /bin/bash "$NEW/scripts/03_audit_source.sh" --show 0 > "$TMPD/c18.a3" 2>&1; rc=$?
res "...and goes on when it names the archive the profile names" $rc "$(tailof "$TMPD/c18.a3")"
C18=$(branch from-second 100644 proj/src/B/D.lean "$(printf 'def d : Nat := 2\n')")
prof fix-from "TGT_GIT_COMMIT=$C18"
refused "a second commit, made after the clone: 01 stops and says to use --redownload" "run this script again with --redownload" \
  RH_TARGET=fix-from /bin/bash "$NEW/scripts/01_fetch.sh"
refused "with the profile at the second commit, 03 stops: the tree is the first commit's" "is not recorded as extracted from the source that the profile" \
  RH_TARGET=fix-from /bin/bash "$NEW/scripts/03_audit_source.sh" --show 0
refused "...and so does 08 (before it looks for lean or a build)" "is not recorded as extracted from the source that the profile" \
  RH_TARGET=fix-from /bin/bash "$NEW/scripts/08_check_axioms.sh"
# targets/README.md: "After a change of commit, move extract aside and run 02 again." Done before 01 has written the
# second commit's tar file, the tar file in download/ is still the first commit's; no SHA-256 is pinned, and 02 says
# the file "is identified only by the commit that 01_fetch.sh wrote it from", so it should not be taken for the second.
mv "$W18/extract" "$W18/extract.kept"; cp "$W18/extract.from" "$W18/extract.from.kept"
cenv RH_TARGET=fix-from /bin/bash "$NEW/scripts/02_inspect_and_extract.sh" > "$TMPD/c18.s" 2>&1; rc=$?
[ "$rc" != 0 ] && [ ! -e "$W18/extract" ]
res "the commit changed, 01 stopped, extract moved aside: 02 does not extract the first commit's tar file for the second commit" $? \
  "status $rc; extract.from now '$(cat "$W18/extract.from" 2>&1)'; $(grep -c . "$TMPD/c18.s") lines, the last: $(tailof "$TMPD/c18.s" 1)"
rm -rf "${W18:?}/extract" "$W18/extract.partial"; mv "$W18/extract.kept" "$W18/extract"; mv "$W18/extract.from.kept" "$W18/extract.from"
cenv RH_TARGET=fix-from /bin/bash "$NEW/scripts/01_fetch.sh" --redownload > "$TMPD/c18.c" 2>&1; rc=$?
H18b=""; [ -f "$W18/download/source.tar" ] && H18b=$(sha "$W18/download/source.tar")
[ "$rc" = 0 ] && [ -n "$H18b" ] && [ "$H18b" != "$H18" ]; res "01 --redownload: a new clone, and the second commit's tar file (another SHA-256)" $? "status $rc: $(tailof "$TMPD/c18.c")"
cenv RH_TARGET=fix-from /bin/bash "$NEW/scripts/02_inspect_and_extract.sh" > "$TMPD/c18.d" 2>&1; rc=$?
[ "$rc" = 1 ] && grep -q 'and the archive with the profile gives' "$TMPD/c18.d" && [ ! -e "$W18/extract/proj/src/B/D.lean" ] \
  && [ "$(cat "$W18/extract.from" 2>/dev/null)" = "$R18" ]
res "02 then stops (status 1): the tree was not extracted from the archive there now; tree and extract.from unchanged" $? "status $rc: $(tailof "$TMPD/c18.d" 2)"
mv "$W18/extract" "$W18/extract.first"
cenv RH_TARGET=fix-from /bin/bash "$NEW/scripts/02_inspect_and_extract.sh" > "$TMPD/c18.e" 2>&1; rc=$?
[ "$rc" = 0 ] && [ -f "$W18/extract/proj/src/B/D.lean" ] && [ "$(cat "$W18/extract.from" 2>/dev/null)" = "$(record fix-from "$H18b")" ] \
  && [ "$(record fix-from "$H18b")" = "sha256 $H18b git $REPO commit $C18 subdir proj prefix proj/" ]
res "with the tree moved aside, 02 extracts the second commit and names it in extract.from" $? "status $rc: $(cat "$W18/extract.from" 2>&1) $(tailof "$TMPD/c18.e" 2)"
cenv RH_TARGET=fix-from /bin/bash "$NEW/scripts/02_inspect_and_extract.sh" > "$TMPD/c18.f" 2>&1; rc=$?
[ "$rc" = 0 ] && grep -q 'already extracted' "$TMPD/c18.f"; res "02 again: that tree is used as it is" $? "status $rc: $(tailof "$TMPD/c18.f" 2)"
mv "$W18/extract.from" "$W18/extract.from.saved"
refused "a tree with no extract.from beside it is not used" "says 'nothing'" RH_TARGET=fix-from /bin/bash "$NEW/scripts/02_inspect_and_extract.sh"
mv "$W18/extract.from.saved" "$W18/extract.from"
W18d="$TMPD/w18default"; mkdir -p "$W18d/download"; cp "$TB/good.tar.gz" "$W18d/download/lean.tar.gz"
cenv RH_WORKDIR="$W18d" RH_TARBALL_SHA256="$GOODSHA" TGT_RECORDS_DIR=records/c18-nothing \
  /bin/bash "$NEW/scripts/02_inspect_and_extract.sh" > "$TMPD/c18.g" 2>&1; rc=$?
[ "$rc" = 0 ] && [ -f "$W18d/extract/lean/lakefile.toml" ] && [ ! -e "$W18d/extract.from" ]
res "the default target's 02 extracts and writes no extract.from" $? "status $rc: $(ls -A "$W18d" | tr '\n' ' ') $(tailof "$TMPD/c18.g" 2)"
if [ "$HAVE_BASE" = 1 ]; then
  [ -d "$TMPD/w11-new/extract" ] && [ ! -e "$TMPD/w11-new/extract.from" ]; res "...nor did it in case 11" $? "$(ls -A "$TMPD/w11-new" 2>&1 | tr '\n' ' ')"
fi

# ================================================================ 19
section 19 "cloud/gcp/pilot_local.sh knows only the default target"
mkdir -p "$NEW/cloud/gcp"; cp "$ROOT/cloud/gcp/pilot_local.sh" "$NEW/cloud/gcp/pilot_local.sh"
SGC="$TMPD/stub-gcloud"; GLOG="$TMPD/gcloud.log"; mkdir -p "$SGC"; : > "$GLOG"
printf '#!/bin/sh\n# stand-in made by test_targets.sh: logs the call and fails\necho "gcloud $*" >> "%s"\nexit 1\n' "$GLOG" > "$SGC/gcloud"
chmod +x "$SGC/gcloud"
for sub in "launch pilot" ledger teardown; do
  W19="$TMPD/w19-$(printf '%s' "$sub" | tr ' ' -)"
  # shellcheck disable=SC2086
  cenv PATH="$SGC:$NPATH" RH_TARGET=fix-git RH_WORKDIR="$W19" GCP_PROJECT=made-up-project GCP_BUCKET=made-up-bucket \
    /bin/bash "$NEW/cloud/gcp/pilot_local.sh" $sub > "$TMPD/c19.out" 2>&1; rc=$?
  [ "$rc" = 1 ] && grep -q "the cloud scripts know only the default target, alpoge-rh, and RH_TARGET is 'fix-git'" "$TMPD/c19.out" \
    && [ ! -s "$GLOG" ] && [ ! -e "$W19" ]
  res "RH_TARGET=fix-git, '$sub': stops at once (status 1), gcloud is not called, nothing is written" $? "status $rc: $(tailof "$TMPD/c19.out" 2) gcloud: $(tailof "$GLOG" 2)"
done
W19d="$TMPD/w19default"
cenv PATH="$SGC:$NPATH" RH_WORKDIR="$W19d" GCP_PROJECT=made-up-project GCP_BUCKET=made-up-bucket \
  /bin/bash "$NEW/cloud/gcp/pilot_local.sh" ledger > "$TMPD/c19.d" 2>&1; rc=$?
[ "$rc" = 0 ] && grep -q 'estimated spend so far: \$0.00 of \$40 cap' "$TMPD/c19.d" && [ -f "$W19d/analysis/pilot_ledger.tsv" ] && [ ! -s "$GLOG" ]
res "the default target gets past that line: 'ledger' shows an empty ledger, without gcloud" $? "status $rc: $(tailof "$TMPD/c19.d" 2) gcloud: $(tailof "$GLOG" 2)"

# ================================================================ 20
section 20 "00_check_prereqs.sh --install-elan marks the working directory"
S20="$TMPD/stub20"; L20="$TMPD/c20.log"; mkdir -p "$S20"; : > "$L20"
{ printf '#!/bin/sh\n# stand-in made by test_targets.sh: logs the call and writes a made-up installer where -o says\nlog="%s"\n' "$L20"
  cat <<'EOF'
echo "curl $*" >> "$log"
out=""
while [ $# -gt 0 ]; do [ "$1" = -o ] && out=$2; shift; done
[ -n "$out" ] && printf '#!/bin/sh\necho made-up installer\n' > "$out"
exit 0
EOF
} > "$S20/curl"
printf '#!/bin/sh\n# stand-in made by test_targets.sh: logs the call\necho "sh $*" >> "%s"\nexit 0\n' "$L20" > "$S20/sh"
chmod +x "$S20"/*
P20="$S20:$PYBIN:/usr/bin:/bin:/usr/sbin:/sbin"
if cenv PATH="$P20" /bin/sh -c 'command -v elan || command -v lake' > /dev/null 2>&1; then
  skip "00 --install-elan: an elan or lake is on the narrower PATH"
else
  W20="$TMPD/w20"
  cenv PATH="$P20" RH_TARGET=fix-git RH_WORKDIR="$W20" /bin/bash "$NEW/scripts/00_check_prereqs.sh" --install-elan > "$TMPD/c20.a" 2>&1; rc=$?
  [ "$(cat "$W20/.rh-target" 2>/dev/null)" = fix-git ]; res "a made-up target: .rh-target names fix-git (00 ended with status $rc, elan being a stand-in)" $? "$(cat "$W20/.rh-target" 2>&1) $(tailof "$TMPD/c20.a" 2)"
  grep -q "^curl .* -o $W20/download/elan-init.sh " "$L20" && grep -q "^sh $W20/download/elan-init.sh -y --default-toolchain none\$" "$L20" \
    && [ -f "$W20/download/elan-init.sh" ]
  res "...and the installer was fetched into its download/ and run (stand-ins for curl and sh)" $? "$(tailof "$L20" 2)"
  W20d="$TMPD/w20default"
  cenv PATH="$P20" RH_WORKDIR="$W20d" /bin/bash "$NEW/scripts/00_check_prereqs.sh" --install-elan > "$TMPD/c20.b" 2>&1
  [ "$(cat "$W20d/.rh-target" 2>/dev/null)" = alpoge-rh ]; res "the default target: .rh-target names alpoge-rh" $? "$(cat "$W20d/.rh-target" 2>&1) $(tailof "$TMPD/c20.b" 2)"
  n20=$(wc -l < "$L20" | tr -d ' ')
  mkdir -p "$TMPD/w20unmarked"; echo old > "$TMPD/w20unmarked/a-file"
  cenv PATH="$P20" RH_TARGET=fix-git RH_WORKDIR="$TMPD/w20unmarked" /bin/bash "$NEW/scripts/00_check_prereqs.sh" --install-elan > "$TMPD/c20.c" 2>&1; rc=$?
  [ "$rc" != 0 ] && grep -q 'no .rh-target file' "$TMPD/c20.c" && [ "$(wc -l < "$L20" | tr -d ' ')" = "$n20" ] && [ ! -e "$TMPD/w20unmarked/download" ]
  res "a made-up target in a directory with files and no marker: stops before it downloads anything" $? "status $rc: $(tailof "$TMPD/c20.c" 2)"
fi

# ================================================================ 21
section 21 "06_progress.sh and a job line with the information mark (U+2139)"
mklog21() { # mklog21 <workdir>: a made-up build log and status file
  mkdir -p "$1/logs"
  { echo "$OK_MARK [1/4] Built A (1.0s)"
    echo "$WARN_MARK [2/4] Built B.C (2.0s)"; echo 'warning: B/C.lean:1:0: a made-up warning'
    echo "$INFO_MARK [3/4] Built B.D (0.5s)"; echo 'info: B/D.lean:1:0: 1'; } > "$1/logs/build-20261126-000000.log"
  printf 'START epoch=1700000000 threads=4\nEND epoch=1700003600 status=0\n' > "$1/logs/build-status.txt"
}
win21() { sed -n '2,/^== Compiler processes/p' "$1"; }   # what 06 prints that depends on the directory, not on the machine
W21d="$TMPD/w21default"; mklog21 "$W21d"
cenv RH_WORKDIR="$W21d" RH_MODULE_TOTAL=4 /bin/bash "$NEW/scripts/06_progress.sh" > "$TMPD/c21.new" 2>&1; rn=$?
[ "$rn" = 0 ] && grep -q '^  compiled in this run: 2 ' "$TMPD/c21.new" && grep -q -F "  last job line: $WARN_MARK [2/4] Built B.C" "$TMPD/c21.new" && ! grep -q '^target:' "$TMPD/c21.new"
res "the default target: the information mark is not counted (2 compiled; the last job line is the warning one)" $? "status $rn: $(grep 'compiled in this run\|last job' "$TMPD/c21.new" | tr '\n' ' ')"
if [ "$HAVE_BASE" = 1 ]; then
  cenv RH_WORKDIR="$W21d" RH_MODULE_TOTAL=4 /bin/bash "$MAIN/scripts/06_progress.sh" > "$TMPD/c21.base" 2>&1; rb=$?
  win21 "$TMPD/c21.base" > "$TMPD/c21.b"; win21 "$TMPD/c21.new" > "$TMPD/c21.n"
  [ "$rb" = "$rn" ] && [ -s "$TMPD/c21.b" ] && cmp -s "$TMPD/c21.b" "$TMPD/c21.n"
  res "...and its output, to the list of processes, is the base commit's line for line" $? "status $rb/$rn; $(diff "$TMPD/c21.b" "$TMPD/c21.n" | grep '^[<>]' | head -4 | tr '\n' ' ')"
else
  skip "06 against the base commit's: no base commit"
fi
W21f="$TMPD/w21fix"; mklog21 "$W21f"; echo fix-git > "$W21f/.rh-target"
cenv RH_TARGET=fix-git RH_WORKDIR="$W21f" RH_MODULE_TOTAL=4 /bin/bash "$NEW/scripts/06_progress.sh" > "$TMPD/c21.fix" 2>&1; rc=$?
[ "$rc" = 0 ] && grep -q '^target: fix-git$' "$TMPD/c21.fix" && grep -q '^  compiled in this run: 3 ' "$TMPD/c21.fix" \
  && grep -q -F "  last job line: $INFO_MARK [3/4] Built B.D" "$TMPD/c21.fix"
res "a made-up target: it is counted (3 compiled; the last job line is the information one), and the target is named" $? "status $rc: $(grep 'target:\|compiled in this run\|last job' "$TMPD/c21.fix" | tr '\n' ' ')"

# ================================================================ 22
section 22 "reproduce_findings.sh for the default target: S9 without its record, and S10 without a pattern"
nocfg
MLR="$FX/mathlib"; mkdir -p "$MLR"
gml() { cenv GIT_AUTHOR_DATE=1700000000 GIT_COMMITTER_DATE=1700000000 git -C "$MLR" -c user.name=test -c user.email=test@example.com \
          -c commit.gpgsign=false -c core.hooksPath=/dev/null "$@"; }
C_ML=""
{ gml init -q . && printf 'a made-up Mathlib\n' > "$MLR/README" && gml add -A && gml commit -q -m mathlib && gml tag v4.33.1; } > /dev/null 2>&1 \
  && C_ML=$(gml rev-parse HEAD)
# The official repository's address, answered by the one made here: git rewrites it before it connects to anything.
MLENV22="GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=url.file://$MLR.insteadOf GIT_CONFIG_VALUE_0=https://github.com/leanprover-community/mathlib4"
# shellcheck disable=SC2086
t=$(cenv $MLENV22 git ls-remote https://github.com/leanprover-community/mathlib4 refs/tags/v4.33.1 2>/dev/null | cut -f1)
if [ -z "$C_ML" ] || [ "$t" != "$C_ML" ] || case "$MLR" in *' '*) true ;; *) false ;; esac; then
  skip "reproduce_findings.sh for the default target: the made-up Mathlib repository cannot stand in for the official one here"
else
  ok "(the address of the official Mathlib repository is answered by the one made here: tag v4.33.1 is ${C_ML%"${C_ML#???????}"})"
  "$PY3" -I -B - "$TB/good.tar" "$TB/ml.tar.gz" "$MLREV" "$C_ML" <<'PY'
import gzip, io, sys, tarfile
src, out, old, new = sys.argv[1:5]
buf = io.BytesIO()
with tarfile.open(src) as tin, tarfile.open(fileobj=buf, mode="w", format=tarfile.GNU_FORMAT) as tout:
    for m in tin.getmembers():
        d = tin.extractfile(m).read().replace(old.encode(), new.encode())
        m.size = len(d)
        tout.addfile(m, io.BytesIO(d))
with open(out, "wb") as fh:
    fh.write(gzip.compress(buf.getvalue(), mtime=0))
PY
  MLSHA=$(sha "$TB/ml.tar.gz")
  # The made-up tarball's own records, made with the new scripts in a directory of their own.
  W22r="$TMPD/w22-record"; mkdir -p "$W22r/download"; cp "$TB/ml.tar.gz" "$W22r/download/lean.tar.gz"
  cenv RH_WORKDIR="$W22r" RH_TARBALL_SHA256="$MLSHA" TGT_RECORDS_DIR=records/c22-nothing \
    /bin/bash "$NEW/scripts/02_inspect_and_extract.sh" --write-expected "$TMPD/c22.rec" > "$TMPD/c22.rec.out" 2>&1 \
    && cenv RH_WORKDIR="$W22r" RH_TARBALL_SHA256="$MLSHA" TGT_RECORDS_DIR=records/c22-nothing \
         /bin/bash "$NEW/scripts/03_audit_source.sh" --show 0 --write-expected "$TMPD/c22.rec" >> "$TMPD/c22.rec.out" 2>&1 \
    && cenv "$PY3" -I -B -c "$PYRUN" "$NEW/analysis/import_graph.py" "$W22r/extract/lean/src" "$TMPD/c22.an" >> "$TMPD/c22.rec.out" 2>&1
  res "(the made-up tarball's expected.json and import graph summary were made)" $? "$(tailof "$TMPD/c22.rec.out" 3)"
  TREES22="$NEW"; [ "$HAVE_BASE" = 1 ] && TREES22="$NEW
$MAIN"
  printf '%s\n' "$TREES22" | while IFS= read -r t; do
    for f in expected.json import_graph_summary.json; do [ -f "$t/records/source/$f" ] && mv "$t/records/source/$f" "$t/records/source/$f.c22real"; done
    cp "$TMPD/c22.rec" "$t/records/source/expected.json"
  done
  rf22() { # rf22 <label> <scripts directory> [VAR=value ...]: reproduce_findings.sh in a new working directory with the tarball
    local l=$1 s=$2 w="$TMPD/w22-$1"; shift 2
    mkdir -p "$w/download"; cp "$TB/ml.tar.gz" "$w/download/lean.tar.gz"
    # shellcheck disable=SC2086
    cenv RH_WORKDIR="$w" RH_TARBALL_SHA256="$MLSHA" $MLENV22 "$@" /bin/bash "$s/reproduce_findings.sh" > "$TMPD/c22.$l" 2>&1
  }
  rf22 a-new "$NEW/scripts"; rn=$?
  t=$(rows16 "$TMPD/c22.a-new")
  [ ! -e "$NEW/records/source/import_graph_summary.json" ] && [ "$rn" = 1 ] && [ "$(row "$TMPD/c22.a-new" S9)" = FAIL ]
  res "records/source/import_graph_summary.json removed: S9 FAIL, status 1" $? "status $rn: $t"
  [ "$t" = "S1=PASS S2-S4=PASS S5=PASS S6-S8=PASS S9=FAIL S10=FAIL" ]
  res "...the other claims as they should be (S10 fails: no file of the made-up tarball matches the six tactics, not 77)" $? "$t"
  if [ "$HAVE_BASE" = 1 ]; then
    rf22 a-base "$MAIN/scripts"; rb=$?
    tb=$(rows16 "$TMPD/c22.a-base")
    [ "$rb" = "$rn" ] && [ "$tb" = "$t" ] && grep -q 'At least one claim did NOT reproduce' "$TMPD/c22.a-base" && grep -q 'At least one claim did NOT reproduce' "$TMPD/c22.a-new"
    res "...as with the base commit's script: the same results and the same status" $? "base: status $rb, $tb; new: status $rn, $t"
  else
    skip "reproduce_findings.sh against the base commit's: no base commit"
  fi
  cp "$TMPD/c22.an/import_graph_summary.json" "$NEW/records/source/import_graph_summary.json"
  rf22 b "$NEW/scripts" TGT_S10_COUNT=0; rc=$?
  t=$(rows16 "$TMPD/c22.b")
  [ "$rc" = 0 ] && [ "$t" = "S1=PASS S2-S4=PASS S5=PASS S6-S8=PASS S9=PASS S10=PASS" ] && grep -q '^All tier-S claims reproduced\.$' "$TMPD/c22.b"
  res "with the record (and TGT_S10_COUNT=0): every claim passes, 'All tier-S claims reproduced.', status 0" $? "status $rc: $t; $(tailof "$TMPD/c22.b" 1)"
  rf22 c "$NEW/scripts" TGT_S10_PATTERN=; rc=$?
  t=$(rows16 "$TMPD/c22.c")
  [ "$rc" = 0 ] && [ "$t" = "S1=PASS S2-S4=PASS S5=PASS S6-S8=PASS S9=PASS S10=n/a" ] && grep -q '^S10  .*TGT_S10_PATTERN is empty' "$TMPD/c22.c" \
    && ! grep -q 'All tier-S claims reproduced' "$TMPD/c22.c" && grep -q '5 of 6 tier-S claims reproduced\. 1 claim was not applicable .* None failed\.' "$TMPD/c22.c"
  res "TGT_S10_PATTERN= in the environment: an S10 row that is n/a, no 'All tier-S claims reproduced.', none failed, status 0" $? "status $rc: $t; $(tailof "$TMPD/c22.c" 1)"
  printf '%s\n' "$TREES22" | while IFS= read -r t; do
    rm -f "$t/records/source/expected.json" "$t/records/source/import_graph_summary.json"
    for f in expected.json import_graph_summary.json; do [ -f "$t/records/source/$f.c22real" ] && mv "$t/records/source/$f.c22real" "$t/records/source/$f"; done
  done
  [ -f "$NEW/records/source/expected.json" ] && [ -f "$NEW/records/source/import_graph_summary.json" ] && [ ! -e "$NEW/records/source/expected.json.c22real" ]
  res "(the repository's records were put back in the scratch copy)" $?
fi

# ================================================================ 23
section 23 "TGT_PROTECTED_NAMES: by default the last component of TGT_STATEMENT_CONST"
prof fix-prot TGT_STATEMENT_CONST=Foo.Bar
t=$(libvar TGT_PROTECTED_NAMES RH_TARGET=fix-prot); [ "$t" = Bar ]; res "TGT_STATEMENT_CONST=Foo.Bar and no TGT_PROTECTED_NAMES: the protected name is Bar" $? "'$t'"
prof fix-prot2 TGT_STATEMENT_CONST=Bar
t=$(libvar TGT_PROTECTED_NAMES RH_TARGET=fix-prot2); [ "$t" = Bar ]; res "...and Bar for TGT_STATEMENT_CONST=Bar" $? "'$t'"
prof fix-prot2 TGT_STATEMENT_CONST=Foo.Bar 'TGT_PROTECTED_NAMES="Baz Qux"'
t=$(libvar TGT_PROTECTED_NAMES RH_TARGET=fix-prot2); [ "$t" = "Baz Qux" ]; res "a profile's own TGT_PROTECTED_NAMES is kept" $? "'$t'"
W23="$TMPD/w23"; mkdir -p "$W23/extract/proj/src/B"; echo fix-prot > "$W23/.rh-target"
printf 'namespace Foo\n\ndef Bar : Prop := True\n\nend Foo\n' > "$W23/extract/proj/src/A.lean"
printf 'def c : Nat := 1\n' > "$W23/extract/proj/src/B/C.lean"
# The record 02 would have written (03 stops without it): any SHA-256 if none is pinned.
cenv RH_TARGET=fix-prot RH_WORKDIR="$W23" /bin/bash -c '. "$1/scripts/lib.sh" && source_record "${RH_TARBALL_SHA256:-$2}"' _ "$NEW" "$(printf '%064d' 0)" > "$W23/extract.from"
for tool in rg grep; do
  if [ "$tool" = rg ] && [ "$HAVE_RG" = 0 ]; then skip "03 with rg: rg is not installed"; continue; fi
  cenv RH_TARGET=fix-prot RH_WORKDIR="$W23" /bin/bash "$NEW/scripts/03_audit_source.sh" --tool "$tool" --show 0 > "$TMPD/c23.$tool" 2>&1; rc=$?
  [ "$rc" = 0 ] && grep -q '^Declarations named Bar: 1$' "$TMPD/c23.$tool" && grep -q '^  A.lean:3: def Bar : Prop := True$' "$TMPD/c23.$tool" \
    && grep -q '^local_def  *1  *1  *declarations named Bar$' "$TMPD/c23.$tool"
  res "03 ($tool) lists the 'def Bar' inside 'namespace Foo'" $? "status $rc: $(grep -A1 '^Declarations named' "$TMPD/c23.$tool" | tr '\n' ' ')"
done
cenv RH_TARGET=fix-prot RH_WORKDIR="$W23" TGT_PROTECTED_NAMES="RiemannHypothesis riemannZeta LFunction" \
  /bin/bash "$NEW/scripts/03_audit_source.sh" --show 0 > "$TMPD/c23.default" 2>&1; rc=$?
[ "$rc" = 0 ] && grep -q '^Declarations named RiemannHypothesis, riemannZeta, LFunction: 0$' "$TMPD/c23.default"
res "(with the default target's names given instead it is not listed: the name is what finds it)" $? "status $rc: $(grep '^Declarations named' "$TMPD/c23.default")"

# ================================================================ 24
section 24 "rhv_tools.py axioms-body accepts only ASCII Lean names"
CAFE=$(printf 'caf\303\251'); LAMX=$(printf '\316\273x')
for n in "$CAFE" "$LAMX"; do
  cenv "$PY3" -I -B "$TOOLS" axioms-body --body "$BODY" --statement-const "$n" > "$TMPD/c24.out" 2> "$TMPD/c24.err"; rc=$?
  [ "$rc" = 2 ] && [ ! -s "$TMPD/c24.out" ] && grep -q -F "not a plain Lean name" "$TMPD/c24.err" && grep -q -F "'$n'" "$TMPD/c24.err"
  res "--statement-const '$n': status 2, nothing on standard output, the name in the message" $? "status $rc: $(tailof "$TMPD/c24.err" 2)"
done
cenv "$PY3" -I -B "$TOOLS" axioms-body --body "$BODY" --statement-const GRH --report-consts "GRH Foo.$LAMX" > "$TMPD/c24.out" 2> "$TMPD/c24.err"; rc=$?
[ "$rc" = 2 ] && [ ! -s "$TMPD/c24.out" ] && grep -q -F "'Foo.$LAMX'" "$TMPD/c24.err"; res "--report-consts 'GRH Foo.<lambda>x': status 2, nothing printed" $? "status $rc: $(tailof "$TMPD/c24.err" 2)"
cenv "$PY3" -I -B "$TOOLS" axioms-body --body "$BODY" --statement-const "$CAFE" --report-consts "$CAFE $CAFE" > "$TMPD/c24.out" 2> "$TMPD/c24.err"; rc=$?
[ "$rc" = 2 ] && [ "$(grep -o 'caf' "$TMPD/c24.err" | wc -l | tr -d ' ')" = 1 ]; res "the same name as the constant and twice in the list: said once" $? "status $rc: $(tailof "$TMPD/c24.err" 2)"
nl24=$(cat "$STUBLOG.lean" 2>/dev/null | wc -l | tr -d ' '); nf24=$(ls "$W4"/logs/axioms-full-*.lean 2>/dev/null | wc -l | tr -d ' ')
refused "08 for a target whose statement constant is '$CAFE' stops" "could not write the check" RH_TARGET=fix-git "TGT_STATEMENT_CONST=$CAFE" /bin/bash "$NEW/scripts/08_check_axioms.sh"
[ "$(cat "$STUBLOG.lean" 2>/dev/null | wc -l | tr -d ' ')" = "$nl24" ] && [ "$(ls "$W4"/logs/axioms-full-*.lean 2>/dev/null | wc -l | tr -d ' ')" = "$nf24" ]
res "...before it runs lean, and leaves no .lean file" $?

# ================================================================ 25
section 25 "analysis/rhpaths.py: directories from the environment, without asking lib.sh"
W25="$TMPD/w25"; mkdir -p "$W25/proj/src/B"
printf 'import B.C\n\ntheorem m : True := trivial\n' > "$W25/proj/src/Main.lean"
printf 'def c : Nat := 1\n' > "$W25/proj/src/B/C.lean"; printf 'def o : Nat := 2\n' > "$W25/proj/src/Other.lean"
SB="$TMPD/stub-bash"; BLOG="$TMPD/bash.log"; mkdir -p "$SB"; : > "$BLOG"
printf '#!/bin/sh\n# stand-in made by test_targets.sh: logs the call and fails\necho "bash $*" >> "%s"\nexit 1\n' "$BLOG" > "$SB/bash"; chmod +x "$SB/bash"
[ "$(cat "$W4/.rh-target" 2>/dev/null)" = fix-git ]; res "(RH_WORKDIR for these runs is work-fix-git, marked for fix-git)" $?
cenv PATH="$SB:$CPATH" RH_WORKDIR="$W4" RH_PROJ="$W25/proj" RH_AN="$W25/an" RH_LOGS="$W25/logs" \
  "$PY3" -I -B -c "$PYRUN" "$NEW/analysis/import_graph.py" > "$TMPD/c25.a" 2>&1; rc=$?
[ "$rc" = 0 ] && [ ! -s "$BLOG" ] && jsonok "$W25/an/import_graph_summary.json" 'd["root"] == "Main" and d["modules_total"] == 3 and d["main_closure_modules"] == 2'
res "RH_TARGET unset, RH_PROJ, RH_AN and RH_LOGS given: import_graph.py works, root Main, and the stand-in bash is not called" $? "status $rc: $(tailof "$TMPD/c25.a" 2) bash: $(tailof "$BLOG" 1)"
cenv PATH="$SB:$CPATH" RH_TARGET=fix-git RH_WORKDIR="$TMPD/w6other" RH_PROJ="$W25/proj" RH_AN="$W25/an2" RH_LOGS="$W25/logs" \
  TGT_SRC_DIR=src TGT_ROOT_MODULE=B.C "$PY3" -I -B -c "$PYRUN" "$NEW/analysis/import_graph.py" > "$TMPD/c25.b" 2>&1; rc=$?
[ "$rc" = 0 ] && [ ! -s "$BLOG" ] && jsonok "$W25/an2/import_graph_summary.json" 'd["root"] == "B.C" and d["main_closure_modules"] == 1'
res "another target with TGT_SRC_DIR and TGT_ROOT_MODULE in the environment as well: not asked either, root B.C" $? "status $rc: $(tailof "$TMPD/c25.b" 2) bash: $(tailof "$BLOG" 1)"
cenv PATH="$SB:$CPATH" RH_WORKDIR="$W4" RH_AN="$W25/an3" "$PY3" -I -B -c "$PYRUN" "$NEW/analysis/import_graph.py" > "$TMPD/c25.s" 2>&1; rc=$?
[ "$rc" != 0 ] && [ -s "$BLOG" ] && grep -q "belongs to target 'fix-git'" "$TMPD/c25.s" && [ ! -e "$W25/an3" ]
res "(control: without RH_PROJ the stand-in bash is called, and the default layout it falls back to is refused too)" $? "status $rc: $(tailof "$TMPD/c25.s" 1) bash: $(tailof "$BLOG" 1)"
: > "$BLOG"
cenv RH_WORKDIR="$W4" RH_AN="$W25/an3" "$PY3" -I -B -c "$PYRUN" "$NEW/analysis/import_graph.py" > "$TMPD/c25.c" 2>&1; rc=$?
[ "$rc" != 0 ] && grep -q "belongs to target 'fix-git'" "$TMPD/c25.c" && [ ! -e "$W25/an3" ]
res "without RH_PROJ, lib.sh is asked, and it stops (the directory is another target's)" $? "status $rc: $(tailof "$TMPD/c25.c" 2)"

# ================================================================ 26
section 26 "archive names, .lake under the sources, and the record beside a git source's tar file"
T26="$TMPD/c26"; mkdir -p "$T26"
cenv "$PY3" -I -B - "$T26" <<'PY'
import io, os, sys, tarfile
out = sys.argv[1]
def tar(path, names):
    with tarfile.open(path, "w", format=tarfile.GNU_FORMAT, encoding="utf-8") as tf:
        for n in names:
            ti = tarfile.TarInfo(n); ti.mode = 0o644; ti.size = 2
            tf.addfile(ti, io.BytesIO(b"x\n"))
tar(os.path.join(out, "filedir.tar"), ["lean/lakefile.toml", "lean/src/A.lean", "lean/src/A.lean/B.lean"])
tar(os.path.join(out, "ntfs.tar"), ["lean/lakefile.toml", "lean/.git::$INDEX_ALLOCATION/config"])
tar(os.path.join(out, "lake1.tar"), ["lean/lakefile.toml", "lean/LAKE~1/x.olean"])
tar(os.path.join(out, "cn.tar"), ["lean/lakefile.toml", "lean/src/͸.lean"])
PY
for c in "filedir|a file where this entry needs a directory" "ntfs|a '.git' component" "lake1|a '.lake' component" "cn|a character unassigned in Unicode"; do
  f=${c%%|*}; want=${c#*|}
  refused "tar-inspect refuses $f.tar: $want" "$want" "$PY3" -I -B "$NEW/scripts/verify/rhv_tools.py" tar-inspect "$T26/$f.tar"
done
refused "tar-inspect refuses --src-dir 'src/' (only '.' is accepted as a directory that is not a plain path)" "--src-dir 'src/'" \
  "$PY3" -I -B "$NEW/scripts/verify/rhv_tools.py" tar-inspect "$TB/good.tar" --src-dir src/
cenv "$PY3" -I -B "$NEW/scripts/verify/rhv_tools.py" tar-inspect "$TB/good.tar" --src-dir . > "$T26/dot.out" 2>&1; rc=$?
[ "$rc" = 0 ] && grep -q '^Lean files under lean/: 3$' "$T26/dot.out"; res "...and accepts --src-dir . (the .lean files under the prefix: 3)" $? "status $rc: $(tailof "$T26/dot.out")"
P26="$T26/flat"; mkdir -p "$P26/.lake/packages/dep" "$P26/B"
printf 'import B.C\n' > "$P26/A.lean"; printf 'def c := 1\n' > "$P26/B/C.lean"; printf 'def d := 1\n' > "$P26/.lake/packages/dep/D.lean"
cenv "$PY3" -I -B "$NEW/scripts/verify/rhv_tools.py" import-graph --src "$P26" --out "$T26/ig.json" > "$T26/ig.out" 2>&1; rc=$?
[ "$rc" = 0 ] && jsonok "$T26/ig.json" 'd["modules"] == ["A", "B.C"] and d["imports"] == [[1], []]'
res "rhv_tools.py import-graph on a project directory: the .lake directory under it is not walked" $? "status $rc: $(tailof "$T26/ig.out")"
prof fix-rec; W26="$NEW/work-fix-rec"
cenv RH_TARGET=fix-rec /bin/bash "$NEW/scripts/01_fetch.sh" > "$T26/f.a" 2>&1; rc=$?
H26=""; [ -f "$W26/download/source.tar" ] && H26=$(sha "$W26/download/source.tar"); R26=$(record fix-rec "$H26")
[ "$rc" = 0 ] && [ -n "$H26" ] && [ "$(cat "$W26/download/source.tar.from" 2>/dev/null)" = "$R26" ]
res "01 writes source.tar.from beside the tar file" $? "status $rc: $(cat "$W26/download/source.tar.from" 2>&1)"
cenv RH_TARGET=fix-rec /bin/bash "$NEW/scripts/01_fetch.sh" --check-only > "$T26/f.b" 2>&1; rc=$?
[ "$rc" = 0 ] && grep -q '^record:   written from this address, commit, directory and prefix' "$T26/f.b"; res "01 --check-only: the record names this file and the profile's commit" $? "status $rc: $(tailof "$T26/f.b")"
mv "$W26/download/source.tar.from" "$T26/from.saved"
refused "02 does not use a tar file with no SHA-256 pinned and no record beside it" "is not known to be the archive" RH_TARGET=fix-rec /bin/bash "$NEW/scripts/02_inspect_and_extract.sh"
refused "...and 01 --check-only says so (status 1)" "DOES NOT NAME THIS FILE" RH_TARGET=fix-rec /bin/bash "$NEW/scripts/01_fetch.sh" --check-only
[ ! -e "$W26/extract" ]; res "...nothing was extracted" $?
mv "$T26/from.saved" "$W26/download/source.tar.from"
prof fix-rec TGT_GIT_SUBDIR=proj2 TGT_ARCHIVE_PREFIX=proj2/
refused "02 does not use it for a profile that now names another directory of the commit" "is not known to be the archive" RH_TARGET=fix-rec /bin/bash "$NEW/scripts/02_inspect_and_extract.sh"
prof fix-rec "TGT_TARBALL_SHA256=$(printf '%064d' 0)"
cenv RH_TARGET=fix-rec /bin/bash "$NEW/scripts/01_fetch.sh" > "$T26/f.c" 2>&1; rc=$?
[ "$rc" = 1 ] && [ "$(cat "$W26/download/source.tar.from" 2>/dev/null)" = "$R26" ]
res "pinned wrong: 01 stops (status 1), and its record still says what the file was written from" $? "status $rc: $(cat "$W26/download/source.tar.from" 2>&1)"
prof fix-rec "TGT_TARBALL_SHA256=$H26"
cenv RH_TARGET=fix-rec /bin/bash "$NEW/scripts/02_inspect_and_extract.sh" > "$T26/f.d" 2>&1; rc=$?
[ "$rc" = 0 ] && [ "$(cat "$W26/extract.from" 2>/dev/null)" = "$R26" ]; res "pinned right: 02 extracts and names the archive in extract.from" $? "status $rc: $(tailof "$T26/f.d" 2)"
cenv RH_TARGET=fix-rec /bin/bash -c '. "$1/scripts/lib.sh" && . "$1/scripts/common.sh" && require_extract_from && echo passed' _ "$NEW" > "$T26/f.e" 2>&1; rc=$?
[ "$rc" = 0 ] && grep -q '^passed$' "$T26/f.e"; res "require_extract_from passes for that tree" $? "status $rc: $(tailof "$T26/f.e")"
prof fix-rec "TGT_TARBALL_SHA256=$(printf '%064d' 1)"
refused "...and 09 stops once the profile pins another SHA-256" "is not recorded as extracted from the source that the profile" RH_TARGET=fix-rec /bin/bash "$NEW/scripts/09_kernel_replay.sh" --summary

# ================================================================ 27
section 27 "the end of an archive, long names, what tar wrote, and the commit and address a tar file is from"
T27="$TMPD/c27"; mkdir -p "$T27"
cenv "$PY3" -I -B - "$T27" <<'PY'
import gzip, os, sys, tarfile
out = sys.argv[1]
def member(name, data=b"x\n", mode=0o644, kind=tarfile.REGTYPE, link=""):
    ti = tarfile.TarInfo(name); ti.mode = mode; ti.type = kind; ti.linkname = link
    ti.size = len(data) if kind == tarfile.REGTYPE else 0
    b = ti.tobuf(tarfile.GNU_FORMAT, "utf-8", "surrogateescape")
    return b + (data + b"\0" * (-len(data) % 512) if kind == tarfile.REGTYPE else b"")
END = b"\0" * 1024
good = member("lean/lakefile.toml") + member("lean/src/A.lean")
# What a tar that carries on past a damaged place would extract: a file in .lake, an executable, a link out.
hidden = (member("lean/.lake/build/lib/lean/A.olean") + member("lean/src/run.sh", b"#!/bin/sh\n", 0o755)
          + member("lean/src/link", kind=tarfile.SYMTYPE, link="/etc"))
def write(name, data):
    with open(os.path.join(out, name), "wb") as fh:
        fh.write(data)
gz = lambda b: gzip.compress(b, mtime=0)
write("damaged.tar.gz", gz(good + b"\x01" * 512 + hidden + END))
write("damaged.tar", good + b"\x01" * 512 + hidden + END)
write("zeroblock.tar.gz", gz(good + b"\0" * 512 + hidden + END))
# Two gzip members. Without end blocks in the first, the two hold one archive; with them, the second comes after the end.
write("multi.tar.gz", gz(good) + gz(hidden + END))
write("multi_end.tar.gz", gz(good + END) + gz(hidden + END))
write("trailing.tar.gz", gz(good + END) + b"not gzip")
whole = gz(good + END)
write("truncated.tar.gz", whole[:len(whole) // 2])
write("zeros.tar.gz", whole + b"\0" * 4096)                 # zero bytes after the last member, which gzip allows
write("padded.tar", good + END + b"\0" * 9216)              # filled up to a whole record, as tar does
write("component.tar", member("lean/src/%s.lean" % ("x" * 300)) + END)
write("deep.tar.gz", gz(member("lean/src/" + "a/" * 40000 + "x.lean") + END))
write("dirs.tar", member("lean/", kind=tarfile.DIRTYPE) + member("lean/src/", kind=tarfile.DIRTYPE) + good + END)
PY
for c in "damaged.tar.gz|data after the end of the archive" "damaged.tar|data after the end of the archive" \
         "zeroblock.tar.gz|data after the end of the archive" "multi.tar.gz|not a regular file (symbolic link): lean/src/link" \
         "multi_end.tar.gz|data after the end of the archive" "trailing.tar.gz|cannot be read to its end" \
         "truncated.tar.gz|cannot be read to its end" "component.tar|a component of the name longer than 255 bytes" \
         "deep.tar.gz|a name longer than 1024 bytes"; do
  f=${c%%|*}; want=${c#*|}
  refused "tar-inspect refuses $f: $want" "$want" "$PY3" -I -B "$NEW/scripts/verify/rhv_tools.py" tar-inspect "$T27/$f"
done
if [ "$HAVE_BASE" = 1 ]; then
  cenv "$PY3" -I -B "$MAIN/scripts/verify/rhv_tools.py" tar-inspect "$T27/damaged.tar.gz" > "$T27/base.out" 2>&1; rc=$?
  [ "$rc" = 0 ] && grep -q '^tarball entries: *2$' "$T27/base.out"
  res "(the base commit's tar-inspect passed damaged.tar.gz, seeing 2 entries of 5: what this case guards against)" $? "status $rc: $(tailof "$T27/base.out")"
fi
for f in zeros.tar.gz padded.tar; do
  cenv "$PY3" -I -B "$NEW/scripts/verify/rhv_tools.py" tar-inspect "$T27/$f" > "$T27/$f.out" 2>&1; rc=$?
  [ "$rc" = 0 ]; res "tar-inspect accepts $f: only zero bytes follow the end" $? "status $rc: $(tailof "$T27/$f.out")"
done
cenv "$PY3" -I -B "$NEW/scripts/verify/rhv_tools.py" tar-inspect "$T27/dirs.tar" > "$T27/dirs.out" 2>&1; rc=$?
[ "$rc" = 1 ] && grep -q 'not a regular file (directory): lean/src$' "$T27/dirs.out" && ! grep -q 'needs a directory' "$T27/dirs.out"
res "tar-inspect on directory entries: refused as such, with no 'file where a directory is needed'" $? "status $rc: $(tailof "$T27/dirs.out" 4)"
C_LONG=$(branch long 100644 "proj/src/$(printf '%0300d' 0 | tr 0 x).lean" 'def x := 1')
refused "git-export refuses a component longer than 255 bytes" "a component of the name longer than 255 bytes" \
  "$PY3" -I -B "$NEW/scripts/verify/rhv_tools.py" git-export --git-dir "$REPO/.git" --commit "$C_LONG" --subdir proj --prefix proj/ --out "$T27/long.tar"
[ ! -e "$T27/long.tar" ]; res "...and writes nothing" $?

# --check-extracted: what is on disk against the listing
X27="$T27/x"; mkdir -p "$X27"; tar -xf "$TB/good.tar" -C "$X27"
ce() { cenv "$PY3" -I -B "$NEW/scripts/verify/rhv_tools.py" tar-inspect "$TB/good.tar" --quiet --check-extracted "$X27" "$@" > "$T27/ce.out" 2>&1; }
ce; rc=$?
[ "$rc" = 0 ] && grep -q '^extracted tree: 8 files under ' "$T27/ce.out"; res "--check-extracted on what tar wrote: status 0, 8 files" $? "status $rc: $(tailof "$T27/ce.out")"
# cex <description> <text> <command that changes the tree> <command that undoes it>
cex() {
  local rc
  eval "$3"; ce; rc=$?; eval "$4"
  [ "$rc" = 1 ] && grep -q -- "$2" "$T27/ce.out"; res "--check-extracted refuses $1" $? "status $rc: $(tailof "$T27/ce.out" 3)"
}
cex "a file that is not an entry" "a file that is not an entry of the archive: lean/src/Extra.lean" \
  'echo x > "$X27/lean/src/Extra.lean"' 'rm -f "$X27/lean/src/Extra.lean"'
cex "a file in .lake" "a file that is not an entry of the archive: lean/.lake/build/x.olean" \
  'mkdir -p "$X27/lean/.lake/build" && : > "$X27/lean/.lake/build/x.olean"' 'rm -rf "${X27:?}/lean/.lake"'
cex "a link to a file" "a symbolic link: lean/src/Link.lean" 'ln -s Main.lean "$X27/lean/src/Link.lean"' 'rm -f "$X27/lean/src/Link.lean"'
cex "a link to a directory" "a symbolic link: lean/etc" 'ln -s /etc "$X27/lean/etc"' 'rm -f "$X27/lean/etc"'
cex "an executable bit" "an executable bit (mode 755): lean/src/Main.lean" 'chmod 755 "$X27/lean/src/Main.lean"' 'chmod 644 "$X27/lean/src/Main.lean"'
cex "an entry that is missing" "an entry of the archive that is not on disk: lean/src/Main.lean" \
  'mv "$X27/lean/src/Main.lean" "$T27/Main.lean.aside"' 'mv "$T27/Main.lean.aside" "$X27/lean/src/Main.lean"'
cex "an empty directory" "a directory with no entry of the archive in it: lean/empty" 'mkdir "$X27/lean/empty"' 'rmdir "$X27/lean/empty"'
cex "a file with a second name" "a file with more than one name (a hard link): lean/README.md" \
  'ln "$X27/lean/README.md" "$T27/README.second"' 'rm -f "$T27/README.second"'
chmod 755 "$X27/lean/src/Main.lean"; ce --allow-exec; rc=$?; chmod 644 "$X27/lean/src/Main.lean"
[ "$rc" = 0 ]; res "...and accepts the executable bit with --allow-exec" $? "status $rc: $(tailof "$T27/ce.out")"

# 02 with a tar that writes one file the archive does not have (a stand-in for a tar that reads an archive otherwise)
STUB27="$TMPD/stub27"; mkdir -p "$STUB27"; REALTAR=$(command -v tar)
cat > "$STUB27/tar" <<EOF
#!/bin/sh
# stand-in made by test_targets.sh: extracts with the real tar, then leaves a file in .lake that the archive does not have
"$REALTAR" "\$@" || exit
for a; do last=\$a; done
mkdir -p "\$last/proj/.lake/build" && echo planted > "\$last/proj/.lake/build/planted.olean"
EOF
chmod +x "$STUB27/tar"
prof fix-plant; W27="$NEW/work-fix-plant"
cenv RH_TARGET=fix-plant /bin/bash "$NEW/scripts/01_fetch.sh" > "$T27/p.a" 2>&1; rc=$?
[ "$rc" = 0 ]; res "fix-plant: 01 writes the tar file" $? "status $rc: $(tailof "$T27/p.a")"
refused "02 with a tar that writes more than the listing showed: stops" "what tar extracted is not what the listing showed" \
  PATH="$STUB27:$CPATH" RH_TARGET=fix-plant /bin/bash "$NEW/scripts/02_inspect_and_extract.sh"
grep -q 'a file that is not an entry of the archive: proj/.lake/build/planted.olean' "$TMPD/refused.out" && [ ! -e "$W27/extract" ] \
  && [ ! -e "$W27/extract.from" ] && [ -f "$W27/extract.partial/proj/.lake/build/planted.olean" ]
res "...names the file; no extract and no extract.from; the tree is left in extract.partial" $? "$(tailof "$TMPD/refused.out" 3)"
cenv RH_TARGET=fix-plant /bin/bash "$NEW/scripts/02_inspect_and_extract.sh" > "$T27/p.b" 2>&1; rc=$?
[ "$rc" = 0 ] && grep -q 'extracted tree: [0-9]* files under .*extract.partial' "$T27/p.b" && [ -f "$W27/extract.from" ] \
  && [ ! -e "$W27/extract/proj/.lake" ]
res "02 with the real tar: what it wrote is the listing's, and the tree is put in place" $? "status $rc: $(tailof "$T27/p.b" 3)"

# A pin left over from an earlier commit, and a clone made from another address
C_NEXT=$(branch next 100644 proj/src/B/D.lean 'def d : Nat := 2')
prof fix-pin; W27p="$NEW/work-fix-pin"
cenv RH_TARGET=fix-pin /bin/bash "$NEW/scripts/01_fetch.sh" > "$T27/s.a" 2>&1
H27=""; [ -f "$W27p/download/source.tar" ] && H27=$(sha "$W27p/download/source.tar")
prof fix-pin "TGT_TARBALL_SHA256=$H27"
cenv RH_TARGET=fix-pin /bin/bash "$NEW/scripts/02_inspect_and_extract.sh" > "$T27/s.b" 2>&1; rc=$?
[ "$rc" = 0 ] && [ -n "$H27" ] && [ -d "$W27p/extract" ]; res "fix-pin: pinned, fetched and extracted" $? "status $rc: $(tailof "$T27/s.b")"
mv "$W27p/extract" "$T27/extract.first"
prof fix-pin "TGT_TARBALL_SHA256=$H27" "TGT_GIT_COMMIT=$C_NEXT"
refused "a pin left over from the first commit: 01 --check-only finds that the record names that commit (status 1)" \
  "DOES NOT NAME THIS FILE" RH_TARGET=fix-pin /bin/bash "$NEW/scripts/01_fetch.sh" --check-only
grep -q '^archive:  .*  ok$' "$TMPD/refused.out"; res "...although the file's SHA-256 is the pinned one" $? "$(tailof "$TMPD/refused.out" 4)"
refused "...and 02 does not extract the first commit's file as the second's" "is not known to be the archive" \
  RH_TARGET=fix-pin /bin/bash "$NEW/scripts/02_inspect_and_extract.sh"
[ ! -e "$W27p/extract" ]; res "...nothing was extracted" $?
cenv RH_TARGET=fix-pin /bin/bash "$NEW/scripts/01_fetch.sh" > "$T27/s.c" 2>&1; rc=$?
[ "$rc" = 1 ] && grep -q "commit $C_NEXT " "$W27p/download/source.tar.from"
res "01 writes the second commit's file: status 1 on the pin, and the record names the second commit" $? "status $rc: $(cat "$W27p/download/source.tar.from" 2>&1)"
refused "...and 02 stops on the pin" "tarball SHA-256 is" RH_TARGET=fix-pin /bin/bash "$NEW/scripts/02_inspect_and_extract.sh"
prof fix-pin "TGT_TARBALL_SHA256=$H27" "TGT_GIT_URL=$REPO/."
refused "a clone made from another address than the profile's: 01 stops" "was made from '$REPO'" \
  RH_TARGET=fix-pin /bin/bash "$NEW/scripts/01_fetch.sh"
refused "...and 01 --check-only says so (status 1)" "NOT MADE FROM THE PROFILE'S ADDRESS" RH_TARGET=fix-pin /bin/bash "$NEW/scripts/01_fetch.sh" --check-only
cenv RH_TARGET=fix-pin /bin/bash "$NEW/scripts/01_fetch.sh" --redownload > "$T27/s.d" 2>&1; rc=$?
[ "$rc" = 0 ] && [ "$(cenv git --git-dir="$W27p/download/repo.git" config --get rhv.sourceurl)" = "$REPO/." ] \
  && [ "$(cat "$W27p/download/source.tar.from" 2>/dev/null)" = "$(record fix-pin "$H27")" ]
res "...01 --redownload clones from the profile's address, which the clone and the record then name" $? "status $rc: $(tailof "$T27/s.d")"

# ================================================================ 28
section 28 "nothing reached for the network or the toolchain in cases 14 to 27"
[ ! -s "$STUBLOG" ] && [ ! -s "$GLOG" ]; res "no stand-in of curl, wget, lake, elan, leanchecker or gcloud was called" $? "$(tailof "$STUBLOG" 3) $(tailof "$GLOG" 3)"

echo "$N checks, $FAILS failed, $SKIPS skipped ($(( $(date +%s) - START )) s)"
[ "$FAILS" = 0 ]
