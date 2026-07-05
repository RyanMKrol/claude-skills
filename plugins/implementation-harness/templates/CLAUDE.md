# CLAUDE.md — working conventions for this repo

This file defines how Claude should behave when making changes in this repository.
Follow these conventions on **every** task unless the user explicitly says otherwise in
the current conversation. They are the coding-conventions rulebook; the **build harness**
that drives autonomous runs is described in [`.harness/docs/HARNESS.md`](./.harness/docs/HARNESS.md).

## Project orientation

- **What it is / what you're building:** see `README.md` and (if present) `PLAN.md` or
  `.harness/docs/designs/`. `README.md` is the source of truth for **what is currently
  implemented** — read it first to understand the present state.
- **What's planned:** `TASKS.json` is the implementation backlog, executed one atomic task
  at a time by a **single sequential loop** (`.harness/scripts/loop.sh`; see
  [`.harness/docs/HARNESS.md`](./.harness/docs/HARNESS.md)).
- **How it's built:** [`.harness/docs/HARNESS.md`](./.harness/docs/HARNESS.md) is the authoritative design of
  the autonomous build harness — the Ralph loop, its Definition of Done, and its gates.

## Golden rules

### 1. Every change happens on a branch

- Never commit directly to `main`. Always `git pull` (or `git fetch`) first, then create a
  fresh branch off the latest `main` for **each atomic task**. Branches are what keep the
  CI gate and clean rollback possible.
- Suggested branch naming: `tNNN` (e.g. `t014`) for backlog tasks — this is what the loop
  expects — or `<type>/<short-slug>` (e.g. `fix/reconnect`) for off-backlog work.
- Keep each branch scoped to one logical unit of work; don't bundle unrelated changes.

### 2. Merge it yourself — no pull requests

- This project **doesn't use pull requests**. When the work is complete and **green**,
  integrate the branch into `main` and push. Under the autonomous harness, the *loop* does
  this for you (it fast-forwards `main` on green CI); when working by hand:
  ```sh
  git checkout main && git pull          # sync
  git merge --no-ff <branch>             # integrate the task
  git push                               # publish main
  git branch -d <branch>                 # clean up (also delete remote if pushed)
  ```
- Merge only when the change passes the Definition of Done ([`.harness/docs/HARNESS.md`](./.harness/docs/HARNESS.md) §5)
  and only when the work was asked for — don't merge speculative changes.

### 3. Every change updates the documentation

Treat docs as part of "done," not an afterthought. Keep docs in lockstep with the code **in
the same commit** — never as a follow-up. A task is **done when its branch is integrated into
`main`** (code + docs both updated). On every change:

- **`README.md`** — update the implementation-status section in the same commit so it always
  reflects what the code does, IF you're working by hand (outside the harness). Under the
  autonomous loop (either isolation variant), the LOOP is the sole writer of
  `.harness/tracking/TASKS.json` `"status"` — it flips a task to `"done"` itself, in a follow-up
  commit, once the build clears the structural checks and the audit gate. Never set `"status"`
  yourself while working on a harness-driven task; doing so trips the scope gate.
- **`TASKS.json`** — if working BY HAND (no harness / no loop running), set the task's `"status"`
  to `"done"` in the same commit as the work, same as any other doc update.
- **`PLAN.md` / design docs** — update only if the change alters the design or an
  architectural decision. Day-to-day implementation usually doesn't touch them.
- If a change introduces a convention or decision worth remembering, note it here in
  `CLAUDE.md`.

### 4. One atomic task at a time

- Keep each commit scoped to a single logical unit of work.
- If a task reveals additional needed work, prefer finishing the current task and committing
  the rest separately over expanding scope mid-task.

### 4a. Commit + push as you go — uncommitted work is NOT durable here (non-negotiable)

The in-place loop can be run with **`LOOP_AUTORESET=1`**: if the working tree is dirty when a run
starts, it **auto-stashes everything and hard-resets to `origin/main`**. So any uncommitted work —
notably a `/implementation-harness-convert-ideas` sweep that just authored a batch of new tasks, or a
hand-edit to `TASKS.json` — can silently vanish into a stash the next time the loop starts. **Treat
"uncommitted" as "not durable."** When a discrete unit of work is done (a conversion sweep, a backlog
edit, a recovery), **commit and push it immediately**, don't leave it sitting in the tree across a
session. (The `mark-*.sh` and `consolidate-ideas.sh` tools already commit+push for you; the risk is
hand-edits and multi-step flows that don't.)

### 5. Every change records its trade-offs & limitations

- When a change introduces or reveals a design **trade-off**, **bottleneck**, or known
  **limitation**, add a row to [`.harness/docs/LIMITATIONS.md`](./.harness/docs/LIMITATIONS.md) **in the same
  commit** — what it is, *why* it was chosen, its **impact**, and *when to revisit*.
- That file is the single place to evaluate the design's compromises later without
  re-deriving them from the code. A capped scope, a hardcoded assumption, an "un-handled for
  now" — that's exactly what belongs there.

### 6. Tests never touch production state

A task's Definition-of-Done **test** run must execute against a **scratch / throwaway** resource —
a temp database, a fake or sandboxed endpoint, a tmp working dir — **never** the project's real
database, live services, or real data/output files. A test that mutates production state can
corrupt the running product, and the usual culprit is a stray *direct* test invocation
(`pytest path/to/x`, `node --test foo`, `cargo test x`) run outside the normal harness env.
**Build the guard into the code, not into discipline:** detect a test context from the environment
and **redirect to a scratch resource** (e.g. an `isTestEnv()` / `resolveXxxPath()` that refuses the
production default under tests). This matters most under the **in-place loop variant**
([`.harness/docs/HARNESS.md`](./.harness/docs/HARNESS.md) §6), which works directly in the primary checkout and shares
the live local DB / daemon — there a leaky test pollutes real state immediately.

### 7. Backlog tasks carry facets (difficulty auto-tuning)

Every BUILDABLE task you add to `TASKS.json` MUST carry a `"facets": { "layer": …, "workType": …,
"risk": [...] }` object, with values chosen ONLY from `facets.json`'s controlled vocabulary (use the
task's `scope` paths to pick the `layer`). The loop's policy reads facets to choose each task's
STARTING model/effort from escalation history; the cold-start prior is the `harness.env`
`MODEL`/`EFFORT` floor. **Never add per-task `model`/`effort` fields — the loop ignores them**
(facets are the only per-task difficulty signal). `needs-human` (gated) tasks are **carved out** —
they get NO facets. Author through the
add-to-backlog skill when it's available (it assigns facets + runs the poor-fit / layer-evolution
gate), but the rule holds even on a direct `TASKS.json` edit: a buildable task without facets gets
no auto-tuning, and the loop **pre-flight WARNs** about facet-less buildable tasks. This same
mandate is restated in **`.harness/CLAUDE.md`**, which loads whenever you work inside `.harness/`
(i.e. exactly when authoring `TASKS.json`), so the rule surfaces at the authoring moment. (See
[`.harness/docs/HARNESS.md`](./.harness/docs/HARNESS.md) and `.harness/docs/designs/difficulty-autotune.md`.)

