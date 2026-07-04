# .harness/CLAUDE.md — rules for working *inside* the build harness

Loaded whenever Claude works with files in `.harness/` — notably when adding or editing backlog
tasks in `TASKS.json`. It keeps the harness's own authoring rules *with* the harness, so they travel
with it and surface at the authoring moment. (Repo-wide conventions are in the root `CLAUDE.md`; the
loop's design is in `docs/HARNESS.md` + `docs/designs/`.)

## Adding a backlog task → invoke the add-to-backlog skill

To add a task to the backlog, invoke the **`implementation-harness-add-to-backlog`** skill. It is the **single
source of authoring logic**: it assigns the task's **facets** (difficulty auto-tuning), pairs every
chooser task with a review task, runs the **poor-fit / layer-evolution gate**, and writes a
schema-correct task object + its `tasks/TNNN.md` spec. Prefer it over hand-editing `TASKS.json`.

## The floor (holds even on a direct edit)

If the skill isn't available and you edit `TASKS.json` directly, the non-negotiable invariant is:
**every BUILDABLE task MUST carry `facets: { layer, workType, risk[] }`**, with values chosen ONLY
from `config/facets.json`'s controlled vocabulary (use the task's `scope` paths to pick the `layer`).
`needs-human` (gated) tasks are **carved out** — they get NO facets. A buildable task missing facets
gets no auto-tuning and the loop **pre-flight WARNs** about it. Background:
`docs/designs/difficulty-autotune.md`.

## A task touching `.harness/**` MUST be `gate: "needs-human"` — never buildable

Any backlog task whose `scope` array includes a path prefixed `.harness/`, OR whose
`facets.layer == "harness"`, **MUST** be authored `gate: "needs-human"`. Never `gate: null`
(buildable) or `gate: "gate"` (still built unsupervised, only reviewed after the fact). This
applies regardless of how the task is authored — the add-to-backlog skill, the ideas-conversion
pipeline, or a direct hand-edit of `TASKS.json`.

**Why:** the harness's own build/task-selection/calibration machinery is what constrains every
OTHER task the loop builds. A bad *unsupervised* edit here is uniquely dangerous compared to an
ordinary buildable task going wrong — it can corrupt `TASKS.json`, break task selection or
escalation, or silently defeat the loop's own safety rails, edited by the very process it
constrains, with no human in the loop. A human must look at a diff to `.harness/**` before it's
built, not just before it's merged.

Enforced two ways: documented here (loads whenever Claude works inside `.harness/`), and a
non-fatal pre-flight WARN in the loop (mirrors the missing-facets WARN) that names any currently
buildable task touching `.harness/` without the required gate — it does not stop the loop or
change selection, it's a backlog-hygiene signal.

## Marking a task done / failed / reviewed → use the mark-*.sh scripts

Never hand-edit `TASKS.json`'s `status` field directly — the loop is its sole writer.
`scripts/mark-done.sh TNNN` marks a `needs-human` task done; `scripts/mark-failed.sh TNNN "<reason>"`
overturns a `done` task the loop/audit got wrong; `scripts/mark-reviewed.sh TNNN` sets the cosmetic
reviewed flag. Each writes one `tracking/*.json` overlay file, which `reconcile_overlays()` promotes
into `TASKS.json` status on the loop's next iteration. Background: `docs/designs/manual-fail-signal.md`.

## Known-but-deferred issues (log real incidents here, dated)

A running, dated log of real problems hit while operating THIS harness — not aspirational design
notes, actual incidents with a root cause and a fix. This is institutional memory: the next person
(human or agent) debugging a strange loop failure should check here before re-deriving the cause
from scratch. Add an entry whenever you diagnose a genuine harness-mechanism bug (not a one-off
project bug), in this shape:

```
### YYYY-MM-DD — <one-line symptom>
**Root cause:** <what was actually wrong, and why it wasn't obvious>
**Fix:** <what changed, with a file/function pointer>
**Verification:** <how you confirmed the fix actually works>
```

Keep entries even after the fix ships — they're the record of *why* the current behavior exists,
which saves the next debugging session from re-discovering the same failure mode. (No entries yet
in a freshly-scaffolded project — this section is the template for adding them.)
