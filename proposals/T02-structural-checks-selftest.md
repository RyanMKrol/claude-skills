# T02: A `--struct-selftest` entry point for structural_checks

**Type**: testing · **Priority**: P2 · **Effort**: M
**Affected files**: `templates/scripts/loop.sh` + `loop.in-place.sh` (new dispatch flag — mirror the four existing `--*-selftest` flags), NEW `templates/scripts/structural-checks.test.sh`
**Release**: PATCH/MINOR bump · MIGRATIONS entry (mechanism, both variants + new test) · checksums · parity (the selftest function should be manifest-eligible if written variant-neutral)

## Problem

`structural_checks` — the scope contract's enforcement point — is untested as a COMPOSITION even
though its primitive (`scope_match`) is well covered. Untested branches: empty-diff fail; scope-
creep aggregation (multiple files, correct STRUCT_FAIL_DETAIL); the lockfile exemption (added
after a real incident); test-files-always-allowed; `expectsTest:true` without a test-file change →
`test-missing`; `SCOPE_EXEMPT_GLOBS` honored; failing `LOCAL_DOD` (in-place) → `local-dod` with
output tail captured; `STRUCT_FAIL_KIND` attribution for each.

## Design

Follow the proven selftest pattern (`--rl-selftest` is the template — it made the RL family
testable): a `--struct-selftest` dispatch that builds a tiny throwaway repo internally (or takes a
prepared fixture dir), constructs named diff scenarios, runs the REAL `structural_checks` against
each, and prints `kind=<STRUCT_FAIL_KIND>` / `ok` lines the test asserts on. Scenario list =
exactly the branch list above, one per line. The wrapping `structural-checks.test.sh` runs it for
whichever variants are present (copy select-task.test.sh's dispatch-by-header loop).

## Acceptance criteria

- Every branch above exercised with the REAL function via the real script boot path; each failure
  scenario asserts the exact `STRUCT_FAIL_KIND`.
- Both variants; suite <10s; bash 3.2 clean.
- The existing selftests still pass (`--guard/--scope/--scope-exempt/--rl`) — the dispatch chain
  in the FORCE_TASK arg-filter line must gain the new flag (that line lists selftest flags
  explicitly; miss it and the flag becomes a bogus FORCE_TASK — the guard will refuse it, which is
  the failure mode to test for once).

## Notes

D01 (`[skip ci]` authorization) and D02 (three-dot diffs) both want scenarios here — if they land
together, add their cases in the same matrix.
