#!/bin/bash
# Tests for cloud/gcp/target_guest.sh, the startup script of the cloud modes `target` and `target-rehearsal`: what it
# does with each step's outcome, what it uploads, and how it ends.
#
#   bash scripts/dev/test_target_guest.sh          (bash 3.2 on macOS, or bash 5; python3 and ps needed)
#
# No network, no cloud and no Lean. The guest is run as a COPY in a scratch directory, in a made-up world per case:
#   - The copy differs from the script by the substitutions listed below and by nothing else: the paths it writes on
#     the machine are moved under the case's directory, and its waits are shortened so that one minute of the guest
#     is one second here. Each substitution must match exactly once and no other path of the machine may be left,
#     or the test stops: a later change of the guest cannot escape it unseen.
#   - Everything the guest calls that must not be real is a stand-in on a private PATH: that PATH holds the case's
#     stand-ins directory and /usr/bin:/bin:/usr/sbin:/sbin, nothing else. lean, lake, elan, leanchecker and git are
#     stand-ins too, so nothing real can be reached; this is checked before any guest copy is run.
#     curl plays the metadata server and a bucket that is a directory; runuser runs the made-up user's commands as
#     whoever runs the test, in a made-up home; pkill ends only what that made-up user runs in the same case;
#     python3 is the real one, called by its full path.
#   - The repository's numbered steps are stubs in a scratch archive. They write the files the real steps write and
#     do what the case's control files (ctl/) say: exit status, how long to sleep, how the build ends.
# What this cannot show: anything that needs the real machine (the real curl reading -K -, runuser with PAM,
# iptables, the name resolver, GNU tar and time, apt), and anything the real steps do.
# Prints ok or FAIL per check; exits 1 if any check failed. TEST_SCRATCH=<dir> (new or empty) keeps the scratch
# files there; otherwise they are made under TMPDIR and removed. The cases run side by side: on the 10-core Mac
# this was written on, busy with other work at the time, the whole test took between 55 and 110 seconds.
PY3=$(command -v python3) || { echo "python3 is needed"; exit 2; }
case "$PY3" in /*) ;; *) echo "python3 is needed (found only '$PY3')"; exit 2 ;; esac
REPO=${TEST_REPO:-"$(cd "$(dirname "$0")/../.." && pwd)"}
# ---- the private PATH, before anything else ---------------------------------------------------------------------
# The test's own commands come from the system's directories; python3 is called by the full path found above.
SYSPATH=/usr/bin:/bin:/usr/sbin:/sbin
PATH=$SYSPATH; export PATH
WORK=${TEST_SCRATCH:-$(mktemp -d "${TMPDIR:-/tmp}/target_guest_test.XXXXXX")}
mkdir -p "$WORK" || exit 2
WORK=$(cd "$WORK" && pwd -P) || exit 2
# The guest puts its directories on command lines that a shell reads, so the scratch path must be plain.
case "$WORK" in *[!A-Za-z0-9_./+-]*) echo "the scratch directory's path may hold only letters, digits and _ . / + - : $WORK"; exit 2 ;; esac
T="$WORK/template"; TW="$T/world"; ST="$TW/stubs"; C="$WORK/c"
[ ! -e "$T" ] && [ ! -e "$C" ] || { echo "TEST_SCRATCH must be a new or empty directory; $WORK holds an earlier run"; exit 2; }
mkdir -p "$ST" "$C" "$TW/md" "$TW/mdx" "$TW/ctl" "$TW/etc" "$TW/root_home" "$TW/bucket/inputs/target" || exit 2
GUEST="$REPO/cloud/gcp/target_guest.sh"
[ -f "$GUEST" ] || { echo "no cloud/gcp/target_guest.sh in $REPO"; exit 2; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf 'ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL  %s: %s\n' "$1" "$2"; }
res() { if [ "$2" = 0 ]; then ok "$1"; else bad "$1" "${3:-}"; fi; }   # res <text> <status> [detail]
sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }
# The made-up names every case uses. The stand-in curl knows the last two: they must never be on a command line.
COMMIT=0123456789abcdef0123456789abcdef01234567
BUCKET=standin-bucket-6c2a
TOKEN=made-up-token-0f1e2d3c
# What must resolve to a stand-in in every case (checked before a guest copy is started), and the stand-ins that
# only make up for what macOS lacks or what needs root.
MUST_BE_STANDINS="lean lake elan leanchecker git curl runuser pkill pgrep apt-get iptables useradd mkfs.xfs mount sysctl timeout"
ALSO_STANDINS="python3 chown getent resolvectl tee nproc lscpu free du df"

# ---- the stand-ins ----------------------------------------------------------------------------------------------
# Each finds its case's directory from its own path (<case>/stubs/<name>, so H=${0%/*/*}), never from the
# environment: steps 08 and 09 are started with an emptied environment. They start as few processes as they can:
# the guest uploads some 150 objects in a run, and each upload is two calls of curl and two of python3.
put() { cat > "$ST/$1" && chmod 755 "$ST/$1"; }
# The two one-line programs the guest runs for every upload, as they stand in it (see the stand-in python3).
P_TOK='import sys,json; print(json.load(sys.stdin)["access_token"])'
P_ENC='import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1],safe=""))'
sed -e "s|@PY3@|$PY3|" -e "s|@P_TOK@|$P_TOK|" -e "s|@P_ENC@|$P_ENC|" <<'EOF' | put python3
#!/bin/bash
# python3: the one the test found, by its full path; isolated, without site-packages, writing no bytecode.
# The guest runs two one-line programs for every object it uploads, some 150 times a run: one takes the token out
# of the metadata server's answer, the other percent-encodes the object's name. Each gives the same answer for the
# same input, so this remembers Python's answer per input (in <case>/memo) and starts Python only for an input it
# has not seen. Only these two exact program texts are remembered: a changed version of either goes to Python
# every time, as everything else does.
PY="@PY3@"; H=${0%/*/*}
if [ "$1" = -c ] && [ $# = 3 ] && [ "$2" = '@P_ENC@' ]; then
  case "$3" in ""|/*|*..*|*[!A-Za-z0-9_./-]*) ;; *)
    m="$H/memo/enc/$3.memo"
    if [ -f "$m" ]; then IFS= read -r -d '' v < "$m"; printf '%s' "$v"; exit 0; fi
    v=$("$PY" -I -S -B "$@") || exit $?
    mkdir -p "${m%/*}" && printf '%s\n' "$v" > "$m.$$" && mv -f "$m.$$" "$m"
    printf '%s\n' "$v"; exit 0 ;;
  esac
fi
if [ "$1" = -c ] && [ $# = 2 ] && [ "$2" = '@P_TOK@' ]; then
  j=""; a=""; IFS= read -r -d '' j; [ ! -f "$H/memo/tok.in" ] || IFS= read -r -d '' a < "$H/memo/tok.in"
  if [ -n "$j" ] && [ "$j" = "$a" ] && [ -f "$H/memo/tok.out" ]; then IFS= read -r -d '' v < "$H/memo/tok.out"; printf '%s' "$v"; exit 0; fi
  v=$(printf '%s' "$j" | "$PY" -I -S -B "$@") || exit $?
  mkdir -p "$H/memo" && printf '%s\n' "$v" > "$H/memo/tok.out.$$" && mv -f "$H/memo/tok.out.$$" "$H/memo/tok.out" \
    && printf '%s' "$j" > "$H/memo/tok.in.$$" && mv -f "$H/memo/tok.in.$$" "$H/memo/tok.in"
  printf '%s\n' "$v"; exit 0
fi
exec "$PY" -I -S -B "$@"
EOF
for c in lean lake elan leanchecker git; do put "$c" <<'EOF'
#!/bin/bash
# Stand-in: the real program is never run by this test. Says so, and records the call.
H=${0%/*/*}
echo "${0##*/} $*" >> "$H/lean_calls.log"
echo "stand-in ${0##*/} (scripts/dev/test_target_guest.sh): $*"
EOF
done
for c in apt-get sysctl mkfs.xfs mount chown iptables; do put "$c" <<'EOF'
#!/bin/bash
# Stand-in for a command that needs root on the real machine: records its arguments and succeeds. The rules given
# to iptables are also kept in iptables.log, where the stand-in curl looks them up. With ctl/<name>.hangs it does
# not come back.
H=${0%/*/*}; me=${0##*/}
echo "$me $*" >> "$H/root_cmds.log"
[ "$me" != iptables ] || echo "$*" >> "$H/iptables.log"
[ ! -e "$H/ctl/$me.hangs" ] || sleep 600
exit 0
EOF
done
put useradd <<'EOF'
#!/bin/bash
# useradd -m -s /bin/bash rhv: makes the made-up user's home. Its login file sets one variable, so that a step can
# tell whether it was started through a login shell.
H=${0%/*/*}
echo "useradd $*" >> "$H/root_cmds.log"
[ "$*" = "-m -s /bin/bash rhv" ] || { echo "useradd $*" >> "$H/standin_errors.log"; exit 2; }
[ ! -e "$H/home/rhv" ] || exit 9
mkdir -p "$H/home/rhv" && printf 'export RHV_LOGIN_FILE_WAS_READ=1\n' > "$H/home/rhv/.profile"
EOF
put getent <<'EOF'
#!/bin/bash
# getent passwd rhv: the made-up user's line. getent hosts <the bucket's host>: answers unless ctl/getent_hosts_fails.
H=${0%/*/*}
case "$*" in
  "passwd rhv") [ -d "$H/home/rhv" ] || exit 2; echo "rhv:x:1001:1001::$H/home/rhv:/bin/bash" ;;
  "hosts storage.googleapis.com") [ ! -e "$H/ctl/getent_hosts_fails" ] || exit 2; echo "192.0.2.1       storage.googleapis.com" ;;
  *) echo "getent $*" >> "$H/standin_errors.log"; exit 2 ;;
