# The owner-overlay triad & the manual-fail signal — design

> **Customizing?** Add project notes in `custom/docs/designs/manual-fail-signal.md` (the overlay — upgrades
> never touch it), not in this plugin-owned file. See `.harness/custom/CLAUDE.md`.

Difficulty auto-tuning (`difficulty-autotune.md`) and the audit gate (`audit-verification.md`) both
assume the ledger's `blocked:false` rows are genuine successes. Sometimes they aren't: the sampled
audit missed something, or `expectsTest`/CI simply can't check the thing that's wrong (a visual
regression, a subtly wrong value that still "looks" correct). A **false success is more dangerous
than a failure** — a failure is visible and self-corrects via escalation; a false success is silent
and actively poisons calibration, telling the policy a cell is *safer* than it is.

## The owner-overlay triad (`tracking/`)

Three small JSON files, `{id: {...}}` maps, all sharing one design: **committed**, **disjoint git
paths** from whatever the loop itself writes, **owner-written only** (via a CLI script or a
dashboard, never by hand-editing `TASKS.json`), **loop-read-only**, and reconciled into
authoritative `TASKS.json` status by `reconcile_overlays()` at the top of every loop iteration —
so an owner action taken mid-run (from a separate `mark-*.sh` invocation or dashboard click on the
same checkout) takes effect on the loop's very next pass, not just at its next cold start.

- **`human-done.json`** — `{id: {done, at}}`. Marks a `needs-human` task done once the human has
  completed the out-of-band step it was parked for. `reconcile_overlays` promotes it to
  `status:"done"`.
- **`manual-fail.json`** — `{id: {failed, reason, at}}`. Overturns a `done` task the owner has
  caught as a false success. `reconcile_overlays` promotes it to `status:"failed"` — **terminal,
  not auto-reopened**; a human decides separately whether/how to redo the work. The `reason` is
  recorded for a future human, not fed into the auditor's prompt.
- **`reviews.json`** — `{id: {reviewed, at}}`. Purely cosmetic. The loop never reads or writes it;
  it exists only so a dashboard (or the owner) can track which `done` tasks have actually been
  eyeballed.

All three are written by the corresponding `mark-*.sh` CLI (`mark-done.sh`, `mark-failed.sh`,
`mark-reviewed.sh`), which validate the target id(s) **before** any write (a bad id in a multi-id
batch aborts the whole batch — see `mark-done-bulk.test.sh`), then commit + push under the same
`repo-lock.sh` the loop itself uses, so an overlay write can never race a loop commit. A dashboard's
mutation buttons should shell out to these same scripts rather than reimplementing the write, so a
click and a manual CLI run take the identical, already-tested code path.

## Why subtract at read time, not mutate the ledger

`manual-fail.json` corrects the record **without ever rewriting `ledgers/outcomes.jsonl`**, which
stays strictly append-only (a hard invariant elsewhere in this harness — see `HARNESS.md` §6). A
manually-failed task's ledger row still literally says `blocked:false`. Instead, **every reader
that turns ledger rows into a calibration signal subtracts the overlay at query time**:

1. **`policy.jq`'s tier-selection branch** takes a `$manualFail` argument (the parsed
   `manual-fail.json`). When expanding a ledger row into per-rung pass/fail events, a row whose id
   is in `$manualFail` with `failed:true` is treated exactly like `blocked:true` — every rung it
   touched counts as a failure, and the would-be success event is dropped. This stops the
   overturned task from making a `(layer × work-type)` cell look more reliable than it is.
2. **`audit_gate`'s confirmed-audited-count query** (both loop variants) filters out any id present
   in `manual-fail.json` before counting `verification:"audited"` successes for a cell. This
   matters independently of (1): a cell's audit-sampling rate decays toward a floor as *confirmed*
   successes accumulate (`audit-verification.md` §4.6), so a false success that isn't excluded
   would keep suppressing future audit sampling for that exact kind of task — precisely the cells
   most likely to keep producing false successes.

Both subtractions are pure functions of `(ledger row, current overlay)` — evaluated fresh on every
read, so undoing a `mark-failed.sh --undo` immediately restores the original signal with no ledger
surgery either way.

## What this does NOT do

- It does not re-open or re-queue the task. `status:"failed"` is terminal; a fresh task (or a
  hand-authored fix) is a separate, ordinary backlog entry.
- It does not feed the failure reason into the auditor's prompt — the audit stays independent and
  stateless per `audit-verification.md`'s no-feedback-to-the-builder rule.
- It is not automatic. Nothing in the loop ever writes `manual-fail.json` itself; it exists purely
  to capture a human catching something the automated gates didn't.
