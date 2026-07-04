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
//     "ideaBullets": ["<original bullet text from IDEAS.md, for fuzzy removal>", ...]
//   }
//
// Does, in order:
//   1. Allocate sequential real ids for every unit across every pending file (deterministic order:
//      files sorted by name, units in array order).
//   2. Resolve dependsOn: a tempId → its newly-allocated real id; an id that already matches an
//      EXISTING task is left as-is; anything else is dropped with a warning (never silently kept
//      as a dangling reference).
//   3. Write each unit's tasks/TNNN.md spec file (## Do / ## Done when from specDo/specDoneWhen).
//   4. Append the new task objects to TASKS.json (never touches existing tasks/status).
//   5. Fuzzy-remove each processed idea's bullets from tracking/IDEAS.md (exact → prefix →
//      substring fallback, since captured idea text won't byte-match hand-wrapped markdown).
//
// Idempotent: only ever processes whatever .pending-tasks/*.json files exist right now; the
// wrapper script (consolidate-ideas.sh) deletes them after a successful commit.
'use strict';

import fs from 'node:fs';
import path from 'node:path';

const HARNESS_DIR = path.join(path.dirname(new URL(import.meta.url).pathname), '..');
const ROOT = path.join(HARNESS_DIR, '..');
const TASKS_PATH = path.join(HARNESS_DIR, 'tracking', 'TASKS.json');
const IDEAS_PATH = path.join(HARNESS_DIR, 'tracking', 'IDEAS.md');
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

function normalizeForMatch(text) {
  // Strip a leading bullet marker + backticks, so the stored bullet (no marker, no backticks) matches
  // a wrapped file bullet reconstructed from its lines.
  return text
    .replace(/^\s*([-*]|\d+\.)\s+/, '')
    .replace(/`/g, '')
    .replace(/\s+/g, ' ')
    .trim()
    .toLowerCase();
}

const isBulletStart = (l) => /^\s*([-*]|\d+\.)\s+/.test(l);
const isHeading = (l) => /^\s*#{1,6}\s+/.test(l);

// Bounds [lo, hi) of the "## Inbox" section, so bullet removal only ever touches the inbox and can't
// splice a matching line out of a heading or a done/archive section. No explicit Inbox → whole file.
function inboxBounds(lines) {
  const start = lines.findIndex((l) => /^\s*##\s+Inbox\b/i.test(l));
  if (start === -1) return [0, lines.length];
  let end = lines.length;
  for (let i = start + 1; i < lines.length; i++) {
    if (/^\s*##\s+/.test(lines[i])) { end = i; break; }
  }
  return [start + 1, end];
}

// Reconstruct the inbox's LOGICAL bullets: each is a bullet-start line plus its wrapped continuation
// lines (not a new bullet / heading / blank), joined and normalized. So a bullet that wraps across
// lines matches its single-line stored form.
function inboxBullets(lines) {
  const [lo, hi] = inboxBounds(lines);
  const bullets = [];
  for (let i = lo; i < hi; i++) {
    if (!isBulletStart(lines[i])) continue;
    let end = i + 1;
    while (end < hi && !isBulletStart(lines[end]) && !isHeading(lines[end]) && lines[end].trim() !== '') end++;
    bullets.push({ start: i, end, text: normalizeForMatch(lines.slice(i, end).join(' ')) });
    i = end - 1;
  }
  return bullets;
}

// Fuzzy-remove a bullet from IDEAS.md's Inbox: exact → prefix → substring (either direction), matched
// against reconstructed logical bullets; removes the WHOLE span (bullet line + wrapped continuations).
// Warns (doesn't throw) if nothing matches — the bullet may already be hand-edited/removed.
function removeIdeaBullet(ideasText, bullet) {
  const lines = ideasText.split('\n');
  const bullets = inboxBullets(lines);
  const target = normalizeForMatch(bullet);
  const targetPrefix = target.slice(0, 200);

  let b = bullets.find((x) => x.text === target);
  if (!b) b = bullets.find((x) => targetPrefix.length > 20 && x.text.startsWith(targetPrefix));
  if (!b) b = bullets.find((x) => target.length > 20 && x.text.includes(target.slice(0, 80)));
  if (!b) b = bullets.find((x) => x.text.length > 20 && target.includes(x.text.slice(0, 80)));
  if (!b) {
    console.warn(`WARN: could not find idea bullet to remove (already edited?): ${bullet.slice(0, 60)}...`);
    return ideasText;
  }
  lines.splice(b.start, b.end - b.start);
  return lines.join('\n');
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
  const allBullets = [];
  for (const f of files) {
    const parsed = readJson(path.join(PENDING_DIR, f));
    for (const unit of parsed.units || []) allUnits.push(unit);
    for (const bullet of parsed.ideaBullets || []) allBullets.push(bullet);
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
  fs.writeFileSync(TASKS_PATH, JSON.stringify(tasksDoc, null, 2) + '\n');

  if (fs.existsSync(IDEAS_PATH)) {
    let ideasText = fs.readFileSync(IDEAS_PATH, 'utf8');
    for (const bullet of allBullets) ideasText = removeIdeaBullet(ideasText, bullet);
    fs.writeFileSync(IDEAS_PATH, ideasText);
  }

  console.log(`consolidate-ideas: added ${newTasks.length} task(s): ${newTasks.map((t) => t.id).join(', ')}`);
}

main();
