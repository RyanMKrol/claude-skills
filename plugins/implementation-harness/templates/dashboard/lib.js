// lib.js — pure, file-I/O-free backlog-derivation logic for the harness dashboard.
//
// computeBacklog() MUST mirror the loop's own task-selection logic (scripts/loop.sh /
// loop.in-place.sh select_task, and postflight.sh's board) exactly, so the dashboard never shows
// a state that disagrees with what the loop will actually do next. If you change select_task's
// eligibility rules, update this function to match.
//
// Bucket precedence (a task lands in exactly one bucket):
// failedPendingReview > done > needsHuman > waiting > ready.
'use strict';

function isTerminalDone(task, overlays) {
  if (task.status === 'done') return true;
  const hd = overlays.humanDone[task.id];
  return !!(hd && hd.done === true);
}

function isFailed(task, overlays) {
  if (task.status === 'failed') return true;
  const mf = overlays.manualFail[task.id];
  return !!(mf && mf.failed === true);
}

function isNeedsHuman(task, blockedIds) {
  if (task.gate === 'needs-human') return true;
  // status:"blocked" is a first-class TASKS.json value (set by block_task() when a task exhausts
  // the top ladder rung) — check it directly, not just via the worklog-grep blockedIds fallback
  // (kept for tasks blocked before status:"blocked" existed). In computeBacklog's main loop, an
  // unreviewed blocked task is normally diverted to failedPendingReview BEFORE this ever runs —
  // this check stays here as: (a) what isStuck() uses directly for dependency-chain purposes,
  // where "blocked, reviewed or not" is equally non-buildable either way, and (b) a defensive
  // fallback bucket for the (should-be-rare) case of a blocked task that's already been marked
  // reviewed without ever having mark-failed.sh run against it.
  if (task.status === 'blocked') return true;
  return blockedIds.has(task.id);
}

function isReviewed(task, overlays) {
  const r = overlays.reviews[task.id];
  return !!(r && r.reviewed === true);
}

// Parse the numeric part of a "T123"-style id, for numeric (not lexicographic) sort.
function numericId(id) {
  const m = /(\d+)/.exec(id || '');
  return m ? parseInt(m[1], 10) : Number.MAX_SAFE_INTEGER;
}

