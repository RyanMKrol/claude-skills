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

## 1.22.0 → 1.23.0 — prose customization overlay (`custom/`) + standardize upgrade path + version nudge
The big change is the **prose overlay**: plugin-owned prose files (`.harness/CLAUDE.md`, `README.md`,
`docs/**`) stay pristine and reference a parallel `.harness/custom/` tree where consumers put their edits —
so those files upgrade cleanly instead of drifting into per-file reconciles. Baked into fresh installs
(templates + `create`, here) and migratable for existing forks via the upgrade skill's new §1b *standardize*
path (skill-side — reaches existing installs automatically). The `convert-ideas` version-check nudge is
also skill-side (no template change).
- new files: `custom/CLAUDE.md`, `custom/README.md`, `custom/docs/HARNESS.md`, `custom/docs/LIMITATIONS.md`,
  `custom/docs/designs/{audit-verification,difficulty-autotune,manual-fail-signal,visual-verification}.md`
  — the overlay stub tree (mirrors the prose layout). **Add-if-missing on upgrade; NEVER overwrite an
  existing overlay file — it's user content.** Without them the pristine files' `@custom/…`/pointer
  references have no target.
- mechanism: `harness-CLAUDE.md` — appends an `@custom/CLAUDE.md` import at the very bottom (auto-loads the
  overlay when `.harness/CLAUDE.md` loads) and adds a "Customizing / forking the harness" section (put
  changes in `custom/`, never inline; scripts/config are the exception).
- mechanism: `README.md`, `docs/HARNESS.md`, `docs/LIMITATIONS.md`, `docs/designs/*.md` — each gains a
  one-line pointer to its `custom/…` overlay near the top; `docs/LIMITATIONS.md` also redirects
  golden-rule-5's "add a row" to `custom/docs/LIMITATIONS.md`.
- config: none.
- manual attention: existing installs adopt the overlay via the upgrade skill — add the missing `custom/`
  stubs, take the pristine files' new pointer lines, and (for a fork) run the §1b **standardize** path to
  move any inline prose edits into `custom/`. Repo-root `CLAUDE.md` is user-data: its golden-rule-5 now
  points at `custom/docs/LIMITATIONS.md` for FRESH installs (via `create`); existing repos should update
  that wording by hand if they want the overlay convention.
- breaking: none.

## 1.21.0 → 1.22.0 — front-load clarification into the planning stage (DoD emphasis)
(The behavioural change lives in the `convert-ideas` / `review-failed` skills — bias toward asking, a
mandatory definition-of-done confirmation, and an `ideaSummary` shown before questions — which are skill
files, not `templates/`, so they reach existing installs automatically without an upgrade. The only
`templates/` touch is the docs paragraph below.)
- mechanism: `docs/HARNESS.md` — §5.1 ("Planning vs building") gains a paragraph stating that clarification
  is front-loaded into the authoring stage (idea→task conversion, failed-task review), where a human
  confirms the definition of done, so the unattended build pass inherits an unambiguous contract; the
  planning skills bias toward asking, the loop does not.
- config: none.
- new files: none.
- renamed/removed: none.
- manual attention: none.
- breaking: none.

## 1.19.0 → 1.21.0 — dashboard ops console: live "Now" strip, freshness, observed audit + failure health
(1.20.0 was skill-only — the upgrade skill's adoption mode for legacy/hand-forked installs — no template
changes, so no entry.)
- mechanism: `scripts/loop.sh` + `scripts/loop.in-place.sh` — new `heartbeat`/`heartbeat_clear` helpers:
  the loop drops a gitignored `worklog/.current.json` breadcrumb (task, phase building/awaiting-ci/
  auditing/integrating/rate-limited, rung, attempt, tier, timestamps) at phase transitions and removes it
  at terminal outcomes and on any exit (trap). Purely observational — nothing reads it back; every write
  is `|| true`.
- mechanism: `dashboard/server.js` — new `GET /api/activity` (loop lock state via the same
  `<git-common>/<name>-loop.lock/pid` derivation as repo-lock.sh with a PID liveness probe; the heartbeat;
  the last ~40 lines of `.claude-out` from whichever checkout was touched last; freshness = FETCH_HEAD age
  + local HEAD vs `origin/<MAIN_BRANCH>`), an always-visible "Now" strip on every tab (running / idle /
  ⚠ stale-lock-run-loop-recover pill, `local ≠ origin` and "origin seen Xm ago" badges, collapsible live
  output tail), an opt-in interval `git fetch` (`HARNESS_DASHBOARD_FETCH_SECONDS`, fetch-only), and the
  Internals table now shows **Audit (policy)** next to **Audited (observed)** plus a global failure-kind
  health panel (per-cell kinds on the ⚠ hover).
