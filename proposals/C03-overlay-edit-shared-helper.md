# C03: A shared `overlay-edit.sh` for the mark-* scripts

**Type**: consolidation · **Priority**: P2 · **Effort**: M
**Affected files**: `templates/scripts/mark-done.sh`, `mark-failed.sh`, `mark-reviewed.sh`, NEW `templates/scripts/overlay-edit.sh` (sourced lib), `rewire-dependents.sh` (lock + push reuse), MIGRATIONS/create/upgrade plumbing for the new file
**Release**: MINOR bump · MIGRATIONS entry (new mechanism file) · checksums · `bash -n`

## Problem

The three mark scripts share a ~70% common skeleton, each hand-maintained: path derivation, lock
acquisition, overlay-file initialization, jq edit + validate, staged-diff no-op check, commit,
`push_with_retry`, messaging, `--undo`. B05's safety fixes (branch check, pathspec commit) and
B02's trap fix would each need to land three times. `rewire-dependents.sh` additionally hand-rolls
its own lock probe AND its own commit+push (without rebase retry) instead of reusing
`repo-lock.sh`.

## Proposed fix

Extract a sourced `overlay-edit.sh` exposing something like:

```bash
overlay_edit <overlay-relpath> <jq-program> <commit-msg> [extra-pathspec…]
# derives ROOT/GIT_COMMON, acquires the lock (REPO_LOCK_WAIT semantics of the caller),
# refuses off-main (B05), applies the jq edit via temp+rename, jq-validates,
# no-op-exits when nothing changed, commits with pathspec, push_with_retry, releases.
```

Each mark script becomes: arg parsing + its own status-guard jq + one `overlay_edit` call (+ its
`--undo` variant as a second jq program). `rewire-dependents.sh` swaps its hand-rolled lock/push
for `repo-lock.sh`'s primitives (it edits TASKS.json, not an overlay — it may only reuse the lock
+ push + branch-guard pieces; don't force-fit it into `overlay_edit`).

Fold in B02 (traps) and B05 (branch/pathspec) here — this file is their structural home.

## Acceptance criteria

- All three mark scripts behave identically to today on the happy paths:
  `mark-done-bulk.test.sh` green unmodified (it tests through the real CLIs).
- B05's two safety cases pass (off-main refusal; staged-unrelated exclusion) — via the lib, tested
  once.
- New file plumbed: create copies+chmods, upgrade table row, MIGRATIONS new-file entry, checksums.
- `rewire-dependents.test.sh` green; its push now retries on a moved remote (add that case).

## Test plan

`mark-done-bulk.test.sh` is the regression net; add an `overlay-edit.test.sh` for the lib's own
matrix (no-op, invalid jq output → abort untouched, off-main, pathspec isolation, lock contention
with a short REPO_LOCK_MAX_WAIT).