esac
EOF
put resolvectl <<'EOF'
#!/bin/bash
# resolvectl query <the bucket's host>: answers only if ctl/resolvectl_answers is there.
H=${0%/*/*}
[ "$*" = "query storage.googleapis.com" ] || { echo "resolvectl $*" >> "$H/standin_errors.log"; exit 2; }
[ -e "$H/ctl/resolvectl_answers" ]
EOF
put runuser <<'EOF'
#!/bin/bash
# Stand-in for runuser: runs the command as whoever runs the test, with the made-up home. It stays the parent of
# what it starts, so that the stand-in pkill can find "the user's processes" beneath it. Each call is written to
# runuser.log: which of the guest's two ways of starting a step was used, and for the clean way the names of the
# variables it was given, the PATH it was given and the command.
#   runuser -l rhv -c <string>      a login shell: a fresh environment, the user's login file read first
#   runuser -u rhv -- <command...>  the command as given. When it is `env -i NAME=value... command`, the PATH given
#                                   is recorded as it is and then narrowed for the run: the stand-ins first, then
#                                   only the system's directories and what lies in the case's own directory, so
#                                   that /usr/local or anything else of this machine is never searched.
H=${0%/*/*}
UHOME="$H/home/rhv"
if [ "$1" = -l ] && [ "$2" = rhv ] && [ "$3" = -c ] && [ $# = 4 ]; then
  printf 'login\t%s\n' "$4" >> "$H/runuser.log"
  env -i HOME="$UHOME" USER=rhv LOGNAME=rhv SHELL=/bin/bash AS_RHV=1 PATH="$H/stubs:/usr/bin:/bin:/usr/sbin:/sbin" \
    /bin/bash -c '[ ! -f "$HOME/.profile" ] || . "$HOME/.profile"; '"$4"
  exit $?
fi
if [ "$1" = -u ] && [ "$2" = rhv ] && [ "$3" = -- ] && [ $# -ge 4 ]; then
  shift 3
  if [ "$1" = env ] && [ "$2" = -i ]; then
    shift 2; names=""; given=""; keep=()
    while [ $# -gt 0 ]; do
      case "$1" in
        PATH=*) given=${1#PATH=}; names="$names PATH" ;;
        [A-Za-z_]*=*) names="$names ${1%%=*}"; keep[${#keep[@]}]=$1 ;;
        *) break ;;
      esac
      shift
    done
    names=$(printf '%s\n' $names | LC_ALL=C sort | tr '\n' ' ')
    printf 'clean\t%s\t%s\t%s\n' "${names% }" "$given" "$*" >> "$H/runuser.log"
    path="$H/stubs"
    IFS=: read -r -a dirs <<< "$given"
    for d in "${dirs[@]}"; do case "$d" in /usr/bin|/bin|/usr/sbin|/sbin|"$H"/*) path="$path:$d" ;; esac; done
    env -i "${keep[@]}" PATH="$path" "$@"
    exit $?
  fi
  printf 'plain\t%s\n' "$*" >> "$H/runuser.log"
  AS_RHV=1 HOME="$UHOME" "$@"
  exit $?
fi
echo "runuser $*" >> "$H/standin_errors.log"; exit 98
EOF
sed -e "s/@TOKEN@/$TOKEN/" -e "s/@BUCKET@/$BUCKET/" <<'EOF' | put curl
#!/bin/bash
# Stand-in for curl: the metadata server (the attributes are the files in md/, the token is made up) and a bucket
# that is the directory bucket/. For the bucket, the token and the URL are to come on standard input (-K -), as the
# two lines
#   header = "Authorization: Bearer <token>"
#   url = "<url>"
# and a request with no token, or a wrong one, is refused. A call with "Bearer", the token or the bucket's name in
# an argument is answered all the same, but it is written to curl_argv_violations.log and the test fails on that
# file: every user of a machine can read every process's command line.
# As the made-up user (AS_RHV=1, set by the stand-in runuser) nothing is served: the request fails if the stand-in
# iptables was given the rule that rejects it, and connects otherwise.
H=${0%/*/*}
TOKEN=@TOKEN@; BUCKET=@BUCKET@; all="$*"
for a in "$@"; do
  case "$a" in *Bearer*|*"$TOKEN"*|*"$BUCKET"*) printf '%s\n' "$all" >> "$H/curl_argv_violations.log"; break ;; esac
done
unknown() { echo "curl $all ($1)" >> "$H/standin_errors.log"; exit 2; }
url=""; out=""; up=""; cfg=""; tok=""; bearer='Authorization: Bearer '
while [ $# -gt 0 ]; do
  case "$1" in
    -s|-f|-sf) ;;
    --connect-timeout|--max-time|--speed-limit|--speed-time|--retry|--retry-delay|-m|-X) shift ;;
    -H) case "$2" in "$bearer"*) tok=${2#"$bearer"} ;; esac; shift ;;
    -o) out=$2; shift ;;
    -T) up=$2; shift ;;
    -K) cfg=$2; shift ;;
    http://*|https://*) url=$1 ;;
    *) unknown "argument $1" ;;
  esac
  shift
done
if [ -n "$cfg" ]; then
  [ "$cfg" = - ] && [ -z "$url" ] || unknown "-K is known only as '-K -', with the URL in it"
  p1='header = "Authorization: Bearer '; p2='url = "'; l1=""; l2=""; l3=""
  IFS= read -r l1; IFS= read -r l2; IFS= read -r l3
  case "$l1" in "$p1"*\") ;; *) unknown "first line on standard input: $l1" ;; esac
  case "$l2" in "$p2"*\") ;; *) unknown "second line on standard input: $l2" ;; esac
  [ -z "$l3" ] || unknown "a third line on standard input"
  tok=${l1#"$p1"}; tok=${tok%\"}; url=${l2#"$p2"}; url=${url%\"}
  echo "$url" >> "$H/curl_config_calls.log"
fi
if [ -n "${AS_RHV:-}" ]; then
  case "$url" in
    *//169.254.169.254/*|*//metadata.google.internal/*) rule='--uid-owner rhv -d 169.254.169.254 -j REJECT' ;;
    *) rule='--uid-owner rhv ! -o lo -j REJECT' ;;
  esac
  if grep -q -F -e "$rule" "$H/iptables.log" 2>/dev/null; then exit 7; fi
  exit 0
