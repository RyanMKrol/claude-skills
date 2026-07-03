---
name: implementation-harness-add-to-backlog
description: >-
  Use when a project already has the implementation harness (.harness/HARNESS.md, .harness/loop.sh, TASKS.json
  present) and the user wants to draft or extend the task backlog — phrases like "add tasks",
  "write the backlog", "turn this feature into tasks", "plan the next phase for the loop". Runs a
  focused interview that turns a feature description into atomic, dependency-ordered TASKS.json task
  objects following the HARNESS.md §8.1 schema (dependsOn / scope / design / verify / facets + a
  per-task `spec` Markdown file), with difficulty auto-tuned from facets, gate / needs-human markers, appended without
  disturbing existing tasks.
argument-hint: "[feature or phase to break into tasks]"
allowed-tools: Read, Write, Edit, Bash, Glob, AskUserQuestion
---

# Author / extend the TASKS.json backlog

You are turning a feature or phase description into well-formed `TASKS.json` task objects that the
single-loop harness can build. Read this whole file, then execute in order. The cardinal rule:
**append, never clobber** — existing *pending / in-flight* task objects and their `status` are
sacred. (Completed `done` tasks may be deliberately pruned to keep the backlog readable — see §7 —
but are never silently altered during an append.)

## 1. Pre-flight

- Require the harness: `TASKS.json`, `.harness/HARNESS.md`, and `.harness/loop.sh` must exist in the
  project. If any is missing, stop and point the user at `/implementation-harness-create` first.
  (Either loop variant — worktree or in-place — installs as `.harness/loop.sh` and keeps
  `TASKS.json` at the repo root, so this skill is identical for both.)
- Require `jq` (the loop and this skill use it). If absent, tell the user to `brew install jq`.
- **Read `.harness/HARNESS.md` §8.1** (the task schema) live — bind to the actual schema in this
  project, in case it has evolved. Don't rely on a hardcoded copy.
- **Read `TASKS.json`** and extract, with jq:
  - the highest existing id — `jq -r '.tasks[].id' TASKS.json | sort | tail -1` → new ids continue
    monotonically, zero-padded to the same width (≥3 digits);
  - all existing ids (`jq -r '.tasks[].id'`), so `dependsOn` references real tasks, never a dupe;
  - Tasks carry NO per-task model/effort/escalation; the policy auto-tunes difficulty from
    `facets` + the ledger (the cold-start floor lives in `harness.env`, not `TASKS.json`).
- **Read `facets.json`** (`jq '.facets'`) — the controlled facet vocabulary you'll assign in §2.4.

