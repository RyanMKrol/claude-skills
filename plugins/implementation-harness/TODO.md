# implementation-harness — deferred design TODO

Items we identified but deliberately deferred, captured so they're not lost. (Dev-only file — not
under `templates/`, so it isn't installed into scaffolded projects and needs no version bump.)

## 1. Reconcile the worktree done-protocol with the scope gate (stopgap in place)

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
- **`risk` facet wired — v1.5.0.** `policy.jq` now takes a `$risk` arg (the task's `facets.risk`
  array): AUDIT mode returns mandatory 1000 per-mille whenever `risk` is non-empty (bypassing the
  per-cell decay curve entirely); TIER mode clamps the eligible starting index to `>= 1` (never the
  cheapest rung) for a risky task, even if historical calibration would otherwise let index 0 clear
  the floor. Both loop variants' `pick_base`/`audit_gate` now extract and pass the current task's
  risk flags. See `docs/designs/difficulty-autotune.md`.
