# The Ralph Harness — Difficulty Auto-Tuning + Verification: First-Principles Design Reference

This is the **canonical, from-first-principles** reference for the cost/correctness mechanism the
Ralph harness uses to build a backlog autonomously: difficulty auto-tuning, the audit-gated Definition
of Done, cold-only attempts, the structural gates, and the orchestration around them. It captures the
*why* and the *trade-offs*, not just the *what*. Use it to rebuild the mechanism from scratch, or to
check whether the implementation has drifted from intent.

This file is **dev-level** (not installed into scaffolded harnesses). The operational subset that
*ships* lives in `templates/docs/designs/difficulty-autotune.md` and `…/audit-verification.md`; this
doc is their superset + rationale. Deferred work is in `TODO.md`. Where this doc and the code disagree,
the code wins — fix one to match the other and note it.

> **One-paragraph summary.** Build each task with the *cheapest model that history says can do this
> kind of task*, starting cheap and escalating only on failure (difficulty auto-tuning). Because a
> cheap model is also the weakest judge of its own work, never let its self-judgement advance a task or
> feed the learning: gate "done" on objective, model-agnostic checks (file-scope, a required test, the
> local DoD, CI) and — sampled — an **independent stronger auditor** that reads the spec + diff and must
> say PASS. An audit/structural failure is just a normal failed attempt → it escalates, so a cheap
> model's false successes become honest "this cell needs a stronger tier" signal instead of poisoning
> the calibration. Every attempt runs **cold** so each outcome measures one tier's standalone ability.

---

## 0. The problem

An autonomous build loop (`claude -p`, fresh context, one task per iteration) wants two things that
pull against each other:

1. **Minimise cost** — most tasks are simple; paying for a top model on all of them is wasteful.
2. **Guarantee correctness** — the work is committed + pushed unattended; wrong work is expensive.

The naïve "always use the strong model" is correct but costly. "Always use the cheap model" is cheap
but unsafe — **and the unsafety is subtle**: the cheap model is *also the weakest at judging whether it
did the job correctly.* So you can't simply ask it "did you do it right?" and believe the answer. Every
decision below falls out of resolving that tension.

---

## 1. The autonomous loop (the substrate everything sits on)

- A **single sequential loop** (`loop.sh`) builds a `TASKS.json` backlog one fully-verified task at a
  time. Each task is built by a **fresh-context** `claude -p` invocation; all durable state lives in the
  repo (statuses in `TASKS.json`, per-task notes in `worklog/`, the work in git, the calibration in
  `outcomes.jsonl`). The conversation is disposable; the repo is the memory.
- **Two isolation variants**, same logic:
  - **worktree** (default): builds each task in a throwaway sibling git worktree off `origin/main` on a
    branch `tNNN`, integrates by fast-forwarding `main` on green CI. Can only see *tracked* files.
  - **in-place**: builds directly on `main` in the primary checkout (no worktree/branch). Chosen when
    the build/verify needs *untracked/gitignored* local state (private code in a public repo, local
    datasets, secrets-driven tests) that a clean worktree can't see. Safety model = git itself (every
    task is one commit; a bad one is a `git revert`) + a load-bearing pre-push guard.
- The harness is **sequential/single-flight**: at most one task in motion, so an interruption damages
  at most one task. This is the core lever that makes everything else simple.

---

## 2. Difficulty auto-tuning — the cost lever

**First principle:** don't pay for a strong model on a task a cheaper one can reliably do — and learn
that split from *evidence*, not a human guessing per task.

### 2.1 Facets — the generalisation key
A task is classified by **facets**, chosen from a controlled vocabulary in `facets.json`:
- **`layer`** (exactly one) — *where* the change lives (e.g. `ui`, `api`, `job`, `db`, `framework`,
  `harness`), inferred largely from the task's `scope` paths.
- **`workType`** (exactly one) — *what kind* of change (`style`, `bugfix`, `feature`, `migration`,
  `llm-prompt`, …).
- **`risk`** (zero or more) — danger flags (`touches-schema`, `full-stack`, `cross-cutting`,
  `touches-executor`).

*Why facets:* they're the **join key** that lets escalation history from past tasks predict the right
tier for a *new* task. Without a shared classification you'd have to learn each task cold.