// computeBacklog(tasksJson, overlays, blockedIds) -> { ready, waiting, needsHuman, failedPendingReview, done }
//   tasksJson  — the parsed TASKS.json document ({ tasks: [...] })
//   overlays   — { humanDone: {...}, manualFail: {...}, reviews: {...} } (parsed tracking/*.json)
//   blockedIds — a Set of task ids whose worklog contains "failed:blocked" (mirrors the loop's
//                own task_blocked() grep)
function computeBacklog(tasksJson, overlays, blockedIds) {
  const tasks = tasksJson.tasks || [];
  const byId = new Map(tasks.map((t) => [t.id, t]));
  const stuckMemo = new Map();
  const visiting = new Set();

  // isStuck(id) — true if the task at `id` is not done and is itself permanently blocked
  // (failed / needs-human / gate / worklog-blocked), OR depends (transitively) on one that is.
  // A task with only ORDINARY unmet deps (still buildable, just not built yet) is NOT stuck.
  function isStuck(id) {
    if (stuckMemo.has(id)) return stuckMemo.get(id);
    if (visiting.has(id)) return false; // cycle guard — never let a dependency cycle infinite-loop
    const task = byId.get(id);
    if (!task) { stuckMemo.set(id, false); return false; }
    visiting.add(id);
    let result;
    if (isTerminalDone(task, overlays)) {
      result = false;
    } else if (isFailed(task, overlays) || isNeedsHuman(task, blockedIds)) {
      result = true;
    } else {
      const deps = task.dependsOn || [];
      result = deps.some((d) => {
        const dep = byId.get(d);
        return dep && !isTerminalDone(dep, overlays) && isStuck(d);
      });
    }
    visiting.delete(id);
    stuckMemo.set(id, result);
    return result;
  }

  const buckets = { ready: [], waiting: [], needsHuman: [], failedPendingReview: [], closedFailed: [], donePendingReview: [], done: [] };

  for (const task of tasks) {
    const failed = isFailed(task, overlays);
    // Same population implementation-harness-review-failed's own Stage 1 worklist selects:
    // status=="failed" (incl. a manual-fail overturn) OR the literal status=="blocked" (NOT the
    // blockedIds worklog-grep fallback below — review-failed's own query only ever reads the
    // TASKS.json status field, so a legacy pre-status:"blocked" task it wouldn't pick up shouldn't
    // land here either; it stays in needsHuman via the fallback, same as always).
    const blockedStatus = task.status === 'blocked';
    // reviewed means "has an explicit tracking/reviews.json entry" — no auto-implication from
    // failed anymore. A failed-or-blocked-and-unreviewed task gets its own bucket (below) instead
    // of being silently treated as reviewed and buried in Done, or sitting in Human Tasks
    // indistinguishable from a task that just needs a human decision.
    const reviewed = isReviewed(task, overlays);
    if ((failed || blockedStatus) && !reviewed) {
      buckets.failedPendingReview.push({ ...task, failed, reviewed });
      continue;
    }
    // A REVIEWED failure/blocked is closed out — but it is NOT a success, so it gets its own
    // "Closed — failed" bucket rather than hiding in Done (where a failure looked done, and any task
    // that depended on it sat silently stranded — the stranded-dependent scan in pre-loop-checkin /
    // review-failed is what surfaces those). Checked before isTerminalDone so an overturned
    // done→failed task (manual-fail overlay on a status:done task) lands here, not in Done.
    if (failed || blockedStatus) {
      buckets.closedFailed.push({ ...task, failed, reviewed });
      continue;
    }
    if (isTerminalDone(task, overlays)) {
      // Genuinely done. Reviewed → Done; not-yet-reviewed work gets its own "Pending review" bucket so
      // it isn't buried under a long history of already-checked tasks. The reviewed flag IS the
      // boundary, so marking a task reviewed moves it into Done and un-reviewing it moves it back.
      (reviewed ? buckets.done : buckets.donePendingReview).push({ ...task, failed, reviewed });
      continue;
    }
    if (isNeedsHuman(task, blockedIds)) {
      buckets.needsHuman.push({ ...task, reviewed });
      continue;
    }
    const deps = task.dependsOn || [];
    const unmetDeps = deps.filter((d) => {
      const dep = byId.get(d);
      return !dep || !isTerminalDone(dep, overlays);
    });
    const stuck = unmetDeps.some((d) => isStuck(d));
    if (stuck) {
      buckets.waiting.push({ ...task, unmetDeps, reviewed });
    } else {
      // Buildable now, even if it has unmet-but-not-stuck deps — don't hide real work, just
      // annotate it, mirroring a deliberate fix upstream (a task waiting only on other buildable
      // work should still show as ready, not disappear into "waiting").
      buckets.ready.push({ ...task, unmetDeps, reviewed });
    }
  }

  // Both done-family buckets sort by ascending numeric task id — the reviewed/not-reviewed split is
  // now the bucket boundary itself (Done is uniformly reviewed; Pending review is uniformly not).
  const byNumericId = (a, b) => numericId(a.id) - numericId(b.id);
  buckets.done.sort(byNumericId);
  buckets.donePendingReview.sort(byNumericId);
  buckets.closedFailed.sort(byNumericId);

  return buckets;
}

// ─── Harness-internals helpers (Ideas + Internals dashboard views) ───────────────────────────────

// parseJsonl(text) — tolerant JSONL parser: one object per non-blank line, garbled lines skipped.
function parseJsonl(text) {
  const out = [];
  if (!text) return out;
  for (const line of text.split('\n')) {
    if (!line.trim()) continue;
    try { out.push(JSON.parse(line)); } catch (_err) { /* skip a garbled row */ }
  }
  return out;
}

// coldTierIndex(ladder, model, effort) — index of (model,effort) on the tier ladder, else 0 (cheapest).
// Mirrors pick_base()'s cold-start prior: the authored model/effort's ladder position.
function coldTierIndex(ladder, model, effort) {
  const i = (ladder || []).findIndex((t) => t && t.model === model && t.effort === effort);
  return i >= 0 ? i : 0;
}

