# T05: Round out the mutation-CLI tests — consolidate-ideas and mark-failed

**Type**: testing · **Priority**: P3 · **Effort**: S
**Affected files**: NEW `templates/scripts/consolidate-ideas.test.sh`, NEW `templates/scripts/mark-failed.test.sh` (clone the existing scaffolds)
**Release**: PATCH bump · MIGRATIONS entry (mechanism tests) · checksums

## Problem

`consolidate-ideas.mjs` is the single writer of new backlog STRUCTURE (id allocation, spec files,
dependency wiring) and only its rewire path is tested (`consolidate-rewire.test.sh`). Its wrapper
`consolidate-ideas.sh` (lock-wait, invalid-JSON abort that must PRESERVE pending files,
delete-only-after-push) is untested. `mark-failed.sh` is the only untested mark-* sibling.

## Scenarios

**consolidate-ideas** (clone consolidate-rewire.test.sh's scaffold):
1. Sequential id allocation across MULTIPLE pending files (deterministic file-name order — two
   files each adding tasks; assert ids don't collide and order is stable).
2. tempId cross-file resolution (file A's task depends on file B's tempId).
3. Dangling dependency → dropped WITH the warning (assert the warning text + the dep removed, task
   kept).
4. Spec files written to `.harness/tasks/TNNN.md` with the drafted content.
5. Converted `ideaIds` rows removed from `tracking/IDEAS.jsonl`; unconverted rows untouched.
6. Wrapper: mjs producing invalid JSON (inject via a corrupted pending file) → abort, pending
   files STILL PRESENT, nothing committed.
7. Wrapper: happy path deletes pending files only AFTER the push succeeds (bare-remote assert).
8. (After B13) the whole suite under a path containing a space.

**mark-failed** (clone mark-done-bulk.test.sh):
1. Rejects a pending task ("not currently done or blocked").
2. Requires a reason; multi-word unquoted trailing reason survives intact into the overlay.
3. Happy path on a done task → overlay row, one commit, pushed.
4. `--undo` removes the row.

## Acceptance criteria

- All hermetic (mktemp repos + bare remotes), <15s total, bash 3.2 clean, no reliance on repo
  state. Node required only where the mjs runs (CI has it).
