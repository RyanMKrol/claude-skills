// lib.test.js — a small, dependency-free test suite for lib.js (Node's built-in `assert` only,
// matching the dashboard's own no-npm-dependency philosophy). Run standalone:
//   node .harness/dashboard/lib.test.js
'use strict';

const assert = require('assert');
const { computeBacklog, harnessCells, recentActivity, coldTierIndex, parseJsonl, failureKinds, mdToHtml, ideasFromJsonl, liveOutputFromJsonl } = require('./lib');

const EMPTY_OVERLAYS = { humanDone: {}, manualFail: {}, reviews: {} };
let pass = 0;
let fail = 0;

function test(name, fn) {
  try {
    fn();
    pass++;
    console.log(`ok - ${name}`);
  } catch (err) {
    fail++;
    console.error(`FAIL - ${name}`);
    console.error(`       ${err.message}`);
  }
}

test('a plain done task lands in done', () => {
  const tasks = { tasks: [{ id: 'T001', status: 'done', gate: null, dependsOn: [] }] };
  const b = computeBacklog(tasks, EMPTY_OVERLAYS, new Set());
  assert.strictEqual(b.done.length, 1);
  assert.strictEqual(b.done[0].failed, false);
});

test('a status:failed task with no reviews.json entry lands in failedPendingReview, not done', () => {
  const tasks = { tasks: [{ id: 'T001', status: 'failed', gate: null, dependsOn: [] }] };
  const b = computeBacklog(tasks, EMPTY_OVERLAYS, new Set());
  assert.strictEqual(b.failedPendingReview.length, 1);
  assert.strictEqual(b.done.length, 0);
  assert.strictEqual(b.failedPendingReview[0].failed, true);
  assert.strictEqual(b.failedPendingReview[0].reviewed, false);
});

test('a status:failed task WITH a reviews.json entry lands in done, reviewed', () => {
  const tasks = { tasks: [{ id: 'T001', status: 'failed', gate: null, dependsOn: [] }] };
  const overlays = { ...EMPTY_OVERLAYS, reviews: { T001: { reviewed: true } } };
  const b = computeBacklog(tasks, overlays, new Set());
  assert.strictEqual(b.done.length, 1);
  assert.strictEqual(b.done[0].failed, true);
  assert.strictEqual(b.done[0].reviewed, true);
  assert.strictEqual(b.failedPendingReview.length, 0);
});

test('a manual-fail overturned task with no reviews.json entry lands in failedPendingReview', () => {
  const tasks = { tasks: [{ id: 'T001', status: 'done', gate: null, dependsOn: [] }] };
  const overlays = { ...EMPTY_OVERLAYS, manualFail: { T001: { failed: true } } };
  const b = computeBacklog(tasks, overlays, new Set());
  assert.strictEqual(b.failedPendingReview.length, 1);
  assert.strictEqual(b.done.length, 0);
  assert.strictEqual(b.failedPendingReview[0].reviewed, false);
});

test('human-done overlay promotes a needs-human task to done', () => {
  const tasks = { tasks: [{ id: 'T001', status: 'pending', gate: 'needs-human', dependsOn: [] }] };
  const overlays = { ...EMPTY_OVERLAYS, humanDone: { T001: { done: true } } };
  const b = computeBacklog(tasks, overlays, new Set());
  assert.strictEqual(b.done.length, 1);
  assert.strictEqual(b.needsHuman.length, 0);
});

test('manual-fail overlay overturns a done task into done+failed once reviewed (not needs-human)', () => {
  const tasks = { tasks: [{ id: 'T001', status: 'done', gate: null, dependsOn: [] }] };
  const overlays = {
    ...EMPTY_OVERLAYS,
    manualFail: { T001: { failed: true } },
    reviews: { T001: { reviewed: true } },
  };
  const b = computeBacklog(tasks, overlays, new Set());
  assert.strictEqual(b.done.length, 1);
  assert.strictEqual(b.done[0].failed, true);
  assert.strictEqual(b.needsHuman.length, 0);
});

test('needs-human tasks land in needsHuman (gate is only null | needs-human)', () => {
  const tasks = {
    tasks: [
      { id: 'T001', status: 'pending', gate: 'needs-human', dependsOn: [] },
      { id: 'T002', status: 'pending', gate: 'needs-human', dependsOn: [] },
    ],
  };
  const b = computeBacklog(tasks, EMPTY_OVERLAYS, new Set());
  assert.strictEqual(b.needsHuman.length, 2);
});

