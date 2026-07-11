# F01: Cost/usage ledger — measure the thing the harness optimizes

**Type**: feature · **Priority**: P1 · **Effort**: M
**Affected files**: `templates/scripts/loop.sh` + `loop.in-place.sh` (`run_claude`, `record_failure`/`flush_failures`, `record_outcome`/`mark_done`, `audit_gate`), `templates/dashboard/server.js`/`lib.js` (display), `templates/docs/HARNESS.md` §8 (row schema), `postflight*.sh` (optional total)
**Release**: MINOR bump · MIGRATIONS entry (mechanism both variants + ledger-schema note — additive fields, forward-only, no backfill) · checksums · parity where the code is shared

## Problem

DESIGN.md §0 goal #1 is "minimise cost"; nothing measures spend. `run_claude` already tees the raw
stream-json to `.claude-out.*.jsonl`, whose final `result` event carries usage and
`total_cost_usd` — and the loop discards it. Unanswerable today: what did T042 cost? What does an
escalation to rung 4 cost vs starting there? Is the audit overhead worth it? Does auto-tuning beat
"always sonnet/medium"?

## Design

1. **Capture (loop-owned — P5: only the loop writes ledgers).** After each `run_claude`, extract
   from the raw jsonl:
   ```bash
   jq -r 'select(.type=="result") | [.usage.input_tokens // 0, .usage.output_tokens // 0, .total_cost_usd // 0] | @tsv'
   ```
   (Verify field names against a real transcript first — `usage` shape has changed across CLI
   versions; make the extraction tolerant: missing fields → 0, never fail the attempt over
   accounting.)
2. **Per-attempt**: add `tokensIn/tokensOut/costUSD` to the `failures.jsonl` row that
   `record_failure` writes (diagnostics ledger — additive fields are safe). Successful final
   attempts have no failures row, so ALSO accumulate per-task running totals in loop variables.
3. **Per-task**: add to the `outcomes.jsonl` row: `buildCostUSD` (sum over all attempts),
   `auditCostUSD` (auditor invocations, tagged separately — they're overhead, not build cost),
   `tokensIn/tokensOut` totals. Append-only, forward-only: old rows simply lack the fields; every
   consumer must treat them as optional (`// 0`).
4. **Display**: dashboard internals per-cell "avg build cost @ chosen tier" + a "spend (last 7d /
   run)" strip from row timestamps; postflight prints a one-line total. Keep policy.jq UNCHANGED —
   cost is observability, not (yet) a policy input; wiring cost into tier choice is a separate
   future decision.

## Acceptance criteria

- After a real (or T01-fake with a synthetic result event) build: the outcome row carries plausible
  nonzero cost/token fields; audit cost tagged separately; a failed attempt's failures row carries
  its own attempt cost.
- Old rows without the fields render as "—" in the dashboard, never NaN.
- Accounting failures (unparseable usage) never fail an attempt — log a WARN, write zeros.
- HARNESS.md §8 row schema updated; MIGRATIONS ACTION documents the additive fields.

## Test plan

Unit: a fixture raw-jsonl with a result event → extraction function returns the tsv (new selftest
flag or lib extraction). lib.test.js: cell aggregation with mixed old/new rows. T01: end-to-end
row assertion once the fake claude emits a synthetic result event with usage.
