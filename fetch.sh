#!/usr/bin/env bash
#
# pr-dashboard/fetch.sh
# Queries GitHub for every PR that is waiting on me (directly-requested review,
# team-requested review) plus my own open PRs, then regenerates dashboard.html.
#
# Requires: gh (authenticated), jq.
# Usage:    ./fetch.sh            # write dashboard.html next to this script
#           OUT=/tmp/x.html ./fetch.sh
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${OUT:-$DIR/dashboard.html}"
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

# --- config ------------------------------------------------------------------
# Teams I'm on, used for the team-review-requested query. Regenerate with:
#   gh api user/teams --jq '.[] | "\(.organization.login)/\(.slug)"'
TEAMS=(
  "1EdTech/contributingmembers"
  "blackboard-foundations/bb-arch-team"
  "blackboard-foundations/bb-cpe"
  "blackboard-foundations/bb-foundations"
  "blackboard-foundations/pd-team-daffy"
  "blackboard-innersource/pd-team-daffy"
  "blackboard-learn/engineering"
  "blackboard-learn/pd-team-cpe"
  "blackboard-learn/pd-team-cpe-learn"
  "blackboard-learn/pd-team-daffy"
)

# PRs to keep out of the review queue no matter what, by exact URL. This is now
# the ONLY hard drop — a deliberate, hand-maintained escape hatch. Everything
# else (drafts, archived repos, changes-requested-by-others) is shown and badged.
EXCLUDE_URLS=(
  # 1EdTech/lti-proposals #20 "Asset Processor". The repo was archived with the
  # review request still open, so the request can never be withdrawn, dismissed
  # or merged away — it would sit in the queue forever. Permanent, intentional.
  "https://github.com/1EdTech/lti-proposals/pull/20"
)

COMMON_JSON="repository,number,title,author,url,updatedAt,isDraft"

# Hard ceiling on every gh call. A laptop sleep or VPN drop leaves the TCP socket
# half-open: gh has no read timeout of its own, so it blocks forever and stalls
# the whole watch loop (launchd's KeepAlive can't help — the process is alive,
# just wedged). Coreutils `timeout` isn't on macOS by default, so run gh in the
# background and reap it ourselves.
GH_TIMEOUT="${GH_TIMEOUT:-60}"

# Pacing + retry for the search API. Search has a 30 req/min primary budget, but
# its *secondary* (burst) limit trips long before that is spent: this script
# fires one search per team plus two more back-to-back, and the last one in the
# burst came back `HTTP 403: secondary rate limit` while the primary budget still
# showed 16/30 left. That call was "my open PRs", so the column silently rendered
# empty and looked like good news. Space the searches out and retry the 403.
SEARCH_DELAY="${SEARCH_DELAY:-8}"
# Only one quick retry. GitHub's secondary limit asks you to wait *minutes*, so
# long in-cycle backoff just burns the cycle budget to still fail -- the last-good
# cache below is what actually keeps a section populated through a 403.
GH_RETRIES="${GH_RETRIES:-2}"
RETRY_BACKOFF="${RETRY_BACKOFF:-5}"

# Last-good cache. Each search's result is kept on disk, so a query that 403s
# this cycle reuses its previous result instead of blanking a whole section.
# Entries older than CACHE_MAX_AGE are refused: showing hour-old review requests
# as current would be its own kind of lie.
CACHE_DIR="${CACHE_DIR:-$DIR/.cache}"
CACHE_MAX_AGE="${CACHE_MAX_AGE:-3600}"
mkdir -p "$CACHE_DIR"

# How many consecutive empty results it takes to believe a query is really empty.
# Observed: the direct-review search returned `[]` with HTTP 200 during one cycle
# and 3 results a minute later -- GitHub's search index blinking under load. An
# empty 200 counts as success, so without this it would both blank the column and
# overwrite the last-good cache with the blank. Two cycles of agreement (~10 min)
# discards the blips while still reflecting a genuinely emptied queue promptly.
EMPTY_CONFIRM="${EMPTY_CONFIRM:-2}"

