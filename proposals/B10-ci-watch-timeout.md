# B10: `gh run watch` can block forever — CI_TIMEOUT only bounds FINDING the run

**Type**: bug · **Priority**: P2 · **Effort**: S
**Affected files**: `templates/scripts/loop.sh` (`wait_ci_green`), `loop.in-place.sh` (same function — differs by variant, mirror the logic)
**Release**: PATCH bump · MIGRATIONS entry (mechanism, both variants) · checksums

## Problem

In `wait_ci_green`, the `$waited`/`CI_TIMEOUT` loop bounds only the search for a run id. Once an
id is found, the code calls `gh run watch "$runid"` with no timeout — a run stuck `in_progress`
(hung runner, awaiting manual approval, a queue outage) hangs the loop indefinitely, heartbeat
frozen at `awaiting-ci`, with supervise never regaining control.

## Proposed fix

Replace the blocking `gh run watch` with a bounded poll of the run's status (the function already
polls to find the id — reuse the idiom):

```bash
while :; do
  status="$(gh run view "$runid" --json status,conclusion --jq '.status + "/" + (.conclusion // "")' 2>/dev/null || echo unknown)"
  case "$status" in
    completed/*) break ;;
  esac
  waited=$((waited + WAIT_SECONDS))
  [ "$waited" -ge "$CI_TIMEOUT" ] && { log "CI run $runid still not finished after ${CI_TIMEOUT}s — treating as indeterminate"; return 2; }
  sleep "$WAIT_SECONDS"
done
```

Then classify the conclusion exactly as today. `CI_TIMEOUT` becomes the bound for the WHOLE wait
(find + run); document that in `harness.env`'s comment for `CI_TIMEOUT` (config prose change —
note in the ledger, no knob added). Returning 2 (indeterminate) routes into the existing
indeterminate handling (see B08 — land B08 first or together so in-place gets the re-check).

## Acceptance criteria

- A run that never completes → after CI_TIMEOUT total, `wait_ci_green` returns 2; the loop
  proceeds via the indeterminate path (re-check then soft-fail), never hangs.
- Green/red classification unchanged for runs that do finish.
- Both variants mirrored; heartbeat continues updating during the poll (check whether the
  heartbeat is written inside this wait today — if not, leave as-is; do not expand scope).

## Test plan

T01's fake `gh` covers this naturally (a scripted `gh` that never returns completed → assert the
loop moves on after a tiny CI_TIMEOUT). If landing before T01: extract-and-probe is NOT needed —
a hermetic test can run `wait_ci_green` by sourcing? The function reads globals; simplest is to
defer behavioral coverage to T01 and land this with `bash -n` + careful review + the existing
suite green.
