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
const { execFile, execFileSync } = require('child_process');
const { computeBacklog, parseJsonl, coldTierIndex, harnessCells, recentActivity, failureKinds, ideasFromJsonl, liveOutputFromJsonl } = require('./lib');

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
const IDEAS_PATH = path.join(HARNESS_DIR, 'tracking', 'IDEAS.jsonl');
const FACETS_PATH = path.join(HARNESS_DIR, 'config', 'facets.json');
const HARNESS_ENV_PATH = path.join(HARNESS_DIR, 'config', 'harness.env');
const DASHBOARD_TITLE_PATH = path.join(HARNESS_DIR, 'custom', 'dashboard-title.txt');
const OUTCOMES_PATH = path.join(LEDGERS_DIR, 'outcomes.jsonl');
const FAILURES_PATH = path.join(LEDGERS_DIR, 'failures.jsonl');
const POLICY_JQ = path.join(SCRIPTS_DIR, 'policy.jq');
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

function escHtml(s) {
  return String(s == null ? '' : s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

// customDashboardTitle() — an optional project label from custom/dashboard-title.txt (opt-in overlay,
// like the other custom/ extension points): blank lines and #-comments ignored, first remaining line
// wins. Lets a project distinguish its dashboard's header + browser tab when several are open at once.
function customDashboardTitle() {
  const text = readText(DASHBOARD_TITLE_PATH);
  if (!text) return null;
  for (const raw of text.split('\n')) {
    const line = raw.trim();
    if (!line || line.startsWith('#')) continue;
    return line;
  }
  return null;
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

// buildOutcomesByTask() — { <taskId>: <latest ledgers/outcomes.jsonl row for that id> }, so a done
// task can show which model/effort actually completed it (finalModel/finalEffort — the tier that
// succeeded, after any escalation, as opposed to startModel/startEffort which is just the cold-start
// floor it began at). Rows are append-order → last wins (a task id should only ever get one terminal
// row, but this stays robust if that ever changes). Robust to a missing/garbled ledger (returns {}).
function buildOutcomesByTask() {
  const out = {};
  for (const row of parseJsonl(readText(OUTCOMES_PATH))) {
    if (row && row.id) out[row.id] = row;
  }
  return out;
}

function loadState() {
  const tasksJson = readJson(TASKS_PATH, { tasks: [] });
  const failures = buildFailures();
  const outcomesByTask = buildOutcomesByTask();
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
      // Attach failed-attempt history to any task that ISN'T a closed-out (failed AND reviewed)
      // done task — a still-open task, or a failed-but-not-yet-reviewed task, both want the "N
      // failed attempts" signal; only a genuinely reviewed failure should suppress it.
      if ((!task.failed || !task.reviewed) && failures[task.id]) task.buildFailures = failures[task.id];
      // Which model/effort actually completed this task, once it has a terminal outcome. A task
      // marked done via the human-done overlay (a needs-human gate, or any task completed by hand)
      // never goes through run_claude()/record_outcome(), so it has no ledger row at all — that's
      // not a gap to leave blank, it's a distinct, equally real "who completed this" answer.
      const oc = outcomesByTask[task.id];
      if (oc && (oc.finalModel || oc.finalEffort)) {
        task.completedWith = { model: oc.finalModel || null, effort: oc.finalEffort || null };
      } else {
        const hd = overlays.humanDone[task.id];
        if (hd && hd.done === true) task.completedWith = { human: true };
      }
    }
  }
  return {
    counts: {
      ready: buckets.ready.length,
      waiting: buckets.waiting.length,
      needsHuman: buckets.needsHuman.length,
      failedPendingReview: buckets.failedPendingReview.length,
      done: buckets.done.length,
    },
    buckets,
  };
}

// ─── Internals view: per-facet calibration state ─────────────────────────────────────────────────
// buildHarnessState() surfaces the harness's OWN calibration for each (layer × work-type) cell:
//   • chosen start model/effort + audit rate — by INVOKING scripts/policy.jq exactly as the loop's
//     pick_base()/audit_gate() do, so the dashboard shows the SAME numbers the loop uses (no reimpl);
//   • build/failure counts — aggregated in lib.js (harnessCells);
//   • the tier ladder + policy knobs (facets.json) + a recent-activity feed.
// Memoised on the max mtime of the inputs so the 5s poll only re-runs jq when a ledger actually changed.
let _harnessCache = { key: null, value: null };

function mtimeKey(paths) {
  let mx = 0;
  for (const p of paths) { try { mx = Math.max(mx, fs.statSync(p).mtimeMs); } catch (_err) { /* missing = 0 */ } }
  return mx;
}

// Cold-start prior: env MODEL/EFFORT wins, else the harness.env `${X:=default}`, else cheapest tier.
function coldStartTuple(ladder) {
  const env = readText(HARNESS_ENV_PATH) || '';
  const grab = (name, envVal) => {
    if (envVal) return envVal;
    const m = new RegExp('\\$\\{' + name + ':=([^}"\\s]+)').exec(env);
    return m ? m[1] : null;
  };
  return {
    model: grab('MODEL', process.env.MODEL) || (ladder[0] && ladder[0].model),
    effort: grab('EFFORT', process.env.EFFORT) || (ladder[0] && ladder[0].effort),
  };
}

// runPolicy(argPairs) — invoke scripts/policy.jq and return the parsed number (or null). Every policy.jq
// arg must be supplied on every call (both branches compile), so callers pass the full set with
// placeholders for the unused branch — mirroring loop.sh's pick_base()/audit_gate() invocations.
// TIER mode's stdout is a 3-field line ("chosen explorePM exploreIdx", -rn since it's a jq string, not
// a bare number) — this only ever wants the first field (chosenIdx); AUDIT mode's stdout is still a
// bare number with no spaces, so splitting on whitespace and taking the first token is a no-op for it.
function runPolicy(argPairs) {
  const args = ['-rn', '-f', POLICY_JQ];
  for (const [flag, name, val] of argPairs) args.push(flag, name, val);
  const out = execFileSync('jq', args, { encoding: 'utf8', timeout: 5000 });
  const n = Number(String(out).trim().split(/\s+/)[0]);
  return Number.isFinite(n) ? n : null;
}

function buildHarnessState() {
  const facets = readJson(FACETS_PATH, {});
  const ladder = (facets.tiers && facets.tiers.ladder) || [];
  const pol = facets.policy || {};
  const floor = pol.floor != null ? pol.floor : 0.75;
  const minN = pol.minN != null ? pol.minN : 6;
  const auditStartN = pol.auditStartN != null ? pol.auditStartN : 3;
  const auditFloorN = pol.auditFloorN != null ? pol.auditFloorN : 8;
  const auditFloorPM = Math.round((pol.auditFloor != null ? pol.auditFloor : 0.10) * 1000);
  const explorePM = pol.exploreProbabilityPM != null ? pol.exploreProbabilityPM : 0;
  const exploreCooldownN = pol.exploreCooldownN != null ? pol.exploreCooldownN : 40;

  const key = mtimeKey([OUTCOMES_PATH, FAILURES_PATH, FACETS_PATH, OVERLAY_PATHS.manualFail, TASKS_PATH]);
  if (_harnessCache.key === key && _harnessCache.value) return _harnessCache.value;

  const outcomes = parseJsonl(readText(OUTCOMES_PATH));
  const failures = parseJsonl(readText(FAILURES_PATH));
  const manualFail = readJson(OVERLAY_PATHS.manualFail, {});
  const tasks = (readJson(TASKS_PATH, { tasks: [] }).tasks) || [];
  const coldIdx = coldTierIndex(ladder, ...Object.values(coldStartTuple(ladder)));
  const cells = harnessCells(outcomes, failures, tasks, manualFail);

  let jqOk = true;
  try { execFileSync('jq', ['--version'], { timeout: 3000, stdio: 'ignore' }); } catch (_e) { jqOk = false; }
  if (jqOk && cells.length) {
    const rowsJson = JSON.stringify(outcomes), ladderJson = JSON.stringify(ladder), mfJson = JSON.stringify(manualFail);
    for (const c of cells) {
      try {
        const chosenIdx = runPolicy([
          ['--argjson', 'rows', rowsJson], ['--argjson', 'tiers', ladderJson],
          ['--arg', 'layer', c.layer], ['--arg', 'wt', c.workType],
          ['--argjson', 'floor', String(floor)], ['--argjson', 'minN', String(minN)], ['--argjson', 'coldIdx', String(coldIdx)],
          ['--argjson', 'manualFail', mfJson], ['--argjson', 'risk', '[]'],
          ['--argjson', 'auditCount', '-1'], ['--argjson', 'auditStartN', String(auditStartN)],
          ['--argjson', 'auditFloorN', String(auditFloorN)], ['--argjson', 'auditFloorPM', String(auditFloorPM)],
          ['--argjson', 'explorePM', String(explorePM)], ['--argjson', 'exploreCooldownN', String(exploreCooldownN)],
        ]);
        const tier = (chosenIdx != null && ladder[chosenIdx]) || null;
        c.chosenModel = tier ? tier.model : null;
        c.chosenEffort = tier ? tier.effort : null;
        c.chosenIdx = chosenIdx;
        c.hasHistory = c.builds >= minN;   // rough "data-driven vs cold-start prior" hint

        // audit rate: confirmed-audited successes in the cell (== loop's audit_gate query), then policy audit branch
        const auditCount = outcomes.filter((r) => r.facets && r.facets.layer === c.layer && r.facets.workType === c.workType
          && r.blocked === false && r.verification === 'audited' && !(manualFail[r.id] && manualFail[r.id].failed === true)).length;
        const pm = runPolicy([
          ['--argjson', 'auditCount', String(auditCount)], ['--argjson', 'risk', '[]'],
          ['--argjson', 'auditStartN', String(auditStartN)], ['--argjson', 'auditFloorN', String(auditFloorN)], ['--argjson', 'auditFloorPM', String(auditFloorPM)],
          ['--argjson', 'rows', '[]'], ['--argjson', 'tiers', '[]'], ['--arg', 'layer', ''], ['--arg', 'wt', ''],
          ['--argjson', 'floor', '0'], ['--argjson', 'minN', '0'], ['--argjson', 'coldIdx', '0'], ['--argjson', 'manualFail', '{}'],
          ['--argjson', 'explorePM', '0'], ['--argjson', 'exploreCooldownN', '0'],
        ]);
        c.auditPct = pm != null ? Math.round(pm / 10) : null;
      } catch (_err) { /* one bad cell shouldn't blank the rest; leave its calibration fields undefined */ }
    }
  }

  const value = {
    ladder, coldIdx,
    policy: { floor, minN, auditStartN, auditFloorN, auditFloor: auditFloorPM / 1000, auditorModel: pol.auditorModel || null, auditorEffort: pol.auditorEffort || null },
    cells, recent: recentActivity(outcomes, failures, 20), failureKinds: failureKinds(failures), jqOk,
  };
  _harnessCache = { key, value };
  return value;
}

// ─── Live activity ("Now" strip): lock + heartbeat + log tail + freshness ────────────────────────
const NAME = path.basename(ROOT);
const HEARTBEAT_PATH = path.join(WORKLOG_DIR, '.current.json');

// envKnob(name, fallback) — real env wins, else the harness.env `${NAME:=default}` line, else fallback
// (same precedence the loop's own `: "${VAR:=…}"` sourcing gives).
function envKnob(name, fallback) {
  if (process.env[name]) return process.env[name];
  const env = readText(HARNESS_ENV_PATH) || '';
  const m = new RegExp('\\$\\{' + name + ':=([^}"\\s]+)').exec(env);
  return m ? m[1] : fallback;
}

let _gitCommon = undefined;   // memoised — the git common dir never changes while the server runs
function gitCommonDir() {
  if (_gitCommon !== undefined) return _gitCommon;
  try {
    let d = execFileSync('git', ['rev-parse', '--git-common-dir'], { cwd: ROOT, encoding: 'utf8', timeout: 3000 }).trim();
    if (!path.isAbsolute(d)) d = path.join(ROOT, d);
    _gitCommon = d;
  } catch (_err) { _gitCommon = null; }
  return _gitCommon;
}

// lockState() — read the loop's own mkdir lock (<git-common>/<name>-loop.lock/pid, identical
// derivation to repo-lock.sh) and probe the PID, so "running / idle / stale lock" can never
// disagree with what the loop itself would conclude.
function lockState() {
  const common = gitCommonDir();
  if (!common) return { held: false, pid: null, alive: false };
  const lockDir = path.join(common, `${NAME}-loop.lock`);
  if (!fs.existsSync(lockDir)) return { held: false, pid: null, alive: false };
  const pid = parseInt(readText(path.join(lockDir, 'pid')) || '', 10);
  if (!Number.isFinite(pid)) return { held: true, pid: null, alive: false };
  let alive = true;
  try { process.kill(pid, 0); } catch (_err) { alive = false; }
  return { held: true, pid, alive };
}

// claudeOutTailFor(phase) — the builder's or auditor's live output, reconstructed from whichever
// worklog was touched most recently (the worktree variant writes inside the loop worktree,
// ../<name>-loop/.harness/worklog/; the in-place variant writes in the primary checkout). Since
// loop.sh/loop.in-place.sh invoke claude with --output-format stream-json, the raw transcript lives
// in `.claude-out.<phase>.jsonl` (streamed incrementally — see run_claude()); `.claude-out.<phase>`
// is that same invocation's plain-text reconstruction. Build and audit are SEPARATE files precisely
// so one doesn't truncate the other — before this, both phases shared one filename, so the moment
// the audit started, its first byte wiped out the builder's still-fresh output via `tee`.
function claudeOutTailFor(phase) {
  const dirs = [WORKLOG_DIR, path.join(path.dirname(ROOT), `${NAME}-loop`, '.harness', 'worklog')];
  const candidates = [];
  for (const d of dirs) { candidates.push(path.join(d, `.claude-out.${phase}.jsonl`), path.join(d, `.claude-out.${phase}`)); }
  let best = null, bestM = 0;
  for (const p of candidates) {
    try { const m = fs.statSync(p).mtimeMs; if (m > bestM) { bestM = m; best = p; } } catch (_err) { /* absent */ }
  }
  if (!best) return { text: null, tool: null };
  const text = readText(best);
  if (!text) return { text: null, tool: null };
  if (best.endsWith('.jsonl')) {
    const live = liveOutputFromJsonl(text);
    return { text: live.text ? live.text.slice(-8000) : null, tool: live.tool };
  }
  const lines = text.split('\n');
  return { text: lines.slice(-40).join('\n').slice(-8000), tool: null };
}

// claudeOutTail() — both phases' live output, each independent (see claudeOutTailFor above).
function claudeOutTail() {
  return { build: claudeOutTailFor('build'), audit: claudeOutTailFor('audit') };
}

// freshness() — how stale is what this dashboard renders? Age of the last `git fetch` (FETCH_HEAD
// mtime) + whether the local checkout's HEAD is the same commit as origin/<main>. The dashboard reads
// LOCAL files, so with the loop stopped and no fetch, it can silently lag origin — this surfaces that.
function freshness() {
  const common = gitCommonDir();
  let lastFetchSec = null;
  if (common) {
    try { lastFetchSec = Math.max(0, Math.round((Date.now() - fs.statSync(path.join(common, 'FETCH_HEAD')).mtimeMs) / 1000)); } catch (_err) { /* never fetched */ }
  }
  const rev = (ref) => {
    try { return execFileSync('git', ['rev-parse', ref], { cwd: ROOT, encoding: 'utf8', timeout: 3000 }).trim(); } catch (_err) { return null; }
  };
  const mainBranch = envKnob('MAIN_BRANCH', 'main');
  const localHead = rev('HEAD');
  const originHead = rev(`origin/${mainBranch}`);
  return {
    lastFetchSec,
    mainBranch,
    inSync: !!(localHead && originHead && localHead === originHead),
    known: !!(localHead && originHead),
  };
}

function activityState() {
  const live = claudeOutTail();
  return {
    lock: lockState(),
    current: readJson(HEARTBEAT_PATH, null),
    build: live.build,
    audit: live.audit,
    freshness: freshness(),
    fetchEverySec: parseInt(envKnob('HARNESS_DASHBOARD_FETCH_SECONDS', '0'), 10) || 0,
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

    if (req.method === 'GET' && url.pathname === '/api/ideas') {
      const ideas = ideasFromJsonl(readText(IDEAS_PATH));
      return sendJson(res, 200, { ideas, empty: ideas.length === 0 });
    }

    if (req.method === 'GET' && url.pathname === '/api/harness') {
      return sendJson(res, 200, buildHarnessState());
    }

    if (req.method === 'GET' && url.pathname === '/api/activity') {
      return sendJson(res, 200, activityState());
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
        // A human completing a needs-human task themselves IS the review — chain mark-reviewed.sh so it
        // doesn't also need a separate manual click (mirrors: marking a task failed is itself a review
        // verdict). Two single-purpose script calls, two commits, serialized safely under repo-lock.sh.
        await runScript('mark-reviewed.sh', ids);
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
  const customTitle = customDashboardTitle();
  const titleHtml = customTitle ? escHtml(customTitle) : null;
  return `<!doctype html>
<html>
<head>
<meta charset="utf-8">
<title>${titleHtml ? titleHtml + ' — ' : ''}Backlog — implementation harness</title>
<style>
  /* Four bold, hue-distinct dark themes (client picks one — see the theme picker below); baked in
     at +10% brightness over the originally-workshopped values. Semantic colors (green/red/yellow/
     human) are tuned per theme for contrast, not swapped for the accent — they mean the same thing
     (done/failed/blocked/needs-human) in every theme. */
  :root, [data-theme="ink"]{
    --bg:#1a2b45; --panel:#203453; --panel-2:#273d65; --border:#3c537a;
    --text:#e9eefb; --muted:#9fafcd; --accent:#ff7a54;
    --green:#4ad991; --red:#ff5c6e; --yellow:#ffcf5c; --amber:#ff9d4d; --human:#b98bff;
  }
  [data-theme="forest"]{
    --bg:#1e3c2e; --panel:#254435; --panel-2:#2c513d; --border:#426953;
    --text:#e7f2ea; --muted:#94b5a1; --accent:#f2b53c;
    --green:#4fd1a5; --red:#ff6b5c; --yellow:#e0c34a; --amber:#f2b53c; --human:#6fa8ff;
  }
  [data-theme="plum"]{
    --bg:#2f1f45; --panel:#362553; --panel-2:#402c63; --border:#584180;
    --text:#f1e9f8; --muted:#b8a5cf; --accent:#ff5ec4;
    --green:#5fd18a; --red:#ff5c6e; --yellow:#f0c14a; --amber:#f2b53c; --human:#6fa8ff;
  }
  [data-theme="amber"]{
    --bg:#3d2a15; --panel:#483414; --panel-2:#543717; --border:#73511d;
    --text:#f5e9d6; --muted:#ba9a69; --accent:#ffa629;
    --green:#6bd453; --red:#ff5c5c; --yellow:#f0c33e; --amber:#ffa629; --human:#5b9bff;
  }
  *{box-sizing:border-box}
  body{margin:0;background:var(--bg);color:var(--text);font:14px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;}
  .container{max-width:1000px;margin:0 auto;padding:26px 20px 72px;}
  h1{font-size:22px;font-weight:700;margin:0 0 4px;}
  .sub{color:var(--muted);margin:0 0 14px;font-size:13px;}
  .mono{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;}
  a{color:var(--accent);text-decoration:none} a:hover{text-decoration:underline}
  button{cursor:pointer;font:inherit}

  /* ---- overview strip: at-a-glance counts above the sections ---- */
  .summary-strip{display:flex;gap:10px;margin:0 0 22px;flex-wrap:wrap;}
  .summary-chip{flex:1 1 160px;background:var(--panel);border:1px solid var(--border);border-radius:10px;padding:12px 14px;display:flex;flex-direction:column;gap:2px;cursor:pointer;text-align:left;font:inherit;color:inherit;transition:border-color .15s,background .15s;}
  .summary-chip:hover{background:color-mix(in srgb, var(--text) 4%, var(--panel));border-color:color-mix(in srgb, var(--text) 20%, var(--border));}
  .summary-chip .n{font-family:ui-monospace,Menlo,monospace;font-variant-numeric:tabular-nums;font-size:22px;font-weight:600;line-height:1.1;}
  .summary-chip .n small{color:var(--muted);font-weight:500;font-size:14px;}
  .summary-chip .lbl{font-size:11.5px;color:var(--muted);letter-spacing:.02em;}
  .summary-chip.action .n{color:var(--human);}
  .summary-chip.review .n{color:var(--red);}
  .summary-chip.done .n{color:var(--green);}

  .pill{display:inline-block;font-size:11px;padding:1px 8px;border-radius:999px;background:var(--panel-2);border:1px solid var(--border);color:var(--muted);white-space:nowrap;margin-left:4px;}
  .pill.buildable{color:var(--amber);background:color-mix(in srgb, var(--amber) 14%, transparent);border-color:color-mix(in srgb, var(--amber) 40%, transparent);}
  .pill.human{color:#fff;background:var(--human);border-color:var(--human);}
  .pill.blocked{color:var(--yellow);background:color-mix(in srgb, var(--yellow) 16%, transparent);border-color:color-mix(in srgb, var(--yellow) 45%, transparent);font-weight:600;}
  .pill.done{color:var(--green);background:color-mix(in srgb, var(--green) 14%, transparent);border-color:color-mix(in srgb, var(--green) 35%, transparent);}
  .pill.failed{color:var(--red);background:color-mix(in srgb, var(--red) 12%, transparent);border-color:color-mix(in srgb, var(--red) 35%, transparent);}
  .pill.reviewed{color:var(--green);background:color-mix(in srgb, var(--green) 14%, transparent);border-color:color-mix(in srgb, var(--green) 35%, transparent);}

  /* ---- section-as-card: one bordered/rounded container, header divided from body by a border ---- */
  details.section{margin:0 0 22px;background:var(--panel);border:1px solid var(--border);border-radius:14px;overflow:hidden;}
  summary.section-heading{display:flex;align-items:flex-start;gap:10px;padding:16px 18px 14px;cursor:pointer;list-style:none;user-select:none;font-size:14.5px;font-weight:650;color:var(--text);}
  summary.section-heading::-webkit-details-marker{display:none}
  summary.section-heading::before{content:'▾';font-size:11px;color:var(--muted);margin-top:3px;transition:transform .15s;flex-shrink:0;}
  details.section:not([open]) > summary.section-heading::before{transform:rotate(-90deg)}
  summary.section-heading .count{font-family:ui-monospace,Menlo,monospace;font-variant-numeric:tabular-nums;color:var(--muted);font-weight:500;font-size:13px;margin-left:2px;}
  .section-desc{color:var(--muted);font-size:12.5px;padding:14px 18px 12px;margin:0;font-weight:400;}
  .section-body{border-top:1px solid var(--border);}
  .panel{padding:0 18px;}
  .empty{color:var(--muted);padding:11px 2px;}

  .section-toolbar{display:flex;align-items:center;gap:9px;flex-wrap:wrap;padding:10px 18px;border-bottom:1px solid var(--border);background:color-mix(in srgb, black 12%, transparent);}

  .taskrow .row{display:flex;gap:8px;align-items:baseline;flex-wrap:wrap;padding:9px 0;cursor:pointer;user-select:none;border-bottom:1px solid var(--border);}
  .taskrow .row:hover{background:color-mix(in srgb, var(--text) 3%, transparent);}
  .panel > .taskrow:last-child .row{border-bottom:none}
  .caret{color:var(--muted);font-size:10px;min-width:10px}
  .tid{font-weight:700;min-width:46px}
  .title{flex:1;min-width:220px}

  .expand{padding:12px 16px 14px;margin:0 0 8px;background:var(--panel-2);border:1px solid var(--border);border-radius:6px;font-size:13px;}
  .expand pre{white-space:pre-wrap;background:var(--panel);border:1px solid var(--border);border-radius:4px;padding:8px;max-height:300px;overflow:auto;font-size:12px;}
  .expand details{margin-top:8px} .expand summary{color:var(--muted);font-size:12px;cursor:pointer;user-select:none}
  .expand .md-body{background:none;border:none;padding:0}
  .dep-link{font-family:ui-monospace,Menlo,monospace;color:var(--accent);text-decoration:underline;text-underline-offset:2px;cursor:pointer}
  .kv{font-size:12px;color:var(--muted);margin-bottom:6px}

  .bar{display:flex;align-items:center;gap:9px;flex-wrap:wrap;margin:8px 0 6px;}
  .barlabel{font-size:11px;color:var(--muted);text-transform:uppercase;letter-spacing:.04em}
  .barbtn{font-size:11px;padding:3px 9px;border-radius:5px;border:1px solid var(--border);background:var(--panel-2);color:var(--muted);}
  .barbtn:hover{border-color:var(--accent);color:var(--text)}
  .barbtn.on{border-color:var(--accent);color:var(--accent);background:color-mix(in srgb, var(--accent) 12%, transparent)}
  .act{font-size:12px;padding:3px 11px;border-radius:6px;border:1px solid var(--border);background:var(--panel-2);color:var(--text)}
  .act:hover{border-color:var(--accent)}
  .act.danger:hover{border-color:var(--red);color:var(--red)}
  .act[disabled]{opacity:.5;cursor:default}
  label.sel{display:inline-flex;align-items:center;gap:6px;cursor:pointer;font-size:13px;color:var(--muted)}

  .flash{animation:flash 1.6s ease-out;border-radius:6px}
  @keyframes flash{from{background:color-mix(in srgb, var(--accent) 25%, transparent)}to{background:transparent}}

  .topbar{display:flex;align-items:center;gap:16px;flex-wrap:wrap;margin:0 0 12px;}
  .topbar h1{margin:0}
  /* An SVG icon, not a text/emoji glyph — confirmed by pixel-level screenshot verification (real
     GPU compositing, not disabled) that a rotating text glyph visibly wobbles: the browser
     re-hints/re-rasterizes the glyph's font-atlas texture at each angle, drifting up to ~0.7px
     per frame. An SVG shape has no such glyph-atlas resampling step and measured EXACTLY 0px of
     centroid drift across a full rotation under the same conditions. 29px = the 22px h1 baseline
     + 30%, rounded to a whole pixel (fractional dimensions add their own sub-pixel layout drift).
     will-change/backface-visibility:hidden put the rotation on its own GPU layer. */
  .cog{display:inline-block;width:29px;height:29px;color:var(--text);vertical-align:middle;transform-origin:50% 50%;will-change:transform;backface-visibility:hidden}
  .cog.spin{animation:cogspin 1s linear infinite}
  @keyframes cogspin{from{transform:rotate(0deg)}to{transform:rotate(360deg)}}
  @media (prefers-reduced-motion: reduce){.cog.spin{animation:none}}
  .themepicker{display:flex;align-items:center;gap:5px;margin-left:auto}
  .swatch{width:20px;height:20px;padding:0;border-radius:50%;border:2px solid var(--border);cursor:pointer;box-shadow:none}
  .swatch:hover{border-color:var(--muted)}
  .swatch.active{border-color:var(--accent);box-shadow:0 0 0 2px var(--accent)}

  /* "Now" strip — live loop status + freshness, on every tab */
  .nowbar{display:flex;align-items:center;gap:8px;flex-wrap:wrap;margin:0 0 18px;font-size:12px}
  .nowpill{display:inline-flex;align-items:center;gap:6px;font-size:12px;padding:3px 11px;border-radius:999px;border:1px solid var(--border);background:var(--panel);color:var(--muted);white-space:nowrap}
  .nowpill.run{color:var(--green);border-color:color-mix(in srgb, var(--green) 45%, transparent);background:color-mix(in srgb, var(--green) 10%, transparent);font-weight:600}
  .nowpill.idle{color:var(--muted)}
  .nowpill.warn{color:var(--yellow);border-color:color-mix(in srgb, var(--yellow) 45%, transparent);background:color-mix(in srgb, var(--yellow) 10%, transparent);font-weight:600}
  .nowpill.bad{color:var(--red);border-color:color-mix(in srgb, var(--red) 40%, transparent);background:color-mix(in srgb, var(--red) 8%, transparent);font-weight:600}
  .nowbar details{flex-basis:100%;margin-top:2px}
  .nowbar summary{color:var(--muted);font-size:12px;cursor:pointer;user-select:none}
  .nowbar pre{white-space:pre-wrap;background:var(--panel);border:1px solid var(--border);border-radius:6px;padding:8px;max-height:260px;overflow:auto;font-size:11px;font-family:ui-monospace,Menlo,monospace;margin:6px 0 0}

  .kindpills{display:flex;gap:8px;flex-wrap:wrap;margin:6px 0 2px}
  .tabs{display:flex;gap:6px;flex-wrap:wrap}
  .tab{font-size:13px;padding:5px 13px;border-radius:7px;border:1px solid var(--border);background:var(--panel);color:var(--muted);}
  .tab:hover{border-color:var(--accent);color:var(--text)}
  .tab.on{background:var(--accent);border-color:var(--accent);color:var(--bg);font-weight:600}
  .view[hidden]{display:none}
  .note{color:var(--muted);font-size:12px;margin:6px 0 14px}

  /* Ideas (rendered markdown) */
  .md-body{background:var(--panel);border:1px solid var(--border);border-radius:10px;padding:6px 22px 20px;}
  .md-body h1,.md-body h2,.md-body h3,.md-body h4{color:var(--text);margin:18px 0 8px}
  .md-body h1{font-size:20px} .md-body h2{font-size:17px} .md-body h3{font-size:15px} .md-body h4{font-size:13px}
  .md-body p{margin:8px 0}
  .md-body ul,.md-body ol{margin:8px 0;padding-left:24px} .md-body li{margin:3px 0}
  .md-body code{font-family:ui-monospace,Menlo,monospace;font-size:12px;background:var(--panel-2);border:1px solid var(--border);border-radius:4px;padding:1px 5px}
  .md-body pre{background:var(--panel-2);border:1px solid var(--border);border-radius:6px;padding:10px;overflow:auto} .md-body pre code{background:none;border:none;padding:0}
  .md-body blockquote{margin:8px 0;padding:2px 14px;border-left:3px solid var(--border);color:var(--muted)}
  .md-body hr{border:none;border-top:1px solid var(--border);margin:16px 0}
  .md-body a{color:var(--accent)}

  /* Internals (per-facet calibration) */
  .htitle{font-size:14px;font-weight:700;text-transform:uppercase;letter-spacing:.04em;color:var(--muted);margin:22px 0 8px}
  .htitle:first-child{margin-top:2px}
  .ftable{width:100%;border-collapse:collapse;background:var(--panel);border:1px solid var(--border);border-radius:10px;overflow:hidden;font-size:13px}
  .ftable th{text-align:left;font-size:11px;text-transform:uppercase;letter-spacing:.03em;color:var(--muted);padding:8px 10px;border-bottom:1px solid var(--border);font-weight:600}
  .ftable td{padding:7px 10px;border-bottom:1px solid var(--border)} .ftable tr:last-child td{border-bottom:none}
  .ftable td.num,.ftable th.num{text-align:right;font-variant-numeric:tabular-nums}
  .qtip{display:inline-flex;align-items:center;justify-content:center;width:13px;height:13px;border-radius:50%;background:var(--panel-2);border:1px solid var(--border);color:var(--muted);font-size:9px;font-weight:700;line-height:1;cursor:help;text-transform:none;letter-spacing:normal;vertical-align:1px}
  .qtip:hover,.qtip:focus{border-color:var(--accent);color:var(--accent)}
  .qtip:focus{outline:2px solid var(--accent);outline-offset:2px}
  #qtip-popup{position:fixed;z-index:50;max-width:260px;background:var(--panel-2);color:var(--text);border:1px solid var(--border);padding:7px 10px;border-radius:7px;font-size:11.5px;font-weight:400;line-height:1.4;text-transform:none;letter-spacing:normal;box-shadow:0 4px 14px rgba(0,0,0,.35);pointer-events:none;display:none}
  .facet-name{font-weight:600}
  .model-tag{font-family:ui-monospace,Menlo,monospace;font-size:12px}
  .cold-tag{font-size:10px;color:var(--muted);margin-left:5px}
  .refgrid{display:flex;gap:16px;flex-wrap:wrap}
  .refcard{flex:1;min-width:240px;background:var(--panel);border:1px solid var(--border);border-radius:10px;padding:12px 16px;font-size:13px}
  .refcard ol{margin:6px 0 0;padding-left:22px} .refcard li{margin:2px 0;font-size:12px}
  .refcard .knob{display:flex;justify-content:space-between;gap:12px;font-size:12px;padding:2px 0;color:var(--muted)} .refcard .knob b{color:var(--text);font-weight:600;text-align:right}
  .recent{background:var(--panel);border:1px solid var(--border);border-radius:10px;padding:4px 14px}
  .recent .ev{display:flex;gap:10px;align-items:baseline;padding:5px 0;border-bottom:1px solid var(--border);font-size:12px} .recent .ev:last-child{border-bottom:none}
  .recent .ev .t{color:var(--muted);font-variant-numeric:tabular-nums;white-space:nowrap}
  .recent .ev .eid{font-weight:700;min-width:42px}
</style>
</head>
<body>
<div class="container">
<div class="topbar">
  <h1><svg id="cog" class="cog" viewBox="0 0 24 24" role="img" aria-label="loop status gear"><title>Spins while the loop is actively running</title><defs><mask id="gearHole"><rect width="24" height="24" fill="white"/><circle cx="12" cy="12" r="1.9" fill="black"/></mask></defs><g fill="currentColor" mask="url(#gearHole)"><circle cx="12" cy="12" r="4.6"/><rect x="10.70" y="5.30" width="2.60" height="3.10" rx="0.6" transform="rotate(0.0 12 12)"/><rect x="10.70" y="5.30" width="2.60" height="3.10" rx="0.6" transform="rotate(45.0 12 12)"/><rect x="10.70" y="5.30" width="2.60" height="3.10" rx="0.6" transform="rotate(90.0 12 12)"/><rect x="10.70" y="5.30" width="2.60" height="3.10" rx="0.6" transform="rotate(135.0 12 12)"/><rect x="10.70" y="5.30" width="2.60" height="3.10" rx="0.6" transform="rotate(180.0 12 12)"/><rect x="10.70" y="5.30" width="2.60" height="3.10" rx="0.6" transform="rotate(225.0 12 12)"/><rect x="10.70" y="5.30" width="2.60" height="3.10" rx="0.6" transform="rotate(270.0 12 12)"/><rect x="10.70" y="5.30" width="2.60" height="3.10" rx="0.6" transform="rotate(315.0 12 12)"/></g></svg> ${titleHtml || 'Harness'}</h1>
  <nav class="tabs">
    <button class="tab on" data-view="backlog" onclick="switchView('backlog')">Backlog</button>
    <button class="tab" data-view="ideas" onclick="switchView('ideas')">Ideas</button>
    <button class="tab" data-view="harness" onclick="switchView('harness')">Internals</button>
  </nav>
  <div class="themepicker" title="Dashboard theme — saved in this browser only">
    <button type="button" class="swatch" data-theme="ink" style="background:#1a2b45" title="Ink" onclick="setTheme('ink')"></button>
    <button type="button" class="swatch" data-theme="forest" style="background:#1e3c2e" title="Forest" onclick="setTheme('forest')"></button>
    <button type="button" class="swatch" data-theme="plum" style="background:#2f1f45" title="Plum" onclick="setTheme('plum')"></button>
    <button type="button" class="swatch" data-theme="amber" style="background:#3d2a15" title="Amber" onclick="setTheme('amber')"></button>
  </div>
</div>
<div id="nowbar" class="nowbar"></div>
<div id="view-backlog" class="view">
  <p class="sub" id="summary"></p>
  <div id="summary-chips" class="summary-strip"></div>
  <div id="sections"></div>
</div>
<div id="view-ideas" class="view" hidden>
  <p class="sub" id="ideas-summary"></p>
  <div id="ideas-md"></div>
</div>
<div id="view-harness" class="view" hidden>
  <div id="harness-body"></div>
</div>
</div>
<script>
const HARNESS_PROJECT_KEY = ${JSON.stringify(NAME)};
const state = { activeView: 'backlog', open: new Set(), openLogs: new Set(), closedSections: new Set(), selected: new Set(), doneFilter: 'all', lastClicked: null, lastData: null, lastFetchedJson: null, openIdeas: new Set(), lastIdeasData: null, lastIdeasJson: null, lastHarnessJson: null, lastNowJson: null, nowLogOpen: { build: false, audit: false } };

function switchView(name) {
  state.activeView = name;
  var tabs = document.querySelectorAll('.tab');
  for (var i = 0; i < tabs.length; i++) tabs[i].classList.toggle('on', tabs[i].dataset.view === name);
  var views = document.querySelectorAll('.view');
  for (var j = 0; j < views.length; j++) views[j].hidden = (views[j].id !== 'view-' + name);
  refreshActive();
}

// One 5s poll, dispatched to whichever view is active (plus the always-on "Now" strip). Each view
// keeps its own change-guard so an unchanged poll never rebuilds the DOM (preserves scroll / open
// <pre> position — see the backlog note).
function refreshActive() {
  refreshNow();
  if (state.activeView === 'ideas') return refreshIdeas();
  if (state.activeView === 'harness') return refreshHarness();
  return refreshBacklog();
}

async function refreshNow() {
  let data; try { data = await (await fetch('/api/activity')).json(); } catch (e) { return; }
  const json = JSON.stringify(data);
  if (json === state.lastNowJson) return;
  state.lastNowJson = json;
  renderNow(data);
}

function ago(sec) {
  if (sec == null) return 'never';
  if (sec < 60) return sec + 's ago';
  if (sec < 3600) return Math.round(sec / 60) + 'm ago';
  return (sec / 3600).toFixed(1) + 'h ago';
}

// renderNow(data) — the live status strip: what the loop is doing RIGHT NOW (from its lock +
// worklog/.current.json heartbeat), how fresh the rendered data is vs origin, and a collapsible
// tail of the builder's live output.
// nowLogDetails(phase, info, cur) — one collapsible live-output panel for a single phase (build or
// audit). Build and audit are rendered as two INDEPENDENT panels (not one shared one) because they
// now come from two independent files — see claudeOutTailFor() — so the audit starting no longer
// blanks out the builder's still-fresh output, and vice versa.
function nowLogDetails(phase, info, cur) {
  if (!info || !info.text) return '';
  const id = 'now-log-' + phase;
  const open = state.nowLogOpen[phase];
  const activeTask = cur && cur.task && (cur.phase || '').toLowerCase().indexOf(phase === 'audit' ? 'audit' : 'build') !== -1;
  const label = 'live output — ' + phase + (activeTask ? ' (' + esc(cur.task) + ')' : '');
  return \`<details id="\${id}" ontoggle="onNowLogToggle('\${phase}', this)"\${open ? ' open' : ''}>
    <summary>\${label}</summary>
    <pre id="\${id}-pre">\${esc(info.text)}</pre>
  </details>\`;
}

function onNowLogToggle(phase, el) { state.nowLogOpen[phase] = el.open; }

function renderNow(data) {
  const el = document.getElementById('nowbar');
  const lock = data.lock || {}, cur = data.current, fr = data.freshness || {};
  const cog = document.getElementById('cog');
  if (cog) cog.classList.toggle('spin', !!(lock.held && lock.alive));
  let h = '';
  if (lock.held && lock.alive) {
    if (cur && cur.task) {
      const tier = cur.model ? ' · ' + esc(cur.model) + (cur.effort ? '/' + esc(cur.effort) : '') : '';
      h += '<span class="nowpill run">▶ ' + esc(cur.task) + ' — ' + esc(cur.phase || 'working')
         + ' (rung ' + esc(String(cur.rung)) + ', attempt ' + esc(String(+cur.attempt + 1)) + tier + ')</span>';
    } else {
      h += '<span class="nowpill run">▶ loop running (PID ' + esc(String(lock.pid || '?')) + ')</span>';
    }
  } else if (lock.held && !lock.alive) {
    h += '<span class="nowpill warn" title="The lock dir exists but its PID is dead — a loop was interrupted. Run the loop-recover skill.">⚠ stale lock (PID ' + esc(String(lock.pid || '?')) + ' dead) — run loop-recover</span>';
  } else {
    h += '<span class="nowpill idle">◼ loop idle</span>';
  }
  // Which phase is CURRENTLY active drives the tool pill — the heartbeat's own phase (e.g.
  // "auditing") decides between the build and audit live-output streams' tool field.
  const activePhase = (cur && /audit/i.test(cur.phase || '')) ? 'audit' : 'build';
  const activeTool = data[activePhase] && data[activePhase].tool;
  if (lock.held && lock.alive && activeTool) {
    h += '<span class="nowpill run" title="From the live output stream — the tool call most recently started, with no response text after it yet">▶ running ' + esc(activeTool) + '…</span>';
  }
  if (fr.known && !fr.inSync) {
    h += '<span class="nowpill bad" title="The local checkout this dashboard reads is not on the same commit as origin/' + esc(fr.mainBranch || 'main') + ' — what you see may be stale or ahead.">local ≠ origin/' + esc(fr.mainBranch || 'main') + '</span>';
  }
  const fetchCls = (fr.lastFetchSec == null || fr.lastFetchSec > 900) ? 'nowpill warn' : 'nowpill idle';
  const fetchNote = data.fetchEverySec > 0 ? ' (auto-fetch ' + data.fetchEverySec + 's)' : '';
  h += '<span class="' + fetchCls + '" title="Age of the last git fetch — the dashboard renders LOCAL files, so origin changes are invisible until something fetches. Set HARNESS_DASHBOARD_FETCH_SECONDS to have the dashboard fetch itself.">origin seen: ' + ago(fr.lastFetchSec) + fetchNote + '</span>';
  h += nowLogDetails('build', data.build, cur);
  h += nowLogDetails('audit', data.audit, cur);
  el.innerHTML = h;
  ['build', 'audit'].forEach(function (phase) {
    const pre = document.getElementById('now-log-' + phase + '-pre');
    if (pre && state.nowLogOpen[phase]) pre.scrollTop = pre.scrollHeight;
  });
}

async function refreshBacklog() {
  let data; try { data = await (await fetch('/api/backlog')).json(); } catch (e) { return; }
  const json = JSON.stringify(data);
  if (json === state.lastFetchedJson) return;
  state.lastFetchedJson = json;
  renderBacklog(data);
}

async function refreshIdeas() {
  let data; try { data = await (await fetch('/api/ideas')).json(); } catch (e) { return; }
  const json = JSON.stringify(data);
  if (json === state.lastIdeasJson) return;
  state.lastIdeasJson = json;
  renderIdeas(data);
}

async function refreshHarness() {
  let data; try { data = await (await fetch('/api/harness')).json(); } catch (e) { return; }
  const json = JSON.stringify(data);
  if (json === state.lastHarnessJson) return;
  state.lastHarnessJson = json;
  renderHarness(data);
}

function renderIdeas(data) {
  state.lastIdeasData = data;   // cache so toggling a row re-renders without a refetch
  const el = document.getElementById('ideas-md');
  const ideas = data.ideas || [];
  document.getElementById('ideas-summary').innerHTML = ideas.length
    ? esc(String(ideas.length)) + ' idea(s) in <span class="mono">.harness/tracking/IDEAS.jsonl</span> — click one to expand.'
    : '';
  if (!ideas.length) {
    el.innerHTML = '<p class="note">No ideas captured yet — add one with <span class="mono">/implementation-harness-capture-idea</span>, then sweep them into tasks with <span class="mono">/implementation-harness-convert-ideas</span>.</p>';
    return;
  }
  const allOpen = ideas.every(function (i) { return state.openIdeas.has('idea-' + i.id); });
  const bar = '<div class="bar"><button class="barbtn" onclick="toggleAllIdeas()">' + (allOpen ? 'Collapse all' : 'Expand all') + '</button></div>';
  el.innerHTML = bar + '<div class="panel">' + ideas.map(renderIdea).join('') + '</div>';
}

// toggleAllIdeas() — one button to unfurl (or re-collapse) every idea at once, instead of clicking
// each caret individually. Flips based on whether every idea is CURRENTLY open (so the button always
// reads as the action it's about to take, not a fixed label).
function toggleAllIdeas() {
  const ideas = (state.lastIdeasData && state.lastIdeasData.ideas) || [];
  const allOpen = ideas.length > 0 && ideas.every(function (i) { return state.openIdeas.has('idea-' + i.id); });
  if (allOpen) state.openIdeas.clear();
  else ideas.forEach(function (i) { state.openIdeas.add('idea-' + i.id); });
  renderIdeas(state.lastIdeasData);
}

// renderIdea(idea) — one collapsed one-line row (id + title + captured date) by default; expands to
// the full description (server-rendered markdown, XSS-safe by construction — see lib.js mdToHtml).
// Mirrors the backlog's taskrow/expand pattern so both tabs read as one design language.
function renderIdea(idea) {
  const key = 'idea-' + idea.id;
  const open = state.openIdeas.has(key);
  const when = idea.capturedAt ? '<span class="pill">' + esc(String(idea.capturedAt).slice(0, 10)) + '</span>' : '';
  const detail = open
    ? \`<div class="expand" onclick="event.stopPropagation()"><div class="md-body">\${idea.descriptionHtml}</div></div>\`
    : '';
  return \`<div class="taskrow" id="\${key}">
    <div class="row" onclick="toggleIdea('\${key}')">
      <span class="caret">\${open ? '▾' : '▸'}</span>
      <span class="tid mono">#\${esc(String(idea.id))}</span>
      <span class="title">\${esc(idea.title)}</span>
      \${when}
    </div>
    \${detail}
  </div>\`;
}

function toggleIdea(key) {
  state.openIdeas.has(key) ? state.openIdeas.delete(key) : state.openIdeas.add(key);
  if (state.lastIdeasData) renderIdeas(state.lastIdeasData);
}

function knob(label, val) { return '<div class="knob"><span>' + label + '</span><b>' + esc(String(val)) + '</b></div>'; }

function renderHarness(data) {
  const el = document.getElementById('harness-body');
  const L = data.ladder || [], cells = data.cells || [], recent = data.recent || [], p = data.policy || {};
  let h = '';
  h += '<div class="htitle">Model tiers &amp; policy</div><div class="refgrid">';
  h += '<div class="refcard"><b>Tier ladder</b> — cheapest → priciest<ol>' +
       L.map(function (t) { return '<li class="model-tag">' + esc(t.model) + (t.effort ? ' / ' + esc(t.effort) : '') + '</li>'; }).join('') + '</ol></div>';
  h += '<div class="refcard"><b>Policy knobs</b>' +
       knob('pass floor', Math.round((p.floor || 0) * 100) + '% first-attempt') +
       knob('min samples', p.minN) +
       knob('audit taper', '100% until ' + p.auditStartN + ' → ' + Math.round((p.auditFloor || 0) * 100) + '% by ' + p.auditFloorN + ' audited') +
       knob('auditor', (p.auditorModel || '—') + ' / ' + (p.auditorEffort || '—')) +
       '</div></div>';

  h += '<div class="htitle">Per-facet calibration</div>';
  if (data.jqOk === false) h += '<p class="note">⚠ <span class="mono">jq</span> not found on PATH — install jq to compute the chosen model &amp; audit rate. The counts below are still accurate.</p>';
  h += '<p class="note">Baseline per <b>layer × work-type</b> cell (no risk flags). A task carrying a risk facet always audits (100%) and starts at least one tier higher.</p>';
  if (!cells.length) {
    h += '<p class="note">No calibration data yet — the harness records an outcome each time it builds a task.</p>';
  } else {
    h += '<table class="ftable"><thead><tr>'
       + '<th>Facet <span class="qtip" tabindex="0" data-tip="The layer × work-type combination this row\\'s stats are calibrated for (e.g. backend/feature).">?</span></th>'
       + '<th>Start model <span class="qtip" tabindex="0" data-tip="The model/effort the policy would pick to START a task in this cell right now (it only escalates from here on real failure). \\'cold\\' = no build history yet, using the cold-start prior.">?</span></th>'
       + '<th class="num">Audit (policy) <span class="qtip" tabindex="0" data-tip="The sampling probability the policy will use for the NEXT build in this cell">?</span></th>'
       + '<th class="num">Audited (observed) <span class="qtip" tabindex="0" data-tip="What actually happened: audited successes / all successes recorded in the ledger">?</span></th>'
       + '<th class="num">Builds <span class="qtip" tabindex="0" data-tip="Total tasks in this cell that reached a terminal outcome (success or blocked), per the outcomes ledger.">?</span></th>'
       + '<th class="num">✓ <span class="qtip" tabindex="0" data-tip="Successful builds in this cell that the owner did NOT overturn.">?</span></th>'
       + '<th class="num">✗ <span class="qtip" tabindex="0" data-tip="Builds the owner overturned as a false success, or that the loop itself gave up on (blocked).">?</span></th>'
       + '<th class="num">⚠ fails <span class="qtip" tabindex="0" data-tip="Failed attempts recorded before a task in this cell eventually succeeded or was blocked — see Failure health below for a kind breakdown.">?</span></th>'
       + '</tr></thead><tbody>';
    for (const c of cells) {
      const model = c.chosenModel ? esc(c.chosenModel) + (c.chosenEffort ? ' / ' + esc(c.chosenEffort) : '') : '—';
      const cold = (c.chosenModel && !c.hasHistory) ? '<span class="cold-tag">cold</span>' : '';
      const audit = (c.auditPct != null) ? c.auditPct + '%' : '—';
      const observed = c.successes ? Math.round((c.audited / c.successes) * 100) + '% <span class="cold-tag">' + c.audited + '/' + c.successes + '</span>' : '—';
      const failTip = Object.entries(c.kinds || {}).map(function (kv) { return kv[0] + ' ×' + kv[1]; }).join(', ');
      h += '<tr><td class="facet-name">' + esc(c.layer) + '/' + esc(c.workType) + '</td>' +
           '<td class="model-tag">' + model + cold + '</td>' +
           '<td class="num">' + audit + '</td>' +
           '<td class="num">' + observed + '</td>' +
           '<td class="num">' + c.builds + '</td>' +
           '<td class="num">' + c.successes + '</td>' +
           '<td class="num">' + c.blocked + '</td>' +
           '<td class="num"' + (failTip ? ' title="' + esc(failTip) + '"' : '') + '>' + c.failures + '</td></tr>';
    }
    h += '</tbody></table>';
  }

  const kinds = data.failureKinds || [];
  if (kinds.length) {
    h += '<div class="htitle">Failure health</div>';
    h += '<p class="note">Every failed attempt in <span class="mono">ledgers/failures.jsonl</span>, by kind — which gate is actually catching things. (Hover a cell\\'s ⚠ count above for its per-facet breakdown.)</p>';
    h += '<div class="kindpills">' + kinds.map(function (k) {
      return '<span class="pill blocked">' + esc(k.kind) + ' ×' + k.count + '</span>';
    }).join('') + '</div>';
  }

  h += '<div class="htitle">Recent activity</div>';
  if (!recent.length) {
    h += '<p class="note">Nothing recorded yet.</p>';
  } else {
    h += '<div class="recent">' + recent.map(function (e) {
      const when = (e.ts || '').slice(0, 16).replace('T', ' ');
      const cls = e.type === 'failure' ? 'pill blocked' : 'pill done';
      return '<div class="ev"><span class="t">' + esc(when) + '</span><span class="eid mono">' + esc(e.id) + '</span>' +
             '<span class="' + cls + '">' + esc(e.label) + '</span>' +
             '<span class="t">' + esc(e.facet) + '</span>' +
             (e.detail ? '<span>' + esc(e.detail) + '</span>' : '') + '</div>';
    }).join('') + '</div>';
  }
  el.innerHTML = h;
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
  } else if (bucketName === 'failedPendingReview') {
    // Amber "blocked"-style pills, not the red "failed" pill Done uses — this means "unresolved,
    // needs attention" (like blocked), distinct from Done's "confirmed, closed-out failure."
    // Distinguish the two ways a task lands here, same wording Human Tasks already used for the
    // blocked case, so a task reads consistently as it moves between sections.
    pills += task.status === 'blocked'
      ? '<span class="pill blocked">⚠ blocked (loop gave up)</span>'
      : '<span class="pill blocked">⚠ failed — awaiting review</span>';
  } else if (bucketName === 'done') {
    pills += task.reviewed ? '<span class="pill reviewed">👁 reviewed</span>' : '<span class="pill">not reviewed</span>';
    pills += task.failed ? '<span class="pill failed">✗ failed</span>' : '<span class="pill done">✓ done</span>';
    if (task.completedWith) {
      const cw = task.completedWith;
      if (cw.human) {
        pills += '<span class="pill" title="No ledgers/outcomes.jsonl row for this task — it was marked done via the human-done overlay (a needs-human gate, or a task completed by hand), not built by the loop.">🧑 implemented manually</span>';
      } else {
        const label = esc(cw.model || '?') + (cw.effort ? '/' + esc(cw.effort) : '');
        pills += '<span class="pill model-tag" title="The model/effort that completed this task, from ledgers/outcomes.jsonl">' + label + '</span>';
      }
    }
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
    if (!task.reviewed) detail += \`<button class="act" onclick="markReviewed('\${task.id}')">Mark reviewed</button>\`;
    detail += '</div></div>';
  }
  // Only offer a bulk-select checkbox where bulk actions exist: needsHuman (mark-done),
  // not-yet-reviewed done tasks, and failedPendingReview tasks (mark-reviewed) — mirrors the three
  // bulk-action groups.
  const showCheckbox = bucketName === 'needsHuman' || (bucketName === 'done' && !task.reviewed) || bucketName === 'failedPendingReview';
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
  if (name === 'needsHuman' || name === 'done' || name === 'failedPendingReview') {
    const selectable = tasks.filter(t => name === 'needsHuman' || !t.reviewed).map(t => t.id);
    const n = selectable.filter(id => state.selected.has(id)).length;
    const allSel = selectable.length > 0 && n === selectable.length;
    if (selectable.length) {
      const verb = name === 'needsHuman' ? 'done' : 'reviewed';
      bar = \`<div class="section-toolbar"><label class="sel"><input type="checkbox" \${allSel ? 'checked' : ''} onclick="toggleAll('\${name}', this.checked)"> select all (\${selectable.length})</label>\`
          + \`<button class="act" onclick="bulkAction('\${name}')" \${n ? '' : 'disabled'}>Mark \${n} \${verb}</button></div>\`;
    }
  }
  let filterBar = '';
  if (name === 'done') {
    const mk = (mode, text) => \`<button class="barbtn\${state.doneFilter === mode ? ' on' : ''}" onclick="setDoneFilter('\${mode}')">\${text}</button>\`;
    filterBar = \`<div class="section-toolbar"><span class="barlabel">Show</span>\${mk('all', 'All')}\${mk('reviewed', 'Reviewed')}\${mk('unreviewed', 'Not reviewed')}</div>\`;
  }
  const rows = tasks.length ? tasks.map(t => renderTask(t, name)).join('') : '<p class="empty">None.</p>';
  const descHtml = desc ? \`<p class="section-desc">\${desc}</p>\` : '';
  return \`<details id="section-\${name}" class="section"\${openAttr} ontoggle="onSectionToggle('\${name}', this)">
    <summary class="section-heading">\${emoji} \${label} <span class="count">(\${countStr})</span></summary>
    <div class="section-body">
      \${descHtml}\${filterBar}\${bar}
      <div class="panel">\${rows}</div>
    </div>
  </details>\`;
}

function renderBacklog(data) {
  state.lastData = data;   // cache so pure-UI actions (expand, filter, select) re-render without a refetch
  const b = data.buckets, c = data.counts;
  const total = b.ready.length + b.waiting.length + b.needsHuman.length + b.failedPendingReview.length + b.done.length;
  const reviewed = b.done.filter(t => t.reviewed).length;
  document.getElementById('summary').innerHTML =
    'The harness task list (<span class="mono">.harness/tracking/TASKS.json</span>), rendered. '
    + \`\${total} task(s) · \${c.ready} ready · \${c.waiting} waiting · \${c.needsHuman} need a human · \${c.failedPendingReview} failed (pending review) · \${c.done} done (\${reviewed} reviewed). Auto-refreshes.\`;
  document.getElementById('summary-chips').innerHTML =
    \`<button class="summary-chip action" onclick="scrollToSection('needsHuman')"><span class="n">\${c.needsHuman}</span><span class="lbl">need your action</span></button>\`
    + \`<button class="summary-chip review" onclick="scrollToSection('failedPendingReview')"><span class="n">\${c.failedPendingReview}</span><span class="lbl">failed, pending review</span></button>\`
    + \`<button class="summary-chip done" onclick="scrollToSection('done')"><span class="n">\${c.done} <small>· \${reviewed} reviewed</small></span><span class="lbl">done</span></button>\`;
  document.getElementById('sections').innerHTML =
    renderSection('ready', '🤖', 'Ready', 'Everything the harness can build with no human involved — either right now, or once an earlier, equally-buildable task in its chain lands.', b.ready, b.ready.length)
    + renderSection('waiting', '⏳', 'Waiting on Human Tasks', 'Buildable, but blocked somewhere upstream by a task a human still has to clear.', b.waiting, b.waiting.length)
    + renderSection('needsHuman', '🔒', 'Human Tasks', 'The loop skips these — a needs-human step, or a task it gave up on. Work them yourself, then mark done.', b.needsHuman, b.needsHuman.length)
    + renderSection('failedPendingReview', '🩹', 'Failed — Pending Review', 'The loop gave up on these, or the owner overturned a false success — nobody has confirmed the verdict yet. Investigate (or run /review-failed), then mark reviewed.', b.failedPendingReview, b.failedPendingReview.length)
    + renderSection('done', '✅', 'Done', null, b.done, \`\${b.done.length} · \${reviewed} reviewed · \${b.done.length - reviewed} not reviewed\`);
}

// Re-render from cached data (no network) — for expand/collapse, filter, and selection changes.
function rerender() { if (state.lastData) renderBacklog(state.lastData); }

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

// Summary-chip navigation: expand + scroll to + briefly highlight the section the chip refers to.
function scrollToSection(name) {
  state.closedSections.delete(name);
  rerender();
  const el = document.getElementById('section-' + name);
  if (!el) return;
  el.scrollIntoView({ behavior: 'smooth', block: 'start' });
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
  if (await post('/api/mark-done', { ids: [id] })) refreshActive();
}
async function markFailed(id) {
  const reason = prompt('Mark ' + id + ' as a false success — what was actually wrong?');
  if (!reason) return;
  if (await post('/api/mark-failed', { id, reason })) refreshActive();
}
async function markReviewed(id) { if (await post('/api/mark-reviewed', { ids: [id] })) refreshActive(); }

async function bulkAction(bucket) {
  const ids = [...state.selected];
  if (!ids.length) return;
  let ok = true;
  if (bucket === 'needsHuman') {
    if (!confirm('Mark ' + ids.length + ' task(s) done? Writes human-done.json, commits + pushes.')) return;
    ok = await post('/api/mark-done', { ids });
  }
  if (bucket === 'done' || bucket === 'failedPendingReview') ok = await post('/api/mark-reviewed', { ids });
  if (ok) { state.selected.clear(); refreshActive(); }
}

// Theme picker — four bold, hue-distinct dark themes, baked in as [data-theme="…"] CSS blocks
// above (client-only, localStorage, namespaced by project dir name so several projects'
// dashboards, even on the same port at different times, don't clobber each other's choice). No
// open-ended color input — picking a good palette from unlimited options is fiddly; a small
// curated set is not.
const THEME_STORAGE_KEY = 'harness-dashboard-theme:' + HARNESS_PROJECT_KEY;
const THEME_NAMES = ['ink', 'forest', 'plum', 'amber'];
function markActiveTheme(name) {
  document.querySelectorAll('.swatch').forEach(function (b) {
    b.classList.toggle('active', b.dataset.theme === name);
  });
}
function setTheme(name) {
  document.documentElement.setAttribute('data-theme', name);
  localStorage.setItem(THEME_STORAGE_KEY, name);
  markActiveTheme(name);
}
function initThemePicker() {
  if (!document.querySelector('.swatch')) return;
  const saved = localStorage.getItem(THEME_STORAGE_KEY);
  const theme = THEME_NAMES.includes(saved) ? saved : 'ink';
  document.documentElement.setAttribute('data-theme', theme);
  markActiveTheme(theme);
}
initThemePicker();

// Instant tooltips for .qtip icons — the native title= attribute has a browser-enforced ~1-1.5s
// hover delay that CSS can't shorten. One popup element, positioned via getBoundingClientRect and
// clamped to the viewport (so it's never clipped by a table's own overflow:hidden, unlike a
// CSS-only ::after pinned to the icon would be), shown/hidden via event delegation on document so
// it keeps working across re-renders (the Internals tab rebuilds its innerHTML on every poll).
function initQtips() {
  let popup = document.getElementById('qtip-popup');
  if (!popup) {
    popup = document.createElement('div');
    popup.id = 'qtip-popup';
    document.body.appendChild(popup);
  }
  function show(el) {
    const tip = el.getAttribute('data-tip');
    if (!tip) return;
    popup.textContent = tip;
    popup.style.display = 'block';
    const r = el.getBoundingClientRect();
    const pr = popup.getBoundingClientRect();
    let left = r.left + r.width / 2 - pr.width / 2;
    left = Math.max(6, Math.min(left, window.innerWidth - pr.width - 6));
    let top = r.bottom + 7;
    if (top + pr.height > window.innerHeight - 6) top = r.top - pr.height - 7;
    popup.style.left = left + 'px';
    popup.style.top = top + 'px';
  }
  function hide() { popup.style.display = 'none'; }
  document.addEventListener('mouseover', function (e) { const q = e.target.closest('.qtip'); if (q) show(q); });
  document.addEventListener('mouseout', function (e) { const q = e.target.closest('.qtip'); if (q) hide(); });
  document.addEventListener('focusin', function (e) { const q = e.target.closest('.qtip'); if (q) show(q); });
  document.addEventListener('focusout', function (e) { const q = e.target.closest('.qtip'); if (q) hide(); });
}
initQtips();

refreshActive();
setInterval(refreshActive, 5000);   // one poll → the active view (each keeps its own change-guard)
</script>
</body>
</html>`;
}

if (require.main === module) {
  server.listen(PORT, '127.0.0.1', () => {
    console.log(`[dashboard] listening on http://127.0.0.1:${PORT}`);
  });
  // Opt-in freshness fetch (HARNESS_DASHBOARD_FETCH_SECONDS > 0): keep FETCH_HEAD / origin refs
  // current so the backlog can't silently lag origin when the loop isn't running. Fetch-only —
  // never touches the working tree; failures (offline, no remote) are silent and harmless.
  const fetchEvery = parseInt(envKnob('HARNESS_DASHBOARD_FETCH_SECONDS', '0'), 10) || 0;
  if (fetchEvery > 0) {
    setInterval(() => {
      execFile('git', ['fetch', 'origin', '--quiet'], { cwd: ROOT, timeout: 60000 }, () => {});
    }, fetchEvery * 1000);
    console.log(`[dashboard] fetching origin every ${fetchEvery}s (HARNESS_DASHBOARD_FETCH_SECONDS)`);
  }
}

module.exports = { server, loadState, isLoopback };
