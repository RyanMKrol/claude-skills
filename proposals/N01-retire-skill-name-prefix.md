# N01: Retire the redundant `implementation-harness-` prefix from every skill name

**Type**: new-idea (owner request, 2026-07-11) · **Priority**: P1 · **Effort**: L — the riskiest migration in this folder; read fully before starting
**Affected files**: every `skills/*/` and `templates/skills/*/` dir + frontmatter; cross-references in ALL skills/docs/READMEs/loop prompts; `implementation-harness-create` (scaffold loop + validation); `implementation-harness-upgrade` (its skills table, validation, AND its own sibling-file paths — `MIGRATIONS.md`/`CHECKSUMS.jsonl`/`gen-checksums.sh` live inside the upgrade skill's directory, which is itself being renamed); `gen-checksums.sh` (canonical paths change); plugin.json/marketplace.json descriptions
**Release**: MAJOR-ish MINOR bump · a heavyweight MIGRATIONS entry (renames of all nine project-local skill dirs) · checksums (paths change!) · full test suite

## The owner's problem

Global skills invoke as `/implementation-harness:implementation-harness-create` — the plugin
namespace ALREADY says implementation-harness, so the second prefix is pure stutter. Project-local
skills invoke bare as `/implementation-harness-convert-ideas` — no namespace there, but the prefix
is still 23 characters of typing before the meaningful word.

## Scope decision (settle with the owner before implementing)

**Part 1 — the four global skills (LOW risk, clear win): definitely do.**
`implementation-harness-create` → `create`, `-customize` → `customize`, `-upgrade` → `upgrade`,
`-report-issue` → `report-issue`. Invocation becomes `/implementation-harness:create` etc. The
namespace collision surface is zero (the plugin prefix scopes them).

**Part 2 — the nine project-local skills (REAL trade-off): confirm intent.**
Renaming `implementation-harness-convert-ideas` → `convert-ideas` (etc.) gives `/convert-ideas` —
much nicer — but these land in the CONSUMER's `.claude/skills/` flat namespace, so generic names
can collide with a project's own skills (`/capture-idea`, `/add-to-backlog` are plausible names
for unrelated project skills). Options:
- (a) fully bare: `convert-ideas`, `capture-idea`, … — nicest, collision risk on generic names;
- (b) short prefix: `harness-convert-ideas`, … — collision-safe, still 60% shorter;
- (c) bare for distinctive names, short-prefixed for generic ones — inconsistent, avoid.
**Recommendation: (b) `harness-` for project-local** (they operate "the harness" — the word earns
its place), **bare for global**. But this is the owner's call — ask first.

## Implementation plan (order matters)

1. **Inventory**: `grep -rn 'implementation-harness-' plugins/implementation-harness/ | wc -l`
   (hundreds of hits) — classify: skill-name references (change), plugin-name references (keep:
   the plugin itself, `implementation-harness:` namespace, repo paths), historical MIGRATIONS
   entries (KEEP verbatim — they describe the past).
2. **Global skills**: `git mv` the four dirs; update frontmatter `name:`; fix every cross-
   reference (`implementation-harness:implementation-harness-upgrade` →
   `implementation-harness:upgrade` — these appear in create/upgrade/customize/report-issue
   prose, templates/README.md, harness-CLAUDE.md, plugin README, CLAUDE.md files).
   **Trap**: `gen-checksums.sh` and the upgrade skill resolve `MIGRATIONS.md`/`CHECKSUMS.jsonl`
   via `${CLAUDE_SKILL_DIR}` — after the rename the dir is `skills/upgrade/`; the files move WITH
   it, so intra-skill relative paths keep working, but the repo CI's hardcoded paths
   (`.github/workflows/ci.yml` references `skills/implementation-harness-upgrade/…` three times)
   and this repo's CLAUDE.md prose must be updated in the same commit.
3. **Project-local skills**: `git mv` the nine template dirs to the chosen names; update
   frontmatter; update `create`'s scaffold loop + validation loop + handoff prose, `upgrade`'s
   skills table + validation loop; update every `/implementation-harness-<x>` invocation mention
   across templates/docs/README/harness-CLAUDE.md AND the loop prompts if any reference skills.
4. **The upgrade path for existing installs (the hard part)**: the upgrade skill must migrate
   `$T/.claude/skills/implementation-harness-<x>/` → the new dirs: add old→new rename pairs to
   the MIGRATIONS entry, and teach the skills-table section a one-time rename rule (present the
   nine renames as a batch action: copy new, delete old, preserving any local edits by content-
   diffing against the OLD canonical path in CHECKSUMS — the checksum lookup is by canonical
   path, so record BOTH old and new paths for the transition version, or special-case the lookup).
   **Verify the checksum fast-path survives**: after this version, `gen-checksums.sh` discovers
   the NEW paths; an installed OLD-path file must still be matchable — simplest: the MIGRATIONS
   entry instructs the upgrade to treat old-path files' hashes as look-up-able under their old
   canonical path (all prior CHECKSUMS lines still carry them).
5. **Deprecation shims (decide)**: optionally keep the old project-local names for one version as
   thin SKILL.md stubs whose body says "renamed — invoke /<new>" (helps muscle memory; doubles
   the table). Recommendation: no shims for project-local (upgrade renames them in place), but DO
   note the old global invocations in the plugin README for one release.
6. **Sequencing**: do this AFTER the queue's P0/P1 bugs (every open proposal references current
   names; landing N01 early invalidates paths in ~50 spec files — or accept that and fix the
   proposals' paths in the same commit).

## Acceptance criteria

- `/implementation-harness:create` (etc.) works in a fresh session; old colon-invocations gone
  from all docs.
- A fresh scaffold produces the new project-local names; create's validation loop passes.
- An EXISTING install (fixture with the old dirs) upgraded → old dirs gone, new dirs present,
  local edits surfaced not clobbered; `.harness-version` restamped.
- Repo CI green (its hardcoded upgrade-skill paths updated); full test suite green; checksums
  regenerated under the new canonical paths.
- No historical MIGRATIONS/CHECKSUMS lines rewritten.
