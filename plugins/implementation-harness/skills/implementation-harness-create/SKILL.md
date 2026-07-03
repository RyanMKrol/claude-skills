---
name: implementation-harness-create
description: >-
  Use when the user wants to set up the autonomous implementation harness (the Ralph-style
  single-loop TASKS.json builder) in a project — phrases like "scaffold the harness", "add the
  build loop to this repo", "set up the implementation harness", "install loop.sh / supervise.sh".
  Runs a short interview (project
  name, purpose, stack, the format/lint/test/build Definition-of-Done commands, build artifacts,
  CI workflow name, cold-start difficulty floor (cheapest tier), optional empirical
  run/backtest check), copies the verbatim harness files in, and writes the personalized CLAUDE.md,
  ci.yml, .gitignore, harness.env, README.md, and an initial TASKS.json. Leaves the project ready to
  run .harness/scripts/supervise.sh.
argument-hint: "[target project dir — defaults to cwd]"
allowed-tools: Read, Write, Edit, Bash, Glob, AskUserQuestion
---

# Scaffold the implementation harness into a project

You are installing a self-contained autonomous build harness into a target project and
**personalizing** it. The harness is a single sequential shell loop that builds a `TASKS.json`
backlog one fully-verified task at a time, at an auto-tuned (policy-chosen) model tier, gated on green GitHub CI. Read this whole file,
then execute the steps **in order**. Be conversational and concise; confirm before anything
destructive.

## 0. Locate the bundled templates

The plugin ships the harness under a `templates/` dir. Resolve it robustly (the env var differs
by context) and cache the path as `TPL`:

```bash
TPL="${CLAUDE_PLUGIN_ROOT:-}/templates"
[ -d "$TPL" ] || TPL="${CLAUDE_SKILL_DIR}/../../templates"
TPL="$(cd "$TPL" && pwd)"   # normalize
ls "$TPL"                    # sanity: expect config/ docs/ scripts/ tasks/ tracking/ worklog/ .github/ CLAUDE.md README.md gitignore
```

If `TPL` doesn't resolve to a dir containing `scripts/loop.sh`, stop and tell the user the
plugin install looks broken (templates not found).

> Note the template stores the gitignore as `gitignore` (no leading dot) so it ships inside the
> plugin; you will write it into the target as `.gitignore`.

## 1. Resolve the target project

- Target dir = the skill argument if given, else the current working directory.
- Confirm it's a git repo: `git -C "<target>" rev-parse --git-dir` succeeds. If not, ask whether
  to `git init` it (the loop needs git + ideally a GitHub `origin`).
- Compute and **surface** the derived loop name: `NAME="$(basename "<target>")"`. Tell the user:
  "`loop.sh` will name its worktree `../${NAME}-loop` and its lock `${NAME}-loop.lock`." If a
  sibling project shares that basename, warn about the clash.

## 2. Pre-flight: don't clobber existing work

Glob the target for: `.harness/scripts/loop.sh`, `.harness/docs/HARNESS.md`, `CLAUDE.md`,
`.harness/tracking/TASKS.json`, `.github/workflows/ci.yml`, `README.md`. Also require `jq` on PATH
(the loop parses `TASKS.json` with it) — if missing, tell the user to `brew install jq`.

- **Harness already present** (`.harness/scripts/loop.sh` or `.harness/docs/HARNESS.md` exists) →
  switch to **update mode**: offer (a) refresh the verbatim files from templates, (b) re-personalize
  specific files, (c) abort. Do only what's chosen. Never blast over personalized files silently.
- **User content present but no harness** (`CLAUDE.md` / `TASKS.json` / `README.md` exist) → these
  belong to the user. For each, ask: back up to `<file>.pre-harness` and replace, **merge** the
  harness content into the existing file, or **skip** it. Default to backup-then-write only with
  explicit consent.

## 3. Interview

Use `AskUserQuestion`, batching related questions. Gather:

0. **Isolation mode (ask first — it decides which loop variant is installed).** "Can the loop
   build **and** verify entirely from what's committed to the remote, or does it need untracked /
   gitignored local state (private files, local datasets, secrets-driven fixtures)?"
   - *Everything committed* → **worktree** variant (default; max isolation; safe to run while other
     work happens in the checkout). Installs `.harness/scripts/loop.sh`.
   - *Needs local state* → **in-place** variant: works directly on `main` in the primary checkout
     so it can see that state; safety = one-commit-per-task + a load-bearing pre-push sensitive-path
     guard. Installs `scripts/loop.in-place.sh` as `.harness/scripts/loop.sh`. (See
     `.harness/docs/HARNESS.md` "In-place variant".)
   Record the answer as `ISOLATION=worktree|in-place`; steps 4 and 7 branch on it. Note that the
   `../<repo>-loop` worktree/lock naming surfaced in step 1 applies to the **worktree** variant only.

1. **Project name** (default = `NAME`) and a one-line **purpose**.
2. **Stack**: Rust / Node / Python / Go / Other. This drives the default DoD commands and
   `.gitignore` lines. The template's `docs/HARNESS.md` §5 and `.github/workflows/ci.yml` comments
   list canonical examples per stack — use them as pre-filled, **editable** suggestions:
   - **Rust** — format `cargo fmt --all --check`; lint `cargo clippy --all-targets --all-features -- -D warnings`; test `cargo test --all-features`; build (implicit / `cargo build`). gitignore `/target`.
   - **Node** — install `npm ci`; format `npm run format:check`; lint `npm run lint`; test `npm test`; build `npm run build`. gitignore `/node_modules`, `/dist`.
   - **Python** — format `ruff format --check .`; lint `ruff check .`; test `pytest`. gitignore `__pycache__/`, `*.pyc`, `.venv/`.
   - **Go** — format `test -z "$(gofmt -l .)"`; lint `go vet ./...`; test `go test ./...`; build `go build ./...`. gitignore `/bin`.
3. **Definition-of-Done commands** — confirm/edit the four (format, lint, test, build). These are
   load-bearing: they go verbatim into CI and are what the loop runs locally. Drop the build step
   if the stack folds it into test.
4. **.gitignore build artifacts** — confirm/extend the stack suggestion (plus anything
   project-specific, e.g. local DB files, captures).
5. **CI workflow name** — default `CI`. It must equal `name:` in `ci.yml` **and** `CI_WORKFLOW` in
   `harness.env`; you keep them in lockstep. Only ask if they want a non-default.
6. **Cold-start difficulty floor** — the model/effort a task STARTS at *before* difficulty
   auto-tuning has data. It lives in `harness.env` (`MODEL`/`EFFORT`) — the SINGLE source; it is
   NOT mirrored into `TASKS.json`.
   **Default to the CHEAPEST tier — `claude-sonnet-4-6` / `low`** (bias-cheap). Explain why: the
   policy starts every task at this floor and ESCALATES up the global tier ladder
   (`facets.json .tiers.ladder`) on repeated failure, then *learns* the cheapest tier that reliably
   builds each kind of task (faceted calibration). So there is **no per-task model guessing and no
   per-task escalation ladder** any more — the global ladder + the calibrated policy own model
   choice. Only raise this floor if you have a concrete reason; otherwise take the cheap default.
7. **Caps** — `MAX_ATTEMPTS` (2), `MAX_ITERS` (100). Defaults are fine; only ask if they care.
8. **Empirical Verify step** — "Is there a way to run the app / a backtest to watch it behave?"
   If yes, capture the command and a short label (e.g. `run-app`). This seeds `Verify:` on relevant
   tasks; remember it for the initial TASKS.json and to pass to `implementation-harness-add-to-backlog`.
9. **GitHub remote** — check `git -C "<target>" remote get-url origin`. The loop integrates by
   pushing to `origin/main`, required when `REQUIRE_CI=1`. If there's no `origin`, warn and offer
   `REQUIRE_CI=0` as a stop-gap (record it as a limitation in `.harness/docs/LIMITATIONS.md`), or guide them
   to create the remote.
