---
name: implementation-harness-upgrade
description: >-
  Use when a project already has an installed `.harness/` and the user wants to pull in newer harness
  changes shipped by this plugin — phrases like "upgrade the harness", "update my harness", "pull in the
  latest harness changes", "is my harness up to date", "/upgrade-harness". Reconciles the installed
  `.harness/` against the plugin's bundled reference: refreshes plugin-owned mechanism files and adds new
  `harness.env` knobs, REPORTING first and asking before every change, and NEVER touching the backlog,
  worklog, ledgers, or the user's config values. Also ADOPTS legacy or hand-forked installs (no version
  marker, hand-maintained since install, or a pre-plugin hand-ported harness) — classifying each
  difference as plugin-newer vs local-bespoke vs conflict before anything is overwritten. Requires a
  harness already scaffolded (use implementation-harness-create for a fresh install).
argument-hint: "[optional: path to the project or its .harness — defaults to cwd]"
allowed-tools: Read, Write, Edit, Bash, Glob, AskUserQuestion
---

# Upgrade an installed harness to the bundled reference

You are reconciling a project's **existing** `.harness/` against the version of the harness this plugin
currently ships (`templates/`), so the project picks up new scripts, dashboard changes, docs, and new
`harness.env` knobs **without losing the user's own data or edits**. Read this whole file, then execute
the stages in order.

**Two rules govern everything below (the user chose these):**
1. **Report, then apply on confirm.** Produce a full dry-run report first; mutate only after the user
   approves.
