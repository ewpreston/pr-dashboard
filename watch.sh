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

echo "watching: regenerating every ${INTERVAL}s (cycle cap ${CYCLE_TIMEOUT}s). Ctrl-C to stop." >&2
while true; do
  # `set -m` puts the background job in its own process group whose PGID == its PID,
  # so a negative kill takes down fetch.sh and any gh child with it.
  set -m
  "$DIR/fetch.sh" &
  pid=$!
  set +m
  waited=0
  while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt "$CYCLE_TIMEOUT" ]; do
    sleep 1
    waited=$((waited + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -9 -"$pid" 2>/dev/null || kill -9 "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    echo "[$(date '+%H:%M:%S')] [warn] cycle exceeded ${CYCLE_TIMEOUT}s, killed; will retry" >&2
  else
    wait "$pid" || echo "[$(date '+%H:%M:%S')] [warn] fetch failed, will retry" >&2
  fi
  sleep "$INTERVAL"
done
