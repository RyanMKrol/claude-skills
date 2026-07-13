---
name: implementation-harness-evaluate-fit
description: >-
  Use when the user wants to check whether an already-installed harness is well-tuned to THIS project and
  fix any mismatches — phrases like "evaluate the harness fit", "does the harness suit this project",
  "check in on the harness", "tune the harness to the project", "the facets/floor look wrong for this repo",
  "/evaluate-fit". Runs a full multi-agent DEEP DIVE of the project (stack, module structure, risk profile,
  deploy/notify story, secret + visual surfaces), reads the CURRENT harness config, then produces ranked,
  evidence-backed recommendations across the ONLY customizable surfaces — the `custom/` overlay, `harness.env`
  knobs, and `facets.json` (`layer` vocabulary + `policy`) — and, on your approval, applies them. It NEVER
  edits harness mechanism (scripts/docs/dashboard) — an install stays fork-free and upgrade-clean. Ideal after
  a harness was scaffolded against an empty/young repo, or after the project has grown. Requires a scaffolded
  `.harness/`.
argument-hint: "[optional: a focus area, e.g. 'facets' or 'hooks' — omit to evaluate the whole surface]"
allowed-tools: Read, Write, Edit, Bash, Glob, Grep, Agent, AskUserQuestion, Skill
---

# Evaluate harness fit — tune the customizable surface to THIS project

The `implementation-harness:implementation-harness-create` step scaffolds a *generic* harness and tailors
what it can from whatever the project looked like at setup — which is often **almost nothing** (a fresh repo).
As a project takes shape, the harness's project-specific knobs (the difficulty **floor**, the `layer` facet
vocabulary, the `custom/` overlay) can drift out of fit, and there is otherwise **no path to re-fit them**
except the slow runtime poor-fit gate. This skill closes that gap: it studies the project in depth, diffs
that understanding against the harness's *customizable* surface, and applies the fixes you approve.

`customize` is the reactive menu ("here are the features, which do you want?"). **This skill is the proactive
diagnostician** ("here is what YOUR project needs and why"). It reuses `customize`'s overlay mechanics and
delegates the tier ladder to `update-ladder`; it does not duplicate them.

Read this whole file, then execute in order.

## 0. Pre-flight

- Require a harness: `.harness/scripts/loop.sh`, `.harness/config/harness.env`, and `.harness/config/facets.json`
  must exist. If not, send the user to `implementation-harness:implementation-harness-create` and stop.
- Read the installed version for context: `cat .harness/.harness-version 2>/dev/null`.
- Note `$ARGUMENTS`: if it names a focus area (e.g. `facets`, `hooks`, `floor`, `visual`), you may still run
  the full dive but bias the report/apply toward that area. With no argument, evaluate the whole surface.
- This skill runs in an interactive session with a human present — it is a **planning-stage** operation, so
  **bias toward asking** when a recommendation changes real behavior (a floor bump costs money; a DoD change
  changes what "done" means). Confirm before applying; never apply silently.

## 1. The fork-safety contract — the ONLY things you may write (read this before anything else)

The single most important rule of this skill: **an install must stay fork-free and upgrade-clean.** You
therefore may **only ever write** to the project-owned *customizable* surface, and you treat everything else
as **strictly read-only**.

**WRITABLE (customizable — the upgrade reconciles these, never clobbering your values):**
- `.harness/custom/**` — the whole overlay: `CLAUDE.md` (conventions), `hooks/on-*.sh`, `sensitive-paths.txt`,
  `visual-verify-build.md` / `visual-verify-audit.md`, `build-preamble.md` / `audit-preamble.md`,
  `dashboard-title.txt`, and `custom/docs/LIMITATIONS.md`. (The feature list + drafting guidance is owned by
  the `customize` catalog — treat that as the SSOT; see §5.)
- `.harness/config/harness.env` — the scalar knobs (edit/uncomment a knob; never restructure the file).
- `.harness/config/facets.json` — **only** the project-specific parts: `.facets.layer.values` (additive
  tailoring) and, cautiously, `.policy` knobs. **Do NOT hand-edit `.tiers.ladder`** — delegate that to
  `implementation-harness:implementation-harness-update-ladder`, which owns the ladder-migration runbook.