# gh_json <fallback-json> <gh args...> -- echoes gh's stdout, or the fallback on
# timeout/failure so one bad call degrades the dashboard instead of hanging it.
gh_json() {
  local fallback="$1"; shift
  local out err rc attempt=1 backoff pid waited
  while : ; do
    out="$(mktemp)"; err="$(mktemp)"
    gh "$@" >"$out" 2>"$err" &
    pid=$!
    waited=0
    while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt "$GH_TIMEOUT" ]; do
      sleep 1
      waited=$((waited + 1))
    done
    if kill -0 "$pid" 2>/dev/null; then
      kill -9 "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      echo "[$(date '+%H:%M:%S')] [warn] timed out after ${GH_TIMEOUT}s: gh $*" >&2
      rm -f "$out" "$err"
      printf '%s' "$fallback"
      return 0
    fi
    wait "$pid"; rc=$?
    if [ "$rc" -eq 0 ] && [ -s "$out" ]; then
      cat "$out"
      rm -f "$out" "$err"
      return 0
    fi
    # Retry just the transient shape -- GitHub's secondary/abuse rate limit is a
    # short burst penalty, so a few seconds of backoff clears it.
    if [ "$attempt" -lt "$GH_RETRIES" ] \
       && grep -qiE 'rate limit|HTTP 403|HTTP 429' "$err" 2>/dev/null; then
      backoff=$((attempt * RETRY_BACKOFF))
      echo "[$(date '+%H:%M:%S')] [warn] rate-limited, attempt ${attempt}/${GH_RETRIES}, retrying in ${backoff}s: gh $*" >&2
      rm -f "$out" "$err"
      sleep "$backoff"
      attempt=$((attempt + 1))
      continue
    fi
    # Retries exhausted, or a failure we should not retry. This branch used to be
    # silent, which is exactly why a 403 on the authored search left no trace in
    # watch.log -- always log before degrading.
    echo "[$(date '+%H:%M:%S')] [warn] failed (rc=$rc): gh $* :: $(tr '\n' ' ' <"$err" | cut -c1-200)" >&2
    rm -f "$out" "$err"
    printf '%s' "$fallback"
    return 0
  done
}

echo "[$(date '+%H:%M:%S')] fetching..." >&2

# Every search goes through here so the burst stays paced. The fallback is `null`
# rather than `[]` so callers can tell a failed query from a genuinely empty one
# -- that distinction is the whole point: a 403 used to look like "no PRs".
search_prs() {
  gh_json 'null' search prs "$@"
  sleep "$SEARCH_DELAY"
}

# failed_search <value> -- true when the search degraded rather than returned.
failed_search() { [ "$1" = "null" ] || [ -z "$1" ]; }

# cached_search <cache-key> <search args...>
# Echoes fresh results (refreshing the cache) and returns 0. On failure, echoes
# the last good result for this query and returns 1; echoes `null` and returns 1
# when there is no usable cache. Callers use `if out="$(cached_search ...)"` so
# the non-zero return does not trip `set -e`.
cached_search() {
  local key="$1"; shift
  local file="$CACHE_DIR/$key.json"
  local streakfile="$CACHE_DIR/$key.empty"
  local out age streak cached_len
  out="$(search_prs "$@")"

  # -- hard failure (403 / timeout / non-JSON): fall back to the cache ---------
  if failed_search "$out"; then
    if [ -s "$file" ]; then
      age=$(( $(date +%s) - $(stat -f %m "$file") ))
      if [ "$age" -le "$CACHE_MAX_AGE" ]; then
        echo "[$(date '+%H:%M:%S')] [info] $key failed; reusing cached copy (${age}s old)" >&2
        cat "$file"
        return 1
      fi
      echo "[$(date '+%H:%M:%S')] [warn] $key failed and its cache is ${age}s old (> ${CACHE_MAX_AGE}s); dropping" >&2
    fi
    printf 'null'
    return 1
  fi

  # -- succeeded, but empty: demand corroboration before believing it ---------
  if [ "$(jq 'length' <<<"$out" 2>/dev/null || echo 0)" = "0" ] && [ -s "$file" ]; then
    cached_len="$(jq 'length' <"$file" 2>/dev/null || echo 0)"
    age=$(( $(date +%s) - $(stat -f %m "$file") ))
    if [ "$cached_len" != "0" ] && [ "$age" -le "$CACHE_MAX_AGE" ]; then
      streak=$(( $(cat "$streakfile" 2>/dev/null || echo 0) + 1 ))
      printf '%s' "$streak" >"$streakfile"
      if [ "$streak" -lt "$EMPTY_CONFIRM" ]; then
        echo "[$(date '+%H:%M:%S')] [info] $key came back empty (${streak}/${EMPTY_CONFIRM}); keeping ${cached_len} cached result(s) pending confirmation" >&2
        cat "$file"
        return 1
      fi
      echo "[$(date '+%H:%M:%S')] [info] $key empty ${streak}x in a row; accepting it as real" >&2
    fi
  fi

  # -- accept the fresh result ------------------------------------------------
  rm -f "$streakfile"
  printf '%s' "$out" >"$file"
  printf '%s' "$out"
  return 0
}

