# T04: rl_reset_wait parse-matrix test

**Type**: testing · **Priority**: P2 · **Effort**: S
**Affected files**: `templates/scripts/loop-ratelimit.test.sh` (extend — the `rl_selftest wait` plumbing already exists)
**Release**: PATCH bump · MIGRATIONS entry (mechanism test) · checksums

## Problem

`rl_reset_wait` has three independent parse branches (ISO-8601 timestamp; "resets in 45 minutes"
relative; "resets 3:45 PM"/"resets 1am (TZ)" clock forms with tomorrow-rollover) plus the
`RL_BUFFER` cushion and `RL_BACKOFF_MAX` cap — and exactly ONE shape ("resets 1am (TZ)") is
exercised today. This function computes how long an unattended overnight run sleeps; a parse
branch regression turns a 20-minute wait into 5 hours (or a mis-parse into an instant hammer
loop).

## Design

Pure extension of `loop-ratelimit.test.sh`'s existing `wait` cases (write each notice into the
raw sibling `$O.jsonl`, call the selftest, bound-check the returned seconds):

1. ISO-8601 with Z; ISO-8601 with a numeric offset.
2. "resets in 45 minutes" / "resets in 2 hours" / "resets in 90 seconds".
3. Clock without TZ ("resets 3:45 PM") — assert same-day when in the future.
4. Past clock time ("resets 1am" when now is later) → +86400 rollover (bound: 0 < wait ≤ 24h and
   > the naive negative value).
5. A parsed reset far away → capped at `RL_BACKOFF_MAX` (set the knob small in-test).
6. Garbage / no notice → the `none` sentinel (exponential-fallback path signal).
7. `RL_BUFFER` added on top of a parsed time (set BUFFER=60, assert the +60).

Time-dependence: cases 3/4 depend on "now" — compute expected bounds inside the test from `date`
at runtime (BSD + GNU date compatible, like the function itself; skip a case gracefully if the
platform date lacks the needed mode, printing SKIP not FAIL).

## Acceptance criteria

- All branches covered on macOS bash 3.2 AND ubuntu (CI runs both); no flakes across timezones
  (run with `TZ=UTC` and one odd zone, e.g. `TZ=Pacific/Kiritimati`, in the test itself).
