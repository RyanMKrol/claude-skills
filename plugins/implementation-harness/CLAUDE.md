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

## ⚠️ Every version bump MUST regenerate the checksums ledger (non-negotiable)

The upgrade skill's checksum fast-path (`skills/implementation-harness-upgrade/CHECKSUMS.jsonl`) lets
it auto-upgrade a file that's merely STALE (never locally edited) without asking — but it can only do
that for versions actually recorded in the ledger. **Any commit that bumps `.claude-plugin/plugin.json`'s
`version` MUST, in the same commit, re-run:**

```bash
plugins/implementation-harness/skills/implementation-harness-upgrade/gen-checksums.sh --append
```

No separate rule is needed for adding or removing a file under `templates/` — `gen-checksums.sh`
discovers files unconditionally from the mechanism directories every time it runs (no manifest, no
exclude list), so there is nothing to remember to update beyond the version-bump step that was already
mandatory.

**A skipped run degrades safely, not silently wrong:** that version's files simply never fast-path,
falling back to the existing ask-the-user diff flow — never a wrong overwrite. But it IS a **permanent**
coverage gap for that version once time passes — unlike a missed `MIGRATIONS.md` entry, this can't be
usefully backfilled later for a commit that no longer reflects "the state at that version" once
`templates/` has since moved on. **Run it as the literal last step before committing the version bump**,
exactly like `bash -n` before committing an edited `*.sh`.

## File taxonomy (classify every change against this)

The upgrade skill treats the three classes differently, so classify correctly:

- **Mechanism** (plugin-owned; the upgrade content-diffs and, on approval, overwrites): all `scripts/*`,
  `dashboard/*.js`, `docs/**`, `harness-CLAUDE.md` (→ `.harness/CLAUDE.md`), `README.md` (→ `.harness/README.md`).
  Terse ledger notes are fine — the diff speaks for itself.
- **Config/schema** (the upgrade reconciles *additively*, never clobbering the user's values):
  `config/harness.env` (knobs), `config/facets.json` (schema/vocabulary). These NEED a precise `ACTION:` line.
- **User data** (the upgrade NEVER touches): `tracking/*`, `tasks/*`, `worklog/*`, `ledgers/*`,
  **`custom/*`** (the prose overlay — see below), and the repo-root `CLAUDE.md` / `.gitignore` /
  `.github/workflows/ci.yml` / `README.md`. A change to one of these templates can only be applied by hand
  — list it under **manual attention** so the upgrade surfaces it.

## The `custom/` overlay — prose companions + behavior/config extension points

The plugin-owned **prose** files (`harness-CLAUDE.md`→`.harness/CLAUDE.md`, `README.md`, everything under
`docs/**`) are mechanism — the upgrade overwrites them. To keep them cleanly upgradeable, consumers put
their edits in a parallel **`templates/custom/`** overlay (mirroring the prose layout) instead of editing
the pristine files in place; each pristine file carries an include pointer to its overlay
(`.harness/CLAUDE.md` uses a real `@custom/CLAUDE.md` import; the docs use a reference line), and `custom/*`
is user-data the upgrade never overwrites (the `implementation-harness-upgrade` §1b *standardize* path
migrates a fork onto this by extracting inline edits into `custom/`). Rules when maintaining prose:

- **Adding a new plugin-owned prose file MUST, in the same change, add its `custom/` overlay stub and its
  include pointer** — otherwise the overlay tree is incomplete and a fresh/standardized install has no home
  for customizations of that file. (Mirror the existing stubs; keep them non-empty so the `@import` never
  targets an empty/missing file.)
- **Don't personalize shipped prose in place** anywhere in `create` — that reintroduces the exact
  byte-drift the overlay exists to prevent (the DoD commands live authoritatively in `ci.yml`/`harness.env`,
  not in a personalized `docs/HARNESS.md`).
- The overlay absorbs *additions* cleanly; it does **not** absorb in-place *edits to shipped lines* — those
  remain a conflict the standardize path surfaces, not a thing the overlay solves.
- **`custom/` also carries behavior/config extension points**, discovered by the loop by convention (never a
  `harness.env` knob): lifecycle hooks (`custom/hooks/on-<event>.sh`, dispatched by `run_hook`) and an
  append-only pre-push guard denylist (`custom/sensitive-paths.txt`). They ship as `.example` stubs (opt-in
  by copy; add-if-missing on upgrade, never overwrite the user's real file). **Adding a new lifecycle event
  = a `run_hook <event>` call at the fire point in BOTH loop variants (keep them in parity) + a new
  `on-<event>.sh.example` stub + a row in the `docs/HARNESS.md` §8.3 event table.** Hooks run as non-fatal
  children and must never fire on an error/prereq exit (`exit 3`); `templates/scripts/loop-extend.test.sh`
  covers the guard extension + the dispatcher.
- **Any new `custom/` extension point MUST be added to the customization catalog** in
  `skills/implementation-harness-customize/SKILL.md` §1 (name, files, a `since: <version>`, and a drafting
  interview) in the same change. That catalog is the single source of truth the **customize** skill walks on
  demand, that **create** walks in full, and that **upgrade** walks scoped to `--since <installed version>`
  — so a feature missing a catalog row is invisible to users (never surfaced on create/upgrade). The
  `since:` must be the version the feature ships in, or the upgrade "what's new for you" scoping is wrong.

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