test('a status:"blocked" task with no reviews.json entry lands in failedPendingReview, not needsHuman', () => {
  const tasks = { tasks: [{ id: 'T001', status: 'blocked', gate: null, dependsOn: [] }] };
  const b = computeBacklog(tasks, EMPTY_OVERLAYS, new Set());
  assert.strictEqual(b.failedPendingReview.length, 1);
  assert.strictEqual(b.needsHuman.length, 0);
  assert.strictEqual(b.failedPendingReview[0].reviewed, false);
});

test('a status:"blocked" task WITH a reviews.json entry falls back to needsHuman (defensive edge case — normally review-failed also flips it to status:"failed" before marking reviewed)', () => {
  const tasks = { tasks: [{ id: 'T001', status: 'blocked', gate: null, dependsOn: [] }] };
  const overlays = { ...EMPTY_OVERLAYS, reviews: { T001: { reviewed: true } } };
  const b = computeBacklog(tasks, overlays, new Set());
  assert.strictEqual(b.needsHuman.length, 1);
  assert.strictEqual(b.failedPendingReview.length, 0);
});

test('a worklog-blocked task lands in needsHuman', () => {
  const tasks = { tasks: [{ id: 'T001', status: 'pending', gate: null, dependsOn: [] }] };
  const b = computeBacklog(tasks, EMPTY_OVERLAYS, new Set(['T001']));
  assert.strictEqual(b.needsHuman.length, 1);
});

test('a task depending on a needs-human task is waiting, not ready', () => {
  const tasks = {
    tasks: [
      { id: 'T001', status: 'pending', gate: 'needs-human', dependsOn: [] },
      { id: 'T002', status: 'pending', gate: null, dependsOn: ['T001'] },
    ],
  };
  const b = computeBacklog(tasks, EMPTY_OVERLAYS, new Set());
  assert.strictEqual(b.waiting.length, 1);
  assert.strictEqual(b.waiting[0].id, 'T002');
  assert.deepStrictEqual(b.waiting[0].unmetDeps, ['T001']);
});

test('a task depending on an ordinary pending (buildable) task is READY, not hidden as waiting', () => {
  const tasks = {
    tasks: [
      { id: 'T001', status: 'pending', gate: null, dependsOn: [] },
      { id: 'T002', status: 'pending', gate: null, dependsOn: ['T001'] },
    ],
  };
  const b = computeBacklog(tasks, EMPTY_OVERLAYS, new Set());
  assert.strictEqual(b.ready.length, 2);
  const t002 = b.ready.find((t) => t.id === 'T002');
  assert.deepStrictEqual(t002.unmetDeps, ['T001']);
});

test('waiting propagates transitively through a chain', () => {
  const tasks = {
    tasks: [
      { id: 'T001', status: 'pending', gate: 'needs-human', dependsOn: [] },
      { id: 'T002', status: 'pending', gate: null, dependsOn: ['T001'] },
      { id: 'T003', status: 'pending', gate: null, dependsOn: ['T002'] },
    ],
  };
  const b = computeBacklog(tasks, EMPTY_OVERLAYS, new Set());
  assert.strictEqual(b.waiting.length, 2);
});

test('a dependency cycle does not infinite-loop (cycle guard)', () => {
  const tasks = {
    tasks: [
      { id: 'T001', status: 'pending', gate: null, dependsOn: ['T002'] },
      { id: 'T002', status: 'pending', gate: null, dependsOn: ['T001'] },
    ],
  };
  const b = computeBacklog(tasks, EMPTY_OVERLAYS, new Set());
  assert.strictEqual(b.ready.length + b.waiting.length, 2);
});

test('bucket sort order is stable input order within each bucket', () => {
  const tasks = {
    tasks: [
      { id: 'T003', status: 'pending', gate: null, dependsOn: [] },
      { id: 'T001', status: 'pending', gate: null, dependsOn: [] },
      { id: 'T002', status: 'pending', gate: null, dependsOn: [] },
    ],
  };
  const b = computeBacklog(tasks, EMPTY_OVERLAYS, new Set());
  assert.deepStrictEqual(b.ready.map((t) => t.id), ['T003', 'T001', 'T002']);
});

test('done bucket sorts not-reviewed first, then ascending numeric id', () => {
  const tasks = {
    tasks: [
      { id: 'T010', status: 'done', gate: null, dependsOn: [] },
      { id: 'T002', status: 'done', gate: null, dependsOn: [] },
      { id: 'T005', status: 'done', gate: null, dependsOn: [] },
      { id: 'T001', status: 'done', gate: null, dependsOn: [] },
    ],
  };
  const overlays = {
    ...EMPTY_OVERLAYS,
    reviews: { T010: { reviewed: true }, T001: { reviewed: true } },
  };
  const b = computeBacklog(tasks, overlays, new Set());
  // not-reviewed (T002, T005) first in ascending id order, then reviewed (T001, T010) in ascending id order.
  assert.deepStrictEqual(b.done.map((t) => t.id), ['T002', 'T005', 'T001', 'T010']);
});

