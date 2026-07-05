# Harness migration ledger

Per-version record of what changed under `templates/` and **how an upgrade should apply it to an existing
`.harness/`**. The `implementation-harness-upgrade` skill reads this to explain each diff it finds and to
apply config changes additively. **Newest entry first.**

> **Maintainer rule:** every change under `templates/` MUST add/extend an entry here in the same commit —
> see `plugins/implementation-harness/CLAUDE.md`. A missing entry means the change silently never reaches
> existing installs on upgrade.

## How the upgrade skill uses this

- **Mechanism files** (all `scripts/*`, `dashboard/*.js`, `docs/**`, `harness-CLAUDE.md`→`.harness/CLAUDE.md`,
  `README.md`→`.harness/README.md`) — the skill content-diffs these against the reference regardless of the
  ledger; the notes here just explain *what* the diff is so the user can tell a shipped change from a local edit.
- **Config/schema files** (`config/harness.env`, `config/facets.json`) — the `ACTION:` lines are load-bearing:
  they tell the skill exactly which knobs to add (with defaults) while preserving the user's values.
- **User-data files** (`tracking/*`, `tasks/*`, `worklog/*`, `ledgers/*`, root `CLAUDE.md`/`.gitignore`/`ci.yml`)
  are never reconciled. Where a version changed one of those, it is listed under **manual attention** so the
  skill can surface it for the user to apply by hand.

Entry format:
```
## <old> → <new>  — <summary>
- mechanism: <paths + one line each>
- config: <path> — ACTION: <exact additive instruction>
- new files: <paths the reference adds>
- renamed/removed: <old → new | removed>
- manual attention: <user-data / root files the upgrade won't touch>
- breaking: <none | description + manual steps>
```

---

## 1.17.0 → 1.18.0 — dashboard Ideas + Internals (per-facet calibration) tabs
- mechanism: `dashboard/server.js` + `dashboard/lib.js` — the dashboard is now a 3-tab app
  (Backlog / Ideas / Internals). New `GET /api/ideas` (renders `tracking/IDEAS.md` via a dependency-free,
  XSS-safe `mdToHtml`) and `GET /api/harness` (per `layer × work-type` cell: chosen model + audit rate by
  invoking `scripts/policy.jq` exactly as the loop does, plus build/failure counts, the tier ladder, the
  policy knobs, and a recent-activity feed; memoised on ledger mtimes). `README.md` dashboard section updated.
- config: none. new files: none. breaking: none. (Pure dashboard refresh — no change to the loop, ledgers,
  or task schema.)

## 1.16.1 → 1.17.0 — worktree loop leaves the primary checkout on main when done
- mechanism: `scripts/loop.sh` (worktree variant only) — new `sync_primary_checkout()`, called at the
  clean "backlog drained / idle" exits: fast-forwards the owner's primary checkout onto the latest main so
  the local copy reflects the completed work. Safe/best-effort — skips a dirty tree, ff-only, non-fatal.
  Header ISOLATION note + `docs/HARNESS.md` §Isolation updated. `loop.in-place.sh` unchanged (it already
  works directly on main).
- config: `config/harness.env` — ACTION: add knob `SYNC_PRIMARY_ON_DONE` (default `1`) if absent; do not
  touch existing values. `0` keeps the strict never-touch-the-primary-checkout behavior. (No effect on the
  in-place variant.)
- breaking: none (default-on but safe + opt-out).

## 1.16.0 → 1.16.1 — dashboard fixes: spec-scroll reset + failed-implies-reviewed
- mechanism: `dashboard/server.js` — the 5s auto-refresh now skips the re-render when the backlog is
  unchanged since the last poll (it was rebuilding `#sections` every tick, recreating each open `<pre>`
  and snapping its scroll back to the top mid-read); the per-task "Mark reviewed" button is no longer
  offered on a failed task.
- mechanism: `dashboard/lib.js` — a failed task is now implicitly reviewed (`reviewed = isReviewed || failed`),
  so it drops out of the unreviewed / bulk-review set and shows the reviewed pill; failure is itself the
  review verdict.
- config: none. breaking: none.

## 1.15.0 → 1.16.0 — upgrade skill + version stamping + migration ledger
- new files: `.harness/.harness-version` (written by create/upgrade — the plugin version marker; commit it).
- mechanism: `scripts/loop.sh` + `scripts/loop.in-place.sh` gain a `# harness-loop-variant:` header line
  (worktree / in-place) so the upgrade skill knows which reference to diff a target's `loop.sh` against.
