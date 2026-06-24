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
4. **Every attempt is COLD — measure capability, not recovery.** Each (re)attempt builds the task
   from the spec alone (no worklog, no prior-attempt context, no audit feedback), so the outcome
   measures whether that model can do the task *in one cold pass* — the signal the difficulty
   calibration + audit gate depend on. The worklog is observability-only, never read by the builder. A
   task that can't be done cold in one pass is mis-sized → split it. (See `designs/audit-verification.md`.)
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
you most want control. Each task is sized to be achievable by a single context window of
**its chosen** model, so the harness must *guarantee* that model, not hope for it.

The pin is **per task**, but the loop's difficulty **policy** chooses it — not a hand-authored
field. It resolves to the policy's chosen tier for the task's facets (§8.1; the global
`.tiers.ladder` + escalation history), falling back to the cold-start floor — `harness.env`
`MODEL`/`EFFORT`. The loop reads that rung and passes it through:

```sh
claude -p "<task prompt>" \
  --model "<the task's model>" \   # pin the FULL id (the alias `opus` drifts to "latest")
  --effort "<the task's effort>" \ # low|medium|high|xhigh|max
  --dangerously-skip-permissions
```

- **`--model`** — always the FULL id (the bare alias resolves to "latest" and will drift).
  The cold-start floor is `claude-sonnet-4-6` (`MODEL=` in `harness.env`) — the cheapest tier;
  the policy climbs the global ladder from there as a facet cell's history warrants.
- **`--effort`** (`low|medium|high|xhigh|max`). Cold-start floor **`low`** (`EFFORT=` in
  `harness.env`); the policy raises it via the ladder, whose top rungs reach `xhigh`/`max` only
  for facet cells whose history proves they need it.
- **`--dangerously-skip-permissions`** — deliberate. A headless loop has no human at the
  keyboard to answer permission prompts; the safety comes from the review gates and the
  bounded, reviewable per-task branches, not from per-action prompts.

Rationale: spend the cheap model where the work is mechanical and the strong model where
judgement is needed — but the **policy learns** that split from escalation history per facet cell
rather than a human guessing it per task. Bias is toward cheap (start at the floor); the global
ladder is the safety net that climbs only the cells that actually fail there. (Zero-stakes
helpers — the status board, cleanup — use **no** model at all.)

### Escalation — climb to a stronger model on repeated failure

The loop climbs ONE global tier ladder (`facets.json → .tiers.ladder`) when a rung keeps failing.
The mechanism reuses the soft-failure cap (§7): after **`MAX_ATTEMPTS`** `failed:soft` attempts on
the current rung, the loop advances to the next ladder rung (logging
`escalating TNNN → rung N: <model>/<effort>`) and resets the per-rung counter. Only once the **top**
rung has also exhausted its attempts is the task treated as `failed:blocked` and surfaced for a
human. The policy sets the START rung per task (from its facets); escalation walks UP the ladder from
there — so a backlog *tries cheap first* and automatically climbs to a stronger model only for the
tasks that actually need it.

**Difficulty is auto-tuned (see `.harness/designs/difficulty-autotune.md`).** Rather than per-task
`escalation` ladders, the loop rides ONE global tier ladder (`facets.json → .tiers.ladder`) and a
policy (`.harness/policy.jq`) picks each task's START tier from its `(layer × work-type)` facet cell's
escalation history (the cheapest tier clearing `floor` with ≥ `minN` samples; else the authored
difficulty as a cold-start prior). Every built task's outcome is captured to `outcomes.jsonl` — the
sole, forward-only calibration input. With no authored per-task model/effort, the cold-start prior is
simply the cheapest tier (the `harness.env` floor); `needs-human` tasks are carved out entirely. Tasks
are classified with **facets** (not a guessed
difficulty) by the add-to-backlog skill, and the `layer` vocabulary self-evolves via a poor-fit gate.

> The current rung is tracked **in-memory per `loop.sh` run** (like the attempt counter): a
> fresh run after an interruption restarts the task at rung 0. Deriving the rung durably from
> the worklog's soft-failure count is a possible future hardening, not a guarantee today.

### Planning vs building — where `max` effort lives