# Per-cycle health: queries served from cache vs. ones with no data at all.
STALE_QUERIES=0
FAILED_QUERIES=0

# classify_query <value> -- bumps the counters and leaves the normalized JSON in
# CQ_RESULT. Call only on the failure path (cached_search returned non-zero).
#
# Sets a global instead of echoing on purpose: `x="$(classify_query ...)"` would
# run it in a subshell, and the counter increments would be discarded with it --
# which is precisely how this reported `failedQueries: 0` alongside two logged
# 403s. Callers must run it in the parent shell.
classify_query() {
  if failed_search "$1"; then
    FAILED_QUERIES=$((FAILED_QUERIES + 1))
    CQ_RESULT='[]'
  else
    STALE_QUERIES=$((STALE_QUERIES + 1))
    CQ_RESULT="$1"
  fi
}

# --- 1. review requested directly of me --------------------------------------
DIRECT_FAILED=false
DIRECT_STALE=false
if DIRECT="$(cached_search direct --review-requested=@me --state=open --limit 100 \
  --json "$COMMON_JSON")"; then :; else
  if failed_search "$DIRECT"; then DIRECT_FAILED=true; else DIRECT_STALE=true; fi
  classify_query "$DIRECT"; DIRECT="$CQ_RESULT"
fi

# --- 1a. PRs I authored ------------------------------------------------------
# Deliberately fetched BEFORE the ten team queries. This search used to run dead
# last, so when the search burst tripped GitHub's secondary rate limit it was
# always the call that lost -- "My open PRs" was empty every time while the
# review queue, fetched earlier, looked fine. Enrichment stays in section 3;
# it uses the core API, which has budget to spare.
AUTHORED_FAILED=false
AUTHORED_STALE=false
if AUTHORED="$(cached_search authored --author=@me --state=open --limit 50 \
  --json repository,number)"; then :; else
  if failed_search "$AUTHORED"; then AUTHORED_FAILED=true; else AUTHORED_STALE=true; fi
  classify_query "$AUTHORED"; AUTHORED="$CQ_RESULT"
fi

# --- 1b. PRs I have already reviewed -----------------------------------------
# Not everything I review is routed to me: a PR I picked up because someone asked
# in chat has no review request and no team on it, so sections 1 and 2 never see
# it and it silently drops off the queue the moment I engage with it. That is the
# worst time to lose one -- a half-reviewed stack is exactly what needs tracking.
#
# Placed with the other early searches for the reason section 1a documents: the
# tail of the burst is what loses to the secondary rate limit, and this list now
# carries the stack view, so it should not be the call that degrades.
REVIEWED_FAILED=false
REVIEWED_STALE=false
if REVIEWED="$(cached_search reviewed --reviewed-by=@me --state=open --limit 100 \
  --json "$COMMON_JSON")"; then :; else
  if failed_search "$REVIEWED"; then REVIEWED_FAILED=true; else REVIEWED_STALE=true; fi
  classify_query "$REVIEWED"; REVIEWED="$CQ_RESULT"
fi