fi
# emit <file>: the body, to the file -o names or else to standard output (text, written by the shell itself)
emit() { local v=""; case "$out" in "") IFS= read -r -d '' v < "$1"; printf '%s' "$v" ;; /dev/null) ;; *) cp "$1" "$out" ;; esac; }
MD=http://metadata.google.internal/computeMetadata/v1/instance
GET="https://storage.googleapis.com/storage/v1/b/$BUCKET/o/"; GETEND='?alt=media'
PUT="https://storage.googleapis.com/upload/storage/v1/b/$BUCKET/o?uploadType=media&name="
case "$url" in
  "$MD/attributes/startup-script") emit "$H/guest.sh" ;;
  "$MD/attributes/"*) k=${url#"$MD/attributes/"}; case "$k" in ""|*/*|.*) exit 22 ;; esac; [ -f "$H/md/$k" ] || exit 22; emit "$H/md/$k" ;;
  "$MD/machine-type") emit "$H/mdx/machine-type" ;;
  "$MD/service-accounts/default/token") emit "$H/mdx/token" ;;
  "$GET"*"$GETEND")
    [ "$tok" = "$TOKEN" ] || exit 22
    n=${url#"$GET"}; n=${n%"$GETEND"}; printf -v n '%b' "${n//%/\\x}"    # %2F -> /
    case "$n" in ""|/*|*..*) exit 22 ;; esac
    [ -f "$H/bucket/$n" ] || exit 22
    emit "$H/bucket/$n" ;;
  "$PUT"*)
    [ "$tok" = "$TOKEN" ] && [ -f "$up" ] || exit 22
    n=${url#"$PUT"}; printf -v n '%b' "${n//%/\\x}"
    case "$n" in ""|/*|*..*) exit 22 ;; esac
    # beside the object and then moved in, so that nobody reads half of one
    d="$H/bucket/$n"; [ -d "${d%/*}" ] || mkdir -p "${d%/*}" || exit 23
    cp "$up" "$d.part.$$" && mv -f "$d.part.$$" "$d" || exit 23
    echo "$n" >> "$H/uploads.log" ;;
  *) unknown "URL $url" ;;
esac
exit 0
EOF
put pkill <<'EOF'
#!/bin/bash
# Stand-in for `pkill -KILL -u rhv`: ends what the made-up user runs in THIS case and nothing else. That is
# everything beneath a live stand-in runuser of this case, and the stub build's runner with everything beneath it.
# Both are recognised by this case's own directory in their command line, never by a remembered process number.
# The two marks reach awk through its environment, so that awk's own command line does not hold them.
H=${0%/*/*}
[ "$*" = "-KILL -u rhv" ] || { echo "pkill $*" >> "$H/standin_errors.log"; exit 2; }
pids=$(ps -A -ww -o pid=,ppid=,command= | RU="$H/stubs/runuser" BR="$H/mnt_work/rhv/scripts/05_build.sh __run" awk '
  { par[$1] = $2
    if (index($0, ENVIRON["BR"])) die[$1] = 1; else if (index($0, ENVIRON["RU"])) ru[$1] = 1 }
  END { do { more = 0
             for (p in par) if (!(p in die) && ((par[p] in die) || (par[p] in ru))) { die[p] = 1; more = 1 }
        } while (more)
        for (p in die) print p }')
n=0; for p in $pids; do kill -KILL "$p" 2>/dev/null && n=$((n + 1)); done
echo "$n" >> "$H/pkill.log"
[ "$n" -gt 0 ]
EOF
put pgrep <<'EOF'
#!/bin/bash
# Stand-in for root's own look for the build, `pgrep -u rhv -x lake`: the stub build's runner plays lake. It is
# found by this case's directory in its command line. ctl/pgrep_sees_nothing makes the look find nothing.
H=${0%/*/*}
echo "$*" >> "$H/pgrep.log"
[ "$*" = "-u rhv -x lake" ] || { echo "pgrep $*" >> "$H/standin_errors.log"; exit 2; }
[ ! -e "$H/ctl/pgrep_sees_nothing" ] || exit 1
ps -A -ww -o command= | BR="$H/mnt_work/rhv/scripts/05_build.sh __run" awk 'index($0, ENVIRON["BR"]) { found = 1 } END { exit !found }'
EOF
put gtime <<'EOF'
#!/bin/bash
# Stand-in for GNU time, which the guest names by its full path (/usr/bin/time; the copy names this file):
# `time -v -o FILE command...` runs the command, writes a peak-memory line to FILE, exits with the command's status.
H=${0%/*/*}
[ "$1" = -v ] && [ "$2" = -o ] && [ $# -ge 4 ] || { echo "time $*" >> "$H/standin_errors.log"; exit 2; }
f=$3; shift 3
"$@"; rc=$?
printf '\tMaximum resident set size (kbytes): 4321\n' > "$f"
exit "$rc"
EOF
printf '#!/bin/bash\n# timeout: see timeout.py beside this file.\nexec "%s" -I -S -B "$0.py" "$@"\n' "$PY3" | put timeout
put timeout.py <<'EOF'
# Stand-in for timeout (older macOS has none): timeout [-k SECONDS] SECONDS COMMAND [ARGUMENT...]
# Runs the command. If it is still running after SECONDS, TERM is sent to it and to everything beneath it and the
# status is 124 (137 if KILL was needed, -k SECONDS later); otherwise the status is the command's own.
# It makes no process group of its own, unlike GNU timeout: the test ends a case through its one process group.
# Every call is written to timeout.log.
import os, signal, subprocess, sys
here = os.path.dirname(os.path.dirname(os.path.abspath(sys.argv[0])))
a = sys.argv[1:]
with open(os.path.join(here, "timeout.log"), "a") as f:
    f.write(" ".join(a) + "\n")
kill_after = None
try:
    if a[0] == "-k":
        kill_after, a = float(a[1]), a[2:]
    limit, cmd = float(a[0]), a[1:]
    if not cmd:
        raise ValueError("no command")
except (IndexError, ValueError):
    with open(os.path.join(here, "standin_errors.log"), "a") as f:
        f.write("timeout " + " ".join(sys.argv[1:]) + "\n")
    sys.exit(125)
def beneath(top):
    out = subprocess.run(["ps", "-A", "-o", "pid=,ppid="], stdout=subprocess.PIPE, universal_newlines=True).stdout
    kids = {}
    for line in out.split("\n"):
        f = line.split()
        if len(f) == 2 and f[0].isdigit() and f[1].isdigit():
            kids.setdefault(int(f[1]), []).append(int(f[0]))
    found, todo = [], [top]
    while todo:
        x = todo.pop()
        found.append(x)
        todo.extend(kids.get(x, []))
    return found
def send(sig):
    for x in beneath(p.pid):
        try:
            os.kill(x, sig)
        except OSError:
            pass
try:
    p = subprocess.Popen(cmd)
except OSError:
    sys.exit(127)
try:
    rc = p.wait(timeout=limit)
    sys.exit(rc if rc >= 0 else 128 - rc)
except subprocess.TimeoutExpired:
    pass
send(signal.SIGTERM)
try:
    p.wait(timeout=kill_after)
    sys.exit(124)
except subprocess.TimeoutExpired:
    send(signal.SIGKILL)
    p.wait()
    sys.exit(137)
EOF
put tee <<'EOF'
#!/bin/bash
# tee -p is GNU's; the tee of macOS has no -p. Nothing tested here depends on it.
[ "$1" != -p ] || shift
for t in /usr/bin/tee /bin/tee; do [ ! -x "$t" ] || exec "$t" "$@"; done
exit 127
EOF
printf '#!/bin/bash\n# nproc: macOS has none.\necho 8\n' | put nproc
printf '#!/bin/bash\n# lscpu: macOS has none.\necho "Model name:          stand-in CPU"\n' | put lscpu
printf '#!/bin/bash\n# free: macOS has none.\necho "               total        used        free"; echo "Mem:              31           1          30"\n' | put free
printf '#!/bin/bash\n# du -sb <dir>: the du of macOS has no -b.\nprintf "4096\\t%%s\\n" "$2"\n' | put du
printf '#!/bin/bash\n# df -B1 <dir>: the df of macOS has no -B.\necho "Filesystem 1B-blocks Used Available Use%% Mounted on"; echo "/dev/standin 1000000 1000 999000 1%% $2"\n' | put df
command -v sha256sum >/dev/null 2>&1 || printf '#!/bin/bash\n# sha256sum: older macOS has only shasum, whose lines are the same.\nexec /usr/bin/shasum -a 256 "$@"\n' | put sha256sum

# ---- the copy of the guest --------------------------------------------------------------------------------------
/bin/bash -n "$GUEST"; res "target_guest.sh has no syntax error" $?
"$PY3" -I -B - "$GUEST" "$TW/guest.sh" > "$T/nsubs" <<'PY' || exit 2
import re, sys
src, dst = sys.argv[1:3]
s = open(src, encoding="utf-8").read()
R = "$TEST_ROOT"   # the case's directory: the test starts the copy with this variable set
subs = [
    # ---- paths: what the guest writes or reads on the machine is moved into the case's directory
    ("NEEDRESTART_MODE=a HOME=/root\n", "NEEDRESTART_MODE=a HOME=" + R + "/root_home\n"),
    ("PD=/var/pilot; ", "PD=" + R + "/var_pilot; "),
    ("WORK=/mnt/work; ", "WORK=" + R + "/mnt_work; "),
    ('case "$UH" in /home/*) ;;', 'case "$UH" in "' + R + '/home/"*) ;;'),
    ("awk '/MemTotal/ {print $2}' /proc/meminfo)", "awk '/MemTotal/ {print $2}' \"" + R + "/meminfo\")"),
    ("> /etc/security/limits.d/rhv.conf; }", '> "' + R + '/etc/limits_rhv.conf"; }'),
    ("[ -e /dev/disk/by-id/google-pilot-data ] || return 1", '[ -e "' + R + '/dev_data" ] || return 1'),
    ("printf 'rhv\\n' >> /etc/cron.deny\n", "printf 'rhv\\n' >> \"" + R + "/etc/cron.deny\"\n"),
    # GNU time is named by its full path: the stand-in, by its own
    ('as_user_clean "exec /usr/bin/time -v ', 'as_user_clean "exec ' + R + '/stubs/gtime -v '),
    ('as_user "exec /usr/bin/time -v ', 'as_user "exec ' + R + '/stubs/gtime -v '),
    # ---- time: one minute of the guest is one second here
    ("DEADLINE=$(( T0 + DEADLINE_MIN * 60 ))\n", "DEADLINE=$(( T0 + DEADLINE_MIN * 1 ))\n"),
    ("( sleep $(( DEADLINE_MIN * 60 )); touch ", "( sleep $(( DEADLINE_MIN * 1 )); touch "),
    ("RESERVE=420 ", "RESERVE=7 "),
    ('if [ "$limit" -le 60 ]; then', 'if [ "$limit" -le 1 ]; then'),
    ("    sleep $(( i * 5 ))\n", "    sleep 0\n"),
    ('gcs_put "$PD/status.json" "$RES/status.json" 2>/dev/null; sleep 60; done', 'gcs_put "$PD/status.json" "$RES/status.json" 2>/dev/null; sleep 1; done'),
    ("stop_user; sleep 600; [ -e ", "stop_user; sleep 10; [ -e "),
    ("while true; do stop_user; sleep 30; done ) &\n", "while true; do stop_user; sleep 0.5; done ) &\n"),
    ("while true; do stop_user; sleep 30; done ) & HB_PID=$!", "while true; do stop_user; sleep 0.5; done ) & HB_PID=$!"),
    ("&& sync_small; sleep 60; done\n", "&& sync_small; sleep 1; done\n"),
    ("idle=$((idle + 1)); sleep 5; build_ended ", "idle=$((idle + 1)); sleep 0.1; build_ended "),
    ("\n  sleep 30\ndone\n", "\n  sleep 0.5\ndone\n"),
]
# Left as they are: the limits the guest gives curl and timeout for single commands (--max-time, timeout 120 ...,
# timeout -k 30). They are upper bounds that no stand-in comes near.
def stop(msg):
    sys.exit(msg + "\nThe guest has changed there: bring the list of substitutions in scripts/dev/test_target_guest.sh up to date.")
for i, (old, new) in enumerate(subs, 1):
    if s.count(old) != 1:
        stop("substitution %d matches %d times in target_guest.sh, not exactly once: %r" % (i, s.count(old), old))
    s = s.replace(old, new)
# No other path of the machine may be left in a line of code: the copy would read or write it on THIS machine.
allowed = {"/dev/null",                           # nothing
           "/dev/disk/by-id/google-pilot-data",   # an argument of the stand-ins mkfs.xfs and mount
           "/etc/os-release",                     # read for env.txt; not there on macOS, and then only that is said
           "/bin/bash",                           # an argument of the stand-in useradd
           "/usr/local/sbin", "/usr/local/bin", "/usr/sbin", "/usr/bin", "/sbin", "/bin"}   # the PATH of steps 08 and 09
path = re.compile(r"(?<![A-Za-z0-9_$}.])/(?:etc|var|mnt|home|root|proc|usr|dev|sys|run|tmp|opt|bin|sbin|boot|srv|lib)(?![A-Za-z0-9_])(?:/[A-Za-z0-9_.+*-]+)*")
for no, line in enumerate(s.split("\n"), 1):
    if line.lstrip().startswith("#"):
        continue
    for m in path.finditer(line):
        if m.group(0) not in allowed:
            stop("line %d of the copy names %s, a path of the machine this test neither moves nor knows" % (no, m.group(0)))
open(dst, "w", encoding="utf-8").write(s)
print(len(subs))
PY
NSUBS=$(cat "$T/nsubs")
/bin/bash -n "$TW/guest.sh" || { echo "the copy of the guest has a syntax error"; exit 2; }
ok "the copy of the guest: $NSUBS substitutions of paths and waits, each matching exactly once, and no other path of the machine left in it"

# ---- the stub repository, as the archive the controller would have put in the bucket -----------------------------
RR="$T/repo/rhv"; mkdir -p "$RR/scripts" "$RR/targets/fix" "$RR/analysis" || exit 2
printf 'TGT_SMOKE_TARGETS="A B.C"\nTGT_ROOT_MODULE=Main\n' > "$RR/targets/fix/target.env"
cat > "$RR/scripts/lib.sh" <<'EOF'
# Stub of scripts/lib.sh for scripts/dev/test_target_guest.sh. CASE is the case's directory: the archive is
# unpacked in <case>/mnt_work/rhv. The control files are in <case>/ctl.
REPO_ROOT=${BASH_SOURCE[0]}; case "$REPO_ROOT" in /*) ;; *) REPO_ROOT=$PWD/$REPO_ROOT ;; esac
REPO_ROOT=${REPO_ROOT%/scripts/lib.sh}; CASE=${REPO_ROOT%/*/*}; CTL="$CASE/ctl"
RH_PROJ="$RH_WORKDIR/extract/fix"; RH_LOGS="$RH_WORKDIR/logs"; RH_AN="$RH_WORKDIR/analysis"
STAMP=20261127-000000
# step <name> [arguments]: records the call (steps_run.log) and the environment it was made in (envs/), sleeps
# ctl/<name>.sleep seconds if that file is there, and returns the first line of ctl/<name>.rc (0 without the file).
# When that file has several lines the first is used up, so a step can answer differently each time.
step() {
  local n=$1 rc=0 k; shift
  echo "$n $*" >> "$CASE/steps_run.log"
  k=$(wc -l < "$CASE/steps_run.log" | tr -d ' ')
  mkdir -p "$CASE/envs" && env > "$CASE/envs/$k.$n"
  echo "stub step $n $* (RH_TARGET=${RH_TARGET:-unset} RH_JOBS=${RH_JOBS:-unset})"
  if [ -f "$CTL/$n.sleep" ]; then sleep "$(cat "$CTL/$n.sleep")"; fi
  if [ -f "$CTL/$n.rc" ]; then
    rc=$(head -n 1 "$CTL/$n.rc")
    if [ "$(wc -l < "$CTL/$n.rc" | tr -d ' ')" -gt 1 ]; then tail -n +2 "$CTL/$n.rc" > "$CTL/$n.rc.new" && mv "$CTL/$n.rc.new" "$CTL/$n.rc"; fi
  fi
  return "$rc"
}
EOF
stub() { { echo '#!/bin/bash'; echo "# Stub of scripts/$1 for scripts/dev/test_target_guest.sh: writes the files the real step writes, then does what ctl/ says."; echo '. "${0%/*}/lib.sh"'; cat; } > "$RR/scripts/$1"; }
stub 00_check_prereqs.sh <<'EOF'
mkdir -p "$RH_WORKDIR" && echo fix > "$RH_WORKDIR/.rh-target"
# --install-elan: a made-up elan and toolchain in the user's home (not with ctl/00.no_elan). What its programs print
# is one line, ctl/00.lean_says if that file is there.
case " $* " in *" --install-elan "*)
  if [ ! -e "$CTL/00.no_elan" ]; then
    TC="$HOME/.elan/toolchains/standin-4.0.0"; mkdir -p "$HOME/.elan/bin" "$TC/bin" "$TC/lib"
    says="Lean (version 4.0.0-standin, made by the stub step 00)"; [ ! -f "$CTL/00.lean_says" ] || says=$(cat "$CTL/00.lean_says")
    for t in elan lean lake leanchecker; do printf '#!/bin/bash\necho "%s"\n' "$says" > "$HOME/.elan/bin/$t"; chmod 755 "$HOME/.elan/bin/$t"; done
    for t in lean leanchecker; do printf '#!/bin/bash\necho "stand-in %s of the made-up toolchain"\n' "$t" > "$TC/bin/$t"; chmod 755 "$TC/bin/$t"; done
    ln -sfn ../bin "$TC/lib/bin"
  fi ;;
