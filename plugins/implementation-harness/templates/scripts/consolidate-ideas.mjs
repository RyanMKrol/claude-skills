#!/usr/bin/env node
// consolidate-ideas.mjs — the single locked consolidation pass of the ideas→tasks pipeline.
// Pure data processing, NO git (that's consolidate-ideas.sh's job). Node core modules only.
//
// Reads every .harness/.pending-tasks/<slug>.json left by the implementation-harness-convert-ideas
// skill's per-idea conversion agents, each shaped:
//   {
//     "units": [
//       { "tempId": "idea1-a", "title": "...", "dependsOn": ["idea1-a"|"T003"], "gate": null,
//         "tags": [...], "scope": [...], "design": null, "verify": [...], "expectsTest": false,
//         "facets": { "layer": "...", "workType": "...", "risk": [] },   // omit for needs-human
//         "specDo": "...", "specDoneWhen": "..." },
//       ...
//     ],
//     "ideaIds": [<the id(s) from tracking/IDEAS.jsonl this unit set consumed>, ...]
//   }
// A review-failed unit that RE-ATTEMPTS a terminal-failed task may additionally carry
//   "rewireFrom": "<oldFailedId>", "rewireDependents": ["<existing task id>", ...]
// to repoint pre-existing dependents of the failed task onto this replacement (step 5 below).
//
// Does, in order:
//   1. Allocate sequential real ids for every unit across every pending file (deterministic order:
//      files sorted by name, units in array order).
//   2. Resolve dependsOn: a tempId → its newly-allocated real id; an id that already matches an
//      EXISTING task is left as-is; anything else is dropped with a warning (never silently kept
//      as a dangling reference).
//   3. Write each unit's tasks/TNNN.md spec file (## Do / ## Done when from specDo/specDoneWhen).
//   4. Append the new task objects to TASKS.json, then rewire any rewireDependents onto the
//      replacement (swap the dead rewireFrom id for the new real id in each existing dependent's
//      dependsOn). Existing tasks' status is never touched — only a named dependent's dependsOn.
//   5. Remove each processed idea's row from tracking/IDEAS.jsonl by `id` (an id with no matching
//      row is a no-op — e.g. review-failed units, which have no real idea id at all).
//
// Idempotent: only ever processes whatever .pending-tasks/*.json files exist right now; the
// wrapper script (consolidate-ideas.sh) deletes them after a successful commit.
'use strict';

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

// Use fileURLToPath, NOT new URL(...).pathname — the latter yields a percent-encoded path
// (e.g. /Users/x/My%20Repo/...) for any repo path containing spaces or other special chars,
// which then ENOENTs every fs call below and breaks the whole consolidation for such repos.
const HARNESS_DIR = path.join(path.dirname(fileURLToPath(import.meta.url)), '..');
const ROOT = path.join(HARNESS_DIR, '..');
const TASKS_PATH = path.join(HARNESS_DIR, 'tracking', 'TASKS.json');
const IDEAS_PATH = path.join(HARNESS_DIR, 'tracking', 'IDEAS.jsonl');
const PENDING_DIR = path.join(HARNESS_DIR, '.pending-tasks');
const TASKS_DIR = path.join(HARNESS_DIR, 'tasks');

function readJson(p) {
  return JSON.parse(fs.readFileSync(p, 'utf8'));
}

function nextIdSequence(existingIds, count) {
  let max = 0;
  for (const id of existingIds) {
    const m = /^T(\d+)$/.exec(id);
    if (m) max = Math.max(max, parseInt(m[1], 10));
  }
  const width = Math.max(3, String(max).length);
  const out = [];
  for (let i = 1; i <= count; i++) {
    out.push('T' + String(max + i).padStart(width, '0'));
  }
  return out;
}

// removeIdeaRows(ideasText, ids) — drop every JSONL row whose `id` is in `ids` (a Set). A garbled
// line is preserved as-is (not our job to fix it here); an id with no matching row is simply a
// no-op (e.g. review-failed's units, which never had a real idea id).
function removeIdeaRows(ideasText, ids) {
  if (!ideasText) return ideasText;
  const lines = ideasText.split('\n');
  const kept = lines.filter((line) => {
    if (!line.trim()) return false;   // drop blank lines while we're rewriting anyway
    let row;
    try { row = JSON.parse(line); } catch (_err) { return true; }   // keep unparseable lines untouched
    return !(row && ids.has(row.id));
  });
  return kept.length ? kept.join('\n') + '\n' : '';
}