# --- 2. review requested of my teams -----------------------------------------
# team-review-requested can't be OR-ed in one query (gh wraps the whole string
# as a single qualifier), so query each team and merge. De-dupe (against each
# other and the direct list) happens client-side in the HTML, keyed on url.
TEAMPRS='[]'
for t in "${TEAMS[@]}"; do
  if one="$(cached_search "team-${t//\//_}" --state=open --limit 100 \
    --json "$COMMON_JSON" "team-review-requested:$t")"; then :; else
    classify_query "$one"; one="$CQ_RESULT"
  fi
  TEAMPRS="$(jq -s '.[0] + .[1]' <(echo "$TEAMPRS") <(echo "$one"))"
done

# --- 2a. manual opt-out (the only hard drop) ---------------------------------
# The queue deliberately shows EVERY PR I'm a reviewer on. It used to hard-drop
# drafts and archived-repo PRs and collapse the ones another reviewer had already
# sent back; all three are now surfaced as badges instead (computed in 2b) so the
# triage signal survives without anything disappearing from the list.
DROP_URLS="$(printf '%s\n' "${EXCLUDE_URLS[@]+"${EXCLUDE_URLS[@]}"}" \
  | jq -R 'select(length > 0)' | jq -s '.')"

filter_queue() {
  jq --argjson drop "$DROP_URLS" \
    '[ .[] | select( .url as $u | $drop | index($u) | not ) ]'
}
DIRECT="$(filter_queue <<<"$DIRECT")"
TEAMPRS="$(filter_queue <<<"$TEAMPRS")"
REVIEWED="$(filter_queue <<<"$REVIEWED")"

MY_LOGIN="$(gh_json '' api user --jq '.login')"
# No login means auth or the network is down; a blank would silently mangle the
# "is this mine?" filters below, so fail the cycle and let the watcher retry.
if [ -z "$MY_LOGIN" ]; then
  echo "[$(date '+%H:%M:%S')] [warn] could not resolve gh login; leaving dashboard.html untouched" >&2
  exit 1
fi

# --- 2b. enrich review-queue PRs with triage badges --------------------------
# Everything computed here is DISPLAY metadata — none of it removes a PR from the
# queue. Per unique PR waiting on me:
#   - changesRequestedByOther / iEngaged: another reviewer already sent it back
#     and I haven't weighed in, so the ball is probably with the author
#   - archived: the repo is archived, so the PR's status can never change
#
# The archived check needs one API call per distinct repo, so memoize it: a
# repo's archived flag is stable and the queue spans only a handful of repos.
declare -A REPO_ARCHIVED=()
is_archived() {
  local repo="$1"
  if [ -z "${REPO_ARCHIVED[$repo]+set}" ]; then
    local v
    # Default to "false" on any failure — a VPN drop should not mislabel a live repo.
    v="$(gh_json 'false' api "repos/$repo" --jq '.archived')"
    [ "$v" = "true" ] || v="false"
    REPO_ARCHIVED[$repo]="$v"
    if [ "$v" = "true" ]; then
      echo "[$(date '+%H:%M:%S')] [info] $repo is archived; badging its PRs" >&2
    fi
  fi
  [ "${REPO_ARCHIVED[$repo]}" = "true" ]
}

