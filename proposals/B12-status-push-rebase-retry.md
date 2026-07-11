# B12: The loop's own status-flip pushes never rebase-and-retry

**Type**: bug · **Priority**: P2 · **Effort**: S
**Affected files**: `templates/scripts/loop.sh` (`record_outcome`'s push), `loop.in-place.sh` (`mark_done`/status push)
**Release**: PATCH bump · MIGRATIONS entry (mechanism, both variants) · checksums

## Problem

The persist-or-shout blocks retry a **plain `git push`** twice with a 1s sleep. If `origin/main`
moved between the loop's fetch and its push (owner pushed a commit, a mark-script ran from
another machine), both attempts fail identically (non-fast-forward) → the loud "status=done … did
NOT persist" error fires and the board diverges — the documented idle-stall precondition (the
1.65.0 incident class). Meanwhile `push_with_retry` (fetch + rebase + push, in `repo-lock.sh`) is
already sourced by both loops and unused on these paths.

## Proposed fix

- **In-place** (`mark_done` and any sibling status push): straightforward — replace the manual
  retry with `push_with_retry` semantics (it operates on the current checkout; the loop holds the
  lock so no self-contention — verify lock reentrancy: `push_with_retry` itself must NOT try to
  take the lock the caller already holds).
- **Worktree** (`record_outcome` commits via a detached worktree): a rebase isn't directly
  applicable to the detached-worktree commit. On push rejection: re-fetch, rebuild the detached
  worktree from the NEW `origin/main`, re-apply the status flip + ledger row (the inputs are all
  still in variables), commit, push again — bounded at 2-3 rounds, then the existing loud error.
  Factor as a small retry wrapper around the existing commit-building block rather than new
  machinery.

## Acceptance criteria

- With `origin/main` advanced by one unrelated commit between build and status flip: the flip
  lands on the first retry round; no "did NOT persist" error; ledger row present exactly once.
- Genuine persistent rejection (e.g. pre-receive hook denying) still produces the loud error after
  the bounded retries — the persist-or-shout contract is preserved.
- Both variants; `mark-done-bulk.test.sh` (which covers push_with_retry via the CLIs) stays green.

## Test plan

Hermetic (pattern from `mark-done-bulk.test.sh`): bare remote; after the fixture's setup, advance
the remote from a second clone; then drive the status-flip path. Reaching `record_outcome` outside
a real run needs T01 — before T01, cover the in-place `mark_done` path via a focused extraction
test or land together with T01's persist-or-shout scenario (its test #8 in the evaluation's test
plan covers exactly this).
