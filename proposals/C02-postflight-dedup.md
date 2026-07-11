# C02: Dedupe the postflight pair

**Type**: consolidation · **Priority**: P3 · **Effort**: M
**Affected files**: `templates/scripts/postflight.sh`, `postflight.in-place.sh`, upgrade skill (it selects `POSTFLIGHT_SRC` by variant today)
**Release**: MINOR bump · MIGRATIONS entry (mechanism; possibly a removal if merged to one file) · checksums

## Problem

The two postflight variants are ~85% identical — the entire board-building/rendering half is
byte-identical; only the data accessors differ (worktree reads `origin/main` blobs + the tNNN
build branch; in-place reads the LOCAL checkout + a dirty-tree check) plus `inprogress()`.
Same hand-mirroring liability as the loops, smaller blast radius.

## Proposed fix (pick one)

- **Option A (one file)**: a single `postflight.sh` that detects the variant at runtime by reading
  `# harness-loop-variant:` from the sibling `loop.sh`, and switches its data layer accordingly.
  Simplifies `create`/`upgrade` (no `POSTFLIGHT_SRC` selection — remove that branch from the
  upgrade skill's stage-1 snippet and `create`'s copy step; ledger records the removal of
  `postflight.in-place.sh`).
- **Option B (shared lib)**: extract the rendering half into `postflight-lib.sh`, keep two thin
  data-layer scripts. Less upgrade-skill churn, one more file.

Recommendation: A — postflight is read-only/zero-risk, runtime variant detection is one grep, and
deleting a whole variant file is the bigger simplification.

## Acceptance criteria

- Board output byte-comparable to today for both variants on the same fixture repo (golden-diff
  the output before/after on a scratch harness of each variant).
- `create` + `upgrade` updated in the same commit (no `POSTFLIGHT_SRC` dangling); MIGRATIONS
  records the rename/removal so upgrades clean up the old file.
- `board()` in the loops (which shells to postflight) unaffected.

## Test plan

A `postflight.test.sh`: hermetic repo per variant (reuse select-task.test.sh's `setup_repo`),
run postflight, assert the section headers + a known task appears in the right bucket; run under
both bash 3.2 and 5.
