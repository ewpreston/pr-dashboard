#!/usr/bin/env bash
#
# pr-dashboard/render.sh
# Emits a self-contained HTML dashboard to stdout. Reads the JSON payload from
# the DATA env var (set by fetch.sh). The page meta-refreshes so that whenever
# fetch.sh regenerates the file, the browser picks it up automatically.
#
# Implementation note: the template is a QUOTED heredoc so the shell leaves the
# JS template literals (${...}) untouched. The real values we inject
# (__REFRESH__, __STALE_AFTER__, __CHECKED_AT__, __DATA__) are placeholders swapped in afterward.
set -euo pipefail

REFRESH="${REFRESH:-60}"    # seconds; must match the watcher interval
STALE_AFTER="${STALE_AFTER:-$(( REFRESH * 3 + 240 ))}"  # set by watch.sh
# Epoch ms of the last successful check for activity (watch.sh's heartbeat
# re-render). Empty means "same as generatedAt", i.e. a fresh full fetch.
CHECKED_AT="${CHECKED_AT:-}"
DATA="${DATA:?render.sh expects the DATA env var}"

TEMPLATE="$(cat <<'HTML'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="refresh" content="__REFRESH__">
<title>PR Review Dashboard</title>
<!-- Inline owl-face favicon (data URI so it survives render.sh regeneration; bold shapes read at 16px). -->
<link rel="icon" type="image/svg+xml" href="data:image/svg+xml,%3Csvg%20xmlns='http://www.w3.org/2000/svg'%20viewBox='0%200%2064%2064'%3E%3Crect%20width='64'%20height='64'%20rx='14'%20fill='%2312d3c4'/%3E%3Cpath%20d='M14%2016%20L26%2026%20M50%2016%20L38%2026'%20stroke='%23074f49'%20stroke-width='6'%20stroke-linecap='round'/%3E%3Cpath%20d='M32%2014c-13%200-21%209-21%2022s9%2016%2021%2016%2021-3%2021-16-8-22-21-22z'%20fill='%23085d55'/%3E%3Ccircle%20cx='23'%20cy='31'%20r='11'%20fill='%23fff'/%3E%3Ccircle%20cx='41'%20cy='31'%20r='11'%20fill='%23fff'/%3E%3Ccircle%20cx='23'%20cy='31'%20r='5'%20fill='%23161b22'/%3E%3Ccircle%20cx='41'%20cy='31'%20r='5'%20fill='%23161b22'/%3E%3Cpath%20d='M32%2038 l-5%207 h10 z'%20fill='%2312d3c4'/%3E%3C/svg%3E">
<link rel="alternate icon" href="data:image/svg+xml,%3Csvg%20xmlns='http://www.w3.org/2000/svg'%20viewBox='0%200%2064%2064'%3E%3Crect%20width='64'%20height='64'%20rx='14'%20fill='%2312d3c4'/%3E%3Ccircle%20cx='23'%20cy='31'%20r='11'%20fill='%23fff'/%3E%3Ccircle%20cx='41'%20cy='31'%20r='11'%20fill='%23fff'/%3E%3Ccircle%20cx='23'%20cy='31'%20r='5'%20fill='%23161b22'/%3E%3Ccircle%20cx='41'%20cy='31'%20r='5'%20fill='%23161b22'/%3E%3C/svg%3E">
<style>
  :root {
    --bg:#0d1117; --panel:#161b22; --border:#30363d; --text:#e6edf3;
    --muted:#8b949e; --link:#58a6ff; --draft:#6e7681;
    --fresh:#3fb950; --warn:#d29922; --stale:#f85149;
    --chip:#21262d;
  }
  @media (prefers-color-scheme: light) {
    :root {
      --bg:#ffffff; --panel:#f6f8fa; --border:#d0d7de; --text:#1f2328;
      --muted:#656d76; --link:#0969da; --draft:#8c959f;
      --fresh:#1a7f37; --warn:#9a6700; --stale:#cf222e; --chip:#eaeef2;
    }
  }
  * { box-sizing:border-box; }
  body {
    margin:0; font:14px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",Helvetica,Arial,sans-serif;
    background:var(--bg); color:var(--text); padding:24px;
  }
  header { display:flex; align-items:baseline; gap:16px; flex-wrap:wrap; margin-bottom:20px; }
  h1 { font-size:20px; margin:0; }
  .meta { color:var(--muted); font-size:12px; }
  .cols { display:grid; grid-template-columns:repeat(auto-fit,minmax(360px,1fr)); gap:20px; align-items:start; }
  section { background:var(--panel); border:1px solid var(--border); border-radius:8px; padding:14px 16px; }
  section h2 { font-size:14px; margin:0 0 12px; display:flex; align-items:center; gap:8px; }
  .count { background:var(--chip); border-radius:20px; padding:1px 9px; font-size:12px; color:var(--muted); }
  .org { color:var(--muted); font-size:11px; text-transform:uppercase; letter-spacing:.04em; margin:14px 0 6px; }
  .org:first-of-type { margin-top:0; }
  .pr { padding:8px 0; border-top:1px solid var(--border); }
  .pr:first-child { border-top:0; }
  .pr a { color:var(--link); text-decoration:none; font-weight:500; }
  .pr a:hover { text-decoration:underline; }
  .pr-main { display:flex; align-items:flex-start; gap:8px; justify-content:space-between; }
  .review-btn { flex:0 0 auto; cursor:pointer; font:inherit; font-size:11px; font-weight:600;
    color:#0b3b37; background:#12d3c4; border:0; border-radius:6px; padding:2px 10px; line-height:1.6; }
  .review-btn:hover { background:#3ee0d3; }
  .review-btn.ok { background:var(--fresh); color:#fff; }
  .sub { color:var(--muted); font-size:12px; margin-top:2px; display:flex; gap:8px; flex-wrap:wrap; align-items:center; }
  .badge { font-size:10px; padding:1px 7px; border-radius:10px; font-weight:600; letter-spacing:.02em; }
  .b-draft { background:var(--chip); color:var(--draft); }
  .b-arch  { background:var(--chip); color:var(--muted); }
  .b-fresh { color:var(--fresh); border:1px solid var(--fresh); }
  .b-warn  { color:var(--warn);  border:1px solid var(--warn); }
  .b-stale { color:var(--stale); border:1px solid var(--stale); }
  .b-ci-pass { color:var(--fresh); border:1px solid var(--fresh); }
  .b-ci-fail { color:var(--stale); border:1px solid var(--stale); }
  .b-ci-pend { color:var(--warn); border:1px solid var(--warn); }
  .b-appr { color:var(--fresh); border:1px solid var(--fresh); }
  .b-chg  { color:var(--stale); border:1px solid var(--stale); }
  .b-rev  { color:var(--warn); border:1px solid var(--warn); }

  /* --- stacks ---------------------------------------------------------------
     A stack is one unit of work split across PRs, so it is drawn as one block
     with a rail down the side rather than as N rows that happen to be adjacent.
     The rail uses the page's one accent, the same colour as the Review button,
     because "these belong together" and "this is the actionable thing" are the
     two facts the column exists to convey. */
  .stack { border:1px solid var(--border); border-left:3px solid #12d3c4;
    border-radius:6px; padding:2px 10px 6px; margin:8px 0; background:var(--bg); }
  .stack .pr:first-of-type { border-top:0; }
  .stack-head { display:flex; gap:8px; flex-wrap:wrap; align-items:baseline;
    font-size:11px; color:var(--muted); padding:6px 0 2px; }
  .stack-n { color:#12d3c4; font-weight:700; letter-spacing:.03em; }
  .stack-head code { background:var(--chip); padding:1px 5px; border-radius:4px; }
  .stack-hint { margin-left:auto; font-style:italic; }
  /* Indent by depth so a stack that branches (two PRs on one parent) is visible
     as two rows at the same indent, rather than being flattened into a false
     1-2-3-4 sequence. Capped at 6: deeper than that the indent costs more room
     than it conveys, and the position badge still carries the number. */
  .pr.stacked .pr-main { display:flex; align-items:baseline; gap:6px; }
  .rail { flex:0 0 auto; color:#12d3c4; opacity:.65; font-weight:700;
    white-space:pre; font-family:ui-monospace,SFMono-Regular,Menlo,monospace; }
  .d1 .rail::before { content:'└ '; }
  .d2 .rail::before { content:'  └ '; }
  .d3 .rail::before { content:'    └ '; }
  .d4 .rail::before { content:'      └ '; }
  .d5 .rail::before { content:'        └ '; }
  .d6 .rail::before { content:'          └ '; }
  .b-mine { background:var(--chip); color:var(--link); }
  .b-stack { background:var(--chip); color:var(--muted); }
  .b-first { color:#12d3c4; border:1px solid #12d3c4; }
  .b-blocked { background:var(--chip); color:var(--draft); }
  /* Stack context (fetch.sh 3b): there so the stack reads whole, not because it
     is waiting on me. Dimmed rather than hidden; hover brings it back to full. */
  .b-ctx { background:var(--chip); color:var(--muted); font-style:italic; }
  .pr.ctx { opacity:.6; }
  .pr.ctx:hover { opacity:1; }
  .empty { color:var(--muted); font-style:italic; padding:6px 0; }
  /* A query that failed must never look like an empty result. Same slot as
     .empty, but styled as a problem rather than as "nothing to do". */
  .fetch-err { color:var(--text); background:var(--panel); font-size:12px;
    border:1px solid var(--stale); border-left:3px solid var(--stale);
    border-radius:6px; padding:8px 10px; margin:6px 0; }
  .fetch-err code { background:var(--chip); padding:1px 4px; border-radius:4px; }
  /* Softer than .fetch-err: the data is real, just possibly a cycle behind. */
  .fetch-note { color:var(--muted); font-size:12px; border-left:3px solid var(--warn);
    background:var(--panel); border-radius:6px; padding:6px 10px; margin:6px 0; }
  /* What the queue filtered out. Deliberately quiet — it is a receipt, not a
     warning — but present, so a short queue is never mistaken for a lost one. */
  .queue-note { color:var(--muted); font-size:11px; margin:0 0 10px; }
  footer { color:var(--muted); font-size:11px; margin-top:24px; }
  /* Shown only when the data itself is old — a frozen generator used to be
     invisible, since stale content still renders as a normal-looking page. */
  #stale-warn {
    display:none; margin:0 0 14px; padding:10px 12px; border-radius:6px;
    background:var(--panel); border:1px solid var(--stale);
    border-left:4px solid var(--stale); color:var(--text); font-size:13px;
  }
  #stale-warn.show { display:block; }
  #stale-warn code { background:var(--chip); padding:1px 5px; border-radius:4px; }
</style>
</head>
<body>
<header>
  <h1>PR Review Dashboard</h1>
  <span class="meta" id="meta"></span>
</header>
<div id="stale-warn" role="alert"></div>
<div class="cols">
  <section><h2>Needs my review <span class="count" id="c-review"></span></h2><div id="review"></div></section>
  <section><h2>My open PRs <span class="count" id="c-mine"></span></h2><div id="mine"></div></section>
</div>
<footer id="foot"></footer>

<script id="data" type="application/json">
__DATA__
</script>
<script>
const D = JSON.parse(document.getElementById('data').textContent);
const now = new Date(D.generatedAt);

function ageDays(iso){ return (now - new Date(iso)) / 864e5; }
function ageLabel(iso){
  const d = ageDays(iso);
  if (d < 1)  return Math.max(1,Math.round(d*24)) + 'h';
  if (d < 30) return Math.round(d) + 'd';
  return Math.round(d/30) + 'mo';
}
function staleClass(iso){
  const d = ageDays(iso);
  if (d <= 2)  return 'b-fresh';
  if (d <= 7)  return 'b-warn';
  return 'b-stale';
}
function orgOf(nameWithOwner){ return nameWithOwner.split('/')[0]; }
function esc(s){ const e=document.createElement('div'); e.textContent=s??''; return e.innerHTML; }

// ---- Needs my review: merge direct + team, dedupe by url --------------------
// What arrives here is already filtered by fetch.sh: no drafts, and no
// picked-up PR I have already submitted a review on. A picked-up row that
// survives is a review I started and never submitted — nobody routed that PR to
// me, so nothing will route it back. The badges below are pure triage: archived
// repos and PRs sitting with the author still show, because those are judgment
// calls rather than answered questions.
const reviewMeta = D.reviewMeta || {};
const seen = new Set();
const review = [];
// GitHub routed these to me -- a direct request or one of my teams. Anything in
// the list that is NOT here I picked up myself, which is worth showing as a
// different thing: nobody will re-route it to me if I lose track of it.
const routed = new Set([...(D.reviewDirect||[]), ...(D.reviewTeam||[])].map(p => p.url));
for (const p of [...(D.reviewDirect||[]), ...(D.reviewTeam||[]), ...(D.reviewReviewed||[])]) {
  if (seen.has(p.url)) continue;
  seen.add(p.url);
  const meta = reviewMeta[p.url] || {};
  review.push({
    repo: p.repository.nameWithOwner, number: p.number, title: p.title,
    author: p.author?.login, url: p.url, updatedAt: p.updatedAt, isDraft: p.isDraft,
    head: meta.headRefName, base: meta.baseRefName,
    unrouted: !routed.has(p.url),
    // "the ball is with the author": someone else requested changes and I haven't
    // reviewed or commented, so there's probably nothing for me to do yet.
    waitingOnAuthor: !!meta.changesRequestedByOther && !meta.iEngaged,
    changesRequestedByOther: !!meta.changesRequestedByOther,
    archived: !!meta.archived
  });
}
// oldest-first: the ones that have waited longest float to the top
review.sort((a,b)=> new Date(a.updatedAt) - new Date(b.updatedAt));

// ---- Stacked PRs ------------------------------------------------------------
// GitHub records only a base-branch string, so nothing in the API says "these
// five are one stack" -- the chain has to be reconstructed. A PR sits on another
// when its base branch is that other PR's head branch **in the same repo**.
//
// Indexed across both columns on purpose: a stack can straddle them (my PR on top
// of someone else's, or a root I am not a reviewer on), and a stack that appears
// to start in the middle is exactly the confusion this is meant to remove.
function linkStacks(lists){
  const byHead = new Map();
  const all = [];
  for (const list of lists) for (const p of list){
    all.push(p);
    if (p.head) byHead.set(p.repo + '|' + p.head, p);
  }
  for (const p of all) p.parent = (p.base && byHead.get(p.repo + '|' + p.base)) || null;

  // Real branches cannot form a cycle, but a branch renamed mid-fetch could, and
  // an infinite walk in the render is a worse failure than a wrong badge -- so
  // every walk is bounded by the population size.
  const walkUp = (p) => { let c = p, n = 0; while (c.parent && n++ < all.length) c = c.parent; return c; };
  const depthOf = (p) => { let d = 0, c = p; while (c.parent && d < all.length){ d++; c = c.parent; } return d; };

  const groups = new Map();
  for (const p of all){
    const root = walkUp(p);
    if (!groups.has(root)) groups.set(root, []);
    groups.get(root).push(p);
  }
  for (const [root, g] of groups){
    if (g.length < 2){ g[0].stackSize = 1; continue; }
    for (const p of g) p.stackDepth = depthOf(p);
    g.sort((a,b) => a.stackDepth - b.stackDepth || a.number - b.number);
    g.forEach((p,i) => {
      p.stackId = root.repo + '#' + root.number;
      p.stackPos = i + 1;
      p.stackSize = g.length;
      p.stackRoot = (p === root);
    });
  }
}

// Keep a stack contiguous and bottom-up, and let its *oldest* member set where
// the whole block sits in the queue. Sorting the block by its newest member would
// let a stack jump the line every time its tip is pushed, which is the opposite
// of what oldest-first is for.
// `newestFirst` flips only the order of the blocks, never the order *within* a
// stack: bottom-up is a property of the work, not a sort preference, so the two
// columns order blocks differently but always read a stack the same way.
function stackAwareOrder(list, newestFirst){
  const groups = new Map();
  for (const p of list){
    const k = p.stackId || ('solo:' + p.url);
    if (!groups.has(k)) groups.set(k, []);
    groups.get(k).push(p);
  }
  const blocks = [...groups.values()];
  for (const g of blocks) g.sort((a,b) => (a.stackPos || 0) - (b.stackPos || 0));
  // Context rows (fetch.sh 3b) ride along inside a block but never place it:
  // only the PRs that are actually in this column's list decide where it sits.
  const key = g => {
    const own = g.filter(p => !p.context);
    const ts = (own.length ? own : g).map(p => +new Date(p.updatedAt));
    return newestFirst ? Math.max(...ts) : Math.min(...ts);
  };
  blocks.sort((a,b) => newestFirst ? key(b) - key(a) : key(a) - key(b));
  return blocks.flat();
}

// ---- My PRs: normalize ------------------------------------------------------
function ciRollup(checks){
  if (!checks || !checks.length) return null;
  let fail=0, pend=0;
  for (const c of checks){
    const s = (c.conclusion || c.state || c.status || '').toUpperCase();
    if (['FAILURE','ERROR','TIMED_OUT','CANCELLED','ACTION_REQUIRED'].includes(s)) fail++;
    else if (['SUCCESS','COMPLETED','NEUTRAL','SKIPPED'].includes(s)) {}
    else pend++;
  }
  if (fail) return 'fail';
  if (pend) return 'pend';
  return 'pass';
}

// Did this cycle's queries actually succeed? `fetchErrors` is absent on pages
// written by an older fetch.sh, so default every flag to "fine".
const FE = D.fetchErrors || {};
function fetchErrNote(what){
  return '<div class="fetch-err"><strong>Could not load ' + what + '.</strong> ' +
    'The GitHub query failed this cycle and no recent cached copy was available, ' +
    'so this list is <em>not</em> necessarily empty. Usually the search API\'s ' +
    'secondary rate limit, which clears on its own. ' +
    'See <code>tail ~/pr-dashboard/watch.log</code>.</div>';
}
// A count, never a list: the point is to prove the filter is working, not to
// re-introduce the rows it removed. Silence here would put us back where this
// started — a queue whose length nobody can account for.
function hiddenNote(){
  const h = FE.hidden || {};
  const bits = [];
  if (h.reviewed) bits.push(h.reviewed + ' already reviewed');
  if (h.aged)     bits.push(h.aged + ' untouched for ' + (h.agedDays || 30) + '+ days');
  if (h.drafts)   bits.push(h.drafts + ' draft');
  if (h.muted)    bits.push(h.muted + ' muted');
  if (!bits.length) return '';
  return '<div class="queue-note">' + bits.join(' · ') + ' hidden. ' +
    'A re-requested review always comes back.</div>';
}
function staleNote(what){
  // The age matters now: an over-age cache is served rather than dropped, so
  // this note is the only thing standing between you and treating an hours-old
  // review request as current.
  const a = Number(FE.staleAgeSec || 0);
  const how = !a               ? 'it may be a few minutes behind'
            : a < 5400         ? 'it is about ' + Math.round(a / 60) + ' minutes old'
            :                    'it is about ' + Math.round(a / 3600) + ' hours old';
  return '<div class="fetch-note">Showing the last good copy of ' + what + ' — ' +
    'that query failed this cycle, so ' + how + '.</div>';
}

const mine = (D.authored||[]).map(p => ({
  repo: p.repoName, number: p.number, title: p.title, url: p.url,
  updatedAt: p.updatedAt, isDraft: p.isDraft,
  head: p.headRefName, base: p.baseRefName,
  reviewDecision: p.reviewDecision,
  ci: ciRollup(p.statusCheckRollup)
})).sort((a,b)=> new Date(b.updatedAt) - new Date(a.updatedAt));

// The rest of each stack (fetch.sh 3b): open PRs in a stack I am working on
// that are neither waiting on me nor mine. Drawn inside their stack so it reads
// whole and starts at its real bottom, but never counted as review work.
const context = (D.stackContext||[]).map(p => ({
  repo: p.repository.nameWithOwner, number: p.number, title: p.title,
  author: p.author?.login, url: p.url, updatedAt: p.updatedAt, isDraft: p.isDraft,
  head: p.headRefName, base: p.baseRefName, context: true
}));

// All three at once -- see linkStacks. Runs after `mine` exists so a stack
// spanning the columns is linked rather than showing up as unrelated fragments.
linkStacks([review, mine, context]);

// Each context row joins the column its stack already lives in: the review
// column when the stack has a queue PR, otherwise mine. A context row whose
// stack is in neither (cannot happen today -- 3b only walks out from PRs on the
// page) is dropped rather than shown as a stray.
const reviewStacks = new Set(review.map(p => p.stackId).filter(Boolean));
const mineStacks = new Set(mine.map(p => p.stackId).filter(Boolean));
const contextReview = context.filter(p => reviewStacks.has(p.stackId));
const contextMine = context.filter(p => !reviewStacks.has(p.stackId) && mineStacks.has(p.stackId));

function stackBits(p){
  if (!(p.stackSize > 1)) return { cls:'', rail:'', badges:'' };
  const d = Math.min(p.stackDepth || 0, 6);
  return {
    cls: ' stacked d' + d,
    rail: d ? '<span class="rail" aria-hidden="true"></span>' : '',
    badges:
      `<span class="badge b-stack">stack ${p.stackPos}/${p.stackSize}</span>` +
      // "review first" only on a root I actually need to review. A context root
      // (say, one I already approved) is still the bottom of the stack, but
      // telling me to review it first would point at finished work.
      (p.stackRoot && !p.context
        ? '<span class="badge b-first">review first</span>'
        : p.stackRoot
        ? '<span class="badge b-blocked">bottom</span>'
        : `<span class="badge b-blocked">on #${p.parent ? p.parent.number : '?'}</span>`)
  };
}

// A stack is drawn as one block with a header, because the thing worth seeing is
// "this is one piece of work in N parts", not N adjacent rows.
function stackBlock(g, rowFn){
  if (g.length < 2) return g.map(rowFn).join('');
  const root = g[0];
  return `<div class="stack">
      <div class="stack-head">
        <span class="stack-n">${g.length}-PR stack</span>
        <span>onto <code>${esc(root.base || '?')}</code></span>
        <span class="stack-hint">review bottom-up</span>
      </div>
      ${g.map(rowFn).join('')}
    </div>`;
}

// Re-split an already-ordered list back into its contiguous stack blocks so each
// can be wrapped. stackAwareOrder guarantees members are adjacent and in order.
function renderBlocks(ordered, rowFn){
  const out = [];
  let i = 0;
  while (i < ordered.length){
    const id = ordered[i].stackId;
    if (!id){ out.push(rowFn(ordered[i])); i++; continue; }
    const g = [];
    while (i < ordered.length && ordered[i].stackId === id){ g.push(ordered[i]); i++; }
    out.push(stackBlock(g, rowFn));
  }
  return out.join('');
}

function groupByOrg(list){
  const g = {};
  for (const p of list){ (g[orgOf(p.repo)] ||= []).push(p); }
  return g;
}

// Copy a ready-to-paste review prompt for this PR to the clipboard. "high" is the
// /code-review effort level. The prompt is plain text rather than a leading slash
// command on purpose: a message that starts with /code-review hands everything
// after it to that skill as arguments, so a chained /post-draft-review would be
// read as part of the review target instead of run afterwards.
// /post-draft-review only ever posts a PENDING review, which nobody else sees
// until it is submitted by hand on GitHub.
function reviewPrompt(url){
  return 'Run /code-review high ' + url +
    ', then run /post-draft-review to post the verified findings as a draft review.';
}
function copyReview(url, btn){
  const cmd = reviewPrompt(url);
  const done = () => { const t = btn.textContent; btn.textContent = 'Copied ✓'; btn.classList.add('ok');
    window.setTimeout(() => { btn.textContent = t; btn.classList.remove('ok'); }, 1500); };
  if (navigator.clipboard && navigator.clipboard.writeText) {
    navigator.clipboard.writeText(cmd).then(done).catch(() => window.prompt('Copy this into Claude:', cmd));
  } else {
    window.prompt('Copy this into Claude:', cmd);
  }
}

// Shared by both columns. Delegation-free but attached after each render, so it
// avoids inline handlers (and the file:// CSP problems they bring).
function wireReviewButtons(host){
  host.querySelectorAll('.review-btn').forEach(b =>
    b.addEventListener('click', () => copyReview(b.dataset.url, b)));
}

function reviewButton(url){
  return `<button class="review-btn" data-url="${esc(url)}"
            title="Copy a /code-review high + /post-draft-review prompt for Claude">Review</button>`;
}

function reviewRow(p){
  const s = stackBits(p);
  return `
      <div class="pr${s.cls}${p.context ? ' ctx' : ''}">
        <div class="pr-main">
          ${s.rail}
          <a href="${p.url}" target="_blank" rel="noopener">${esc(p.repo.split('/')[1])} #${p.number} — ${esc(p.title)}</a>
          ${reviewButton(p.url)}
        </div>
        <div class="sub">
          <span>@${esc(p.author)}</span>
          ${p.context ? '<span class="badge b-ctx" title="Not waiting on me: no review request, no pending draft of mine. Shown so the stack reads whole.">stack context</span>' : ''}
          ${p.unrouted ? '<span class="badge b-mine" title="No review request and no team of mine — it is here because I already reviewed it">picked up</span>' : ''}
          ${s.badges}
          ${p.isDraft ? '<span class="badge b-draft">DRAFT</span>' : ''}
          ${p.archived ? '<span class="badge b-arch">ARCHIVED REPO</span>' : ''}
          ${p.waitingOnAuthor ? '<span class="badge b-chg">with author</span>'
            : p.changesRequestedByOther ? '<span class="badge b-chg">changes requested</span>' : ''}
          <span class="badge ${staleClass(p.updatedAt)}">${ageLabel(p.updatedAt)} old</span>
        </div>
      </div>`;
}

function mineRow(p){
  const s = stackBits(p);
  const rd = p.reviewDecision;
  const rdBadge = rd === 'APPROVED' ? '<span class="badge b-appr">approved</span>'
    : rd === 'CHANGES_REQUESTED' ? '<span class="badge b-chg">changes requested</span>'
    : rd === 'REVIEW_REQUIRED' ? '<span class="badge b-rev">review required</span>' : '';
  const ciBadge = p.ci === 'pass' ? '<span class="badge b-ci-pass">CI ok</span>'
    : p.ci === 'fail' ? '<span class="badge b-ci-fail">CI fail</span>'
    : p.ci === 'pend' ? '<span class="badge b-ci-pend">CI …</span>' : '';
  return `
      <div class="pr${s.cls}">
        <div class="pr-main">
          ${s.rail}
          <a href="${p.url}" target="_blank" rel="noopener">${esc(p.repo.split('/')[1])} #${p.number} — ${esc(p.title)}</a>
          ${reviewButton(p.url)}
        </div>
        <div class="sub">
          ${p.isDraft ? '<span class="badge b-draft">DRAFT</span>' : ''}
          ${s.badges}
          ${rdBadge} ${ciBadge}
          <span class="badge ${staleClass(p.updatedAt)}">${ageLabel(p.updatedAt)} old</span>
        </div>
      </div>`;
}

function renderGroups(list){
  const g = groupByOrg(list);
  return Object.keys(g).sort().map(org =>
    `<div class="org">${esc(org)}</div>` +
    renderBlocks(stackAwareOrder(g[org]), reviewRow)).join('');
}

function renderReview(){
  const host = document.getElementById('review');
  document.getElementById('c-review').textContent = review.length;
  const degraded = FE.direct || FE.reviewed || (FE.failedQueries || 0) > 0;
  const stale    = FE.directStale || FE.reviewedStale || (FE.staleQueries || 0) > 0;
  const note = (degraded ? fetchErrNote('some review requests')
              : stale    ? staleNote('some review requests') : '') + hiddenNote();
  // The count above stays review.length: context rows are not review work.
  host.innerHTML = note + (review.length
    ? renderGroups(review.concat(contextReview))
    : (degraded ? '' : '<div class="empty">Nothing waiting on you</div>'));
  wireReviewButtons(host);
}

function renderMine(){
  const host = document.getElementById('mine');
  document.getElementById('c-mine').textContent = mine.length;
  // The bug this replaces: a 403 on the authored search degraded to an empty
  // list and rendered as "No open PRs.", which reads as reassurance.
  if (FE.authored){ host.innerHTML = fetchErrNote('your open PRs'); return; }
  if (!mine.length){ host.innerHTML = '<div class="empty">No open PRs.</div>'; return; }
  const dropped = FE.authoredDropped || 0;
  const partial =
    (FE.authoredStale ? staleNote('your open PRs') : '') +
    (dropped > 0
      ? '<div class="fetch-err">' + dropped + ' more of your PRs could not be loaded ' +
        'this cycle, so they are missing from this list.</div>'
      : '');
  // Context rows here are someone else's PRs in a stack with mine, so they get
  // the review-row layout (author, context badge) rather than my CI/decision row.
  const g = groupByOrg(mine.concat(contextMine));
  host.innerHTML = partial + Object.keys(g).sort().map(org =>
    `<div class="org">${esc(org)}</div>` +
    renderBlocks(stackAwareOrder(g[org], true), p => p.context ? reviewRow(p) : mineRow(p))).join('');
  wireReviewButtons(host);
}

// Last time the watcher checked GitHub for activity. Between full fetches the
// data is only re-fetched when a notification says something moved, so the
// generated time can legitimately be ~10 minutes old; the check time cannot.
const checked = new Date(Number('__CHECKED_AT__') || now.getTime());
document.getElementById('meta').textContent =
  'as ' + D.me + ' · generated ' + now.toLocaleTimeString() +
  ' · checked ' + checked.toLocaleTimeString() + ' · checks every __REFRESH__s';

// Staleness banner. The page meta-refreshes regardless of whether the generator
// is still alive, so without this a wedged watcher just serves old data that
// looks entirely current. Keyed on the last check, not on generatedAt. Threshold
// = STALE_AFTER (3 polls plus a cycle cap, from watch.sh), so a single missed
// poll or a slow full fetch doesn't cry wolf.
(function () {
  const staleAfterSec = Number('__STALE_AFTER__') || 420;
  const ageSec = (Date.now() - checked.getTime()) / 1000;
  if (ageSec < staleAfterSec) return;
  const mins = Math.round(ageSec / 60);
  const age = mins < 90 ? mins + ' minutes' : Math.round(mins / 60) + ' hours';
  const el = document.getElementById('stale-warn');
  el.innerHTML = 'Nothing has checked GitHub for <strong>' + age + '</strong>. The watcher ' +
    'pauses while the Mac is idle or asleep, so this clears a few minutes after ' +
    'you are back. If it does not: ' +
    '<code>launchctl list | grep pr-dashboard</code> and ' +
    '<code>tail ~/pr-dashboard/watch.log</code>';
  el.classList.add('show');
})();
document.getElementById('foot').textContent =
  'Oldest-first. Hidden: drafts, picked-up PRs you have already reviewed, and team requests you approved — a ' +
  'picked-up row means a review you started and never submitted. Direct requests ' +
  'are never hidden. ' +
  'Dimmed "stack context" rows are the rest of a stack you are on, shown so it reads ' +
  'whole; they are not counted. ' +
  'Badges flag archived repos and PRs sitting with the author. Staleness is time since ' +
  'last update. Review copies a /code-review high + /post-draft-review prompt. Regenerated by pr-dashboard/fetch.sh.';

renderReview();
renderMine();
</script>
</body>
</html>
HTML
)"

# Swap placeholders. DATA is JSON (multi-line, may contain slashes/ampersands),
# so we split the template at the __DATA__ marker line and stitch the JSON in
# between — avoids sed/awk escaping and multi-line-variable pitfalls.
RENDERED="${TEMPLATE//__REFRESH__/$REFRESH}"
RENDERED="${RENDERED//__STALE_AFTER__/$STALE_AFTER}"
RENDERED="${RENDERED//__CHECKED_AT__/$CHECKED_AT}"
printf '%s\n' "${RENDERED%%__DATA__*}"
printf '%s\n' "$DATA"
printf '%s\n' "${RENDERED#*__DATA__}"
