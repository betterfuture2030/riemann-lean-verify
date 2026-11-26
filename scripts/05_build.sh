#!/bin/bash
# 05_build.sh - start, stop or inspect the full compile of the proof.
#
# What it does:
#   start   launches 'lake build' in the background, detached from the terminal (nohup), so it
#           survives closing the window. On macOS it runs under caffeinate so the machine does
#           not sleep. The number of parallel compiler processes comes from --jobs, else RH_JOBS,
#           else the recommended value (see 00_check_prereqs.sh); it is passed to Lake as
#           LEAN_NUM_THREADS. The open-file limit is raised first. Refuses to start if a build
#           of this project is already running. Extra arguments are passed to 'lake build' as
#           targets (for example +Main); with none, everything is built.
#   stop    stops Lake, then kills any Lean compiler processes of this project that are still
#           alive. (Lake does not always take its children with it; orphaned compilers would
#           keep using memory and CPU.) Modules that were being compiled are lost and are
#           compiled again on the next start; finished modules are kept.
#   status  says whether a build is running and shows the last entries of the status file.
#   Lake only compiles what is missing or out of date, so stop and start as often as you like.
#   'lake update' is never run: the dependency versions stay exactly as published.
# What it changes on disk: 'start' writes, in RH_WORKDIR/logs: build-<timestamp>.log, the
#   symlink build-current.log, build.pid, and one START and one END line per run appended to
#   build-status.txt. Lake writes compiled files under RH_PROJ/.lake/build (roughly 1.5 TB for
#   a complete build, by extrapolation). 'stop' and 'status' write nothing themselves.
# How long it takes: 'start' returns in seconds. The build itself takes days on a laptop.
#   (The size and the days are the default target's.)
#
# Usage: scripts/05_build.sh start [--jobs N] [lake-target ...]
#        scripts/05_build.sh stop
#        scripts/05_build.sh status
# Exit status: start: 0 if the build was launched; stop: 0 if nothing is left running;
#   status: 0 if a build is running, 1 if not.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"
. "$HERE/common.sh"

STATUS_FILE="$RH_LOGS/build-status.txt"
PID_FILE="$RH_LOGS/build.pid"

# The detached runner. Not for direct use: 'start' launches it under nohup. Its second argument
# is the project directory; it is there only so that the process can be recognised as this
# project's launcher from its command line.
run_build() {  # run_build <jobs> <project dir> [targets...]
  local jobs=$1 ts logf rc
  shift 2
  cd "$RH_PROJ" || exit 1
  raise_nofile
  export LEAN_NUM_THREADS="$jobs"
  ts=$(date +%Y%m%d-%H%M%S)
  logf="$RH_LOGS/build-$ts.log"
  ln -sfn "$logf" "$RH_LOGS/build-current.log"
  echo "START $(date '+%Y-%m-%d %H:%M:%S') epoch=$(date +%s) threads=$jobs log=$logf" >> "$STATUS_FILE"
  if is_macos && command -v caffeinate >/dev/null 2>&1; then
    caffeinate -i -m -s lake build "$@" > "$logf" 2>&1
  else
    lake build "$@" > "$logf" 2>&1
  fi
  rc=$?
  echo "END $(date '+%Y-%m-%d %H:%M:%S') epoch=$(date +%s) rc=$rc" >> "$STATUS_FILE"
  exit "$rc"
}

cmd_start() {
  local jobs="" runner
  while [ $# -gt 0 ]; do
    case "$1" in
      --jobs) shift; [ $# -gt 0 ] || die "--jobs needs a number"; jobs=$1; shift ;;
      --) shift; break ;;
      -*) die "unknown option for start: $1" ;;
      *) break ;;
    esac
  done
  case "$jobs" in ''|*[!0-9]*|0) [ -z "$jobs" ] || die "--jobs must be a positive number" ;; esac
  require_extract_from     # for a target other than the default one: the tree must be the profile's archive
  [ -f "$RH_PROJ/lakefile.toml" ] || die "project not found at $RH_PROJ (run steps 01 to 04 first)"
  [ -d "$RH_PROJ/.lake/packages/mathlib" ] || die "Mathlib is not set up in $RH_PROJ (run 04_setup_toolchain.sh first)"
  need_cmd lake
  ensure_dirs
  if build_is_running; then
    echo "A build of this project is already running; not starting another." >&2
    cmd_status >&2
    exit 1
  fi
  jobs=$(effective_jobs "$jobs")
  nohup bash "$HERE/05_build.sh" __run "$jobs" "$RH_PROJ/" "$@" >/dev/null 2>&1 &
  runner=$!
  echo "$runner" > "$PID_FILE"
  disown "$runner" 2>/dev/null || true
  sleep 3
  if ! kill -0 "$runner" 2>/dev/null; then
    case "$(tail -n 1 "$STATUS_FILE" 2>/dev/null)" in
      END*" rc=0")
        log "lake build finished at once with status 0: everything it was asked for is already compiled"
        return 0 ;;
    esac
    echo "The build process exited within 3 seconds. Last lines of its log:" >&2
    tail -n 20 "$RH_LOGS/build-current.log" 2>/dev/null >&2
    tail -n 2 "$STATUS_FILE" 2>/dev/null >&2
    exit 1
  fi
  log "build started with $jobs parallel jobs (launcher pid $runner)"
  log "log:      $RH_LOGS/build-current.log"
  log "progress: $HERE/06_progress.sh"
  log "stop:     $0 stop"
}