- config: none.
- manual attention: none. (This is the first version that stamps `.harness-version`; any harness installed
  before it reads as "legacy/unknown" and is reconciled purely by content diff.)
- breaking: none.

## 1.14.0 → 1.15.0 — facets-driven visual-verification trigger
- config: `config/harness.env` — ACTION: add these knobs if absent (do NOT touch existing values):
  `VISUAL_VERIFY_LAYERS` (default `frontend`) and `VISUAL_VERIFY_SKIP_WORKTYPES` (default `docs config logging`).
  Also the default for `VISUAL_VERIFY_WORKTYPES` widened from `component` to `component style` — only update a
  target that still holds the *old default verbatim*; if the user customized it, leave it and just report.
- mechanism: `scripts/loop.{sh,in-place.sh}` (`visual_verify_block` now also reads `facets.layer`);
  `scripts/consolidate-ideas.mjs` (carries a unit's `visualVerify` through to the task);
  `docs/designs/visual-verification.md`, `docs/HARNESS.md` (two-tier model).
- breaking: none (a task with no flag simply gains layer-based auto-fire; suppress with `visualVerify:false`).

## 1.13.1 → 1.14.0 — dashboard restyle (cream/amber)
- mechanism: `dashboard/server.js` (full restyle + `failures.jsonl` aggregation → failed-attempts pill).
- config: none. breaking: none.

## 1.13.0 → 1.13.1 — ignore ideas-pipeline scratch dirs entirely
- manual attention: root `.gitignore` — the template now ignores `.harness/.pending-tasks/*` and
  `.harness/.pending-questions/*` wholesale (keeping each `.gitkeep`). The upgrade does NOT edit the user's
  `.gitignore`; if theirs still uses the old `*.json`-only rules, tell them to widen it by hand.
- config: none. breaking: none.

## 1.12.0 → 1.13.0 — content alignment (## Overview spec convention)
- mechanism: `scripts/consolidate-ideas.mjs` (+ `.sh`) now writes a leading `## Overview` into each spec;
  `docs/HARNESS.md` documents it.
- manual attention: `tracking/IDEAS.md` became a committed starter inbox — user-data, not reconciled.
- config: none. breaking: none.

## 1.11.1 → 1.12.0 — operational skills, drop `gate:"gate"`
- mechanism/docs: `docs/HARNESS.md` + authoring guidance dropped the dead-end `gate:"gate"` value (gate is
  now `null | "needs-human"`). No installed *data* migration — but if a target's `TASKS.json` still contains
  a literal `"gate":"gate"`, flag it under manual attention (the loop treats only `"needs-human"` as gated).
- (The three operational skills added this version — review-failed, loop-recover, pre-loop-checkin — are
  plugin skills, not files installed into `.harness/`, so nothing to reconcile.)
- config: none. breaking: none.

## 1.11.0 → 1.11.1 — cold-start ladder model refresh
- config/state: `config/facets.json` `tiers.ladder` example refreshed to `claude-sonnet-5`. This file is
  tailored per project, so the upgrade leaves it alone — informational only.

## 1.10.0 → 1.11.0 — generalize visual verification beyond browser UI
- config: `config/harness.env` — ACTION: add the `VISUAL_VERIFY_HOOK` block + `VISUAL_VERIFY_WORKTYPES`
  (default `component`) if absent. `UI_VERIFY_HOOK` is kept as a back-compat alias, so a target still using
  the old name keeps working — no removal needed.
- renamed/removed: `docs/designs/ui-verification.md` → `docs/designs/visual-verification.md` (remove the old,
  add the new).
- mechanism: `scripts/loop.{sh,in-place.sh}` (`ui_verify_block` → `visual_verify_block`).
- breaking: none (alias preserved).

---

### Older context (pre-1.11 — reconstruct from `git log` if upgrading a very old install)
A harness from before ~1.11 predates version stamping and much of the current file set. The upgrade skill's
"missing in target" detection will surface any absent files; notable additions by version:
`dashboard/*` + `check-task-scope.sh` (1.3.0), `consolidate-ideas.{mjs,sh}` + the ideas pipeline (1.4.0),
the `mark-*.sh` triad + owner-overlay `tracking/*.json` (1.2.0), and the `config/`, `scripts/`, `docs/`
regrouping (1.1.0). For such installs, prefer re-running `implementation-harness-create` in update mode if
the drift is large.
