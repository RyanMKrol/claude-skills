---
name: ralph-loop-add-to-backlog
description: >-
  Use when a project already has the Ralph harness (docs/HARNESS.md, scripts/loop.sh, TASKS.md
  present) and the user wants to draft or extend the task backlog — phrases like "add tasks",
  "write the backlog", "turn this feature into tasks", "plan the next phase for the loop". Runs a
  focused interview that turns a feature description into atomic, dependency-ordered TASKS.md
  entries following the HARNESS.md §8.1 schema (Depends on / Scope / Design / Verify / Do /
  Done-when), with 🚦 Gate / 🔒 needs-human markers and the status-index checkboxes, appended
  without disturbing existing tasks.
argument-hint: "[feature or phase to break into tasks]"
allowed-tools: Read, Write, Edit, Bash, Glob, AskUserQuestion
---

# Author / extend the TASKS.md backlog

You are turning a feature or phase description into well-formed `TASKS.md` entries that the
single-loop harness can build. Read this whole file, then execute in order. The cardinal rule:
**append, never clobber** — existing tasks and their checkbox state are sacred.

## 1. Pre-flight

- Require the harness: `TASKS.md`, `docs/HARNESS.md`, and `scripts/loop.sh` must exist in the
  project. If any is missing, stop and point the user at `/ralph-loop-create-harness` first.
- **Read `docs/HARNESS.md` §8.1** (the task schema) live — bind to the actual schema in this
  project, in case it has evolved. Don't rely on a hardcoded copy.
- **Read `TASKS.md`** and extract:
  - the highest existing task id (`T0xx`) → new ids continue monotonically, zero-padded to the
    same width (≥3 digits);
  - the phase grouping (the `**Phase N — …**` headers in the Status index), if any;
  - all existing ids, so `Depends on:` can reference real tasks and you never duplicate an id.
- Note how the loop reads tasks: the **index checkbox line** is the only status source, and the
  loop detects gates (🚦 / 🔒) **on the index line** — so markers MUST go there, not only in the
  detail block.

## 2. Interview

Use `AskUserQuestion`. Establish:

1. **What are we building?** The feature/phase in prose (use the skill argument if provided).
2. **Decomposition.** Probe for natural atomic units and their order:
   - interface-first vs feature-first; what must exist before what (dependencies);
   - what is independently testable;
   - anything that should be a separate task because it touches a different scope.
3. **Per task**, settle:
   - **Scope** — the files this task should touch (keeps diffs tight for the CI gate).
   - **Design** — does it need a fuller `docs/designs/TNNN-slug.md` plan doc? Optional; only when
     warranted (those are authored separately, interactively, at `--effort max`).
   - **Verify** — does it need an empirical check (e.g. `run-app`, `live-api`)? If the project
     captured a run/backtest command at scaffold time, reuse that label.
   - **Done-when** — the task-specific acceptance bar. Do **not** restate the universal bar
     (format/lint/test, CI green, docs lockstep) — that lives once in HARNESS §5.
4. **Gates.** Ask which tasks:
   - freeze an interface, validate an approach, or rely on experimental data others will trust →
     **🚦 Gate** (human reviews the deliverable before dependents proceed);
   - need credentials, provisioning, real money, or production access → **🔒 needs-human**.
5. **Sizing.** Push back on any task too big for a single context window (HARNESS §12) — offer to
   split it.

## 3. Generate the entries (schema-correct per HARNESS §8.1)

For each task, in dependency order, produce two things:

**(a) A Status-index line** under the right phase:
```
- [ ] TNNN <concise title>            # add ` 🚦 Gate` or ` 🔒 needs-human` when applicable
```

**(b) A detail block** in the Tasks section:
```
### TNNN — <concise title>
- **Depends on:** <ids, or (none)>
- **Scope:** `<files/globs this task touches>`
- **Design:** docs/designs/TNNN-<slug>.md      # OPTIONAL — only if one is warranted
- **Verify:** <label>                            # OPTIONAL — empirical check(s)
- **Do:** <the work, 1–3 sentences>
- **Done-when:** <task-specific acceptance criteria>
```

Rules: ids monotonic from the existing max, zero-padded; `Depends on:` references only ids that
exist (existing or newly-added-above); omit `Design:`/`Verify:` when not needed rather than
leaving them blank.

## 4. Edit, don't clobber

- Insert the new index lines into the Status index (under the correct phase header, creating a new
  `**Phase N — …**` header only if the user wants a new phase).
- Append the new detail blocks to the Tasks section.
- Use **targeted `Edit`s** that add lines; never rewrite the file or touch existing tasks'
  checkboxes or text.

## 5. Validate before finishing

- Every `Depends on:` id exists in the index (no dangling deps, no cycles).
- No duplicate ids; index lines and detail blocks are 1:1 (every new index entry has a block and
  vice versa).
- Gate markers (🚦 / 🔒) appear on the **index line**.
- Print a short summary: the tasks added, each with its deps, so the user can confirm the
  dependency graph reads correctly.

## 6. Hand off

Tell the user the loop will pick these up in dependency order on the next `scripts/loop.sh` /
`scripts/supervise.sh` pass, building one at a time and stopping at any 🚦 / 🔒 task for them.
