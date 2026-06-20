# ralph-harness

A personal Claude Code plugin that **scaffolds an autonomous build harness into any project** and
**authors its task backlog**, via two interview-style skills.

The harness it installs (the "Ralph Loop") is a single **sequential** shell loop that builds a
`TASKS.md` backlog **one fully-verified task at a time** — fresh-context `claude -p` per task,
git-worktree isolation, a **green-GitHub-CI merge gate**, a pinned model, and 🚦/🔒 review gates.
All durable state lives in the repo, so an interrupted run wastes at most one task.

> Distinct from Anthropic's official **`ralph-loop`** plugin, which implements the simpler
> "Ralph Wiggum" while-true technique. This one is the fuller task-by-task, CI-gated harness.

## Skills

| Skill | Invoke | What it does |
|---|---|---|
| `ralph-loop-create-harness` | `/ralph-loop-create-harness [dir]` | One-time setup. Interview (name, stack, format/lint/test/build commands, CI name, model/effort, optional run/backtest check), then copy the verbatim harness files and write the personalized `CLAUDE.md`, `ci.yml`, `.gitignore`, `harness.env`, `README.md`, and an initial `TASKS.md`. Leaves the project ready to run `scripts/supervise.sh`. |
| `ralph-loop-add-to-backlog` | `/ralph-loop-add-to-backlog [feature]` | Repeatable. Focused interview that turns a feature/phase into atomic, dependency-ordered `TASKS.md` entries (schema in `docs/HARNESS.md` §8.1) with 🚦/🔒 gate markers — appended without disturbing existing tasks. |

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
    ├── scripts/{loop,supervise,postflight}.sh, harness.env
    ├── docs/{HARNESS,LIMITATIONS}.md
    ├── .github/workflows/ci.yml
    ├── CLAUDE.md, TASKS.md, README.md, gitignore   (gitignore ships dot-less; written as .gitignore on scaffold)
    └── worklog/.gitkeep
```

`templates/` is the **single source of truth** for the harness — iterate on the harness here.
Bump `plugin.json` `version` when the templates change. The authoritative design of the harness
itself is `templates/docs/HARNESS.md`.

## Install (once)

```
/plugin marketplace add ~/.claude/plugins-local
/plugin install ralph-harness@personal-local
```

Then it's available in every project. Use it by running `/ralph-loop-create-harness` inside a
repo, or just asking Claude to "set up the build harness here".

## Notes

- The shipped `templates/.github/workflows/ci.yml` **fails on purpose** (an `exit 1` placeholder)
  until `ralph-loop-create-harness` replaces its steps with your real Definition-of-Done commands —
  so an un-personalized harness can never silently pass CI.
- The loop integrates by pushing to `origin/main`; a GitHub remote is required when
  `REQUIRE_CI=1` (the default).
- `loop.sh` derives its worktree/lock name from the repo directory basename — nothing to configure.
