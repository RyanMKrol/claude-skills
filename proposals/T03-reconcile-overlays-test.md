# T03: Test `reconcile_overlays` — three parallel implementations, only one tested

**Type**: testing · **Priority**: P2 · **Effort**: S
**Affected files**: `templates/scripts/loop.sh` + `loop.in-place.sh` (possibly a new `--reconcile-selftest` flag), NEW `templates/scripts/reconcile-overlays.test.sh`
**Release**: PATCH bump · MIGRATIONS entry · checksums

## Problem

The overlay promotion rules — `human-done.json` promotes ONLY `gate:"needs-human"` tasks to done;
`manual-fail.json` flips any non-failed task to failed — exist in THREE implementations: both
loop variants' `reconcile_overlays` (shell) and `dashboard/lib.js` (JS mirror). Only the lib.js
copy is tested. The shell copies are the authoritative ones (they write TASKS.json and push);
mirror drift here means the dashboard shows one truth and the loop enacts another.

## Design

Preferred: a `--reconcile-selftest` dispatch flag (the established pattern) that runs the real
function against an internally-constructed fixture repo. The scenarios:

1. human-done entry for a `gate:"needs-human"` pending task → status flips to done.
2. human-done entry for an ORDINARY pending task → no change (the guard case).
3. manual-fail entry for a done task → flips to failed.
4. manual-fail entry for an already-failed task → no-op, no commit churn.
5. No applicable overlay entries → NO commit at all (idempotence — guards against the
   formatting-churn issue noted in the evaluation: worktree's `jq '.'` rewrite vs the mjs's
   `JSON.stringify(…,2)` — assert byte-stability on the no-op path).
6. Result is pushed (worktree: to origin/main; in-place: committed locally per its model) — assert
   per variant.

Cross-check the same fixtures against `lib.js`'s reducer in `lib.test.js` (add the fixtures there
too) so the three implementations are pinned to ONE behavior table.

## Acceptance criteria

- All six scenarios green for both variants via the real function; lib.test.js shares the fixture
  table (copy the JSON literally into both tests with a comment linking them).
- No-op runs produce zero commits (assert rev-count unchanged).
