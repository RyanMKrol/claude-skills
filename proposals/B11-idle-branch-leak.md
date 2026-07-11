# B11: The worktree idle path leaks the tNNN branch

**Type**: bug · **Priority**: P2 · **Effort**: S
**Affected files**: `templates/scripts/loop.sh` (the `idle` verdict handler in the main dispatch)
**Release**: PATCH bump · MIGRATIONS entry (mechanism, worktree variant) · checksums

## Problem

The worktree main-loop `idle` handler (reconcile status → continue, or block on the second
consecutive idle) never calls `cleanup_task`, so the local `tNNN` branch created by `prepare_wt`
persists — and if the builder pushed the branch before concluding idle, the REMOTE branch leaks
too. `postflight.sh`'s `inprogress()` then reports "🔨 In flight: branch tNNN" forever, making the
status board lie.

## Proposed fix

In both idle sub-paths (reconcile-and-continue AND the consecutive-idle `block_task` path), run
the same teardown the other terminal paths use — `cleanup_task "$branch"` (worktree removal +
local branch delete + remote branch delete if pushed + prune). Verify ordering: teardown AFTER the
status/ledger writes those paths perform, mirroring the done path.

## Acceptance criteria

- An idle verdict leaves no `tNNN` local branch, no remote branch, no worktree.
- `postflight.sh` shows nothing in flight after an idle.
- The idle-reconcile semantics (1.65.0) are unchanged — `idle-reconcile.test.sh` stays green.

## Test plan

T01 (fake-claude) scenario: builder returns `idle` → assert `git branch` empty of `t[0-9]+` and
worktree gone. Before T01: extend `idle-reconcile.test.sh`'s static assertions to require a
`cleanup_task` call within the idle handler block (grep-shape with a loud comment).
