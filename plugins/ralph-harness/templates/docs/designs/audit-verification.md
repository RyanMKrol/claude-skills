# Audit-gated Definition of Done (verification-aware calibration)

How the harness keeps its difficulty calibration honest: a blocking audit gate makes "done" mean
*intent met*, not just *the cheap model believes it's done*.

## 1. The problem

The difficulty auto-tuning starts every task at the cheapest model and escalates on failure, learning
per facet-cell which tier reliably builds each kind of task. The success/fail signal that feeds that
learning is, by default, **the builder's own judgement + green CI**. The weakest model is also the
weakest *self-validator*, so the dangerous failure mode is a **false success**: the cheap model writes
plausible code that compiles, passes the existing tests, and builds — but doesn't satisfy the task's
intent — and CI is green because nothing pins the new behaviour. That false success:

1. ships subtly-wrong work, and
2. **poisons the calibration** — it records "the cheap tier *can* do this cell," so the policy
   under-provisions that cell forever. False successes are worse than false failures: failure is
   self-correcting (the ladder escalates) while a false success is silent and compounding.

CI is a real, model-agnostic gate, but it only verifies what CI can check (compile/test/build), not
*intent*. The gap between "CI green" and "actually done" is where false successes live.

## 2. Principles (settled)

- **The builder's judgement must never be what advances a task or feeds the ledger.** Only an
  objective signal does. Verification effort goes into *catching false positives*, not re-checking the
  build.