esac
step 00 "$@"
EOF
stub 01_fetch.sh <<'EOF'
mkdir -p "$RH_WORKDIR/download" "$RH_LOGS" "$RH_AN"
echo "sha256 0000 git https://example.invalid/fix commit 0123 subdir . prefix fix/" > "$RH_WORKDIR/download/source.tar.from"
echo "download: $*" >> "$RH_LOGS/download.log"
step 01 "$@"
EOF
stub 02_inspect_and_extract.sh <<'EOF'
mkdir -p "$RH_PROJ/src" "$RH_PROJ/.lake/build/lib/lean"
echo "leanprover/lean4:v4.0.0-standin" > "$RH_PROJ/lean-toolchain"
echo "theorem t : True := trivial" > "$RH_PROJ/src/A.lean"
echo "sha256 0000" > "$RH_WORKDIR/extract.from"
step 02 "$@"
EOF
stub 03_audit_source.sh <<'EOF'
# With ctl/03.kills_the_guest or ctl/03.terms_the_guest: sends KILL or TERM to the main script of this case's guest
# copy. That is the leader of the process group this step is in (the test starts each copy as one), and it is
# signalled only if its command line is that of this case's copy.
main=$(ps -o pgid= -p $$ | tr -d ' ')
case "$main" in ""|*[!0-9]*|0|1) main="" ;; esac
[ -z "$main" ] || ps -o command= -p "$main" | grep -q -F -e "$CASE/guest.sh" || main=""
if [ -n "$main" ]; then
  [ ! -e "$CTL/03.kills_the_guest" ] || kill -KILL "$main"
  [ ! -e "$CTL/03.terms_the_guest" ] || kill -TERM "$main"
fi
step 03 "$@"
EOF
stub reproduce_findings.sh <<'EOF'
echo "the detail of section S1" > "$RH_LOGS/reproduce_S1.log"
step reproduce "$@"
EOF
stub 04_setup_toolchain.sh <<'EOF'
echo "the detailed log of step 04" > "$RH_LOGS/setup-$STAMP.log"
printf 'compiled' > "$RH_PROJ/.lake/build/lib/lean/A.olean"; printf 'hash' > "$RH_PROJ/.lake/build/lib/lean/A.olean.hash"
[ ! -d "$HOME/.elan/toolchains/standin-4.0.0" ] || echo "installed by the stub step 04" > "$HOME/.elan/toolchains/standin-4.0.0/lib/installed_by_04"
step 04 "$@"
EOF
stub 05_build.sh <<'EOF'
# start: a runner in the background that "builds" for ctl/build.secs seconds (2 without the file), or with
# ctl/build.until_looks until `status` has been asked that many times, and then writes the END line with
# rc=<ctl/build.rc, or 0>; with ctl/build.dies it ends with no END line. status: whether the runner lives, except
# that the first <ctl/status_fails> looks fail whatever is so. stop: ends the runner, which then writes its END
# line with rc=143, as the real one does when lake is stopped. The START and END lines are the real step's. The
# runner is found by its command line, which holds this case's directory, never by a remembered process number.
BS="$RH_LOGS/build-status.txt"; LOG="$RH_LOGS/build-20261127-000001.log"
runner() { ps -A -ww -o pid=,command= | MARK="$REPO_ROOT/scripts/05_build.sh __run" awk 'index($0, ENVIRON["MARK"]) { print $1 }'; }
sub=${1:-}; [ $# = 0 ] || shift
case "$sub" in
  start)
    step 05_start "$@" || exit $?
    mkdir -p "$RH_LOGS"
    nohup /bin/bash "$REPO_ROOT/scripts/05_build.sh" __run "$@" > /dev/null 2>&1 &
    i=0; while [ ! -s "$BS" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
    echo "build started (arguments: $*)" ;;
  __run)
    echo "START $(date '+%Y-%m-%d %H:%M:%S') epoch=$(date +%s) threads=8 log=$LOG" >> "$BS"
    echo "lake build $*" > "$LOG"
    [ ! -e "$CTL/build.makes_replay_dir" ] || { mkdir -p "$RH_AN/kernel_replay"; printf 'module\tstatus\n' > "$RH_AN/kernel_replay/results.tsv"; }
    sp=""; trap '[ -z "$sp" ] || kill "$sp" 2>/dev/null; echo "END $(date "+%Y-%m-%d %H:%M:%S") epoch=$(date +%s) rc=143" >> "$BS"; exit 143' TERM
    if [ -f "$CTL/build.until_looks" ]; then
      want=$(cat "$CTL/build.until_looks"); i=0
      while [ "$i" -lt 600 ]; do n=$(grep -c '^05_status' "$CASE/steps_run.log" 2>/dev/null); [ "${n:-0}" -lt "$want" ] || break; sleep 0.3; i=$((i + 1)); done
    else
      sleep "$(cat "$CTL/build.secs" 2>/dev/null || echo 2)" & sp=$!
      wait "$sp"
    fi
    [ ! -e "$CTL/build.dies" ] || exit 9
    echo "the last line of the build" >> "$LOG"
    echo "END $(date '+%Y-%m-%d %H:%M:%S') epoch=$(date +%s) rc=$(cat "$CTL/build.rc" 2>/dev/null || echo 0)" >> "$BS" ;;
  status)
    echo "05_status" >> "$CASE/steps_run.log"
    n=$(cat "$CTL/status_fails" 2>/dev/null || echo 0)
    if [ "$n" -gt 0 ]; then echo $((n - 1)) > "$CTL/status_fails"; echo "(stub) this look fails, as a session that could not be opened would"; exit 1; fi
    [ -n "$(runner)" ] ;;
  stop)
    echo "05_stop" >> "$CASE/steps_run.log"
    for p in $(runner); do kill "$p" 2>/dev/null; done
    echo "build stopped" ;;
  *) echo "stub 05_build.sh: $sub?"; exit 64 ;;
esac
EOF
stub 06_progress.sh <<'EOF'
echo "06" >> "$CASE/steps_run.log"
echo "compiled: 1 of 1 (100.00%)"
EOF
stub 08_check_axioms.sh <<'EOF'
mkdir -p "$RH_LOGS"
case " $* " in
  *" --probe "*) n=08_probe; echo "probe log" > "$RH_LOGS/axioms-probe-$STAMP.log"
                 printf '%s %s\n' "${TGT_PROBE_MODULE:-unset}" "${TGT_PROBE_THEOREM:-unset}" > "$CASE/probe_seen.txt" ;;
  *" --deep "*)  n=08_deep ;;
  *)             n=08 ;;
esac
if [ "$n" != 08_probe ]; then
  echo "axioms log of $n" > "$RH_LOGS/axioms-full-$STAMP.log"
  rm -f "$RH_LOGS/axioms-full-latest.json"
  if [ -e "$CTL/08.summary_is_a_link" ]; then ln -s "$CASE/not_for_upload.txt" "$RH_LOGS/axioms-full-latest.json"
  else echo "{\"run\": \"$n\"}" > "$RH_LOGS/axioms-full-latest.json"; fi
  [ ! -e "$CTL/$n.makes_replay_dir" ] || mkdir -p "$RH_AN/kernel_replay"
  [ ! -e "$CTL/$n.changes_compiled" ] || printf 'changed' > "$RH_PROJ/.lake/build/lib/lean/A.olean"
fi
step "$n" "$@"
EOF
stub 09_kernel_replay.sh <<'EOF'
case " $* " in *" --summary "*) step 09_summary "$@"; exit $? ;; esac
mkdir -p "$RH_AN/kernel_replay"
printf '{"passed_by_leanchecker": %s}\n' "$(cat "$CTL/09.passed" 2>/dev/null || echo 2)" > "$RH_AN/kernel_replay/summary.json"
printf 'module\tstatus\nA\t0\n' > "$RH_AN/kernel_replay/results.tsv"
[ ! -e "$CTL/09.changes_toolchain" ] || echo "# changed by the stub step 09" >> "$HOME/.elan/toolchains/standin-4.0.0/bin/leanchecker"
[ ! -e "$CTL/09.adds_link" ] || ln -sfn /bin/echo "$HOME/.elan/bin/added_by_09"
step 09 "$@"
EOF
cat > "$RR/analysis/import_graph.py" <<'EOF'
# Stub of analysis/import_graph.py for scripts/dev/test_target_guest.sh.
import os
w = os.environ["RH_WORKDIR"]
case = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
os.makedirs(os.path.join(w, "analysis"), exist_ok=True)
open(os.path.join(w, "analysis", "import_graph_summary.json"), "w").write('{"modules": 1}\n')
open(os.path.join(case, "steps_run.log"), "a").write("import_graph\n")
EOF
ARCHIVE="$TW/bucket/inputs/target/rhv-$COMMIT.tar.gz"
( cd "$T/repo" && COPYFILE_DISABLE=1 tar -czf "$ARCHIVE" rhv ) || { echo "could not make the stub archive"; exit 2; }

# ---- the world every case starts from: a rehearsal, as the controller sends one ---------------------------------
printf 'MemTotal:       32000000 kB\n' > "$TW/meminfo"; : > "$TW/dev_data"
echo "must never reach the bucket" > "$TW/not_for_upload.txt"
printf 'projects/123456789/machineTypes/n4d-standard-8' > "$TW/mdx/machine-type"
printf '{"access_token": "%s", "expires_in": 3599, "token_type": "Bearer"}' "$TOKEN" > "$TW/mdx/token"
mdt() { printf '%s' "$2" > "$TW/md/$1"; }
mdt pilot-bucket "$BUCKET"; mdt pilot-mode target-rehearsal; mdt pilot-nmax 8; mdt pilot-deadline-min 300
mdt pilot-runtag target-rehearsal-20261127-000000; mdt full-tools-commit "$COMMIT"; mdt full-guest-sha "$(sha "$TW/guest.sh")"
mdt target-name fix; mdt target-repo-object "inputs/target/rhv-$COMMIT.tar.gz"; mdt target-repo-sha "$(sha "$ARCHIVE")"
mdt target-build-args "+A +B.C"; mdt target-replay-args "--sample 2"; mdt target-axioms skip

# mk <case> [target]: a new world for one case; H is its directory. With `target`, the metadata of mode target.
# md <name> <value> sets a metadata attribute of it, ctl <name> [content] makes a control file (see the stubs).
CASES=""
mk() {
  H="$C/$1"; cp -R "$TW" "$H" || exit 2; CASES="$CASES $1"
  if [ "${2:-}" = target ]; then
    md pilot-mode target; md pilot-nmax 16; md pilot-runtag target-20261127-000000
    md target-axioms deep; md target-replay-args --c3; rm -f "$H/md/target-build-args"
  fi
}
md()  { printf '%s' "$2" > "$H/md/$1"; }
ctl() { printf '%s\n' "${2:-}" > "$H/ctl/$1"; }
# A step that sleeps "for ever" (until the guest's time limit ends it).
LONG=600

