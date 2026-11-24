#!/usr/bin/env bash
#
# pr-dashboard/watch.sh
# Keeps dashboard.html live, modeled on blackboard-learn/varju-github-dashboard:
# a cheap notifications check every POLL_INTERVAL (poll.sh), and a full fetch.sh
# cycle only when it reports new activity on a PR I'm involved in, plus a full
# cycle every FULL_INTERVAL regardless, as the backstop for changes that raise
# no notification (CI finishing on my PRs, a teammate approving a team request,
# a muted thread). The page meta-refreshes every POLL_INTERVAL.
#
# Usage:  ./watch.sh                                # poll 60s, full fetch every 10 min
#         POLL_INTERVAL=120 FULL_INTERVAL=1800 ./watch.sh
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACHE_DIR="${CACHE_DIR:-$DIR/.cache}"
OUT="${OUT:-$DIR/dashboard.html}"
# INTERVAL is the old name, still honored so an older plist keeps working.
POLL_INTERVAL="${POLL_INTERVAL:-${INTERVAL:-60}}"
FULL_INTERVAL="${FULL_INTERVAL:-600}"
export REFRESH="$POLL_INTERVAL"

# Whole-cycle ceiling. fetch.sh caps each individual gh call, but it makes one
# call per PR while enriching, so a slow-but-not-hung network could still outrun
# the interval. Kill the cycle and everything it spawned, then start clean.
# (No `setsid` on macOS — bash's own job control gives us the process group:
# run fetch.sh in a monitored subshell so `kill -PGID` reaches its gh children.)
CYCLE_TIMEOUT="${CYCLE_TIMEOUT:-240}"

# The page warns when the last successful check is older than this. Every quiet
# poll re-renders the page with a new check time (heartbeat), so the longest a
# healthy watcher goes without one is a poll gap plus a full cycle (~60s + ~156s).
# 3 polls plus the cycle cap leaves room for a missed poll and a slow cycle.
export STALE_AFTER="${STALE_AFTER:-$(( POLL_INTERVAL * 3 + CYCLE_TIMEOUT ))}"

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

# Re-render the page from the last full cycle's payload with a new check time,
# so the stale banner knows the watcher is alive. No GitHub calls. Same
# temp-file-and-rename as fetch.sh, so the browser never reloads onto half a page.
heartbeat() {
  local data="$CACHE_DIR/last-data.json" tmp="$OUT.tmp.$$"
  [ -s "$data" ] || return 0
  if CHECKED_AT="$(( $(date +%s) * 1000 ))" DATA="$(cat "$data")" "$DIR/render.sh" >"$tmp"; then
    mv "$tmp" "$OUT"
  else
    rm -f "$tmp"
    log "[warn] heartbeat re-render failed"
  fi
}

log "watching: checking notifications every ${POLL_INTERVAL}s, full fetch on activity or every ${FULL_INTERVAL}s (cycle cap ${CYCLE_TIMEOUT}s, pausing after ${IDLE_SKIP}s idle). Ctrl-C to stop."
paused=false
paused_since=0
force_full=true   # startup: the page may be any age, so fetch before polling
last_full=0
poll_errors=0
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
    force_full=true   # nothing was polled while away, so the page is behind
  fi

  # Poll on every pass, even one that will run a full cycle anyway: it moves the
  # "seen" marker up to now, so activity the full cycle is about to pick up does
  # not come back on the next poll and trigger a second, redundant cycle.
  wait_for=$POLL_INTERVAL
  why=""
  polled_ok=false
  result="$("$DIR/poll.sh")" || result="error $POLL_INTERVAL poll.sh exited nonzero"
  read -r kind gh_interval rest <<<"$result" || true
  # Never poll faster than GitHub's X-Poll-Interval asks.
  if [[ "$gh_interval" =~ ^[0-9]+$ ]] && [ "$gh_interval" -gt "$wait_for" ]; then
    wait_for=$gh_interval
  fi
  case "$kind" in
    fresh)
      poll_errors=0; polled_ok=true
      why="activity: $rest"
      ;;
    quiet|baseline)
      poll_errors=0; polled_ok=true
      ;;
    *)
      # Log the first failure and then every 10th, so a long VPN drop doesn't
      # write a line a minute.
      poll_errors=$(( poll_errors + 1 ))
      if [ "$poll_errors" -eq 1 ] || [ $(( poll_errors % 10 )) -eq 0 ]; then
        log "[warn] notifications check failed (${poll_errors}x): ${rest:-$result}"
      fi
      ;;
  esac
  if [ "$force_full" = true ]; then
    why="startup/resume"
  elif [ -z "$why" ] && [ $(( $(date +%s) - last_full )) -ge "$FULL_INTERVAL" ]; then
    why="backstop, ${FULL_INTERVAL}s since last full fetch"
  fi

  if [ -z "$why" ]; then
    # No heartbeat on a failed check: if GitHub stays unreachable the page
    # should go stale and say so.
    if [ "$polled_ok" = true ]; then heartbeat; fi
  else
    log "full fetch: $why"
    last_full=$(date +%s)
    force_full=false
    run_cycle
  fi

  # Deadline rather than `sleep`: if the Mac sleeps through the wait it is
  # already past on wake, so the next check fires immediately instead of
  # serving a page that is however many hours stale.
  next=$(( $(date +%s) + wait_for ))
  while [ "$(date +%s)" -lt "$next" ]; do sleep 5; done
done