- **Poor-fit gate — has the `layer` vocabulary drifted?** If `facet-misfits.jsonl` exists, count its
  lines; if that count ≥ `facets.json`'s `.policy.poorFitThreshold` (default 5), run a **layer
  re-evaluation BEFORE authoring anything**:
  1. **Re-cluster (you do this):** read the recent backlog + `facet-misfits.jsonl` + the current
     `layer` values, and propose an updated `layer` set (add / split / merge / rename) that fits the
     project as it now is.
  2. **Surface it to the human — TEACH first, they may not know this machinery exists.** Open with a
     short plain-language paragraph, *then* the proposed diff. Use this template:

     > *"Heads up: this project's build harness automatically decides how much AI effort (which model
     > + reasoning level) to spend on each task, and learns from results — it starts cheap, escalates
     > only when a task fails, and remembers which kinds of work need more power. It groups tasks by
     > 'layer' (roughly, where in the codebase the work lives) to make those predictions. We've now
     > seen **N** recent tasks that didn't fit any existing layer well, which usually means the project
     > has grown past its current layer list. Here's a proposed updated set: `<diff>`. Approving it
     > re-groups recent work so the harness keeps predicting difficulty accurately. It's optional and
     > reversible — declining just keeps the current layers."*

  3. **On accept — MIGRATE history (don't skip):** update `facets.json`'s `layer` values; remap the
     `facets.layer` in existing `outcomes.jsonl` rows AND re-tag affected tasks' `facets` in
     `TASKS.json` to the new values (rename = substitute; split = reassign by scope; merge = union) —
     otherwise the changed calibration cells silently cold-start. Then **clear `facet-misfits.jsonl`**
     (cooldown, so it doesn't re-fire next task). The human approves/nudges/declines — they never do
     the clustering. On decline, leave everything and proceed.

## 2. Interview

Use `AskUserQuestion`. Establish:

1. **What are we building?** The feature/phase in prose (use the skill argument if provided).
2. **Decomposition.** Probe for natural atomic units and their order:
   - interface-first vs feature-first; what must exist before what (dependencies);
   - what is independently testable;
   - anything that should be a separate task because it touches a different scope.
3. **Per task**, settle:
   - **scope** — the files this task should touch (keeps diffs tight for the CI gate).
   - **design** — does it need a fuller `.harness/designs/TNNN-slug.md` plan doc? Optional; only when
     warranted (those are authored separately, interactively, at `--effort max`). Else `null`.
   - **verify** — does it need an empirical check (e.g. `["run-app"]`, `["live-api"]`)? If the
     project captured a run/backtest command at scaffold time, reuse that label. Else `[]`.
   - **do / done-when** — the work, and the task-specific acceptance bar. These go in the per-task
     Markdown spec `.harness/tasks/TNNN.md` (sections `## Do` / `## Done when`), NOT inline in the
     JSON (see §3). Do **not** restate the universal bar (format/lint/test, CI green, docs lockstep)
     in done-when — that lives once in HARNESS §6.
4. **Facets (per task) — DESCRIBE the task; the policy decides difficulty.** Difficulty (which model
   + effort to start on) is now AUTO-TUNED by the loop's policy from escalation history — you do NOT
   guess it (see `.harness/designs/difficulty-autotune.md`). Your job is to *classify* the task. Read the
   project's `facets.json` (`jq '.facets' facets.json`) and assign, choosing values ONLY from that
   controlled vocabulary:
   - **`layer`** (exactly one) — WHERE the change lives. Use the task's `scope` file paths as the
     primary signal (paths → layers).
   - **`work-type`** (exactly one) — WHAT KIND of change (style / docs / bugfix / feature / migration / …).
   - **`risk`** (zero or more) — danger flags (touches-schema, full-stack, …).

   Put these in a `"facets": { "layer": "...", "workType": "...", "risk": [...] }` object on the task.
   Do **NOT** set per-task `model`/`effort`/`escalation` at all — the policy picks the starting tier
   from facets + the outcomes ledger, escalation rides the global tier ladder in `facets.json`, and
   the cold-start floor lives in `harness.env`. `facets` is the ONLY difficulty signal you author.
   `needs-human`/gated tasks need NO facets (they never run through the loop).

   **If nothing fits — record a poor-fit signal; do NOT invent a value.** Minting an ad-hoc facet
   value re-fragments the calibration. If you're genuinely confident no existing `layer` (or
   `work-type`) fits, pick the CLOSEST existing value, tag the task with it, AND append a
   context-carrying line to `facet-misfits.jsonl` (at the harness root):
   `{ "taskId": "...", "axis": "layer"|"work-type", "closest": "...", "note": "<one line: what was missing>", "ts": "<iso8601>" }`.
5. **Gates.** The loop's selection **skips any task with a non-null `gate` entirely** — it never
   builds it, and a gated task still blocks its dependents until a human clears it. So mark as
   gated anything that isn't a clean autonomous build. Ask which tasks:
   - freeze an interface, validate an approach, or rely on experimental data others will trust →
     `"gate": "gate"` (human reviews the deliverable before dependents proceed);
   - need credentials, provisioning, real money, or production access, hinge on a human **decision**
     first, or aren't **machine-verifiable** (subjective "make it nicer" UI work, taste calls) →
     `"gate": "needs-human"`. Use it liberally — a needs-human task is parked safely, not lost.
   - otherwise `"gate": null`.
   Tip: if a task *feels* subjective but has a checkable proxy (e.g. "looks good on mobile" → an
   emulated-viewport check for overflow/truncation), prefer making it buildable with that `verify`.

   **Pair every "options to choose between" task with a review + a hardcode follow-up.** When a
   task builds MULTIPLE options for the owner to pick among (toggleable styles, strategy variants,
   A/B layouts), author — **in the same edit** — *three* linked tasks, never the chooser alone:
   (a) the **chooser** that builds the options behind a switch; (b) a paired **`needs-human`
   review** task that `dependsOn` the chooser (the human picks a winner and records it); and (c) a
   buildable **hardcode-the-winner** follow-up that `dependsOn` the review (bakes in the chosen
   option and deletes the switch + unused paths). Otherwise the evaluation scaffolding becomes
   permanent cruft. *Worked chain: T040 "build 5 caret styles behind a toggle" → T041 (needs-human)
   "review the styles, pick one" → T042 "hardcode the chosen caret, remove the toggle".*

   **Split a decision/unknown into its own `needs-human` task.** When a task hinges on a human
   **decision**, or on an **unknown that needs probing** before the real work can even be specified,
   don't ship one big task the loop will burn `MAX_ATTEMPTS` on — split it: a **`needs-human`
   decision/investigation** task that records the answer, plus a **dependent buildable** follow-up
   that implements it from the now-settled spec.
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
  "tags": ["<type>"],                 // optional, DESCRIPTIVE (feature area) — NOT the calibration key
  "facets": { "layer": "...", "workType": "...", "risk": [] },  // §2.4 — the ONLY difficulty signal; OMIT for needs-human/gated tasks
  "scope": ["<files/globs>"],
  "design": null,                     // or ".harness/designs/TNNN-slug.md"
  "verify": [],                       // or ["run-app"]
  "expectsTest": false,               // true → the loop requires a test file in the diff (structural gate); set for test-pinnable tasks
  "spec": ".harness/tasks/TNNN.md"    // the task's do/done-when (## Do / ## Done when) — author this MD file too
  // NO model/effort/escalation, NO inline do/doneWhen — the policy auto-tunes difficulty from facets + the ledger
}
```

Rules: ids monotonic from the existing max, zero-padded; `dependsOn` references only ids that exist
(existing or newly-added-above); NO per-task `model`/`effort`/`escalation` (difficulty is auto-tuned
from facets); `status` is always `"pending"` (the loop flips it to `"done"`). **For every task you
add, also create its `.harness/tasks/TNNN.md`** with `## Do` and `## Done when` sections — the JSON
`spec` field points at it and the loop appends its full text to the build prompt.