10. **Long-running product / deploy hook (`INTEGRATE_HOOK`).** "Does this project run a long-lived
    process — a daemon, server, or preview — that must be restarted/redeployed to reflect new code?"
    The loop builds and commits but does **not** restart anything, so a running instance keeps
    serving **stale code** after a task lands — an easy-to-miss outage (e.g. a DB-schema rename
    merges, but the live process still queries the old tables). If yes, capture the restart/deploy
    command and set it as `INTEGRATE_HOOK` in `harness.env`; the loop runs it after each task
    integrates so what's running always matches `main`. If no (a library/CLI with nothing
    long-lived), leave it empty.
11. **Visual UI verification (`UI_VERIFY_HOOK`) — optional, only ask if the project has a browser
    UI.** "Does this project have a browser UI worth visually verifying — a page/component that
    could pass every automated check while still rendering wrong?" If yes, ask for a command that
    produces something inspectable (a screenshot script, or similar) and set it as `UI_VERIFY_HOOK`
    in `harness.env`; it's injected into the builder + auditor prompt ONLY for tasks whose
    `facets.workType` is `component` (see `.harness/docs/designs/ui-verification.md` for the
    rationale and an optional `PAGES`/`FLOWS` convention worth adopting for larger UI surfaces). If
    no, or the project has no UI at all, leave it empty — zero cost either way.

## 4. Copy the verbatim files

Byte-identical copies from `$TPL` into the target (do **not** template these):

The whole harness lives in a self-contained **`.harness/`** folder at the repo root (`$T` is the
REPO ROOT), grouped by kind: `config/` (facets + env knobs), `docs/` (design docs), `ledgers/`
(calibration data), `scripts/` (loop + tooling), `tasks/` (per-task specs), `tracking/` (the
backlog + owner overlays), `worklog/` (per-task history) — only `.github/workflows/ci.yml` lives at
the repo root (GitHub requires it there). The repo-root `CLAUDE.md`, `.gitignore`, `README.md` are
written/merged in §5. Note there are **two CLAUDE.md files** and they are NOT the same: the
**repo-root `CLAUDE.md`** (§5, personalized — the project's full conventions + golden rules, loaded
for ALL work) and **`.harness/CLAUDE.md`** (copied verbatim here — the focused *authoring* mandate
that loads whenever Claude works inside `.harness/`, i.e. exactly when editing `TASKS.json`, telling
it to invoke the add-to-backlog skill).

```bash
T="<target>"          # the REPO ROOT
H="$T/.harness"       # the self-contained harness folder (everything but ci.yml lives here)
mkdir -p "$H/config" "$H/dashboard" "$H/docs/designs" "$H/ledgers" "$H/scripts" "$H/tasks" "$H/tracking" "$H/worklog" "$H/.pending-tasks" "$H/.pending-questions" "$T/.github/workflows"
# Install the loop variant chosen in step 0 — BOTH install as .harness/scripts/loop.sh.
if [ "${ISOLATION:-worktree}" = in-place ]; then
  cp -p "$TPL/scripts/loop.in-place.sh" "$H/scripts/loop.sh"
else
  cp -p "$TPL/scripts/loop.sh" "$H/scripts/loop.sh"
fi
cp -p "$TPL/scripts/supervise.sh" "$TPL/scripts/postflight.sh" "$TPL/scripts/repo-lock.sh" "$TPL/scripts/policy.jq" "$H/scripts/"
cp -p "$TPL/scripts/mark-done.sh" "$TPL/scripts/mark-failed.sh" "$TPL/scripts/mark-reviewed.sh" "$TPL/scripts/mark-done-bulk.test.sh" "$TPL/scripts/check-task-scope.sh" "$H/scripts/"
cp -p "$TPL/scripts/consolidate-ideas.sh" "$TPL/scripts/consolidate-ideas.mjs" "$H/scripts/"   # ideas->tasks pipeline consolidation (needs Node — see below)
cp -p "$TPL/dashboard/server.js" "$TPL/dashboard/lib.js" "$TPL/dashboard/lib.test.js" "$H/dashboard/"   # portable backlog viewer — `node .harness/dashboard/server.js` (needs Node on the machine, regardless of the target project's own stack)
touch "$H/.pending-tasks/.gitkeep" "$H/.pending-questions/.gitkeep"
cp -p "$TPL/config/facets.json" "$H/config/facets.json"   # facet vocabulary + tier ladder + policy knobs (tailored below)
cp -p "$TPL/docs/HARNESS.md" "$TPL/docs/LIMITATIONS.md" "$H/docs/"
cp -p "$TPL/docs/designs/"*.md "$H/docs/designs/"
cp -p "$TPL/tasks/"*.md "$H/tasks/"                    # per-task Markdown specs (## Do / ## Done when), one per example task — replace with yours in §6
cp -p "$TPL/harness-CLAUDE.md" "$H/CLAUDE.md"          # .harness/CLAUDE.md — authoring mandate, loads when working in .harness/
cp -p "$TPL/README.md" "$H/README.md"                  # .harness/README.md — the harness's own quick-start explainer (distinct from the repo-root README.md written in §5)
cp -p "$TPL/tracking/human-done.json" "$TPL/tracking/manual-fail.json" "$TPL/tracking/reviews.json" "$H/tracking/"   # owner-overlay files (loop reads, owner tooling writes) — seed empty
cp -p "$TPL/tracking/IDEAS.md" "$H/tracking/IDEAS.md"   # gitignored ideas inbox — see implementation-harness-capture-idea / -convert-ideas
cp -p "$TPL/worklog/.gitkeep" "$H/worklog/"
: >"$H/ledgers/outcomes.jsonl"; : >"$H/ledgers/failures.jsonl"   # seed empty, committed ledgers (calibration input; diagnostics)
chmod +x "$H/scripts/"*.sh
```