REVIEW_META='{}'
while IFS=$'\t' read -r repo num url; do
  [ -z "$url" ] && continue
  if is_archived "$repo"; then archived=true; else archived=false; fi
  # head/base ride along on the call we already make. `gh search prs` cannot return
  # them -- they are not in its --json field set -- and a second per-PR call would
  # double this loop's request count for data this one can carry for free. Given
  # the secondary-rate-limit history above, free is the only acceptable price.
  meta="$(gh_json '{}' pr view "$num" --repo "$repo" \
    --json reviews,comments,headRefName,baseRefName)"
  flags="$(jq -n --argjson m "$meta" --arg me "$MY_LOGIN" --argjson archived "$archived" '
    ( $m.reviews  // [] ) as $rv |
    ( $m.comments // [] ) as $cm |
    {
      archived: $archived,
      headRefName: $m.headRefName,
      baseRefName: $m.baseRefName,
      changesRequestedByOther:
        ( [ $rv[] | select( .author.login != $me and .state == "CHANGES_REQUESTED" ) ] | length > 0 ),
      iEngaged:
        ( ( [ $rv[] | select( .author.login == $me ) ] | length > 0 )
          or ( [ $cm[] | select( .author.login == $me ) ] | length > 0 ) )
    }' 2>/dev/null || echo '{}')"
  REVIEW_META="$(jq --arg u "$url" --argjson f "$flags" '. + {($u): $f}' <<<"$REVIEW_META")"
done < <(jq -rs 'add | map( {repo: .repository.nameWithOwner, number: .number, url: .url} )
                 | unique_by(.url) | .[] | "\(.repo)\t\(.number)\t\(.url)"' \
           <(echo "$DIRECT") <(echo "$TEAMPRS") <(echo "$REVIEWED"))

# --- 3. enrich my authored PRs with review + CI state ------------------------
# The search itself happened in 1a; this only decorates it. Enrichment failures
# are counted, not swallowed -- a dropped PR here also means the column is
# understating reality, and the page says so.
AUTHORED_FULL='[]'
AUTHORED_DROPPED=0
while IFS=$'\t' read -r repo num; do
  [ -z "$repo" ] && continue
  pr="$(gh_json '{}' pr view "$num" --repo "$repo" \
    --json number,title,url,updatedAt,isDraft,reviewDecision,statusCheckRollup,author,headRefName,baseRefName)"
  if [ "$pr" = "{}" ]; then
    AUTHORED_DROPPED=$((AUTHORED_DROPPED + 1))
    continue
  fi
  pr="$(jq --arg r "$repo" '. + {repoName:$r}' <<<"$pr")"
  AUTHORED_FULL="$(jq --argjson p "$pr" '. + [$p]' <<<"$AUTHORED_FULL")"
done < <(jq -r '.[] | "\(.repository.nameWithOwner)\t\(.number)"' <<<"$AUTHORED")

# --- assemble one JSON payload for the HTML generator ------------------------
NOW="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

# Which queries degraded this cycle. The page needs this to avoid the failure
# mode that started all of it: an empty column that reads as "nothing to do".
FETCH_ERRORS="$(jq -n \
  --argjson authored "$AUTHORED_FAILED" \
  --argjson authoredStale "$AUTHORED_STALE" \
  --argjson direct "$DIRECT_FAILED" \
  --argjson directStale "$DIRECT_STALE" \
  --argjson reviewed "$REVIEWED_FAILED" \
  --argjson reviewedStale "$REVIEWED_STALE" \
  --argjson staleQueries "$STALE_QUERIES" \
  --argjson failedQueries "$FAILED_QUERIES" \
  --argjson dropped "$AUTHORED_DROPPED" \
  '{authored: $authored, authoredStale: $authoredStale,
    direct: $direct, directStale: $directStale,
    reviewed: $reviewed, reviewedStale: $reviewedStale,
    staleQueries: $staleQueries, failedQueries: $failedQueries,
    authoredDropped: $dropped}')"

jq -n \
  --argjson direct "$DIRECT" \
  --argjson teamprs "$TEAMPRS" \
  --argjson reviewed "$REVIEWED" \
  --argjson authored "$AUTHORED_FULL" \
  --argjson reviewMeta "$REVIEW_META" \
  --argjson fetchErrors "$FETCH_ERRORS" \
  --arg me "$MY_LOGIN" \
  --arg now "$NOW" \
  '{
     generatedAt: $now,
     me: $me,
     # team PRs minus my own authored ones; dedupe of direct happens in JS
     reviewTeam: ($teamprs | map(select(.author.login != $me))),
     reviewDirect: $direct,
     # reviewed-by:@me cannot return my own PRs (you cannot review your own), but
     # filter anyway so a future qualifier change cannot double-list a PR in both
     # columns -- the same guard reviewTeam carries, for the same reason.
     reviewReviewed: ($reviewed | map(select(.author.login != $me))),
     reviewMeta: $reviewMeta,
     authored: $authored,
     fetchErrors: $fetchErrors
   }' > "$TMP"

# --- render HTML -------------------------------------------------------------
DATA="$(cat "$TMP")" "$DIR/render.sh" > "$OUT"
echo "[$(date '+%H:%M:%S')] wrote $OUT" >&2
