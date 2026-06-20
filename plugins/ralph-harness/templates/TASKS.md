# TASKS — implementation backlog

> **This is a template.** The tasks below are illustrative examples that show the
> schema and the gate markers. **Replace them with your own** atomic,
> dependency-ordered tasks before running the loop.

This is the execution backlog for the project. Each task is atomic, ordered by
dependency, and bounded by explicit acceptance criteria so it is achievable by a single
build pass of the pinned model. It is executed by a **single sequential loop** — the next
eligible task, one at a time — described in [`docs/HARNESS.md`](./docs/HARNESS.md).

See [`CLAUDE.md`](./CLAUDE.md) for the repo conventions (branch + self-merge, no PRs; docs
in lockstep) and [`docs/HARNESS.md`](./docs/HARNESS.md) for the autonomous build harness.

## How the loop works

The build harness is a **single sequential loop** — one `claude -p` per task, fresh context,
all durable state in the repo (this file's statuses, `worklog/`, git). The authoritative
design is [`docs/HARNESS.md`](./docs/HARNESS.md); this section is just how to *read this
file*. Each iteration the loop:

1. **Picks the next eligible task** — the first not-done task (per the Status index) whose
   `Depends on:` are all `done` **and merged into `main`**.
2. **Resumes, never restarts.** If a `tNNN` branch or uncommitted work exists from an
   interrupted attempt, it continues that — reads `worklog/TNNN.md`, inspects the working
   tree, and reconciles the delta against the task's `Done-when:` before coding.
3. **Implements only the outstanding delta**, within the task's `Scope:`, and verifies
   prerequisites are real (deps present in code, not just a ticked box).
4. **Passes the Definition of Done** ([`docs/HARNESS.md`](./docs/HARNESS.md) §5): your
   project's format/lint/test/build, integration/empirical checks where the task's `Verify:`
   asks for it, and **green GitHub CI** — flipping the index box and the `README.md` row in
   the **same commit**.
5. **Branches off `main`, pushes; the loop merges on green CI** and records the result. On
   failure it appends a `worklog/TNNN.md` entry (what failed, why, what's left) and stops.

Rules:
- **One task per iteration.** Do not batch.
- **Finish completely.** Never mark `done` with a failing `Done-when:` or partial scope.
- Tasks tagged **🔒 needs-human** need a one-time manual step (credentials, provisioning);
  author + validate as far as possible, then record `failed:blocked` — do **not** mark done.
  Tasks tagged **🚦 Gate** additionally need an explicit human review of the deliverable.

### Work log & retries

Loops must never spin forever burning tokens. The mechanics:

- **Status vocabulary:** `pending` → `done`, or `failed` (carries an **attempt count** and a
  **reason**). `failed` is written by the loop at runtime; the index/specs below start
  everything `pending`.
- **Per-task work log `worklog/TNNN.md`** (append-only): every attempt appends a dated entry —
  what it tried, what passed/failed, the reason/blocker, and what's left. **Read it before
  every (re)attempt.**
- **Failure taxonomy:**
  - `failed:soft` — transient (token/quota exhaustion, flaky network, partial progress
    checkpointed) → eligible for retry.
  - `failed:blocked` — hard blocker (🔒 needs-human, unmet/abandoned prerequisite, missing
    gate decision) → **not** retried; surface to the human.
- **Caps:** `MAX_ATTEMPTS` per task (default 3) of `failed:soft` → then `failed:blocked`. A
  global iteration/wall-clock cap bounds total spend (and naturally handles running out of
  tokens — `claude -p` simply can't run). Waiting on deps consumes no attempt.

---

## Execution order & gates

There are no tracks, waves, or parallel worktrees — the loop walks the backlog in
**dependency order**, one task at a time ([`docs/HARNESS.md`](./docs/HARNESS.md)). A task
becomes eligible once its `Depends on:` are merged into `main`.

**Gates (the loop must not skip them).** A task marked **🚦 Gate** needs its `Done-when:` met
**and** an explicit human review of the deliverable before any dependent task proceeds. A
task marked **🔒 needs-human** needs a one-time human step (credentials, provisioning, a live
go/no-go) and is recorded `failed:blocked`, never auto-completed.

---

## Status index

> The checkbox is the **only** source of done/not-done. Group by phase as the backlog grows.

- [ ] T001 Project scaffold + CI green on an empty build
- [ ] T002 Core module skeleton + public interface
- [ ] T003 First feature against the core interface
- [ ] T004 Integration test harness 🚦 Gate
- [ ] T005 Provision external resource 🔒 needs-human

---

## Tasks

### T001 — Project scaffold + CI green on an empty build
- **Depends on:** (none)
- **Scope:** project manifest, `src/` entrypoint, `.github/workflows/ci.yml`
- **Do:** Lay down the minimal project skeleton for your stack and wire the real
  format/lint/test/build commands into CI so an empty build goes green.
- **Done-when:** `README.md` documents how to build/run; CI is green on `main`; the
  Definition of Done commands in `docs/HARNESS.md` §5 match what CI runs.

### T002 — Core module skeleton + public interface
- **Depends on:** T001
- **Scope:** `src/core.*`, `tests/core_*`
- **Do:** Define the central module's public interface (types/traits/functions) that later
  tasks build against, with stub implementations and unit tests for the contract.
- **Done-when:** the interface compiles, is unit-tested, and is documented; downstream tasks
  can code against it without touching its internals.

### T003 — First feature against the core interface
- **Depends on:** T002
- **Scope:** `src/feature_x.*`, `tests/feature_x_*`
- **Design:** docs/designs/T003-feature-x.md   # OPTIONAL — only if you authored one
- **Do:** Implement the first real feature using the T002 interface.
- **Done-when:** feature works, unit + integration tests pass, README status row flipped.

### T004 — Integration test harness 🚦 Gate
- **Depends on:** T003
- **Scope:** `tests/integration/*`
- **Verify:** run-app
- **Do:** Build an end-to-end test that exercises the feature against a realistic input, and
  run the app once against real input to confirm it behaves.
- **Done-when:** the e2e test passes and the empirical run is recorded in `worklog/T004.md`.
  **🚦 A human reviews this deliverable before dependent tasks proceed.**

### T005 — Provision external resource 🔒 needs-human
- **Depends on:** T004
- **Scope:** `infra/*`, `docs/SETUP.md`
- **Do:** Prepare everything for the external resource (config, scripts, docs) up to the
  point a human must run the privileged/credentialed step.
- **Done-when:** everything around the manual step is ready and documented; the agent records
  `failed:blocked` (needs-human) — **the human performs the one-time provisioning step.**
