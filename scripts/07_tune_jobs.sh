#!/bin/bash
# 07_tune_jobs.sh - measure which number of parallel jobs compiles fastest on this machine.
#
# What it does: for each job count in the candidate list it stops any running build, starts
#   the build with that many jobs, waits for a warm-up period, then counts how many modules are
#   compiled during a fixed window and samples CPU user / system / idle time. One row per
#   candidate goes to a TSV file. At the end it restarts the build with the fastest setting and
#   leaves it running. The comparison is only fair while there is plenty left to compile.
#
#   Background: on a 10-core, 24 GB Mac (2026-11-20, 5-minute windows) 8 jobs was fastest at
#   about 3,200 modules per hour. 5 jobs gave about 2,100. 10 jobs gave about 2,900 and spent
#   about half of all CPU time in the operating system. More jobs than the memory allows makes
#   the build slower, not faster.
# What it changes on disk: writes RH_WORKDIR/logs/tuning-<timestamp>.tsv, and everything that
#   05_build.sh start writes. Each switch discards the modules that were being compiled at
#   that moment (they are compiled again); finished modules are kept.
# How long it takes: (warm-up + window) seconds per candidate, by default 400 s each.
#
# Usage: scripts/07_tune_jobs.sh [--window SECONDS] [--warmup SECONDS] [JOBS ...]
#   --window SECONDS  length of each measurement window (default 300)
#   --warmup SECONDS  time to let Lake start before measuring (default 100)
#   JOBS ...          job counts to try, in order (default: recommended-2, recommended,
#                     recommended+2, limited to the range 1..cores)
# Example: scripts/07_tune_jobs.sh --window 300 8 5 10 6
# Exit status: 0 if the build was left running with the best setting, 1 otherwise.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"
. "$HERE/common.sh"

WINDOW=300; WARMUP=100; CANDIDATES=""
while [ $# -gt 0 ]; do
  case "$1" in
    --window) shift; [ $# -gt 0 ] || die "--window needs a number of seconds"; WINDOW=$1 ;;
    --warmup) shift; [ $# -gt 0 ] || die "--warmup needs a number of seconds"; WARMUP=$1 ;;
    -h|--help) show_help; exit 0 ;;
    -*) die "unknown option: $1 (try --help)" ;;
    *) case "$1" in *[!0-9]*|0) die "job counts must be positive numbers: $1" ;; esac
       CANDIDATES="$CANDIDATES $1" ;;
  esac
  shift
done
case "$WINDOW" in ''|*[!0-9]*|0) die "--window must be a positive number of seconds" ;; esac
case "$WARMUP" in ''|*[!0-9]*) die "--warmup must be a number of seconds" ;; esac
if [ -z "$CANDIDATES" ]; then
  r=$(recommended_jobs); c=$(ncpu)
  for n in $((r - 2)) "$r" $((r + 2)); do
    [ "$n" -ge 1 ] && [ "$n" -le "$c" ] && CANDIDATES="$CANDIDATES $n"
  done
fi
[ -f "$RH_PROJ/lakefile.toml" ] || die "project not found at $RH_PROJ (run steps 01 to 04 first)"
ensure_dirs
OUT="$RH_LOGS/tuning-$(date +%Y%m%d-%H%M%S).tsv"
TAB=$(printf '\t')
BUILD="$HERE/05_build.sh"

# CPU user / system / idle percentages over a sampling period, tab separated.
# Linux: exact averages between two readings of /proc/stat. macOS: top's average over 10 s.
cpu_begin() { if [ -r /proc/stat ]; then head -n 1 /proc/stat; fi; }
cpu_end() {  # cpu_end <first reading>
  if [ -r /proc/stat ]; then
    { printf '%s\n' "$1"; head -n 1 /proc/stat; } | awk '
      NR == 1 { for (i = 2; i <= NF; i++) a[i] = $i; next }
      { t = 0; for (i = 2; i <= NF; i++) { d[i] = $i - a[i]; t += d[i] }
        if (t <= 0) t = 1
        printf "%.2f\t%.2f\t%.2f\n", 100 * (d[2] + d[3]) / t, 100 * (d[4] + d[7] + d[8]) / t, 100 * (d[5] + d[6]) / t }'
  else
    top -l 2 -s 10 -n 0 2>/dev/null | grep 'CPU usage' | tail -n 1 \
      | sed -E "s/.*: *([0-9.]+)% user, *([0-9.]+)% sys, *([0-9.]+)% idle.*/\\1${TAB}\\2${TAB}\\3/"
  fi
}
failed_total() {
  if ls "$RH_LOGS"/build-2*.log >/dev/null 2>&1; then
    cat "$RH_LOGS"/build-2*.log | LC_ALL=C grep -c "^$MARK_FAIL "
  else
    echo 0
  fi
}

log "work directory: $RH_WORKDIR"
log "candidates:$CANDIDATES   warm-up ${WARMUP}s   window ${WINDOW}s   results: $OUT"
printf 'cap\tmodules\tseconds\tmodules_per_hour\tcpu_user\tcpu_sys\tcpu_idle\tfailed_total\n' > "$OUT"
best=""; bestrate=-1
for N in $CANDIDATES; do
  bash "$BUILD" stop >/dev/null || die "could not stop the running build; not continuing"
  bash "$BUILD" start --jobs "$N" >/dev/null || die "could not start the build with $N jobs"
  log "measuring $N jobs"
  sleep "$WARMUP"
  c0=$(count_oleans); t0=$(date +%s); cpu0=$(cpu_begin)
  if [ ! -r /proc/stat ] && [ "$WINDOW" -gt 15 ]; then sleep $((WINDOW - 12)); else sleep "$WINDOW"; fi
  cpu=$(cpu_end "$cpu0")
  c1=$(count_oleans); t1=$(date +%s)
  secs=$((t1 - t0)); [ "$secs" -gt 0 ] || secs=1
  rate=$(awk -v a="$c0" -v b="$c1" -v s="$secs" 'BEGIN { printf "%.1f", (b - a) * 3600 / s }')
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$N" "$((c1 - c0))" "$secs" "$rate" "${cpu:-$TAB$TAB}" "$(failed_total)" >> "$OUT"
  log "  $N jobs: $((c1 - c0)) modules in ${secs}s = $rate modules/hour"
  if awk -v r="$rate" -v b="$bestrate" 'BEGIN { exit !(r > b) }'; then bestrate=$rate; best=$N; fi
  if ! bash "$BUILD" status >/dev/null 2>&1; then
    log "  the build is no longer running (finished, or failed); stopping the experiment"
    break
  fi
done
[ -n "$best" ] || die "no candidate was measured"

bash "$BUILD" stop >/dev/null
bash "$BUILD" start --jobs "$best" || die "could not restart the build with $best jobs"
echo
echo "Best: $best jobs at $bestrate modules/hour. The build is running again with $best jobs."
echo "To keep that setting, put RH_JOBS=$best in config.env."
echo
if command -v column >/dev/null 2>&1; then column -t -s "$TAB" "$OUT"; else cat "$OUT"; fi
echo
echo "Compiled modules now: $(count_oleans)"
exit 0