### 2.2 The global tier ladder
One ordered ladder in `facets.json` (`.tiers.ladder`), cheapest → priciest, e.g.
`sonnet/low, sonnet/medium, sonnet/high, opus/medium, opus/high, opus/xhigh, opus/max`. Escalation
walks **up** this single ladder. There is **no per-task escalation ladder** any more.

### 2.3 Capture → calibrate → policy
- **Capture:** every *built* task appends one row to `outcomes.jsonl` (append-only, forward-only) —
  facets, the start + final tier, `succeededRung`, attempt counts, blocked/ok, and (added later) a
  `verification` tag. This is the **sole input** to calibration. Forward-only: it only fills as the
  loop runs; we never backfill or rewrite it.
- **Policy** (`policy.jq` + `pick_base`): for a task's `(layer × workType)` **cell**, pick the
  **cheapest ladder tier whose historical success rate ≥ `floor` (0.75) with ≥ `minN` (6) samples**;
  if the cell lacks data, fall back to the **cold-start floor**.
- **Escalation:** `MAX_ATTEMPTS` (2) soft failures on a rung → climb to the next rung; past the top
  rung → `failed:blocked` (surfaced for a human). The policy sets the *start* rung; escalation climbs
  from there.

### 2.4 Key decisions & trade-offs
- **Bias cheap.** Cold-start is the **cheapest** tier (`sonnet/low`, set in `harness.env`), not a
  conservative default. *Reason:* with the ladder as a safety net, starting cheap is recoverable (a
  failure just escalates) and *self-teaching* (it generates the very data calibration needs). This
  reversed the older "default to the strong model" rule. *Trade-off:* more early escalation churn on
  hard cells before the policy learns — accepted, because it's bounded (per-cell, transient) and the
  exploration is the point.
- **The calibration cell is `(layer × workType)` only.** `risk` is **not** part of the cell key —
  it's a cross-cutting modifier applied on top (below), not a third join dimension.
