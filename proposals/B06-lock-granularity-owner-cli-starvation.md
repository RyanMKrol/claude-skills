# B06: Owner CLIs starve for the whole run — the loop holds the lock per-RUN, waiters wait forever

## ⚠️ Status — ABANDONED (2026-07-15), owner's call after a real blocker surfaced mid-implementation

A+C were implemented (new `acquire_run_lock`/`release_run_lock` + reentrant `loop_lock_acquire`/
`loop_lock_release` in `repo-lock.sh`; every git-mutating function in both loop variants rewrapped
to hold the lock only around its own git-mutating span, not the whole run; `throttled_push`'s cooldown
sleep deliberately kept OUTSIDE the lock). Full test suite was green (including `loop-parity.test.sh`
and a new reentrancy selftest) before Option C (mark-*.sh bypasses the lock entirely) surfaced a real
safety gap:

**The in-place variant's `cold_reset` (`git reset --hard` + `git clean -fd`) runs in the SAME working
tree `mark-done.sh`/`mark-failed.sh`/`mark-reviewed.sh` commit into** (unlike the worktree variant,
where the loop never touches the primary checkout directly except one already-guarded exception). If
an owner script has staged-but-not-yet-committed its overlay edit at the exact moment `cold_reset`
fires, the hard reset silently discards it — no error, the owner's action just vanishes. Today this
can't happen (the lock fully serializes the two for the whole run); Option A alone keeps them safely
serialized in brief bursts; it's specifically Option C's "skip the lock entirely" that reopens this
window, and only for in-place installs. The proposal's own Option C framing ("keep the lock for
consolidate/rewire which touch TASKS.json") didn't anticipate this — the real dividing line isn't
"touches TASKS.json vs. a separate overlay file," it's "does the LOOP ever touch the primary checkout's
own working tree" (true always for in-place, only in one guarded spot for worktree).

Offered three ways to close the gap (worktree-only bypass / accept the narrow in-place race / a
bounded-wait middle ground for in-place) — owner chose to abandon the whole proposal rather than pick
one. All implementation work was reverted (uncommitted at abandonment time, so a clean `git checkout --`
sufficed — nothing shipped). If picked back up later, start from this finding rather than re-deriving
it, and resolve the in-place safety question BEFORE touching Option C.

**Type**: bug · **Priority**: P1 · **Effort**: M (has a real design decision)
**Affected files**: `templates/scripts/repo-lock.sh`, `loop.sh`, `loop.in-place.sh`, the `mark-*.sh`/`consolidate-ideas.sh` callers, `dashboard/server.js` (button UX)
**Release**: MINOR bump · MIGRATIONS entry (mechanism, both variants) · checksums · parity

## Problem

The loop acquires the repo lock once before iteration 1 and holds it until process exit — a
multi-hour hold. The owner CLIs (`mark-done.sh` etc.) set `REPO_LOCK_WAIT=1` and poll `sleep 2`;
`REPO_LOCK_MAX_WAIT` has **no default**, so they poll forever. Consequences:

- The documented promise "an owner action taken mid-run takes effect on the loop's next iteration"
  (comments in `loop.in-place.sh` around `reconcile_overlays`) is unreachable — the overlay can't
  even be WRITTEN until the run ends.
- Dashboard buttons (which shell to the mark scripts) hang indefinitely with no feedback.
- `repo-lock.sh`'s header assumption ("they'd rather wait a few seconds for the loop") described a
  per-operation lock, not a per-run one — the code drifted from its own rationale.

## Design decision (pick one; recommendation first)

**Option A (recommended): the loop holds the lock only around its own git-mutating sections.**
The lock exists to serialize *git operations on the shared checkout/refs*, not to declare "a run
is in progress" (the heartbeat already signals that). Acquire/release around: `prepare_wt`/
`cold_reset`, integrate/push blocks, `record_outcome`/`mark_done`/`block_task`,
`reconcile_overlays`, `sync_primary_checkout`. Between builds (the minutes-long `claude` call, CI
watch) the lock is free, so a mark-done waits seconds, exactly as the header intended.
*Risk*: more acquire/release pairs to keep correct; audit every git-touching path. The
"second loop instance" guard moves to the heartbeat/lock-at-startup probe: keep a run-level
`*-loop.run` marker (mkdir, same idiom) that ONLY loops take, so two loops still can't overlap.

**Option B (smaller): default `REPO_LOCK_MAX_WAIT` (e.g. 120s) + a clear failure message** telling
the owner the loop holds the lock and to retry after the run (or use the overlays via dashboard
later). Honest, but the mid-run-overlay promise stays broken — update those comments/docs too.

**Option C**: overlay writes bypass the lock entirely (the loop only READS overlays at iteration
boundaries; a torn read is prevented by writing temp+rename). Smallest diff that restores the
promise; keep the lock for consolidate/rewire which touch TASKS.json itself.

A+C combine naturally. If unsure, implement B now (one-line default + message) and file A as the
follow-up — B is strictly better than today.

## Acceptance criteria

- `mark-done.sh` during a live run either completes within seconds (A/C) or fails within
  `REPO_LOCK_MAX_WAIT` with an actionable message (B) — never an infinite silent poll.
- Two loop instances still cannot run concurrently (whatever mechanism guards that, test it).
- Dashboard mark buttons never hang the HTTP request indefinitely.
- Update `repo-lock.sh`'s header prose to match the implemented reality.

## Test plan

Hermetic: hold the lock from a background subshell (mkdir the lock dir), run `mark-done.sh` with a
small `REPO_LOCK_MAX_WAIT`, assert timely exit + message (B) or success via the released window
(A/C). Extend `repo-lock.sh --selftest` for any new marker. If A: a two-contender test (two
subshells doing acquire/mutate/release loops) asserting no interleaved corruption of a counter
file.
