---
name: ralph-loop-create-harness
description: >-
  Use when the user wants to set up the autonomous build harness (the Ralph-style single-loop
  TASKS.md builder) in a project — phrases like "scaffold the harness", "add the build loop to
  this repo", "set up ralph", "install loop.sh / supervise.sh". Runs a short interview (project
  name, purpose, stack, the format/lint/test/build Definition-of-Done commands, build artifacts,
  CI workflow name, model/effort, optional empirical run/backtest check), copies the verbatim
  harness files in, and writes the personalized CLAUDE.md, ci.yml, .gitignore, harness.env,
  README.md, and an initial TASKS.md. Leaves the project ready to run scripts/supervise.sh.
argument-hint: "[target project dir — defaults to cwd]"
allowed-tools: Read, Write, Edit, Bash, Glob, AskUserQuestion
---

# Scaffold the Ralph harness into a project

You are installing a self-contained autonomous build harness into a target project and
**personalizing** it. The harness is a single sequential shell loop that builds a `TASKS.md`
backlog one fully-verified task at a time, gated on green GitHub CI. Read this whole file,
then execute the steps **in order**. Be conversational and concise; confirm before anything
destructive.

## 0. Locate the bundled templates

The plugin ships the harness under a `templates/` dir. Resolve it robustly (the env var differs
by context) and cache the path as `TPL`:

