# CLAUDE.md — working conventions for this repo

This file defines how Claude should behave when making changes in this repository.
Follow these conventions on **every** task unless the user explicitly says otherwise in
the current conversation. They are the coding-conventions rulebook; the **build harness**
that drives autonomous runs is described in [`docs/HARNESS.md`](./docs/HARNESS.md).

## Project orientation

- **What it is / what you're building:** see `README.md` and (if present) `PLAN.md` or
  `docs/designs/`. `README.md` is the source of truth for **what is currently
  implemented** — read it first to understand the present state.
- **What's planned:** `TASKS.json` is the implementation backlog, executed one atomic task
  at a time by a **single sequential loop** (`scripts/loop.sh`; see
  [`docs/HARNESS.md`](./docs/HARNESS.md)).
- **How it's built:** [`docs/HARNESS.md`](./docs/HARNESS.md) is the authoritative design of
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
- Merge only when the change passes the Definition of Done ([`docs/HARNESS.md`](./docs/HARNESS.md) §5)
  and only when the work was asked for — don't merge speculative changes.

### 3. Every change updates the documentation

Treat docs as part of "done," not an afterthought. Keep docs in lockstep with the code **in
the same commit** — never as a follow-up. A task is **done when its branch is integrated into
`main`** (code + docs both updated). On every change:

- **`README.md`** — update the implementation-status section in the same commit so it always
  reflects what the code does. Flip a task's status row to ✅ in the commit that completes it.
- **`TASKS.json`** — in the same commit, set the task's `"status"` to `"done"`.
- **`PLAN.md` / design docs** — update only if the change alters the design or an
  architectural decision. Day-to-day implementation usually doesn't touch them.
- If a change introduces a convention or decision worth remembering, note it here in
  `CLAUDE.md`.

### 4. One atomic task at a time

- Keep each commit scoped to a single logical unit of work.
- If a task reveals additional needed work, prefer finishing the current task and committing
  the rest separately over expanding scope mid-task.

### 5. Every change records its trade-offs & limitations

- When a change introduces or reveals a design **trade-off**, **bottleneck**, or known
  **limitation**, add a row to [`docs/LIMITATIONS.md`](./docs/LIMITATIONS.md) **in the same
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
([`docs/HARNESS.md`](./docs/HARNESS.md) §6), which works directly in the primary checkout and shares
the live local DB / daemon — there a leaky test pollutes real state immediately.

## Standard workflow for a change

1. `git checkout main && git pull` — **always** sync `main` first, so the new branch is based
   on the latest work and never a stale local `main`. *(Under the harness the loop reads
   `origin/main` and works in an isolation worktree — you don't switch branches yourself.)*
2. Create a fresh branch off `main` (or, under the harness, work in the worktree/branch the
   loop already checked out for you).
3. Read `README.md` (current state) and the relevant `TASKS.json` entry.
4. Make the change, keeping it atomic and within the task's `Scope:`.
5. Update docs in the same commit: `README.md`, `TASKS.json`, `docs/LIMITATIONS.md` (any new
   trade-off, golden rule 5), and design docs / `CLAUDE.md` if applicable.
6. **Verify the Definition of Done** ([`docs/HARNESS.md`](./docs/HARNESS.md) §5): your
   project's format/lint/test/build all pass, integration/empirical checks where the task
   asks, docs in lockstep.
7. Commit on the branch and push. Don't merge by hand under the harness — the loop watches
   CI and integrates on green. Working manually, merge per golden rule 2 once green.

## Before you start a task — prerequisites & worklog

- **Read `worklog/TNNN.md` first** (if it exists) whenever you start or retry a task. It's
  the append-only memory across fresh agent invocations — prior attempts record what failed,
  why, and what's left. Don't repeat their dead ends.
- **Resume interrupted work — never restart it.** An attempt can be cut off mid-task (token
  limit, crash). Before coding, check for partial work: an existing `tNNN` branch,
  uncommitted changes, or `Scope:` files already present. If found, continue from there, then
  **reconcile the delta**: compare the actual working-tree state against the task's
  `Done-when:` and do *only* what's outstanding (trust the code over the worklog if they
  disagree) — don't redo finished work.
- **Verify prerequisites are real.** Each `Depends on:` task must be `done` **and actually
  merged into `main`**. Don't trust a status box — confirm the functions/types/modules you
  need actually exist and build. If a prereq is half-done, stop and finish/flag it rather
  than working around it.
- **Respect the gates.** Tasks marked **🚦 Gate** must have their deliverable reviewed by a
  human before downstream work proceeds; tasks marked **🔒 needs-human** need a one-time human
  step — prepare everything around it and record `failed:blocked`, never auto-complete it.
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
  [`docs/HARNESS.md`](./docs/HARNESS.md) §5 and mirror them verbatim in
  `.github/workflows/ci.yml`. CI is the authoritative gate.
- Before pushing, the code should pass that full suite locally — it mirrors CI exactly.
- Tasks marked **🔒 needs-human** require the user (credentials, provisioning, anything
  spending real money or touching production). Do not attempt the human-gated portion
  yourself; prepare everything around it and hand off.
