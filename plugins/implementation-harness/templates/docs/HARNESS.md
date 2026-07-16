# HARNESS.md — the Ralph Loop autonomous build harness

> **Customizing this file?** Don't edit it in place — it's plugin-owned and refreshed on upgrade. Put
> project-specific notes in `custom/docs/HARNESS.md` (the overlay — upgrades never touch it). See
> `.harness/custom/CLAUDE.md`.

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
| `claude -p` worker | A fresh agent that does **one** task end-to-end against the hardened Definition of Done (§5). |
| `postflight.sh` | Zero-token, read-only **status board** of where the backlog stands. |

**It is *not*** your product designer (that's `PLAN.md` / design docs), your
coding-conventions rulebook (`CLAUDE.md` — every task still obeys it), or a controller for
anything irreversible (those live behind the 🔒 needs-human gate in §9; the harness never crosses
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
5. **Definition of Done is *empirical* (§5).** "Done" means it compiled, tests passed,
   **remote CI went green**, and — where the task asks for it — we **watched it actually
   run**. Not "the model believes it's done."
6. **Determinism where it's cheap; the model only where judgement is needed.** Sync,
   CI-watch, merge, and cleanup are plain shell (reliable, zero tokens). The model
   implements, fixes, reconciles, and *judges* behaviour.
7. **The human stays in the loop without babysitting it.** Runs are unattended
   (`--dangerously-skip-permissions`, §3), but the heartbeat cadence, the status board, and
   the review **gate** (🔒 needs-human) keeps a person in control of everything that matters.

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
  The cold-start floor is `claude-sonnet-5` (`MODEL=` in `harness.env`) — the cheapest tier;
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

> **Keep the ladder short on purpose.** A doomed task BLOCKS to a human after at most
> `ladder_length × MAX_ATTEMPTS` attempts. The template ships a deliberately short **5-tier** ladder —
> `haiku` (no effort param), then `sonnet/low → medium → high`, then `opus/high` — so that's at most
> `5 × 2 = 10` cold attempts before a stuck task asks for help: if `opus/high` can't do it in two cold
> passes, a human glance is far cheaper than burning `opus/xhigh`/`max`. If you extend it (adding e.g.
> `opus/xhigh`/`max`), remember every extra rung is extra spend a *stuck* task grinds through before it
> ever asks for help — match the top rung to the hardest task you'd want built unsupervised, not to the
> strongest model available.

**Difficulty is auto-tuned (see `.harness/docs/designs/difficulty-autotune.md`).** Rather than per-task
`escalation` ladders, the loop rides ONE global tier ladder (`facets.json → .tiers.ladder`) and a
policy (`.harness/scripts/policy.jq`) picks each task's START tier from its `(layer × work-type)` facet cell's
escalation history (the cheapest tier clearing `floor` with ≥ `minN` samples; else the `harness.env`
`MODEL`/`EFFORT` floor as the cold-start prior). Every built task's outcome is captured to `outcomes.jsonl` —
the sole, forward-only calibration input. Facets are the ONLY per-task difficulty signal: a per-task
`model`/`effort` field is ignored by the loop, never an override; `needs-human` tasks are carved out entirely. Tasks
are classified with **facets** (not a guessed
difficulty) by the add-to-backlog skill, and the `layer` vocabulary self-evolves via a poor-fit gate.

> The current rung/attempt count is tracked in-memory per `loop.sh` run, but it also survives a
> process restart: the `worklog/.current.json` heartbeat is cleared only at a genuine terminal
> outcome (blocked / done / drained), never on a plain exit — so a leftover heartbeat at process
> start (e.g. after `supervise.sh` relaunches following a rate-limit or `MAX_ITERS` exit) is read
> back and resumes the SAME task's rung/attempts instead of cold-starting the ladder, as long as
> it's younger than `LOOP_HEARTBEAT_RESUME_MAX_AGE` (default ~6h) and the task is still pending.
> This restores only *scheduling metadata* (which tier to start the next cold attempt at) — it does
> **not** resume a partial build diff; every attempt still tears down and rebuilds from `origin/main`
> (or resets in-place), same as always. Set `LOOP_IGNORE_HEARTBEAT=1` for one run to force a clean,
> cold restart of the ladder regardless of a leftover heartbeat.

### Planning vs building — where `max` effort lives

The loop **only ever builds**, at the policy-chosen effort; it never runs a planning pass. The
`Design:` field (§8.1) is an **optional** pointer to a fuller design/plan doc: if one exists
the build pass **reads it** before coding; if not, the agent works from the task's spec
(`## Do` / `## Done when`) on its own judgement — a doc is **never required**. When you *do* want a task explored
up front, **you author that doc** — interactively, with Claude at `--effort max` — into
`.harness/docs/designs/TNNN-*.md`, and the high-effort build pass implements from it. So `max` effort
exists in the project but lives **out of band** (optional, human-driven), never in the loop.

Because the loop builds blind from the spec on the policy-chosen (often weaker) model, **clarification is
front-loaded into the authoring stage**, not the build. When ideas become tasks
(`/harness-convert-ideas`) or a failed task is reviewed
(`/harness-review-failed`), that is where a human confirms the **definition of done** and
any open decision — while a strong model and a person are both in the room — so the unattended build pass
inherits an unambiguous contract it can hit in one cold pass. Those planning skills deliberately bias
*toward* asking; the loop, having no human to ask, deliberately does not.

### Bumping the base model (migration runbook)

When a new model generation supersedes the one `config/facets.json`'s `.tiers.ladder` is pinned to,
migrate the ladder and BOTH ledgers together, in this order, so calibration survives the move
instead of silently cold-starting:

1. **Update the ladder.** Edit `config/facets.json → .tiers.ladder`, replacing each old model id
   with its successor at the equivalent effort rung (same rung COUNT and ORDER — don't add or
   remove rungs in the same pass, or the ledger migration in the next step can't map old indices to
   new ones cleanly).
2. **Migrate `ledgers/outcomes.jsonl`.** Every row's `startModel`/`finalModel` must be rewritten to
   the new ids at the SAME rung position — a plain `sed` substitution per old→new model-id pair
   across the whole file works, since the ladder positions didn't move. Do the same for
   `ledgers/failures.jsonl`'s `model` field (diagnostics only, but keep it consistent).
3. **Verify calibration survived.** Run `policy.jq` in tier-selection mode for a few real
   `(layer, work-type)` cells you know have history, before and after the migration, and confirm
   the chosen index is unchanged (same cheapest-tier-clearing-floor result) — a mismatch means a
   rung got mapped to the wrong new-model index in step 2.
4. **Update the cold-start floor** if the cheapest rung itself changed — in **both** places it is
   pinned: `config/harness.env` (`MODEL`/`EFFORT`) *and* the built-in fallback in the loop scripts
   (`MODEL="${MODEL:-…}"` near the top of `scripts/loop.sh` and `scripts/loop.in-place.sh`), so a run
   that doesn't source `harness.env` still floors to the new model. (The transient
   `worklog/.failures.buf` flush buffer needs no migration — it's gitignored and drained every
   terminal event.)
5. **Commit the ladder + both ledgers together**, so `git log` shows the migration as one atomic
   change rather than a period where the ladder and ledger disagree.

Skipping step 2 doesn't break anything catastrophically — a ledger row with an old model id simply
stops matching any ladder tier (`tidx()` returns `-1` and the row is dropped from calibration), so
the practical effect is silent, partial data loss: every cell's calibration quietly resets to its
cold-start prior instead of carrying forward what the harness had already learned.

### Inserting a new rung (as opposed to swapping one in place)

The runbook above covers **swapping** a model at a fixed ladder position — same rung count and order.
**Inserting** a brand-new rung (e.g. adding a cheaper tier-0, or a rung between two existing ones)
shifts every subsequent rung's index, but this needs **no ledger migration at all**: `tidx()` re-matches
a ledger row's `(startModel, startEffort)`/`(finalModel, finalEffort)` against the *current* ladder
fresh, every single time it runs — it never trusts a cached index. A historical row that resolved to
index 0 last month will simply resolve to its new (correct) index after the insertion, and the
success-rate math for that `(layer × work-type)` cell keeps working without any migration step.

What *does* go stale, cosmetically: each ledger row also stamps `succeededRung`/`topRung` — raw
integers recording the rung reached *at write time*. These are **diagnostic-only** — `policy.jq` never
reads them, and the dashboard's completed-task display already reads `finalModel`/`finalEffort`
instead. After an insertion, an old row's `succeededRung`/`topRung` may no longer match the *current*
ladder's position for that model/effort pair — e.g. a row written when `sonnet/low` was rung 0 will
still say `succeededRung: 0` even after a rung is inserted ahead of it. For the authoritative record of
what a task actually ran on, always read `startModel`/`startEffort`/`finalModel`/`finalEffort` — those
are permanent and never renumbered. No historical identity is ever lost; only the raw position label on
old rows can drift from the live ladder's current shape.

**Getting the new rung actually tried (`exploreProbabilityPM`).** Calibration-safe is not the same
as calibration-*live* — a newly inserted rung has zero samples on any cell that's already calibrated
to a pricier tier, so `pick_base()`'s normal "cheapest eligible tier" rule will never select it on
its own; it has no way to distinguish "unproven" from "proven bad." To actually get it tested on
established work, raise `.policy.exploreProbabilityPM` (per-mille, default `0`) in `config/facets.json`
— see `docs/designs/difficulty-autotune.md` §2a for the full mechanism. The
`harness-update-ladder` skill prompts for this after every insert.

**A rejected rung isn't stuck forever (`exploreCooldownN`).** If a probed rung fails its trial,
it isn't excluded permanently — task difficulty can drift over a project's life (a codebase
maturing, gaining conventions/helpers), and a rung that failed early on might succeed later.
`.policy.exploreCooldownN` (rows of *other* cell activity since the rung's last touch, default
`40`) controls how long a rejected rung stays quiet before it's offered a fresh batch of trials
again — a pure row-count check, not calendar time. See "Periodic recheck" in
`docs/designs/difficulty-autotune.md` §2a for the full mechanism, including how a resulting
promotion can itself quietly fall back if the rung starts failing for real later.

---

## 4. Operating model — one iteration, end to end

```
supervise.sh (heartbeat)
  └─ loop.sh   ──  one loop only (a lock makes a 2nd invocation exit immediately)
       Decisions read from origin/main; every build runs in the loop's OWN sibling
       worktree (../<repo>-loop) — never the primary checkout anything else may be using.
       repeat until done / blocked / capped:
         1. SELECT (shell):  from origin/main, next eligible = first not-done task whose
                             Depends-on are all done; skip 🔒 needs-human / blocked.
                             none → stop cleanly.
         2. PREP   (shell):  tear down any prior state + create a FRESH worktree on branch `tNNN`
                             off origin/main — every attempt is COLD (no resume of partial work).
         3. WORK  (claude):  one `claude -p` (policy-chosen model/effort) IN that worktree: build
                             the task FRESH from its spec in scope, pass the Definition of Done
                             (§5), commit ONE commit on `tNNN`. Do NOT push, do NOT merge — the
                             loop is the sole pusher.
         4. GATE  (shell):   run structural checks + LOCAL_DOD locally FIRST; on pass push `tNNN`
                             and watch its CI (`gh run watch`); on green run the sampled blocking
                             audit. all pass → fast-forward main via push (never checks main out),
                             tear down. any fail → tear down → COLD retry.
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
4. **Remote CI is green.** The **loop** pushes the branch (only after the local gate in item 5
   passes — the builder never pushes) and **watches its GitHub Actions run** (`gh run watch`, the
   workflow named by `CI_WORKFLOW`), merging **only on success**. A red run is a `failed:soft` → the
   loop tears the branch/worktree down for a fresh COLD retry (never a resume of the prior attempt).
5. **Structural + audit gate** *(see `designs/audit-verification.md`)*. Before marking done the loop
   also enforces **structural checks** (the diff touches the task's `scope`; if `expectsTest: true`, a
   test file changed — both the `scope` and the `expectsTest` requirement are injected into the build
   prompt, so the builder is *told* each up front, not just judged on it after; and, when the diff
   touches `.github/workflows/*.yml`, a local **`actionlint`** run — `LINT_WORKFLOW_FILES`,
   `ACTIONLINT_VERSION` — that catches workflow YAML which is valid YAML but invalid per GitHub Actions'
   own schema, before the push; best-effort, backed by the independent `lint-workflows.yml` CI job) and —
   when the task is **sampled** (per-cell audit decay) — a **blocking audit**
   by a fresh stronger agent (`max(opus-medium, builder tier)`) verifying the diff against the spec's
   `## Done when`, which must return PASS. A structural/audit FAIL is a `failed:soft` → cold retry /
   escalate. Each outcome is logged to `outcomes.jsonl` tagged `audited`/`ci-only`.
6. **Task status is the loop's to set — not the builder's.** The loop flips the task's `TASKS.json`
   `status` to `"done"` itself, in its own follow-up commit, once 1–5 hold (`CLAUDE.md` golden rule 3).
   The builder never sets status, and never updates the root `README.md` — that is maintainer-owned
   product documentation the loop never touches, not a per-task status log.

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
  torn down and re-created FRESH off `origin/main` on every attempt — cold, never reused (§2.4).
- **Integration fast-forwards `main` via push** (`git push origin tNNN:main`); the loop never
  checks `main` out, so it cannot collide with the primary checkout. Single-flight keeps this
  a clean fast-forward; if `main` moved under it the push is rejected and the task soft-fails
  so the next pass absorbs the change.
- **A concurrency lock** in the shared `.git` (`<repo>-loop.lock`, PID-stamped with stale
  reclamation) ensures only one `loop.sh` runs at once — a second invocation exits immediately
  rather than racing.
- **When the loop finishes** (backlog drained) it optionally leaves the **primary checkout on
  the latest `main`**, so your local copy reflects everything that just landed instead of sitting
  stale on an old commit or branch (`sync_primary_checkout`). This is the *only* time it touches the
  primary checkout, and it's safe + best-effort: it **skips a dirty tree** (never stashes or clobbers
  uncommitted work), **fast-forwards only** (never rewrites unpushed local commits), and is non-fatal.
  Set `SYNC_PRIMARY_ON_DONE=0` to keep the strict never-touch-the-primary-checkout behavior.

### In-place variant (when the build needs untracked local state)

The worktree model above rests on one assumption: **everything the loop needs to build and
verify is committed to `origin/main`.** It reads `TASKS.json` from `origin/main` and builds in a
fresh worktree off `origin/main`, so it only ever sees *tracked* files. When the build or its
verification depends on **untracked or gitignored local state** — private code in a public repo,
local datasets/fixtures, secrets-driven tests — a clean worktree literally can't see it, and the
worktree model can't work. For those projects the harness ships an **in-place variant**
(`scripts/loop.in-place.sh`, installed as `.harness/scripts/loop.sh`), selected at scaffold time.

It differs from the worktree loop as follows:

- **Works directly on `main` in the primary checkout** — no sibling worktree, no per-task `tNNN`
  branches. So it *can* see the untracked local state the build needs.
- **Reads `TASKS.json` from the local working file**, not `origin/main`.
- **Every attempt starts fresh (cold)** — the in-place loop discards any leftover working-tree
  changes before building, so no attempt ever resumes partial work (§2.4).

Both variants agree that **the shell owns task status** — the worker commits the task but does
**not** edit `TASKS.json`; only after the structural checks + audit gate pass does the loop itself
set `status:"done"` (a `[skip ci]` commit) and push. In-place does this directly on `main`,
sweeping `worklog/` into the same commit so a stray note can't dirty the tree; worktree does it via
a detached-worktree commit (`record_outcome`, mirroring how it already records the outcome ledger).

**Safety model.** Without worktree isolation, two things stand in for it: (1) every task is one
commit on `main`, so a bad one is a one-line `git revert`; and (2) a **load-bearing pre-push
guard** — before pushing, the loop refuses if any pending commit touches a sensitive/gitignored
path (`data/`, real `.env*`, `chrome-profile/`, `*.pem`/`*.key`/`*.p12`, `service-account*`,
`credentials.json`). The tracked `.env.example` template is explicitly allowed. The guard is
self-testable (`.harness/scripts/loop.sh --guard-selftest`) and a trip makes the loop **discard that commit,
block the task, and move on** (the sensitive path is never pushed; a human reviews the block). The
worker is therefore instructed to stage files **explicitly** (never `git add -A`).

**Trade-off.** The in-place loop works *on* the shared checkout, so it isn't safe to run while
other work happens there (unlike the worktree loop). Choose it only when the local-state
requirement forces it; prefer the worktree variant otherwise.

**Dirty-tree refusal (in-place only).** The in-place loop cold-resets the working tree
(`git reset --hard origin/main`) between every attempt, so it **always** hard-refuses to start if the
checkout is dirty (§9 incident) — it prints a loud banner listing the offending files and exits `3`,
and it **never** stashes, resets, or builds. Recovery is a deliberate human action (commit, stash, or
discard, then re-run); the loop will not decide it for you, so nothing depends on someone spotting a
buried log line. (`supervise.sh` treats that `exit 3` as a terminal stop rather than retrying on a
timer.) The worktree variant never needs this — it builds in a sibling worktree and never touches the
primary checkout.

**`PUSH_COOLDOWN_SECONDS` (optional, both variants, default 0/off).** Enforces a minimum
wall-clock gap between successful integration pushes to `main`, for projects whose deploy webhook
has its own rate limit that a rapid string of task-completion pushes can trip even though each
individual push is fine (`throttled_push()`, persisted in a gitignored-equivalent file under
`.git/`). Only the final integration push is throttled, not internal status/ledger bookkeeping
commits.

The in-place variant also adds **rate-limit handling** (on a Claude usage limit it sleeps and
re-attempts the same task COLD, not a soft failure) and honours the optional `INTEGRATE_HOOK` (a
deploy/restart command run after each task integrates, so the running product matches `main`).

---

## 7. Failure handling & caps

- **Result vocabulary:** `done` · `failed:soft` (transient/partial — retry) ·
  `failed:blocked` (needs-human / unmet prerequisite — do **not** retry) · `waiting` (a dep
  isn't merged yet) · `idle` (**this task's** Done-when is already met on main — nothing to build
  for it). The worker writes exactly one of these to `worklog/.result` as its final action; the
  loop acts on it. An `idle` is **per-task**, not a drained backlog: the loop reconciles that one
  task to `done` (its work reached main in a prior attempt but the status flip was lost) and
  **continues** — it does not end the run. The only clean stop-on-nothing-to-do is the
  backlog-drained exit (no eligible task left). A task that keeps reporting `idle` — its status
  won't persist — is **blocked** after 2, never spun on.
- **Caps & escalation:** `MAX_ATTEMPTS` per **rung** (default 2) of `failed:soft` → the loop
  **escalates** up the global tier ladder (the policy sets the start rung from the task's facets; §3)
  and resets the counter; only after the **top** rung is exhausted is the task `failed:blocked`. A
  global `MAX_ITERS` and the heartbeat cadence bound total spend.
- **One bad task never halts the loop.** A `failed:blocked` task — whether the agent reported it,
  the ladder was exhausted, or a pre-push guard tripped — is **recorded in its worklog and skipped**,
  and the loop moves on to the next eligible task (a human reviews blocked tasks later). A **red CI**
  is handled the same way: the loop **reverts the pushed commit** (restoring `main`) and soft-retries,
  blocking-and-moving-on only once the ladder is exhausted. The only hard stops are an empty/all-gated
  backlog (exit 0), `MAX_ITERS` (exit 4), or a prolonged usage limit (exit 5 → `supervise.sh`
  relaunches). So leaving the loop unattended for hours can't lose progress to a single failure.
- **Usage / session limits are not failures.** When `claude` reports a usage/session limit, the loop
  first **parses the reset time out of Claude's own message** — a clock time with zone (`resets 2:30pm
  (Europe/London)`), a relative duration (`in 42 minutes`), or an ISO timestamp — and **sleeps until
  then + `RL_BUFFER`** (capped at `RL_BACKOFF_MAX`), then RE-ATTEMPTS the same task COLD. If nothing
  parses, the build path **backs off exponentially** (`RL_BACKOFF_MIN` doubling to `RL_EXP_MAX`)
  rather than hammering a fixed poll; the audit path polls every `RL_POLL`. Every sleep prints a
  boxed banner with the wall-clock resume time, so an unattended overnight run is diagnosable from
  the log alone. Either way it picks back up shortly after the quota resets rather than idling for
  hours. Only after `RL_MAX_WAIT` (~6h) still-limited does it exit (code
  5); `supervise.sh` then relaunches after a short `RETRY_INTERVAL` instead of waiting out the full window.
- **Stops cleanly for review** at every 🔒 needs-human task — the loop surfaces it
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
| `ledgers/outcomes.jsonl` | One terminal row per built task — the **sole** input to difficulty calibration (§3). Append-only. |
| `ledgers/failures.jsonl` | One row per **failed attempt** (not per task) — diagnostics only, never read by calibration. Append-only. |
| `tracking/human-done.json`, `tracking/manual-fail.json`, `tracking/reviews.json` | Owner overlays — see §8.2. |

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
  "status": "pending",                 // "pending" | "done" | "blocked" | "failed" — the ONLY status source
  "dependsOn": ["T009", "T013"],
  "gate": null,                         // null | "needs-human"
  "scope": ["src/replay.*", "tests/fixtures/replay_*"],
  "design": ".harness/docs/designs/T014-replay.md",   // optional; null = build from the spec alone
  "verify": ["run-app"],               // optional empirical checks
  "expectsTest": true,                 // optional; true → the loop requires a test file in the diff (structural gate)
  "visualVerify": true,                // optional; true → force VISUAL_VERIFY_HOOK on any platform; false → suppress; omit → workType heuristic
  "ciSkipOk": true,                    // optional; true → the loop accepts a builder [skip ci] commit for THIS task; omit/false → structural fail if the builder tags one
  "spec": ".harness/tasks/T014.md",    // REQUIRED — the task's do/done-when (## Do / ## Done when), in its own MD file
  "facets": { "layer": "backend", "workType": "feature", "risk": [] },  // calibration key; OMIT for gated/needs-human tasks
  "tags": ["validation"]               // optional, freeform
}
```

| Field | Meaning |
|---|---|
| `id` | Task identifier, zero-padded, ≥ three digits (`T001`…`T999`). The branch is `tNNN`. |
| `title` | One-line human summary (shown on the status board). |
| `status` | `"pending"`, `"done"`, `"blocked"`, or `"failed"` — the **only** status source. Per-attempt retry state lives in `worklog/` + `.result`, not here. The LOOP (not the builder) sets `"done"`, in a follow-up commit, once the build clears the structural checks + the audit gate (§5). `"blocked"` is set by `block_task()` when a task exhausts the top ladder rung — a first-class value (not just a worklog marker), so `task_blocked()`/the dashboard see it directly; `task_blocked()` also falls back to a worklog `failed:blocked` grep for tasks blocked before this existed. `"failed"` is set only via the owner's `manual-fail.json` overlay overturning a false "done" (§8.2) — both are terminal; neither is ever auto-reopened by the loop. |
| `dependsOn` | Array of task ids that must be **done + merged** before this task is eligible. |
| `gate` | `null` (buildable) or `"needs-human"` (🔒 a one-time human step; recorded `failed:blocked`, never auto-done). The loop skips `needs-human` during selection (§9). To require a human to **review a deliverable before dependents proceed**, don't gate the work itself — author a separate `needs-human` review task that `dependsOn` it and point the dependents at the review task. |
| `scope` | **The files this task is allowed to touch — a binding contract, and one of the most consequential fields you author. Take real care getting it right.** It is a hard structural gate: the loop requires the diff to land inside `scope`, and the **first** file touched outside it now **blocks the task immediately** — one attempt, no retry, no model escalation (a wrong scope is a human fix, not something a stronger model recovers). So a scope error is not cheap: **too narrow silently dooms the task**; too wide defeats the guard that lets cheap models run unsupervised. Derive it deliberately from what `## Done when` actually requires. **Prefer a directory-level scope over an exhaustive file list** — a directory prefix (`src/feature/**`) that honestly covers where the work lives is far more robust than pre-guessing every individual file (which you usually can't), while still catching the real risk: a build wandering into an unrelated subsystem. Each entry is one of: an **exact path** (`src/auth/session.ts`); a **directory prefix** — a trailing `/`, `/**`, or `/*`, all meaning *everything under it, recursively* (`src/feature/**`); or a **single-level extension glob** (`dir/*.tsx` = any `.tsx` **directly** in `dir`, not nested). Anything else with a glob metacharacter (e.g. a mid-path `**` like `dir/**/*.ts`, or brace expansion) is **not** supported and is flagged by `check-task-scope.sh` at pre-loop-checkin — split it into a directory prefix or explicit paths. |
| `expectsTest` | Optional boolean. `true` → the loop requires a **test file** to change in the diff (a structural check); say what the test must assert in `## Done when`. Set it for tasks whose correctness should be pinned by a test. "Test file" is matched by built-in conventions (incl. Xcode/JVM CamelCase like `UITests/`, `FooTests.swift`) plus any project patterns in `custom/test-file-patterns.txt` (§8.3) — probe with `scripts/loop.sh --test-selftest <path>`. |
| `visualVerify` | Optional boolean. `true` → inject the `VISUAL_VERIFY_HOOK` "actually LOOK at the output" instruction into the builder + auditor prompt **regardless of facets/platform** (a native screen, a mobile simulator, a generated image). `false` → suppress it even for an auto-covered task. **Omit** to use the facets heuristic: auto-fires when `facets.workType` ∈ `VISUAL_VERIFY_WORKTYPES` (default `component style`) on any layer, OR `facets.layer` ∈ `VISUAL_VERIFY_LAYERS` (default `frontend`) unless the work-type is in `VISUAL_VERIFY_SKIP_WORKTYPES` (default `docs config logging`). Maybe-visual work (`bugfix`/`feature`/`migration` off-frontend) is set by the authoring skills, not auto. No-op if `VISUAL_VERIFY_HOOK` is unset. See `docs/designs/visual-verification.md`. |
| `ciSkipOk` | Optional boolean, **planner-only** — never set this because the builder asked for it or because a task is failing CI; it authorizes a `[skip ci]` commit message, it doesn't request one. `true` → this task is genuinely CI-irrelevant (pure docs/config, nothing a test suite would exercise), so the loop accepts a builder commit tagged `[skip ci]` and proceeds straight to the audit gate without waiting for a CI run. **Omit or `false`** (the default) → a structural check FAILS the attempt (`unauthorized-skip-ci`) if the builder's commit message contains `[skip ci]` — the builder cannot self-authorize skipping CI, only the field can (PRINCIPLES.md P2: no gate may be satisfiable by text the builder itself writes). Setting the field does not force a skip — the builder still needs to actually write `[skip ci]` for it to take effect. |
| `design` | **Optional** path to a fuller design doc, or `null`. A path = the build pass **reads that doc** first; `null` = the agent builds from the `spec` on its own judgement. Never required. |
| `verify` | Optional array naming extra **empirical** checks (e.g. `"run-app"`, `"live-api"`) that drive the §5 Definition of Done. Empty = unit/integration + CI suffice. |
| `spec` | **Required** repo-relative path to the task's per-task Markdown spec (`.harness/tasks/TNNN.md`) — a leading **`## Overview`** (one or two plain-language sentences: the "what & why, at a glance", read first), then `## Do` (the work, kept short) and `## Done when` (the **task-specific** acceptance bar; the **universal** bar in §5 is not repeated). The loop appends its full text to the build prompt. `do`/`doneWhen` do **not** live in the JSON. (`## Overview` is a later convention — specs authored before it are left as-is, no backfill.) |
| `facets` | The difficulty-calibration key for buildable tasks: `{ "layer", "workType", "risk": [...] }`, values drawn from `facets.json`. The policy picks the starting tier and escalates from it — this REPLACES per-task `model`/`effort`/`escalation` (a task carries none). **Omitted only for gated / needs-human tasks** (never calibrated). |
| `tags` | Optional freeform DESCRIPTIVE labels (feature area) — not the calibration key (that's `facets`). |

The cold-start `model`/`effort` floor lives in `harness.env` (the cheapest tier), NOT in `TASKS.json`;
a task carries no per-task model/effort/escalation — `facets` + the outcomes ledger drive difficulty.
When design docs exist they live in **`.harness/docs/designs/TNNN-slug.md`**
and are written with Claude at `--effort max` (§3); the loop only ever *consumes* one — it
never requires or writes one.

### 8.2 — Owner overlays (`tracking/*.json`)

Three small `{id: {...}}` JSON maps let a human correct or advance the backlog **without ever
hand-editing `TASKS.json`**: `human-done.json` (marks a `needs-human` task done),
`manual-fail.json` (overturns a `done` task as a false success — a caught bug the audit/CI missed),
and `reviews.json` (a purely cosmetic "I've checked this" flag the loop never reads). All three are
**committed**, **owner-written only** (via `scripts/mark-done.sh` / `mark-failed.sh` /
`mark-reviewed.sh`, or a dashboard shelling out to the same scripts), and **read-only from the
loop's perspective**. `reconcile_overlays()` promotes `human-done`/`manual-fail` into authoritative
`TASKS.json` status at the top of every iteration, so an overlay written by a separate process on
this same checkout takes effect on the loop's very next pass. A `manual-fail` entry also
retroactively corrects difficulty calibration **by subtracting at read time**, never by mutating the
append-only ledger — see `docs/designs/manual-fail-signal.md` for the full mechanism and rationale.
`reviews.json` is now also written automatically by `harness-review-failed` (for every
task it investigates, so a future sweep never re-investigates it) and by the dashboard's "Mark done"
action (a human completing a needs-human task themselves is itself a review) — both are just
additional callers of `mark-reviewed.sh`, not a change to the mechanism itself.

### 8.3 — Extending via `custom/` (lifecycle hooks + guard denylist)

`.harness/custom/` is the harness's single customization surface — the prose overlays (the pointer in each
doc) plus two **convention-based, opt-in** extension points the loop auto-discovers. Both are
back-compatible: absent → byte-identical stock behavior. Each ships a `.example` stub; **copy it to the real
filename to activate** (a shipped stub can never change behavior, and upgrades add-if-missing the `.example`
without touching your real file).

**Lifecycle hooks — `custom/hooks/on-<event>.sh`.** If present, the loop runs the matching script at that
event as a **child process** (never sourced — it cannot touch loop state), **non-fatal** (a nonzero exit is
logged and ignored), with `HARNESS_ROOT`, `HARNESS_DIR`, `HARNESS_MAIN_BRANCH` exported:

| Hook file | Fires when | Args (`$1 …`) |
|---|---|---|
| `on-drained.sh` | the loop finishes with nothing left to build (no eligible task) | `drained` |
| `on-exhausted.sh` | the loop stops WITHOUT draining | `max-iters` or `rate-limit` |
| `on-blocked.sh` | a task is blocked (needs-human / unmet prereq / guard-tripped) | task-id, reason |
| `on-integrated.sh` | a task successfully integrates into main | task-id, verification (`audited`/`ci-only`) |

A hook can fire **once per loop cycle** (e.g. `on-drained` on every supervise re-run while the backlog
stays empty), so it MUST be **cheap and idempotent** — gate real work on "did anything actually change?".
Hooks never fire on a prerequisite/config error exit. `on-integrated` fires *alongside* the `INTEGRATE_HOOK`
env command (harness.env): use `INTEGRATE_HOOK` for a plain restart/redeploy; use the file hook when you
want the task id / verification as arguments.

**Guard denylist — `custom/sensitive-paths.txt`.** Extra pre-push secret-guard patterns, one ERE fragment
per line (blank/`#` lines ignored), **OR-appended** to the built-in guard. **Append-only** — it can only
*tighten* the guard, never loosen it. If the combined regex won't compile, the file is ignored with a WARN
and the base guard stays fully active (a bad custom pattern can never wedge the loop or disable the guard).
Probe a path with `scripts/loop.sh --guard-selftest <path>` (prints `BLOCK`/`ALLOW`).

**Test-file patterns — `custom/test-file-patterns.txt`.** Extra patterns for "what counts as a test file",
used by the `expectsTest: true` gate and the test-file scope-creep exemption. One ERE fragment per line
(blank/`#` lines ignored), **OR-appended** to the built-in conventions (which stay active regardless; a bad
regex is ignored with a WARN). The built-ins already recognize `.test.`/`.spec.`/`_test.` names, `test_`/
`tests/` segments, AND CamelCase test dirs/files (`UITests/`, `FooTests.swift`, `BarTest.kt` — without
matching plain words like `latest/`); add lines here only for a convention they miss (e.g. `androidTest/`,
a top-level `e2e/`, `.feature`). Probe a path with `scripts/loop.sh --test-selftest <path>` (`TEST`/`NOT-TEST`).

**Visual-verification prompt snippets — `custom/visual-verify-build.md` / `custom/visual-verify-audit.md`.**
When the visual-verification block fires for a task (the `VISUAL_VERIFY_HOOK` is set AND the task opts in —
`visualVerify: true` or the facets heuristic), the loop **appends** the matching file's contents to the
generic block: `visual-verify-build.md` in the builder prompt, `visual-verify-audit.md` in the auditor
prompt. It's how a project injects its own richer discipline — exact capture commands, a living-fixtures
file to keep current, named flows to screenshot — without forking `loop.sh`. It only *appends* (the generic
baseline stays), only fires when the block already fires (not an independent trigger), and absent → no
output → identical to stock. Populate one or both.

**Build/audit prompt preambles — `custom/build-preamble.md` / `custom/audit-preamble.md`.** Standing,
always-applies project rules injected into **every** builder / auditor prompt (respectively) — e.g. "never
make live paid-API calls during verification; use cached fixtures + the scratch DB." Unlike the visual-verify
snippet (gated on the task opting into visual verification), a preamble is **unconditional**: present → it's
appended to every prompt of that kind; absent → no output → byte-identical. Append-only (augments the generic
instructions, never replaces them). Populate one or both.

**Dashboard title — `custom/dashboard-title.txt`.** An optional short project label the dashboard shows next
to its gear icon and in the browser tab, read by `dashboard/server.js` (not the loop). Blank lines and
`#`-comments are ignored; the first remaining line wins. Absent → the dashboard just shows "Harness" — useful
mainly when several harness dashboards are open at once and need to be told apart. (The dashboard's own
background-color picker, in the same header, is a client-only preference — saved per-browser via
`localStorage`, not a `custom/` file.)

Customize behavior or the guard by adding a `custom/` file — **never by editing `loop.sh`** (an inline edit
forfeits clean upgrades; see `custom/CLAUDE.md`).

---

## 9. Gates — the boundaries the loop will not cross

Some work must not happen autonomously. Two values of a task's `gate` field in `TASKS.json`
stop the loop:

- **🔒 needs-human** (`gate: "needs-human"`) — the task needs a one-time human step the agent can't or shouldn't do
  (credentials, provisioning, anything spending real money or touching production). The agent
  prepares everything *around* it, then records `failed:blocked` and hands off.

`gate` has exactly two values — `null` (buildable) and `"needs-human"`. There is deliberately **no
separate "review this before dependents proceed" gate**: a value the loop would never build and could
never mark done is a dead end. Express that need instead with a **paired review task** — keep the work
buildable, add a `needs-human` review task that `dependsOn` it (its `## Do` = "review X; if good, mark
done"), and make the downstream tasks `dependsOn` the *review* task. The human marking the review done
is exactly the "approve before dependents proceed" gate, and it fits the one mechanism the loop has.

The loop **skips** `needs-human` during selection and surfaces it on the status board under
"Needs you". It never marks it done on its own.

---

## 10. Invariants (must always hold)

1. Never commit directly to `main`; always a `tNNN` branch off **latest** `origin/main`.
2. One task per iteration. Never batch.
3. The model/effort is **always pinned explicitly** (`--model`, `--effort`) — never inherited; the
   policy picks the start tier from the task's facets, and on repeated soft-failure the loop
   escalates up the global ladder before stopping for a human.
4. Never mark `done` with any §5 gate red (including a red or unobserved CI run).
5. Touch only the task's scope. Never edit the root `README.md` (maintainer-owned) or set task
   status (the loop owns it).
6. **Every attempt is cold** — never read prior worklogs or resume partial work (§2.4).
7. Never cross a 🔒 needs-human boundary autonomously.
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
3. **Set the knobs.** Edit `.harness/config/harness.env` (`MODEL`, `EFFORT`, caps, `CI_WORKFLOW`).
4. **Write the backlog.** Replace the example tasks in `TASKS.json` with your own atomic,
   dependency-ordered tasks (schema in §8.1). Mark gated work 🔒 needs-human.
5. **Push `main` to GitHub** so the CI gate has somewhere to run. The loop integrates by
   pushing to `origin/main`, so a remote is required when `REQUIRE_CI=1`.
6. **Run it:** `chmod +x .harness/scripts/*.sh && .harness/scripts/supervise.sh` (or a single pass with
   `.harness/scripts/loop.sh`; preview the next pick with `DRY_RUN=1 .harness/scripts/loop.sh`). Run
   this yourself, from a real terminal — both scripts refuse to start if invoked from within a Claude
   Code session; see `harness-CLAUDE.md`.

---

## 12. Trade-offs & limitations (the harness's own, kept honest)

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
- **The loop can only ever be started by a human, never an agent.** `supervise.sh`/`loop.sh`
  hard-refuse when `$CLAUDECODE` is set (invoked from inside any Claude Code Bash tool call) —
  intentional, no override, since an agent that could bypass it could just as easily be told to. A
  real incident prompted this: an interactive session, asked to do something unrelated, started the
  loop itself.
- **Auto-tuned model routing & escalation trade attempts for cost.** The policy picks each task's
  start tier from its facets + the outcomes ledger; if it starts too weak, the task burns up to
  `MAX_ATTEMPTS` soft-failures (and their CI runs) per rung before escalating — escalation is a safety
  net, not a substitute for atomic sizing. The current rung/attempt count is tracked in-memory per
  `loop.sh` run but survives most restarts via the `worklog/.current.json` heartbeat (§3); it's only
  lost on a heartbeat older than `LOOP_HEARTBEAT_RESUME_MAX_AGE` (default ~6h), a task whose status
  changed underneath it, or `LOOP_IGNORE_HEARTBEAT=1` — those cases restart the task at the policy's
  chosen start tier as before.

---

*Change this file first, then make the scripts match it.*