- **Front-load verification authorship to planning time.** The backlog is authored by a strong model;
  the strong author writes the *objective bar* (what must change, what a check must assert) into the
  spec, so the cheap builder is checked against a bar **it did not write.** This breaks the recursion
  (the cheap model can't validate itself with its own lenient test).
- **The audit is part of the Definition of Done** — blocking, not async. A task is not complete until
  it passes. This keeps `main` and the ledger clean *at the source*, and makes audit failures normal
  failure signals that drive escalation + correct learning.
- **Every attempt is fully cold.** No worklog carryover, no audit feedback, no partial-work resume.
  Each measured attempt answers exactly "can this tier do this spec, cold?" This **reverses** the old
  "resume, don't restart" rule and makes **atomic task sizing load-bearing** (a task that can't be
  done in one cold pass is mis-sized → split it).
- **No feedback to the builder.** Audit reasons go to a separate audit log for humans/observability,
  never into the builder's context (including the worklog, which the builder no longer reads).

## 3. The flow

```
SELECT → BUILD (cheap, cold)  →  cheap objective checks  →  AUDIT gate (if sampled)  →  DONE
              tier from policy     structural + DoD/CI       max(opus-medium, builder)
                                                             spec + diff → PASS/FAIL
   on any gate FAIL → failed attempt at tier T → retry cold (MAX_ATTEMPTS) → escalate up the ladder
```

Cheap checks first (free / model-agnostic) so we never spend an audit on work that doesn't even
compile. The audit runs only if the task is *sampled* (§4.6); when it runs it **blocks**.

### Who does what — the loop is the sole orchestrator

The models are **stateless sub-processes the loop invokes for one step each.** Neither the builder nor
the auditor pushes-to-complete, watches CI, or marks anything done — **the loop owns all of that**
(pushes, the CI-watch, the `TASKS.json` status edit, the `outcomes.jsonl` row). The chain is **loop →
builder → (loop runs gates, incl. invoking the auditor) → loop pushes/watches CI → loop marks done.**

**Worktree variant** — `main` is untouched until every gate passes:
1. Loop picks the task, computes the build tier (policy), decides if it's audit-sampled.
2. Loop spawns the **builder** (cheap, cold) in the worktree → builds, runs local DoD, commits,
   **pushes branch `tNNN`** (the push that triggers CI — a *branch*, main untouched).
3. Loop runs cheap structural checks. Fail → failed attempt.
4. Loop **watches the branch CI run**. Red → failed attempt.
5. Loop — if sampled — spawns the **auditor** (`max(opus-medium, builder)`, stateless, spec + branch
   diff) → `PASS`/`FAIL`. Fail → failed attempt.
6. Loop — all green — **fast-forwards `main` + pushes**, marks `done`, writes the ledger row (tagged
   `audited`/`ci-only`). Auditing after CI-green means no audit spend on a CI-red build.

**In-place variant** — no branch, so the local DoD is the CI proxy that gates before the audit:
1–2. Loop → **builder** builds + commits **locally** (does NOT push).
3. Loop runs structural checks **+ the local DoD** (your stack's format/lint/test/build) — the cheap
   objective gate standing in for "CI before audit" (no real CI without pushing).
4. Loop — if sampled — runs the **auditor**. Fail → **reset the local commit before it is pushed**
   (remote stays clean) → failed attempt.
5. Loop pushes → watches the real CI run (final remote confirmation).
6. Loop — CI green — marks `done` + writes the ledger row.

## 4. Components

### 4.1 Cold attempts (no carryover)
The build prompt is spec-only: the task's `spec` MD (`## Do` / `## Done when`), `scope`, `verify`, and
framework rules — **no worklog, no prior-attempt context, no audit reasons.** The worklog is still
*written* (append-only, for humans) but **not read** by the builder. This removes the "resume, don't
restart" guidance from the loop prompt, `CLAUDE.md`, and `HARNESS.md`. (An *infra* interruption —
rate-limit/crash — is not a counted failure: the loop waits out the limit, then RE-ATTEMPTS the task
COLD like any other attempt. Every attempt — failure-retry or post-pause — is cold; we accept the
re-work to keep every measured pass a clean cold one.)

### 4.2 Authoring-time verification contract + structural post-checks
The strong author records, per buildable task, machine-checkable expectations; the loop asserts them
before accepting `done` (cheap, model-agnostic):
- **`scope`** — the diff must touch these files; flag scope creep.
- **`expectsTest: bool`** — if true, a test file must have changed in the diff.
- **`verify`** — the named commands must run and pass (the loop runs them).
A failed structural check is a failed attempt, before any audit spend.

### 4.3 The blocking audit
A fresh agent (NOT the builder) gets the task `spec` + the diff and answers: *does this satisfy
`## Done when`?* It returns a strict **PASS/FAIL** (+ reasons → audit log only). PASS is required for
`done`. Stateless and independent of the builder.

### 4.4 Auditor tier = `max(opus-medium, builder tier)`
Floor of the medium-tier flagship, rising to match the builder if it escalated above medium — so the
auditor is **never weaker than the work it checks.** Common case (cheap build) → medium audits it;
rare escalated case → the auditor rises to the builder's tier.

### 4.5 No feedback (see §2). Audit reasons never reach the builder.

### 4.6 Verification-strength ledger tag + per-cell audit sampling
Each `outcomes.jsonl` row gains a **`verification`** field: `audited` (passed the blocking audit) or
`ci-only` (not sampled). Calibration weights `ci-only` successes lower. **Sampling is per facet-cell,
on `audited`-confirmed successes only**, decaying from full audit to a floor that is never zero:
- `auditStartN = 3` — audit **100%** until the cell has 3 audit-confirmed successes.
- linear taper `3 → 8`.
- `auditFloorN = 8`, `auditFloor = 0.10` — from 8 confirmed onward, audit **10%** (drift spot-check).
Keyed on confirmed-only so the system can't talk itself into confidence on thin evidence; floored so
it never stops checking. Sparse cells (rare task types) keep auditing — correct, not a cost bug.

### 4.7 Audit failure handling
An audit FAIL (or structural/DoD/CI fail) = a **failed attempt at tier T** → retry cold up to
`MAX_ATTEMPTS`, then escalate. The ledger records the failure at that tier, so a cheap tier that
produces false successes now *escalates on them* and the calibration learns it is insufficient for the
cell — the correct lesson.

## 5. Config / schema changes

`facets.json` `.policy` gains: `auditStartN` (3), `auditFloorN` (8), `auditFloor` (0.10),
`auditorModel`, `auditorEffort` (the medium-tier flagship). Separate from the model-selection `minN`.
Task schema gains optional **`expectsTest: bool`**.
`outcomes.jsonl` rows gain **`verification: "audited" | "ci-only"`**.
