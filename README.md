# claude-skills

A personal [Claude Code](https://claude.com/claude-code) **plugin marketplace** — a versioned home
for skills and plugins I use, so they can be shared and installed anywhere.

## Install

```
/plugin marketplace add RyanMKrol/claude-skills
/plugin install ralph-harness@claude-skills
```

(During local development you can point at a checkout instead:
`/plugin marketplace add ~/Development/claude-skills`.)

## Plugins

| Plugin | What it does |
|---|---|
| [`ralph-harness`](./plugins/ralph-harness) | Scaffolds the Ralph-style single-loop, CI-gated autonomous build harness into any project and authors its task backlog, via two interview skills. The backlog is a `TASKS.json` file with **per-task model selection** and **automatic escalation** to a stronger model on repeated failure. |

## Layout

```
claude-skills/
├── .claude-plugin/marketplace.json   ← the marketplace manifest (lists the plugins below)
└── plugins/
    └── ralph-harness/                ← one plugin (its own .claude-plugin/plugin.json + skills + templates)
```

Each plugin is self-contained under `plugins/<name>/`. To add a new plugin, drop it under
`plugins/` and add an entry to `.claude-plugin/marketplace.json`.