function main() {
  if (!fs.existsSync(PENDING_DIR)) {
    console.log('consolidate-ideas: no .pending-tasks/ directory — nothing to do');
    return;
  }
  const files = fs.readdirSync(PENDING_DIR).filter((f) => f.endsWith('.json')).sort();
  if (!files.length) {
    console.log('consolidate-ideas: no pending task files — nothing to do');
    return;
  }

  const tasksDoc = readJson(TASKS_PATH);
  const existingIds = new Set(tasksDoc.tasks.map((t) => t.id));

  const allUnits = [];
  const allIdeaIds = new Set();
  for (const f of files) {
    const parsed = readJson(path.join(PENDING_DIR, f));
    for (const unit of parsed.units || []) allUnits.push(unit);
    for (const id of parsed.ideaIds || []) allIdeaIds.add(id);
  }
  if (!allUnits.length) {
    console.log('consolidate-ideas: pending files had no units — nothing to do');
    return;
  }

  const realIds = nextIdSequence(existingIds, allUnits.length);
  const tempToReal = new Map();
  allUnits.forEach((unit, i) => {
    if (unit.tempId) tempToReal.set(unit.tempId, realIds[i]);
  });

  const newTasks = [];
  allUnits.forEach((unit, i) => {
    const id = realIds[i];
    const resolvedDeps = (unit.dependsOn || [])
      .map((d) => {
        if (tempToReal.has(d)) return tempToReal.get(d);
        if (existingIds.has(d)) return d;
        console.warn(`WARN: ${id} dependsOn "${d}" does not resolve to any temp or real id — dropped`);
        return null;
      })
      .filter(Boolean);

    const specRel = path.join('.harness', 'tasks', `${id}.md`).split(path.sep).join('/');
    const specOverview = unit.specOverview || '';
    const specDo = unit.specDo || '(missing ## Do — fix before building)';
    const specDoneWhen = unit.specDoneWhen || '(missing ## Done when — fix before building)';
    if (!unit.specDo || !unit.specDoneWhen) {
      console.warn(`WARN: ${id} is missing specDo/specDoneWhen — wrote a placeholder spec`);
    }
    if (!specOverview) {
      console.warn(`WARN: ${id} has no specOverview — spec written without the leading ## Overview (one or two plain-language sentences: what & why)`);
    }
    // A leading ## Overview (the plain-language "what are we doing, at a glance" — read first) precedes
    // the denser Do / Done-when detail when the author supplied one.
    const overviewBlock = specOverview ? `## Overview\n${specOverview}\n\n` : '';
    fs.writeFileSync(
      path.join(TASKS_DIR, `${id}.md`),
      `${overviewBlock}## Do\n${specDo}\n\n## Done when\n${specDoneWhen}\n`
    );

    // A needs-human task carries a "needs-human" tag so any tag-based consumer (dashboards, filters)
    // sees it, not just readers of the `gate` field.
    const tags = Array.isArray(unit.tags) ? [...unit.tags] : [];
    if (unit.gate === 'needs-human' && !tags.includes('needs-human')) tags.push('needs-human');

    const task = {
      id,
      title: unit.title || id,
      status: 'pending',
      dependsOn: resolvedDeps,
      gate: unit.gate ?? null,
      tags,
      scope: unit.scope || [],
      design: unit.design ?? null,
      verify: unit.verify || [],
      expectsTest: !!unit.expectsTest,
      spec: specRel,
    };
    // Carry the optional visualVerify opt-in/out THROUGH to the task (only when the unit set it —
    // omitting the field means "fall back to the facets heuristic at runtime"). A boolean check keeps
    // a stray string/null from becoming a truthy field.
    if (typeof unit.visualVerify === 'boolean') task.visualVerify = unit.visualVerify;
    if (unit.gate !== 'needs-human' && unit.facets) task.facets = unit.facets;
    newTasks.push(task);
  });

  tasksDoc.tasks.push(...newTasks);

  // Rewire PRE-EXISTING dependents of a replaced failed task onto its replacement. A review-failed unit
  // that re-attempts a terminal-failed task carries { "rewireFrom": "<oldFailedId>", "rewireDependents":
  // ["<existing task id>", ...] }: for each named existing task, swap the dead id for THIS unit's new
  // real id in its dependsOn. Without this, a task that depended on the failed one is stranded forever
  // (the failed task is terminal — never re-attempted — and the replacement has a brand-new id). Only
  // review-failed sets these fields; convert-ideas units never do, so this is a no-op for them.
  const byId = new Map(tasksDoc.tasks.map((t) => [t.id, t]));
  let rewired = 0;
  allUnits.forEach((unit, i) => {
    const newId = realIds[i];
    const from = unit.rewireFrom;
    const deps = unit.rewireDependents;
    if (!from || !Array.isArray(deps) || !deps.length) return;
    for (const depId of deps) {
      const t = byId.get(depId);
      if (!t) { console.warn(`WARN: rewireDependents names "${depId}", not an existing task — skipped`); continue; }
      const cur = Array.isArray(t.dependsOn) ? t.dependsOn : [];
      if (!cur.includes(from)) { console.warn(`WARN: ${depId} does not depend on ${from} (rewireFrom) — left unchanged`); continue; }
      const next = cur.filter((d) => d !== from);          // drop the dead id
      if (!next.includes(newId)) next.push(newId);          // point at the replacement (dedup)
      t.dependsOn = next;
      rewired++;
      console.log(`consolidate-ideas: rewired ${depId} dependsOn ${from} -> ${newId}`);
    }
  });

  fs.writeFileSync(TASKS_PATH, JSON.stringify(tasksDoc, null, 2) + '\n');

  if (allIdeaIds.size && fs.existsSync(IDEAS_PATH)) {
    const ideasText = fs.readFileSync(IDEAS_PATH, 'utf8');
    fs.writeFileSync(IDEAS_PATH, removeIdeaRows(ideasText, allIdeaIds));
  }

  console.log(`consolidate-ideas: added ${newTasks.length} task(s): ${newTasks.map((t) => t.id).join(', ')}`);
}

main();
