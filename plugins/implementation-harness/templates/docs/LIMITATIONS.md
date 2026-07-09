# LIMITATIONS.md — trade-offs, bottlenecks & known limitations

> **Add THIS project's limitations to the overlay, not here.** This file is plugin-owned and refreshed on
> upgrade — the rows below are the *harness's own* trade-offs. Record your project's limitations in
> `custom/docs/LIMITATIONS.md` (the overlay — upgrades never touch it). See `.harness/custom/CLAUDE.md`.

The single place to evaluate the design's compromises later **without re-deriving them from
the code**. Per `CLAUDE.md` golden rule 5, every change that introduces or reveals a
trade-off, bottleneck, or known limitation **adds a row** to `custom/docs/LIMITATIONS.md` in the same commit.

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

- **The loop can only ever be started by a human, never an agent.**
  *Why:* a real incident — an interactive session, asked to do something unrelated, started the
  loop itself.
  *Impact:* `supervise.sh`/`loop.sh` hard-refuse when `$CLAUDECODE` is set (invoked from inside
  any Claude Code Bash tool call) — intentional, no override.
  *Revisit:* n/a — this is a permanent, load-bearing safety invariant, not a trade-off to
  reconsider.

- **Empirical checks depend on live conditions.**
  *Why:* they verify clean operation against the real environment, not exhaustive coverage.
  *Impact:* a quiet environment may not exercise every path a task touches.
  *Revisit:* add targeted fixtures/flows for paths that matter but aren't naturally exercised.

- **Auto-tuned model routing & escalation trade attempts for cost.**
  *Why:* start cheap and climb only for tasks that actually need it (the policy picks the start
  tier from facets + the outcomes ledger).
  *Impact:* if it starts too weak, a task burns up to `MAX_ATTEMPTS` soft-failures (and their CI
  runs) per rung before escalating. The rung/attempt count is in-memory per run but survives most
  restarts via the `worklog/.current.json` heartbeat; it's only lost on a heartbeat older than
  `LOOP_HEARTBEAT_RESUME_MAX_AGE` (default ~6h), a task whose status changed underneath it, or
  `LOOP_IGNORE_HEARTBEAT=1` — those cases restart at the policy's chosen start tier.
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

### Field notes — traps learned operating this harness in production

Distilled from real incidents in the harnesses this design grew out of. The *mechanism* fixes are
already in the scripts; what's listed is the part that stays true for operators and maintainers.
(Log your own incidents in `.harness/CLAUDE.md` § *Known-but-deferred issues*.)

- **Ctrl-C between the code push and the status commit orphans the task.** The work is merged on
  `main` but the task is still `pending`, so the next run rebuilds it and the gates then fight the
  already-merged diff. After ANY manual interrupt, run the **loop-recover skill** before restarting
  the loop — that's exactly what it exists for.
- **Never recombine the `git add`s in `mark_done`/`block_task`/`record_outcome`.** They stage
  always-present files first and add `failures.jsonl` only `if [ -f … ]`, because a single `git add`
  that lists a missing file fails **atomically** — staging nothing — and the `status:"done"` commit
  silently never happens (this once orphaned five consecutive completed tasks). The split is
  load-bearing, not style.
- **A rapid string of task-completion pushes can trip your deploy webhook's own rate limit.** A
  Vercel Hobby project once had ~10 pushes land within an hour; deploys silently stopped for ~10h
  with no alert. That's why `PUSH_COOLDOWN_SECONDS` exists — set it if anything deploys off `main`.
- **UI false-successes dominate owner manual-fails.** Structurally-green, CI-green changes shipped
  invisible or mis-rendered UI (an element present in the DOM but not visible; a theme flicker that
  had to be manually failed four times). Visual verification only works if a human actually LOOKS at
  the captures — treat "the screenshot exists" as not verified.
- **Tests can encode the same bug as the code.** A data-migration task passed its own tests because
  the fixtures used the same wrong field names, then crashed on first live run. A task whose
  `Done when` only cites its own new tests is weaker evidence than one verified against real data or
  an independent audit.
- **Rate-limit detection (`RL_HARD_RE`/`RL_RE`) still regex-matches the CLI's English prose, not the
  structured `rate_limit_event` (`rate_limit_info: {status, resetsAt, rateLimitType, …}`) that
  `--output-format stream-json` also emits on every invocation.** `resetsAt` is a plain Unix
  timestamp — it would let `rl_reset_wait()` drop most of its fragile prose-parsing (absolute clock
  time, relative duration, ISO-8601, all hand-rolled regex) entirely. Not done yet because it needs
  its own dedicated verification against a REAL rate-limit-hit payload (this repo's testing only ever
  observed `"status":"allowed"`); revisit as a follow-up once that's practical to test safely.

---

## Project

> Add your project's own trade-offs and limitations below as they arise.