**Then tailor `facets.json` to THIS project (difficulty auto-tuning — see `.harness/docs/designs/difficulty-autotune.md`):**
- The `work-type`, `risk`, and `policy` axes are universal — leave them.
- The **`tiers.ladder`** is the global difficulty ladder — set it to the models this project uses,
  cheapest → priciest (it should span the step-6 default model/effort + any escalation tiers).
- The **`facets.layer`** values are a generic STARTER set (`frontend`/`backend`/`data`/`infra`/`build`/`meta`).
  Inspect the target repo's top-level structure (its source dirs / architecture) and **replace them
  with a fitted `layer` set** (e.g. a CLI tool might use `commands`/`core`/`io`/`docs`) — one-line
  defs + a difficulty hint each. This is the same clustering the poor-fit gate runs later; here it's
  a one-time fit at setup. Keep it small (≈4–8 values). The harness self-evolves the layers over time
  via the poor-fit gate, so don't over-think it — just make it roughly match the repo today.

## 5. Write the personalized files

Build each from the corresponding template, substituting the interview answers. Prefer targeted
`Edit`s over full rewrites where a template already has the right shape.

- **`CLAUDE.md`** (repo ROOT — its golden rules, incl. the facets-authoring mandate, must load for ALL work, not just inside `.harness/`) — from `$TPL/CLAUDE.md`. Fill the "Project orientation" intro with the project
  name + purpose, and the "Tooling notes" with the stack and the exact DoD commands. Keep every
  golden rule and the harness-facing sections **verbatim**. (Honor the step-2 backup/merge/skip
  choice if a CLAUDE.md already existed.)
- **`.github/workflows/ci.yml`** — from `$TPL/.github/workflows/ci.yml`. Set `name:` to the chosen
  CI workflow name. **Replace the three placeholder steps** (the `Format check` with its `exit 1`,
  and the `Lint` / `Test` echoes) with the real DoD commands; add a `Build` step if the stack has
  one; add the stack's toolchain-setup step (e.g. `actions/setup-node`, `dtolnay/rust-toolchain`,
  `actions/setup-go`, `actions/setup-python`) and an install step where needed. Delete the
  "REPLACE the steps below" comment block.