# ---- the cases ---------------------------------------------------------------------------------------------------
# First those that do not depend on the clock (their deadline is 300 "minutes" away), then the five that are about
# the deadline.
# a: its build lasts until the guest has looked at it once, so that the look is there to be checked
mk a;  md target-probe "B.C c_lemma"; ctl 08_probe.rc 1; ctl build.until_looks 1
mk b target; md target-jobs 3; ctl getent_hosts_fails; ctl resolvectl_answers
mk c;  ctl 04.rc 1
mk e;  ctl build.rc 1
mk g2; ctl build.secs 1; ctl build.dies
# h1 and h2 also carry (g): looks at a running build that fail, two of them blind on both sides in h1, five of
# '05 status' alone in h2
mk h1; ctl 09.passed 0; ctl build.until_looks 3; ctl status_fails 2; ctl pgrep_sees_nothing
mk h2; ctl 09.rc 3;     ctl build.until_looks 6; ctl status_fails 5
mk i target;  ctl 09.rc 3; ctl 08.summary_is_a_link
# j also carries a run in which step 00 put no toolchain where the guest lists it
mk j target;  ctl 08.rc 1; ctl 00.no_elan
mk k;  ctl build.makes_replay_dir
mk k2 target; ctl 08_deep.makes_replay_dir
# l1 also carries a replay that says 3 (not complete yet) and then 0
mk l1 target; ctl 09.changes_toolchain; printf '3\n0\n' > "$H/ctl/09.rc"
# l2 also carries a fact that only looks like a number
mk l2; ctl 09.adds_link; ctl getent_hosts_fails; ctl 00.lean_says "--5"
mk m1; md target-build-args "+A;id"
mk m2; md target-probe "OnlyOneWord"
mk m3; echo "not the archive" > "$T/other"; md target-repo-sha "$(sha "$T/other")"
mk m4; md full-guest-sha "$COMMIT$COMMIT"
mk n;  mkdir -p "$H/var_pilot" && date -u +%FT%TZ > "$H/var_pilot/STARTED"
# n2: a second boot after the run had ended: its final status is still on the machine's own disk
mk n2; mkdir -p "$H/var_pilot" && date -u +%FT%TZ > "$H/var_pilot/STARTED" && : > "$H/var_pilot/FINAL"
printf '{"phase": "gather", "state": "DONE", "message": "the first boot ended DONE", "elapsed_s": 100, "deadline_in_s": 50, "mode": "target-rehearsal", "nmax": 8, "utc": "2026-11-27T00:00:00Z"}' > "$H/var_pilot/status.json"
# q1 to q3: the guest's own safety nets. Its main script is killed (q1) or sent TERM (q2) during step 03; in q3 a
# command of the machine's setup never comes back and the deadline is 10 "minutes" away
mk q1; ctl 03.kills_the_guest
mk q2; ctl 03.terms_the_guest
mk q3; md pilot-deadline-min 10; ctl mount.hangs
REST=$CASES; CASES=""
mk d1; md pilot-deadline-min 20; ctl 00.sleep "$LONG"
mk d2; md pilot-deadline-min 8
mk d3; md pilot-deadline-min 45; ctl 09.sleep "$LONG"
mk d4 target; md pilot-deadline-min 45; ctl 08.sleep "$LONG"
mk f;  md pilot-deadline-min 45; ctl build.secs "$LONG"
CLOCK=$CASES; CASES="$REST $CLOCK"

# ---- before any copy is run: nothing real can be reached ---------------------------------------------------------
for c in $CASES; do
  got=$(env -i PATH="$C/$c/stubs:$SYSPATH" /bin/bash -c 'for t in "$@"; do command -v "$t" || echo "(nothing)"; done' _ $MUST_BE_STANDINS $ALSO_STANDINS | tr '\n' ' ')
  want=$(for t in $MUST_BE_STANDINS $ALSO_STANDINS; do printf '%s ' "$C/$c/stubs/$t"; done)
  [ "$got" = "$want" ] || { echo "case $c: on the guest's PATH not every one of '$MUST_BE_STANDINS $ALSO_STANDINS' is the stand-in; no guest copy was run."; echo "  found: $got"; exit 2; }
done
ok "on the PATH each guest copy gets (its stand-ins and $SYSPATH), lean, lake, elan, leanchecker, git, curl, runuser, pkill, pgrep, apt-get, iptables, useradd, mkfs.xfs, mount, sysctl and timeout are the stand-ins"

# The stand-in curl's own check, tried once the old way: the token and the bucket in the arguments.
S0="$WORK/selftest"; cp -R "$TW" "$S0" || exit 2
env -i PATH="$S0/stubs:$SYSPATH" curl -sf -H "Authorization: Bearer $TOKEN" -o "$S0/got.tar.gz" "https://storage.googleapis.com/storage/v1/b/$BUCKET/o/inputs%2Ftarget%2Frhv-$COMMIT.tar.gz?alt=media" >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && cmp -s "$S0/got.tar.gz" "$ARCHIVE" && [ "$(wc -l < "$S0/curl_argv_violations.log" 2>/dev/null | tr -d ' ')" = 1 ]
res "the stand-in curl notes a call that has the token and the bucket's name in its arguments (it answers it all the same: such a guest would fail check (o) and nothing else)" $? "status $rc"

# The stand-in python3 remembers the answers of the guest's two one-line programs: they must be Python's, the first
# time and from memory.
O_NAME="results/a-run/logs/build-20261127-000001.log.gz"; O_ODD="a name+with/other signs"
w1=$("$PY3" -I -B -c "$P_ENC" "$O_NAME"); w2=$("$PY3" -I -B -c "$P_ENC" "$O_ODD"); w3=$("$PY3" -I -B -c "$P_TOK" < "$TW/mdx/token")
g=""; for i in 1 2; do g="$g|$(env -i PATH="$S0/stubs:$SYSPATH" python3 -c "$P_ENC" "$O_NAME")|$(env -i PATH="$S0/stubs:$SYSPATH" python3 -c "$P_ENC" "$O_ODD")|$(env -i PATH="$S0/stubs:$SYSPATH" python3 -c "$P_TOK" < "$TW/mdx/token")"; done
[ "$w3" = "$TOKEN" ] && [ "$g" = "|$w1|$w2|$w3|$w1|$w2|$w3" ] && [ -f "$S0/memo/tok.out" ] && [ -f "$S0/memo/enc/$O_NAME.memo" ]
res "the stand-in python3 gives Python's own answers for the guest's two one-line programs (the token, an object's name), the first time and from memory" $? "got $g; Python says |$w1|$w2|$w3"
grep -q -F -e "$P_TOK" "$GUEST" && grep -q -F -e "$P_ENC" "$GUEST" || echo "note: the guest's one-line programs for the token and for an object's name are no longer the two the stand-in python3 remembers: every call now starts Python (slower, and as right as before)"

# ---- running them ------------------------------------------------------------------------------------------------
# start <case> <seconds>: starts the case's guest copy in a session of its own, with the private PATH and nothing
# else in its environment but TEST_ROOT. It is started from a subshell that ends at once, so that this shell has no
# job to report on when a copy is killed. The guest never ends by itself (it idles until its machine is deleted),
# so attend plays the watcher for all of them: a case whose status.json in the bucket has a final state, or whose
# <seconds> are up, or of which no process is left, is ended, with everything its copy started: one process group.
N=0; LIVE=0
start() {
  local H="$C/$1" pid
  pid=$( ( "$PY3" -I -B -c 'import os, sys
try:
    os.setsid()
except OSError:
    pass
if os.getpgrp() != os.getpid():
    os.setpgid(0, 0)
h = sys.argv[1]
os.execve("/bin/bash", ["/bin/bash", h + "/guest.sh"], {"PATH": h + "/stubs:" + sys.argv[2], "TEST_ROOT": h})' "$H" "$SYSPATH" > "$H/console.out" 2>&1 & echo $! ) )
  case "$pid" in ""|*[!0-9]*|0|1) echo "could not start the guest copy of case $1"; exit 2 ;; esac
  R_NAME[$N]=$1; R_PID[$N]=$pid; R_T0[$N]=$SECONDS; R_END[$N]=$(( SECONDS + $2 ))
  R_ST[$N]="$H/bucket/results/$(cat "$H/md/pilot-runtag")/status.json"
  N=$((N + 1)); LIVE=$((LIVE + 1))
}
attend() {
  local i j
  for (( i = 0; i < N; i++ )); do
    [ -n "${R_PID[$i]}" ] || continue
    j=""; [ ! -f "${R_ST[$i]}" ] || IFS= read -r -d '' j < "${R_ST[$i]}"
    case "$j" in
      *'"state": "DONE"'*|*'"state": "FAIL"'*|*'"state": "DEADLINE"'*|*'"state": "BUILD_FAILED"'*) ;;
      *) if [ "$SECONDS" -lt "${R_END[$i]}" ] && { kill -0 -- "-${R_PID[$i]}" 2>/dev/null || [ $(( SECONDS - R_T0[$i] )) -lt 3 ]; }; then continue; fi ;;
    esac
    kill -KILL -- "-${R_PID[$i]}" 2>/dev/null; kill -KILL "${R_PID[$i]}" 2>/dev/null
    echo $(( SECONDS - R_T0[$i] )) > "$C/${R_NAME[$i]}/seconds"
    R_PID[$i]=""; LIVE=$((LIVE - 1))
  done
}
# An interrupted test must not leave copies of the guest idling for ever.
trap 'for p in "${R_PID[@]}"; do [ -z "$p" ] || kill -KILL -- "-$p" 2>/dev/null; done; echo "interrupted: the guest copies were ended; the scratch files are in $WORK"; exit 130' INT TERM HUP
T_START=$SECONDS
# The cases about the clock get a head start, so that the load of the others does not decide whether they reach
# the step that waits for the time limit: until d1 and d2 have ended, f is building, d3 is in step 09 and d4 in
# step 08 (or one minute has passed). From then on they wait, and the others run beside them.
for c in $CLOCK; do start "$c" 200; done
n=0
while [ "$n" -lt 120 ]; do
  attend
  [ -e "$C/d1/var_pilot/FINAL" ] && [ -e "$C/d2/var_pilot/FINAL" ] && grep -q '^05_start' "$C/f/steps_run.log" 2>/dev/null && grep -q '^09 ' "$C/d3/steps_run.log" 2>/dev/null && grep -q '^08 ' "$C/d4/steps_run.log" 2>/dev/null && break
  sleep 0.5; n=$((n + 1))
done
for c in $REST; do start "$c" 240; done
while [ "$LIVE" -gt 0 ]; do attend; sleep 0.5; done
T_RUN=$(( SECONDS - T_START ))

# ---- reading the results -----------------------------------------------------------------------------------------
# For every case: final.txt (state, phase, message, mode of the bucket's status.json) and facts.txt (STATE and WHAT
# of target_facts.json, then one line per fact), so that the checks below need no JSON.
for c in $CASES; do printf '%s\n' "$C/$c"; done | "$PY3" -I -B -c '
import json, os, sys
def load(p):
    try:
        return json.load(open(p))
    except (OSError, ValueError):
        return {}
def show(v):
    return {True: "true", False: "false"}[v] if isinstance(v, bool) else v
for h in sys.stdin.read().split():
    b = os.path.join(h, "bucket", "results", open(os.path.join(h, "md", "pilot-runtag")).read())
    s, t = load(os.path.join(b, "status.json")), load(os.path.join(b, "target_facts.json"))
    with open(os.path.join(h, "final.txt"), "w") as f:
        for k in ("state", "phase", "message", "mode"):
            f.write("%s=%s\n" % (k, s.get(k, "")))
    with open(os.path.join(h, "facts.txt"), "w") as f:
        f.write("STATE=%s\nWHAT=%s\n" % (t.get("state", ""), t.get("what", "")))
        for k, v in sorted(t.get("facts", {}).items()):
            f.write("%s=%s\n" % (k, show(v)))
