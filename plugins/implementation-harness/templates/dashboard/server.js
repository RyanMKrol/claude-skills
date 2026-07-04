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

function loadState() {
  const tasksJson = readJson(TASKS_PATH, { tasks: [] });
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
  :root { color-scheme: light dark; }
  body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; max-width: 900px; margin: 2rem auto; padding: 0 1rem; }
  h1 { font-size: 1.3rem; }
  .counts { display: flex; gap: 1rem; margin-bottom: 1.5rem; flex-wrap: wrap; }
  .chip { padding: 0.25rem 0.75rem; border-radius: 999px; background: #eee; font-size: 0.85rem; }
  section { margin-bottom: 1.5rem; }
  section h2 { font-size: 1rem; border-bottom: 1px solid #ccc; padding-bottom: 0.25rem; }
  .task { border: 1px solid #ddd; border-radius: 6px; padding: 0.5rem 0.75rem; margin-bottom: 0.4rem; }
  .task-head { display: flex; align-items: center; gap: 0.5rem; cursor: pointer; }
  .task-id { font-family: monospace; font-weight: bold; }
  .pill { font-size: 0.7rem; padding: 0.1rem 0.5rem; border-radius: 999px; background: #ddd; }
  .pill.failed { background: #f8d7da; color: #842029; }
  .pill.gate { background: #fff3cd; color: #664d03; }
  .badge { font-size: 0.7rem; color: #666; }
  .detail { margin-top: 0.5rem; font-size: 0.85rem; }
  .detail pre { white-space: pre-wrap; background: #f6f6f6; padding: 0.5rem; border-radius: 4px; max-height: 300px; overflow: auto; }
  button { cursor: pointer; }
  .actions { margin-left: auto; display: flex; gap: 0.4rem; }
  .hidden { display: none; }
  .dep-link { font-family: monospace; text-decoration: underline; cursor: pointer; }
  .filt { cursor: pointer; text-decoration: underline; margin-left: 0.5rem; }
  .filt.on { font-weight: bold; text-decoration: none; }
  .task.flash { animation: flash 1.5s ease-out; }
  @keyframes flash { from { background: #fff3cd; } to { background: transparent; } }
</style>
</head>
<body>
<h1>Implementation harness — backlog</h1>
<div class="counts" id="counts"></div>
<div id="sections"></div>
<script>
const state = { open: new Set(), selected: new Set(), doneFilter: 'all', lastClicked: null };

async function refresh() {
  const res = await fetch('/api/backlog');
  const data = await res.json();
  render(data);
}

function esc(s) { return (s || '').replace(/[&<>]/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;'}[c])); }

function depLinks(ids) {
  return (ids || []).map(id => \`<span class="dep-link" onclick="event.stopPropagation(); openTask('\${id}')">\${esc(id)}</span>\`).join(', ') || '(none)';
}

function pillsFor(task, bucketName) {
  let pills = '';
  if (bucketName === 'done' && task.failed) pills += '<span class="pill failed">failed</span>';
  if (task.gate) pills += \`<span class="pill gate">\${esc(task.gate)}</span>\`;
  if (task.unmetDeps && task.unmetDeps.length) pills += \`<span class="badge">waiting on \${depLinks(task.unmetDeps)}</span>\`;
  return pills;
}

function renderTask(task, bucketName) {
  const open = state.open.has(task.id);
  const checked = state.selected.has(task.id) ? 'checked' : '';
  let detail = '';
  if (open) {
    detail = '<div class="detail">';
    detail += \`<div><b>dependsOn:</b> \${depLinks(task.dependsOn)} · <b>scope:</b> \${(task.scope||[]).join(', ') || '(none)'}</div>\`;
    if (task.facets) detail += \`<div><b>facets:</b> \${esc(JSON.stringify(task.facets))}</div>\`;
    if (task.spec) detail += \`<details open><summary>spec</summary><pre>\${esc(task.spec)}</pre></details>\`;
    if (task.worklog) detail += \`<details><summary>worklog</summary><pre>\${esc(task.worklog)}</pre></details>\`;
    if (task.audit) detail += \`<details><summary>audit</summary><pre>\${esc(task.audit)}</pre></details>\`;
    detail += '<div class="actions" style="margin-top:0.5rem;">';
    if (bucketName === 'needsHuman') detail += \`<button onclick="event.stopPropagation(); markDone('\${task.id}')">Mark done</button>\`;
    if (bucketName === 'done' && !task.failed) detail += \`<button onclick="event.stopPropagation(); markFailed('\${task.id}')">Mark failed</button>\`;
    detail += \`<button onclick="event.stopPropagation(); markReviewed('\${task.id}')">\${task.reviewed ? 'Reviewed ✓' : 'Mark reviewed'}</button>\`;
    detail += '</div></div>';
  }
  // Only offer a bulk-select checkbox where bulk actions exist: needsHuman (mark-done) and
  // not-yet-reviewed done tasks (mark-reviewed) — mirrors the two bulk-action groups.
  const showCheckbox = bucketName === 'needsHuman' || (bucketName === 'done' && !task.reviewed);
  const checkbox = showCheckbox
    ? \`<input type="checkbox" \${checked} data-id="\${task.id}" data-bucket="\${bucketName}" onclick="event.stopPropagation(); rangeSelect(event, this)" onchange="toggleSelect(this)">\`
    : '';
  const hidden = (bucketName === 'done' && state.doneFilter !== 'all' && ((state.doneFilter === 'reviewed') !== !!task.reviewed)) ? ' style="display:none"' : '';
  return \`<div class="task" id="task-\${task.id}"\${hidden}>
    <div class="task-head">
      \${checkbox}
      <span class="task-id" onclick="toggleOpen('\${task.id}')">\${esc(task.id)}</span>
      <span onclick="toggleOpen('\${task.id}')">\${esc(task.title || '')}</span>
      \${pillsFor(task, bucketName)}
    </div>
    \${detail}
  </div>\`;
}

function renderSection(name, label, tasks) {
  if (!tasks.length) return '';
  let bulk = '';
  if (name === 'needsHuman' || name === 'done') {
    const n = tasks.filter(t => state.selected.has(t.id)).length;
    bulk = \`<button onclick="bulkAction('\${name}')" \${n ? '' : 'disabled'}>Apply to selected (\${n})</button>\`;
  }
  let filterBar = '';
  if (name === 'done') {
    const mk = (mode, text) => \`<a class="filt\${state.doneFilter===mode?' on':''}" onclick="setDoneFilter('\${mode}')">\${text}</a>\`;
    filterBar = \`<span style="margin-left:0.5rem">Show: \${mk('all','All')} \${mk('reviewed','Reviewed')} \${mk('unreviewed','Not reviewed')}</span>\`;
  }
  return \`<section><h2>\${label} (\${tasks.length}) \${bulk}\${filterBar}</h2>\${tasks.map(t => renderTask(t, name)).join('')}</section>\`;
}

function render(data) {
  document.getElementById('counts').innerHTML = Object.entries(data.counts)
    .map(([k, v]) => \`<span class="chip">\${k}: \${v}</span>\`).join('');
  document.getElementById('sections').innerHTML =
    renderSection('needsHuman', '🔒 Needs you', data.buckets.needsHuman) +
    renderSection('ready', '▶ Ready', data.buckets.ready) +
    renderSection('waiting', '⏳ Waiting', data.buckets.waiting) +
    renderSection('done', '✅ Done', data.buckets.done);
}

function toggleOpen(id) { state.open.has(id) ? state.open.delete(id) : state.open.add(id); refresh(); }
function toggleSelect(cb) { cb.checked ? state.selected.add(cb.dataset.id) : state.selected.delete(cb.dataset.id); refresh(); }

// Dependency navigation: expand + scroll to + briefly highlight a task wherever it currently lives.
function openTask(id) {
  const el = document.getElementById('task-' + id);
  if (!el) return;
  state.open.add(id);
  refresh().then(() => {
    const el2 = document.getElementById('task-' + id);
    if (!el2) return;
    el2.scrollIntoView({ behavior: 'smooth', block: 'center' });
    el2.classList.add('flash');
    setTimeout(() => el2.classList.remove('flash'), 1500);
  });
}

function setDoneFilter(mode) { state.doneFilter = mode; refresh(); }

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

async function markDone(id) {
  if (!confirm('Mark ' + id + ' done? Writes human-done.json, commits + pushes.')) return;
  await fetch('/api/mark-done', { method: 'POST', headers: {'Content-Type':'application/json'}, body: JSON.stringify({ ids: [id] }) }); refresh();
}
async function markFailed(id) {
  const reason = prompt('Mark ' + id + ' as a false success — what was actually wrong?');
  if (!reason) return;
  await fetch('/api/mark-failed', { method: 'POST', headers: {'Content-Type':'application/json'}, body: JSON.stringify({ id, reason }) }); refresh();
}
async function markReviewed(id) { await fetch('/api/mark-reviewed', { method: 'POST', headers: {'Content-Type':'application/json'}, body: JSON.stringify({ ids: [id] }) }); refresh(); }

async function bulkAction(bucket) {
  const ids = [...state.selected];
  if (!ids.length) return;
  if (bucket === 'needsHuman') {
    if (!confirm('Mark ' + ids.length + ' task(s) done? Writes human-done.json, commits + pushes.')) return;
    await fetch('/api/mark-done', { method: 'POST', headers: {'Content-Type':'application/json'}, body: JSON.stringify({ ids }) });
  }
  if (bucket === 'done') await fetch('/api/mark-reviewed', { method: 'POST', headers: {'Content-Type':'application/json'}, body: JSON.stringify({ ids }) });
  state.selected.clear();
  refresh();
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