```bash
TPL="${CLAUDE_PLUGIN_ROOT:-}/templates"
[ -d "$TPL" ] || TPL="${CLAUDE_SKILL_DIR}/../../templates"
TPL="$(cd "$TPL" && pwd)"   # normalize
ls "$TPL"                    # sanity: expect scripts/ docs/ .github/ worklog/ CLAUDE.md TASKS.md README.md gitignore
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

Glob the target for: `scripts/loop.sh`, `docs/HARNESS.md`, `CLAUDE.md`, `TASKS.md`,
`.github/workflows/ci.yml`, `README.md`.

- **Harness already present** (`scripts/loop.sh` or `docs/HARNESS.md` exists) → switch to
  **update mode**: offer (a) refresh the verbatim files from templates, (b) re-personalize
  specific files, (c) abort. Do only what's chosen. Never blast over personalized files silently.
- **User content present but no harness** (`CLAUDE.md` / `TASKS.md` / `README.md` exist) → these
  belong to the user. For each, ask: back up to `<file>.pre-harness` and replace, **merge** the
  harness content into the existing file, or **skip** it. Default to backup-then-write only with
  explicit consent.

## 3. Interview

Use `AskUserQuestion`, batching related questions. Gather:

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
6. **Model / effort** — default `claude-opus-4-8` / `high`. Allow override; warn against
   `max`/`xhigh` (HARNESS §3 — not worth the cost on a days-long loop).
7. **Caps** — `MAX_ATTEMPTS` (3), `MAX_ITERS` (100). Defaults are fine; only ask if they care.
8. **Empirical Verify step** — "Is there a way to run the app / a backtest to watch it behave?"
   If yes, capture the command and a short label (e.g. `run-app`). This seeds `Verify:` on relevant
   tasks; remember it for the initial TASKS.md and to pass to `ralph-loop-add-to-backlog`.
9. **GitHub remote** — check `git -C "<target>" remote get-url origin`. The loop integrates by
   pushing to `origin/main`, required when `REQUIRE_CI=1`. If there's no `origin`, warn and offer
   `REQUIRE_CI=0` as a stop-gap (record it as a limitation in `docs/LIMITATIONS.md`), or guide them
   to create the remote.

## 4. Copy the verbatim files

Byte-identical copies from `$TPL` into the target (do **not** template these):

```bash
T="<target>"
mkdir -p "$T/scripts" "$T/docs" "$T/.github/workflows" "$T/worklog"
cp -p "$TPL/scripts/loop.sh" "$TPL/scripts/supervise.sh" "$TPL/scripts/postflight.sh" "$T/scripts/"
cp -p "$TPL/docs/HARNESS.md" "$TPL/docs/LIMITATIONS.md" "$T/docs/"
cp -p "$TPL/worklog/.gitkeep" "$T/worklog/"
chmod +x "$T/scripts/"*.sh
```

## 5. Write the personalized files

Build each from the corresponding template, substituting the interview answers. Prefer targeted
`Edit`s over full rewrites where a template already has the right shape.

- **`CLAUDE.md`** — from `$TPL/CLAUDE.md`. Fill the "Project orientation" intro with the project
  name + purpose, and the "Tooling notes" with the stack and the exact DoD commands. Keep every
  golden rule and the harness-facing sections **verbatim**. (Honor the step-2 backup/merge/skip
  choice if a CLAUDE.md already existed.)
- **`.github/workflows/ci.yml`** — from `$TPL/.github/workflows/ci.yml`. Set `name:` to the chosen
  CI workflow name. **Replace the three placeholder steps** (the `Format check` with its `exit 1`,
  and the `Lint` / `Test` echoes) with the real DoD commands; add a `Build` step if the stack has
  one; add the stack's toolchain-setup step (e.g. `actions/setup-node`, `dtolnay/rust-toolchain`,
  `actions/setup-go`, `actions/setup-python`) and an install step where needed. Delete the
  "REPLACE the steps below" comment block.
- **`scripts/harness.env`** — from `$TPL/scripts/harness.env`. Set `MODEL`, `EFFORT`,
  `MAX_ATTEMPTS`, `MAX_ITERS`, `CI_WORKFLOW`, `REQUIRE_CI` to the answers. Keep the
  `: "${VAR:=…}"` form so real-env overrides still win.
- **`.gitignore`** — from `$TPL/gitignore` (note: no dot in the template). Append the chosen
  build-artifact lines, de-duplicated against any pre-existing `.gitignore` in the target. Write
  the result as `<target>/.gitignore`.
- **`docs/HARNESS.md` §5** — *optional, confirm first.* Replace the generic example command shapes
  in §5 with the project's real DoD commands so §5 and `ci.yml` match (the doc states "they must
  match"). Targeted Edit, not a rewrite.
- **`README.md`** — title = project name, opening = purpose, plus an initial implementation-status
  table seeded from the tasks you write in step 6. (Honor step-2 choice if a README existed —
  offer to inject a "Build status" section rather than overwrite.)

## 6. Initial `TASKS.md`

From `$TPL/TASKS.md`, keep the header/"how the loop works"/schema sections, and **replace the
illustrative T001–T005** with a minimal real backlog:

- Always include **T001 = "Project scaffold + CI green on an empty build"** (deps: none) — its job
  is to prove the CI gate end-to-end before any feature work. Give it a proper detail block.
- If the user described features, offer to **chain into `ralph-loop-add-to-backlog`** now to draft
  the rest of the backlog rather than leaving only T001. If they decline, leave just T001.
- Never leave the shipped example T002–T005 unless the user explicitly wants them.

## 7. Validation gate — refuse to report success otherwise

```bash
T="<target>"
grep -qE 'exit 1|TODO: replace' "$T/.github/workflows/ci.yml" && echo "FAIL: ci.yml still has placeholders"
# CI_WORKFLOW must equal ci.yml name:
W=$(grep -m1 '^name:' "$T/.github/workflows/ci.yml" | sed -E 's/^name:[[:space:]]*//')
grep -q "CI_WORKFLOW:=${W}" "$T/scripts/harness.env" || echo "WARN: CI_WORKFLOW != ci.yml name ($W)"
test -x "$T/scripts/loop.sh" && test -x "$T/scripts/supervise.sh" && test -x "$T/scripts/postflight.sh" || echo "FAIL: scripts not executable"
grep -q 'worklog/.result' "$T/.gitignore" && grep -q 'worklog/STATUS.md' "$T/.gitignore" || echo "WARN: loop scratch not git-ignored"
```

If `ci.yml` still contains `exit 1` or `TODO: replace`, the scaffold is **not** complete — fix it
(the placeholder CI fails by design until the real DoD commands are in). Resolve every `FAIL`
before declaring done.

## 8. Handoff

Summarize what you wrote, then print the exact next steps:

```sh
git add -A && git commit -m "Add ralph-harness build harness"
git push -u origin main          # the CI merge-gate needs a GitHub remote
chmod +x scripts/*.sh
DRY_RUN=1 scripts/loop.sh        # preview the next task the loop would build
scripts/supervise.sh             # leave running; re-runs the loop on a cadence
```

Remind the user:
- CI now runs their real DoD commands (the placeholder that fails on purpose has been replaced).
- A GitHub `origin` remote is required when `REQUIRE_CI=1`; without it the loop can't merge.
- `docs/HARNESS.md` is the authoritative design; `CLAUDE.md` is the per-project conventions.
- To grow the backlog later, run `/ralph-loop-add-to-backlog`.
