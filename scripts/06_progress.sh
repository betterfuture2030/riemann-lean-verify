#!/bin/bash
# 06_progress.sh - a read-only snapshot of the build.
#
# What it does: prints how many modules are compiled (the number of .olean files under
#   RH_PROJ/.lake/build/lib) out of how many source files; the number of failed jobs (lines that
#   start with Lake's failure mark in all build logs); warnings; the rate of the current run and
#   of the last 15 minutes; a naive time-remaining figure; the compiler processes; memory, swap
#   and free disk space. Works on macOS and Linux.
#
#   The time-remaining figure is a FLOOR, not a forecast. It assumes the recent rate holds for
#   every remaining module. Modules are compiled in dependency order, so later ones tend to
#   import more of the project; how much slower that makes them had not been measured when
#   this was written (2026-11-20).
# What it changes on disk: nothing.
# How long it takes: a few seconds (it counts files in the build directory).
#
# Usage: scripts/06_progress.sh [--du]
#   --du   also report the size of the build directory (slow on a large build)
# Exit status: 0. (Failures are reported in the output, not through the exit status.)
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"
. "$HERE/common.sh"

DU=0
for arg in "$@"; do
  case "$arg" in
    --du) DU=1 ;;
    -h|--help) show_help; exit 0 ;;
    *) die "unknown argument: $arg (try --help)" ;;
  esac
done

STATUS_FILE="$RH_LOGS/build-status.txt"
now=$(date +%s)
echo "== Build snapshot $(date '+%Y-%m-%d %H:%M:%S')"
echo "work directory: $RH_WORKDIR"
[ "${RH_TARGET_IS_DEFAULT:-1}" = 1 ] || echo "target: $RH_TARGET"

# --- is it running?
runner=$(build_runner_pid)
lakes=$(lake_build_pids | tr '\n' ' ')
if [ -n "$runner" ] || [ -n "$lakes" ]; then
  echo "state: RUNNING (launcher pid ${runner:-none}, lake pid ${lakes:-none})"
else
  echo "state: NOT RUNNING"
fi

# --- status file
start_epoch=""; end_epoch=""; threads="?"
if [ -f "$STATUS_FILE" ]; then
  last_start=$(grep '^START' "$STATUS_FILE" | tail -n 1)
  last_line=$(tail -n 1 "$STATUS_FILE")
  runs=$(grep -c '^START' "$STATUS_FILE")
  start_epoch=$(printf '%s\n' "$last_start" | sed -n -E 's/.*epoch=([0-9]+).*/\1/p')
  threads=$(printf '%s\n' "$last_start" | sed -n -E 's/.* threads=([^ ]+).*/\1/p')
  case "$last_line" in END*) end_epoch=$(printf '%s\n' "$last_line" | sed -n -E 's/.*epoch=([0-9]+).*/\1/p') ;; esac
  echo "runs so far: $runs   last entries of the status file:"
  tail -n 2 "$STATUS_FILE" | sed 's/^/  /'
else
  echo "no build has been started here yet ($STATUS_FILE does not exist)"
fi

# --- modules
total=${RH_MODULE_TOTAL:-$(count_sources)}
compiled=$(count_oleans)
echo
echo "== Modules"
if [ "$total" -gt 0 ]; then
  pct=$(awk -v c="$compiled" -v t="$total" 'BEGIN { printf "%.2f", 100 * c / t }')
  echo "compiled: $compiled of $total ($pct%)"
else
  echo "compiled: $compiled (the source directory was not found, so the total is unknown)"
fi

# --- logs
LOGF=""
if [ -L "$RH_LOGS/build-current.log" ]; then LOGF=$(readlink "$RH_LOGS/build-current.log"); fi
if [ -z "$LOGF" ] || [ ! -f "$LOGF" ]; then
  LOGF=$(ls -1 "$RH_LOGS"/build-2*.log 2>/dev/null | tail -n 1)
fi
fail_lines=0; fail_modules=0
if ls "$RH_LOGS"/build-2*.log >/dev/null 2>&1; then
  fail_lines=$(cat "$RH_LOGS"/build-2*.log | LC_ALL=C grep -c "^$MARK_FAIL ")
  fail_modules=$(cat "$RH_LOGS"/build-2*.log | LC_ALL=C grep "^$MARK_FAIL " | awk '{ print $4 }' | sort -u | wc -l | tr -d ' ')
fi
echo "FAILED jobs: $fail_lines line(s) in all build logs, $fail_modules distinct target(s)"
if [ "$fail_lines" -gt 0 ]; then
  cat "$RH_LOGS"/build-2*.log | LC_ALL=C grep "^$MARK_FAIL " | awk '{ print $4 }' | sort -u | head -n 10 | sed 's/^/  failed: /'
fi