function facetCell(facets) {
  if (!facets || !facets.layer || !facets.workType) return null;
  return { layer: facets.layer, workType: facets.workType };
}

// harnessCells(outcomes, failures, tasks, manualFail) — the per (layer × work-type) COUNTS for the
// Internals view. The calibration verdicts (chosen tier, audit rate) are NOT computed here — those come
// from policy.jq itself (invoked in server.js) so the dashboard can never disagree with the loop. This
// only aggregates raw counts, applying the same overturn rule the audit query + policy tier branch use:
// a row is a failure if blocked==true OR the owner overturned it in manual-fail.json.
function harnessCells(outcomes, failures, tasks, manualFail) {
  outcomes = outcomes || []; failures = failures || []; tasks = tasks || []; manualFail = manualFail || {};
  const cells = new Map();
  const keyOf = (l, w) => l + ' ' + w;
  const ensure = (l, w) => {
    const k = keyOf(l, w);
    let c = cells.get(k);
    if (!c) { c = { layer: l, workType: w, builds: 0, successes: 0, blocked: 0, audited: 0, ciOnly: 0, failures: 0, pending: 0, kinds: {} }; cells.set(k, c); }
    return c;
  };
  const overturned = (row) => row.blocked === true || !!(manualFail[row.id] && manualFail[row.id].failed === true);
  for (const row of outcomes) {
    const fc = facetCell(row.facets); if (!fc) continue;
    const c = ensure(fc.layer, fc.workType);
    c.builds += 1;
    if (overturned(row)) { c.blocked += 1; }
    else { c.successes += 1; if (row.verification === 'audited') c.audited += 1; else c.ciOnly += 1; }
  }
  for (const row of failures) {
    const fc = facetCell(row.facets); if (!fc) continue;
    const c = ensure(fc.layer, fc.workType);
    c.failures += 1;
    const k = row.kind || 'unknown';
    c.kinds[k] = (c.kinds[k] || 0) + 1;
  }
  for (const t of tasks) {
    if (!t || t.status === 'done' || t.status === 'failed') continue;
    const fc = facetCell(t.facets); if (!fc) continue;
    ensure(fc.layer, fc.workType).pending += 1;
  }
  return Array.from(cells.values()).sort((a, b) =>
    a.layer === b.layer ? a.workType.localeCompare(b.workType) : a.layer.localeCompare(b.layer));
}

// failureKinds(failures) — global failure-kind breakdown from ledgers/failures.jsonl rows, sorted by
// count desc then kind asc (stable for the change-guard). The Internals health panel: which gate is
// actually catching things — audit-fail vs ci-red vs scope-creep vs local-dod …
function failureKinds(failures) {
  const counts = new Map();
  for (const row of (failures || [])) {
    const k = (row && row.kind) || 'unknown';
    counts.set(k, (counts.get(k) || 0) + 1);
  }
  return Array.from(counts, ([kind, count]) => ({ kind, count }))
    .sort((a, b) => (b.count - a.count) || a.kind.localeCompare(b.kind));
}

// recentActivity(outcomes, failures, limit) — the newest `limit` events (outcomes + failures) merged
// and sorted by timestamp desc, for the Internals activity feed.
function recentActivity(outcomes, failures, limit) {
  limit = limit || 20;
  const facetStr = (f) => (f && f.layer ? f.layer + '/' + f.workType : '');
  // The model/effort behind this one attempt. Outcomes carry finalModel/finalEffort (the tier that
  // actually completed — or was blocked at — after any escalation); failure rows carry model/effort
  // (the tier that attempt ran at). Rendering each row's model is what makes an escalation legible —
  // the duplicate rows for a failed→retried task then visibly differ by the rung they ran on.
  const modelStr = (m, e) => (m ? String(m) + (e ? '/' + e : '') : '');
  const ev = [];
  for (const r of (outcomes || [])) {
    ev.push({ ts: r.ts || '', id: r.id || '', type: 'outcome',
      label: r.blocked ? 'blocked' : (r.verification === 'audited' ? 'built · audited' : 'built'),
      detail: r.reason || '', facet: facetStr(r.facets), model: modelStr(r.finalModel, r.finalEffort) });
  }
  for (const r of (failures || [])) {
    ev.push({ ts: r.ts || '', id: r.id || '', type: 'failure', label: r.kind || 'failure', detail: r.detail || '', facet: facetStr(r.facets), model: modelStr(r.model, r.effort) });
  }
  ev.sort((a, b) => (a.ts < b.ts ? 1 : a.ts > b.ts ? -1 : 0));
  return ev.slice(0, limit);
}

