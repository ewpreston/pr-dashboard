# PR Review Dashboard

A live, self-contained HTML dashboard of every PR waiting on you across all your
GitHub orgs, plus your own open PRs with review + CI status.

## Requirements
- `gh` CLI, authenticated (`gh auth status`) with `read:org` + `repo` scopes
- `jq`

## Use

```sh
# one-off snapshot
./fetch.sh && open dashboard.html

# live: regenerate every 5 min while the tab stays open (meta-refresh reloads it)
./watch.sh
# or a tighter loop:
INTERVAL=120 ./watch.sh
```

Open `dashboard.html` in a browser and leave the tab up. `watch.sh` rewrites the
file on each interval; the page's `<meta refresh>` reloads it, so it stays current.

## What it shows
- **Needs my review** — PRs where I'm a directly-requested reviewer, *or* a team
  I'm on is requested, *or* **I have already reviewed it** (`reviewed-by:@me`).
  That third source exists because not everything I review is routed to me: a PR
  I picked up because someone asked in chat has no request and no team on it, so
  it used to vanish from the queue the moment I engaged with it — the worst
  possible time to lose one. Those rows carry a **picked up** badge, since nobody
  will re-route them to me if I forget.
  Merged and de-duped by URL, sorted **oldest-first** so the
  longest-waiting PRs are at the top. **Nothing is filtered out**: drafts,
  archived-repo PRs and PRs another reviewer has already sent back all appear,
  each carrying a badge (`DRAFT`, `ARCHIVED REPO`, `with author`) rather than
  being hidden. The single exception is the hand-maintained `EXCLUDE_URLS` array
  at the top of `fetch.sh`.
- **My open PRs** — my authored PRs with review decision (approved / changes
  requested / review required) and a rolled-up CI status, so I can see what's
  blocked on others vs. on me.
- **Stacks** — PRs that build on each other are drawn as one block with a teal
  rail, a `N-PR stack` header naming the branch the whole stack lands on, and a
  `stack 2/5` badge per row. The bottom PR is badged **review first**; every other
  row says which PR it sits **on**. See "How stacking is worked out" below.
- **Review button** on every row in both columns — copies
  `/code-review medium <pr-url>` to the clipboard to paste into a Claude session.
  Deliberately clipboard-only: a `file://` page can't run `claude`, and nothing
  should post to someone else's PR unattended.

## How stacking is worked out

GitHub does not model stacks. A PR records only a base-branch *string*, so the
chain is reconstructed in the page: **PR A is the parent of PR B when A's head
branch is B's base branch, in the same repo.** Everything else — depth, position,
which one to read first — falls out of that.

Three things worth knowing:

- **It costs no extra API calls.** `gh search prs` cannot return `headRefName` /
  `baseRefName` (they are not in its `--json` field set), but `fetch.sh` already
  makes one `gh pr view` per PR to work out review state, so the two fields ride
  along on a request that was happening anyway. Given the rate-limit history
  below, that was the only acceptable price.
- **The index spans both columns.** A stack can straddle them — your PR on top of
  one of mine, or a root you are not a reviewer on — and a stack that appeared to
  start in the middle would be worse than no grouping at all.
- **A block is placed by its oldest member, never its newest.** Sorting a stack by
  its tip would let it jump the queue every time someone pushed to the top PR,
  which is the opposite of what oldest-first is for. Order *within* a stack is
  always bottom-up, in both columns.

Limitations, all deliberate:

- A stack that **branches** (two PRs based on the same parent) is shown flattened,
  with both children at the same indent. The indent tells the truth; the `2/5`
  numbering reads as a sequence it is not. Rare enough not to be worth a tree.
- A PR whose parent is **already merged or closed** becomes a root, which is
  correct — there is nothing left to review under it.
- Depth indent caps at 6 levels. The position badge still carries the real number.
- Branch renames between fetches could in principle form a cycle; every walk is
  bounded by the population size, so the worst case is a wrong badge rather than
  a hung page.

Staleness badge colors: green ≤2 days, amber ≤7 days, red older (time since last
update).

- **Stale-data banner** — if the data is older than 3 refresh intervals, a red
  banner appears at the top saying so. The page meta-refreshes whether or not the
  generator is still alive, so without this a wedged watcher just serves old data
  that looks current.

## Timeouts (why the watcher can't wedge any more)

`gh` has no read timeout of its own. If the laptop sleeps or the VPN drops, the
TCP socket is left half-open and `gh` blocks **forever** — which once stalled the
whole loop for three days. launchd's `KeepAlive` does not help: the process is
alive, just stuck.

Independent ceilings guard it, plus the pacing and retry knobs the search API
needs (see the section below):

| Knob | Default | What it caps |
|---|---|---|
| `GH_TIMEOUT` | 60s | any single `gh` call (`fetch.sh`); on timeout that query degrades to empty rather than hanging |
| `CYCLE_TIMEOUT` | 240s | a whole `fetch.sh` cycle (`watch.sh`), killed by process group so no orphan `gh` survives |
| `SEARCH_DELAY` | 8s | gap between consecutive **search** calls, to stay under the secondary rate limit |
| `GH_RETRIES` | 2 | attempts per `gh` call; only rate-limit failures are retried |
| `RETRY_BACKOFF` | 5s | multiplied by attempt number, so attempt 2 waits 5s |
| `CACHE_MAX_AGE` | 3600s | oldest last-good search result still considered usable |
| `EMPTY_CONFIRM` | 2 | consecutive empty results required before an empty query is believed |

