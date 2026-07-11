# Implementation Harness

> **Customizing?** Put project-specific notes in `custom/README.md` (the overlay — upgrades never touch
> it), not in this plugin-owned file. See `.harness/custom/CLAUDE.md`.

A generic **autonomous implementation harness**: a single, sequential shell loop that builds a
`TASKS.json` backlog **one fully-verified task at a time**, using a fresh-context headless
Claude (`claude -p`) per task, with **all durable memory in the repo**. It's optimised to
**waste as few tokens as possible when a run is interrupted**, and to never mark a task done
until it is *empirically* done — it builds, tests pass, remote CI is green, and (where the
task asks) the thing was observed actually running.

It is language- and project-agnostic. You bring a `TASKS.json` backlog and a CI workflow that
encodes your Definition of Done; the loop does the rest.

> **Full design:** [`docs/HARNESS.md`](./docs/HARNESS.md) is the source of truth for how the
> loop works and why. This README is the quick start.

## The idea in one picture

```
supervise.sh (heartbeat, runs for days)
  └─ loop.sh   ── one task at a time, in its own isolation worktree:
        SELECT  next eligible task from origin/main (deps met, not gated)
        WORK    one `claude -p` builds it, runs the Definition of Done, pushes a branch
        GATE    watch GitHub CI on that branch → green? fast-forward main : fix on resume
        RECORD  refresh the zero-token status board, repeat
```

The conversation is disposable; the repo is the memory. Statuses live in `TASKS.json`,
per-task history in `worklog/TNNN.md`, the work in git. Nothing important lives in a context
window, so every invocation is cheap to (re)start and an interruption is survivable.

## How you operate this harness

Once the harness is installed (this `.harness/` folder is here), day-to-day use is a loop:
**capture ideas as they occur → convert a batch into tasks → check the backlog is ready → run the
loop → review whatever failed → repeat.** Each step is a scaffolded slash-command in this project
(invoke bare, e.g. `/implementation-harness-capture-idea`), except the loop itself, which **you**
start from a real terminal.

```mermaid
flowchart TD
    A[💡 capture-idea<br/>anytime an idea strikes] --> B[🔄 convert-ideas<br/>batch the inbox into tasks]
    B --> C{✅ pre-loop-checkin<br/>GO / NO-GO}
    C -->|scope WARNs| D[🔧 fix-scope-gaps]
    D --> C
    C -->|GO| E[▶ scripts/supervise.sh<br/>the autonomous loop, started by a human]
    E -->|task failed / blocked| F[🩺 review-failed<br/>author better follow-ups]
    F --> C

    classDef human fill:#2d333b,stroke:#adbac7,color:#adbac7;
    class A,B,C,D,F human;
```

1. **`/implementation-harness-capture-idea <idea>`** — zero-ceremony. Appends one row to
   `tracking/IDEAS.jsonl` and stops. No interview, no `TASKS.json` write — it deliberately defers
   every question to the conversion sweep, so capture never breaks your flow.
2. **`/implementation-harness-convert-ideas`** — once a batch has accrued. Sweeps the **whole**
   `tracking/IDEAS.jsonl` inbox: dedupes, shapes each idea/cluster into atomic tasks, batches genuine
   questions back to you (always confirming the definition of done), then runs the locked
   `scripts/consolidate-ideas.sh` pass — allocating real ids, writing each `tasks/TNNN.md` spec,
   appending to `tracking/TASKS.json`, and clearing the converted rows.
3. **`/implementation-harness-pre-loop-checkin`** — before every unattended run. A strictly
   **read-only** GO/NO-GO over `tracking/TASKS.json`: needs-human blockers, session hygiene, dependency
   short-circuits, per-task spec/scope/facet quality. It changes nothing.
4. **(optional) `/implementation-harness-fix-scope-gaps`** — if the check-in's scope check WARNs, it
   **offers this** right there. It judges each warning real-gap vs false-positive against the spec's
   prose and auto-applies the confident real gaps to each task's `scope` (asking only on ambiguity).
