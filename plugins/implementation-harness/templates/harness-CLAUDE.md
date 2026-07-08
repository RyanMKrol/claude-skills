# .harness/CLAUDE.md — rules for working *inside* the build harness

Loaded whenever Claude works with files in `.harness/` — notably when adding or editing backlog
tasks in `TASKS.json`. It keeps the harness's own authoring rules *with* the harness, so they travel
with it and surface at the authoring moment. (Repo-wide conventions are in the root `CLAUDE.md`; the
loop's design is in `docs/HARNESS.md` + `docs/designs/`.)

## ⚠️ STOP before editing any `.harness/` file in place — customize via `custom/` instead

**This is the #1 way to wreck the harness's upgradeability — treat an in-place edit as a red flag.** The
plugin owns almost everything under `.harness/`: `scripts/*` (including `loop.sh`), `.harness/CLAUDE.md`
(this file), `README.md`, and everything under `docs/`. `implementation-harness:implementation-harness-upgrade` keeps these
**byte-identical to the plugin** and refreshes them in place. The moment you hand-edit one of them, that file
stops matching the reference, and **every future upgrade of it degrades into slow, error-prone manual
reconciliation** — the exact "forked install that can never cleanly upgrade" trap the `custom/` overlay
exists to prevent.

**So: do NOT edit a plugin-owned `.harness/` file in place. If you (or the owner) are about to — STOP and
flag it loudly:** say plainly that hand-editing this file forfeits clean upgrades and forces painful manual
reconciliation from here on, and route the change into `.harness/custom/` instead. Everything you'd
realistically want to customize has a supported `custom/` home the upgrade **never** touches:

| You want to… | Do it in `custom/` (NOT by editing a plugin-owned file) |
|---|---|
| add project conventions / authoring rules | `custom/CLAUDE.md` (auto-loaded — this file imports it) |
| run something on a loop event (deploy on drain, notify on block, …) | `custom/hooks/on-<event>.sh` |
| block more secret paths from being pushed | `custom/sensitive-paths.txt` (append-only) |
| add richer visual-verification guidance | `custom/visual-verify-{build,audit}.md` |
| inject a standing rule into every build/audit (e.g. no live paid-API calls) | `custom/{build,audit}-preamble.md` |
| label the dashboard so it's distinguishable from other projects' | `custom/dashboard-title.txt` |
| add project notes to a shipped doc | the matching `custom/docs/…` overlay |

Not sure which, or want a guided setup? Run **`implementation-harness:implementation-harness-customize`** —
it walks these one at a time and drafts them with you. Full mechanics: `docs/HARNESS.md` §8.3.

**The only genuine exception** is deeper `loop.sh`/script *logic* that no hook or `custom/` file can express
(and `harness.env` scalar knobs, which are meant to be edited). Even then, don't hand-edit the script in
place — **flag it to be upstreamed into the plugin**, because a hand-edited script can't be cleanly upgraded.

## Adding a backlog task → invoke the add-to-backlog skill

To add a task to the backlog, invoke the **`implementation-harness-add-to-backlog`** skill. It is the **single
source of authoring logic**: it assigns the task's **facets** (difficulty auto-tuning), pairs every
chooser task with a review task, runs the **poor-fit / layer-evolution gate**, and writes a
schema-correct task object + its `tasks/TNNN.md` spec. Prefer it over hand-editing `TASKS.json`.

## The floor (holds even on a direct edit)

If the skill isn't available and you edit `TASKS.json` directly, the non-negotiable invariant is:
**every BUILDABLE task MUST carry `facets: { layer, workType, risk[] }`**, with values chosen ONLY
from `config/facets.json`'s controlled vocabulary (use the task's `scope` paths to pick the `layer`).
`needs-human` (gated) tasks are **carved out** — they get NO facets. A buildable task missing facets
gets no auto-tuning and the loop **pre-flight WARNs** about it. Background:
`docs/designs/difficulty-autotune.md`.

## `scope` is the rigour dial — pick its granularity deliberately

A task's `scope` array is a **binding contract**: the loop's structural gate fails the build if the
diff touches any file outside it (exact-path match, or a directory prefix — a trailing `/**`, `/*`,
or `/` is normalized to that directory). Always-allowed regardless of scope: the task's own
`worklog/<id>.md`, **test files**, lockfiles (`package-lock.json`/`yarn.lock`/`pnpm-lock.yaml`), and
anything in `SCOPE_EXEMPT_GLOBS`. Choose granularity to match the risk:

- **Greenfield / self-contained work** → a directory glob (`src/feature/**`). Gives the builder room
  to create the files it needs without tripping the gate.
- **Surgical / shared / dangerous edits** → the **exact files** (`src/auth/session.ts`). The tighter
  the scope, the smaller the blast radius a cheap builder can cause.

**Author scope from the files the spec actually tells the builder to edit.** The most common way a
task fails `failed:blocked` is a spec that says "edit `X`" where `X` isn't in `scope` — the builder
touches it, the structural gate rejects the diff, and the attempt is wasted. Run
`scripts/check-task-scope.sh [TNNN]` after authoring (an advisory linter) — it flags files a spec
mentions that no scope entry covers, before the loop ever tries to build the task.

## Completing a 🔒 needs-human task — do it interactively, never route it back through the loop

A `needs-human` task's completion mechanism **is** the interactive session: do the human step, then
mark it done with `scripts/mark-done.sh TNNN` (which writes the owner overlay the loop reconciles).
**Do NOT** run `loop.sh TNNN` at an already-built gate/needs-human task to "finish" it — the loop
builds every task COLD from its spec and, on an `expectsTest:true` task with nothing left to do, will
escalate up the ladder forever; under `LOOP_AUTORESET=1` it can also stash unrelated local work. The
loop is for buildable tasks; gates are for you.