### Writing the spec MD (`.harness/tasks/TNNN.md`) so a fresh agent gets it right

Each task's spec is a Markdown file with two sections — `## Do` (the work, 1–3 sentences) and
`## Done when` (the task-specific acceptance bar). The building agent is a **fresh agent** with
**none** of this interview's context — the spec is the entire brief it binds to. Make it
self-contained and unambiguous, or it will confidently build the wrong thing:

- **No ambiguous referents.** Name the exact artifact/identifier; avoid bare words like "the ID",
  "the page", "the value". (A real miss: *"the ID of the workflow"* got built against the workflow
  **name** when the workflow-**run** id was meant — write "the workflow-RUN id (e.g. `wr_…`), NOT
  the workflow name".)
- **Cite concrete anchors** where you know them — `path/to/file.ts:NNN`, a component/function name,
  the exact endpoint/table — so the agent edits the right place instead of guessing.
- **For UI / behavioural tasks, require verification against the *real running* thing**, not just
  "build/tests pass": e.g. *"load `<page>` and confirm `<element>` shows `<expected>`"*. Put it in
  `## Done when` (or as a `verify` label) so a plausible-but-wrong build can't slip through green CI.
- **Self-contained.** No "as we discussed" / "like the other one" — the fresh agent can't see this
  conversation.
- **Tests stay hermetic.** If the task adds tests, `## Done when` should require they run against a
  scratch/temp resource, never the real DB / services / files (CLAUDE.md golden rule) — never
  author a task whose verification mutates production state.

**Author the objective bar — it IS the verification contract (see `designs/audit-verification.md`).**
The build is checked against what *you* (the strong author) write here, by cheap structural checks
plus a **sampled blocking audit** (a stronger model verifies the diff against `## Done when`). The
more objective and runnable the bar, the harder it is for a cheap builder to false-pass:
- Make `## Done when` items **concrete and runnable** where possible — name the command + the expected
  result (e.g. *"`npm test -- foo.test.ts` passes"*, *"`GET /api/x` returns `{ ok: true }`"*), not
  just prose.
- Set **`expectsTest: true`** when correctness should be pinned by a test, and **say in `## Done when`
  what the test must assert** — the builder writes the test, but to YOUR spec, so it can't validate
  itself with a lenient one.
- Keep **`scope` accurate** — it's now a structural gate (the diff must touch those files).

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

**Write each new task's spec file too:** for every task appended above, create
`.harness/tasks/TNNN.md` (sections `## Do` / `## Done when`) so its `spec` path resolves — a task
whose spec file is missing leaves the builder with no brief.

**Ordering matters — the loop builds in array order.** Selection walks `.tasks` in **array order**
and takes the first eligible task; `dependsOn` only *blocks*, it does **not** reorder (HARNESS
§8.1). Appending (above) puts new tasks at the **end**, which is almost always right. The case to
watch: a **destructive / rename / migration** task must run **after** everything that references the
old name/shape — so keep it at the **end** of the array (don't hand-move it earlier), and remember
that any tasks you add *later* will append *after* it, so re-check that the rename still sits last.

## 5. Validate before finishing

- `jq empty TASKS.json` passes (still valid JSON).
- Existing task count + new count == total: `jq '.tasks | length' TASKS.json` matches expectation,
  and no prior `status` changed (`jq -r '.tasks[]|select(.status=="done")|.id'` is unchanged).
- Every `dependsOn` id exists (`jq` cross-check), no dangling deps, no cycles, no duplicate ids.
- `gate` is one of `null` / `"gate"` / `"needs-human"`; no task carries `model`/`effort`/`escalation`.
- **Every task has a `spec` path AND a matching `.harness/tasks/TNNN.md` on disk** (sections `## Do` /
  `## Done when`) — no inline `do`/`doneWhen` in the JSON. (`for s in $(jq -r '.tasks[].spec' TASKS.json); do test -f "$s" || echo "missing $s"; done`)
- **Every buildable (non-needs-human) task has a `facets` object** with a `layer` + `workType` drawn
  from `facets.json`'s vocabulary, and any `risk` flags valid; needs-human/gated tasks have none.
- Print a short summary: tasks added, each with its deps + **facets** (layer/work-type), so the user
  can confirm the dependency graph and the facet classification read correctly. (Don't report a
  "chosen model" — the policy decides difficulty now.)

## 6. Hand off

Tell the user the loop will pick these up in dependency order on the next `.harness/loop.sh` /
`.harness/supervise.sh` pass — building one at a time, the policy choosing each task's starting tier
from its facets and escalating up the global ladder on repeated failure, and stopping at any `gate` /
`needs-human` task for them.

## 7. (Optional) Prune completed tasks

Over a long-lived backlog, finished tasks pile up and bury the live work. Pruning `status:"done"`
tasks is a legitimate operation **separate from the append above** — it keeps the backlog (and a
dashboard that renders it) readable. Only do it when the user asks. It is safe as long as **no
remaining task's `dependsOn` references a pruned id** — dropping a done task that a pending task
still lists as a dependency would dangle it forever.

```sh
# Drop completed tasks, but ABORT if that would leave a dangling dependsOn or invalid JSON.
jq '.tasks |= map(select(.status != "done"))' TASKS.json > TASKS.json.tmp \
  && jq -e '([.tasks[].id]) as $ids | all(.tasks[].dependsOn[]?; . as $d | $ids|index($d))' TASKS.json.tmp >/dev/null \
  && jq empty TASKS.json.tmp && mv TASKS.json.tmp TASKS.json \
  || { echo "ABORT: pruning would dangle a dependsOn (or invalid JSON) — left TASKS.json untouched"; rm -f TASKS.json.tmp; }
```

- **Keep ids monotonic.** Never renumber the survivors or reuse a pruned id — `worklog/<id>.md`
  files and git history still reference the originals. New tasks continue from the highest id ever
  used, even if it was pruned.
- **The shell owns `status`.** Prune only from a quiet loop (no `.harness/loop.sh` running), and
  commit the pruned `TASKS.json` like any backlog edit. To keep a record instead of deleting, move
  the done tasks into a `TASKS.done.json` archive rather than dropping them.