test('reviewed flag is attached to tasks in every bucket, not just done', () => {
  const tasks = { tasks: [{ id: 'T001', status: 'pending', gate: 'needs-human', dependsOn: [] }] };
  const overlays = { ...EMPTY_OVERLAYS, reviews: { T001: { reviewed: true } } };
  const b = computeBacklog(tasks, overlays, new Set());
  assert.strictEqual(b.needsHuman[0].reviewed, true);
});

// ─── Internals-view helpers ──────────────────────────────────────────────────────────────────────

test('parseJsonl skips blank + garbled lines', () => {
  const rows = parseJsonl('{"a":1}\n\nnot json\n{"a":2}\n');
  assert.deepStrictEqual(rows, [{ a: 1 }, { a: 2 }]);
});

test('coldTierIndex finds the tier, else 0', () => {
  const ladder = [{ model: 's', effort: 'low' }, { model: 's', effort: 'high' }, { model: 'o', effort: 'medium' }];
  assert.strictEqual(coldTierIndex(ladder, 'o', 'medium'), 2);
  assert.strictEqual(coldTierIndex(ladder, 'nope', 'x'), 0);
});

test('harnessCells aggregates counts per (layer × workType)', () => {
  const outcomes = [
    { id: 'T1', facets: { layer: 'backend', workType: 'feature' }, blocked: false, verification: 'audited' },
    { id: 'T2', facets: { layer: 'backend', workType: 'feature' }, blocked: false, verification: 'ci-only' },
    { id: 'T3', facets: { layer: 'backend', workType: 'feature' }, blocked: true, verification: 'ci-only' },
    { id: 'T4', facets: { layer: 'frontend', workType: 'component' }, blocked: false, verification: 'ci-only' },
  ];
  const failures = [{ id: 'T3', facets: { layer: 'backend', workType: 'feature' }, kind: 'ci-red' }];
  const cells = harnessCells(outcomes, failures, [], {});
  const be = cells.find((c) => c.layer === 'backend' && c.workType === 'feature');
  assert.strictEqual(be.builds, 3);
  assert.strictEqual(be.successes, 2);
  assert.strictEqual(be.blocked, 1);
  assert.strictEqual(be.audited, 1);
  assert.strictEqual(be.ciOnly, 1);
  assert.strictEqual(be.failures, 1);
  assert.strictEqual(cells.length, 2);   // one cell per distinct facet
});

test('harnessCells treats a manual-fail overturn as a failure, not a success', () => {
  const outcomes = [{ id: 'T1', facets: { layer: 'backend', workType: 'feature' }, blocked: false, verification: 'audited' }];
  const cells = harnessCells(outcomes, [], [], { T1: { failed: true } });
  const be = cells[0];
  assert.strictEqual(be.successes, 0);
  assert.strictEqual(be.blocked, 1);
  assert.strictEqual(be.audited, 0);   // overturned → not counted as an audited success
});

test('harnessCells surfaces a pending-task cell with no history yet', () => {
  const tasks = [{ id: 'T9', status: 'pending', facets: { layer: 'data', workType: 'migration' } }];
  const cells = harnessCells([], [], tasks, {});
  assert.strictEqual(cells.length, 1);
  assert.strictEqual(cells[0].pending, 1);
  assert.strictEqual(cells[0].builds, 0);
});

test('harnessCells tallies failure kinds per cell', () => {
  const failures = [
    { id: 'T1', facets: { layer: 'backend', workType: 'feature' }, kind: 'ci-red' },
    { id: 'T1', facets: { layer: 'backend', workType: 'feature' }, kind: 'ci-red' },
    { id: 'T2', facets: { layer: 'backend', workType: 'feature' }, kind: 'audit-fail' },
    { id: 'T3', facets: { layer: 'backend', workType: 'feature' } },   // no kind → 'unknown'
  ];
  const cells = harnessCells([], failures, [], {});
  assert.deepStrictEqual(cells[0].kinds, { 'ci-red': 2, 'audit-fail': 1, unknown: 1 });
  assert.strictEqual(cells[0].failures, 4);
});

