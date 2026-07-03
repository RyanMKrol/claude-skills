# implementation-harness — deferred design TODO

Items we identified but deliberately deferred, captured so they're not lost. (Dev-only file — not
under `templates/`, so it isn't installed into scaffolded projects and needs no version bump.)

Nothing currently deferred — see "Done" below for the most recent resolved items.

---

## Done (kept for reference)

- **Scope structural gate** — *implemented in v0.9.4.* `structural_checks()` (both loop variants +
  local-jobs) now fails any task whose diff touches a file outside its declared `scope`, with the
  worklog + test files allowlisted and docs requiring explicit declaration.
- **`risk` facet wired — v1.5.0.** `policy.jq` now takes a `$risk` arg (the task's `facets.risk`
  array): AUDIT mode returns mandatory 1000 per-mille whenever `risk` is non-empty (bypassing the
  per-cell decay curve entirely); TIER mode clamps the eligible starting index to `>= 1` (never the
  cheapest rung) for a risky task, even if historical calibration would otherwise let index 0 clear
  the floor. Both loop variants' `pick_base`/`audit_gate` now extract and pass the current task's
  risk flags. See `docs/designs/difficulty-autotune.md`.
- **Worktree done-protocol reconciled with the scope gate — v1.6.0.** Moved `TASKS.json`
  status-ownership out of the worktree builder and into `loop.sh` itself: `record_outcome()` now
  flips `status:"done"` in the SAME detached-worktree commit as the outcome-ledger row, after
  structural checks + the audit gate pass — mirroring the in-place variant's `mark_done()`. The
  builder's prompt no longer mentions `TASKS.json`/README/LIMITATIONS bookkeeping, and
  `structural_checks`' 3-file stopgap allowlist is gone — it's strict (worklog + tests only) like
  the in-place variant now.
