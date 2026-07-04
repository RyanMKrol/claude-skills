# LIMITATIONS.md — trade-offs, bottlenecks & known limitations

The single place to evaluate the design's compromises later **without re-deriving them from
the code**. Per `CLAUDE.md` golden rule 5, every change that introduces or reveals a
trade-off, bottleneck, or known limitation **adds a row here in the same commit**.

Each entry: **what** it is · **why** we chose it · **impact** · **when to revisit**.

---

## Harness

These come from the build harness itself (mirror of [`docs/HARNESS.md`](./HARNESS.md) §12) —
keep them here so the design's compromises live in one place alongside your project's own.

- **Hardened Definition of Done makes each task longer.**
  *Why:* empirical + integration + CI-watch is what makes "done" trustworthy.
  *Impact:* more wall-clock and tokens per task; a single window may not finish a large one.
  *Revisit:* if tasks routinely overflow a window — split them smaller.

- **CI-green-before-merge adds minutes per task.**
  *Why:* it buys an always-green `main`.
  *Impact:* latency per integration.
  *Revisit:* acceptable while sequential; only a concern if throughput becomes the constraint.

- **Sequential, single-flight — no wall-clock parallelism.**
  *Why:* the binding constraint is tokens-per-window, and parallelism multiplies
  interruption + merge-reconciliation cost, not throughput.
  *Impact:* one task at a time.
  *Revisit:* if a large batch of genuinely independent, low-conflict tasks appears with spare
  budget (HARNESS.md §6).

- **`--dangerously-skip-permissions` removes per-action guardrails.**
  *Why:* a headless loop has no human to answer prompts.
  *Impact:* no per-action confirmation; the gates + reviewable per-task branches are the
  backstop.
  *Revisit:* if a task class needs tighter control, gate it 🔒.

- **Empirical checks depend on live conditions.**
  *Why:* they verify clean operation against the real environment, not exhaustive coverage.
  *Impact:* a quiet environment may not exercise every path a task touches.
  *Revisit:* add targeted fixtures/flows for paths that matter but aren't naturally exercised.

- **Auto-tuned model routing & escalation trade attempts for cost.**
  *Why:* start cheap and climb only for tasks that actually need it (the policy picks the start
  tier from facets + the outcomes ledger).
  *Impact:* if it starts too weak, a task burns up to `MAX_ATTEMPTS` soft-failures (and their CI
  runs) per rung before escalating; the rung is in-memory per run, so a fresh run restarts at the
  policy's chosen start tier.
  *Revisit:* escalation is a safety net, not a substitute for atomic sizing — split tasks that keep
  climbing the ladder.

- **The loop pushes its own backlog-status commits straight to `main`.**
  *Why:* the loop is the sole writer of `TASKS.json` status; it records each `done`/`blocked`
  verdict + ledger row itself, tagged `[skip ci]`.
  *Impact:* `main`'s history carries one bookkeeping commit per completed/blocked task interleaved
  with the code commits.
  *Revisit:* acceptable for a solo/automated repo; if the history noise matters, squash on a
  release cadence.

- **A task's `do`/`doneWhen` are split across two files (JSON entry + `tasks/TNNN.md` spec).**
  *Why:* keeps `TASKS.json` scannable while giving each task room for a real spec.
  *Impact:* the JSON `spec` pointer and the `.md` can drift if hand-edited carelessly.
  *Revisit:* author through the add-to-backlog / convert-ideas skills, which write both together.

### In-place variant (only if you run `loop.in-place.sh`)

- **Autonomous pushes to a possibly-public `main`, guarded only by a path denylist.**
  *Why:* the in-place loop works directly in the primary checkout (needed when the build requires
  untracked/gitignored local state) and integrates by pushing `main` itself.
  *Impact:* a pre-push guard refuses commits touching sensitive paths (`.env`, `data/`, keys,
  `credentials.json`, …), but it's a denylist — a novel secret path it doesn't know about could ship.
  *Revisit:* extend `SENSITIVE_RE`/keep secrets out of the tree; prefer the worktree variant when the
  build doesn't need local state.

- **`LOOP_AUTORESET=1` can stash unrelated local work.**
  *Why:* it lets the in-place loop self-heal a dirty checkout (assumed to be orphaned partial work)
  instead of refusing to start.
  *Impact:* if the checkout is *also* used by hand, a dirty tree at startup gets stashed.
  *Revisit:* leave it OFF (default) unless the checkout is dedicated solely to the loop.

---

## Project

> Add your project's own trade-offs and limitations below as they arise.
