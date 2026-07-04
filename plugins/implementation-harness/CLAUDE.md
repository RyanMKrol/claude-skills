# CLAUDE.md — maintaining the implementation-harness plugin

This is the **maintainer** guide for the `implementation-harness` plugin. The repo-root
`../../CLAUDE.md` still applies (most importantly: **bump `.claude-plugin/plugin.json`'s `version` in the
same commit as any plugin change** — the cache only re-installs on a version change). This file adds the
one rule specific to this plugin.

## ⚠️ Every change under `templates/` MUST update the migration ledger (non-negotiable)

Consumers don't run `templates/` directly — they run a **copy** scaffolded into their own repo's
`.harness/` (by the `implementation-harness-create` skill). The **only** way a change you make here reaches
a repo that *already has* a harness is the `implementation-harness-upgrade` skill — and that skill is
driven by the migration ledger at **`skills/implementation-harness-upgrade/MIGRATIONS.md`**.

**So: any change under `templates/` — editing, adding, renaming, or removing a file; adding a `harness.env`
knob; changing a `facets.json` / `TASKS.json` schema — MUST add or extend the matching ledger entry in the
same commit.** A forgotten entry is the exact sibling of the forgotten-version-bump gotcha: the change ships
to *new* installs but silently never reaches *existing* ones on upgrade.

The ledger entry must record (newest-first, using the format documented at the top of `MIGRATIONS.md`):
- the version transition (`<old> → <new>`) and a one-line summary;
- each file touched **and its class** (see taxonomy below);
- for **config** files, the exact **additive** `ACTION:` (e.g. "add knob `X` default `Y` if absent; don't
  touch existing values") — the upgrade applies these verbatim;
- any **rename/removal** (old path → new path, or removed);
- anything the upgrade **won't** touch (user-data / root files) under **manual attention**;
- any **breaking** change + the manual steps it needs.

## File taxonomy (classify every change against this)

The upgrade skill treats the three classes differently, so classify correctly:

- **Mechanism** (plugin-owned; the upgrade content-diffs and, on approval, overwrites): all `scripts/*`,
  `dashboard/*.js`, `docs/**`, `harness-CLAUDE.md` (→ `.harness/CLAUDE.md`), `README.md` (→ `.harness/README.md`).
  Terse ledger notes are fine — the diff speaks for itself.
- **Config/schema** (the upgrade reconciles *additively*, never clobbering the user's values):
  `config/harness.env` (knobs), `config/facets.json` (schema/vocabulary). These NEED a precise `ACTION:` line.
- **User data** (the upgrade NEVER touches): `tracking/*`, `tasks/*`, `worklog/*`, `ledgers/*`, and the
  repo-root `CLAUDE.md` / `.gitignore` / `.github/workflows/ci.yml` / `README.md`. A change to one of these
  templates can only be applied by hand — list it under **manual attention** so the upgrade surfaces it.

## Reminders that interact with the above

- Two loop variants: `scripts/loop.sh` (worktree) and `scripts/loop.in-place.sh` (in-place). Both install
  as `.harness/scripts/loop.sh`; each carries a `# harness-loop-variant:` header the upgrade reads to pick
  the right reference. **Keep both variants in parity** and keep those markers intact. Run `bash -n` on any
  edited `*.sh` (target: bash 3.2 — no bash-4 builtins).
- The scaffolded `.harness/.harness-version` marker is written by `create` (and re-stamped by `upgrade`)
  from `plugin.json`'s `version` — it's what lets an upgrade know the starting point. It's not a template
  file; don't add one.
- Validate JSON (`jq empty`) before committing; keep `marketplace.json`'s plugin description roughly in sync
  with `plugin.json`'s.