- mechanism: `dashboard/lib.js` + `dashboard/lib.test.js` — `harnessCells` cells gain a `kinds` breakdown;
  new `failureKinds()` global aggregation; tests for both.
- mechanism: `README.md` — dashboard section documents the Now strip, observed-audit column, failure
  health, and the fetch knob.
- config: `config/harness.env` — ACTION: add these knobs if absent (do NOT touch existing values):
  `HARNESS_DASHBOARD_PORT` (default `4790`), `HARNESS_DASHBOARD_FETCH_SECONDS` (default `0`).
- manual attention: repo-root `.gitignore` (user data) — add `.harness/worklog/.current.json` next to the
  other worklog scratch entries. Without it the heartbeat is still safe (the worktree variant writes it
  only to the primary checkout; the in-place variant never stages it), but it will show as an untracked
  file.
- breaking: none.

## 1.18.1 → 1.19.0 — smarter rate-limit backoff + production field notes
- mechanism: `scripts/loop.sh` + `scripts/loop.in-place.sh` —
  - `rl_reset_wait` now returns non-zero (echoes nothing) when no reset time parses, instead of
    silently returning `RL_POLL`; a PARSED wait is capped at `RL_BACKOFF_MAX`.
  - The build path falls back to **exponential backoff** (`RL_BACKOFF_MIN` doubling to `RL_EXP_MAX`)
    when the notice carries no parseable reset time; the audit path still polls `RL_POLL`. The
    `RL_MAX_WAIT` → exit-5-for-supervise budget is unchanged.
  - New `_hms` + `rl_banner` helpers: every rate-limit sleep prints a boxed banner with what Claude
    reported, the sleep duration, and the WALL-CLOCK resume time (unattended runs become diagnosable
    from the log alone). Inline `RL_BUFFER` default raised 60 → 300 (waking a hair early re-hits the
    same limit and burns the attempt).
- mechanism: `docs/HARNESS.md` (§ usage-limit handling rewritten to match),
  `docs/LIMITATIONS.md` (new "Field notes — traps learned operating this harness in production"
  subsection under Harness: interrupt-orphan → run loop-recover; the load-bearing split `git add`s;
  deploy-webhook rate limits → `PUSH_COOLDOWN_SECONDS`; UI false-successes need a human to actually
  look; tests can encode the same bug as the code).
- config: `config/harness.env` — ACTION: add these knobs if absent (do NOT touch existing values):
  `RL_BACKOFF_MIN` (default `300`), `RL_EXP_MAX` (default `3600`), `RL_BACKOFF_MAX` (default `18000`).
  ACTION: `RL_BUFFER` default changed `60` → `300` — update only if the target still holds the old
  default verbatim (`: "${RL_BUFFER:=60}"`); if the user customized it, leave it and just report.
- breaking: none (RL_POLL keeps its role as the audit-path fallback; behavior only changes on the
  previously-fixed-poll unknown-reset build path).

## 1.18.0 → 1.18.1 — loop correctness fixes (ledger accuracy + policy hygiene)
- mechanism: `scripts/loop.sh` + `scripts/loop.in-place.sh` —
  - `cur_verification` now resets to `ci-only` whenever a NEW task is selected (was reset only inside
    `audit_gate`, so a task failing before its audit could write the previous task's `"audited"` into
    its outcome/blocked ledger row).
  - `pick_base` no longer reads per-task `.model`/`.effort` from `TASKS.json` — the cold-start prior is
    always the `harness.env` `MODEL`/`EFFORT` floor. Facets were already the documented only difficulty
    signal; a stray hand-added field could silently override the tier floor.
  - audit sampling uses a new `rand_pm` helper (rejection-sampled `$RANDOM`) instead of `RANDOM % 1000`,
    removing the modulo bias that skewed the effective audit rate slightly below the configured per-mille.
- mechanism: `scripts/loop.sh` (worktree variant only) — `sync_primary_checkout` no longer checks out
  `main` from another branch: a primary checkout deliberately left on a feature branch (or detached) is
  left alone; only a checkout already on `main` is fast-forwarded.
- mechanism: `docs/HARNESS.md`, `docs/designs/difficulty-autotune.md` — cold-start-prior wording updated
  to match (prior = `harness.env` floor; per-task `model`/`effort` ignored).
- config: `config/harness.env` — comment-only clarification on `PUSH_COOLDOWN_SECONDS` (the throttle
  covers the integration push; the follow-up `[skip ci]` status/ledger push is not throttled). No ACTION —
  knob reconciliation doesn't carry comments; nothing to apply.
- manual attention: root `CLAUDE.md` template (golden rule 7) rewords the cold-start-prior sentence and
  now says per-task `model`/`effort` fields are ignored — existing installs may want to update their copy.
  If any existing `TASKS.json` task carries a hand-added `model`/`effort` field, it stops having an effect
  as of this version (facets/ladder govern entirely).
- breaking: none.

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
