# .harness/CLAUDE.md — rules for working *inside* the build harness

Loaded whenever Claude works with files in `.harness/` — notably when adding or editing backlog
tasks in `TASKS.json`. It keeps the harness's own authoring rules *with* the harness, so they travel
with it and surface at the authoring moment. (Repo-wide conventions are in the root `CLAUDE.md`; the
loop's design is in `HARNESS.md` + `designs/`.)

## Adding a backlog task → invoke the add-to-backlog skill

To add a task to the backlog, invoke the **`ralph-loop-add-to-backlog`** skill. It is the **single
source of authoring logic**: it assigns the task's **facets** (difficulty auto-tuning), pairs every
chooser task with a review task, runs the **poor-fit / layer-evolution gate**, and writes a
schema-correct task object + its `tasks/TNNN.md` spec. Prefer it over hand-editing `TASKS.json`.

## The floor (holds even on a direct edit)

If the skill isn't available and you edit `TASKS.json` directly, the non-negotiable invariant is:
**every BUILDABLE task MUST carry `facets: { layer, workType, risk[] }`**, with values chosen ONLY
from `facets.json`'s controlled vocabulary (use the task's `scope` paths to pick the `layer`).
`needs-human` (gated) tasks are **carved out** — they get NO facets. A buildable task missing facets
gets no auto-tuning and the loop **pre-flight WARNs** about it. Background:
`designs/difficulty-autotune.md`.