The loop **only ever builds**, at the policy-chosen effort; it never runs a planning pass. The
`Design:` field (§8.1) is an **optional** pointer to a fuller design/plan doc: if one exists
the build pass **reads it** before coding; if not, the agent works from the task's spec
(`## Do` / `## Done when`) on its own judgement — a doc is **never required**. When you *do* want a task explored
up front, **you author that doc** — interactively, with Claude at `--effort max` — into
`.harness/designs/TNNN-*.md`, and the high-effort build pass implements from it. So `max` effort
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
5. **Structural + audit gate** *(see `designs/audit-verification.md`)*. Before marking done the loop
   also enforces **structural checks** (the diff touches the task's `scope`; if `expectsTest: true`, a
   test file changed) and — when the task is **sampled** (per-cell audit decay) — a **blocking audit**
   by a fresh stronger agent (`max(opus-medium, builder tier)`) verifying the diff against the spec's
   `## Done when`, which must return PASS. A structural/audit FAIL is a `failed:soft` → cold retry /
   escalate. Each outcome is logged to `outcomes.jsonl` tagged `audited`/`ci-only`.
6. **Docs in lockstep.** In the **same commit**: the task's `TASKS.json` `status` set to `"done"`, the
   `README.md` status row updated, and any new trade-off added to `.harness/LIMITATIONS.md`
   (`CLAUDE.md` golden rules 3 & 5).

Only when 1–6 hold does the task integrate. Anything short of that is a `failed:*` with a
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

### In-place variant (when the build needs untracked local state)

The worktree model above rests on one assumption: **everything the loop needs to build and
verify is committed to `origin/main`.** It reads `TASKS.json` from `origin/main` and builds in a
fresh worktree off `origin/main`, so it only ever sees *tracked* files. When the build or its
verification depends on **untracked or gitignored local state** — private code in a public repo,
local datasets/fixtures, secrets-driven tests — a clean worktree literally can't see it, and the
worktree model can't work. For those projects the harness ships an **in-place variant**
(`scripts/loop.in-place.sh`, installed as `.harness/loop.sh`), selected at scaffold time.

It differs from the worktree loop as follows:

- **Works directly on `main` in the primary checkout** — no sibling worktree, no per-task `tNNN`
  branches. So it *can* see the untracked local state the build needs.
- **Reads `TASKS.json` from the local working file**, not `origin/main`.
- **The shell owns task status.** The worker commits the task but does **not** edit `TASKS.json`;
  after CI is green the loop sets `status:"done"` itself (a `[skip ci]` commit) and pushes — and
  sweeps `worklog/` into that commit so a stray note can't dirty the tree.
- **Every attempt starts fresh (cold)** — the in-place loop discards any leftover working-tree
  changes before building, so no attempt ever resumes partial work (§2.4).

**Safety model.** Without worktree isolation, two things stand in for it: (1) every task is one
commit on `main`, so a bad one is a one-line `git revert`; and (2) a **load-bearing pre-push
guard** — before pushing, the loop refuses if any pending commit touches a sensitive/gitignored
path (`data/`, real `.env*`, `chrome-profile/`, `*.pem`/`*.key`/`*.p12`, `service-account*`,
`credentials.json`). The tracked `.env.example` template is explicitly allowed. The guard is
self-testable (`.harness/loop.sh --guard-selftest`) and a trip makes the loop **discard that commit,
block the task, and move on** (the sensitive path is never pushed; a human reviews the block). The
worker is therefore instructed to stage files **explicitly** (never `git add -A`).

**Trade-off.** The in-place loop works *on* the shared checkout, so it isn't safe to run while
other work happens there (unlike the worktree loop). Choose it only when the local-state
requirement forces it; prefer the worktree variant otherwise.

The in-place variant also adds **rate-limit auto-resume** (on a Claude usage limit it sleeps and
resumes the same task, not a soft failure) and honours the optional `INTEGRATE_HOOK` (a
deploy/restart command run after each task integrates, so the running product matches `main`).

---

## 7. Failure handling & caps

