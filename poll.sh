#!/usr/bin/env bash
#
# pr-dashboard/poll.sh
# One cheap check of GitHub notifications: has any PR thread I'm involved in
# (review requested, mention, comment, author, assign...) had activity since the
# last check? watch.sh calls this every POLL_INTERVAL and runs a full fetch.sh
# cycle only when the answer is yes. Same idea as the notifications poller in
# blackboard-learn/varju-github-dashboard.
#
# Why it is cheap: the request carries the previous response's ETag as
# If-None-Match, and GitHub answers 304 Not Modified when nothing changed. A 304
# does not count against the rate limit. If-Modified-Since does NOT work here
# (measured: GitHub answers 200 to it every time), so this keys on the ETag only.
#
# Prints exactly one line on stdout and always exits 0:
#   quiet    <poll-interval>                       nothing new (304, or 200 with nothing newer)
#   baseline <poll-interval>                       first check; recorded a starting point
#   fresh    <poll-interval> <count> <summary...>  new PR activity, so run a full cycle
#   error    <poll-interval> <message...>          the check itself failed
# <poll-interval> is GitHub's X-Poll-Interval, its requested minimum cadence.
#
# State in $CACHE_DIR: notif.etag (for If-None-Match) and notif.since (the newest
# PR-thread updated_at seen so far; anything newer is "fresh").
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACHE_DIR="${CACHE_DIR:-$DIR/.cache}"
POLL_TIMEOUT="${POLL_TIMEOUT:-30}"
DEFAULT_INTERVAL=60
ETAG_FILE="$CACHE_DIR/notif.etag"
SINCE_FILE="$CACHE_DIR/notif.since"
mkdir -p "$CACHE_DIR"

out="$(mktemp)"; err="$(mktemp)"
trap 'rm -f "$out" "$err"' EXIT

args=(api -i 'notifications?all=true&per_page=50')
etag="$(cat "$ETAG_FILE" 2>/dev/null || true)"
if [ -n "$etag" ]; then args+=(-H "If-None-Match: $etag"); fi

# Same wall-clock ceiling as fetch.sh's gh_json: gh has no read timeout, and a
# half-open socket after sleep or a VPN drop would otherwise block forever.
gh "${args[@]}" >"$out" 2>"$err" &
pid=$!
deadline=$(( $(date +%s) + POLL_TIMEOUT ))
while kill -0 "$pid" 2>/dev/null && [ "$(date +%s)" -lt "$deadline" ]; do sleep 1; done
if kill -0 "$pid" 2>/dev/null; then
  kill -9 "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  echo "error $DEFAULT_INTERVAL timed out after ${POLL_TIMEOUT}s"
  exit 0
fi
# gh exits 1 on a 304, so the status line decides, not the exit code.
wait "$pid" 2>/dev/null || true

header() { grep -i -m1 "^$1:" "$out" | cut -d' ' -f2- | tr -d '\r' || true; }
status="$(head -1 "$out" | awk '{print $2}')"
interval="$(header x-poll-interval)"
case "$interval" in ''|*[!0-9]*) interval=$DEFAULT_INTERVAL ;; esac

case "$status" in
  304) echo "quiet $interval"; exit 0 ;;
  200) ;;
  *)   echo "error $interval HTTP ${status:-none}: $(tr '\n' ' ' <"$err" | cut -c1-200)"; exit 0 ;;
esac

# Body follows the first blank line of `gh api -i` output.
body="$(awk 'f {print} !f && /^\r?$/ {f=1}' "$out")"
prs="$(jq -c '[.[] | select(.subject.type == "PullRequest")
               | {updated_at, reason,
                  ref: (.repository.full_name + "#" + (.subject.url | split("/") | last))}]' \
         <<<"$body" 2>/dev/null)" || { echo "error $interval unparseable notifications response"; exit 0; }
newest="$(jq -r 'map(.updated_at) | max // empty' <<<"$prs")"
since="$(cat "$SINCE_FILE" 2>/dev/null || true)"

# The ETag is written last in every branch, so a run that dies before recording
# `since` asks again next time instead of getting a 304 and missing the activity.
save_etag() {
  local e; e="$(header etag)"
  if [ -n "$e" ]; then printf '%s' "$e" >"$ETAG_FILE"; fi
}

if [ -z "$since" ]; then
  # First check: record where we are, replay nothing (watch.sh does a full
  # cycle on startup anyway).
  printf '%s' "${newest:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}" >"$SINCE_FILE"
  save_etag
  echo "baseline $interval"
  exit 0
fi

# ISO-8601 UTC timestamps compare correctly as strings.
fresh="$(jq -c --arg s "$since" 'map(select(.updated_at > $s))' <<<"$prs")"
count="$(jq 'length' <<<"$fresh")"
if [ -n "$newest" ] && [[ "$newest" > "$since" ]]; then printf '%s' "$newest" >"$SINCE_FILE"; fi
save_etag

if [ "$count" -eq 0 ]; then
  # 200 with nothing newer: a thread was marked read, or a non-PR thread moved.
  echo "quiet $interval"
else
  echo "fresh $interval $count $(jq -r 'map(.ref + " (" + .reason + ")") | .[:3] | join(", ")' <<<"$fresh")"
fi
