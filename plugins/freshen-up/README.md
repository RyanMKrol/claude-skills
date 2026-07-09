# freshen-up

**One command to update everything.** `freshen-up` refreshes every configured Claude Code
marketplace and then updates every installed plugin to its latest version — in a single step,
reporting exactly what changed. A single skill, nothing else; no project files touched.

It exists because the interactive `/plugin` session commands have **no bulk "update all" option** —
you'd otherwise update marketplaces and plugins one at a time by hand. `freshen-up` drives the
`claude` CLI's own scriptable subcommands to do the whole sweep at once.

## Use it

```
/freshen-up:go
```

…or just ask Claude to "update all my plugins" / "refresh my marketplaces".

## What it does

1. **Snapshot** the current state — `claude plugin list --json` (so it can diff at the end).
2. **Update everything** — `claude plugin marketplace update` (no argument = refresh **all**
   configured marketplaces from their sources), then `claude plugin update` for **every** installed
   plugin (a `jq`/`xargs` loop, since `claude plugin update` takes one target at a time). If a single
   plugin fails to update (e.g. it was removed from its marketplace), it keeps going rather than
   aborting the whole run.
3. **Diff and report** — lists which plugins changed version (old → new), which were already current,
   and any new commits/versions the marketplace update pulled.

## Heads-up: restart to pick it up

Every `claude plugin update` prints "restart required to apply." The updates aren't **live** in your
current session until you run `/reload-plugins` or start a fresh `claude` session — `freshen-up` says
so as the last line of its report.

## Requirements

- The **`claude`** CLI on PATH (this drives `claude plugin …` subcommands).
- **`jq`** — used to snapshot and diff the plugin list (`brew install jq`).

## Install

```
/plugin marketplace add RyanMKrol/claude-skills
/plugin install freshen-up@claude-skills
```

(For local development, point the marketplace at a checkout instead:
`/plugin marketplace add ~/Development/claude-skills`.)
