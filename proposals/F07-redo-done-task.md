# F07: Redo-done-task — an authoring front-end for the manual-fail signal

**Type**: feature · **Priority**: P2 · **Effort**: M
**Affected files**: NEW project-local skill (e.g. `harness-redo-task`) or a documented mode of review-failed; registration plumbing (create/upgrade/READMEs, per the 1.70.0 checklist)
**Release**: MINOR bump · MIGRATIONS entry · checksums

## Problem

The harness handles FAILED work beautifully (review-failed: root cause → better follow-up →
rewire) — but "this DONE task isn't actually right / needs another pass" has no front-end. The
manual-fail mechanism exists (mark-failed.sh writes the overlay; calibration subtracts the false
success; docs/designs/manual-fail-signal.md) but the owner must run the CLI by hand, then wait for
the next review-failed sweep, and the follow-up task is authored from scratch — losing the
original spec/scope as the starting point.

## Design

A small interactive skill: `/…-redo-task TNNN <what's wrong>` (planning-stage — human present, so
it MUST bias toward asking, per the plugin CLAUDE.md principle):

1. Validate TNNN is `done`; show its spec + final tier + audit status (was the success audited or
   ci-only? — sets expectations about what went wrong).
2. Interview: what's wrong, and is the original DoD bar itself wrong or was it just not met?
   **Always confirm the corrected definition of done** (the mandatory planning-stage check).
3. Author the follow-up: clone the original spec/scope as the draft, fold in the correction,
   route through the SAME pending-tasks + `consolidate-ideas.sh` machinery review-failed uses
   (real id allocation, spec file, dependsOn the original where sensible).
4. Close out: run `mark-failed.sh TNNN "<reason>"` (the overlay flip that corrects calibration) —
   AFTER the follow-up is consolidated, so the board never shows a hole without its replacement.
5. Report: original overturned, follow-up id, what changed in the spec.

## Acceptance criteria

- End state after a run: original task `status:"failed"` via the overlay (manual-fail recorded),
  follow-up task pending with a spec that demonstrably differs (the correction is in `## Done
  when`), one consolidation commit + one overlay commit, both pushed.
- Refuses non-done targets (point at review-failed for failed/blocked ones).
- The interview asks — it never silently invents the corrected DoD.
- Registered everywhere per the checklist; named `harness-redo-task` per the N01 convention (landed in 1.94.0).

## Notes

Decide with the owner: standalone skill (discoverable) vs a mode of review-failed (less surface).
Recommendation: standalone — review-failed is a sweep over MANY tasks; this is a targeted
single-task flow with a different entry state (done, not failed).
