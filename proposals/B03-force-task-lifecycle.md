# B03: FORCE_TASK bypasses terminal-status checks and is never cleared

**Type**: bug · **Priority**: P1 · **Effort**: S
**Affected files**: `templates/scripts/loop.sh` (`select_task`, main loop), `loop.in-place.sh` (same)
**Release**: PATCH/MINOR bump · MIGRATIONS entry (mechanism, both variants) · checksums · parity (select_task differs by variant — mirror the logic, not the bytes)

## Problem

`loop.sh [TNNN]` sets `FORCE_TASK`. The forced path in `select_task` validates only that the id
EXISTS in TASKS.json (the DESIGN §9 safety guard), then echoes it unconditionally — it skips
`task_done` / `task_failed` / `task_gated` / `task_blocked`. And nothing ever clears `FORCE_TASK`,
so every subsequent iteration of the same run re-selects the same task.

**Failure scenarios**:
1. `loop.sh T014`; T014 builds and integrates (status=done). Next iteration selects T014 again →
   cold rebuild → builder finds Done-when already met → `idle` (count 1) → next iteration idle
   again (count 2) → **`block_task` flips the successfully-done T014 to `status:"blocked"`** with a
   blocked outcome row. A forced run ends by vandalizing its own success.
2. Alternate path: the builder re-does the work → empty-diff/scope failures → escalates up the
   whole ladder burning paid attempts.
3. Forcing a `needs-human` or owner-`failed` task builds it, violating "the loop never selects it".

## Proposed fix

1. In the forced path of `select_task` (both variants), after the existence check, apply the same
   terminal-status skips as the normal path; if the forced task is done/failed/gated/blocked, log
   WHY and return 1 (nothing eligible) rather than building it.
2. In the main loop, treat `FORCE_TASK` as **one-shot**: after the forced task reaches ANY
   terminal outcome for this run (integrated, blocked, or refused), clear `FORCE_TASK` so the run
   either proceeds through the normal backlog or (probably better, and simpler) **exits cleanly
   after the forced task completes** — a human forcing one task usually wants exactly that task.
   Decide with the owner which; default recommendation: exit 0 after the forced task's outcome,
   with a clear log line ("forced run complete — exiting; run supervise.sh for the full backlog").
3. Keep DRY_RUN behavior aligned: `DRY_RUN=1 loop.sh <done-task>` should print the refusal, not
   "would build".

## Acceptance criteria

- Forcing a done/failed/gated/blocked id → loud refusal naming the status; exit without building.
- Forcing a pending id → builds it once; after its terminal outcome the run does not re-select it.
- The existing bogus-id refusal is unchanged.
- `templates/scripts/select-task.test.sh` extended: force-a-done-task and force-a-gated-task cases
  (assert refusal text), plus keep the existing cases green.

## Notes

The evaluation deliberately did NOT pin the current buggy behavior in select-task.test.sh (it only
tests forcing an eligible task) so this fix won't fight the suite.
