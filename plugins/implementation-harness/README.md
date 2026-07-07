# implementation-harness

A personal Claude Code plugin that **scaffolds an autonomous implementation harness into any
project**, authors its task backlog, and gives it a portable backlog dashboard — via nine skills
(three global, six scaffolded per-project — see [Skills](#skills)).

The harness it installs (the "Ralph Loop") is a single **sequential** shell loop that builds a
`TASKS.json` backlog **one fully-verified task at a time** — fresh-context `claude -p` per task,
worktree **or** in-place isolation (chosen at scaffold), a **green-GitHub-CI merge gate**, a
**sampled blocking audit**, and `gate`/`needs-human` review stops. Difficulty (which model/effort
to build a task at) is **data-driven auto-tuning**: the policy starts every task at the cheapest
tier and escalates up a global ladder on repeated failure, learning per-kind-of-task which tier
reliably works. All durable state lives in the repo, so an interrupted run wastes at most one task.

> Distinct from Anthropic's official **`ralph-loop`** plugin, which implements the simpler
> "Ralph Wiggum" while-true technique. This one is the fuller task-by-task, CI-gated harness.

## Skills

Three **global** skills (plugin-registered — invoke with the `implementation-harness:` prefix from
any project) bootstrap and reconcile a harness install:

| Skill | Invoke | What it does |
|---|---|---|
| `implementation-harness-create` | `/implementation-harness:implementation-harness-create [dir]` | One-time setup. Interview (isolation mode — worktree vs in-place, name, stack, format/lint/test/build commands, CI name, cold-start difficulty floor, optional run/backtest check), then copy the verbatim harness files (including the six project-local skills below) and write the personalized `CLAUDE.md`, `ci.yml`, `.gitignore`, `harness.env`, `README.md`, and an initial `TASKS.json`. Leaves the project ready to run `.harness/scripts/supervise.sh`. |
| `implementation-harness-customize` | `/implementation-harness:implementation-harness-customize` | Guided walkthrough of the `custom/` extension-point catalog (lifecycle hooks, secret-guard denylist, visual-verify snippets, build/audit preambles, dashboard title, …) — activates the opt-in file and helps draft its content for each feature the user wants. |
| `implementation-harness-upgrade` | `/implementation-harness:implementation-harness-upgrade [dir]` | Reconciles an installed `.harness/` (and the six project-local skills below) against the plugin's bundled reference — refreshes plugin-owned mechanism files, adds new `harness.env` knobs additively, reports first and asks before every change. Also adopts legacy/hand-forked installs. |

Six **project-local** skills (scaffolded by `create` into your project's own `.claude/skills/`, kept
in sync by `upgrade` — invoke bare, no prefix — so their logic can never drift ahead of what this
specific project's `.harness/` understands) operate a harness that's already installed:

| Skill | Invoke | What it does |
|---|---|---|
| `implementation-harness-add-to-backlog` | `/implementation-harness-add-to-backlog [feature]` | Repeatable. Focused interview that turns a feature/phase into atomic, dependency-ordered `TASKS.json` task objects (schema in `.harness/docs/HARNESS.md` §8.1) with auto-tuned difficulty (`facets`) and `gate`/`needs-human` markers — appended (via `jq`) without disturbing existing tasks. |
| `implementation-harness-capture-idea` | `/implementation-harness-capture-idea <idea>` | Zero-ceremony: appends one `{id,title,description,capturedAt}` row to the committed `tracking/IDEAS.jsonl` inbox. No interview, no `TASKS.json` write. |
| `implementation-harness-convert-ideas` | `/implementation-harness-convert-ideas` | Sweeps the whole ideas inbox at once — dedupes, converts each idea/cluster in parallel via its own sub-agent, relays any open questions in one batch, then runs the locked `consolidate-ideas.sh` pass into `TASKS.json`. |
| `implementation-harness-review-failed` | `/implementation-harness-review-failed [id]` | Sweeps every `failed`/`blocked` task, investigates the root cause (one sub-agent each, in parallel), and authors a demonstrably-better follow-up task via the same `consolidate-ideas.sh` pipeline. Never a blind retry; never touches the terminal task's status. |
| `implementation-harness-loop-recover` | `/implementation-harness-loop-recover [id]` | Recovers the loop after a manual interrupt: stops-check, surgical dirty-tree / leftover-worktree cleanup, stale-lock clearing, orphaned-task detection + fix (verified against the DoD), ledger-noise cleanup, then a readiness check. Mutates + pushes — the correcting the stopped loop can't do. |
| `implementation-harness-pre-loop-checkin` | `/implementation-harness-pre-loop-checkin [id]` | Read-only GO/NO-GO before an unattended run: needs-human blockers, session hygiene, dependency short-circuits, and per-task facets/spec/scope quality. Changes nothing. |

All nine are also model-invocable (Claude triggers them from the descriptions when you ask in plain
language) — the three global ones from any project, the six project-local ones once scaffolded into
that project.

## Layout

```
implementation-harness/
├── .claude-plugin/plugin.json
├── README.md
├── skills/                     ← global, plugin-registered (colon-invoked)
│   ├── implementation-harness-create/SKILL.md
│   ├── implementation-harness-customize/SKILL.md
│   └── implementation-harness-upgrade/{SKILL.md,MIGRATIONS.md}
└── templates/                 ← the harness itself (single source of truth), vendored here
    ├── skills/                 ← sources for the six project-local skills (scaffolded to
    │                             <project>/.claude/skills/implementation-harness-<name>/SKILL.md
    │                             by create, kept in sync by upgrade)
    │   ├── implementation-harness-add-to-backlog/SKILL.md
    │   ├── implementation-harness-capture-idea/SKILL.md
    │   ├── implementation-harness-convert-ideas/SKILL.md
    │   ├── implementation-harness-loop-recover/SKILL.md
    │   ├── implementation-harness-pre-loop-checkin/SKILL.md
    │   └── implementation-harness-review-failed/SKILL.md
    ├── config/{harness.env,facets.json}
    ├── docs/{HARNESS,LIMITATIONS}.md, docs/designs/*.md
    ├── ledgers/                (outcomes.jsonl, failures.jsonl — seeded empty, committed)
    ├── scripts/                loop.sh, loop.in-place.sh, supervise.sh, postflight.sh,
    │                           repo-lock.sh, policy.jq, mark-{done,failed,reviewed}.sh (+ its
    │                           bulk test), check-task-scope.sh, consolidate-ideas.{sh,mjs}
    ├── dashboard/              server.js, lib.js, lib.test.js — portable backlog viewer
    ├── tasks/                  per-task Markdown specs (## Do / ## Done when)
    ├── tracking/               TASKS.json, IDEAS.jsonl, human-done/manual-fail/reviews.json
    ├── .pending-tasks/, .pending-questions/   ideas-pipeline scratch dirs
    ├── worklog/.gitkeep
    ├── .github/workflows/ci.yml
    └── CLAUDE.md, harness-CLAUDE.md, README.md, gitignore   (gitignore ships dot-less; written as .gitignore on scaffold)
```

`templates/` is the **single source of truth** for the harness — iterate on the harness here.
Bump `plugin.json` `version` when the templates change. The authoritative design of the harness
itself is `templates/docs/HARNESS.md`; the owner-overlay/dashboard mechanism is
`templates/docs/designs/manual-fail-signal.md`.

## Install (once)

```
/plugin marketplace add RyanMKrol/claude-skills
/plugin install implementation-harness@claude-skills
```

(For local development on the plugin itself, point the marketplace at a checkout instead:
`/plugin marketplace add ~/Development/claude-skills`.)

Then it's available in every project. Use it by running
`/implementation-harness:implementation-harness-create` inside a repo, or just asking Claude to "set
up the implementation harness here".

## Notes

- The shipped `templates/.github/workflows/ci.yml` **fails on purpose** (an `exit 1` placeholder)
  until `implementation-harness:implementation-harness-create` replaces its steps with your real
  Definition-of-Done commands — so an un-personalized harness can never silently pass CI.
- The loop integrates by pushing to `origin/main`; a GitHub remote is required when
  `REQUIRE_CI=1` (the default).
- `loop.sh` and `postflight.sh` parse `TASKS.json` with **`jq`** — the scaffolded project needs it
  on PATH (`brew install jq`). The dashboard and the ideas-pipeline consolidation script need
  **`node`** — a harness-tooling dependency independent of the target project's own stack.
- `loop.sh` derives its worktree/lock name from the repo directory basename — nothing to configure.
- **Two isolation variants.** The default **worktree** loop builds each task in an isolated sibling
  worktree off `origin/main` (it only sees tracked files). The **in-place** loop works directly on
  `main` in the primary checkout — pick it when the build/verify needs **untracked or gitignored
  local state** (private code, local datasets, secrets-driven tests) a worktree can't see;
  `create-harness` asks and installs the right one as `.harness/scripts/loop.sh`. In-place adds a
  load-bearing pre-push sensitive-path guard (self-testable via
  `.harness/scripts/loop.sh --guard-selftest`) plus rate-limit auto-resume. See
  `templates/docs/HARNESS.md` "In-place variant".
- **Owner overlays + dashboard.** `mark-done.sh`/`mark-failed.sh`/`mark-reviewed.sh` (and the
  dashboard's buttons, which shell out to the same scripts) let a human correct or advance the
  backlog without ever hand-editing `TASKS.json` — see `templates/docs/designs/manual-fail-signal.md`.
- Optional **`INTEGRATE_HOOK`** (in `config/harness.env`) runs a deploy/restart command after each
  task integrates, so the running product matches `main`.
