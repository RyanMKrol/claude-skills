# F03: `prioritize.sh` — a supported way to say "build this next"

**Type**: feature · **Priority**: P2 · **Effort**: S
**Affected files**: NEW `templates/scripts/prioritize.sh`, MIGRATIONS/create/upgrade plumbing, `templates/docs/HARNESS.md` §8.1 (array-order note gains the pointer)
**Release**: MINOR bump · MIGRATIONS entry (new mechanism file) · checksums · `bash -n`

## Problem

Task selection is pure array order in TASKS.json ("array position itself decides" — HARNESS.md
§8.1), and add-to-backlog explicitly warns against hand-moving entries. So "build T090 next" has
no supported path except the undocumented one-shot `FORCE_TASK` arg. Owners either hand-edit JSON
(warned against) or wait.

## Design

A small CLI in the mark-* family: `prioritize.sh TNNN [--after TMMM]`.

- Guards: loop not running (lock free — `REPO_LOCK_WAIT=0` acquire like the loop, i.e. skip if
  held, with a clear message), task exists, task is pending + not gated, and — the important
  validation — **the move cannot place a task before its own dependencies**: after computing the
  new array, assert every task's `dependsOn` entries appear earlier or are done; refuse otherwise
  with the violating edge named.
- Default move: to the FRONT of the eligible region (position 0 of the not-done prefix… simplest
  correct: move to the very front of the array — done tasks earlier in the array are skipped by
  selection anyway, so front-of-array is sufficient and simple). `--after TMMM` for finer control.
- Edit via jq to a temp file + `jq empty` validate + rename; commit + `push_with_retry` with a
  `[skip ci]` message, exactly like the mark scripts (reuse `overlay-edit.sh`'s guards if C03 has
  landed — this edits TASKS.json, not an overlay, so reuse the branch/lock/push pieces).

## Acceptance criteria

- `prioritize.sh T090` on a valid pending task → T090 is the next `DRY_RUN=1 loop.sh` selection.
- Moving a task ahead of its unmet dependency → refusal naming the dependency.
- Gated/done/failed/blocked targets → refusal naming the status.
- Loop running (lock held) → refusal, nothing written.
- Committed + pushed atomically; TASKS.json still valid JSON.

## Test plan

`prioritize.test.sh` cloning `mark-done-bulk.test.sh`'s scaffold: the five cases above, plus
DRY_RUN cross-check with the real loop (reuse select-task.test.sh's `setup_repo`).
