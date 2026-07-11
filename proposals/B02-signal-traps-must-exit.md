# B02: Signal traps must exit — Ctrl-C/kill currently releases the lock but the loop keeps running

**Type**: bug · **Priority**: P0 · **Effort**: S
**Affected files**: `templates/scripts/loop.sh`, `loop.in-place.sh` (main-loop trap), `mark-done.sh`, `mark-failed.sh`, `mark-reviewed.sh`, `consolidate-ideas.sh` (same trap shape)
**Release**: PATCH/MINOR bump · MIGRATIONS entry (mechanism, both variants + the CLIs) · checksums · `bash -n` · parity

## Problem

Both loops install:

```bash
trap 'release_lock' EXIT INT TERM
```

A trap handler that does not `exit` **resumes the script after the handler returns**. Verified
empirically during the evaluation: after `kill -TERM <pid>` (and INT) the loop was still alive and
continued executing.

**Consequences**:
- Ctrl-C during a build: the `claude` child dies (rc 130) → `run_claude` returns non-zero → the
  loop logs "crash", sleeps 30s, and re-attempts the task — but the INT trap already **deleted the
  lock**, so a second `loop.sh` (or a `mark-done.sh` believing no loop runs) can start
  concurrently. The concurrency guard is void after one signal.
- Plain `kill <pid>` effectively cannot stop the loop (only `kill -9`, which skips lock cleanup).
- The "✅ SAFE TO Ctrl-C NOW" banners are only accidentally true (via `set -e` on an interrupted
  `sleep`), and NOT true during a build.

The `mark-*.sh` / `consolidate-ideas.sh` scripts share the trap shape with lower stakes.

## Proposed fix

Standard signal-trap idiom, in every affected script:

```bash
trap 'release_lock' EXIT
trap 'release_lock; trap - EXIT; exit 130' INT
trap 'release_lock; trap - EXIT; exit 143' TERM
```

(`trap - EXIT` prevents a double release; `release_lock` is already safe to call twice, but keep
the idiom clean.) In the loops, exiting 130/143 also means `supervise.sh` sees a non-zero,
non-3/5 exit → its short error backoff — acceptable; a human who Ctrl-C'd the loop almost
certainly Ctrl-C's supervise too (its own INT trap exits 0).

## Acceptance criteria

- `kill -TERM` a running loop → process exits promptly (within the current blocking call), exit
  code 143, lock released exactly once.
- Ctrl-C (INT) → exit 130, lock released, **no further iteration/attempt runs**.
- Normal completion unchanged (EXIT trap still releases).
- Same behavior in both variants and the four CLI scripts.

## Test plan

Extend `templates/scripts/supervise.test.sh`'s pattern: a test that backgrounds a loop stub—
actually, test the real thing: start `env -u CLAUDECODE ... loop.sh` in a hermetic repo rigged so
`select_task` finds nothing but with a long `WAIT_SECONDS`… simpler and sufficient: a
`trap-exit.test.sh` that sources nothing and instead runs each script with a stubbed long-running
region via `bash -c`, sends TERM, asserts exit code and that the lock dir is gone and no output is
produced afterward. (The evaluation verified the bug with a 10-line scratch script — reuse that
shape: replicate the trap line in a probe first to prove the FIXED idiom, then assert the real
scripts contain the fixed trap lines verbatim, one grep per script.)

## Notes

- Do NOT change the deliberate rule that the heartbeat is cleaned only on clean paths, not in the
  trap (the heartbeat is how an interrupted climb resumes — see the comment above `heartbeat()`).
  Only the lock/exit behavior changes.
