---
name: implementation-harness-add-to-backlog
description: >-
  Use when a project already has the implementation harness (.harness/docs/HARNESS.md, .harness/scripts/loop.sh, .harness/tracking/TASKS.json
  present) and the user wants to draft or extend the task backlog — phrases like "add tasks",
  "write the backlog", "turn this feature into tasks", "plan the next phase for the loop". Runs a
  focused interview that turns a feature description into atomic, dependency-ordered .harness/tracking/TASKS.json task
  objects following the HARNESS.md §8.1 schema (dependsOn / scope / design / verify / facets + a
  per-task `spec` Markdown file), with difficulty auto-tuned from facets, gate / needs-human markers, appended without
  disturbing existing tasks.
argument-hint: "[feature or phase to break into tasks]"
allowed-tools: Read, Write, Edit, Bash, Glob, AskUserQuestion
---

# Author / extend the .harness/tracking/TASKS.json backlog

You are turning a feature or phase description into well-formed `.harness/tracking/TASKS.json` task objects that the
single-loop harness can build. Read this whole file, then execute in order. The cardinal rule:
**append, never clobber** — existing *pending / in-flight* task objects and their `status` are
sacred. (Completed `done` tasks may be deliberately pruned to keep the backlog readable — see §7 —
but are never silently altered during an append.)

## 1. Pre-flight

- Require the harness: `.harness/tracking/TASKS.json`, `.harness/docs/HARNESS.md`, and `.harness/scripts/loop.sh` must exist in the
  project. If any is missing, stop and point the user at `implementation-harness:implementation-harness-create` first.
  (Either loop variant — worktree or in-place — installs as `.harness/scripts/loop.sh` and keeps
  `.harness/tracking/TASKS.json` at the same fixed path, so this skill is identical for both.)
- Require `jq` (the loop and this skill use it). If absent, tell the user to `brew install jq`.
- **Read `.harness/docs/HARNESS.md` §8.1** (the task schema) live — bind to the actual schema in this
  project, in case it has evolved. Don't rely on a hardcoded copy.
- **Read `.harness/tracking/TASKS.json`** and extract, with jq:
  - the highest existing id — `jq -r '.tasks[].id' .harness/tracking/TASKS.json | sort | tail -1` → new ids continue
    monotonically, zero-padded to the same width (≥3 digits);
  - all existing ids (`jq -r '.tasks[].id'`), so `dependsOn` references real tasks, never a dupe;
  - Tasks carry NO per-task model/effort/escalation; the policy auto-tunes difficulty from
    `facets` + the ledger (the cold-start floor lives in `.harness/config/harness.env`, not `.harness/tracking/TASKS.json`).
- **Read `.harness/config/facets.json`** (`jq '.facets'`) — the controlled facet vocabulary you'll assign in §2.4.

