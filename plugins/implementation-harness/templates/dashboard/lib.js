// lib.js — pure, file-I/O-free backlog-derivation logic for the harness dashboard.
//
// computeBacklog() MUST mirror the loop's own task-selection logic (scripts/loop.sh /
// loop.in-place.sh select_task, and postflight.sh's board) exactly, so the dashboard never shows
// a state that disagrees with what the loop will actually do next. If you change select_task's
// eligibility rules, update this function to match.
//
// Bucket precedence (a task lands in exactly one bucket): done > needsHuman > waiting > ready.
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
  // (kept for tasks blocked before status:"blocked" existed).
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

// computeBacklog(tasksJson, overlays, blockedIds) -> { ready, waiting, needsHuman, done }
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

  const buckets = { ready: [], waiting: [], needsHuman: [], done: [] };

  for (const task of tasks) {
    const reviewed = isReviewed(task, overlays);
    if (isTerminalDone(task, overlays) || isFailed(task, overlays)) {
      buckets.done.push({ ...task, failed: isFailed(task, overlays), reviewed });
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

  // done-bucket sort: not-reviewed items first, then ascending numeric task id within each group —
  // keeps the done list from burying unreviewed work under a long history of already-checked tasks.
  buckets.done.sort((a, b) => {
    if (a.reviewed !== b.reviewed) return a.reviewed ? 1 : -1;
    return numericId(a.id) - numericId(b.id);
  });

  return buckets;
}

module.exports = { computeBacklog, isTerminalDone, isFailed, isNeedsHuman, isReviewed, numericId };
