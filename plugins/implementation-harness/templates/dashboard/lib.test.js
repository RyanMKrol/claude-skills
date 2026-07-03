// lib.test.js — a small, dependency-free test suite for lib.js (Node's built-in `assert` only,
// matching the dashboard's own no-npm-dependency philosophy). Run standalone:
//   node .harness/dashboard/lib.test.js
'use strict';

const assert = require('assert');
const { computeBacklog } = require('./lib');

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

test('a status:failed task lands in done, flagged failed', () => {
  const tasks = { tasks: [{ id: 'T001', status: 'failed', gate: null, dependsOn: [] }] };
  const b = computeBacklog(tasks, EMPTY_OVERLAYS, new Set());
  assert.strictEqual(b.done.length, 1);
  assert.strictEqual(b.done[0].failed, true);
});

test('human-done overlay promotes a needs-human task to done', () => {
  const tasks = { tasks: [{ id: 'T001', status: 'pending', gate: 'needs-human', dependsOn: [] }] };
  const overlays = { ...EMPTY_OVERLAYS, humanDone: { T001: { done: true } } };
  const b = computeBacklog(tasks, overlays, new Set());
  assert.strictEqual(b.done.length, 1);
  assert.strictEqual(b.needsHuman.length, 0);
});

test('manual-fail overlay overturns a done task into done+failed (not needs-human)', () => {
  const tasks = { tasks: [{ id: 'T001', status: 'done', gate: null, dependsOn: [] }] };
  const overlays = { ...EMPTY_OVERLAYS, manualFail: { T001: { failed: true } } };
  const b = computeBacklog(tasks, overlays, new Set());
  assert.strictEqual(b.done.length, 1);
  assert.strictEqual(b.done[0].failed, true);
});

test('gate and needs-human tasks land in needsHuman', () => {
  const tasks = {
    tasks: [
      { id: 'T001', status: 'pending', gate: 'gate', dependsOn: [] },
      { id: 'T002', status: 'pending', gate: 'needs-human', dependsOn: [] },
    ],
  };
  const b = computeBacklog(tasks, EMPTY_OVERLAYS, new Set());
  assert.strictEqual(b.needsHuman.length, 2);
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

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail === 0 ? 0 : 1);