built=0
# A job that succeeded starts with one of three marks: plain, with warnings, or (MARK_INFO) with output at
# information level only, as a module with '#eval' or '#print' in it gives. All three are compiled modules.
# For the default target the third is left out, as it was before there were targets: its build logs have
# that mark only on replayed jobs, so the count is the same, but the last job line shown would change.
DONE_MARKS="$MARK_OK|$MARK_WARN"
[ "${RH_TARGET_IS_DEFAULT:-1}" = 1 ] || DONE_MARKS="$DONE_MARKS|$MARK_INFO"
if [ -n "$LOGF" ] && [ -f "$LOGF" ]; then
  built=$(LC_ALL=C grep -cE "^($DONE_MARKS) \[[0-9]+/[0-9]+\] Built " "$LOGF")
  warned=$(LC_ALL=C grep -c "^$MARK_WARN " "$LOGF")
  last=$(LC_ALL=C grep -E "^($DONE_MARKS|$MARK_FAIL) \[" "$LOGF" | tail -n 1 | cut -c1-160)
  echo "current log: $LOGF"
  echo "  compiled in this run: $built   jobs with warnings (including replayed ones): $warned"
  echo "  last job line: ${last:-none yet}"
else
  echo "current log: none found in $RH_LOGS"
fi

# --- rate and the naive figure
echo
echo "== Rate"
rate=""
if [ -n "$start_epoch" ]; then
  until_epoch=${end_epoch:-$now}
  elapsed=$((until_epoch - start_epoch))
  if [ "$elapsed" -gt 0 ]; then
    rate=$(awk -v b="$built" -v e="$elapsed" 'BEGIN { printf "%.0f", b * 3600 / e }')
    echo "current run: $built modules in $(awk -v e="$elapsed" 'BEGIN { printf "%.2f", e / 3600 }') h with $threads jobs = $rate modules/hour"
  fi
fi
recent=0
if [ -d "$RH_PROJ/.lake/build/lib" ]; then
  recent=$(find "$RH_PROJ/.lake/build/lib" -name '*.olean' -type f -mmin -15 2>/dev/null | wc -l | tr -d ' ')
fi
recent_rate=$((recent * 4))
echo "last 15 minutes: $recent modules = $recent_rate modules/hour"
use_rate=$recent_rate
[ "$use_rate" -gt 0 ] || use_rate=${rate:-0}
if [ "$total" -gt 0 ] && [ "$compiled" -ge "$total" ]; then
  echo "every source file has a compiled module."
elif [ "$total" -gt 0 ] && [ "$use_rate" -gt 0 ]; then
  awk -v t="$total" -v c="$compiled" -v r="$use_rate" 'BEGIN {
    h = (t - c) / r
    printf "naive time remaining: at least %.0f hours (%.1f days) at %d modules/hour\n", h, h / 24, r }'
  echo "  This is a floor, not a forecast: it assumes the recent rate holds for all remaining"
  echo "  modules, and later modules tend to import more of the project than earlier ones."
else
  echo "naive time remaining: not available (no recent progress to extrapolate from)"
fi

# --- processes
echo
echo "== Compiler processes"
leans=$(project_pids_named lean | tr '\n' ' ')
checkers=$(project_pids_named leanchecker | wc -l | tr -d ' ')
nlean=$(printf '%s\n' $leans | grep -c .)
echo "lean: $nlean   leanchecker: $checkers"
if [ "$nlean" -gt 0 ]; then
  # shellcheck disable=SC2086
  ps -o rss= -o etime= -o args= -p "$(printf '%s,' $leans | sed 's/,$//')" 2>/dev/null | sort -rn | head -n 5 \
    | awk '{ f = ""; for (i = 3; i <= NF; i++) if ($i ~ /\.lean$/) { f = $i; break }
             n = split(f, p, "/"); printf "  %6d MB  %10s  %s\n", $1 / 1024, $2, (n ? p[n] : "") }'
fi

# --- memory, swap, disk
echo
echo "== Memory and disk"
echo "cores: $(ncpu)   memory: $(mem_gb) GB   load: $(uptime | sed -E 's/.*load averages?: *//')"
if is_macos; then
  memory_pressure 2>/dev/null | grep -E 'free percentage' | sed 's/^/  /'
  echo "  swap: $(sysctl -n vm.swapusage 2>/dev/null)"
elif [ -r /proc/meminfo ]; then
  awk '/^MemAvailable:/ { a = $2 } /^SwapTotal:/ { st = $2 } /^SwapFree:/ { sf = $2 }
       END { printf "  memory available: %.1f GB\n  swap: total %.1f GB, used %.1f GB\n", a / 1048576, st / 1048576, (st - sf) / 1048576 }' /proc/meminfo
fi
free_kb=$(disk_free_kb "$RH_WORKDIR"); free_kb=${free_kb:-0}
echo "free disk in the work directory's filesystem: $((free_kb / 1048576)) GB"
if [ "$DU" -eq 1 ] && [ -d "$RH_PROJ/.lake/build" ]; then
  echo "build directory size: $(du -sh "$RH_PROJ/.lake/build" 2>/dev/null | cut -f1)"
fi
exit 0