' || { echo "could not read the cases' results"; exit 2; }
fin()   { sed -n "s/^$2=//p" "$C/$1/final.txt" | head -n 1; }          # fin <case> state|phase|message|mode
fact()  { sed -n "s/^$2=//p" "$C/$1/facts.txt" | head -n 1; }          # fact <case> <name>
bk()    { printf '%s' "$C/$1/bucket/results/$(cat "$C/$1/md/pilot-runtag")"; }   # the run's directory in the bucket
obj()   { local f; for f in "$(bk "$1")"/$2; do [ -f "$f" ] && return 0; done; return 1; }   # obj <case> <name or pattern>
objs()  { local c=$1 o; shift; for o in "$@"; do obj "$c" "$o" || { MISSING=$o; return 1; }; done; }   # every one of them
rows()  { awk -F'\t' -v s="$2" '$1 == s { printf "%s%s", sep, $2; sep = " " }' "$(bk "$1")/steps.tsv" 2>/dev/null; }   # the exit statuses of step <s>, in order
ran()   { local n; n=$(grep -c -E "^$2( |\$)" "$C/$1/steps_run.log" 2>/dev/null); echo "${n:-0}"; }   # how often the stub step <name> was called
how()   { printf 'it ended %s in phase %s: %s' "$(fin "$1" state)" "$(fin "$1" phase)" "$(fin "$1" message | cut -c1-220)"; }
# ends <case> <state> <words of the message> <text>: the final state and message, as the watcher reads them
ends()  { if [ "$(fin "$1" state)" = "$2" ] && case "$(fin "$1" message)" in *"$3"*) true ;; *) false ;; esac; then ok "$4"; else bad "$4" "$(how "$1")"; fi; }
listing() { ( cd "$(bk "$1")" 2>/dev/null && find . -type f | LC_ALL=C sort | tr '\n' ' ' | cut -c1-600 ); }

# ---- (a) a rehearsal with a probe lemma ----------------------------------------------------------------------------
ends a DONE "rehearsal: the phases ran" "(a) a rehearsal with a probe lemma ends DONE"
[ "$(fin a mode)" = target-rehearsal ] && grep -q '^[0-9][0-9]*$' "$(bk a)/heartbeat" 2>/dev/null
res "(a) ...its status.json names the mode, and a heartbeat is in the bucket" $? "mode '$(fin a mode)'; $(listing a)"
[ "$(fact a STATE)" = DONE ] && [ "$(fact a mode)" = target-rehearsal ] && [ "$(fact a target)" = fix ] && [ "$(fact a user_cannot_connect_to_another_machine)" = true ] \
  && [ "$(fact a user_can_look_up_names)" = true ] && [ "$(fact a toolchain_files_unchanged_from_step_04_to_the_end)" = true ] \
  && [ "$(fact a replay_modules_passed_by_leanchecker)" = 2 ] && [ "$(fact a axioms_probe_exit_status)" = 1 ]
res "(a) ...target_facts.json holds mode, target, user_cannot_connect_to_another_machine, user_can_look_up_names, toolchain_files_unchanged_from_step_04_to_the_end, replay_modules_passed_by_leanchecker and axioms_probe_exit_status" $? "$(tr '\n' ' ' < "$C/a/facts.txt" | cut -c1-700)"
case "$(fact a WHAT)" in *"not a verdict"*"that user's word"*) true ;; *) false ;; esac
res "(a) ...and says what it is: facts, not a verdict, and from step 04 on the word of the one user that ran everything" $? "$(fact a WHAT | cut -c1-200)"
MISSING=""; objs a logs/04_setup.log 'logs/setup-*.log' logs/download.log 'logs/reproduce_*.log' 'logs/build-2*.log.gz' logs/build-status.txt logs/replay_summary.json steps.tsv
res "(a) the bucket holds logs/04_setup.log, step 04's own setup-*.log, download.log, reproduce_*.log, the build log (gzip), build-status.txt, replay_summary.json and steps.tsv" $? "no $MISSING; $(listing a)"
gzip -dc "$(bk a)"/logs/build-2*.log.gz 2>/dev/null | grep -q 'the last line of the build' && grep -q '^START ' "$(bk a)/logs/build-status.txt" && grep -q '^END .*rc=0' "$(bk a)/logs/build-status.txt"
res "(a) ...the build log whole, down to its last line, and build-status.txt with its START and END lines" $?
MISSING=""; objs a logs/extract.from logs/source.tar.from logs/rh-target logs/import_graph_summary.json logs/toolchain_files_after_step_04.sha256.gz logs/compiled_before.sha256 logs/compiled_after.sha256 logs/replay_results.tsv.gz logs/08_probe.log logs/09_replay_1.log logs/09_summary.log target_facts.json pilot.log facts.tsv
res "(a) ...and the steps' other records: extract.from, source.tar.from, rh-target, import_graph_summary.json, the lists of the toolchain's and of the compiled files, the replay's results, each step's output" $? "no $MISSING; $(listing a)"
[ "$(rows a 08_probe)" = 1 ] && [ "$(rows a 09_replay_1)" = 0 ] && [ -z "$(rows a 09_replay_2)" ] && [ -z "$(rows a 08_axioms)" ] && [ "$(ran a 08_probe)" = 1 ] && [ "$(ran a 09)" = 1 ]
res "(a) steps.tsv lists 08_probe and 09_replay_1, each run once; there is no 08_axioms and no second replay" $? "$(cut -f1,2 "$(bk a)/steps.tsv" 2>/dev/null | tr '\t\n' '= ')"
[ "$(cat "$C/a/probe_seen.txt" 2>/dev/null)" = "B.C c_lemma" ] && grep -q -- '--probe' "$C/a/steps_run.log"
res "(a) the probe was 08_check_axioms.sh --probe with TGT_PROBE_MODULE and TGT_PROBE_THEOREM in its environment; its status (1 here) is recorded and not judged" $? "the stub saw '$(cat "$C/a/probe_seen.txt" 2>/dev/null)'"
grep -q '^05_start +A +B.C$' "$C/a/steps_run.log"
res "(a) the build was started with the modules of target-build-args" $? "$(grep '^05_start' "$C/a/steps_run.log" 2>/dev/null)"
[ "$(ls -ld "$C/a/var_pilot" | cut -c1-10)" = "drwx------" ]
res "(a) the guest's own directory (/var/pilot on the machine) is mode 700" $? "$(ls -ld "$C/a/var_pilot" | cut -c1-10)"
grep -q '^apt-get -o DPkg::Lock::Timeout=300 update' "$C/a/root_cmds.log" && grep -q '^mkfs.xfs -q -f /dev/disk/by-id/google-pilot-data$' "$C/a/root_cmds.log" && grep -q '^useradd -m -s /bin/bash rhv$' "$C/a/root_cmds.log" \
  && [ "$(wc -l < "$C/a/iptables.log" | tr -d ' ')" = 2 ] && grep -q -F -e '-d 169.254.169.254 -j REJECT' "$C/a/iptables.log" && grep -q -F -e '! -o lo -j REJECT' "$C/a/iptables.log"
res "(a) the machine was prepared: packages (waiting for the package lock), the data disk, the user, and the two firewall rules for that user" $? "$(tr '\n' ';' < "$C/a/root_cmds.log" | cut -c1-400)"
T_OUT=""; for w in "120 lean --version" "15 getent hosts" "120 bash scripts/05_build.sh status" "300 bash scripts/06_progress.sh" "600 bash scripts/09_kernel_replay.sh --summary" "10 tail -n 1" "120 gzip -c"; do grep -q -- "^$w" "$C/a/timeout.log" || T_OUT="$T_OUT [$w]"; done
[ -z "$T_OUT" ]; res "(a) the user's commands that are not timed steps have a time limit each: lean --version, the name lookup, 05 status, 06, 09 --summary, the reads of the build's status and log" $? "none for$T_OUT"

# ---- (p) steps 08 and 09 are started without the login shell -------------------------------------------------------
CLEANPATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$C/a/home/rhv/.elan/bin"
awk -F'\t' '/scripts\/0[89]_/ { n++; if ($1 != "clean" || index($4, "bash --noprofile --norc -c ") != 1) other++ } END { exit !(n >= 3 && other == 0) }' "$C/a/runuser.log"
res "(p) steps 08 and 09 (and 09 --summary) were started without the login shell: runuser -u rhv -- env -i ... bash --noprofile --norc -c" $? "$(grep 'scripts/0[89]_' "$C/a/runuser.log" | cut -c1-200 | tr '\n' ';')"
awk -F'\t' -v p="$CLEANPATH" '/scripts\/09_kernel_replay.sh/ { n++; if ($2 != "HOME LANG PATH RH_TARGET RH_WORKDIR" || $3 != p) other++ } END { exit !(n >= 2 && other == 0) }' "$C/a/runuser.log"
res "(p) ...step 09 was given no variable beyond HOME, LANG, PATH, RH_TARGET and RH_WORKDIR, and a PATH that starts with the system's directories and ends with elan's" $? "$(awk -F'\t' '/scripts\/09_/ { print $2 " | " $3 }' "$C/a/runuser.log" | tr '\n' ';' | cut -c1-500)"
# What the stub steps found in their environment: besides what the guest gave, only what the shell itself sets (PWD,
# OLDPWD, SHLVL, _), the probe's two variables, and on macOS a variable its libraries add to every process.
SEEN=""; for f in "$C"/a/envs/*.09 "$C"/a/envs/*.09_summary "$C"/a/envs/*.08_probe; do
  for v in $(sed 's/=.*//' "$f" 2>/dev/null); do case " HOME LANG PATH RH_TARGET RH_WORKDIR TGT_PROBE_MODULE TGT_PROBE_THEOREM PWD OLDPWD SHLVL _ __CF_USER_TEXT_ENCODING " in *" $v "*) ;; *) SEEN="$SEEN $v" ;; esac; done
