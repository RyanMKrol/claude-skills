# ralph-harness — deferred design TODO

Items we identified but deliberately deferred, captured so they're not lost. Each has enough context
to pick up cold later. (Dev-only file — not under `templates/`, so it isn't installed into scaffolded
projects and needs no version bump.)

## 1. Wire the `risk` facet into behaviour — or drop it (currently inert)

**Status:** `facets.risk` (the danger-flag axis — `touches-schema`, `full-stack`, `cross-cutting`,
`touches-executor`) is **assigned** by the add-to-backlog skill and **stored** in every
`outcomes.jsonl` row (the ledger persists the whole `facets` object), but it is **read by nothing**:
`policy.jq` has 0 refs; the loop's `pick_base` / `audit_gate` read only `.facets.layer` +
`.facets.workType`; the dashboard + daemon never touch it. So the calibration cell is
`(layer × workType)` only — `risk` is **purely descriptive today** (captured but functionally inert).

**To do — decide: wire it, or drop it.** Most natural wiring (composes cleanly with the audit gate):
- a high-risk flag (e.g. `touches-executor`, `touches-schema`) **forces the audit** — skip the
  per-cell sampling decay, always audit, never fall to the 10% floor; and/or
- **raises the cold-start floor** a rung for high-risk cells.
Implement in `audit_gate` (sampling) / `pick_base` in `templates/scripts/loop.sh` +
`loop.in-place.sh`, and mirror in local-jobs `.harness/loop.sh`. If we choose NOT to wire it, remove
`risk` from the add-to-backlog skill + the docs so it stops implying a guarantee that doesn't exist.

## 2. Implement the `scope` structural gate (designed but never built)

**Status:** `templates/docs/designs/audit-verification.md` §4.2 says *"`scope` — the diff must touch
these files; flag scope creep."* But `structural_checks()` never checks scope — it only verifies:
non-empty diff, `expectsTest` → a test file changed, and `LOCAL_DOD` passes. So the cheapest, most
objective gate — pure file-path comparison that enforces the cheap builder stayed inside the files the
strong (planner) model declared — is **missing**. This is the gate that most directly delegates
"did the weak model do what was planned" to a free, deterministic script.

**To do:** in `structural_checks()` (both plugin loops + local-jobs `.harness/loop.sh`), add: every
file in the diff (`origin/main..HEAD`) must be **within the task's `scope`** — exact path match, or
under a `scope` directory entry — with two always-allowed exceptions:
- the task's own `.harness/worklog/…` (the builder always commits its worklog), and
- **test files** (`*.test.*`, `*.spec.*`, `**/tests/**`, `test_*`).
Any other changed file outside `scope` = **scope creep → a failed attempt** (cold retry → escalate),
same handling as a failed audit. **Decision already made:** allowlist tests (the planner can't always
name a brand-new test file, and `expectsTest` + the audit already govern tests) but **NOT docs** (the
planner should declare doc files in `scope`; our current backlog mostly does).

**⚠ Before turning it on:** review the pending backlog tasks' `scope` for completeness — a binding
scope gate will throw false "scope creep" failures on any task whose `scope` under-lists a file it
legitimately touches. So this is a two-part job: (a) the check, (b) a scope-completeness pass over the
live backlog.