- **`.harness/config/harness.env`** — from `$TPL/config/harness.env`. Set `MODEL`, `EFFORT`,
  `MAX_ATTEMPTS`, `MAX_ITERS`, `CI_WORKFLOW`, `REQUIRE_CI`, and — if the step-10 deploy/restart
  command was given — `INTEGRATE_HOOK`, and — if the step-11 UI-verification command was given —
  `UI_VERIFY_HOOK` (leave both empty if not answered), to the answers (these `MODEL`/`EFFORT` are the cold-start difficulty FLOOR — the cheapest tier; the
  policy escalates up the global ladder from here and learns per-difficulty). Keep the `: "${VAR:=…}"` form so real-env
  overrides still win.
- **`.gitignore`** — from `$TPL/gitignore` (note: no dot in the template). Append the chosen
  build-artifact lines, de-duplicated against any pre-existing `.gitignore` in the target. Write
  the result as `<target>/.gitignore`.
- **`.harness/docs/HARNESS.md` §5** — *optional, confirm first.* Replace the generic example command shapes
  in §5 with the project's real DoD commands so §5 and `ci.yml` match (the doc states "they must
  match"). Targeted Edit, not a rewrite.
- **`README.md`** — title = project name, opening = purpose, plus an initial implementation-status
  table seeded from the tasks you write in step 6. (Honor step-2 choice if a README existed —
  offer to inject a "Build status" section rather than overwrite.)

## 6. Initial `TASKS.json`

From `$TPL/tracking/TASKS.json`, keep the top-level shape (`_doc`, `version`) and **replace the
illustrative T001–T005 in `.tasks`** with a minimal real backlog. The cold-start floor lives in
`config/harness.env` (`MODEL`/`EFFORT`, cheapest — `claude-sonnet-4-6` / `low`), NOT in `TASKS.json`. A
task carries NO per-task `model`/`effort`/`escalation`; difficulty is auto-tuned from `facets` + the
outcomes ledger.

**Each task's `do` + `done-when` do NOT live in the JSON** — they go in a per-task Markdown spec at
`.harness/tasks/TNNN.md` (sections `## Do` / `## Done when`), referenced by the task's `spec` field.
Every BUILDABLE task also carries `facets: { layer, workType, risk[] }` (values from
`.harness/config/facets.json`); gated (gate / needs-human) tasks carry neither facets nor a real spec body.
The shipped `.harness/tasks/T00N.md` are examples — when you replace the example tasks, write a
matching `.harness/tasks/TNNN.md` for each new task and delete the unused example specs.