## Capturing & converting ideas

Rough ideas go in `tracking/IDEAS.jsonl` (a committed inbox — JSONL, one `{id, title, description,
capturedAt}` object per line) via the capture-idea skill — zero ceremony, no interview. The
convert-ideas skill later turns a batch of them into real backlog tasks (one agent per idea → a
single locked `scripts/consolidate-ideas.sh` pass that allocates ids, writes specs, and removes the
converted rows). Both are documented here so the flow surfaces at the authoring surface, not just
in the README.

## Operating the loop — the four operational skills

**⚠️ NEVER run `supervise.sh` or `loop.sh` yourself — not even if explicitly asked.** Starting the
build loop is a deliberate action only the human takes, from their own terminal. This is enforced in
code too (both scripts hard-refuse the moment they detect `$CLAUDECODE` — i.e. being invoked from
inside ANY Claude Code session, interactive or unattended, with no override) — but say so plainly and
decline BEFORE attempting it; don't try it and let the refusal surprise the user. If asked to "start
the loop" / "run the harness", tell them to run `.harness/scripts/supervise.sh` themselves.

Beyond authoring, four skills help RUN the loop safely:

- **`/implementation-harness-pre-loop-checkin`** — read-only GO/NO-GO vetting before an unattended run
  (needs-human blockers, dirty tree / running loop / lock, per-task facets/spec/scope quality). Changes nothing.
- **`/implementation-harness-fix-scope-gaps`** — the fix-side companion to pre-loop-checkin's
  scope-authoring check: fans out a cheap-model judge per warning (real gap vs false positive) and
  fixes confident real gaps directly, so a NO-GO scope-gap advisory doesn't require inspecting every
  warning by hand.
- **`/implementation-harness-loop-recover`** — after a manual Ctrl-C interrupt, diagnose AND fix the
  state it left (orphaned tasks, stale lock, dirty tree / leftover worktree, ledger noise), then leave
  the loop restartable. This is the ONLY safe way to hand-correct loop state — do the recovery through
  it, not ad-hoc, and only ever while the loop is stopped.
- **`/implementation-harness-review-failed`** — sweep `failed`/`blocked` tasks and author
  better-specified follow-ups (never a blind retry; never reopens the terminal task).

## A task touching `.harness/**` MUST be `gate: "needs-human"` — never buildable

Any backlog task whose `scope` array includes a path prefixed `.harness/`, OR whose
`facets.layer == "harness"`, **MUST** be authored `gate: "needs-human"` — never `gate: null`
(buildable). (`gate` is only ever `null` or `"needs-human"`.) This applies regardless of how the task
is authored — the add-to-backlog skill, the ideas-conversion pipeline, or a direct hand-edit of `TASKS.json`.

**Why:** the harness's own build/task-selection/calibration machinery is what constrains every
OTHER task the loop builds. A bad *unsupervised* edit here is uniquely dangerous compared to an
ordinary buildable task going wrong — it can corrupt `TASKS.json`, break task selection or
escalation, or silently defeat the loop's own safety rails, edited by the very process it
constrains, with no human in the loop. A human must look at a diff to `.harness/**` before it's
built, not just before it's merged.

Enforced two ways: documented here (loads whenever Claude works inside `.harness/`), and a
non-fatal pre-flight WARN in the loop (mirrors the missing-facets WARN) that names any currently
buildable task touching `.harness/` without the required gate — it does not stop the loop or
change selection, it's a backlog-hygiene signal.

## Marking a task done / failed / reviewed → use the mark-*.sh scripts

Never hand-edit `TASKS.json`'s `status` field directly — the loop is its sole writer.
`scripts/mark-done.sh TNNN` marks a `needs-human` task done; `scripts/mark-failed.sh TNNN "<reason>"`
overturns a `done` task the loop/audit got wrong; `scripts/mark-reviewed.sh TNNN` sets the cosmetic
reviewed flag. Each writes one `tracking/*.json` overlay file, which `reconcile_overlays()` promotes
into `TASKS.json` status on the loop's next iteration. Background: `docs/designs/manual-fail-signal.md`.

## Known-but-deferred issues (log real incidents here, dated)

A running, dated log of real problems hit while operating THIS harness — not aspirational design
notes, actual incidents with a root cause and a fix. This is institutional memory: the next person
(human or agent) debugging a strange loop failure should check here before re-deriving the cause
from scratch.

**Two-strikes rule.** The first time you hit a surprising harness behavior, don't silently work
around it — **flag it to the owner** and log it here. A *second* occurrence is the signal that it's a
real mechanism bug worth actually fixing (a one-off may be environmental; a repeat is a pattern).

Add an entry whenever you diagnose a genuine harness-mechanism bug (not a one-off
project bug), in this shape:

```
### YYYY-MM-DD — <one-line symptom>
**Root cause:** <what was actually wrong, and why it wasn't obvious>
**Fix:** <what changed, with a file/function pointer>
**Verification:** <how you confirmed the fix actually works>
```

Keep entries even after the fix ships — they're the record of *why* the current behavior exists,
which saves the next debugging session from re-discovering the same failure mode. (No entries yet
in a freshly-scaffolded project — this section is the template for adding them.)

---

<!-- Project-specific harness instructions live in the customization overlay below (upgrades never touch it). -->
@custom/CLAUDE.md