done
[ -z "$SEEN" ] && ls "$C"/a/envs/*.09 >/dev/null 2>&1 && grep -q '^RHV_LOGIN_FILE_WAS_READ=1$' "$C"/a/envs/*.04 && grep -q '^RHV_LOGIN_FILE_WAS_READ=1$' "$C"/a/envs/*.05_start
res "(p) ...and the steps themselves saw it so: nothing of the user's login file in 08 and 09, which steps 00 to 05 (a login shell) did read" $? "08/09 also saw:$SEEN"
grep -q '^LANG=C.UTF-8$' "$C"/a/envs/*.04 && grep -q "^PATH=$C/a/home/rhv/.elan/bin:" "$C"/a/envs/*.04 && ! grep -q 'elan' "$C/a/home/rhv/.profile"
res "(p) steps 00 to 05 get ~/.elan/bin first on PATH and LANG=C.UTF-8 from the guest itself: the login file here sets neither" $? "$(grep -h '^PATH=\|^LANG=' "$C"/a/envs/*.04 2>/dev/null | tr '\n' ' ' | cut -c1-300)"

# ---- (b) mode target -----------------------------------------------------------------------------------------------
ends b DONE "every step ended with status 0" "(b) mode target ends DONE"
[ "$(rows b 08_axioms)" = 0 ] && [ "$(rows b 08_axioms_deep)" = 0 ] && [ "$(rows b 09_replay_1)" = 0 ] && [ -z "$(rows b 09_replay_2)" ] && [ "$(ran b 08)" = 1 ] && [ "$(ran b 08_deep)" = 1 ] && [ "$(ran b 09)" = 1 ] && grep -q -E '^05_start ?$' "$C/b/steps_run.log"
res "(b) ...having run 08_axioms, 08_axioms_deep and 09_replay_1, each once, after a build of everything" $? "$(cut -f1,2 "$(bk b)/steps.tsv" 2>/dev/null | tr '\t\n' '= ')"
case "$(fin b message)" in *"that user's word"*) true ;; *) false ;; esac
res "(b) ...and the DONE message says whose word that is" $? "$(fin b message | cut -c1-250)"
grep -q '"run": "08"' "$(bk b)/logs/axioms-full.json" 2>/dev/null && grep -q '"run": "08_deep"' "$(bk b)/logs/axioms-full-deep.json" 2>/dev/null
res "(b) step 08's summary is kept twice: the first run's and the --deep run's" $? "$(listing b | tr ' ' '\n' | grep axioms | tr '\n' ' ')"
[ "$(fact b build_exit_status)" = 0 ] && [ "$(fact b replay_runs)" = 1 ] && [ "$(fact b compiled_files_unchanged_during_the_checks)" = true ] && [ "$(fact b toolchain_files_unchanged_from_step_04_to_the_end)" = true ] && [ "$(fact b axioms_probe_exit_status)" = skipped ]
res "(b) ...with the facts of a full run: the build's status, one replay, compiled files and toolchain unchanged" $? "$(tr '\n' ' ' < "$C/b/facts.txt" | cut -c1-700)"
[ "$(fact b user_can_look_up_names)" = true ] && [ "$(fact l2 user_can_look_up_names)" = false ]
res "(b) user_can_look_up_names is true when only resolvectl answers, and false (case l2) when neither getent nor resolvectl does" $? "b: $(fact b user_can_look_up_names), l2: $(fact l2 user_can_look_up_names)"
grep -q '^RH_JOBS=3$' "$C"/b/envs/*.04 && grep -q '^RH_JOBS=3$' "$C"/b/envs/*.09 && awk -F'\t' '/scripts\/09_/ && $2 != "HOME LANG PATH RH_JOBS RH_TARGET RH_WORKDIR" { other++ } END { exit other > 0 }' "$C/b/runuser.log"
res "(b) target-jobs reaches the steps as RH_JOBS, whichever way they are started" $? "$(grep -h '^RH_JOBS' "$C"/b/envs/*.04 "$C"/b/envs/*.09 2>/dev/null | tr '\n' ' ')"

# ---- (c) a step that must pass fails -------------------------------------------------------------------------------
ends c FAIL "step 04_setup ended with status 1; see logs/04_setup.log" "(c) step 04 exiting 1 ends the run FAIL, naming the step and its log"
MISSING=""; objs c logs/04_setup.log 'logs/setup-*.log' logs/download.log 'logs/reproduce_*.log' logs/extract.from steps.tsv target_facts.json
res "(c) ...with the step's output, step 04's own setup log and the earlier steps' logs uploaded" $? "no $MISSING; $(listing c)"
[ "$(ran c 05_start)" = 0 ] && [ "$(wc -l < "$C/c/iptables.log" | tr -d ' ')" = 1 ] && [ "$(rows c 04_setup)" = 1 ]
res "(c) ...and nothing after it was run" $? "$(tr '\n' ' ' < "$C/c/steps_run.log" | cut -c1-300)"

# ---- (d) the guest's own time limit --------------------------------------------------------------------------------
# The DEADLINE file is written at the deadline itself; a step is ended 7 s before it (RESERVE). So when the final
# state was decided earlier than the deadline, it was the step's limit that decided it, not that file.
decided() { sed -n 's/^### [^ ]* +\([0-9][0-9]*\)s  FINISH DEADLINE.*/\1/p' "$C/$1/var_pilot/pilot.log" | head -n 1; }   # seconds into the run
ends d1 DEADLINE "the guest's time limit ended step 00_prereqs" "(d) a step ended by the guest's time limit gives DEADLINE, not FAIL"
s=$(decided d1); case "$(rows d1 00_prereqs)" in 124|137) [ -n "$s" ] && [ "$s" -lt 20 ] && [ "$s" -ge 10 ] ;; *) false ;; esac
res "(d) ...it was ended about 7 s (the reserve) before the deadline of 20, with status 124, and that is what decided it" $? "decided ${s:-?} s into the run; steps.tsv: $(rows d1 00_prereqs)"
ends d2 DEADLINE "the guest's time limit ended step 00_prereqs" "(d) a step not started for lack of time gives DEADLINE, not FAIL"
s=$(decided d2); [ "$(awk -F'\t' '$1 == "00_prereqs" { print $2 "/" $3 }' "$(bk d2)/steps.tsv" 2>/dev/null)" = 124/0 ] && grep -q 'not started' "$(bk d2)/logs/00_prereqs.log" 2>/dev/null && [ "$(ran d2 00)" = 0 ] && [ -n "$s" ] && [ "$s" -lt 8 ]
res "(d) ...the step was not run, its log says so, and it was decided before the deadline of 8" $? "decided ${s:-?} s into the run; stub calls: $(ran d2 00)"
ends d3 DEADLINE "the guest's time limit was reached during the checks (08: skipped, 08 --deep: skipped, 09: 124)" "(d) step 09 ended by the time limit gives DEADLINE too, with the statuses of the checks in the message"
[ "$(rows d3 09_replay_1)" = 124 ] && [ -z "$(rows d3 09_replay_2)" ]
res "(d) ...and 09 is not started again once the time is up" $? "$(cut -f1,2 "$(bk d3)/steps.tsv" 2>/dev/null | tr '\t\n' '= ')"
ends d4 DEADLINE "the guest's time limit was reached during the checks (08: 124, 08 --deep: 124, 09: " "(d) step 08 ended by the time limit in mode target gives DEADLINE as well"
[ "$(ran d4 08)" = 1 ] && [ "$(ran d4 08_deep)" = 0 ] && [ "$(ran d4 09)" = 0 ] && [ "$(fact d4 replay_runs)" = 0 ]
res "(d) ...and neither 08 --deep nor 09 is started after it" $? "08 --deep: $(ran d4 08_deep), 09: $(ran d4 09), replay_runs=$(fact d4 replay_runs)"
[ "$(fact d4 replay_exit_status)" != 3 ] && case "$(fin d4 message)" in *"09: 3)"*) false ;; *) true ;; esac
res "(d) ...and step 09, which was never started, is not reported with status 3, which is 09's own word for 'not complete yet'" $? "replay_exit_status=$(fact d4 replay_exit_status); $(fin d4 message | cut -c1-160)"

# ---- (e) the build fails -------------------------------------------------------------------------------------------
ends e BUILD_FAILED "lake build ended with status 1" "(e) a build that ends with rc=1 gives BUILD_FAILED"
[ "$(fin e phase)" = build ] && [ "$(rows e 05_build)" = 1 ] && [ "$(fact e build_exit_status)" = 1 ] && [ "$(ran e 09)" = 0 ] && [ "$(ran e 08_probe)" = 0 ]
res "(e) ...in phase build, with the build's status in steps.tsv and the facts, and no check run after it" $? "phase $(fin e phase); 05_build: $(rows e 05_build)"
gzip -dc "$(bk e)"/logs/build-2*.log.gz 2>/dev/null | grep -q 'the last line of the build' && obj e logs/build-status.txt && obj e logs/06_progress.log
res "(e) ...and the build log, build-status.txt and 06's output uploaded" $? "$(listing e)"

# ---- (f) the deadline during the build -----------------------------------------------------------------------------
ends f DEADLINE "the guest's deadline was reached during the build" "(f) a build still running near the deadline gives DEADLINE"
gzip -dc "$(bk f)"/logs/build-2*.log.gz 2>/dev/null | grep -q '^lake build' && grep -q '^START ' "$(bk f)/logs/build-status.txt" 2>/dev/null && tail -n 1 "$(bk f)/logs/build-status.txt" | grep -q '^END .* rc=143$' && obj f logs/05_stop.log && obj f logs/06_progress.log
res "(f) ...with the build log, build-status.txt (down to the END line of the stopped build), 05 stop's and 06's output uploaded" $? "$(tail -n 1 "$(bk f)/logs/build-status.txt" 2>/dev/null); $(listing f)"
g=$(grep -n 'logs/build-2.*\.log\.gz$' "$C/f/uploads.log" 2>/dev/null | head -n 1 | cut -d: -f1); s=$(grep -n 'logs/05_stop\.log$' "$C/f/uploads.log" 2>/dev/null | head -n 1 | cut -d: -f1)
[ -n "$g" ] && [ -n "$s" ] && [ "$g" -lt "$s" ]
res "(f) ...and the build log had already been uploaded while the build ran" $? "first upload of the build log: line ${g:-none} of the uploads; of 05_stop.log: line ${s:-none}"

# ---- (g) is the build still running? -------------------------------------------------------------------------------
ends g2 FAIL "the build is not running (three looks) and its status file has no END line" "(g) a build that is gone with no END line gives FAIL"
[ "$(wc -l < "$C/g2/pgrep.log" | tr -d ' ')" = 3 ] && obj g2 'logs/build-2*.log.gz' && obj g2 logs/build-status.txt && ! grep -q '^END ' "$(bk g2)/logs/build-status.txt"
res "(g) ...after exactly three looks, with the build log uploaded" $? "looks by root: $(wc -l < "$C/g2/pgrep.log" | tr -d ' '); $(listing g2)"
[ "$(fin g2 phase)" = build ]
res "(g) ...and its final status names the phase build, as the build's other endings do" $? "phase $(fin g2 phase)"
[ "$(cat "$C/h1/ctl/status_fails")" = 0 ] && [ "$(wc -l < "$C/h1/pgrep.log" | tr -d ' ')" -ge 2 ] && grep -q '^END .*rc=0' "$(bk h1)/logs/build-status.txt" 2>/dev/null && [ "$(fact h1 build_exit_status)" = 0 ] && [ "$(ran h1 09)" -ge 1 ]
res "(g) two looks in a row that see no build (05 status fails, root's pgrep finds nothing) do not end a build that runs: it reaches its END line and the checks follow" $? "looks by root: $(wc -l < "$C/h1/pgrep.log" | tr -d ' '); $(tail -n 1 "$(bk h1)/logs/build-status.txt" 2>/dev/null); $(how h1 | cut -c1-120)"
[ "$(cat "$C/h2/ctl/status_fails")" = 0 ] && [ "$(wc -l < "$C/h2/pgrep.log" | tr -d ' ')" -ge 5 ] && [ "$(fact h2 build_exit_status)" = 0 ] && [ "$(ran h2 09)" -ge 1 ]
res "(g) nor do five failed '05 status' looks in a row, while root's own look still finds lake" $? "looks by root: $(wc -l < "$C/h2/pgrep.log" | tr -d ' '); $(how h2 | cut -c1-120)"

