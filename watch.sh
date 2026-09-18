#!/usr/bin/env bash
#
# pr-dashboard/watch.sh
# Regenerates dashboard.html on an interval so the open page stays live.
# The HTML meta-refreshes on the same interval, so the browser reloads it.
#
# Usage:  ./watch.sh            # default 300s interval
#         INTERVAL=120 ./watch.sh
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INTERVAL="${INTERVAL:-300}"
export REFRESH="$INTERVAL"

# Whole-cycle ceiling. fetch.sh caps each individual gh call, but it makes one
# call per PR while enriching, so a slow-but-not-hung network could still outrun
# the interval. Kill the cycle and everything it spawned, then start clean.
# (No `setsid` on macOS — bash's own job control gives us the process group:
# run fetch.sh in a monitored subshell so `kill -PGID` reaches its gh children.)
CYCLE_TIMEOUT="${CYCLE_TIMEOUT:-240}"

# Idle handling. The Mac idle-sleeps after 15 minutes (`pmset -g | grep sleep`),
# and a cycle that starts in one of the 45-second DarkWake windows gets torn in
# half: sockets die with "connection reset by peer", caches age past their limit
# in wall-clock while only two cycles an hour actually run, and the queue quietly
# loses PRs. So don't fetch while nobody is here. Below IDLE_SKIP seconds of HID
# idleness we run normally; above it we poll cheaply and let the machine sleep.
# Touching the keyboard drops idle to zero, so a cycle starts within IDLE_POLL
# of you sitting back down.
IDLE_SKIP="${IDLE_SKIP:-600}"
IDLE_POLL="${IDLE_POLL:-30}"

log() { echo "[$(date '+%H:%M:%S')] $*" >&2; }

# Seconds since the last keyboard/mouse event. An unreadable counter reports 0
# (active) on purpose: losing the idle optimization is fine, silently never
# fetching again is not.
idle_seconds() {
  local ns=""
  ns="$(ioreg -c IOHIDSystem 2>/dev/null | awk '/HIDIdleTime/ {print $NF; exit}')" || true
  case "$ns" in
    ''|*[!0-9]*) echo 0 ;;
    *)           echo $(( ns / 1000000000 )) ;;
  esac
}

# Set by run_cycle so the exit trap can take the whole cycle down with us: a
# `launchctl kickstart -k` (or any TERM) used to leave fetch.sh orphaned on PPID
# 1, where it kept writing dashboard.html and .cache underneath its replacement.
cycle_pid=""
cleanup() {
  if [ -n "$cycle_pid" ]; then
    kill -9 -"$cycle_pid" 2>/dev/null || kill -9 "$cycle_pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT
trap 'cleanup; exit 143' INT TERM

run_cycle() {
  local pid caf deadline
  # `set -m` puts the background job in its own process group whose PGID == its PID,
  # so a negative kill takes down fetch.sh and any gh child with it.
  set -m
  "$DIR/fetch.sh" &
  pid=$!
  cycle_pid=$pid
  set +m
  # Hold off idle sleep for the life of this cycle only (-i, so lid-close still
  # sleeps). A cycle interrupted halfway is the expensive failure: it leaves
  # half-open sockets that gh blocks on and caches that age out mid-fetch.
  caffeinate -i -w "$pid" &
  caf=$!
  # Wall clock, not a count of `sleep 1` iterations — the counter freezes while
  # the Mac is asleep, which is why a 240s ceiling let cycles run for 50 minutes.
  deadline=$(( $(date +%s) + CYCLE_TIMEOUT ))
  while kill -0 "$pid" 2>/dev/null && [ "$(date +%s)" -lt "$deadline" ]; do
    sleep 1
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -9 -"$pid" 2>/dev/null || kill -9 "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    log "[warn] cycle exceeded ${CYCLE_TIMEOUT}s, killed; will retry"
  else
    wait "$pid" || log "[warn] fetch failed, will retry"
  fi
  kill "$caf" 2>/dev/null || true
  wait "$caf" 2>/dev/null || true
  cycle_pid=""
}

log "watching: regenerating every ${INTERVAL}s (cycle cap ${CYCLE_TIMEOUT}s, pausing after ${IDLE_SKIP}s idle). Ctrl-C to stop."
paused=false
paused_since=0
while true; do
  if [ "$(idle_seconds)" -ge "$IDLE_SKIP" ]; then
    if [ "$paused" = false ]; then
      paused=true
      paused_since=$(date +%s)
      log "[info] idle for ${IDLE_SKIP}s; pausing until you're back"
    fi
    sleep "$IDLE_POLL"
    continue
  fi
  if [ "$paused" = true ]; then
    paused=false
    log "[info] resuming after $(( ( $(date +%s) - paused_since ) / 60 ))m idle/asleep"
  fi

  run_cycle

  # Deadline rather than `sleep $INTERVAL`: if the Mac sleeps through the wait it
  # is already past on wake, so the next cycle fires immediately instead of
  # serving a page that is however many hours stale.
  next=$(( $(date +%s) + INTERVAL ))
  while [ "$(date +%s)" -lt "$next" ]; do sleep 5; done
done
