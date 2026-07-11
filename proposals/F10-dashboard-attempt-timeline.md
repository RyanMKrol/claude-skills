# F10: Dashboard — per-task attempt timeline

**Type**: feature · **Priority**: P3 · **Effort**: S
**Affected files**: `templates/dashboard/lib.js` (reducer + tests), `server.js` (task-expander render)
**Release**: MINOR bump · MIGRATIONS entry (mechanism) · checksums

## Problem

`failures.jsonl` holds per-attempt rows keyed by task id — `rung`, `attempt`, `model`, `effort`,
`kind`, `detail` — but the task expander shows only an aggregate count and the LATEST kind/detail
(the failure pill). The story "rung 0 haiku → ci-red ×2 → rung 1 sonnet → audit-FAIL → rung 2 →
done" is on disk and never rendered; it's the fastest way for an owner to judge whether a task
struggled because of the spec (same kind repeating) or the tier (kinds change as it climbs).

## Design

A `attemptTimeline(failureRows, outcomeRow)` reducer in lib.js: sort the task's failure rows
(rung, attempt), append the terminal outcome (succeeded at rung N / blocked), return a compact
sequence the expander renders as a single line of steps — each step: tier label + failure kind
(with the detail as the title tooltip — mind B14's escaper fix). Truncate detail to a sane length
in the reducer, not the template.

## Acceptance criteria

- A task with a multi-rung history renders the full ladder in order; a clean first-try task shows
  a single "done @ tier" step (no failures rows exist for it — derive from the outcome row alone).
- Tooltips safe with quotes/HTML in `detail` (depends on B14 — land after it).
- lib.test.js: ordering, clean-task case, blocked-task case, truncation.
