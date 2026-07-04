#!/usr/bin/env node
// server.js — a portable, dependency-free backlog dashboard for the implementation harness.
//
// Pure Node core modules only (http, fs, path, child_process) — no npm install, no build step.
// Launch: node .harness/dashboard/server.js   (binds 127.0.0.1 only; port via HARNESS_DASHBOARD_PORT)
//
// Every GET /api/backlog re-reads TASKS.json + the owner overlays + worklog fresh from disk — no
// caching, no daemon polling loop of its own. Mutation endpoints (mark done/failed/reviewed) do
// NOT reimplement overlay-writing logic: they shell out to the exact same scripts/mark-*.sh a
// human would run by hand, so a dashboard click takes the identical, already-tested code path
// (including the loop's own repo-lock).
'use strict';

const http = require('http');
const fs = require('fs');
const path = require('path');
const { execFile } = require('child_process');
const { computeBacklog } = require('./lib');

const HARNESS_DIR = path.join(__dirname, '..');
const ROOT = path.join(HARNESS_DIR, '..');
const TASKS_PATH = path.join(HARNESS_DIR, 'tracking', 'TASKS.json');
const OVERLAY_PATHS = {
  humanDone: path.join(HARNESS_DIR, 'tracking', 'human-done.json'),
  manualFail: path.join(HARNESS_DIR, 'tracking', 'manual-fail.json'),
  reviews: path.join(HARNESS_DIR, 'tracking', 'reviews.json'),
};
const WORKLOG_DIR = path.join(HARNESS_DIR, 'worklog');
const LEDGERS_DIR = path.join(HARNESS_DIR, 'ledgers');
const SCRIPTS_DIR = path.join(HARNESS_DIR, 'scripts');
const PORT = parseInt(process.env.HARNESS_DASHBOARD_PORT || '4790', 10);

function readJson(p, fallback) {
  try {
    return JSON.parse(fs.readFileSync(p, 'utf8'));
  } catch (_err) {
    return fallback;
  }
}

function readText(p) {
  try {
    return fs.readFileSync(p, 'utf8');
  } catch (_err) {
    return null;
  }
}

// blockedIds() — scan worklog/*.md for the literal string "failed:blocked", mirroring the loop's
// own task_blocked() grep exactly, so the dashboard can never disagree with what the loop sees.
function blockedIds() {
  const ids = new Set();
  let files;
  try {
    files = fs.readdirSync(WORKLOG_DIR);
  } catch (_err) {
    return ids;
  }
  for (const f of files) {
    if (!f.endsWith('.md') || f.endsWith('.audit.md')) continue;
    const text = readText(path.join(WORKLOG_DIR, f));
    if (text && /failed:blocked/i.test(text)) ids.add(f.replace(/\.md$/, ''));
  }
  return ids;
}

// buildFailures() — aggregate ledgers/failures.jsonl (the loop's per-attempt diagnostics, appended by
// record_failure) into { <taskId>: { count, latestKind, latestDetail } }, so a not-yet-done task can
// show a "⚠ N failed attempts" pill. Robust to a missing/garbled ledger (returns {}).
function buildFailures() {
  const out = {};
  const text = readText(path.join(LEDGERS_DIR, 'failures.jsonl'));
  if (!text) return out;
  for (const line of text.split('\n')) {
    if (!line.trim()) continue;
    let row;
    try { row = JSON.parse(line); } catch (_err) { continue; }
    if (!row || !row.id) continue;
    const cur = out[row.id] || (out[row.id] = { count: 0, latestKind: '', latestDetail: '' });
    cur.count += 1;
    cur.latestKind = row.kind || cur.latestKind;
    cur.latestDetail = row.detail || cur.latestDetail;   // rows are append-order → last wins
  }
  return out;
}

function loadState() {
  const tasksJson = readJson(TASKS_PATH, { tasks: [] });
  const failures = buildFailures();
  const overlays = {
    humanDone: readJson(OVERLAY_PATHS.humanDone, {}),
    manualFail: readJson(OVERLAY_PATHS.manualFail, {}),
    reviews: readJson(OVERLAY_PATHS.reviews, {}),
  };
  const buckets = computeBacklog(tasksJson, overlays, blockedIds());   // already attaches `reviewed`
  for (const bucket of Object.values(buckets)) {
    for (const task of bucket) {
      task.spec = task.spec ? readText(path.join(ROOT, task.spec)) : null;
      task.worklog = readText(path.join(WORKLOG_DIR, `${task.id}.md`));
      task.audit = readText(path.join(WORKLOG_DIR, `${task.id}.audit.md`));
      // Attach failed-attempt history to NON-done tasks (a done task's past soft-fails aren't
      // interesting; a still-open task with failures is the signal worth surfacing).
      if (!task.failed && failures[task.id]) task.buildFailures = failures[task.id];
    }
  }
  return {
    counts: {
      ready: buckets.ready.length,
      waiting: buckets.waiting.length,
      needsHuman: buckets.needsHuman.length,
      done: buckets.done.length,
    },
    buckets,
  };
}

