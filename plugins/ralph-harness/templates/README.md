# Ralph Loop

A generic **autonomous build harness**: a single, sequential shell loop that builds a
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

## Core principles

1. **Durable state in the repo, not the conversation.**
2. **One task per iteration, fresh context.** No batching.
3. **Sequential, single-flight.** At most one task in motion, so an interruption damages at
   most one task — the core lever for not wasting tokens.
4. **Resume, never restart.** Interrupted work is continued from its branch + worklog.
5. **The Definition of Done is empirical** — compiled, tested, CI green, behaviour observed.
6. **Determinism where it's cheap; the model only where judgement is needed.** Sync, CI-watch,
   merge, cleanup are plain shell; the model implements, fixes, and judges.
7. **The human stays in control without babysitting** — a heartbeat cadence, a status board,
   and 🚦/🔒 review gates.

See [`docs/HARNESS.md`](./docs/HARNESS.md) for the full rationale (including why it's
deliberately *not* parallel).

## What's in here

| Path | Role |
|---|---|
| `scripts/loop.sh` | The single sequential loop: select → build → CI-gate → integrate. |
| `scripts/supervise.sh` | Foreground heartbeat that re-runs `loop.sh` on a cadence. |
| `scripts/postflight.sh` | Zero-token, read-only status board (`worklog/STATUS.md`). |
| `scripts/harness.env` | Optional config: model, effort, caps, CI workflow name. |
| `docs/HARNESS.md` | Authoritative design of the harness. |
| `docs/LIMITATIONS.md` | The trade-off / limitation log (part of "done"). |
| `CLAUDE.md` | Working conventions every task obeys (branch + self-merge, docs lockstep). |
| `TASKS.json` | The backlog: schema + example tasks (replace with your own). |
| `.github/workflows/ci.yml` | CI template — wire your real Definition of Done here. |
| `worklog/` | Per-task append-only memory (`TNNN.md`) + generated scratch. |

## Quick start

1. **Get the files into your repo** — start your project from this one, or copy `scripts/`,
   `docs/HARNESS.md`, `CLAUDE.md`, `TASKS.json`, `.github/workflows/ci.yml`, `.gitignore`, and
   `worklog/`.
2. **Wire your Definition of Done.** Put your real format/lint/test/build commands into
   `.github/workflows/ci.yml` **and** describe them in [`docs/HARNESS.md`](./docs/HARNESS.md)
   §5 — they must match. CI is the authoritative gate. *(The shipped CI fails on purpose
   until you replace the placeholder steps.)*
3. **Set the knobs** in `scripts/harness.env` — `MODEL`, `EFFORT`, caps, and `CI_WORKFLOW`
   (must equal the `name:` of your CI workflow).
4. **Write the backlog.** Replace the example tasks in `TASKS.json` with your own atomic,
   dependency-ordered tasks (schema in `docs/HARNESS.md` §8.1). Mark gated work 🚦 / 🔒.
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

- **`claude`** CLI (Claude Code), authenticated, with a model that accepts `--model` /
  `--effort` (the loop pins `claude-opus-4-8` / `high` by default).
- **`gh`** (GitHub CLI), authenticated with `repo` + `workflow` scopes — the loop watches CI
  runs and integrates via push.
- **`git`** with worktree support, and a GitHub remote named `origin` for `main`.
- **`bash`** (the scripts target bash, not POSIX sh).

## Gates — what the loop won't do on its own

Set a task's `gate` field in `TASKS.json` to stop autonomous execution:

- **🚦 Gate** — the deliverable must be **reviewed by a human** before dependents proceed.
- **🔒 needs-human** — needs a one-time human step (credentials, provisioning, anything that
  spends real money or touches production). The agent prepares everything around it, records
  `failed:blocked`, and hands off.

The loop skips both during selection and surfaces them on the status board under "Needs you".

---

*The name is a nod to the "Ralph" pattern — a dumb outer loop around a smart, fresh-context
worker. The intelligence is in the worker and the verification gate; the loop itself stays
deliberately simple.*