cmd_stop() {
  local lakes runner pid i left n
  lakes=$(lake_build_pids | tr '\n' ' ')
  runner=$(build_runner_pid)
  if [ -z "$lakes" ] && [ -z "$runner" ] && [ -z "$(project_pids_named lean)" ]; then
    log "no build of this project is running"
    return 0
  fi
  if [ -n "$lakes" ]; then
    log "stopping lake (pid $lakes)"
    # shellcheck disable=SC2086
    kill -TERM $lakes 2>/dev/null
    i=0
    while [ "$i" -lt 15 ]; do
      left=""
      for pid in $lakes; do kill -0 "$pid" 2>/dev/null && left="$left $pid"; done
      [ -z "$left" ] && break
      sleep 1; i=$((i + 1))
    done
    if [ -n "$left" ]; then
      log "lake did not exit after 15 s; killing it"
      # shellcheck disable=SC2086
      kill -KILL $left 2>/dev/null
    fi
  fi
  # Lake does not always take its compiler processes with it. Kill the ones that are left. A
  # process is only ever chosen here because it is named lean AND its working directory or
  # command line is inside this project, never because of a remembered PID.
  sleep 1
  n=0
  for pid in $(project_pids_named lean); do
    kill -KILL "$pid" 2>/dev/null && n=$((n + 1))
  done
  [ "$n" -gt 0 ] && log "killed $n orphaned lean process(es)"
  # The launcher records the END line itself once lake has gone; give it a moment.
  if [ -n "$runner" ]; then
    i=0
    while [ "$i" -lt 10 ] && kill -0 "$runner" 2>/dev/null; do sleep 1; i=$((i + 1)); done
    if kill -0 "$runner" 2>/dev/null; then
      log "the launcher (pid $runner) is still alive; sending it TERM"
      kill -TERM "$runner" 2>/dev/null
      sleep 1
    fi
  fi
  if build_is_running || [ -n "$(project_pids_named lean)" ]; then
    log "WARNING: some build processes are still running:"
    cmd_status
    return 1
  fi
  log "build stopped. Compiled modules on disk: $(count_oleans)"
  return 0
}

cmd_status() {
  local runner lakes nlean
  runner=$(build_runner_pid)
  lakes=$(lake_build_pids | tr '\n' ' ')
  nlean=$(project_pids_named lean | wc -l | tr -d ' ')
  echo "work directory:  $RH_WORKDIR"
  [ "${RH_TARGET_IS_DEFAULT:-1}" = 1 ] || echo "target:          $RH_TARGET"
  echo "launcher:        ${runner:-not running}"
  echo "lake build:      ${lakes:-not running}"
  echo "lean compilers:  $nlean"
  if [ -f "$STATUS_FILE" ]; then
    echo "last entries of $STATUS_FILE:"
    tail -n 2 "$STATUS_FILE" | sed 's/^/  /'
  else
    echo "no build has been started here yet ($STATUS_FILE does not exist)"
  fi
  [ -n "$runner" ] || [ -n "$lakes" ]
}

sub=${1:-}
[ $# -gt 0 ] && shift
case "$sub" in
  start) cmd_start "$@" ;;
  stop) cmd_stop ;;
  status) cmd_status ;;
  __run) run_build "$@" ;;
  -h|--help|help) show_help; exit 0 ;;
  '') show_help; exit 2 ;;
  *) die "unknown subcommand: $sub (use start, stop or status)" ;;
esac