test('failureKinds aggregates globally, sorted by count desc then kind asc', () => {
  const failures = [
    { id: 'T1', kind: 'audit-fail' }, { id: 'T2', kind: 'ci-red' }, { id: 'T3', kind: 'ci-red' },
    { id: 'T4', kind: 'scope-creep' }, { id: 'T5', kind: 'audit-fail' }, { id: 'T6' },
  ];
  assert.deepStrictEqual(failureKinds(failures), [
    { kind: 'audit-fail', count: 2 },
    { kind: 'ci-red', count: 2 },
    { kind: 'scope-creep', count: 1 },
    { kind: 'unknown', count: 1 },
  ]);
  assert.deepStrictEqual(failureKinds([]), []);
  assert.deepStrictEqual(failureKinds(null), []);
});

test('recentActivity merges + sorts by ts desc and honours the limit', () => {
  const outcomes = [{ id: 'T1', ts: '2026-01-01T00:00:00Z', blocked: false, verification: 'audited', facets: { layer: 'backend', workType: 'feature' } }];
  const failures = [{ id: 'T2', ts: '2026-01-03T00:00:00Z', kind: 'ci-red', detail: 'x' }, { id: 'T3', ts: '2026-01-02T00:00:00Z', kind: 'audit-fail' }];
  const ev = recentActivity(outcomes, failures, 2);
  assert.strictEqual(ev.length, 2);
  assert.strictEqual(ev[0].id, 'T2');           // newest first
  assert.strictEqual(ev[0].type, 'failure');
  assert.strictEqual(ev[1].id, 'T3');
});

test('mdToHtml renders headings, lists, bold, inline code, links', () => {
  const h = mdToHtml('# Title\n\n- one\n- two\n\n**bold** and `code` and [x](https://e.com)');
  assert.ok(h.includes('<h1>Title</h1>'));
  assert.ok(h.includes('<ul>') && h.includes('<li>one</li>'));
  assert.ok(h.includes('<strong>bold</strong>'));
  assert.ok(h.includes('<code>code</code>'));
  assert.ok(h.includes('<a href="https://e.com"'));
});