- **Poor-fit gate — has the `layer` vocabulary drifted?** If `.harness/config/facet-misfits.jsonl` exists, count its
  lines; if that count ≥ `.harness/config/facets.json`'s `.policy.poorFitThreshold` (default 5), run a **layer
  re-evaluation BEFORE authoring anything**:
  1. **Re-cluster (you do this):** read the recent backlog + `.harness/config/facet-misfits.jsonl` + the current
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

  3. **On accept — MIGRATE history (don't skip):** update `.harness/config/facets.json`'s `layer` values; remap the
     `facets.layer` in existing `.harness/ledgers/outcomes.jsonl` rows AND re-tag affected tasks' `facets` in
     `.harness/tracking/TASKS.json` to the new values (rename = substitute; split = reassign by scope; merge = union) —
     otherwise the changed calibration cells silently cold-start. Then **clear `.harness/config/facet-misfits.jsonl`**
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
   - **scope — get this right; it is one of the highest-leverage decisions in the whole authoring
     pass, not a throwaway field.** It's the files this task is *allowed* to touch, enforced as a hard
     structural gate: the first out-of-scope edit now **blocks the task on the first attempt** (no
     retry, no escalation — a wrong scope is a human fix, not something a stronger model recovers).
     **Too narrow silently dooms the task; too wide defeats the guard** that lets cheap models run
     unsupervised. So reason it through against exactly what `## Done when` requires, and **bias to a
     directory-level scope** — a directory prefix (`src/feature/**`) that honestly covers where the
     work lives beats pre-guessing every individual file (which you usually can't get right), while
     still catching the real failure mode: a build straying into an unrelated subsystem. Each entry
     must be an **exact path**, a **directory prefix** (`dir/`, `dir/**`, `dir/*` — everything under
     it), or a **single-level extension glob** (`dir/*.tsx` — any `.tsx` directly in `dir`). Do NOT
     author a mid-path recursive glob like `dir/**/*.ts` or brace expansion — those match nothing and
     fail every attempt as scope-creep (use a directory prefix or explicit paths instead).
   - **design** — does it need a fuller `.harness/docs/designs/TNNN-slug.md` plan doc? Optional; only when
     warranted (those are authored separately, interactively, at `--effort max`). Else `null`.
   - **verify** — does it need an empirical check (e.g. `["run-app"]`, `["live-api"]`)? If the
     project captured a run/backtest command at scaffold time, reuse that label. Else `[]`.
   - **do / done-when** — the work, and the task-specific acceptance bar. These go in the per-task
     Markdown spec `.harness/tasks/TNNN.md` (sections `## Do` / `## Done when`), NOT inline in the
     JSON (see §3). Do **not** restate the universal bar (format/lint/test, CI green, docs lockstep)
     in done-when — that lives once in HARNESS §5.
4. **Facets (per task) — DESCRIBE the task; the policy decides difficulty.** Difficulty (which model
   + effort to start on) is now AUTO-TUNED by the loop's policy from escalation history — you do NOT
   guess it (see `.harness/docs/designs/difficulty-autotune.md`). Your job is to *classify* the task. Read the
   project's `.harness/config/facets.json` (`jq '.facets' .harness/config/facets.json`) and assign, choosing values ONLY from that
   controlled vocabulary:
   - **`layer`** (exactly one) — WHERE the change lives. Use the task's `scope` file paths as the
     primary signal (paths → layers).
   - **`work-type`** (exactly one) — WHAT KIND of change (style / docs / bugfix / feature / migration / …).
   - **`risk`** (zero or more) — danger flags (touches-schema, full-stack, …).

   Put these in a `"facets": { "layer": "...", "workType": "...", "risk": [...] }` object on the task.
   Do **NOT** set per-task `model`/`effort`/`escalation` at all — the policy picks the starting tier
   from facets + the outcomes ledger, escalation rides the global tier ladder in `.harness/config/facets.json`, and
   the cold-start floor lives in `.harness/config/harness.env`. `facets` is the ONLY difficulty signal you author.
   `needs-human`/gated tasks need NO facets (they never run through the loop).

   **If nothing fits — record a poor-fit signal; do NOT invent a value.** Minting an ad-hoc facet
   value re-fragments the calibration. If you're genuinely confident no existing `layer` (or
   `work-type`) fits, pick the CLOSEST existing value, tag the task with it, AND append a
   context-carrying line to `.harness/config/facet-misfits.jsonl`:
   `{ "taskId": "...", "axis": "layer"|"work-type", "closest": "...", "note": "<one line: what was missing>", "ts": "<iso8601>" }`.
5. **Gates.** The loop's selection **skips any `gate: "needs-human"` task entirely** — it never
   builds it, and it blocks its dependents until a human clears it. `gate` is only ever `null`
   (buildable) or `"needs-human"`. Ask which tasks:
   - need credentials, provisioning, real money, or production access, hinge on a human **decision**
     first, or aren't **machine-verifiable** (subjective "make it nicer" UI work, taste calls) →
     `"gate": "needs-human"`. Use it liberally — a needs-human task is parked safely, not lost.
   - must have a deliverable **reviewed before dependents proceed** (an interface frozen, an approach
     validated, experimental data trusted) → keep the work `"gate": null` (buildable) and add a
     **separate `needs-human` review task** that `dependsOn` it, with the dependents depending on the
     review task. (A gate the loop would never build AND never mark done is a dead end — don't create one.)
   - otherwise `"gate": null`.
   Tip: if a task *feels* subjective but has a checkable proxy (e.g. "looks good on mobile" → an
   emulated-viewport check for overflow/truncation), prefer making it buildable with that `verify`.
   **Non-negotiable: any task whose `scope` touches `.harness/**`, or whose `facets.layer` is
   `"harness"`, MUST be `"gate": "needs-human"`** — never `null` (buildable). An unsupervised edit
   to the harness's own machinery is uniquely dangerous (it can corrupt `TASKS.json` or defeat the
   loop's own safety rails, edited by the very process it constrains). See `.harness/CLAUDE.md`.

   **Convention-defining / cross-cutting tasks need a scope that matches their blast radius — or a gate.**
   A task that turns on or reconfigures a WHOLE-REPO tool — the initial scaffold, a formatter / linter /
   `tsconfig` / CI change, anything whose `format` / `lint` / `test` command sweeps the entire tree — must,
   to make that check pass, touch files ACROSS the repo, not just a tight per-file `scope`. Handing it a
   narrow scope is a predictable scope-gate collision (the tool rewrites/loads files outside `scope` →
   structural creep → discarded build → wasted escalation). Author such a task with EITHER a `scope` that
   honestly covers its blast radius (the config files + every dir the tool rewrites) OR `gate: "needs-human"`
   when it is the foundation-setting bootstrap itself (this is why the scaffold task T001 is needs-human).
   And whatever sets the tool up MUST exclude the vendored `.harness/**` and the harness-authored root prose
   (`CLAUDE.md` / `README.md`) from it — see the repo `CLAUDE.md` Tooling notes.

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
  "gate": null,                       // null | "needs-human"
  "tags": ["<type>"],                 // optional, DESCRIPTIVE (feature area) — NOT the calibration key
  "facets": { "layer": "...", "workType": "...", "risk": [] },  // §2.4 — the ONLY difficulty signal; OMIT for needs-human/gated tasks
  "scope": ["<files/globs>"],
  "design": null,                     // or ".harness/docs/designs/TNNN-slug.md"
  "verify": [],                       // or ["run-app"]
  "expectsTest": false,               // true → the loop requires a test file in the diff (structural gate); set for test-pinnable tasks
  "visualVerify": false,              // OPTIONAL — true forces the VISUAL_VERIFY_HOOK "actually LOOK at it" check; false suppresses; OMIT to use the facets heuristic (see §3). Usually omitted.
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

Each task's spec is a Markdown file with three sections — a leading **`## Overview`** (one or two
plain-language sentences: *what* this task is doing and *why*, the "at a glance" line read FIRST),
then `## Do` (the work, 1–3 sentences) and `## Done when` (the task-specific acceptance bar). (The
Overview is a later convention — pre-existing specs without one are fine, don't backfill.) The building
agent is a **fresh agent** with **none** of this interview's context — the spec is the entire brief it
binds to. Make it self-contained and unambiguous, or it will confidently build the wrong thing:

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
- **Visual verification (`visualVerify`) — decide it from the task's facets:**
  - `layer: frontend` (unless `workType` is docs/config/logging), or `workType: style`/`component` →
    **auto-covered** by the loop; leave `visualVerify` unset (setting it is harmless but redundant).
  - `workType: bugfix`/`feature`/`migration` on a **non-frontend** layer → this is the "might touch the
    UI" tier: **ask the owner** whether the change alters something visual a human should eyeball (a
    backend migration changing an API the UI reads, a bugfix that fixes a rendering issue, a feature
    that adds UI). If yes, set **`"visualVerify": true`**.
  - clearly non-visual work → leave it unset. `"visualVerify": false` hard-suppresses even an
    auto-covered task. (All of this is a no-op if the project set no `VISUAL_VERIFY_HOOK`.)
- Keep **`scope` accurate and directory-level where you can** — it's a hard structural gate; the first
  out-of-scope edit blocks the task on its first attempt (no retry/escalation). See §3's scope bullet and
  HARNESS.md §8.1.

## 4. Append, don't clobber — via jq

Append the new objects so existing tasks and their `status` are untouched. Build the new objects as
a JSON array in a temp file `new-tasks.json`, then:

```sh
jq --slurpfile add new-tasks.json '.tasks += $add[0]' .harness/tracking/TASKS.json > .harness/tracking/TASKS.json.tmp \
  && jq empty .harness/tracking/TASKS.json.tmp \
  && mv .harness/tracking/TASKS.json.tmp .harness/tracking/TASKS.json
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

- `jq empty .harness/tracking/TASKS.json` passes (still valid JSON).
- Existing task count + new count == total: `jq '.tasks | length' .harness/tracking/TASKS.json` matches expectation,
  and no prior `status` changed (`jq -r '.tasks[]|select(.status=="done")|.id'` is unchanged).
- Every `dependsOn` id exists (`jq` cross-check), no dangling deps, no cycles, no duplicate ids.
- `gate` is one of `null` / `"needs-human"`; no task carries `model`/`effort`/`escalation`.
- **Every task has a `spec` path AND a matching `.harness/tasks/TNNN.md` on disk** (sections `## Do` /
  `## Done when`) — no inline `do`/`doneWhen` in the JSON. (`for s in $(jq -r '.tasks[].spec' .harness/tracking/TASKS.json); do test -f "$s" || echo "missing $s"; done`)
