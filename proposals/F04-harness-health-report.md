# F04: Harness-health report — make the write-only ledgers speak

**Type**: feature · **Priority**: P2 · **Effort**: M
**Affected files**: NEW project-local skill `templates/skills/harness-health/SKILL.md` (the `harness-` prefix follows the N01 naming convention, landed in 1.94.0) OR a dashboard tab (`server.js`/`lib.js`); registration plumbing either way
**Release**: MINOR bump · MIGRATIONS entry · checksums

## Problem

`failures.jsonl` is documented as "diagnostics only, never read" — nothing aggregates it, and
`outcomes.jsonl` is only read per-cell by the policy. Invisible today: recurring scope-creep
failures in one cell (a spec-authoring problem), audit-FAIL clusters (spec quality or ladder
problem), ci-red clusters (flaky CI), manual-fail recurrences (the known "UI false-successes"
field note), cells stuck at expensive rungs (ladder candidates), escalation trends. These patterns
are exactly the feedback the PLANNING stage should see (feeding the planner is sanctioned; feeding
the builder is not — PRINCIPLES P4).

## Design

Recommendation: a **read-only project-local skill** (pre-loop-checkin's conventions: never writes,
never pushes) — a dashboard tab can come later reusing the same reducers if they're put in a
sourceable place. Report sections:

1. **Failure mix per cell** (layer×workType): counts by kind (scope-creep / test-missing /
   ci-red / audit-FAIL / local-dod / crash) over a recency window; call out cells where one kind
   dominates, with the canned interpretation per kind (scope-creep ⇒ specs' `scope` too tight or
   prompts drifting; test-missing ⇒ expectsTest authoring gap; audit-FAIL ⇒ under-provisioned
   tier or vague Done-when).
2. **Escalation health**: per cell, fraction of tasks whose `succeededRung > startRung`, and
   `totalSoftFails` per success — the wasted-attempt cost proxy (pairs with F01's cost fields when
   present).
3. **Audit signal**: audited-vs-ci-only mix, audit-FAIL rate (an auditor that never fails is
   rubber-stamping; one that often fails means cheap tiers are shipping junk), manual-fail
   overlays vs audited successes (audit escapes).
4. **Recommendations**: concrete, e.g. "cell frontend×style: 14 audited successes, 0 escapes —
   candidate for a lower floor"; "cell api×migration: 3 blocked at top rung — split tasks or add a
   design doc". Recommendations are ADVICE to the owner — the skill changes nothing (checkin's
   guardrail block verbatim).

## Acceptance criteria

- Runs read-only on a real consumer repo's ledgers; every number reproducible by a jq one-liner
  shown in the report (owners can verify).
- Handles empty/short ledgers gracefully ("not enough data" per section, no division by zero).
- If skill-shaped: registered in create/upgrade/README like the other nine (follow the 1.70.0
  MIGRATIONS entry as the checklist).

## Test plan

Reducer logic as jq programs in files (like policy.jq) → a `health.test.sh` feeding synthetic
ledger fixtures and asserting the aggregates. The skill prose then just runs those programs.
