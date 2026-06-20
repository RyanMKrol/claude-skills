# HARNESS.md — the Ralph Loop autonomous build harness

> **In one line:** a single, **sequential** loop that builds a `TASKS.json` backlog
> **one fully-verified task at a time**, on a **pinned model**, with all memory in
> the repo — optimised to **waste as few tokens as possible when a run is
> interrupted**, and to never mark a task done until it is *empirically* done
> (builds, tests, CI green, behaviour observed).

This document is the source of truth for **how the project is built**, the same way
`README.md` is the source of truth for **what is currently implemented** and (if you
keep one) `PLAN.md`/design docs are the source of truth for **what you're building**.
If you want to change how autonomous runs work, **change this file first, then make
the scripts match it.** A harness change that isn't reflected here is a bug in the harness.

---

## 1. What the harness is

A **Ralph loop**: a shell loop that repeatedly invokes a **fresh-context, headless**
Claude (`claude -p`) that completes **exactly one** `TASKS.json` task per invocation and
records all durable state in the repository. The conversation is disposable; the repo is
the memory. Because nothing important lives in a context window, every invocation is cheap
to (re)start and interruption is survivable.

**Layers:**

| Layer | Role |
|---|---|
| `supervise.sh` | Foreground **heartbeat**. Re-runs the loop on a cadence aligned to the token-refresh window. Leave it in a terminal for days; Ctrl-C between cycles. |
| `loop.sh` | The **single global Ralph loop**. Pick next eligible task → run one `claude -p` → verify → integrate → repeat until done / blocked / capped. |
| `claude -p` worker | A fresh agent that does **one** task end-to-end against the hardened Definition of Done (§6). |
| `postflight.sh` | Zero-token, read-only **status board** of where the backlog stands. |

**It is *not*** your product designer (that's `PLAN.md` / design docs), your
coding-conventions rulebook (`CLAUDE.md` — every task still obeys it), or a controller for
anything irreversible (those live behind the 🔒/🚦 gates in §9; the harness never crosses
them on its own).

---

## 2. Design principles (the "why" behind every rule below)

1. **Durable state in the repo, not the conversation.** Statuses in `TASKS.json`, per-task
   memory in `worklog/`, the work itself in git. A fresh agent reconstructs everything it
   needs from disk.
2. **One task per iteration, fresh context.** No batching. Bounded scope per invocation
   keeps each unit inside a single model context window and keeps the re-orientation tax
   payable.
3. **Sequential, single-flight (§7).** At most **one** task is ever in motion, so an
   interruption can damage **at most one** task — the core lever for minimising wasted tokens.
4. **Resume, never restart.** An interrupted task is continued from its branch + worklog +
   working tree, never redone from scratch.
5. **Definition of Done is *empirical* (§6).** "Done" means it compiled, tests passed,
   **remote CI went green**, and — where the task asks for it — we **watched it actually
   run**. Not "the model believes it's done."
6. **Determinism where it's cheap; the model only where judgement is needed.** Sync,
   CI-watch, merge, and cleanup are plain shell (reliable, zero tokens). The model
   implements, fixes, reconciles, and *judges* behaviour.
7. **The human stays in the loop without babysitting it.** Runs are unattended
   (`--dangerously-skip-permissions`, §3), but the heartbeat cadence, the status board, and
   the review **gates** (🚦 / 🔒) keep a person in control of everything that matters.

---

## 3. The model — pinned, not inherited

Every headless invocation **explicitly pins** the model and effort. A bare `claude -p`
silently inherits whatever the CLI default is — an uncontrolled variable in the one place
you most want control. The backlog is sized to be achievable by a single context window of
the chosen model, so the harness must *guarantee* that model, not hope for it.

```sh
claude -p "<task prompt>" \
  --model claude-opus-4-8 \   # pin the FULL id (the alias `opus` drifts to "latest")
  --effort high \             # high reasoning, NOT max — quality without the max-effort cost
  --dangerously-skip-permissions
```

- **`--model claude-opus-4-8`** — the full name pins the version forever; the bare alias
  resolves to "latest" and will drift. Configure it in `scripts/harness.env` (`MODEL=`).
- **`--effort high`** (`low|medium|high|xhigh|max`). Pin **`high`** explicitly; deliberately
  **avoid `max`/`xhigh`** — the marginal quality isn't worth the token cost on a loop that
  runs for days. (`EFFORT=` in `harness.env`.)
- **`--dangerously-skip-permissions`** — deliberate. A headless loop has no human at the
  keyboard to answer permission prompts; the safety comes from the review gates and the
  bounded, reviewable per-task branches, not from per-action prompts.

Rationale for spending more per iteration: low-quality work that has to be redone is itself
a top source of churn. Getting the task *right the first time* is the cheaper path when
interruption/resume is the thing you're optimising against. (Zero-stakes helpers — the
status board, cleanup — use **no** model at all.)

