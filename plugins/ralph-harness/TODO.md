# ralph-harness — deferred design TODO

Items we identified but deliberately deferred, captured so they're not lost. (Dev-only file — not
under `templates/`, so it isn't installed into scaffolded projects and needs no version bump.)

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

## 2. Reconcile the worktree done-protocol with the scope gate (stopgap in place)

**Status:** the WORKTREE variant's builder done-protocol edits `.harness/TASKS.json` (sets status), the
`README.md` status row, and `.harness/LIMITATIONS.md` — none ever in a task's `scope`. The scope gate
(v0.9.4/0.9.5) would flag those as creep, so `loop.sh`'s `structural_checks` currently **allowlists**
those three files. That works but is loose — a worktree builder can change README / LIMITATIONS freely,
outside scope. The in-place variant has no such issue (its loop owns status; its builder edits only
in-scope docs), so its allowlist stays strict: just worklog + tests.

**To do — the clean fix:** align the worktree done-protocol to the in-place model — the builder commits
code + worklog only; the LOOP's integrate step sets status / flips the README row. Then drop the
`.harness/TASKS.json|README.md|.harness/LIMITATIONS.md` allowlist from `loop.sh`'s `structural_checks`
(make it strict like in-place) and remove the "done-protocol bookkeeping" clause from its build prompt.

---

## Done (kept for reference)

- **Scope structural gate** — *implemented in v0.9.4.* `structural_checks()` (both loop variants +
  local-jobs) now fails any task whose diff touches a file outside its declared `scope`, with the
  worklog + test files allowlisted and docs requiring explicit declaration.
