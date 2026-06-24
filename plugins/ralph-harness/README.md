# ralph-harness

A personal Claude Code plugin that **scaffolds an autonomous build harness into any project** and
**authors its task backlog**, via two interview-style skills.

The harness it installs (the "Ralph Loop") is a single **sequential** shell loop that builds a
`TASKS.json` backlog **one fully-verified task at a time** — fresh-context `claude -p` per task,
worktree **or** in-place isolation (chosen at scaffold), a **green-GitHub-CI merge gate**, and
`gate`/`needs-human` review stops.
Each task names **its own model** (run cheap, mechanical work on Sonnet, judgement-heavy work on
Opus) and can carry an **escalation ladder** that climbs to a stronger model after repeated
failure. All durable state lives in the repo, so an interrupted run wastes at most one task.

> Distinct from Anthropic's official **`ralph-loop`** plugin, which implements the simpler
> "Ralph Wiggum" while-true technique. This one is the fuller task-by-task, CI-gated harness.

## Skills

| Skill | Invoke | What it does |
|---|---|---|
| `ralph-loop-create-harness` | `/ralph-loop-create-harness [dir]` | One-time setup. Interview (isolation mode — worktree vs in-place, name, stack, format/lint/test/build commands, CI name, default model/effort + escalation, optional run/backtest check), then copy the verbatim harness files and write the personalized `CLAUDE.md`, `ci.yml`, `.gitignore`, `harness.env`, `README.md`, and an initial `TASKS.json`. Leaves the project ready to run `.harness/supervise.sh`. |
| `ralph-loop-add-to-backlog` | `/ralph-loop-add-to-backlog [feature]` | Repeatable. Focused interview that turns a feature/phase into atomic, dependency-ordered `TASKS.json` task objects (schema in `.harness/HARNESS.md` §8.1) with per-task model/escalation and `gate`/`needs-human` markers — appended (via `jq`) without disturbing existing tasks. |

Both are also model-invocable (Claude triggers them from the descriptions when you ask in plain
language).

## Layout

```
ralph-harness/
├── .claude-plugin/plugin.json
├── README.md
├── skills/
│   ├── ralph-loop-create-harness/SKILL.md
│   └── ralph-loop-add-to-backlog/SKILL.md
└── templates/                 ← the harness itself (single source of truth), vendored here
    ├── scripts/{loop,loop.in-place,supervise,postflight}.sh, harness.env
    ├── docs/{HARNESS,LIMITATIONS}.md
    ├── .github/workflows/ci.yml
    ├── CLAUDE.md, TASKS.json, README.md, gitignore   (gitignore ships dot-less; written as .gitignore on scaffold)
    └── worklog/.gitkeep
```

`templates/` is the **single source of truth** for the harness — iterate on the harness here.
Bump `plugin.json` `version` when the templates change. The authoritative design of the harness
itself is `templates/docs/HARNESS.md`.

## Install (once)

```
/plugin marketplace add RyanMKrol/claude-skills
/plugin install ralph-harness@claude-skills
```

(For local development on the plugin itself, point the marketplace at a checkout instead:
`/plugin marketplace add ~/Development/claude-skills`.)

Then it's available in every project. Use it by running `/ralph-loop-create-harness` inside a
repo, or just asking Claude to "set up the build harness here".

## Notes

- The shipped `templates/.github/workflows/ci.yml` **fails on purpose** (an `exit 1` placeholder)
  until `ralph-loop-create-harness` replaces its steps with your real Definition-of-Done commands —
  so an un-personalized harness can never silently pass CI.
- The loop integrates by pushing to `origin/main`; a GitHub remote is required when
  `REQUIRE_CI=1` (the default).
- `loop.sh` and `postflight.sh` parse `TASKS.json` with **`jq`** — the scaffolded project needs it
  on PATH (`brew install jq`).
- `loop.sh` derives its worktree/lock name from the repo directory basename — nothing to configure.
- **Two isolation variants.** The default **worktree** loop builds each task in an isolated sibling
  worktree off `origin/main` (it only sees tracked files). The **in-place** loop works directly on
  `main` in the primary checkout — pick it when the build/verify needs **untracked or gitignored
  local state** (private code, local datasets, secrets-driven tests) a worktree can't see;
  `create-harness` asks and installs the right one as `.harness/loop.sh`. In-place adds a
  load-bearing pre-push sensitive-path guard (self-testable via `.harness/loop.sh --guard-selftest`)
  plus rate-limit auto-resume. See `templates/docs/HARNESS.md` "In-place variant".
- Optional **`INTEGRATE_HOOK`** (in `harness.env`) runs a deploy/restart command after each task
  integrates, so the running product matches `main`.