# ---- (h) a rehearsal whose replay shows nothing --------------------------------------------------------------------
ends h1 FAIL "leanchecker passed no module" "(h) a rehearsal whose replay passed 0 modules gives FAIL"
ends h2 FAIL "rehearsal: the replay ended with status 3" "(h) a rehearsal whose replay ended with status 3 gives FAIL"
[ "$(ran h2 09)" = 1 ] && [ "$(rows h2 09_replay_1)" = 3 ] && [ -z "$(rows h2 09_replay_2)" ]
res "(h) ...after one run of 09: a sample is not run again" $? "09 was called $(ran h2 09) times"

# ---- (i) mode target: 09 says 'not complete yet' -------------------------------------------------------------------
ends i FAIL "the kernel replay (09) ended with status 3" "(i) mode target with 09 returning 3 every time gives FAIL"
[ "$(ran i 09)" = 3 ] && [ "$(rows i 09_replay_1) $(rows i 09_replay_2) $(rows i 09_replay_3)" = "3 3 3" ] && [ -z "$(rows i 09_replay_4)" ] && [ "$(fact i replay_runs)" = 3 ]
res "(i) ...after exactly three runs of 09" $? "09 was called $(ran i 09) times; replay_runs=$(fact i replay_runs)"
[ "$(ran l1 09)" = 2 ] && [ "$(rows l1 09_replay_1) $(rows l1 09_replay_2)" = "3 0" ] && [ "$(fact l1 replay_exit_status)" = 0 ]
res "(i) ...and with 09 returning 3 and then 0 (case l1) it is run twice and the second status counts" $? "09 was called $(ran l1 09) times; replay_exit_status=$(fact l1 replay_exit_status)"
! obj i logs/axioms-full.json && ! obj i logs/axioms-full-deep.json && ! grep -r -q 'must never reach the bucket' "$C/i/bucket" 2>/dev/null && [ -L "$C/i/mnt_work/w/logs/axioms-full-latest.json" ]
res "(i) a link where step 08's summary should be is not followed: what it points to does not reach the bucket" $? "$(listing i | tr ' ' '\n' | grep axioms | tr '\n' ' ')"

# ---- (j) 08 fails in mode target -----------------------------------------------------------------------------------
ends j FAIL "the axiom check (08) ended with status 1; see logs/08_axioms.log" "(j) step 08 failing in mode target gives FAIL, naming 08"
[ "$(rows j 08_axioms)" = 1 ] && [ "$(rows j 08_axioms_deep)" = 0 ] && [ "$(rows j 09_replay_1)" = 0 ] && [ "$(ran j 08_deep)" = 1 ] && [ "$(ran j 09)" = 1 ]
res "(j) ...after 08 --deep and 09 were still run" $? "$(cut -f1,2 "$(bk j)/steps.tsv" 2>/dev/null | tr '\t\n' '= ')"

# ---- (k) the replay's results directory is there before the replay ------------------------------------------------
ends k FAIL "analysis/kernel_replay is there before step 09 was run" "(k) analysis/kernel_replay made during the build gives FAIL"
[ "$(ran k 09)" = 0 ] && [ "$(ran k 08_probe)" = 0 ]
res "(k) ...before 08 or 09 is run" $? "08 --probe: $(ran k 08_probe), 09: $(ran k 09)"
ends k2 FAIL "analysis/kernel_replay is there before step 09 was run" "(k) analysis/kernel_replay made during step 08, which also runs the archive's code before 09, gives FAIL as well"

# ---- (l) the toolchain's files -------------------------------------------------------------------------------------
ends l1 FAIL "the toolchain's files changed between step 04 and the end of the checks" "(l) a toolchain file changed after step 04 gives FAIL in mode target"
grep -q 'standin-4.0.0/bin/leanchecker' "$(bk l1)/logs/toolchain_files_changed.diff" 2>/dev/null && [ "$(fact l1 toolchain_files_unchanged_from_step_04_to_the_end)" = false ]
res "(l) ...with the difference uploaded, naming the file" $? "$(head -n 4 "$(bk l1)/logs/toolchain_files_changed.diff" 2>/dev/null | tr '\n' ' ' | cut -c1-300)"
ends l2 DONE "toolchain unchanged: false" "(l) in a rehearsal a changed toolchain (a link added beside elan's programs) is recorded and the run still ends DONE"
[ "$(fact l2 toolchain_files_unchanged_from_step_04_to_the_end)" = false ] && grep -q 'bin/added_by_09' "$(bk l2)/logs/toolchain_files_changed.diff" 2>/dev/null
res "(l) ...with the fact false and the added link in the difference" $? "fact: $(fact l2 toolchain_files_unchanged_from_step_04_to_the_end)"
[ "$(fact l2 lean_version)" = "--5" ] && [ "$(fact l2 STATE)" = DONE ]
res "(l) a fact that only looks like a number ('--5' as the first line of lean --version) is kept as text, and target_facts.json is still written" $? "lean_version='$(fact l2 lean_version)', state in target_facts.json '$(fact l2 STATE)'"
[ "$(fact a toolchain_files_listed)" = 8 ] && [ "$(fact j toolchain_files_listed)" = 0 ] && [ "$(fact j toolchain_files_unchanged_from_step_04_to_the_end)" = false ]
res "(l) the list has every file and link of the made-up toolchain (8 in case a); a run in which none was found (case j) says 0 listed, and does not say unchanged" $? "a: $(fact a toolchain_files_listed) listed; j: $(fact j toolchain_files_listed) listed, unchanged=$(fact j toolchain_files_unchanged_from_step_04_to_the_end)"

# ---- (m) metadata the guest must refuse ----------------------------------------------------------------------------
ends m1 FAIL "target-build-args has a character other than" "(m) target-build-args with a ';' gives FAIL"
[ "$(fin m1 phase)" = setup ] && [ ! -e "$C/m1/root_cmds.log" ] && [ ! -e "$C/m1/runuser.log" ] && [ ! -e "$C/m1/steps_run.log" ]
res "(m) ...in phase setup, before anything is installed or run" $? "phase $(fin m1 phase); $(cat "$C/m1/root_cmds.log" 2>/dev/null | head -n 3 | tr '\n' ';')"
ends m2 FAIL "target-probe is not '<module> <lemma>'" "(m) target-probe with one word gives FAIL"
[ "$(fin m2 phase)" = setup ] && [ ! -e "$C/m2/root_cmds.log" ] && [ ! -e "$C/m2/steps_run.log" ]
res "(m) ...in phase setup too" $? "phase $(fin m2 phase)"
ends m3 FAIL "setup step failed: repository" "(m) an archive of the repository whose SHA-256 is not the one in the metadata gives FAIL"
grep -q 'the archive of the repository.s files has SHA-256' "$(bk m3)/pilot.log" 2>/dev/null && [ ! -e "$C/m3/steps_run.log" ] && [ ! -e "$C/m3/mnt_work/rhv/scripts" ]
res "(m) ...said in the log, with nothing unpacked and no step run" $?
ends m4 FAIL "this script is not the one the controller sent" "(m) a startup script whose SHA-256 is not the one in the metadata gives FAIL"

# ---- (n) a second boot ---------------------------------------------------------------------------------------------
ends n FAIL "the run does not start twice" "(n) a second boot (STARTED is there) gives FAIL: the run does not start twice"
[ "$(fin n phase)" = reboot ] && [ ! -e "$C/n/root_cmds.log" ] && [ ! -e "$C/n/steps_run.log" ] && [ ! -e "$C/n/var_pilot/steps.tsv" ]
res "(n) ...and nothing is run or written over" $? "phase $(fin n phase)"
ends n2 DONE "the first boot ended DONE" "(n) a second boot after the run had ended (its final status is still on the machine's disk) leaves that final state as it was"

# ---- (q) the guest's own safety nets -------------------------------------------------------------------------------
ends q1 FAIL "the main script ended without a final state" "(q) when the main script is gone (killed during step 03), the heartbeat's process reports FAIL"
[ "$(fin q1 phase)" = gone ] && grep -q 'the main script is gone without a final state' "$(bk q1)/pilot.log" 2>/dev/null && obj q1 logs/02_inspect.log
res "(q) ...in phase gone, with the log and the earlier steps' output uploaded" $? "phase $(fin q1 phase); $(listing q1)"
ends q2 FAIL "unexpected signal" "(q) a TERM to the main script (during step 03) ends the run FAIL once that step has returned"
obj q2 logs/03_audit.log && obj q2 logs/download.log && obj q2 target_facts.json && [ "$(ran q2 reproduce)" = 0 ]
res "(q) ...with the steps' logs and the facts uploaded, and no further step run" $? "$(listing q2)"
ends q3 DEADLINE "the script had not finished ten minutes after its deadline" "(q) when the main script hangs (a setup command that never returns), the watchdog reports DEADLINE ten minutes after the deadline"
s=$(sed -n 's/.*"elapsed_s": \([0-9][0-9]*\).*/\1/p' "$(bk q3)/status.json" 2>/dev/null); [ "$(fin q3 phase)" = watchdog ] && [ -n "$s" ] && [ "$s" -ge 20 ]
res "(q) ...in phase watchdog, 10 s (ten minutes) after the deadline of 10 and not before" $? "phase $(fin q3 phase), ${s:-?} s into the run"

# ---- (o) and what holds for every case ------------------------------------------------------------------------------
V=""; U=""; for c in $CASES; do
  [ ! -e "$C/$c/curl_argv_violations.log" ] || V="$V $c"
  n=$(wc -l < "$C/$c/uploads.log" 2>/dev/null | tr -d ' '); k=$(grep -c "/b/$BUCKET/o" "$C/$c/curl_config_calls.log" 2>/dev/null)
  [ "${n:-0}" -ge 1 ] && [ "${k:-0}" -ge "${n:-0}" ] || U="$U $c"
done
[ -z "$V" ]; res "(o) in no case did the token or the bucket's name appear on a curl command line" $? "cases:$V; first: $(cat "$C/${V##* }/curl_argv_violations.log" 2>/dev/null | head -n 1 | cut -c1-200)"
[ -z "$U" ]; res "(o) ...every request to the bucket came with both on standard input (-K -), and every case uploaded" $? "cases:$U"
E=""; for c in $CASES; do [ ! -e "$C/$c/standin_errors.log" ] || E="$E $c"; done
[ -z "$E" ]; res "no stand-in was asked for something it does not know (the guest calls nothing in a way this test has not seen)" $? "cases:$E; first: $(cat "$C/${E##* }/standin_errors.log" 2>/dev/null | head -n 1 | cut -c1-200)"
E=""; for c in $CASES; do grep -q -E 'command not found|unbound variable|syntax error|No such file or directory|Permission denied|Traceback' "$C/$c/var_pilot/pilot.log" 2>/dev/null && E="$E $c"; done
[ -z "$E" ]; res "no case's log shows a shell or Python error (command not found, unbound variable, No such file, Traceback)" $? "cases:$E; first: $(grep -h -E 'command not found|unbound variable|syntax error|No such file or directory|Permission denied|Traceback' "$C/${E##* }/var_pilot/pilot.log" 2>/dev/null | head -n 1 | cut -c1-200)"
E=""; for c in $CASES; do [ -n "$(fin "$c" state)" ] || E="$E $c"; done
[ -z "$E" ]; res "every case reached a final state within its time (the cases took $T_RUN s together)" $? "cases:$E"

echo "$PASS passed, $FAIL failed"
[ -n "${TEST_SCRATCH:-}" ] || rm -rf "${WORK:?}"
[ "$FAIL" = 0 ]
