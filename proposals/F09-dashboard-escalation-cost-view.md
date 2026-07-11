# F09: Dashboard — escalation/cost view from data already recorded

**Type**: feature · **Priority**: P2 · **Effort**: M
**Affected files**: `templates/dashboard/lib.js` (reducers + tests), `server.js` (render), `templates/docs/HARNESS.md` §8 if display semantics need a note
**Release**: MINOR bump · MIGRATIONS entry (mechanism) · checksums · `node --check` + lib.test.js

## Problem

`outcomes.jsonl` records `startModel/Effort`, `finalModel/Effort`, `succeededRung`, `topRung`,
`attemptsAtRung`, `totalSoftFails`, `scopeSize` — but the dashboard uses only the final tier. A
task that limped to opus after 6 soft-fails renders identically to one that passed clean at haiku.
The single biggest observability gap for a cost-thesis harness (and the natural display surface
for F01's cost fields when they exist).

## Design

New reducers in `lib.js` (pure, tested), rendered in the harness-internals view:

1. **Per-cell escalation stats**: N builds, % escalated (`succeededRung > 0` relative to start),
   avg `totalSoftFails` per success, avg attempts. A cell with high escalation = the policy's
   floor is wrong or the specs are weak — pair the number with the existing chosen-tier display so
   the tension is visible at a glance.
2. **Per-task expander line**: `start → final` tier with rung count when they differ
   ("haiku → sonnet/high, 3 rungs, 5 soft-fails"), sourced from `buildOutcomesByTask` (already
   exists in server.js — move it to lib.js per B15's direction).
3. **Wasted-effort strip**: total soft-fails last N tasks (a trend arrow vs the prior N) — the
   cost proxy until F01 lands; render actual `$` when F01's fields are present (`// null` guard,
   "—" for old rows).
4. `scopeSize` column in the cell table (recorded, never shown — cheap while in there).

## Acceptance criteria

- All reducers handle old rows lacking new fields (no NaN anywhere).
- lib.test.js covers each reducer with mixed-era fixture rows.
- No new blocking I/O in the poll path (compose with B15's caching if both land).

## Notes

Coordinate with F10 (attempt timeline) — same expander real estate; F10 shows the per-attempt
ladder from failures.jsonl, this shows the outcome summary from outcomes.jsonl. Build both behind
one expander section if implementing together.