5. **`scripts/supervise.sh`** — **you** start it, from a real terminal. It re-runs `scripts/loop.sh`
   on a heartbeat for days; `loop.sh` builds one fully-verified task at a time, cheapest-tier-first
   with auto-escalation, gated on green GitHub CI. `supervise.sh`/`loop.sh` hard-refuse to run from
   inside a Claude Code session, so an agent can't start an unattended git-mutating loop. Preview
   with `DRY_RUN=1 scripts/loop.sh`; see [Quick start](#quick-start) for the exact commands.
6. **`/implementation-harness-review-failed`** — when the loop leaves tasks `failed` or `blocked`.
   Investigates each root cause and authors a demonstrably-better follow-up (never a blind retry);
   the follow-ups re-enter the cycle at step 3.

**Or run the whole follow-up as one command:** `/implementation-harness-post-run` chains steps
6 → 2 → 3 → 4 in order (review-failed if anything failed, convert-ideas if the inbox has rows,
pre-loop-checkin always, fix-scope-gaps on WARNs), running each constituent skill in full — every
question included — and ending at the GO/NO-GO verdict. It never starts the loop (step 5 stays
yours, from a real terminal).

Off the happy path: `/implementation-harness-add-to-backlog` (author tasks directly, skipping the
ideas inbox), `/implementation-harness-loop-recover` (clean up after a manual Ctrl-C interrupt), and
`/implementation-harness-update-ladder` (change the difficulty tier ladder). The
[ideas → tasks pipeline](#ideas--tasks-pipeline-optional) section below has the capture/convert
detail.

## Core principles

1. **Durable state in the repo, not the conversation.**
2. **One task per iteration, fresh context.** No batching.
3. **Sequential, single-flight.** At most one task in motion, so an interruption damages at
   most one task — the core lever for not wasting tokens.
4. **Every attempt is cold.** No attempt reads a prior worklog or resumes partial work — each one
   measures a fresh pass from the spec alone, which is what makes the difficulty auto-tuning and
   audit signals meaningful. An interruption just means the next attempt starts over, cleanly.
5. **The Definition of Done is empirical** — compiled, tested, CI green, behaviour observed.
6. **Determinism where it's cheap; the model only where judgement is needed.** Sync, CI-watch,
   merge, cleanup are plain shell; the model implements, fixes, and judges.
7. **The human stays in control without babysitting** — a heartbeat cadence, a status board,
   and the 🔒 needs-human review gate.

See [`docs/HARNESS.md`](./docs/HARNESS.md) for the full rationale (including why it's
deliberately *not* parallel).

## What's in here

| Path | Role |
|---|---|
| `scripts/loop.sh` | The single sequential loop: select → build → CI-gate → integrate. |
| `scripts/supervise.sh` | Foreground heartbeat that re-runs `loop.sh` on a cadence. |
| `scripts/postflight.sh` | Zero-token, read-only status board (`worklog/STATUS.md`). |
| `scripts/repo-lock.sh` | Shared mkdir-based lock, sourced by the loop and owner CLIs (`mark-*.sh`). |
| `scripts/policy.jq` | Difficulty auto-tuning policy: tier selection + audit sampling. |
| `scripts/mark-done.sh` / `mark-failed.sh` / `mark-reviewed.sh` | Owner CLIs that write the `tracking/` overlays (also what the dashboard's buttons call). |
| `scripts/check-task-scope.sh` | Advisory linter: warns when a task's spec mentions a file outside its declared `scope`. |
| `scripts/consolidate-ideas.sh` / `.mjs` | The locked consolidation pass of the ideas→tasks pipeline — see below. |
| `dashboard/server.js` | Portable, dependency-free backlog viewer (`node dashboard/server.js`) — see below. |
| `config/harness.env` | Optional config: model, effort, caps, CI workflow name. |
| `config/facets.json` | Facet vocabulary + global tier ladder + policy knobs. |
| `docs/HARNESS.md` | Authoritative design of the harness. |
| `docs/LIMITATIONS.md` | The trade-off / limitation log (part of "done"). |
| `CLAUDE.md` | Working conventions every task obeys (branch + self-merge, docs lockstep). |
| `tracking/TASKS.json` | The backlog: schema + example tasks (replace with your own). |
| `tracking/IDEAS.jsonl` | Committed ideas inbox (JSONL: one `{id,title,description,capturedAt}` object per line) — see below. |
| `tracking/human-done.json` / `manual-fail.json` / `reviews.json` | Owner-overlay files — see `docs/designs/manual-fail-signal.md`. |
| `ledgers/outcomes.jsonl` | One terminal row per built task — the sole input to difficulty calibration. |
| `ledgers/failures.jsonl` | One row per failed attempt — diagnostics only, never read by calibration. |
| `.github/workflows/ci.yml` | CI template — wire your real Definition of Done here. |
| `worklog/` | Per-task append-only memory (`TNNN.md`) + generated scratch. |

## Quick start

1. **Get the files into your repo** — start your project from this one, or copy `scripts/`,
   `config/`, `docs/HARNESS.md`, `CLAUDE.md`, `tracking/TASKS.json`, `.github/workflows/ci.yml`,
   `.gitignore`, and `worklog/`.
2. **Wire your Definition of Done.** Put your real format/lint/test/build commands into
   `.github/workflows/ci.yml` **and** describe them in [`docs/HARNESS.md`](./docs/HARNESS.md)
   §5 — they must match. CI is the authoritative gate. *(The shipped CI fails on purpose
   until you replace the placeholder steps.)*
3. **Set the knobs** in `config/harness.env` — `MODEL`, `EFFORT`, caps, and `CI_WORKFLOW`
   (must equal the `name:` of your CI workflow).
4. **Write the backlog.** Replace the example tasks in `tracking/TASKS.json` with your own atomic,
   dependency-ordered tasks (schema in `docs/HARNESS.md` §8.1). Mark gated work 🔒 needs-human.
5. **Push `main` to GitHub** so the CI gate has somewhere to run (a remote is required when
   `REQUIRE_CI=1`).
6. **Run it:**
   ```sh
   chmod +x scripts/*.sh
   DRY_RUN=1 scripts/loop.sh     # preview the next task the loop would pick
   scripts/loop.sh               # one pass (build the next eligible task)
   scripts/supervise.sh          # leave running for days; re-runs the loop on a cadence
   ```

## Requirements

- **`claude`** CLI (Claude Code), authenticated, with a model that accepts `--model` / `--effort`.
  The loop starts every task at the CHEAPEST configured tier (bias-cheap cold-start floor, set in
  `config/harness.env`) and escalates up the global ladder only on real failure — it does not pin
  an expensive model by default.
- **`gh`** (GitHub CLI), authenticated with `repo` + `workflow` scopes — the loop watches CI
  runs and integrates via push.
- **`git`** with worktree support, and a GitHub remote named `origin` for `main`.
- **`jq`** — the loop and status board parse `TASKS.json` with it (`brew install jq`).
- **`bash`** (the scripts target bash, not POSIX sh).
- **`node`** (any recent version) — only for the optional backlog dashboard (`dashboard/`) and,
  if you use the ideas-to-tasks pipeline, its consolidation script. This is a harness-tooling
  dependency independent of your project's own stack — like `jq`/`gh`, it doesn't need to be
  something your project itself uses.

## Dashboard (optional)

`dashboard/server.js` is a small, dependency-free Node HTTP server (core modules only — no
`npm install`, no build step) with three tabs:

- **Backlog** — the live task buckets (ready / waiting / needs-you / done) with per-task detail (spec,
  worklog, audit log) and buttons that call the same `mark-*.sh` scripts a human would run by hand.
  Each done task also shows the model/effort that actually completed it (`finalModel`/`finalEffort`
  from `ledgers/outcomes.jsonl` — the tier that succeeded, after any escalation), or "🧑 implemented
  manually" for a task marked done via the human-done overlay instead (a needs-human gate, or any
  task completed by hand) — those never go through the loop, so they have no ledger row at all.
- **Ideas** — `tracking/IDEAS.jsonl` rendered as a one-line-per-idea list (id, title, captured date);
  click a row to expand its full description (rendered markdown), so the inbox is scannable without
  opening the file or wading through every idea's full text at once. An "Expand all"/"Collapse all"
  button unfurls (or re-collapses) every idea at once instead of clicking each caret individually.
- **Internals** — the harness's own calibration, per `layer × work-type` facet cell: the model/effort it
  would pick and the audit rate the policy will use next (computed by invoking `scripts/policy.jq` exactly
  as the loop does, so the numbers match what the loop actually uses) **alongside the observed audited
  fraction from the ledger**, plus build/failure counts, a failure-kind health panel (which gate is
  actually catching things), the tier ladder, the policy knobs, and a recent-activity feed. Every column
  header in the per-facet calibration table carries a small "?" icon explaining what it means on hover.

Every tab also carries a live **"Now" strip**: whether the loop is running (from its own repo lock —
including a ⚠ stale-lock warning after an interrupt), the current task/phase/rung/attempt from the loop's
`worklog/.current.json` heartbeat, two independent collapsible tails of the builder's and auditor's
*genuinely* live output (the loop invokes `claude` with `--output-format stream-json`, so each updates
incrementally as it's generated rather than dumping everything at once when the process exits — build
and audit are separate files precisely so the audit starting doesn't blank out the builder's still-fresh
output, and vice versa; every tool call gets an inline `▶ <Tool>` marker in order, so a long silent
stretch of reading/running things with no narration in between reads as an actual sequence of tool
calls rather than looking like the panel started mid-conversation; a `▶ running <Tool>…` pill shows
whichever phase is currently active when a tool call is in flight with no response text after it
yet), and a freshness badge
("origin seen Xm ago" / "local ≠ origin") — the dashboard renders LOCAL files, so this surfaces when
nothing has fetched recently. Set `HARNESS_DASHBOARD_FETCH_SECONDS` (harness.env) to have the dashboard
`git fetch` on an interval itself (fetch-only; it never touches the working tree). The ⚙ next to the
header title also spins for as long as that same lock check says the loop is actively running.

The header also carries two ways to tell dashboards apart when you have several open (e.g. multiple
projects, or multiple harness-driven repos): an optional project title — set `.harness/custom/dashboard-title.txt`
(see the customization walkthrough) and it shows next to the gear icon and in the browser tab — and a
theme picker (4 bold, hue-distinct dark themes — Amber, Ink, Forest, Plum — top right, no open-ended
color input) that's a client-only preference saved per-browser via `localStorage`.

It re-reads everything from disk on every request — no daemon; the Internals tab memoises its per-facet
`jq` work on the ledger mtimes so the 5s refresh is cheap.

```sh
node dashboard/server.js                 # binds 127.0.0.1:4790
HARNESS_DASHBOARD_PORT=5000 node dashboard/server.js   # different port
```

## Ideas → tasks pipeline (optional)

A two-step flow for turning raw ideas into backlog tasks without interrupting whatever you're
doing: capture now, convert later, in a batch. `tracking/IDEAS.jsonl` is a committed, zero-ceremony
inbox — one JSON object per line, `{ "id": 1, "title": "...", "description": "...", "capturedAt":
"..." }` — append a row any time (via the `implementation-harness-capture-idea` skill, or by hand;
`id` is the next integer after the highest one currently in the file, local to the current inbox
contents, not a permanent ledger). When you're ready, `implementation-harness-convert-ideas` sweeps
the whole inbox at once: it dedupes related ideas, converts each one (or cluster) in parallel via
its own sub-agent, relays any genuine open question back to you in one batch, then runs
`scripts/consolidate-ideas.sh` — the single locked pass that allocates real task ids, writes each
task's spec, appends to `TASKS.json`, and removes the converted rows.

## Visual verification (optional)

Automated checks can pass while a change still *looks* wrong — a web page, a native/desktop app, a
mobile screen in a simulator, a generated image/chart. Set `VISUAL_VERIFY_HOOK` in
`config/harness.env` to a command that captures the output (a browser screenshot script,
`screencapture`, `xcrun simctl io booted screenshot`, a render command, …) and it's injected into the
builder + auditor prompt for tasks that opt in — a per-task `"visualVerify": true` (any platform) or a
`facets.workType` in `VISUAL_VERIFY_WORKTYPES` (default `component style`). Zero cost for every other task,
and zero cost if left empty. See `docs/designs/visual-verification.md` for the rationale and worked
per-platform examples (the old `UI_VERIFY_HOOK` name still works as an alias).

## Gates — what the loop won't do on its own

Set a task's `gate` field in `TASKS.json` to `"needs-human"` to stop autonomous execution:

- **🔒 needs-human** — needs a one-time human step (credentials, provisioning, anything that
  spends real money or touches production). The agent prepares everything around it, records
  `failed:blocked`, and hands off.
- To require a human to **review a deliverable before dependents proceed**, keep the work buildable and
  add a separate `needs-human` review task that `dependsOn` it (dependents then depend on the review).

The loop skips both during selection and surfaces them on the status board under "Needs you".

---

*The name is a nod to the "Ralph" pattern — a dumb outer loop around a smart, fresh-context
worker. The intelligence is in the worker and the verification gate; the loop itself stays
deliberately simple.*
