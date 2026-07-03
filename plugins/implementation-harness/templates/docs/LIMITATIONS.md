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

---

## Project

> Add your project's own trade-offs and limitations below as they arise.