Keep `CYCLE_TIMEOUT` below `INTERVAL` so a killed cycle still finishes before the
next one starts. Timeouts are logged to `watch.log` as `[warn]`. With
`SEARCH_DELAY` at 8s a healthy cycle takes roughly 160s (it was ~150s before
`reviewed-by:@me` added a 13th search), so the 240s ceiling still has room for a
retry or two — but the margin is now one search thinner. Adding a 14th would be
the point to re-measure rather than assume.

`SEARCH_DELAY` was raised from 5s to 8s because at 5s the 7th search in the burst
(`blackboard-foundations/pd-team-daffy`, purely by position) 403'd three cycles
running. A query that fails *every* cycle never populates its cache, so it has no
fallback either — pacing is what actually prevents that, not the cache.

## Search rate limiting (why "My open PRs" once went blank)

The search API allows 30 requests/minute, but its **secondary** (burst) limit
trips well before that budget is spent. One cycle issues one search per team plus
three more — 13 back-to-back — and the tail of that burst got
`HTTP 403: You have exceeded a secondary rate limit` while the *primary* budget
still showed 16/30 remaining.

Three things went wrong at once, and all three are fixed:

1. **The authored search ran last**, so it was always the call that lost the
   burst. "My open PRs" rendered empty every cycle while the review queue, which
   is fetched earlier, looked perfectly healthy. It now runs **second**, right
   after the direct-review query.
2. **`gh_json` logged nothing on a non-timeout failure.** A 403 silently
   degraded to the `[]` fallback, so `watch.log` held no trace and the page had
   no idea. Every failure is now logged before it degrades.
3. **An empty list was indistinguishable from a failed query.** The page said
   "No open PRs." — which reads as reassurance. It now distinguishes three
   states: real data, last-good data (amber note), and failed with no usable
   cache (red note).

`fetch.sh` keeps the last good result of every search in `.cache/`. A query that
gets rate-limited reuses its previous result rather than blanking a section, and
the page marks that column as possibly a cycle behind. Entries older than
`CACHE_MAX_AGE` are refused — hour-old review requests shown as current would be
its own kind of lie. Delete `.cache/` at any time; it refills on the next cycle.

### Empty results are not trusted on the first sighting

Rate limiting is not the only way this API lies. The direct-review search was
observed returning `[]` with **HTTP 200** during one cycle and three results a
minute later — the search index blinking under load. An empty 200 counts as
success, so it would otherwise blank a column *and* overwrite the last-good cache
with the blank.

So an empty result that contradicts a fresh non-empty cache is held for
`EMPTY_CONFIRM` (2) consecutive cycles before being accepted. A blip is
discarded; a queue you genuinely cleared shows as empty within ~10 minutes.
Related: the authored search has also been seen returning 3 of 6 PRs. Partial
results are indistinguishable from real ones, so nothing guards them — if a
column looks short, re-check the next cycle before believing it.

Note that running `./fetch.sh` by hand **while the LaunchAgent is also running**
doubles the burst and will cause 403s that would not otherwise happen. Stop the
agent first, or just read the dashboard the agent already writes.


## Files
- `fetch.sh` — queries GitHub, writes `dashboard.html`. Edit the `TEAMS` array
  when your team memberships change:
  `gh api user/teams --jq '.[] | "\(.organization.login)/\(.slug)"'`
- `render.sh` — turns the fetched JSON into HTML (called by `fetch.sh`).
- `.cache/` — last-good result per search, used when a query is rate-limited.
- `watch.sh` — regenerates on an interval.

## Background service (launchd) — installed

A LaunchAgent runs `watch.sh` headless: it starts at login, regenerates every
5 min, restarts itself if it dies, and needs no open terminal. Just keep
`dashboard.html` open in a browser tab (bookmark the `file://` URL).

Plist: `~/Library/LaunchAgents/com.ewpreston.pr-dashboard.plist`
Logs:  `~/pr-dashboard/watch.log`

### Manage it
```sh
# status (PID in col 1, last exit code in col 2)
launchctl list | grep pr-dashboard

# stop / start
launchctl unload ~/Library/LaunchAgents/com.ewpreston.pr-dashboard.plist
launchctl load   ~/Library/LaunchAgents/com.ewpreston.pr-dashboard.plist

# change interval: edit INTERVAL in the plist, then unload + load

# uninstall completely
launchctl unload ~/Library/LaunchAgents/com.ewpreston.pr-dashboard.plist
rm ~/Library/LaunchAgents/com.ewpreston.pr-dashboard.plist
```

Note: after editing `fetch.sh`/`render.sh`, no reload is needed (the running
loop re-invokes them each cycle). After editing **`watch.sh`** or the **plist**,
unload + load — `watch.sh` *is* the running process, so it doesn't pick up its
own edits.

### If the dashboard stops updating

```sh
tail -20 ~/pr-dashboard/watch.log          # last cycle + any [warn] lines
ps -ax -o pid,etime,command | grep fetch.sh # a cycle older than CYCLE_TIMEOUT is wedged
```

A `fetch.sh` or `gh` process with a multi-hour `ELAPSED` is the tell. That should
no longer happen, but if it does: unload + load the agent, then check whether the
timeouts fired in the log.
