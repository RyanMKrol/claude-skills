---
name: ralph-loop-add-to-backlog
description: >-
  Use when a project already has the Ralph harness (docs/HARNESS.md, scripts/loop.sh, TASKS.json
  present) and the user wants to draft or extend the task backlog — phrases like "add tasks",
  "write the backlog", "turn this feature into tasks", "plan the next phase for the loop". Runs a
  focused interview that turns a feature description into atomic, dependency-ordered TASKS.json task
  objects following the HARNESS.md §8.1 schema (dependsOn / scope / design / verify / do / doneWhen),
  with per-task model selection + optional escalation, gate / needs-human markers, appended without
  disturbing existing tasks.
argument-hint: "[feature or phase to break into tasks]"
allowed-tools: Read, Write, Edit, Bash, Glob, AskUserQuestion
---

# Author / extend the TASKS.json backlog

You are turning a feature or phase description into well-formed `TASKS.json` task objects that the
single-loop harness can build. Read this whole file, then execute in order. The cardinal rule:
**append, never clobber** — existing task objects and their `status` are sacred.

## 1. Pre-flight

- Require the harness: `TASKS.json`, `docs/HARNESS.md`, and `scripts/loop.sh` must exist in the
  project. If any is missing, stop and point the user at `/ralph-loop-create-harness` first.
- Require `jq` (the loop and this skill use it). If absent, tell the user to `brew install jq`.
- **Read `docs/HARNESS.md` §8.1** (the task schema) live — bind to the actual schema in this
  project, in case it has evolved. Don't rely on a hardcoded copy.
- **Read `TASKS.json`** and extract, with jq:
  - the highest existing id — `jq -r '.tasks[].id' TASKS.json | sort | tail -1` → new ids continue
    monotonically, zero-padded to the same width (≥3 digits);
  - all existing ids (`jq -r '.tasks[].id'`), so `dependsOn` references real tasks, never a dupe;
  - the file's `defaults` (`jq '.defaults'`) — the default model/effort/escalation, so you only set
    per-task `model`/`effort`/`escalation` when a task should differ from them.

## 2. Interview

Use `AskUserQuestion`. Establish:

1. **What are we building?** The feature/phase in prose (use the skill argument if provided).
2. **Decomposition.** Probe for natural atomic units and their order:
   - interface-first vs feature-first; what must exist before what (dependencies);
   - what is independently testable;
   - anything that should be a separate task because it touches a different scope.
3. **Per task**, settle:
   - **scope** — the files this task should touch (keeps diffs tight for the CI gate).
   - **design** — does it need a fuller `docs/designs/TNNN-slug.md` plan doc? Optional; only when
     warranted (those are authored separately, interactively, at `--effort max`). Else `null`.
   - **verify** — does it need an empirical check (e.g. `["run-app"]`, `["live-api"]`)? If the
     project captured a run/backtest command at scaffold time, reuse that label. Else `[]`.
   - **doneWhen** — the task-specific acceptance bar. Do **not** restate the universal bar
     (format/lint/test, CI green, docs lockstep) — that lives once in HARNESS §5.
4. **Model & escalation (per task).** This is how spend is controlled — match the model to the
   work, and only override the file `defaults` when the task differs:
   - **simple / mechanical** (manual validation, a docs pass, config wiring, a rote refactor) →
     a cheaper model, e.g. `"model": "claude-sonnet-4-6", "effort": "medium"`, usually with an
     `"escalation": [{"model":"claude-opus-4-8","effort":"high"}]` rung so it auto-upgrades if it
     gets stuck;
   - **judgement-heavy** (coding against a tricky interface, test design, reflection, anything
     where a wrong-but-plausible result is costly) → the strong model (the default Opus/high) —
     omit `model`/`effort` to inherit `defaults`;
   - tag tasks with `tags` (e.g. `["validation"]`, `["coding"]`) to make the routing legible.
   When unsure, default to the strong model — a redone task costs more than the cheaper run saved.
5. **Gates.** Ask which tasks:
   - freeze an interface, validate an approach, or rely on experimental data others will trust →
     `"gate": "gate"` (human reviews the deliverable before dependents proceed);
   - need credentials, provisioning, real money, or production access → `"gate": "needs-human"`.
   - otherwise `"gate": null`.
6. **Sizing.** Push back on any task too big for a single context window (HARNESS §12) — offer to
   split it. Remember a too-weak starting model burns MAX_ATTEMPTS attempts before escalating, so
   size the model honestly too.

## 3. Generate the task objects (schema-correct per HARNESS §8.1)

For each task, in dependency order, produce a JSON object:

```jsonc
{
  "id": "TNNN",
  "title": "<concise title>",
  "status": "pending",
  "dependsOn": ["<ids>"],            // [] if none
  "gate": null,                       // null | "gate" | "needs-human"
  "tags": ["<type>"],                 // optional
  "model": "claude-sonnet-4-6",       // OMIT to inherit defaults (strong model)
  "effort": "medium",                 // OMIT to inherit defaults
  "escalation": [ { "model": "claude-opus-4-8", "effort": "high" } ],  // OMIT for no escalation
  "scope": ["<files/globs>"],
  "design": null,                     // or "docs/designs/TNNN-slug.md"
  "verify": [],                       // or ["run-app"]
  "do": "<the work, 1–3 sentences>",
  "doneWhen": "<task-specific acceptance criteria>"
}
```

Rules: ids monotonic from the existing max, zero-padded; `dependsOn` references only ids that exist
(existing or newly-added-above); omit `model`/`effort`/`escalation` to inherit `defaults` rather
than restating them; `status` is always `"pending"` (the loop flips it to `"done"`).

## 4. Append, don't clobber — via jq

Append the new objects so existing tasks and their `status` are untouched. Build the new objects as
a JSON array in a temp file `new-tasks.json`, then:

```sh
jq --slurpfile add new-tasks.json '.tasks += $add[0]' TASKS.json > TASKS.json.tmp \
  && jq empty TASKS.json.tmp \
  && mv TASKS.json.tmp TASKS.json
```

Never hand-edit existing task objects, and never change any existing `status`. (jq normalises
whitespace for the whole file — that's fine; the content of prior tasks is preserved verbatim.)

## 5. Validate before finishing

- `jq empty TASKS.json` passes (still valid JSON).
- Existing task count + new count == total: `jq '.tasks | length' TASKS.json` matches expectation,
  and no prior `status` changed (`jq -r '.tasks[]|select(.status=="done")|.id'` is unchanged).
- Every `dependsOn` id exists (`jq` cross-check), no dangling deps, no cycles, no duplicate ids.
- `gate` is one of `null` / `"gate"` / `"needs-human"`; every `model` is a full id (no bare alias).
- Print a short summary: tasks added, each with its deps + chosen model (or "default"), so the user
  can confirm both the dependency graph and the model routing read correctly.

## 6. Hand off

Tell the user the loop will pick these up in dependency order on the next `scripts/loop.sh` /
`scripts/supervise.sh` pass — building one at a time on each task's chosen model, escalating on
repeated failure, and stopping at any `gate` / `needs-human` task for them.
