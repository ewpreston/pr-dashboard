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
  longest-waiting PRs are at the top. See "What the queue hides" below.
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

## What the queue hides

The queue answers one question — *what is waiting on me right now* — so four
things are dropped outright. Note which two apply to picked-up PRs only:

| Dropped | Scope | Why |
|---|---|---|
| `EXCLUDE_URLS` | all | Hand-maintained exact URLs at the top of `fetch.sh`. Permanent. |
| Drafts | all | A draft is not asking to be reviewed yet. |
| `MUTED_URLS` | picked-up only | A draft review I will never finish — the one row the reviewed rule below cannot reach. Unlike `EXCLUDE_URLS`, a real review request still brings it back; remove the line to unmute. |
| **PRs I already reviewed** | picked-up only | Any submitted state — approved, commented, changes requested. Submitting a review is what finishing one looks like; if the author wants another pass they re-request me, and that arrives through the *direct* search, which this rule does not touch. |
| **Older than `PICKED_MAX_AGE_DAYS`** (30) | picked-up only | Otherwise `reviewed-by:@me` dredges up spec PRs commented on in 2017. |

My own PRs are dropped from all three sources too — `reviewed-by:@me` matches a
comment on my own PR, and a team request lands on me when I open a PR against a
team I am in. They belong in the right-hand column, not the queue.

What that leaves in the picked-up list is the case the `reviewed-by:@me` search
exists for: **a review I started and never submitted** (GitHub state `PENDING`).
Nobody routed that PR to me, so nothing will route it back — losing a
half-written review is the one failure this source prevents. Everything else it
returns is finished work, and finished work is not a queue.

The reviewed and age rules are scoped to the picked-up list on purpose. A direct
or team request is a live ask from a person: it is never hidden for being old,
and never for having been reviewed, because **a re-request is exactly how
someone says "look again"**.

Two rules were considered and rejected for this, both on real data:

- *Hide only what I approved.* Leaves every PR I commented on or sent back
  sitting in the queue with nothing for me to do on it.
- *Bring it back when someone responds after my review.* Sounds right, fails in
  practice: `ultra#18392` had a reply two days after my comment and would have
  stayed visible, which is precisely the row that prompted the rule.

Everything else is still **badged rather than filtered** — archived repos and
PRs sitting with the author stay in the list, because those are judgment calls
rather than answered questions.

A one-line receipt under the queue header says how many rows each rule removed
(`61 already reviewed · 1 muted hidden`), and the same line goes
to `watch.log`. A count, never a list: it proves the filter is working without
re-introducing what it removed. A queue whose length nobody can account for is
how this went wrong in the first place.

### Why this exists

Adding the `reviewed-by:@me` source (so half-reviewed stacks stop vanishing)
took the queue from 4 rows to **63**, of which 54 were already approved and the
oldest was from 2017. It also made the enrichment loop issue one `gh pr view`
per queue PR — 63 a cycle — pushing a cycle to ~250s against a 240s
`CYCLE_TIMEOUT`. Filtering before enrichment fixed both: the queue is 6 rows and
a cycle takes ~156s.

`reviewed-by:@me` is therefore fetched over **GraphQL**, not `gh search prs`:
each hit needs my own review state and the repo's archived flag, and REST search
returns neither. Learning them afterwards would cost one call per hit — 67 calls
to discover that 54 of them should be hidden. One GraphQL call answers it for
the whole list, and `search_reviewed_gql` shapes the rows to match the REST
search output exactly, so nothing downstream can tell which query it came from.

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
| `CACHE_MAX_AGE` | 3600s | oldest last-good search result still considered *current*; older ones are still served, flagged stale |
| `EMPTY_CONFIRM` | 2 | consecutive empty results required before an empty query is believed |
| `IDLE_SKIP` | 600s | HID idleness after which `watch.sh` stops fetching and lets the Mac sleep |
| `IDLE_POLL` | 30s | how often it re-checks idleness while paused |

Keep `CYCLE_TIMEOUT` below `INTERVAL` so a killed cycle still finishes before the
next one starts. Timeouts are logged to `watch.log` as `[warn]`. With
`SEARCH_DELAY` at 8s a healthy cycle takes roughly 156s — 13 searches is ~104s
of pure pacing, and the rest is the per-PR enrichment loop, which is why keeping
the queue small matters to the cycle budget and not just to the eye. Adding a
14th search would be the point to re-measure rather than assume.

`SEARCH_DELAY` was raised from 5s to 8s because at 5s the 7th search in the burst
(`blackboard-foundations/pd-team-daffy`, purely by position) 403'd three cycles
running. A query that fails *every* cycle never populates its cache, so it has no
fallback either — pacing is what actually prevents that, not the cache.

## Sleep (why the log has hour-long gaps, and why that's fine now)

The Mac idle-sleeps after 15 minutes (`pmset -g | grep sleep`). Before this was
handled, a 5-minute loop on a sleeping Mac only ran inside the 45-second DarkWake
windows, so a ~156s cycle got torn across three or four of them. Everything
downstream then failed in a way that looked like a GitHub problem:

- `read: connection reset by peer` — the interface went down mid-call.
- `timed out after 60s` — both watchdogs counted `sleep 1` iterations, which
  freeze during sleep, so a call suspended for two hours woke with its full 60s
  budget unspent and a dead socket to spend it on. Both now use wall-clock
  deadlines (`date +%s`), so a torn call or cycle is killed on the next wake.
- Queue sizes swinging 15 → 5 → 9 — `CACHE_MAX_AGE` is wall-clock, and at two
  cycles an hour every cache ages out. An over-age cache used to be refused,
  which silently removed real review requests from the queue.

Three changes, in `watch.sh` unless noted:

1. **Don't fetch while nobody is here.** Above `IDLE_SKIP` seconds of HID
   idleness the loop polls every `IDLE_POLL` instead of fetching, so the Mac
   sleeps normally. Touching the keyboard drops idle to zero and a cycle starts
   within `IDLE_POLL`. Pause and resume are logged.
2. **Don't tear a cycle in half.** A running cycle holds `caffeinate -i -w $pid`
   — idle sleep only, so lid-close still sleeps — and the wait between cycles is
   a wall-clock deadline, so if the Mac does sleep through it the next cycle
   fires immediately on wake instead of finishing out a stale timer.
3. **Serve an over-age cache rather than dropping it** (`fetch.sh`), counted as
   stale, with `staleAgeSec` in the page's health blob so the note says *how*
   old. An old review request labeled old is honest; one that vanishes is not.

A `TERM` to `watch.sh` (including `launchctl kickstart -k`) now kills the running
cycle's process group. It used to leave `fetch.sh` orphaned on PPID 1, writing
`dashboard.html` and `.cache` underneath its own replacement.

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


## Version control

This directory is a git repo. `dashboard.html`, `.cache/` and `watch.log` are
ignored; the scripts and this README are tracked, so any change here is
revertable (`git log`, `git revert <sha>`). Commit before experimenting.

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

Hour-long gaps between `fetching...` lines are **not** a fault on their own — the
loop pauses while the Mac is idle or asleep (see [Sleep](#sleep-why-the-log-has-hour-long-gaps-and-why-thats-fine-now)).
Look for the `[info] idle for …; pausing` / `[info] resuming after …` pair
bracketing the gap. A gap with no `pausing` line, or one that outlives your
sitting back down by more than a couple of minutes, is a real problem.