2. **Never auto-decide on a file that isn't byte-identical to the reference.** A file that matches the
   reference exactly is already current — skip it silently. For *any* other difference, surface the
   delta (with the ledger's "expected change" note) and **ask the user how to handle it** — they have
   very likely made their own edits, and those must be respected. Do not overwrite on your own judgment.

## 0. Locate the bundled reference, its version, and the ledger

Resolve the plugin's `templates/` exactly as the create skill does (the env var differs by context):

```bash
TPL="${CLAUDE_PLUGIN_ROOT:-}/templates"
[ -d "$TPL" ] || TPL="${CLAUDE_SKILL_DIR}/../../templates"
TPL="$(cd "$TPL" && pwd)"                                   # normalize
[ -f "$TPL/scripts/loop.sh" ] || { echo "plugin templates not found — install looks broken"; exit 1; }
REF_VERSION="$(jq -r .version "$TPL/../.claude-plugin/plugin.json")"
LEDGER="${CLAUDE_SKILL_DIR}/MIGRATIONS.md"                  # the per-version migration notes (sibling of this file)
```

Read `$LEDGER` now — it is your source of truth for *what changed per version* and *how to apply each
change safely* (especially the additive `harness.env` instructions and any file renames/removals).

## 1. Locate + validate the target; detect variant and installed version

- **Target** = the skill argument if given, else the current working directory. Let `H="<target>/.harness"`.
- Require `H/scripts/loop.sh` to exist. If not, this project has no harness — tell the user to run
  `implementation-harness-create` instead, and stop.
- **Detect the loop variant** the target installed (both variants install as `H/scripts/loop.sh`, so you
  must know which reference to diff against):

  ```bash
  if grep -q 'harness-loop-variant: in-place' "$H/scripts/loop.sh"; then VARIANT=in-place
  elif grep -q 'harness-loop-variant: worktree' "$H/scripts/loop.sh"; then VARIANT=worktree
  elif grep -q 'git worktree add' "$H/scripts/loop.sh"; then VARIANT=worktree   # legacy install, pre-marker
  else VARIANT=in-place; fi                                                     # legacy in-place (no worktree calls)
  LOOP_SRC="$TPL/scripts/loop.sh"; [ "$VARIANT" = in-place ] && LOOP_SRC="$TPL/scripts/loop.in-place.sh"
  # postflight also has two variants (the worktree board reads origin/main + the tNNN build branch; the
  # in-place board reads the LOCAL checkout + a dirty-tree check). Both install as scripts/postflight.sh.
  POSTFLIGHT_SRC="$TPL/scripts/postflight.sh"; [ "$VARIANT" = in-place ] && POSTFLIGHT_SRC="$TPL/scripts/postflight.in-place.sh"
  ```

- **Read the installed version:** `CUR_VERSION="$(cat "$H/.harness-version" 2>/dev/null || echo '')"`.
  An empty result means a **legacy install** (scaffolded before version stamping) — note that and proceed.
- If `CUR_VERSION` = `REF_VERSION`, tell the user the harness is already on the current version. Offer an
  optional **integrity re-scan** anyway (stages 3–5 still detect local drift); if they decline, stop here.
- **A version marker is a starting point, not a promise.** Never assume the installed files actually match
  `CUR_VERSION` — owners hand-edit mechanism files between upgrades. The content diffs in stage 3 are
  always the ground truth; the marker only selects which ledger entries explain the *expected* deltas.

## 1a. Adoption mode — legacy & hand-forked installs

Treat the run as an **adoption** (a full-content reconciliation rather than a ledger walk) when any of
these hold: there is no `.harness-version`; `loop.sh` has no `# harness-loop-variant:` header; canonical
paths are missing but similarly-named files exist elsewhere under `.harness/`; or stage-3 diffs contain
changes the selected ledger entries cannot explain. This is the normal shape of a harness that predates
the plugin or was hand-maintained in parallel with it — it is not an error. **When the divergence is in
prose files (`CLAUDE.md`, `README.md`, `docs/**`), offer the §1b standardize path first** — for a fork
that's usually a better fix than reconciling the same inline edits on every future upgrade.

- **Confirm the heuristics.** The variant grep in stage 1 (`git worktree add` → worktree; else in-place —
  an in-place loop resets the primary checkout with `git reset --hard origin/...` / a `cold_reset`
  function) is a guess on a fork: state which variant you detected and WHY, and have the user confirm
  before diffing against that reference.
- **Locate files by name, not just canonical path.** Old installs may keep a flat layout (`HARNESS.md`,
  `harness.env`, `TASKS.json`, overlays at the `.harness/` root) predating the `config/` + `tracking/` +
  `docs/` regroup. Match each reference file to its installed counterpart by filename anywhere under
  `.harness/`, diff against *that*, and list the canonical-layout moves as their own report section — the
  user may adopt the layout or keep theirs (a kept nonstandard layout means mechanism files will keep
  showing path-derivation diffs; say so).
- **Classify every differing mechanism file three ways, hunk by hunk**, instead of one overwrite/keep
  call per file:
  - **(a) plugin-newer** — the delta matches a ledger entry newer than the install's vintage (or, with no
    vintage, is present in the reference and clearly the shipped mechanism). Recommend *take*.
  - **(b) local-bespoke** — present in the target, absent from the reference, and not explained by any
    ledger entry: the owner's own hardening or project coupling (e.g. a custom integrate hook, extra
    logging, a daemon-shared lock). Recommend *keep*, and where the improvement is generic, **explicitly
    suggest upstreaming it as a plugin change** — a fork's fix that never reaches `templates/` is how the
    lineages drift apart.
  - **(c) conflict** — both sides changed the same area. Show both versions of the hunk; the user decides.
    Where they take the reference file wholesale, offer to re-apply their bespoke hunks on top.
- **A missing mechanism file may be a deliberate removal, not a gap.** (Real example: an install that
  drives all owner actions through its dashboard removed the `mark-*.sh` CLIs on purpose.) In adoption
  mode, present missing files as a question — "the reference ships X; your install doesn't have it —
  add it, or was it removed deliberately?" — never as an automatic "new files to add".
