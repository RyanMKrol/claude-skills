# claude-skills

A personal [Claude Code](https://claude.com/claude-code) **plugin marketplace** — a versioned home
for skills and plugins I use, so they can be shared and installed anywhere.

## Install

```
/plugin marketplace add RyanMKrol/claude-skills
/plugin install implementation-harness@claude-skills
```

(During local development you can point at a checkout instead:
`/plugin marketplace add ~/Development/claude-skills`.)

## Plugins

| Plugin | What it does |
|---|---|
| [`implementation-harness`](./plugins/implementation-harness) | Scaffolds a Ralph-style single-loop, CI-gated `TASKS.json` implementation harness into a project's self-contained `.harness/` folder, authors its backlog, and operates it via skills — data-driven difficulty auto-tuning, a portable dashboard, an ideas-to-tasks pipeline, and an upgrade skill that reconciles an existing install with newer plugin versions. See the [plugin's own README](./plugins/implementation-harness/README.md) for the full workflow and skill list. |
| [`freshen-up`](./plugins/freshen-up) | One command to update everything: refreshes every configured marketplace and updates every installed plugin to its latest version, via the `claude` CLI's own scriptable subcommands. A single skill, nothing else. See the [plugin's own README](./plugins/freshen-up/README.md). |

## Layout

```
claude-skills/
├── .claude-plugin/marketplace.json          ← the marketplace manifest (lists the plugins below)
└── plugins/
    └── implementation-harness/              ← one plugin (its own .claude-plugin/plugin.json)
        ├── skills/                          ← 3 global skills (create, customize, upgrade)
        └── templates/skills/                ← 8 skills scaffolded project-locally by `create`
```

Each plugin is self-contained under `plugins/<name>/`. To add a new plugin, drop it under
`plugins/` and add an entry to `.claude-plugin/marketplace.json`.