- Always include **T001 = "Project scaffold + CI green on an empty build"** (`dependsOn: []`) — its
  job is to prove the CI gate end-to-end before any feature work. Give it a full task object
  (it's mechanical, it builds at the cheap cold-start floor like every task; the policy escalates only on real failure).
- If the user described features, offer to **chain into `implementation-harness-add-to-backlog`** now to draft
  the rest of the backlog rather than leaving only T001. If they decline, leave just T001.
- Never leave the shipped example T002–T005 unless the user explicitly wants them.
- Keep it valid: end with `jq empty "$T/.harness/tracking/TASKS.json"` and fix any error before continuing.

## 7. Validation gate — refuse to report success otherwise

```bash
T="<target>"
grep -qE 'exit 1|TODO: replace' "$T/.github/workflows/ci.yml" && echo "FAIL: ci.yml still has placeholders"
# CI_WORKFLOW must equal ci.yml name:
W=$(grep -m1 '^name:' "$T/.github/workflows/ci.yml" | sed -E 's/^name:[[:space:]]*//')
grep -q "CI_WORKFLOW:=${W}" "$T/.harness/config/harness.env" || echo "WARN: CI_WORKFLOW != ci.yml name ($W)"
for s in loop.sh supervise.sh postflight.sh repo-lock.sh mark-done.sh mark-failed.sh mark-reviewed.sh mark-done-bulk.test.sh check-task-scope.sh consolidate-ideas.sh; do
  test -x "$T/.harness/scripts/$s" || echo "FAIL: scripts/$s not executable"
  bash -n "$T/.harness/scripts/$s" || echo "FAIL: scripts/$s has a shell syntax error"
done
"$T/.harness/scripts/repo-lock.sh" --selftest >/dev/null || echo "FAIL: repo-lock self-test failed"
"$T/.harness/scripts/mark-done-bulk.test.sh" >/dev/null || echo "FAIL: mark-done-bulk.test.sh failed"
jq empty "$T/.harness/tracking/human-done.json" "$T/.harness/tracking/manual-fail.json" "$T/.harness/tracking/reviews.json" || echo "FAIL: an owner-overlay file is not valid JSON"
command -v node >/dev/null || echo "WARN: node not installed — the dashboard and ideas pipeline (.harness/dashboard/, .harness/scripts/consolidate-ideas.mjs) need it regardless of this project's own stack"
node --check "$T/.harness/dashboard/server.js" 2>/dev/null || echo "FAIL: dashboard/server.js has a syntax error"
node --check "$T/.harness/dashboard/lib.js" 2>/dev/null || echo "FAIL: dashboard/lib.js has a syntax error"
node "$T/.harness/dashboard/lib.test.js" >/dev/null 2>&1 || echo "FAIL: dashboard/lib.test.js failed"
node --check "$T/.harness/scripts/consolidate-ideas.mjs" 2>/dev/null || echo "FAIL: consolidate-ideas.mjs has a syntax error"
grep -q '.harness/tracking/IDEAS.md' "$T/.gitignore" && grep -q '.harness/.pending-tasks' "$T/.gitignore" || echo "WARN: ideas-pipeline scratch not git-ignored"
grep -q '.harness/worklog/.result' "$T/.gitignore" && grep -q '.harness/worklog/STATUS.md' "$T/.gitignore" && grep -q '.harness/worklog/.failures.buf' "$T/.gitignore" || echo "WARN: loop scratch not git-ignored"
jq empty "$T/.harness/tracking/TASKS.json" || echo "FAIL: TASKS.json is not valid JSON"
for sp in $(jq -r '.tasks[].spec // empty' "$T/.harness/tracking/TASKS.json"); do test -f "$T/$sp" || echo "FAIL: spec file $sp (referenced by a task) is missing"; done
for t in $(jq -r '.tasks[]|select(.gate==null)|select(.facets|not)|.id' "$T/.harness/tracking/TASKS.json"); do echo "WARN: buildable task $t has no facets (no auto-tuning)"; done
command -v jq >/dev/null || echo "FAIL: jq not installed (the loop needs it to parse TASKS.json)"
DRY_RUN=1 "$T/.harness/scripts/loop.sh" >/dev/null 2>&1 || echo "FAIL: DRY_RUN loop.sh errored (selection/backlog won't parse)"
# in-place variant only: prove the load-bearing pre-push guard regex is correct
grep -q -- '--guard-selftest' "$T/.harness/scripts/loop.sh" && { "$T/.harness/scripts/loop.sh" --guard-selftest >/dev/null || echo "FAIL: pre-push guard self-test failed"; }
```

The `bash -n` + `DRY_RUN` smoke catch a generated/edited script that won't parse or run **at
install time** rather than on the first real cycle — e.g. a `set -u` unbound-variable trap. For an
in-place install, the guard self-test must pass before you declare done.

If `ci.yml` still contains `exit 1` or `TODO: replace`, the scaffold is **not** complete — fix it
(the placeholder CI fails by design until the real DoD commands are in). Resolve every `FAIL`
before declaring done.

## 8. Handoff

Summarize what you wrote, then print the exact next steps:

```sh
git add -A && git commit -m "Add implementation harness"
git push -u origin main                    # the CI merge-gate needs a GitHub remote
chmod +x .harness/scripts/*.sh
DRY_RUN=1 .harness/scripts/loop.sh         # preview the next task the loop would build
.harness/scripts/supervise.sh              # leave running; re-runs the loop on a cadence
```

Remind the user:
- CI now runs their real DoD commands (the placeholder that fails on purpose has been replaced).
- A GitHub `origin` remote is required when `REQUIRE_CI=1`; without it the loop can't merge.
- `docs/HARNESS.md` is the authoritative design; `CLAUDE.md` is the per-project conventions.
- To grow the backlog later, run `/implementation-harness-add-to-backlog`.
