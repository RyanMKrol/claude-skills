---
name: harness-update-ladder
description: >-
  Use when the user wants to add, swap, or remove a rung on this project's difficulty/tier ladder —
  phrases like "add a model to the ladder", "update the tier ladder", "add haiku to the ladder",
  "change the escalation ladder", "/update-ladder". Interviews for which model and whether it's a SWAP
  (replace a model at a fixed position) or an INSERT/REMOVE (changes rung count, shifts positions),
  handles models with no effort parameter (e.g. Haiku) via `effort: null`, and walks the correct
  migration path for each — the "Bumping the base model" runbook for a swap, or a no-ledger-migration
  note for an insert/remove (plus a reminder to raise `exploreProbabilityPM` so a newly inserted rung
  doesn't sit inert on already-calibrated work, and `exploreCooldownN` so a rejected rung eventually
  gets rechecked instead of staying excluded forever). Requires the harness scaffolded, and harness
  version >= 1.45.0 for the effort-less-rung path / >= 1.47.0 for downward exploration / >= 1.48.0
  for the recheck cooldown (older installs don't support these yet — this skill checks and offers to
  run the upgrade first).
argument-hint: "[optional: model id to add/change, e.g. claude-haiku-4-5 — omit to be asked]"
allowed-tools: Read, Write, Edit, Bash, Glob, AskUserQuestion
---

# Update the tier ladder

You walk the user through changing `.harness/config/facets.json → .tiers.ladder` — the global difficulty
escalation ladder (`.harness/docs/designs/difficulty-autotune.md`) — for THIS project. Focus target:
`$ARGUMENTS` (a model id, if given, skips straight to asking what to do with it). Read this whole
file, then execute in order.

## 0. Pre-flight

- Confirm `.harness/docs/HARNESS.md` and `.harness/config/facets.json` exist — if not, this project
  isn't scaffolded; point the user at `implementation-harness:create` and stop.
- Read the current `.tiers.ladder` from `.harness/config/facets.json` and show it to the user as the starting
  point.
- Read `.harness/.harness-version`. **Effort-less rungs (`effort: null`) need >= 1.45.0.** If the
  installed version is older and the user's change would introduce a null-effort rung, tell them
  plainly and offer, via `AskUserQuestion`, to run `implementation-harness:upgrade`
  first — don't hand-write the mechanism support yourself; that's exactly the kind of local fork this
  harness avoids (see the project's own `CLAUDE.md`).

## 1. What's changing

Ask (`AskUserQuestion`) which model to add/change, and whether it's a:
- **Swap** — replace the model at an existing rung, same position, same rung count.
- **Insert** — add a brand-new rung (e.g. a cheaper tier-0, or a rung between two existing ones),
  changing the rung count and shifting later positions.
- **Remove** — drop a rung entirely, shifting later positions down.

For reference (verify against the `claude-api` skill or current pricing if it's been a while — this
drifts):

| Model | ID | Effort param |
|---|---|---|
| Claude Haiku 4.5 | `claude-haiku-4-5` | ❌ none — use `effort: null` |
| Claude Sonnet 5 | `claude-sonnet-5` | ✅ low → max |
| Claude Opus 4.8 | `claude-opus-4-8` | ✅ low → max |

If the chosen model has no effort parameter, the new rung's `effort` must be JSON `null` (not omitted,
not the string `"null"`) — see `.harness/config/facets.json`'s `.tiers._about` and
`.harness/docs/designs/difficulty-autotune.md` §2 for why this is safe and requires no other changes.

## 2. Swap path

Follow `.harness/docs/HARNESS.md`'s "Bumping the base model" runbook exactly: update the ladder at the same
position, migrate `.harness/ledgers/outcomes.jsonl` / `failures.jsonl` model ids via `sed` at that position,
verify calibration survived by running `policy.jq` in tier-selection mode before/after for a couple of
real `(layer, work-type)` cells with history, then commit ladder + both ledgers together.

## 3. Insert / Remove path

Per `.harness/docs/HARNESS.md`'s "Inserting a new rung" note: this is safe for calibration with **no ledger
migration needed** — `tidx()` re-matches every ledger row fresh by `(model, effort)` against the
current ladder on every run, never a cached index. Tell the user explicitly: historical rows'
`startModel`/`startEffort`/`finalModel`/`finalEffort` remain accurate forever; only the diagnostic
`succeededRung`/`topRung` integers on old rows may no longer match the live ladder's position for that
model — cosmetic only, never fed into policy decisions.

### 3a. Getting the new rung actually tried (`exploreProbabilityPM`)

An insert is calibration-*safe*, but that only means the new rung won't corrupt anything — it says
nothing about whether it ever gets **used**. On any cell that's already calibrated to a pricier tier
(has `>= minN` samples clearing the floor there), the new rung has zero samples and is therefore
structurally excluded from ever being chosen — it can't accumulate the evidence that would make it
eligible, so it sits permanently inert on established work (`.harness/docs/designs/difficulty-autotune.md`
§2a). After every insert, ask the user whether they want the new rung actually tested on established
cells, and if so, set `.policy.exploreProbabilityPM` in `.harness/config/facets.json` to a nonzero per-mille
value (suggest 50–150 as a starting point) — this is what makes the loop occasionally start a task
one rung below its normal pick specifically to gather that evidence. It's bounded (self-terminates
once a cell hits `minN` explored samples) and audited (every explored task gets a mandatory audit).
Requires harness version >= 1.47.0 — if older, offer to run the upgrade first, same as the
effort-less-rung gate in §0.

A rejection isn't permanent, either — `.policy.exploreCooldownN` (rows of *other* cell activity
since the rung's last touch, default `40`) controls how long a rejected rung waits before it's
offered a fresh batch of trials again, useful if task difficulty is likely to drift over the
project's life (a codebase maturing, gaining conventions/helpers a cheap model could lean on later).
Mention this alongside `exploreProbabilityPM` when discussing an insert — most users setting one
will want to know about the other. Requires harness version >= 1.48.0 for the recheck mechanism
specifically (older installs support `exploreProbabilityPM` but a rejection there is permanent) —
same upgrade-first offer as above if the installed version predates it.

## 4. Cold-start floor

If the change affects rung 0 (a new/changed rung becomes the cheapest), remind the user to update
`.harness/config/harness.env`'s `MODEL`/`EFFORT` to match — leave `EFFORT` unset/empty if the new floor is
itself effort-less.

## 5. Write + validate

Edit `.harness/config/facets.json`'s `.tiers.ladder` to the agreed shape. Validate with
`jq empty .harness/config/facets.json`. Show the user the final ladder before finishing.

## 6. Trade-offs worth remembering (optional)

If this change is a meaningful trade-off (e.g. accepting more unsupervised spend for a longer ladder,
or trusting a cheaper model at tier-0 before it has track record), you *may* — entirely at your
discretion — jot it in `.harness/custom/docs/LIMITATIONS.md` (an optional project-owned log; the
harness never requires it) so the reasoning isn't lost. What was chosen, why, and when to revisit.

## 7. Wrap up

Summarize the final ladder, remind the user this was a project-local `.harness/config/facets.json` edit (not a
plugin change — nothing to upstream), and that the next task the loop picks up will use the new ladder
immediately, no restart required beyond the loop's normal per-task refresh.