- **Facet vocabularies belong to the project.** `facets.json`'s `layer`/`workType`/`risk` word lists are
  user config, tailored and self-evolving per project (one real install uses `api / dashboard-logic / db /
  job / service / ui`, not the template's generic set). NEVER "correct" vocabulary toward the template.
  Only the policy knobs and schema keys the ledger explicitly names are reconcilable — and check the
  policy actually *consumes* what the config declares (a known fork drift: the vocabulary defined `risk`
  but the local `policy.jq` predated risk wiring and silently never read it — exactly the kind of
  plugin-newer mechanism delta to recommend taking).
- **Finish by making the next upgrade normal.** After applying approvals, ensure `loop.sh` carries the
  correct `# harness-loop-variant:` header (if the user kept a forked `loop.sh` without one, offer to
  insert just the header line — a one-line, behavior-free edit), then stamp `.harness-version` per stage
  5. From then on the install upgrades by ledger walk like any other.

## 1b. Standardize path — put a forked install on a clean PROSE-upgrade footing (offer when §1a fires)

When §1a detects a fork/legacy install whose **prose** files (`.harness/CLAUDE.md`, `README.md`,
`docs/**`) have diverged from the reference, the per-file reconcile in stages 3–4 will keep recurring on
every future upgrade — inline edits to plugin-owned prose collide with each new version forever. Offer a
one-time **standardize** as the recommended second path (the user picks; never force it):

> "Your harness's prose files have local edits, so each upgrade needs a manual reconcile. I can
> **standardize** them: move your customizations into the `.harness/custom/` overlay and restore the
> pristine files, so they're byte-identical to the plugin and every future upgrade of them is clean. Or I
> can continue the per-file reconcile (stages 3–4) and leave your edits in place. Which?"

**Scope: prose only.** Standardize touches the plugin-owned markdown prose files and nothing else —
scripts, `config/harness.env`, and `config/facets.json` stay on the normal adoption/additive flow (they
have no prose overlay; a forked script is upstreamed or reconciled, not "standardized"). Say so, so nothing
is over-promised. **But `.harness/custom/` now also carries behavior/config extension points** — lifecycle
hooks (`custom/hooks/on-<event>.sh`) and an append-only guard denylist (`custom/sensitive-paths.txt`). So if
a fork inlined deploy-on-drain logic or extra secret-guard patterns into `loop.sh`, the clean adoption is to
**move that into the matching `custom/` file and take the pristine loop** — call this out when you see it
(see `docs/HARNESS.md` §8.3).

If the user takes standardize, do this (report first, apply on confirm — the stage-4 rules still hold),
reusing §1a's three-way hunk classification:

- **Ensure the overlay exists.** If `.harness/custom/` (or a given overlay file) is missing, scaffold from
  the reference: `cp -pR "$TPL/custom/." "$H/custom/"` — but NEVER overwrite an overlay file that already
  holds user content (copy only the missing ones).
- **Per plugin-owned prose file** (`CLAUDE.md`←`harness-CLAUDE.md`, `README.md`, `docs/HARNESS.md`,
  `docs/LIMITATIONS.md`, `docs/designs/*.md`), diff the installed file against its pristine reference and
  split the hunks:
  - **local-bespoke additions** (present in the target, absent from the reference, not explained by any
    ledger entry — the owner's own notes/rules) → **append them to the matching `custom/<file>`** (append;
    never clobber existing overlay content). This is the move that preserves the customization.
  - **plugin-newer** hunks → taken automatically when you restore the pristine file (that's the goal).
  - **conflict** (the owner edited a line the plugin also ships/changed — an EDIT, not an addition) → the
    overlay can't hold an in-place edit; surface it (show both sides) and let the user choose *take
    reference* / *keep mine* / *resolve by hand*. If they keep an in-place edit, that file will NOT be
    byte-clean — say so plainly (it will still show a diff on the next upgrade).
- **Restore the pristine file** on approval: `cp -p "$ref" "$target"` (this also re-installs the file's
  `@custom/…` import / overlay pointer, since the reference carries it). For `.harness/CLAUDE.md`, confirm
  the restored file ends with its `@custom/CLAUDE.md` import so the overlay actually loads.
- **Root `CLAUDE.md` is the user's** (user-data, never auto-touched) — do NOT standardize it. If it holds
  harness-specific customizations, you MAY **offer** to move those into `.harness/custom/CLAUDE.md` and
  leave a pointer, but only on explicit confirmation; otherwise leave it entirely.

After a standardize, the prose files are byte-identical to the reference — re-stamp `.harness-version`
(stage 5) and note in the report that **future upgrades of these files are now clean ledger walks**, with
the customizations living safely in `.harness/custom/`.

## 2. Select the relevant migration entries

From `$LEDGER`, take the entries whose version transition falls in `(CUR_VERSION, REF_VERSION]`. If the
install is legacy (no `CUR_VERSION`), take the **whole ledger** and lean on the content diffs in stage 3.
These entries give you, per file: a plain-language "what changed" note, the exact additive `harness.env`
knob instructions, and any renames/removals or breaking notes to carry out.

## 3. Reconcile — build the dry-run report (NO writes in this stage)

Compare the target against the reference by class. **Only these files are ever reconciled** — map each to
its template source and compare bytes (`cmp -s A B` → identical):

**Mechanism files (plugin-owned; a clean one is safe to overwrite on approval):**

| Target (under `$H`) | Reference (under `$TPL`) |
|---|---|
| `scripts/loop.sh` | `$LOOP_SRC` (variant-selected above) |
| `scripts/postflight.sh` | `$POSTFLIGHT_SRC` (variant-selected above, like `loop.sh`) |
| `scripts/{supervise,repo-lock,mark-done,mark-failed,mark-reviewed,mark-done-bulk.test,check-task-scope,consolidate-ideas}.sh` | same name under `scripts/` |
| `scripts/policy.jq`, `scripts/consolidate-ideas.mjs` | same |
| `dashboard/{server,lib,lib.test}.js` | same |
| `docs/HARNESS.md`, `docs/LIMITATIONS.md`, `docs/designs/*.md` | same |
| `CLAUDE.md` | `harness-CLAUDE.md` |
| `README.md` | `README.md` |

**Config/schema files (reconcile *additively* only — never overwrite the user's values):**
`config/harness.env` (new knobs), `config/facets.json` (schema/vocabulary changes the ledger calls out).

For each file, classify:
- **identical** (`cmp -s` passes) → up to date, skip.
- **missing in target** → a **new file** the reference adds (a new script/doc). Candidate to add. (In
  adoption mode this is a question, not a recommendation — it may be a deliberate removal; see §1a.)
  Missing **`custom/` scaffolding** is always an add-candidate (scaffolding, not user content): the prose
  overlay stubs (an install predating the overlay won't have them, and the pristine files' `@custom/…`/pointer
  references need them) AND the extension `.example` stubs (`custom/hooks/on-*.sh.example`,
  `custom/sensitive-paths.txt.example`). Offer to add any that are missing; never treat a missing `custom/`
  scaffolding file as a deliberate removal — and NEVER overwrite a user's REAL `custom/hooks/*.sh` or
  `custom/sensitive-paths.txt` (that's their content).
- **differs** → capture the unified diff (`diff -u "$target" "$ref"`) **and** the matching ledger note(s).
  Do NOT decide anything yet — this goes in the report for the user to adjudicate.

Also from the ledger: list any **renames/removals** (e.g. a doc renamed — the old path present in the
target should be removed and the new one added) and any **breaking / MAJOR** items needing manual steps.

**Never diff, list, or touch the pure user-data files:** `tracking/*` (TASKS.json, IDEAS.md,
human-done/manual-fail/reviews.json), `tasks/*.md`, `worklog/*`, `ledgers/*.jsonl`, **`custom/*`** (the
customization overlay — the user's own prose: never reconcile, diff-to-overwrite, or clobber an *existing*
overlay file; the upgrade may only **add a missing overlay stub** from the reference — new-file scaffolding
so an install predating the overlay gets a home for the pristine files' pointers — or **append** to it via
the §1b standardize path), and the repo-root `CLAUDE.md`, `.gitignore`, `.github/workflows/ci.yml`, root
`README.md`. These belong to the user.

Emit a grouped report:
- **Up to date:** N files.
- **New files to add:** paths (+ one-line ledger reason each).
- **Changed — needs your call:** each path, its class, the ledger's "expected change" note, and the diff.
- **Config knobs to add:** each new `harness.env` knob (name + default) absent from the target.
- **Manual attention:** renames/removals, breaking notes, facets/schema changes.
- **Version:** `CUR_VERSION` (or "legacy/unknown") → `REF_VERSION`.

Present this report and STOP for confirmation before any writes.

## 4. Confirm + apply (only after the user has seen the report)

Walk the report and get the user's decision **per difference** — do not batch-decide anything that isn't
byte-identical. Use `AskUserQuestion` (batch related items). For each:
- **Changed mechanism file** → offer: *overwrite with the reference* / *keep mine* / *show full diff* /
  *skip*. Recommend overwrite only when the diff shows purely the shipped change with no sign of local
  edits — but the user chooses.
- **Changed `harness.env`** → offer: *add the missing knob(s) additively (preserving my values)* / *show
  diff* / *skip*. **Never** rewrite an existing knob's value; only append knobs the target lacks, using
  the reference's default line + comment (per the ledger's ACTION note).
- **`facets.json`** → surface the ledger's schema/vocab note; because this file is tailored + self-evolving
  per project, default to *leave it and report* unless the ledger flags a required schema migration.
- **New file** → offer: *add it* / *skip*.
- **Rename/removal** → confirm, then move/delete per the ledger.

Apply exactly what was approved:
- Overwrite an approved mechanism file: `cp -p "$ref" "$target"` (re-`chmod +x` any `scripts/*.sh`).
- Add an approved knob: append the reference's knob line(s) to `config/harness.env` (keep the section
  comment). Confirm you did not alter any existing value.
- Add a new file / perform a rename or removal as approved.

Cleanly-unmodified stale files may be grouped into a single "refresh these N files?" confirmation, but the
user must always be able to see what diverged before approving.

## 5. Re-stamp, validate, and report

- **Re-stamp:** write the new version — `printf '%s\n' "$REF_VERSION" > "$H/.harness-version"` — so the
  next upgrade starts from here. (Do this even on a legacy install; it also creates the marker for the
  first time.) If the retained `loop.sh` still lacks a `# harness-loop-variant:` header, offer to insert
  it now (see §1a) so the next run doesn't have to re-guess the variant.
- **Validate the upgraded harness is healthy:**
  ```bash
  for s in "$H"/scripts/*.sh; do bash -n "$s" || echo "SYNTAX ERROR: $s"; done
  node "$H/dashboard/lib.test.js"                 # the dashboard bucket tests
  for j in "$H"/config/facets.json "$H"/tracking/*.json; do jq empty "$j" || echo "BAD JSON: $j"; done
  ```
  If anything fails, report it prominently — the upgrade left the harness in a broken state and the user
  should revert (all changes are uncommitted).
- **Summarize:** files refreshed, knobs added, files skipped/kept, manual-attention items still open, and
  the version transition (`CUR_VERSION` → `REF_VERSION`).
- **Do NOT commit.** Leave every change uncommitted so the user can review the diff and commit themselves
  (all changes are git-revertible). Remind them to `git add -A && git commit` (and push) when satisfied.
- **Surface new customization features.** New plugin versions often add opt-in `custom/` extension points
  the user has never seen. After re-stamping, **invoke `/implementation-harness-customize --since <CUR_VERSION>`**
  (the version they upgraded FROM) to walk them through **just the features new since their install**,
  one at a time, and set up the ones they want. (No new features since `CUR_VERSION` → it says so and exits.)
  Skip this only if the user declines.

## ⚠️ Guardrails

- **Report before you write.** Stage 3 produces the report; stages 4–5 only run after the user approves.
- **Byte-identical is the only "leave it alone."** Any other difference is the user's call, never yours.
- **Additive-only for config.** New `harness.env` knobs get appended with template defaults; existing
  values are never rewritten. `facets.json` is left alone unless the ledger flags a required migration.
- **User data is off-limits:** never read-to-modify or write `tracking/`, `tasks/`, `worklog/`,
  `ledgers/`, `custom/` (except the §1b standardize path, which only *appends* to it), or the repo-root
  `CLAUDE.md` / `.gitignore` / `ci.yml` / `README.md`.
- **No auto-commit.** Leave the working tree dirty for the user to review.

## What this is NOT

- Not a fresh install — if there's no `.harness/scripts/loop.sh`, send the user to
  `implementation-harness-create`.
- Not a re-personalization — it does not re-run the setup interview or rewrite the user's DoD commands,
  model tiers, or facet layers. It carries plugin changes forward and preserves personalization.
- Not a backlog tool — it never touches tasks, worklog, ledgers, or reviews.
- Not a committer — it reports and leaves the diff for the user.