### Planning vs building — where `max` effort lives

The loop **only ever builds**, always at `--effort high`; it never runs a planning pass. The
`Design:` field (§8.1) is an **optional** pointer to a fuller design/plan doc: if one exists
the build pass **reads it** before coding; if not, the agent works from the `Do:`/`Done-when:`
brief on its own judgement — a doc is **never required**. When you *do* want a task explored
up front, **you author that doc** — interactively, with Claude at `--effort max` — into
`docs/designs/TNNN-*.md`, and the high-effort build pass implements from it. So `max` effort
exists in the project but lives **out of band** (optional, human-driven), never in the loop.

---

## 4. Operating model — one iteration, end to end

```
supervise.sh (heartbeat)
  └─ loop.sh   ──  one loop only (a lock makes a 2nd invocation exit immediately)
       Decisions read from origin/main; every build runs in the loop's OWN sibling
       worktree (../<repo>-loop) — never the primary checkout anything else may be using.
       repeat until done / blocked / capped:
         1. SELECT (shell):  from origin/main, next eligible = first not-done task whose
                             Depends-on are all done; skip 🚦 gate / 🔒 needs-human / blocked.
                             a resumable in-progress `tNNN` branch wins. none → stop cleanly.
         2. PREP   (shell):  (re)create the isolation worktree on branch `tNNN` off origin/main
                             (reuse it in place when resuming an interrupted task).
         3. WORK  (claude):  one `claude -p` (pinned model/effort) IN that worktree: implement
                             only the outstanding delta in scope, pass the Definition of Done
                             (§6), update docs in lockstep, commit, push the branch. No merge.
         4. GATE  (shell):   watch the branch's GitHub CI run (`gh run watch`).
                             green → fast-forward main via push (never checks main out), then
                             tear down worktree + branch.  red → soft fail (agent fixes on resume).
         5. RECORD (shell):  refresh the status board; loop.
```

**Division of labour** — the spine is principle §2.6, "determinism where it's cheap, the
model only where judgement is needed":

- **Shell owns:** sync, eligibility selection, the **CI-watch + merge** gate, cleanup,
  caps/backoff, the status board. No tokens, fully reliable.
- **The model owns:** implementing the task, running the local DoD checks, **judging
  behaviour against real input** where the task asks, fixing a red CI run, reconciling, and
  writing the worklog.

**Token exhaustion is handled by construction:** when credits run out, `claude -p` simply
can't run; the loop backs off and the next heartbeat cycle resumes the *single* in-flight
task. There is never more than one task to recover.

---

## 5. Definition of Done — the merge gate

A task is **done** only when **all** of the following hold. The loop will **not** merge to
`main` until every check is green.

1. **Static + unit.** Your project's **format check, linter, and unit tests** all pass on a
   clean tree. *(Define the exact commands once here and mirror them verbatim in
   `.github/workflows/ci.yml` — CI is the authoritative gate, so anything not run in CI is
   not enforced.)* Example shapes:
   - Node: `npm run lint && npm test && npm run build`
   - Rust: `cargo fmt --all --check && cargo clippy --all-targets -- -D warnings && cargo test`
   - Python: `ruff format --check . && ruff check . && pytest`
   - Go: `gofmt -l . && go vet ./... && go test ./...`
2. **Integration / end-to-end tests.** The task's relevant integration tests are run when
   their preconditions are met. Tests that need credentials, funds, or external resources the
   agent doesn't have are **recorded as `failed:blocked` (needs-human), never silently
   skipped as "passed".**