- **Every buildable (non-needs-human) task has a `facets` object** with a `layer` + `workType` drawn
  from `.harness/config/facets.json`'s vocabulary, and any `risk` flags valid; needs-human/gated tasks have none.
- Print a short summary: tasks added, each with its deps + **facets** (layer/work-type), so the user
  can confirm the dependency graph and the facet classification read correctly. (Don't report a
  "chosen model" — the policy decides difficulty now.)

## 6. Hand off

Tell the user the loop will pick these up in dependency order on the next `.harness/scripts/loop.sh` /
`.harness/scripts/supervise.sh` pass — building one at a time, the policy choosing each task's starting tier
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
jq '.tasks |= map(select(.status != "done"))' .harness/tracking/TASKS.json > .harness/tracking/TASKS.json.tmp \
  && jq -e '([.tasks[].id]) as $ids | all(.tasks[].dependsOn[]?; . as $d | $ids|index($d))' .harness/tracking/TASKS.json.tmp >/dev/null \
  && jq empty .harness/tracking/TASKS.json.tmp && mv .harness/tracking/TASKS.json.tmp .harness/tracking/TASKS.json \
  || { echo "ABORT: pruning would dangle a dependsOn (or invalid JSON) — left .harness/tracking/TASKS.json untouched"; rm -f .harness/tracking/TASKS.json.tmp; }
```

- **Keep ids monotonic.** Never renumber the survivors or reuse a pruned id — `.harness/worklog/<id>.md`
  files and git history still reference the originals. New tasks continue from the highest id ever
  used, even if it was pruned.
- **The shell owns `status`.** Prune only from a quiet loop (no `.harness/scripts/loop.sh` running), and
  commit the pruned `.harness/tracking/TASKS.json` like any backlog edit. To keep a record instead of deleting, move
  the done tasks into a `TASKS.done.json` archive rather than dropping them.