- **`risk` (as of v1.5.0) forces mandatory audit + clamps the starting rung.** `policy.jq` takes a
  `$risk` arg (the task's `facets.risk` array): AUDIT mode returns `1000` unconditionally when
  non-empty (bypassing the per-cell sampling decay); TIER mode clamps the eligible starting index
  to `>= 1` (never the cheapest rung), even if the cell's calibration would otherwise clear the
  floor at index 0. Escalation above that floor on real failure is unaffected.
- **`minN=6`, `floor=0.75`** — enough samples to trust a rate without being unreachable; a 75% bar to
  call a tier "reliable enough." Both live in `facets.json .policy`, tunable.
- **`difficultyHint` is advisory ONLY** — a human/LLM-readable taxonomy intuition on each facet value;
  the policy never reads it. Do not wire it into code.
- **Authoring goes through the `implementation-harness-add-to-backlog` skill** (single source of authoring logic:
  assigns facets, pairs chooser/review tasks, runs the poor-fit / layer-evolution gate). Floor even on
  a direct edit: every buildable task carries `facets`; `needs-human`/gated tasks are carved out (they
  never run the loop, so no facets, no calibration).
- **Layer vocabulary self-evolves** via a poor-fit gate: when authors can't fit a task to an existing
  `layer`, they log a misfit; past a threshold the skill proposes a re-clustering for the human to
  approve (and migrates the ledger so cells don't silently cold-start).

---

## 3. The validation problem (the heart of the session)

Difficulty auto-tuning only works if the **success/fail signal it learns from is true.** And that's
where the cheap-model-first strategy bites:

- **The failure mode is the *false success*.** A cheap model writes plausible code that compiles,
  passes existing tests, and builds — but doesn't satisfy the task's intent — and CI is green because
  nothing pins the new behaviour. The loop records a *success*, and the calibration learns "the cheap
  tier *can* do this cell." It can't.
- **False successes are far worse than false failures.** A failure is **self-correcting** (the ladder
  escalates). A false success is **silent and compounding** — it ships subtly-wrong work *and*
  permanently under-provisions that cell.
- **CI is a real, model-agnostic gate, but it's not enough** — it checks compile/test/build, not
  *intent*. The gap between "CI green" and "actually done" is where false successes live.

**The governing principle:** *the builder's own judgement must never be what advances a task or feeds
the ledger — only an objective signal may.* Spend verification effort on **catching false positives**,
not on re-checking the build.

**The recursion trap.** The obvious fix — "make the cheap model write a test that proves it's done" —
fails, because the *same* cheap model writes the test: a builder that misunderstands the task writes a
lenient test encoding its misunderstanding, then passes it. You've validated nothing.

**The resolution — front-load verification authorship to the strong planner.** The backlog is authored
by a *strong* model (Opus high). So the harness is structurally **strong at planning, cheap at
building.** Let the strong author write the **objective bar** (which files change, which test must
exist, runnable done-when) into the spec, and check the cheap builder against a bar **it did not
write.** That breaks the recursion. Everything in §4–§5 is an instance of this.

---

## 4. The audit-gated Definition of Done

The audit is the judgement-based half of the bar; §5 is the objective half. The audit is **part of the
Definition of Done — blocking, not asynchronous.**

### 4.1 The blocking audit
When a task is sampled (§4.4), a **fresh, independent** `claude -p` (NOT the builder, no shared
context) is given the task spec (`## Done when`) + the build diff and must answer **`PASS`/`FAIL`** on
the first line. PASS is required to mark the task done.

### 4.2 Why blocking, not async — three reasons (this flipped the original async design)
1. **The loop is already a gated, latency-tolerant pipeline** — it already waits minutes for CI.
   One more gate is marginal; blocking *fits* the architecture, async fought it.
2. **It keeps `main` and the ledger clean at the source.** Async ships bad work and reverts later
   (messy history; dependents may build on the bad commit). Blocking means nothing unverified is ever
   "done."
3. **It closes the calibration loop correctly (the decisive reason).** A *blocking* audit failure is
   just a **failed attempt** → cold retry → escalate, and the eventual success is recorded at the tier
   that genuinely passed. So a cheap tier's plausible-but-wrong result **escalates on it**, and the
   ledger learns "this cell needs a stronger tier" — the *correct* lesson. Blocking means the
   calibration only ever sees verified outcomes. *The audit becomes part of the DoD, which is fitting.*

### 4.3 No feedback to the builder
The audit's reasons go to a **separate log** (`worklog/<TASK>.audit.md`), **never** into the
builder-read worklog. *Reason:* the system measures "can tier T do this spec **cold**." Feeding the
auditor's reasons into a retry would measure "tier T **plus hints**" — a strictly easier task —
overstating the tier's standalone ability and re-introducing the false-success poison through a side
door. Each attempt is an independent cold measurement (and statistically, independent Bernoulli trials
of the tier).

### 4.4 Per-cell sampling that decays — the cost control
Auditing every task with a strong model would erode the cost win. So the audit is **sampled per
`(layer × workType)` cell, decaying as confidence grows**:
- **100%** until the cell has **`auditStartN` (3)** *audit-confirmed* successes;
- linear taper to a **`auditFloor` (10%)** floor reached at **`auditFloorN` (8)** confirmed.
- The probability is computed in `policy.jq` (dual-mode: a negative `auditCount` ⇒ tier-selection
  mode, ≥0 ⇒ per-mille audit probability) and sampled with `$RANDOM`.

Decisions & trade-offs:
- **Keyed on *audit-confirmed* successes only, never raw** — so the system can't talk itself into
  confidence on thin evidence (a cell that keeps audit-*failing* adds no confirmed successes, so it
  *stays* heavily audited — it hasn't earned reduced scrutiny).
- **Never decays to zero** — the 10% floor is a permanent drift spot-check.
- **Per-cell, not global wall-clock** — a transferable harness keeps meeting *new* cells (new project /
  layer) even when "mature"; tying decay to wall-clock would under-audit fresh cells.
- **Low thresholds (3 / 8), not high (6 / 18).** Real personal projects are sparse: ~5–6 tasks per
  cell. With high thresholds the decay would be decorative (cells never reach it). Consequence,
  accepted as *correct*: early on you audit almost everything, and rare cells stay audited basically
  forever — they've earned no trust. The decay pays off only on high-frequency cells.
- **Monotonic decay-on-confirmed** today — a burst of failures never *raises* the rate above 100%; it
  just refuses to lower it. (Raising on a fail-burst is a possible future refinement, not needed: the
  cell already self-corrects by escalating.)

### 4.5 Auditor tier = `max(opus-4.8/medium, builder tier)`
Floor of Opus-4.8/medium, rising to match the builder if it escalated above medium — so the auditor is
**never weaker than the work it checks.** Common case (cheap `sonnet` build) → opus-medium audits it
(strong + independent); rare escalated case (`opus/high` build) → auditor rises to `opus/high`. (The
"floor at the builder tier" is a `max`, not a `min` — a `min` would audit cheap work with an equally
cheap auditor, defeating the point.)

### 4.6 Verification-strength tag
Each `outcomes.jsonl` row carries `verification: "audited" | "ci-only"`. `audited` = passed the
blocking audit; `ci-only` = not sampled (cheap checks only). This lets calibration weight or filter by
how objectively a success was confirmed, and is what the §4.4 decay counts.

---

## 5. The cheap objective gates (structural checks) — run *before* the audit

**Principle:** cheap, deterministic, model-agnostic checks first, so the expensive audit only ever runs
on work that already clears the free gates. `structural_checks()` runs after the build commit, before
the audit. Any failure = a failed attempt (cold retry → escalate), same handling as a failed audit.

1. **Non-empty diff** — the builder actually changed something.
2. **`expectsTest`** (optional task field) — if `true`, a **test file must have changed** in the diff.
   The *authoring-time test contract*: the strong planner decides which tasks must be pinned by a test
   (`src/` daemon logic: yes; pure dashboard-visual / logging: no, since the project doesn't unit-test
   React — those are covered by build + visual checks + the audit). The spec's `## Done when` should
   say *what* the test must assert, so the cold builder writes a real test, not a gate-satisfier.
3. **`LOCAL_DOD`** (in-place only) — a configurable command (e.g. `npx tsc --noEmit && npm test`) run
   in the checkout as the cheap **CI proxy** *before* the audit, so a build that doesn't compile never
   reaches the paid auditor. (The worktree variant gets real branch CI before the audit instead.)
4. **The scope gate** — every file in the diff must be **within the task's declared `scope`** (exact
   path or under a scope directory). Two always-allowed exceptions: the task's own
   `.harness/worklog/…` and **test files**. Anything else outside scope = **scope creep → failed
   attempt.** This is the cheapest, most objective gate of all — pure file-path comparison.

### 5.1 The scope gate — decisions & trade-offs
- **It is the purest expression of "strong planner declares, cheap script verifies."** The planner
  lists the files the task should touch; a free script enforces the cheap builder stayed inside them.
  *It was designed in the original spec (§4.2 of `audit-verification.md`) but initially not built — a
  real implementation miss caught + fixed later in the session.*
- **Tests are allowlisted; docs are NOT.** *Reason:* the planner often can't name a brand-new test's
  filename, and `expectsTest` + the audit already govern tests — so tests get a free pass. Docs
  (`README`/`CLAUDE`) *are* predictable, so the planner must declare them in `scope`; an undeclared doc
  edit fails as creep. This makes `scope` a *binding contract* and keeps the planner honest.
- **Literal prefix match, not glob.** `[ "$f" = "$s" ] || [ "${f#"$s"/}" != "$f" ]` — quoted, so
  glob-special scope paths like Next.js `[name]` routes match literally. (`case` patterns would treat
  `[name]` as a character class — a bug avoided.)
- **`set -e`-safe** — verified standalone before insertion (nested while-read over heredocs; the
  test-grep is in an `if`, not a `&& continue`).
- **Implication accepted:** scope becomes binding, so each task's `scope` must list *every*
  production/doc file it touches. A backlog completeness pass is part of turning it on (verify
  commands that are *run* and gitignored `data/` are false positives — they never appear in the diff).

### 5.2 Feeding scope into the prompt (enforce *and* inform)
A hard gate the builder doesn't know about just burns attempts. So the build prompt **injects the
scope list as an explicit hard boundary** ("You may change ONLY these files: …; touching anything else
auto-fails") and reconciles docs-lockstep to "update only in-scope docs; `failed:blocked` if a needed
doc isn't scoped." Enforce + inform are a pair.

---

## 6. Cold-only attempts

**Every (re)attempt is fully cold:** no worklog carryover, no prior-attempt context, no audit feedback,
no partial-work resume. The build prompt is spec-only.

- *Reason:* each measured outcome must answer exactly "can this tier do this spec, **cold**?" — the
  signal the calibration depends on. Carryover would measure recovery, not capability.
- This **reverses the old "resume, don't restart" rule.** The worklog is still *written* (human
  observability) but never *read* by the builder.
- It makes **atomic task sizing load-bearing**: a task that can't be done in one cold pass is
  mis-sized → split it (a feature — it enforces atomicity rather than papering over it).
- **Infra interruptions (rate-limit / crash) also re-attempt COLD** (decision: *always cold*), not
  resume. *Reason:* a rate-limit is not a "retry after failure," but honoring "resume" cleanly isn't
  possible under cold-only anyway (a fresh `claude -p` has no memory without the worklog we removed),
  and re-running cold keeps every measured pass clean. *Trade-off:* re-work on interruption — accepted
  (rate-limits are infrequent; atomic tasks keep each redo small).
- Implementation: the loop `cold_reset`s to a clean `origin/main` before each attempt (in-place); the
  worktree variant tears down + rebuilds a fresh worktree per attempt (which also removed both of its
  resume vectors — a leftover crash branch, and RL-resume).

---

## 7. Orchestration — the loop is the sole orchestrator

The models are **stateless sub-processes the loop invokes for one step each.** Neither the builder nor
the auditor pushes-to-complete, watches CI, or marks anything done — **the loop owns all of it**
(pushes, the `gh` CI-watch, the `TASKS.json` status edit, the `outcomes.jsonl` row). The chain is
`loop → builder → (loop runs the gates, incl. invoking the auditor) → loop pushes / watches CI → loop
marks done`. The builder produces a diff; the auditor produces a verdict; the loop owns every gate,
push, and state write.

Per-variant placement (so nothing unverified reaches `main`):
- **Worktree:** build → commit → push *branch* (triggers CI on a branch — `main` untouched) → loop
  watches branch CI green → structural checks → audit → **only then** fast-forward `main`.
- **In-place:** build → commit locally → structural checks **+ local DoD** (the CI proxy) → audit →
  push `main` → watch real CI. On a structural/audit fail, reset the local commit before it's pushed,
  so the remote stays clean (consistent with in-place's git-is-the-safety-net model).

---

## 8. The two variants — where they legitimately differ

- **Status ownership.** In-place: the **loop** owns status (the builder must NOT edit `TASKS.json`; the
  loop sets it on green). Worktree: the **builder** sets status in its commit (the branch the loop
  fast-forwards). This difference is intentional to each isolation model.
- **Worktree done-protocol vs the scope gate (a live wrinkle, stopgap in place).** The worktree builder
  also edits `TASKS.json` (status), the `README` status row, and `LIMITATIONS.md` — none ever in a
  task's `scope`. The scope gate would false-fail every worktree task, so the worktree `structural_checks`
  **allowlists** those bookkeeping files. Loose but functional. The clean fix (`TODO.md` #2): align the
  worktree done-protocol to the in-place model (loop owns status) so the allowlist can be strict again.
- **Rate-limit backoff strategy.** local-jobs (in-place) uses exponential backoff and never exits;
  the plugin uses a fixed poll + exits after `RL_MAX_WAIT` for `supervise.sh` to relaunch. Both
  "pause + cold re-attempt"; a candidate for alignment (toward poll-and-exit).

---

## 9. Safety (learned from an incident this session)

**The incident:** a verification command ran the loop with a bogus task argument; `select_task` echoed
the bogus `FORCE_TASK` verbatim, the loop treated it as a task to build, ran `cold_reset`
(`git reset --hard origin/main`), and **destroyed a tree full of uncommitted work**, then committed +
pushed garbage. Root cause: an un-validated forced task id + a destructive cold-reset on a dirty tree.

**The two guards that make it impossible (independent of the arg-parsing path):**
1. **`select_task` refuses a `FORCE_TASK` that isn't a real task id** in `TASKS.json`.
2. **The in-place loop refuses to start on a dirty tree** — it cold-resets and would discard
   uncommitted work, so a non-clean checkout aborts the run.

**Operating lessons baked in:** never run the loop framework (it can `git reset --hard` + push) against
a tree with uncommitted work; verify loop changes with `bash -n` + standalone logic tests, never by
executing the loop; the first real run of any new gate should be a deliberate human `DRY_RUN` on a
clean tree.

---

## 10. Configuration & data shapes (the contract surface)

- **`facets.json`** — `facets` vocabulary (`layer`/`workType`/`risk` values, each with an advisory
  `difficultyHint`); `.tiers.ladder` (the global ladder); `.policy`:
  `floor` (0.75), `minN` (6), `auditStartN` (3), `auditFloorN` (8), `auditFloor` (0.10),
  `auditorModel` (`claude-opus-4-8`), `auditorEffort` (`medium`).
- **`harness.env`** — the **cold-start floor** (`MODEL`/`EFFORT` = `sonnet`/`low`), `MAX_ATTEMPTS` (2),
  `LOCAL_DOD`, CI knobs, rate-limit backoff.
- **Task schema** (one `TASKS.json` entry): `id`, `status` (shell-owned), `dependsOn`, `gate`
  (`null`|`gate`|`needs-human`), `tags`, `scope` (the structural contract), `verify`,
  `expectsTest` (bool), `facets` (buildable only), `spec` (path to the per-task MD), `design` (optional).
  **No** per-task `model`/`effort`/`escalation` (the policy owns difficulty).
- **Per-task spec MD** (`tasks/TNNN.md`, sections `## Do` / `## Done when`) — the task's *what* and
  *bar for done*, referenced by `spec`; the loop appends its full text to the build prompt. `## Done
  when` should be concrete/runnable (the authoring-time verification contract).
- **`outcomes.jsonl`** row: `id, ts, facets, scopeSize, startModel/Effort, finalModel/Effort,
  succeededRung, topRung, attemptsAtRung, totalSoftFails, blocked, reason, verification`. Append-only,
  forward-only, the sole calibration input.
- **The version-bump discipline (propagation).** Claude Code installs each plugin into a *versioned
  cache* and re-installs only when `version` changes. So **any change to a plugin's installed files
  MUST bump `plugin.json`** or consumers keep running the cached old version (this is exactly how the
  whole auto-tuning feature once sat unused at a stale version). Dev-only files (`TODO.md`, this
  `DESIGN.md`) aren't installed → no bump.

---

## 11. Open design questions (see `TODO.md`)

1. **Wire `risk` or drop it** — today it's captured + stored but read by nothing. Natural wiring:
   high-risk flags force-audit (skip the decay) and/or raise the cold-start floor.
2. **Reconcile the worktree done-protocol** so its scope gate can be strict (drop the
   `TASKS.json`/`README`/`LIMITATIONS` allowlist) instead of the current stopgap.
3. **The deeper open question (parked):** "done" still ultimately rests on the audit, which is itself a
   model. The mitigations (independent + ≥builder tier, sampled, CI/structural as ground truth, the
   verification tag) reduce but don't eliminate auditor fallibility. Candidate directions if revisited:
   weight outcomes by verification strength; occasional multi-auditor votes on high-stakes cells.

---

## 12. Checking for drift (invariants to verify against the code)

If you suspect the implementation has drifted from this design, these are the load-bearing invariants
and where they live:

- **Cell key is `(layer × workType)`** — `pick_base` + `audit_gate` read only `.facets.layer` /
  `.facets.workType`; nothing reads `.facets.risk`. (`policy.jq`, `loop*.sh`)
- **Audit is blocking, fails = a normal failed attempt** — `structural_checks`/`audit_gate` returning
  non-zero routes into the *existing* `bump`/escalation path, not a parallel one. (`loop*.sh` done) path)
- **Auditor tier = `max(opus-medium, builder)`** — `audit_gate` (`(( ai > bi )) && bi=$ai`).
- **Sampling decays on *audited* successes only, floored, never zero** — the count filters
  `verification=="audited"`; the curve is `100% → 10%` over `auditStartN → auditFloorN`. (`policy.jq`)
- **No audit feedback to the builder** — audit reasons go to `worklog/<id>.audit.md`, never the
  builder-read worklog/`.result`.
- **Every attempt is cold** — `cold_reset` / fresh worktree before each attempt; the prompt forbids
  reading prior state.
- **Scope is enforced** — `structural_checks` rejects any diff file outside `scope` ∪ {worklog, tests
  (+ worktree bookkeeping)}; the build prompt injects the scope list.
- **The two safety guards exist** — `FORCE_TASK` validation in `select_task`; dirty-tree refusal at
  loop start (in-place).
- **The loop is the sole writer of status + ledger + main** — the builder/auditor never push-to-
  complete or mark done.

A quick sanity sweep: the audit-probability smoke (`auditCount` 0/3/5/8/20 → `1000/1000/640/100/100`
per-mille) and `bash -n` on all loop variants.
