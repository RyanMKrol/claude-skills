# CLAUDE.md — maintaining the implementation-harness plugin

This is the **maintainer** guide for the `implementation-harness` plugin. The repo-root
`../../CLAUDE.md` still applies (most importantly: **bump `.claude-plugin/plugin.json`'s `version` in the
same commit as any plugin change** — the cache only re-installs on a version change). This file adds the
rules specific to this plugin.

## ⚠️ Front-load clarification into the planning stage (design principle — do not erode)

This plugin has a deliberate division of labour, and it drives how the skills are written:

- **The build loop is unattended and runs on the policy-chosen (often weaker) model.** It has no human
  at the keyboard, cannot ask anything, and builds each task **from the spec alone** — when it hits a
  real unknown it records `failed:blocked` for a human, it does not clarify (see
  `templates/docs/HARNESS.md` §3 / §5.1).
- **The planning stage is where a human IS present and a strong model is shaping the spec** — the
  idea→task conversion (`implementation-harness-convert-ideas`) and the failed-task review
  (`implementation-harness-review-failed`). This is the ONLY cheap place to resolve ambiguity, and a
  spec that is wrong or under-specified here silently wastes a whole downstream build.

**Therefore the planning-stage skills MUST bias toward asking**, not away: surface any decision that
changes what gets built, and **always confirm the definition of done** with the owner (propose the
acceptance bar, ask them to confirm/adjust) rather than deciding it silently.
`implementation-harness-capture-idea` is the intentional exception — it is zero-ceremony and deliberately
**defers** all questions to the `convert-ideas` sweep, which is exactly why conversion is where the
questioning must concentrate.

**Re-assert guard.** If a change would *reduce* planning-stage questioning — adding "prefer a reasonable
default", "don't block/pester the owner", raising the bar for what counts as worth asking, or removing a
mandatory confirmation like the definition-of-done check — **STOP and re-assert this principle to the
user, making explicit that the change contradicts the plugin's design.** Do not make such a change
silently; if the user still wants it after that, it must be a deliberate, informed choice.

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