// ─── Markdown → HTML (used for each idea's description, Ideas view) ─────────────────────────────
// Dependency-free, XSS-SAFE BY CONSTRUCTION: the whole source is HTML-escaped FIRST, so any raw
// markup/script in an idea's description is rendered as inert text, never executed (mirrors
// local-jobs' "no rehype-raw"). Covers the subset an idea description uses: headings, hr,
// blockquotes, ordered/unordered lists, fenced + inline code, bold/italic, sanitized links, paragraphs.
function mdEscape(s) {
  return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

function mdInline(s) {
  // s is ALREADY HTML-escaped. Protect inline-code spans, then apply links/bold/italic.
  const codes = [];
  s = s.replace(/`([^`]+)`/g, (_m, c) => { codes.push(c); return ' C' + (codes.length - 1) + ' '; });
  s = s.replace(/\[([^\]]+)\]\(([^)\s]+)\)/g, (_m, text, url) => {
    const raw = url.replace(/&amp;/g, '&');   // only http(s)/root-relative/anchor/mailto hrefs survive
    if (/^(https?:\/\/|\/|#|mailto:)/i.test(raw)) return '<a href="' + url + '" target="_blank" rel="noopener noreferrer">' + text + '</a>';
    return text;   // drop an unsafe scheme (javascript:, data:, …); keep the visible label
  });
  s = s.replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>').replace(/__([^_]+)__/g, '<strong>$1</strong>');
  s = s.replace(/\*([^*]+)\*/g, '<em>$1</em>');
  s = s.replace(/(^|[^A-Za-z0-9_])_([^_]+)_(?=[^A-Za-z0-9_]|$)/g, '$1<em>$2</em>');
  return s.replace(/ C(\d+) /g, (_m, i) => '<code>' + codes[+i] + '</code>');
}

function mdToHtml(src) {
  if (!src) return '';
  src = String(src).replace(/<!--[\s\S]*?-->/g, '');   // strip HTML comments (authoring guidance)
  const lines = mdEscape(src).split('\n');
  const html = [];
  let i = 0, para = [], list = null;
  const flushPara = () => { if (para.length) { html.push('<p>' + mdInline(para.join(' ')) + '</p>'); para = []; } };
  const closeList = () => { if (list) { html.push('</' + list + '>'); list = null; } };
  while (i < lines.length) {
    const line = lines[i];
    if (/^```/.test(line.trim())) {                    // fenced code block
      flushPara(); closeList();
      const buf = []; i++;
      while (i < lines.length && !/^```/.test(lines[i].trim())) { buf.push(lines[i]); i++; }
      i++;
      html.push('<pre><code>' + buf.join('\n') + '</code></pre>');
      continue;
    }
    const t = line.trim();
    if (t === '') { flushPara(); closeList(); i++; continue; }
    if (/^(-{3,}|\*{3,}|_{3,})$/.test(t)) { flushPara(); closeList(); html.push('<hr>'); i++; continue; }
    const hm = /^(#{1,6})\s+(.*)$/.exec(t);
    if (hm) { flushPara(); closeList(); const n = hm[1].length; html.push('<h' + n + '>' + mdInline(hm[2]) + '</h' + n + '>'); i++; continue; }
    if (/^&gt;\s?/.test(t)) {                            // blockquote (consecutive lines)
      flushPara(); closeList();
      const buf = [];
      while (i < lines.length && /^\s*&gt;\s?/.test(lines[i])) { buf.push(lines[i].replace(/^\s*&gt;\s?/, '')); i++; }
      html.push('<blockquote>' + mdInline(buf.join(' ')) + '</blockquote>');
      continue;
    }
    const um = /^[-*+]\s+(.*)$/.exec(t);
    if (um) { flushPara(); if (list !== 'ul') { closeList(); html.push('<ul>'); list = 'ul'; } html.push('<li>' + mdInline(um[1]) + '</li>'); i++; continue; }
    const om = /^\d+[.)]\s+(.*)$/.exec(t);
    if (om) { flushPara(); if (list !== 'ol') { closeList(); html.push('<ol>'); list = 'ol'; } html.push('<li>' + mdInline(om[1]) + '</li>'); i++; continue; }
    closeList(); para.push(t); i++;
  }
  flushPara(); closeList();
  return html.join('\n');
}

// ─── Ideas inbox (tracking/IDEAS.jsonl) ──────────────────────────────────────────────────────────
// One JSON object per idea, one per line: { id, title, description, capturedAt }. ids are LOCAL to
// the current inbox contents (max existing id + 1 on capture), not a permanent ledger — same
// semantics as the old numbered-markdown-bullet scheme, just structured. A garbled/blank line is
// silently skipped (parseJsonl); a row missing `id` is dropped (can't be addressed for conversion).
function ideasFromJsonl(text) {
  return parseJsonl(text)
    .filter((r) => r && typeof r.id !== 'undefined' && r.id !== null)
    .map((r) => ({
      id: r.id,
      title: String(r.title || ''),
      descriptionHtml: mdToHtml(r.description || ''),
      capturedAt: r.capturedAt || null,
    }))
    .sort((a, b) => a.id - b.id);
}

// ─── Live output (worklog/.claude-out.jsonl — the builder/auditor's streamed transcript) ─────────
// The loop invokes claude with --output-format stream-json --include-partial-messages so output
// arrives incrementally (plain -p mode never streams to a pipe — it buffers the whole response and
// writes it once at process exit). Reconstructs a human-readable "what's happening right now" view:
// concatenated text as it's generated, plus which tool (if any) is CURRENTLY running. `tool` clears
// the moment text resumes after it (the tool call finished and the model is talking again) — reusing
// parseJsonl's per-line tolerance (a stray non-JSON line, e.g. an interleaved stderr message, is
// silently skipped rather than aborting the rest of the transcript).
//
// Each round of narration (a short sentence or two before/after a tool call — "I'll start by reading
// the current state...", "Now let's run lint, tests, and build.") arrives as its OWN "text" content
// block, confirmed against a real transcript: the model doesn't put a newline between them itself.
// Without a separator these all run together into one unreadable wall of prose, so a newline is
// inserted at each NEW text block's start (never a leading one, and never between two deltas of the
// SAME block — only `content_block_start` marks a genuine new round of narration).
//
// A real transcript can also go through a LONG stretch of pure tool calls (reading files, running
// checks) with no narration text at all in between — the model doesn't always narrate before/after
// every call. Confirmed against a real one: 600+ raw stream lines of nothing but thinking + tool_use
// before the FIRST text block. Since thinking/tool_use content is otherwise invisible here, that read
// as "the panel starts mid-conversation" even though it was showing everything there was to show. So
// every tool call gets a `▶ <name>` marker line inserted inline, in order — a silent stretch now
// reads as an actual sequence of tool calls, not a gap before the visible text begins.
function liveOutputFromJsonl(text) {
  let buf = '';
  let tool = null;
  for (const row of parseJsonl(text)) {
    if (!row || row.type !== 'stream_event' || !row.event) continue;
    const ev = row.event;
    if (ev.type === 'content_block_start' && ev.content_block && ev.content_block.type === 'text' && buf && !buf.endsWith('\n')) {
      buf += '\n';
    } else if (ev.delta && ev.delta.type === 'text_delta') {
      buf += ev.delta.text || '';
      tool = null;
    } else if (ev.type === 'content_block_start' && ev.content_block && ev.content_block.type === 'tool_use') {
      tool = ev.content_block.name || null;
      buf += (buf && !buf.endsWith('\n') ? '\n' : '') + '▶ ' + tool + '\n';
    }
  }
  return { text: buf, tool };
}

module.exports = {
  computeBacklog, isTerminalDone, isFailed, isNeedsHuman, isReviewed, numericId,
  liveOutputFromJsonl,
  parseJsonl, coldTierIndex, harnessCells, recentActivity, failureKinds, mdToHtml, ideasFromJsonl,
};