**READ-ONLY (mechanism — NEVER edit, only report on):**
- `.harness/scripts/**`, `.harness/dashboard/**`, `.harness/docs/**`, the pristine `.harness/CLAUDE.md`
  (only `custom/CLAUDE.md` is yours), `.harness/README.md`, `.harness/.harness-version`.
- The loop's own data — `.harness/tracking/*`, `.harness/worklog/*`, `.harness/ledgers/*`. You may READ these
  to understand the backlog/facet spread; you may recommend backlog re-facleting but apply task edits only
  via the normal authoring path (see §5), never as a config change.
- Repo-root files the harness placed (`CLAUDE.md`, `.github/workflows/ci.yml`, `.gitignore`) — report drift,
  don't edit them here.

**Re-assert guard.** If the deep dive surfaces a real need that can ONLY be met by changing mechanism (a
script, a doc, the dashboard, the ladder-migration logic), **STOP — do not edit it.** Record it as an
*upstream idea* in your report and point the user at
`implementation-harness:implementation-harness-report-issue`. Never satisfy a need by editing a plugin-owned
file — that is the fork this skill exists to prevent.

## 2. Deep-dive the project (full multi-agent fan-out — always)

Dispatch a fan-out of parallel sub-agents (the `Agent` tool), **one per dimension below**, in a single batch.
Each agent gets the same framing ("You are profiling this repo so a build harness can be tuned to it. Read
widely; return ONLY the structured findings below — no prose.") plus its dimension brief. Scale is fixed:
run **all** dimensions every time (the user opted into a full dive). For a large monorepo, an agent may
recurse, but every dimension is always covered.

Each dimension maps to a specific customizable surface — that mapping is the whole point:

| # | Dimension the agent profiles | Feeds which customizable surface |
|---|------------------------------|----------------------------------|
| 1 | **Stack, build & test tooling** — languages, package manager, the ACTUAL format/lint/test/build commands, CI workflow name | `harness.env` `LOCAL_DOD` / CI-name drift (report; DoD change on approval) |
| 2 | **Module & domain structure** — top-level dirs, layering, where different kinds of change live (map real scope-path prefixes → conceptual layers) | `facets.json` `.facets.layer.values` tailoring |
| 3 | **Complexity & risk profile** — LLM-prompt code, concurrency, external APIs, algorithmic depth, blast-radius of a typical change | `harness.env` cold-start `MODEL`/`EFFORT` floor; `.tiers.ladder` (→ `update-ladder`); whether risk facets are warranted |
| 4 | **Deploy / release story** — how the product ships, any deploy command, post-integration steps | `custom/hooks/on-drained.sh` (deploy), `on-integrated.sh`; `harness.env` `INTEGRATE_HOOK` |
| 5 | **Notification channels** — Slack/email/webhooks the user relies on for "needs a human" or "stopped" | `custom/hooks/on-blocked.sh`, `on-exhausted.sh` |
| 6 | **Secret & credential surface** — dirs/files that must never be pushed (`.env*`, cloud creds, tokens, fixtures with secrets) | `custom/sensitive-paths.txt` |
| 7 | **Visual / UI surface** — is there a rendered/visual output? how is it captured? | `harness.env` `VISUAL_VERIFY` hook; `custom/visual-verify-build.md` / `-audit.md`; `custom/build-preamble.md` |
| 8 | **Standing project rules & conventions** — invariants every change must respect (test-isolation, house style, domain gotchas) | `custom/CLAUDE.md`; `custom/build-preamble.md` / `audit-preamble.md` |

While the agents run, do §3 yourself (reading the current config is cheap and doesn't need an agent).

## 3. Read the current harness config state

Capture the present values so the evaluation is a real diff, not a guess:
- **Overlay activation:** for each `custom/**` feature, is the real file active or still a `.example` stub?
  (`find .harness/custom -type f`). An all-`.example` overlay is the strongest signal a fresh-repo install
  was never tuned.
- **`harness.env`:** which knobs are set vs left default — especially the cold-start `MODEL`/`EFFORT` floor,
  `VISUAL_VERIFY_*`, `INTEGRATE_HOOK`, `SCOPE_EXEMPT_PATHS`.
- **`facets.json`:** the current `.facets.layer.values` set, the `.tiers.ladder` rungs, and the `.policy`
  knobs (`floor`, `minN`, `exploreProbabilityPM`, `exploreCooldownN`).
- **Backlog reality:** the task count and the observed `layer × work-type` spread
  (`jq '.tasks[]|.facets.layer+"/"+.facets.workType' .harness/tracking/TASKS.json | sort | uniq -c`), and, if
  present, the outcomes ledger — to see whether any cell has enough samples to have moved off the floor yet.

## 4. Evaluate — build the ranked recommendation report

Join §2 (what the project NEEDS) against §3 (what the harness HAS). For every gap, produce a recommendation
with: the **surface** (which writable target), the **finding** (project evidence), the **exact change**, the
**rationale**, and a **confidence**. Rank most-impactful first. Typical shapes:

- *"Every `custom/` file is still a stub, but the project deploys via `X` and stores creds in `Y`"* → activate
  `on-drained.sh` (deploy) + `sensitive-paths.txt` (`Y`).
- *"This is an LLM-prompt / algorithmically deep project, yet the cold-start floor is `claude-haiku-4-5`"* →
  raise `harness.env` `MODEL`/`EFFORT` (every task otherwise burns attempts escalating from too low a floor).
- *"Real code lives in `cli/ core/ io/`, but the `layer` vocabulary still carries generic `frontend/backend/
  data`"* → tailor `.facets.layer.values` to the real structure (additively; keep values existing tasks use).
- *"There is a rendered visual output with no visual-verify wired"* → set `VISUAL_VERIFY` + draft
  `custom/visual-verify-build.md`.
- *"A need requires a mechanism change"* → upstream idea → `report-issue` (per §1's guard). Never apply.

Present the report to the user (a concise ordered list is fine; a Markdown Artifact is nice for a long one).
Be explicit that mechanism-only findings are report-only.

## 5. Apply on approval

Walk the recommendations in ranked order. For each, use `AskUserQuestion` (*Apply* / *Skip* / *Tell me more*)
— group tightly-related ones (e.g. two hooks) into a single question when it keeps things legible. On
**Apply**, use the RIGHT mechanism for the surface, and confirm what you wrote:

- **`custom/` overlay:** activate + draft exactly as the `customize` catalog prescribes — copy the `.example`
  to the real filename (never clobber an existing real file — offer to append/edit instead), write the
  drafted content, `chmod +x` any `hooks/*.sh`. Your advantage over `customize`: you already have the deep
  dive, so **pre-fill the draft from real evidence** (the actual deploy command, the real secret paths, the
  real capture command) instead of re-interviewing — then show it for confirmation.
- **`harness.env`:** edit/uncomment the specific knob in place; never restructure the file or touch unrelated
  knobs. For a DoD (`LOCAL_DOD`) change, confirm the exact command and remind the user CI (`ci.yml`) must
  match — you report that drift but do not edit `ci.yml` here.
- **`facets.json` `.facets.layer.values`:** ADD missing layer values (additive is safe). A *rename* orphans
  any task using the old value — only rename with the user's explicit OK, and in the same pass re-facet the
  affected tasks (via the authoring path) so none are left dangling. `.policy` knobs: change only with a
  clear rationale, one at a time.
- **Tier ladder (`.tiers.ladder`):** do NOT edit it here — invoke
  `implementation-harness:implementation-harness-update-ladder` (or tell the user to run it) so the ladder
  migration is handled correctly.

## 6. Wrap up

- Summarize what was applied, what was skipped (still available later), and any **mechanism-only** findings
  routed to `report-issue`.
- Everything you wrote lives under `.harness/custom/` or `.harness/config/` and is **upgrade-safe** — the
  upgrade reconciles config additively and never touches `custom/`. Confirm no mechanism file was edited.
- Sanity-check what you activated: `--guard-selftest` for the denylist; a dry
  `bash .harness/custom/hooks/on-<event>.sh <args>` for a hook.
- Commit is the user's call (their files) — remind them to `git add -A && git commit` the changed
  `custom/` + `config/` files so they're durable, and (per the harness's own rule) push.
- Suggest re-running this skill after the project grows meaningfully, or after a batch of loop runs gives the
  calibration real data to reason about.