3. **Empirical behaviour** *(any task whose `Verify:` field names a check — §8.1)*. Run the
   thing the task specifies (e.g. start the app against real input for a **bounded window**)
   and **observe** it behaves: it starts, does its job, no panics/errors, output reads sanely.
   Record the observation in `worklog/TNNN.md`. The bar is the behaviour the task names — not
   a higher one a quiet environment can't demonstrate.
4. **Remote CI is green.** Push the branch; the loop **watches the branch's GitHub Actions
   run** (`gh run watch`, the workflow named by `CI_WORKFLOW`) and merges **only on success**.
   A red run is a `failed:soft` → the model inspects `gh run view --log-failed`, fixes, repeats.
5. **Docs in lockstep.** In the **same commit**: the task's `TASKS.json` `status` set to `"done"`, the
   `README.md` status row updated, and any new trade-off added to `docs/LIMITATIONS.md`
   (`CLAUDE.md` golden rules 3 & 5).

Only when 1–5 hold does the task integrate. Anything short of that is a `failed:*` with a
worklog entry, never a `done`.

---

## 6. Sequential, single-flight — the deliberate non-parallelism

**Decision: one global loop over the whole dependency-ordered backlog, building one task at
a time.** No parallel tracks or waves. Each task is built in the loop's own *isolation*
worktree, and the loop is guarded by a lock (see **Isolation & concurrency** below). Only one
task branch exists at any moment.

