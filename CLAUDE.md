# CLAUDE.md — working in the claude-skills plugin marketplace

This repo is a Claude Code **plugin marketplace** (`.claude-plugin/marketplace.json`). Each plugin
lives under `plugins/<name>/`, with its manifest at `plugins/<name>/.claude-plugin/plugin.json`.

## ⚠️ Bump the plugin version on EVERY change (non-negotiable, #1 gotcha)

Claude Code installs each plugin into a **versioned cache**
(`~/.claude/plugins/cache/<marketplace>/<plugin>/<version>/`) and **re-installs only when the
`version` changes**. So if you edit a plugin's files but do **not** bump its `version` in
`plugins/<name>/.claude-plugin/plugin.json`, consumers keep running the **cached old version** —
your changes never reach them, **even after you commit and push.** A forgotten bump silently makes
all your work invisible (this is exactly how a whole difficulty-auto-tuning feature sat unused: the
files were committed at 0.5.2 but the version never moved, so every session kept loading cached
0.5.2).

**Rule: any change to a plugin's files MUST be committed *together with* a version bump in that
plugin's `plugin.json`** — semver: PATCH for fixes, MINOR for features, MAJOR for breaking changes.
Never edit plugin files without bumping.

After pushing, consumers pick up the new version by **updating the plugin** (Claude Code re-pulls the
marketplace and installs the new version into the cache) — and may need to start a fresh session.

## Conventions

- Keep `marketplace.json`'s plugin entry description roughly in sync with the plugin's `plugin.json`
  description (the latter is canonical).
- Validate JSON before committing: `jq empty plugins/<name>/.claude-plugin/plugin.json` and
  `jq empty .claude-plugin/marketplace.json`.
- The harness scripts target **bash 3.2** (macOS default) — no `mapfile`/bash-4 builtins; run
  `bash -n` on any edited `*.sh` before bumping.
- Commit + push as you go.