function isLoopback(req) {
  const addr = req.socket.remoteAddress || '';
  return addr === '127.0.0.1' || addr === '::1' || addr === '::ffff:127.0.0.1';
}

function runScript(scriptName, args) {
  return new Promise((resolve, reject) => {
    const script = path.join(SCRIPTS_DIR, scriptName);
    execFile('bash', [script, ...args], { cwd: HARNESS_DIR, timeout: 30000 }, (err, stdout, stderr) => {
      if (err) reject(new Error(stderr || stdout || err.message));
      else resolve(stdout);
    });
  });
}

function sendJson(res, status, body) {
  const data = JSON.stringify(body);
  res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8', 'Content-Length': Buffer.byteLength(data) });
  res.end(data);
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let body = '';
    req.on('data', (chunk) => {
      body += chunk;
      if (body.length > 1e6) req.destroy();
    });
    req.on('end', () => {
      try {
        resolve(body ? JSON.parse(body) : {});
      } catch (err) {
        reject(err);
      }
    });
    req.on('error', reject);
  });
}

function isValidTaskId(id) {
  return typeof id === 'string' && /^[A-Za-z0-9_-]+$/.test(id);
}

const server = http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url, 'http://localhost');

    if (req.method === 'GET' && url.pathname === '/api/backlog') {
      return sendJson(res, 200, loadState());
    }

    if (req.method === 'GET' && url.pathname === '/') {
      const html = renderPage();
      res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
      return res.end(html);
    }

    if (req.method === 'POST' && url.pathname.startsWith('/api/mark-')) {
      if (!isLoopback(req)) return sendJson(res, 403, { error: 'dashboard mutation endpoints are loopback-only' });
      const body = await readBody(req);

      if (url.pathname === '/api/mark-done') {
        const ids = Array.isArray(body.ids) ? body.ids : [body.id];
        if (!ids.length || !ids.every(isValidTaskId)) return sendJson(res, 400, { error: 'ids required' });
        await runScript('mark-done.sh', ids);
        return sendJson(res, 200, { ok: true, ids });
      }
      if (url.pathname === '/api/mark-failed') {
        if (!isValidTaskId(body.id) || !body.reason) return sendJson(res, 400, { error: 'id and reason required' });
        await runScript('mark-failed.sh', [body.id, body.reason]);
        return sendJson(res, 200, { ok: true, id: body.id });
      }
      if (url.pathname === '/api/mark-reviewed') {
        const ids = Array.isArray(body.ids) ? body.ids : [body.id];
        if (!ids.length || !ids.every(isValidTaskId)) return sendJson(res, 400, { error: 'ids required' });
        await runScript('mark-reviewed.sh', ids);
        return sendJson(res, 200, { ok: true, ids });
      }
      return sendJson(res, 404, { error: 'unknown endpoint' });
    }

    res.writeHead(404, { 'Content-Type': 'text/plain' });
    res.end('not found');
  } catch (err) {
    sendJson(res, 500, { error: err.message });
  }
});