test('mdToHtml is XSS-safe: raw HTML/script is escaped, never executed', () => {
  const h = mdToHtml('<script>alert(1)</script>\n\n[x](javascript:alert(1))');
  assert.ok(!/<script>/.test(h));                 // the tag is escaped
  assert.ok(h.includes('&lt;script&gt;'));
  assert.ok(!/href="javascript:/i.test(h));       // unsafe scheme dropped
});

test('mdToHtml strips HTML comments (authoring guidance)', () => {
  const h = mdToHtml('before\n<!-- guidance\nmultiline -->\nafter');
  assert.ok(!h.includes('guidance'));
  assert.ok(h.includes('before') && h.includes('after'));
});

test('ideasFromJsonl parses rows, renders description markdown, sorts ascending by id', () => {
  const text = [
    JSON.stringify({ id: 2, title: 'Second', description: 'has **bold**', capturedAt: '2026-07-01T00:00:00Z' }),
    JSON.stringify({ id: 1, title: 'First', description: 'plain' }),
    'not json',
    '',
  ].join('\n');
  const ideas = ideasFromJsonl(text);
  assert.strictEqual(ideas.length, 2);
  assert.strictEqual(ideas[0].id, 1);
  assert.strictEqual(ideas[0].title, 'First');
  assert.strictEqual(ideas[1].id, 2);
  assert.ok(ideas[1].descriptionHtml.includes('<strong>bold</strong>'));
});

test('ideasFromJsonl drops rows with no id and handles empty/missing text', () => {
  const text = [JSON.stringify({ title: 'No id' }), JSON.stringify({ id: 3, title: 'Has id' })].join('\n');
  const ideas = ideasFromJsonl(text);
  assert.strictEqual(ideas.length, 1);
  assert.strictEqual(ideas[0].id, 3);
  assert.deepStrictEqual(ideasFromJsonl(''), []);
  assert.deepStrictEqual(ideasFromJsonl(null), []);
});

test('liveOutputFromJsonl concatenates text_delta chunks across lines', () => {
  const lines = [
    { type: 'stream_event', event: { type: 'content_block_delta', delta: { type: 'text_delta', text: 'Hello, ' } } },
    { type: 'stream_event', event: { type: 'content_block_delta', delta: { type: 'text_delta', text: 'world.' } } },
    { type: 'system', subtype: 'thinking_tokens', count: 5 },
  ].map((r) => JSON.stringify(r)).join('\n');
  const r = liveOutputFromJsonl(lines);
  assert.strictEqual(r.text, 'Hello, world.');
  assert.strictEqual(r.tool, null);
});

test('liveOutputFromJsonl reports the currently-running tool until text resumes', () => {
  const midFlight = [
    { type: 'stream_event', event: { type: 'content_block_delta', delta: { type: 'text_delta', text: "I'll check that. " } } },
    { type: 'stream_event', event: { type: 'content_block_start', content_block: { type: 'tool_use', name: 'Bash' } } },
  ].map((r) => JSON.stringify(r)).join('\n');
  assert.strictEqual(liveOutputFromJsonl(midFlight).tool, 'Bash');

  const finished = midFlight + '\n' + JSON.stringify({ type: 'stream_event', event: { type: 'content_block_delta', delta: { type: 'text_delta', text: 'Done.' } } });
  const r = liveOutputFromJsonl(finished);
  assert.strictEqual(r.tool, null);   // text resumed → the tool call is over
  assert.strictEqual(r.text, "I'll check that. \n▶ Bash\nDone.");
});

test('liveOutputFromJsonl inserts an in-order ▶ <tool> marker for every tool call, even a long silent stretch with no narration text at all', () => {
  const lines = [
    { type: 'stream_event', event: { type: 'content_block_start', content_block: { type: 'thinking' } } },
    { type: 'stream_event', event: { type: 'content_block_start', content_block: { type: 'tool_use', name: 'Read' } } },
    { type: 'stream_event', event: { type: 'content_block_stop' } },
    { type: 'stream_event', event: { type: 'content_block_start', content_block: { type: 'tool_use', name: 'Bash' } } },
    { type: 'stream_event', event: { type: 'content_block_stop' } },
    { type: 'stream_event', event: { type: 'content_block_start', content_block: { type: 'text', text: '' } } },
    { type: 'stream_event', event: { type: 'content_block_delta', delta: { type: 'text_delta', text: 'Now the render section.' } } },
  ].map((r) => JSON.stringify(r)).join('\n');
  const r = liveOutputFromJsonl(lines);
  assert.strictEqual(r.text, '▶ Read\n▶ Bash\nNow the render section.');
});

test('liveOutputFromJsonl separates distinct text blocks with a newline (each narration round is its own block in the real stream, with no separator of its own)', () => {
  const lines = [
    { type: 'stream_event', event: { type: 'content_block_start', content_block: { type: 'text', text: '' } } },
    { type: 'stream_event', event: { type: 'content_block_delta', delta: { type: 'text_delta', text: "I'll start by reading the files." } } },
    { type: 'stream_event', event: { type: 'content_block_stop' } },
    { type: 'stream_event', event: { type: 'content_block_start', content_block: { type: 'tool_use', name: 'Read' } } },
    { type: 'stream_event', event: { type: 'content_block_stop' } },
    { type: 'stream_event', event: { type: 'content_block_start', content_block: { type: 'text', text: '' } } },
    { type: 'stream_event', event: { type: 'content_block_delta', delta: { type: 'text_delta', text: 'Now let me make the fix.' } } },
    { type: 'stream_event', event: { type: 'content_block_stop' } },
  ].map((r) => JSON.stringify(r)).join('\n');
  assert.strictEqual(liveOutputFromJsonl(lines).text, "I'll start by reading the files.\n▶ Read\nNow let me make the fix.");
});

test('liveOutputFromJsonl does not add a leading newline before the very first text block', () => {
  const lines = [
    { type: 'stream_event', event: { type: 'content_block_start', content_block: { type: 'text', text: '' } } },
    { type: 'stream_event', event: { type: 'content_block_delta', delta: { type: 'text_delta', text: 'First.' } } },
  ].map((r) => JSON.stringify(r)).join('\n');
  assert.strictEqual(liveOutputFromJsonl(lines).text, 'First.');
});

test('liveOutputFromJsonl skips a garbled line and keeps concatenating (mirrors parseJsonl tolerance)', () => {
  const lines = [
    JSON.stringify({ type: 'stream_event', event: { type: 'content_block_delta', delta: { type: 'text_delta', text: 'before ' } } }),
    'a stray non-JSON stderr line',
    JSON.stringify({ type: 'stream_event', event: { type: 'content_block_delta', delta: { type: 'text_delta', text: 'after' } } }),
  ].join('\n');
  assert.strictEqual(liveOutputFromJsonl(lines).text, 'before after');
});

test('liveOutputFromJsonl handles empty/missing input', () => {
  assert.deepStrictEqual(liveOutputFromJsonl(''), { text: '', tool: null });
  assert.deepStrictEqual(liveOutputFromJsonl(null), { text: '', tool: null });
});

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail === 0 ? 0 : 1);