**Why not parallel** (the evidence, so it isn't re-argued):

- **The token budget is shared, not multiplied.** Parallel agents draw on the *same* credit
  pool; concurrency doesn't grant more work per window — it just spreads the same budget
  across more **simultaneously-interruptible** units.
- **Interruption cost scales with concurrency.** When a window runs dry, every in-flight
  parallel agent dies mid-task → N partial branches, N dirty worktrees, maybe a mid-merge →
  **N resume taxes** next window. Single-flight pays **one**.
- **Merge reconciliation scales with concurrency.** Many tracks merging into `main`
  continuously forces every track to repeatedly re-absorb `main` and re-validate. In
  practice, parallel tracks accumulate dozens of "merge main / absorb main / resume note"
  commits — friction, not features. Sequential moves `main` only when *the loop* does, so
  cross-task reconciliation ≈ 0.

Parallel only wins with *idle* budget **and** genuinely independent work **and** a low
conflict rate. When the binding constraint is tokens-per-window, sequential is strictly less
wasteful. **Revisit** if that flips — a large batch of independent, low-conflict tasks with
spare budget — at which point bounded parallelism could be reintroduced behind this same DoD.

**Branch-per-task is kept even though only one runs at a time** — the branch is the unit
GitHub CI runs on (so the §5 CI gate has something to gate), it keeps `main` clean
(`CLAUDE.md` golden rule 1), and it gives clean rollback.

### Isolation & concurrency (why a worktree stays)

Sequential execution removes the *parallelism* reason for worktrees, but **not the
*isolation* reason** — the machine is shared. Other agents, a running app, or manual edits
may occupy the **primary checkout** at any moment, so the loop must never work there.
Therefore:

- **The loop reads its decisions from `origin/main`** (`git show origin/main:TASKS.json`), not
  from any working tree — so whatever is checked out anywhere is irrelevant to it.
- **Every task is built in the loop's own dedicated sibling worktree** (`../<repo>-loop`),
  created off `origin/main` per task (reused in place when resuming an interrupted one).
- **Integration fast-forwards `main` via push** (`git push origin tNNN:main`); the loop never
  checks `main` out, so it cannot collide with the primary checkout. Single-flight keeps this
  a clean fast-forward; if `main` moved under it the push is rejected and the task soft-fails
  so the next pass absorbs the change.
- **A concurrency lock** in the shared `.git` (`<repo>-loop.lock`, PID-stamped with stale
  reclamation) ensures only one `loop.sh` runs at once — a second invocation exits immediately
  rather than racing.

---

## 7. Failure handling & caps

- **Result vocabulary:** `done` · `failed:soft` (transient/partial — retry) ·
  `failed:blocked` (needs-human / unmet prerequisite — do **not** retry) · `waiting` (a dep
  isn't merged yet) · `idle` (no eligible task left). The worker writes exactly one of these
  to `worklog/.result` as its final action; the loop acts on it.
- **Caps:** `MAX_ATTEMPTS` per task (default 3) of `failed:soft` → then treated as
  `failed:blocked` for a human. A global `MAX_ITERS` and the heartbeat cadence bound total
  spend. Token exhaustion needs no special case (§4).
- **Stops cleanly for review** at every 🚦 gate and 🔒 needs-human task — the loop surfaces it
  on the status board and halts/moves on rather than spinning.

---

## 8. State & artifacts — where memory lives

| Artifact | Role |
|---|---|
| `TASKS.json` | Backlog + **statuses** + **per-task model** (source of truth for done/pending, dependency order, and which model/effort builds each task). |
| `worklog/TNNN.md` | Append-only **per-task memory**: every attempt, what passed/failed, what's left. **Read before every (re)attempt.** |
| `worklog/.result` | The loop's **last-iteration verdict** (one line). Git-ignored scratch. |
| git history + the single task branch | The work itself. At most one `tNNN` branch at a time, built in the isolation worktree. |
| `worklog/STATUS.md` | Zero-token **status board** written by `postflight.sh`. Git-ignored. |

### 8.1 — Task schema (the shape of a `TASKS.json` entry)

`TASKS.json` is a single JSON document: a `version`, a `defaults` object (the fallback model
rung + escalation ladder), and an ordered `tasks` array. **Order in the array is the
dependency walk order.** A `_doc` string at the top carries the human note (JSON has no
comments). One task object:

```jsonc
{
  "id": "T014",
  "title": "Replay harness (offline feed through the core module)",
  "status": "pending",                 // "pending" | "done"  — the ONLY status source
  "dependsOn": ["T009", "T013"],
  "gate": null,                         // null | "gate" | "needs-human"
  "scope": ["src/replay.*", "tests/fixtures/replay_*"],
  "design": "docs/designs/T014-replay.md",   // optional; null = build from do/doneWhen
  "verify": ["run-app"],               // optional empirical checks
  "do": "<the work, 1–3 sentences>",
  "doneWhen": "<task-specific acceptance criteria>",
  "model": "claude-sonnet-4-6",        // optional; per-task override of defaults.model
  "effort": "medium",                  // optional; per-task override of defaults.effort
  "escalation": [                      // optional; extra rungs tried after the primary fails
    { "model": "claude-opus-4-8", "effort": "high" }
  ],
  "tags": ["validation"]               // optional, freeform
}
```

| Field | Meaning |
|---|---|
| `id` | Task identifier, zero-padded, ≥ three digits (`T001`…`T999`). The branch is `tNNN`. |
| `title` | One-line human summary (shown on the status board). |
| `status` | `"pending"` or `"done"` — the **only** status source. Runtime failure/retry state lives in `worklog/` + `.result`, not here. The build pass sets `"done"` in the same commit as the work. |
| `dependsOn` | Array of task ids that must be **done + merged** before this task is eligible. |
| `gate` | `null`, `"gate"` (🚦 human reviews the deliverable before dependents proceed), or `"needs-human"` (🔒 one-time human step; recorded `failed:blocked`, never auto-done). The loop skips both during selection (§9). |
| `scope` | Files this task should touch — a hint that keeps diffs tight for the CI gate (not a hard lock; only one agent runs). |
| `design` | **Optional** path to a fuller design doc, or `null`. A path = the build pass **reads that doc** first; `null` = the agent builds from `do`/`doneWhen` on its own judgement. Never required. |
| `verify` | Optional array naming extra **empirical** checks (e.g. `"run-app"`, `"live-api"`) that drive the §5 Definition of Done. Empty = unit/integration + CI suffice. |
| `do` | The work, kept short. The deep version (when warranted) is the `design` doc. |
| `doneWhen` | The **task-specific** acceptance bar. The **universal** bar (format/lint/test, CI green, docs lockstep) lives once in §5 and is not repeated per task. |
| `model` / `effort` | **Optional** per-task override of `defaults.model` / `defaults.effort` — the **primary rung** the loop builds this task on. Omitted = inherit `defaults`. This is how a simple validation task runs on a cheaper model while coding/reflection tasks run on Opus (§3). |
| `escalation` | **Optional** ordered array of extra `{model, effort}` rungs tried, in order, **after** the primary rung fails `MAX_ATTEMPTS` times — the auto-escalation ladder (§3, §7). Omitted = inherit `defaults.escalation` (empty = no escalation; the loop stops for a human after the primary, today's behaviour). |
| `tags` | Optional freeform labels; the `add-to-backlog` skill uses them to suggest a model. |

The top-level `defaults` object holds `model`, `effort`, and `escalation` applied to any task
that doesn't override them. When design docs exist they live in **`docs/designs/TNNN-slug.md`**
and are written with Claude at `--effort max` (§3); the loop only ever *consumes* one — it
never requires or writes one.

---

## 9. Gates — the boundaries the loop will not cross

Some work must not happen autonomously. Two values of a task's `gate` field in `TASKS.json`
stop the loop:

- **🚦 Gate** (`gate: "gate"`) — the task's deliverable must be **reviewed by a human** before
  any dependent task proceeds. Use it where a downstream commitment rides on this result being
  right (an approach is validated, an interface is frozen, an experiment's data is trusted).
- **🔒 needs-human** (`gate: "needs-human"`) — the task needs a one-time human step the agent can't or shouldn't do
  (credentials, provisioning, anything spending real money or touching production). The agent
  prepares everything *around* it, then records `failed:blocked` and hands off.

The loop **skips** both kinds during selection and surfaces them on the status board under
"Needs you". It never marks either done on its own.

---

## 10. Invariants (must always hold)

1. Never commit directly to `main`; always a `tNNN` branch off **latest** `origin/main`.
2. One task per iteration. Never batch.
3. The model is **always pinned** (`--model`, `--effort`) — never inherited.
4. Never mark `done` with any §5 gate red (including a red or unobserved CI run).
5. Touch only the task's scope; update docs in the **same** commit.
6. **Resume**, never restart, interrupted work.
7. Never cross a 🚦 gate or 🔒 needs-human boundary autonomously.
8. At most **one** task branch exists at a time (single-flight).
9. The loop works **only** in its own isolation worktree and reads decisions from
   `origin/main`; it never touches the primary checkout, and only one `loop.sh` runs at a
   time (lock-guarded).

---

## 11. Adopting this harness in a project

1. **Copy** `scripts/`, `docs/HARNESS.md`, `CLAUDE.md`, `TASKS.json`, `.github/workflows/ci.yml`,
   `.gitignore`, and the `worklog/` dir into your repo (or start your repo from this one).
2. **Wire the Definition of Done.** Put your real format/lint/test/build commands into
   `.github/workflows/ci.yml` **and** describe them in §5 above. They must match.
3. **Set the knobs.** Edit `scripts/harness.env` (`MODEL`, `EFFORT`, caps, `CI_WORKFLOW`).
4. **Write the backlog.** Replace the example tasks in `TASKS.json` with your own atomic,
   dependency-ordered tasks (schema in §8.1). Mark gated work 🚦 / 🔒.
5. **Push `main` to GitHub** so the CI gate has somewhere to run. The loop integrates by
   pushing to `origin/main`, so a remote is required when `REQUIRE_CI=1`.
6. **Run it:** `chmod +x scripts/*.sh && scripts/supervise.sh` (or a single pass with
   `scripts/loop.sh`; preview the next pick with `DRY_RUN=1 scripts/loop.sh`).

---

## 12. Trade-offs & limitations (kept honest — mirror into `docs/LIMITATIONS.md`)

- **Hardened DoD makes each task longer.** Integration + empirical + CI-watch add wall-clock
  and tokens per task, raising the chance a single window can't finish one. Mitigation: keep
  tasks **atomic**; if a task can't fit a window, split it.
- **CI-green-before-merge adds minutes per task.** Acceptable precisely *because* we're
  sequential and not racing; it buys an always-green `main`.
- **We give up wall-clock parallelism.** Fine while the binding constraint is
  tokens-per-window; revisit if that flips (see §6).
- **Empirical checks depend on live conditions.** A quiet environment may not exercise every
  path; the check verifies clean operation, not exhaustive coverage.
- **`--dangerously-skip-permissions` means no per-action guardrail.** Accepted for headless
  runs; the gates + reviewable branches are the backstop.

---

*Change this file first, then make the scripts match it.*
