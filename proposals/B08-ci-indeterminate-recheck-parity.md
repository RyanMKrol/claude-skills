# B08: CI-indeterminate single re-check exists only in the worktree variant

**Type**: bug (parity drift) · **Priority**: P2 · **Effort**: S
**Affected files**: `templates/scripts/loop.in-place.sh` (done path, CI verdict handling)
**Release**: PATCH bump · MIGRATIONS entry (mechanism, in-place variant) · checksums

## Problem

When `wait_ci_green` returns "indeterminate" (rc 2: no conclusive run — cancelled, skipped, or no
run found within the window), the worktree variant re-checks ONCE before charging the tier a soft
failure. The in-place variant goes straight to `record_failure "ci-indeterminate"; bump`.

Consequence on in-place installs: a merely SLOW or concurrency-cancelled CI run costs the tier a
soft failure — polluting the calibration ledger (the cell looks less capable than it is) and
potentially walking a healthy task up the ladder for infrastructure noise. This is exactly the
"edited one variant, forgot the other" class the parity rule exists for; these code regions are
not in the byte-parity manifest because the surrounding done paths legitimately differ, so it must
be fixed by hand-mirroring the LOGIC.

## Proposed fix

Port the worktree variant's single re-check into the in-place done path: on rc 2, wait
`WAIT_SECONDS`, call `wait_ci_green` once more, and only on a second indeterminate/red charge the
failure. Match the worktree variant's log wording so operators see the same story on both.

## Acceptance criteria

- In-place: first indeterminate → one retry; second indeterminate → failure recorded (kind
  `ci-indeterminate`), same as today.
- Log lines match the worktree variant's phrasing for the re-check.
- Worktree variant untouched.

## Test plan

Behavioral coverage arrives with T01 (fake `gh` returning indeterminate-then-green → task
integrates with zero failures recorded). Until then: a focused grep-shape assertion is acceptable
given the smallness, or fold this into T01's scenario matrix and land them together.