- **Result vocabulary:** `done` · `failed:soft` (transient/partial — retry) ·
  `failed:blocked` (needs-human / unmet prerequisite — do **not** retry) · `waiting` (a dep
  isn't merged yet) · `idle` (no eligible task left). The worker writes exactly one of these
  to `worklog/.result` as its final action; the loop acts on it.
- **Caps & escalation:** `MAX_ATTEMPTS` per **rung** (default 3) of `failed:soft` → the loop
  **escalates** to the next model in the task's `escalation` ladder (§3) and resets the
  counter; only after the **top** rung is exhausted is the task `failed:blocked`. (No ladder =
  one rung = straight to `failed:blocked` at the cap.) A global `MAX_ITERS` and the heartbeat
  cadence bound total spend.
- **One bad task never halts the loop.** A `failed:blocked` task — whether the agent reported it,
  the ladder was exhausted, or a pre-push guard tripped — is **recorded in its worklog and skipped**,
  and the loop moves on to the next eligible task (a human reviews blocked tasks later). A **red CI**
  is handled the same way: the loop **reverts the pushed commit** (restoring `main`) and soft-retries,
  blocking-and-moving-on only once the ladder is exhausted. The only hard stops are an empty/all-gated
  backlog (exit 0), `MAX_ITERS` (exit 4), or a prolonged usage limit (exit 5 → `supervise.sh`
  relaunches). So leaving the loop unattended for hours can't lose progress to a single failure.
- **Usage / session limits are not failures.** When `claude` reports a usage/session limit, the
  loop **polls every `RL_POLL` (default 15 min) and resumes the same task** — so it picks back up
  shortly after the quota resets rather than idling for hours on a coarse backoff. Only after
  `RL_MAX_WAIT` (~6h) still-limited does it exit (code 5); `supervise.sh` then relaunches after a
  short `RETRY_INTERVAL` instead of waiting out the full window.
- **Stops cleanly for review** at every 🚦 gate and 🔒 needs-human task — the loop surfaces it
  on the status board and halts/moves on rather than spinning.

---

## 8. State & artifacts — where memory lives

| Artifact | Role |
|---|---|
| `TASKS.json` | Backlog + **statuses** + **facets** (source of truth for done/pending, dependency order, and each task's difficulty-calibration key). Per-task `do`/`done-when` live in `tasks/TNNN.md` (the `spec` field); difficulty is auto-tuned, not authored. |
| `tasks/TNNN.md` | One per task — the task's spec (`## Do` / `## Done when`), referenced by its `spec` field and appended to the build prompt. |
| `worklog/TNNN.md` | Append-only **human/observability log**: every attempt, what passed/failed. **Never read by the builder** — every attempt is cold (§2.4). |
| `worklog/.result` | The loop's **last-iteration verdict** (one line). Git-ignored scratch. |
| git history + the single task branch | The work itself. At most one `tNNN` branch at a time, built in the isolation worktree. |
| `worklog/STATUS.md` | Zero-token **status board** written by `postflight.sh`. Git-ignored. |

### 8.1 — Task schema (the shape of a `TASKS.json` entry)

`TASKS.json` is a single JSON document: a `version` and an ordered `tasks` array. **Order in the array is the
dependency walk order** — and it is *load-bearing*: selection picks the **first** not-done,
non-gated, deps-satisfied task in **array order** (§4/§9). It is **not** id-sorted and **not** a
full topological sort — `dependsOn` only *blocks* a task until its deps are done, it does **not**
reorder the array. So **array position itself decides what runs first** among otherwise-eligible
tasks. Practical consequence: place **destructive / rename / migration / cleanup** tasks at the
**END** of `.tasks` (so everything that still references the old name/shape builds first), and
**append new tasks at the end** unless an earlier slot is deliberately intended. A `_doc` string at
the top carries the human note (JSON has no comments). One task object:

```jsonc
{
  "id": "T014",
  "title": "Replay harness (offline feed through the core module)",
  "status": "pending",                 // "pending" | "done"  — the ONLY status source
  "dependsOn": ["T009", "T013"],
  "gate": null,                         // null | "gate" | "needs-human"
  "scope": ["src/replay.*", "tests/fixtures/replay_*"],
  "design": ".harness/designs/T014-replay.md",   // optional; null = build from the spec alone
  "verify": ["run-app"],               // optional empirical checks
  "expectsTest": true,                 // optional; true → the loop requires a test file in the diff (structural gate)
  "spec": ".harness/tasks/T014.md",    // REQUIRED — the task's do/done-when (## Do / ## Done when), in its own MD file
  "facets": { "layer": "backend", "workType": "feature", "risk": [] },  // calibration key; OMIT for gated/needs-human tasks
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
| `scope` | Files this task should touch — now a **structural gate**: the loop requires the task's diff to touch these (and flags creep). Keep it accurate. |
| `expectsTest` | Optional boolean. `true` → the loop requires a **test file** to change in the diff (a structural check); say what the test must assert in `## Done when`. Set it for tasks whose correctness should be pinned by a test. |
| `design` | **Optional** path to a fuller design doc, or `null`. A path = the build pass **reads that doc** first; `null` = the agent builds from the `spec` on its own judgement. Never required. |
| `verify` | Optional array naming extra **empirical** checks (e.g. `"run-app"`, `"live-api"`) that drive the §6 Definition of Done. Empty = unit/integration + CI suffice. |
| `spec` | **Required** repo-relative path to the task's per-task Markdown spec (`.harness/tasks/TNNN.md`) — sections `## Do` (the work, kept short) and `## Done when` (the **task-specific** acceptance bar; the **universal** bar in §6 is not repeated). The loop appends its full text to the build prompt. `do`/`doneWhen` do **not** live in the JSON. |
| `facets` | The difficulty-calibration key for buildable tasks: `{ "layer", "workType", "risk": [...] }`, values drawn from `facets.json`. The policy picks the starting tier and escalates from it — this REPLACES per-task `model`/`effort`/`escalation` (a task carries none). **Omitted only for gated / needs-human tasks** (never calibrated). |
| `tags` | Optional freeform DESCRIPTIVE labels (feature area) — not the calibration key (that's `facets`). |

The cold-start `model`/`effort` floor lives in `harness.env` (the cheapest tier), NOT in `TASKS.json`;
a task carries no per-task model/effort/escalation — `facets` + the outcomes ledger drive difficulty.
When design docs exist they live in **`.harness/designs/TNNN-slug.md`**
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
3. The model is **always pinned per task** (`--model`, `--effort`) — never inherited; on
   repeated soft-failure the loop escalates up the task's ladder before stopping for a human.
4. Never mark `done` with any §5 gate red (including a red or unobserved CI run).
5. Touch only the task's scope; update docs in the **same** commit.
6. **Every attempt is cold** — never read prior worklogs or resume partial work (§2.4).
7. Never cross a 🚦 gate or 🔒 needs-human boundary autonomously.
8. At most **one** task branch exists at a time (single-flight).
9. The loop works **only** in its own isolation worktree and reads decisions from
   `origin/main`; it never touches the primary checkout, and only one `loop.sh` runs at a
   time (lock-guarded).

---

## 11. Adopting this harness in a project

1. **Copy** the self-contained **`.harness/`** folder (`loop.sh`, `supervise.sh`, `postflight.sh`,
   `harness.env`, `HARNESS.md`, `LIMITATIONS.md`, `facets.json`, `policy.jq`, `TASKS.json`,
   `CLAUDE.md`, `designs/`, `worklog/`) into your repo root, plus the repo-root `.github/workflows/ci.yml`,
   `CLAUDE.md`, and `.gitignore` (or start your repo from this one). Note the **two `CLAUDE.md`
   files**: the repo-root one (full project conventions, loaded for all work) and `.harness/CLAUDE.md`
   (the authoring mandate, loaded when working inside `.harness/`).
2. **Wire the Definition of Done.** Put your real format/lint/test/build commands into
   `.github/workflows/ci.yml` **and** describe them in §5 above. They must match.
3. **Set the knobs.** Edit `.harness/harness.env` (`MODEL`, `EFFORT`, caps, `CI_WORKFLOW`).
4. **Write the backlog.** Replace the example tasks in `TASKS.json` with your own atomic,
   dependency-ordered tasks (schema in §8.1). Mark gated work 🚦 / 🔒.
5. **Push `main` to GitHub** so the CI gate has somewhere to run. The loop integrates by
   pushing to `origin/main`, so a remote is required when `REQUIRE_CI=1`.
6. **Run it:** `chmod +x .harness/*.sh && .harness/supervise.sh` (or a single pass with
   `.harness/loop.sh`; preview the next pick with `DRY_RUN=1 .harness/loop.sh`).

---

## 12. Trade-offs & limitations (kept honest — mirror into `.harness/LIMITATIONS.md`)

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
- **Per-task model routing & escalation trade attempts for cost.** A task that starts on too
  weak a model burns up to `MAX_ATTEMPTS` soft-failures (and their CI runs) before escalating
  — so pick the starting rung realistically; escalation is a safety net, not a substitute for
  sizing. The current rung is tracked in-memory per `loop.sh` run (§3), so a fresh run after
  an interruption restarts the task at its cheapest rung.

---

*Change this file first, then make the scripts match it.*