function renderPage() {
  return `<!doctype html>
<html>
<head>
<meta charset="utf-8">
<title>Backlog — implementation harness</title>
<style>
  :root{
    --bg:#fbf3dd; --panel:#fff9ec; --panel-2:#ffeec2; --border:#f0d49a;
    --text:#4a3613; --muted:#9c7e44; --accent:#e8821f;
    --green:#5a9e2e; --red:#e0492e; --yellow:#c98a12; --amber:#d9791a; --human:#3a7bd0;
  }
  *{box-sizing:border-box}
  body{margin:0;background:var(--bg);color:var(--text);font:14px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;}
  .container{max-width:1000px;margin:0 auto;padding:26px 20px 72px;}
  h1{font-size:22px;font-weight:700;margin:0 0 4px;}
  .sub{color:var(--muted);margin:0 0 22px;font-size:13px;}
  .mono{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;}
  a{color:var(--accent);text-decoration:none} a:hover{text-decoration:underline}
  button{cursor:pointer;font:inherit}

  .pill{display:inline-block;font-size:11px;padding:1px 8px;border-radius:999px;background:var(--panel-2);border:1px solid var(--border);color:var(--muted);white-space:nowrap;margin-left:4px;}
  .pill.buildable{color:var(--amber);background:rgba(232,160,32,.14);border-color:rgba(232,160,32,.4);}
  .pill.human{color:#fff;background:var(--human);border-color:var(--human);}
  .pill.blocked{color:var(--yellow);background:rgba(201,138,18,.16);border-color:rgba(201,138,18,.45);font-weight:600;}
  .pill.done{color:var(--green);background:rgba(90,158,46,.14);border-color:rgba(90,158,46,.35);}
  .pill.failed{color:var(--red);background:rgba(224,73,46,.12);border-color:rgba(224,73,46,.35);}
  .pill.reviewed{color:var(--green);background:rgba(90,158,46,.14);border-color:rgba(90,158,46,.35);}

  details.section{margin:0 0 26px;}
  summary.section-heading{font-size:15px;font-weight:700;text-transform:uppercase;letter-spacing:.04em;color:var(--muted);cursor:pointer;list-style:none;user-select:none;display:flex;align-items:center;gap:9px;padding:4px 0;}
  summary.section-heading::-webkit-details-marker{display:none}
  summary.section-heading::before{content:'\\203A';font-size:20px;font-weight:900;color:var(--accent);transform:rotate(90deg);transition:transform .2s;line-height:1;}
  details:not([open]) > summary.section-heading::before{transform:rotate(0)}
  details[open] > summary.section-heading{color:var(--text)}
  .section-desc{color:var(--muted);font-size:13px;margin:2px 0 10px 30px;}
  .panel{background:var(--panel);border:1px solid var(--border);border-radius:10px;padding:0 14px;}
  .empty{color:var(--muted);padding:11px 2px;}

  .taskrow .row{display:flex;gap:8px;align-items:baseline;flex-wrap:wrap;padding:6px 0;cursor:pointer;user-select:none;border-bottom:1px solid var(--border);}
  .panel > .taskrow:last-child .row{border-bottom:none}
  .caret{color:var(--muted);font-size:10px;min-width:10px}
  .tid{font-weight:700;min-width:46px}
  .title{flex:1;min-width:220px}

  .expand{padding:12px 16px 14px;margin:0 0 8px;background:var(--panel-2);border:1px solid var(--border);border-radius:6px;font-size:13px;}
  .expand pre{white-space:pre-wrap;background:var(--panel);border:1px solid var(--border);border-radius:4px;padding:8px;max-height:300px;overflow:auto;font-size:12px;}
  .expand details{margin-top:8px} .expand summary{color:var(--muted);font-size:12px;cursor:pointer;user-select:none}
  .dep-link{font-family:ui-monospace,Menlo,monospace;color:var(--accent);text-decoration:underline;text-underline-offset:2px;cursor:pointer}
  .kv{font-size:12px;color:var(--muted);margin-bottom:6px}

  .bar{display:flex;align-items:center;gap:9px;flex-wrap:wrap;margin:8px 0 6px;}
  .barlabel{font-size:11px;color:var(--muted);text-transform:uppercase;letter-spacing:.04em}
  .barbtn{font-size:11px;padding:3px 9px;border-radius:5px;border:1px solid var(--border);background:var(--panel-2);color:var(--muted);}
  .barbtn:hover{border-color:var(--accent);color:var(--text)}
  .barbtn.on{border-color:var(--accent);color:var(--accent);background:rgba(232,130,31,.12)}
  .act{font-size:12px;padding:3px 11px;border-radius:6px;border:1px solid var(--border);background:var(--panel-2);color:var(--text)}
  .act:hover{border-color:var(--accent)}
  .act.danger:hover{border-color:var(--red);color:var(--red)}
  .act[disabled]{opacity:.5;cursor:default}
  label.sel{display:inline-flex;align-items:center;gap:6px;cursor:pointer;font-size:13px;color:var(--muted)}

  .flash{animation:flash 1.6s ease-out;border-radius:6px}
  @keyframes flash{from{background:rgba(232,130,31,.25)}to{background:transparent}}
</style>
</head>
<body>
<div class="container">
<h1>Backlog</h1>
<p class="sub" id="summary"></p>
<div id="sections"></div>
</div>
<script>
const state = { open: new Set(), openLogs: new Set(), closedSections: new Set(), selected: new Set(), doneFilter: 'all', lastClicked: null, lastData: null };

async function refresh() {
  const res = await fetch('/api/backlog');
  const data = await res.json();
  render(data);
}

function esc(s) { return (s || '').replace(/[&<>]/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;'}[c])); }

function depLinks(ids) {
  return (ids || []).map(id => \`<span class="dep-link" onclick="event.stopPropagation(); openTask('\${id}')">\${esc(id)}</span>\`).join(', ') || '(none)';
}

function failPill(task, bucketName) {
  if (bucketName === 'done' || !task.buildFailures || !task.buildFailures.count) return '';
  const bf = task.buildFailures, n = bf.count;
  const tip = esc((bf.latestKind || '') + (bf.latestDetail ? ': ' + bf.latestDetail : ''));
  return \`<span class="pill blocked" title="\${tip}">⚠ \${n} failed attempt\${n === 1 ? '' : 's'}</span>\`;
}

function pillsFor(task, bucketName) {
  let pills = '';
  if (bucketName === 'ready' || bucketName === 'waiting') {
    if (task.unmetDeps && task.unmetDeps.length) pills += \`<span class="pill">needs: \${depLinks(task.unmetDeps)}</span>\`;
    else if (bucketName === 'ready') pills += '<span class="pill buildable">🤖 buildable</span>';
  } else if (bucketName === 'needsHuman') {
    // Distinguish a task the loop gave up on (status:"blocked") from one authored as a human gate.
    pills += task.status === 'blocked'
      ? '<span class="pill blocked">⚠ blocked (loop gave up)</span>'
      : '<span class="pill human">🔒 needs human</span>';
  } else if (bucketName === 'done') {
    pills += task.reviewed ? '<span class="pill reviewed">👁 reviewed</span>' : '<span class="pill">not reviewed</span>';
    pills += task.failed ? '<span class="pill failed">✗ failed</span>' : '<span class="pill done">✓ done</span>';
  }
  pills += failPill(task, bucketName);
  return pills;
}

function renderTask(task, bucketName) {
  const open = state.open.has(task.id);
  const checked = state.selected.has(task.id) ? 'checked' : '';
  let detail = '';
  if (open) {
    detail = '<div class="expand" onclick="event.stopPropagation()">';
    if (task.dependsOn && task.dependsOn.length) detail += \`<div class="kv">depends on: \${depLinks(task.dependsOn)}</div>\`;
    const facets = task.facets ? esc(task.facets.layer + '/' + task.facets.workType + (task.facets.risk && task.facets.risk.length ? ' · ' + task.facets.risk.join(',') : '')) : '—';
    detail += \`<div class="kv">scope: \${(task.scope || []).map(esc).join('  ') || '(none)'} · facets: \${facets}\${task.expectsTest ? ' · expectsTest' : ''}</div>\`;
    // Give each log <details> a stable id + ontoggle so its open/closed state survives a re-render
    // (the 5s auto-refresh rebuilds innerHTML, which would otherwise snap every open section shut).
    const lg = (kind, label, body) => {
      const lid = 'log-' + task.id + '-' + kind;
      const isOpen = state.openLogs.has(lid) || kind === 'spec';
      return \`<details id="\${lid}" ontoggle="onLogToggle(this)"\${isOpen ? ' open' : ''}><summary>\${label}</summary><pre>\${esc(body)}</pre></details>\`;
    };
    if (task.spec) detail += lg('spec', 'spec', task.spec);
    if (task.worklog) detail += lg('worklog', 'build log', task.worklog);
    if (task.audit) detail += lg('audit', 'audit', task.audit);
    detail += '<div class="bar" style="margin-top:10px">';
    if (bucketName === 'needsHuman') detail += \`<button class="act" onclick="markDone('\${task.id}')">Mark done</button>\`;
    if (bucketName === 'done' && !task.failed) detail += \`<button class="act danger" onclick="markFailed('\${task.id}')">Mark failed</button>\`;
    detail += \`<button class="act" onclick="markReviewed('\${task.id}')">\${task.reviewed ? 'Reviewed ✓' : 'Mark reviewed'}</button>\`;
    detail += '</div></div>';
  }
  // Only offer a bulk-select checkbox where bulk actions exist: needsHuman (mark-done) and
  // not-yet-reviewed done tasks (mark-reviewed) — mirrors the two bulk-action groups.
  const showCheckbox = bucketName === 'needsHuman' || (bucketName === 'done' && !task.reviewed);
  const checkbox = showCheckbox
    ? \`<input type="checkbox" \${checked} data-id="\${task.id}" data-bucket="\${bucketName}" onclick="event.stopPropagation(); rangeSelect(event, this)" onchange="toggleSelect(this)">\`
    : '';
  const hidden = (bucketName === 'done' && state.doneFilter !== 'all' && ((state.doneFilter === 'reviewed') !== !!task.reviewed)) ? ' style="display:none"' : '';
  return \`<div class="taskrow" id="task-\${task.id}"\${hidden}>
    <div class="row" onclick="toggleOpen('\${task.id}')">
      \${checkbox}<span class="caret">\${open ? '▾' : '▸'}</span>
      <span class="tid mono">\${esc(task.id)}</span>
      <span class="title">\${esc(task.title || '')}</span>
      \${pillsFor(task, bucketName)}
    </div>
    \${detail}
  </div>\`;
}

function renderSection(name, emoji, label, desc, tasks, countStr) {
  const openAttr = state.closedSections.has(name) ? '' : ' open';
  let bar = '';
  if (name === 'needsHuman' || name === 'done') {
    const selectable = tasks.filter(t => name === 'needsHuman' || !t.reviewed).map(t => t.id);
    const n = selectable.filter(id => state.selected.has(id)).length;
    const allSel = selectable.length > 0 && n === selectable.length;
    if (selectable.length) {
      const verb = name === 'needsHuman' ? 'done' : 'reviewed';
      bar = \`<div class="bar"><label class="sel"><input type="checkbox" \${allSel ? 'checked' : ''} onclick="toggleAll('\${name}', this.checked)"> select all (\${selectable.length})</label>\`
          + \`<button class="act" onclick="bulkAction('\${name}')" \${n ? '' : 'disabled'}>Mark \${n} \${verb}</button></div>\`;
    }
  }
  let filterBar = '';
  if (name === 'done') {
    const mk = (mode, text) => \`<button class="barbtn\${state.doneFilter === mode ? ' on' : ''}" onclick="setDoneFilter('\${mode}')">\${text}</button>\`;
    filterBar = \`<div class="bar"><span class="barlabel">Show</span>\${mk('all', 'All')}\${mk('reviewed', 'Reviewed')}\${mk('unreviewed', 'Not reviewed')}</div>\`;
  }
  const rows = tasks.length ? tasks.map(t => renderTask(t, name)).join('') : '<p class="empty">None.</p>';
  const descHtml = desc ? \`<p class="section-desc">\${desc}</p>\` : '';
  return \`<details class="section"\${openAttr} ontoggle="onSectionToggle('\${name}', this)">
    <summary class="section-heading">\${emoji} \${label} (\${countStr})</summary>
    \${descHtml}\${filterBar}\${bar}
    <div class="panel">\${rows}</div>
  </details>\`;
}

function render(data) {
  state.lastData = data;   // cache so pure-UI actions (expand, filter, select) re-render without a refetch
  const b = data.buckets, c = data.counts;
  const total = b.ready.length + b.waiting.length + b.needsHuman.length + b.done.length;
  const reviewed = b.done.filter(t => t.reviewed).length;
  document.getElementById('summary').innerHTML =
    'The harness task list (<span class="mono">.harness/tracking/TASKS.json</span>), rendered. '
    + \`\${total} task(s) · \${c.ready} ready · \${c.waiting} waiting · \${c.needsHuman} need a human · \${c.done} done (\${reviewed} reviewed). Auto-refreshes.\`;
  document.getElementById('sections').innerHTML =
    renderSection('ready', '🤖', 'Ready', 'Everything the harness can build with no human involved — either right now, or once an earlier, equally-buildable task in its chain lands.', b.ready, b.ready.length)
    + renderSection('waiting', '⏳', 'Waiting on human tasks', 'Buildable, but blocked somewhere upstream by a task a human still has to clear.', b.waiting, b.waiting.length)
    + renderSection('needsHuman', '🔒', 'Human tasks', 'The loop skips these — a needs-human step, or a task it gave up on. Work them yourself, then mark done.', b.needsHuman, b.needsHuman.length)
    + renderSection('done', '✅', 'Done', null, b.done, \`\${b.done.length} · \${reviewed} reviewed · \${b.done.length - reviewed} not reviewed\`);
}

// Re-render from cached data (no network) — for expand/collapse, filter, and selection changes.
function rerender() { if (state.lastData) render(state.lastData); }

function onLogToggle(el) { el.open ? state.openLogs.add(el.id) : state.openLogs.delete(el.id); }

// Persist a section's collapsed state across re-renders (the 5s refresh rebuilds innerHTML).
function onSectionToggle(name, el) { el.open ? state.closedSections.delete(name) : state.closedSections.add(name); }

function toggleAll(name, checked) {
  const tasks = (state.lastData && state.lastData.buckets && state.lastData.buckets[name]) || [];
  for (const t of tasks) {
    if (!(name === 'needsHuman' || !t.reviewed)) continue;   // only the selectable ones
    checked ? state.selected.add(t.id) : state.selected.delete(t.id);
  }
  rerender();
}

function toggleOpen(id) { state.open.has(id) ? state.open.delete(id) : state.open.add(id); rerender(); }
function toggleSelect(cb) { cb.checked ? state.selected.add(cb.dataset.id) : state.selected.delete(cb.dataset.id); rerender(); }

// Dependency navigation: expand + scroll to + briefly highlight a task wherever it currently lives.
function openTask(id) {
  if (!document.getElementById('task-' + id)) return;
  state.open.add(id);
  rerender();
  const el = document.getElementById('task-' + id);
  if (!el) return;
  el.scrollIntoView({ behavior: 'smooth', block: 'center' });
  el.classList.add('flash');
  setTimeout(() => el.classList.remove('flash'), 1500);
}

function setDoneFilter(mode) { state.doneFilter = mode; rerender(); }

// Shift-click range-select: tracks the last checkbox clicked (by id + bucket). Shift-clicking a
// second checkbox in the SAME bucket selects every checkbox in between to match the just-clicked
// box's new state.
function rangeSelect(e, cb) {
  const bucket = cb.dataset.bucket;
  if (e.shiftKey && state.lastClicked && state.lastClicked.bucket === bucket) {
    const boxes = [...document.querySelectorAll('input[data-bucket="' + bucket + '"]')];
    const i1 = boxes.findIndex(b => b.dataset.id === state.lastClicked.id);
    const i2 = boxes.indexOf(cb);
    if (i1 !== -1 && i2 !== -1) {
      const [lo, hi] = i1 < i2 ? [i1, i2] : [i2, i1];
      const on = cb.checked;
      for (let i = lo; i <= hi; i++) { on ? state.selected.add(boxes[i].dataset.id) : state.selected.delete(boxes[i].dataset.id); }
    }
  }
  state.lastClicked = { bucket, id: cb.dataset.id };
}

// POST + surface failures: a mark-*.sh that errors (e.g. push rejected, gpg-sign failure) comes back
// as res.ok=false or {ok:false}; alert the reason instead of silently re-rendering unchanged (the old
// fire-and-forget looked like a successful no-op when the action had actually failed).
async function post(path, body) {
  try {
    const res = await fetch(path, { method: 'POST', headers: {'Content-Type':'application/json'}, body: JSON.stringify(body) });
    const data = await res.json().catch(() => ({}));
    if (!res.ok || data.ok === false) { alert('Action failed:\\n' + (data.error || res.statusText || 'unknown error')); return false; }
    return true;
  } catch (e) { alert('Action error: ' + e); return false; }
}

async function markDone(id) {
  if (!confirm('Mark ' + id + ' done? Writes human-done.json, commits + pushes.')) return;
  if (await post('/api/mark-done', { ids: [id] })) refresh();
}
async function markFailed(id) {
  const reason = prompt('Mark ' + id + ' as a false success — what was actually wrong?');
  if (!reason) return;
  if (await post('/api/mark-failed', { id, reason })) refresh();
}
async function markReviewed(id) { if (await post('/api/mark-reviewed', { ids: [id] })) refresh(); }

async function bulkAction(bucket) {
  const ids = [...state.selected];
  if (!ids.length) return;
  let ok = true;
  if (bucket === 'needsHuman') {
    if (!confirm('Mark ' + ids.length + ' task(s) done? Writes human-done.json, commits + pushes.')) return;
    ok = await post('/api/mark-done', { ids });
  }
  if (bucket === 'done') ok = await post('/api/mark-reviewed', { ids });
  if (ok) { state.selected.clear(); refresh(); }
}

refresh();
setInterval(refresh, 5000);
</script>
</body>
</html>`;
}

if (require.main === module) {
  server.listen(PORT, '127.0.0.1', () => {
    console.log(`[dashboard] listening on http://127.0.0.1:${PORT}`);
  });
}

module.exports = { server, loadState, isLoopback };