## Standard workflow for a change

1. `git checkout main && git pull` — **always** sync `main` first, so the new branch is based
   on the latest work and never a stale local `main`. *(Under the harness the loop reads
   `origin/main` and works in an isolation worktree — you don't switch branches yourself.)*
2. Create a fresh branch off `main` (or, under the harness, work in the worktree/branch the
   loop already checked out for you).
3. Read `README.md` (current state) and the relevant `TASKS.json` entry.
4. Make the change, keeping it atomic and within the task's `Scope:`.
5. Update docs in the same commit: `README.md`, `TASKS.json`, `.harness/docs/LIMITATIONS.md` (any new
   trade-off, golden rule 5), and design docs / `CLAUDE.md` if applicable.
6. **Verify the Definition of Done** ([`.harness/docs/HARNESS.md`](./.harness/docs/HARNESS.md) §5): your
   project's format/lint/test/build all pass, integration/empirical checks where the task
   asks, docs in lockstep.
7. Commit on the branch and push. Don't merge by hand under the harness — the loop watches
   CI and integrates on green. Working manually, merge per golden rule 2 once green.

## Before you start a task — prerequisites & gates

- **Every attempt is fully COLD — do NOT read prior worklogs or resume partial work.** The harness
  measures whether a model can build the task *from the spec alone, in one cold pass* — that signal
  drives the difficulty calibration and the audit gate (see [`.harness/docs/designs/audit-verification.md`](./.harness/docs/designs/audit-verification.md)).
  So each attempt starts blank: build only from the task's `spec` (`## Do` / `## Done when`), `scope`,
  and `verify`. **Never** read `worklog/TNNN.md` as guidance and **never** continue a previous
  attempt's partial work — the worklog is append-only, **for humans/observability only**. If a task
  can't be done in one cold pass, it is **mis-sized and should be split, not resumed.**
- **Verify prerequisites are real.** Each `Depends on:` task must be `done` **and actually
  merged into `main`**. Don't trust a status box — confirm the functions/types/modules you
  need actually exist and build. If a prereq is half-done, stop and finish/flag it rather
  than working around it.
- **Respect the gate.** Tasks marked **🔒 needs-human** need a one-time human step — prepare
  everything around it and record `failed:blocked`, never auto-complete it. (To require review of a
  deliverable before dependents proceed, that's a paired `needs-human` review task — see HARNESS.md §9.)
- **Record outcomes in the worklog.** On finishing or failing, append a dated entry: what you
  did, checks run, and (on failure) `failed:soft` (transient/retryable) or `failed:blocked`
  (needs-human / unmet prereq — do not retry).

## Working alongside other agents

Single-flight means the loop moves `main` only when *it* does, so you rarely race. But the
machine is shared and `main` can still move under you (another agent, a manual merge). If your
fast-forward to `main` is rejected, or `git merge origin/main` reports conflicts — **resolve
them, don't abandon the task:**

1. **Resolve on your own branch** (`git fetch origin && git merge origin/main`), preserving
   **both sides' intent** — union docs/status rows (keep every task's ✅), union dependency /
   manifest lines, and *integrate* (never discard) code changes. Read the other commit's
   `TASKS.json` spec + `worklog/` to understand what it was doing.
2. **Re-run the full Definition of Done** on the merged result. A resolution that builds but
   fails a test — yours *or* theirs — is not done. For lockfile conflicts, resolve the
   manifest first, then regenerate a consistent lock.
3. **Re-validate your own task still holds** on the merged code before you push.
4. **Be discoverable.** Clear `TNNN: <summary>` commit message, and commit your
   `worklog/TNNN.md` so the next agent can read your intent.

## Tooling notes

- Define your stack's exact format/lint/test/build commands once in
  [`.harness/docs/HARNESS.md`](./.harness/docs/HARNESS.md) §5 and mirror them verbatim in
  `.github/workflows/ci.yml`. CI is the authoritative gate.
- Before pushing, the code should pass that full suite locally — it mirrors CI exactly.
- Tasks marked **🔒 needs-human** require the user (credentials, provisioning, anything
  spending real money or touching production). Do not attempt the human-gated portion
  yourself; prepare everything around it and hand off.
