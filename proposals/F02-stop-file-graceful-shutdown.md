# F02: Stop-file graceful shutdown

**Type**: feature · **Priority**: P1 · **Effort**: S
**Affected files**: `templates/scripts/loop.sh` + `loop.in-place.sh` (main loop, between-iterations + between-attempts checks), `supervise.sh` (treat as terminal), `templates/docs/HARNESS.md` (operating docs), `ensure-gitignore.sh` (ignore the marker)
**Release**: MINOR bump · MIGRATIONS entry (mechanism, both variants) · checksums · parity

## Problem

The only clean stop today is Ctrl-C between cycles; mid-cycle interruption is what
`loop-recover` exists to repair (orphaned task, stale lock, dirty tree). There is no "finish the
current task, then stop" signal — the most common thing an owner actually wants ("I need the
machine / want to change the backlog after this task").

## Design

- **Marker**: `.harness/worklog/.stop` (gitignored via the managed block — add to
  `ensure-gitignore.sh`'s heredoc, never to `templates/gitignore`).
- **Loop**: check at the top of each iteration AND between attempts (after a failed attempt,
  before the cold retry): if present, log "stop requested — exiting cleanly after
  <current-position>", delete the marker (consume it), release the lock via the normal exit path,
  **exit 0**… decide: exit 0 lets supervise continue its cadence (it would relaunch next cycle —
  probably what the owner wants after a pause) vs a new exit code 6 that supervise treats as
  "stop the whole supervised run". Recommendation: consume the marker + **exit 6**, supervise
  handler prints a friendly "stopped by request — re-run supervise.sh when ready" and exits 0.
  A stop request means "I want the machine back", not "skip one cycle".
- **Between attempts** placement matters: after `record_failure`, before the next cold reset — so
  no attempt is half-abandoned and the ledger stays consistent. NEVER check mid-gate (between
  commit and status flip — the exact orphaning window loop-recover repairs).
- **Ergonomics**: document `touch .harness/worklog/.stop` in HARNESS.md's operating section; the
  dashboard could get a "request stop" button later (out of scope here — note it in F09/F12 land).

## Acceptance criteria

- Marker created mid-build: current attempt runs to its natural conclusion (integrated or failed),
  THEN the loop exits with the chosen code; marker gone; lock released; no orphaned state
  (TASKS.json status consistent with the ledger).
- Marker present at loop start: exits immediately before selecting, consuming the marker.
- supervise: the new code path prints the message and stops (test via supervise.test.sh stub).
- loop-recover unaffected (a stop-file exit leaves nothing to recover).

## Test plan

supervise.test.sh: stub exiting 6 → assert the handler. T01: create the marker while the fake
build sleeps → assert clean exit + consistent state. Before T01: select-task.test.sh-style fixture
asserting the at-start behavior (marker present → exit, marker consumed) is cheap and real.
