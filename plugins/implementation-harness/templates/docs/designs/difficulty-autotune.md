# Difficulty auto-tuning — design

> **Customizing?** Add project notes in `custom/docs/designs/difficulty-autotune.md` (the overlay —
> upgrades never touch it), not in this plugin-owned file. See `.harness/custom/CLAUDE.md`.

The harness builds each task with an AI agent at a chosen **difficulty** (which model + reasoning
effort to try first). Instead of a one-shot human/LLM guess, a **self-tuning policy** learns, per
*kind* of task, the cheapest setting that reliably works — saving cost and improving first-try
success, with the human out of the loop.

## The closed loop

> **backlog → loop builds on an escalating ladder → capture each outcome → calibrate by facet →
> policy picks the cheapest-safe starting tier → repeat, getting cheaper + better-calibrated.**

The asymmetry that makes it work: **starting too cheap is self-correcting and self-teaching** (the
task escalates, you recover via the ladder, and you learn the class is harder than thought), while
**starting too expensive is silent waste** (it succeeds, but you never learn a cheaper tier would
have worked). So the policy **biases cheap and leans on the ladder as the safety net** — that saves
money *and* generates the data to keep learning.

## 1. Facets — the vocabulary (`facets.json`)

A **facet** is one labelled, difficulty-predictive axis describing a buildable task:
- **`layer`** (exactly one) — *where* the change lives. **Project-specific**; largely inferable from
  the task's scope file paths. Tailored to the repo at create-harness time; self-evolves (§6).
- **`work-type`** (exactly one) — *what kind* of change (style/docs/bugfix/feature/migration/…).
  **Universal** across projects.
- **`risk`** (zero or more) — danger modifiers (touches-schema, full-stack, …). **Not** part of the
  calibration cell key; instead it clamps the policy's usual cost-saving (below).

The calibration keys on **`layer × work-type`**. `facets.json` is the source of truth (vocabulary +
the global tier ladder + policy knobs). **`needs-human`/gated tasks are carved out** — no facets,
never calibrated.

**`risk` clamps the policy, on top of the `layer × work-type` cell.** A non-empty `risk` on a task:
mandatory audit (the per-cell sampling decay is bypassed entirely — `policy.jq`'s audit mode
returns 1000 per-mille unconditionally), and the eligible starting tier index is clamped to `>= 1`
(never the cheapest rung), even if the cell's historical calibration would otherwise clear the
floor at index 0. This directly implements the intuition that a cell can look statistically safe
while still hiding a kind of failure (a schema migration, a change to the executor) worth always
double-checking regardless of track record. Escalation above that floor on real failure rides the
same ladder as any other task.

## 2. Global difficulty ladder

`facets.json → .tiers.ladder`: one ordered list of `{model, effort}` tiers, cheapest → priciest. The
policy picks a **start tier** per task; escalation walks **up** the ladder (clamped at the top). The
cold-start prior is the `harness.env` `MODEL`/`EFFORT` floor (per-task `model`/`effort` fields are
ignored — facets are the only per-task difficulty signal). `MAX_ATTEMPTS` soft failures per tier before
escalating (default 2 — the ladder is fine-grained).

**Effort-less rungs.** A rung's `effort` may be explicit `null` for a model with no effort parameter
at the API level (e.g. Claude Haiku 4.5 as of this writing) — `run_claude()` omits `--effort` entirely
for such a rung. `policy.jq`'s `tidx()` matches rungs with `.model == $m and .effort == $e`, and jq's
`==` treats `null == null` as `true`, so calibration matches an effort-less rung correctly with no
special-casing — **as long as both sides are real JSON `null`**, not the string `"null"` or `""`. The
loop scripts' ladder parser normalizes null/missing effort to an empty string at read time (`.effort //
""`, so `TIER_TUPLES` stays a clean space-separated pair bash can `read`), then convert that empty
string back to real JSON `null` when writing `startEffort`/`finalEffort` to the ledger. Inserting a new
rung anywhere in the ladder (not just at the ends) is safe for calibration: `tidx()` re-matches fresh by
`(model, effort)` on every run, never against a cached index, so historical rows keep resolving
correctly after the ladder's shape changes — see `docs/HARNESS.md`'s "Bumping the base model" section
for what does and doesn't need touching when the ladder changes.

## 2a. Downward exploration — testing a newly inserted, cheaper rung

**The problem this solves.** `pick_base()` (§4) returns the cheapest tier with `>= minN` samples
and a `>= floor` success rate for the task's cell. A brand-new rung inserted below an
already-calibrated cell has **zero** samples, so it's excluded from that eligible set outright —
not outcompeted, structurally unreachable. It can therefore never accumulate the evidence that
would make it eligible: inserting a cheaper tier-0 rung has **no effect at all** on any cell that
already clears the floor at a pricier tier, forever, even though the whole point of the ladder is
"start cheap." Only escalation (walking **up** on failure) exists without this feature — nothing
walks the ladder **down** to test an unproven, cheaper rung against work that's already calibrated.

**The mechanism.** A bounded, self-terminating epsilon-greedy probe, controlled by
`.policy.exploreProbabilityPM` (per-mille, default `0` = off). Whenever the rung directly below
`$chosen` has fewer than `minN` samples for the task's cell (genuinely untested, not
tested-and-rejected), `policy.jq`'s TIER mode also returns a nonzero sampling probability for that
rung and its index; `loop.sh` rolls against it (the same `rand_pm()` helper already used for audit
sampling) and, on a hit, starts the task there instead of at `$chosen`. The floor for how far down a
probe may reach is clamped identically to `$chosen`'s own risk clamp — a risk-flagged task is never
a vehicle for probing the cheapest rung, exactly as today.

**Self-termination is free.** Once the probed rung reaches `minN` samples, `policy.jq` forces its
probability back to `0` — no separate bookkeeping. If its success rate cleared `floor`, the
**unmodified** tier-selection logic above already promotes it to the new `$chosen` on the very next
call, since it's now the lowest eligible index. If it didn't clear the floor, it's excluded
permanently, exactly like any other rejected tier. Either way the exploration mechanism's only job
is to seed the sample count past `minN` — it hands off to existing, unmodified logic the moment
that's done.

**Cost is bounded and audited.** A task started via exploration is, by definition, running on
untested ground — `audit_gate()` forces a mandatory audit for it (bypassing the cell's normal
confirmed-success decay), the same treatment a risk-flagged task already gets. The total cost of
finding out a newly inserted rung *doesn't* work is capped at `minN` mandatory audits per cell,
one-time, to settle it permanently.

**Practical note.** Inserting a rung (§2, "Effort-less rungs" paragraph) is calibration-*safe* on
its own — `tidx()` re-matches fresh every run, no ledger migration needed — but that only means the
new rung *won't corrupt* anything. Getting it actually **tried** on cells that are already
calibrated to a pricier tier requires raising `exploreProbabilityPM` above `0` — see
`docs/HARNESS.md`'s "Inserting a new rung" note and the `implementation-harness-update-ladder`
skill, which prompts for this after an insert.

## 3. Capture — the ledger  *(in `loop.sh`)*

`mark_done`/`block_task` append one JSON row per built task to **`outcomes.jsonl`**: facets, scope
size, start + final model/effort, the rung it succeeded at (or blocked), soft-fail counts. **Forward-
only:** only tasks the loop builds reach these, so gated/needs-human tasks write nothing. **The ledger
is the SOLE input to calibration** — the aggregator joins *from* a ledger row to its facets, never
*from* the task list, so re-tagging done tasks can never influence forward decisions.

## 4. Calibration + policy  *(`policy.jq` + `loop.sh`)*

`policy.jq` reads the ledger and, for a task's `(layer × work-type)` cell, returns the **cheapest tier
whose historical first-attempt success rate ≥ floor (default 0.75) with ≥ minN (default 6) samples;
else the `harness.env` `MODEL`/`EFFORT` floor** (cold-start prior). `pick_base` runs it at task selection; the rung
machinery rides the global ladder offset by that base. Robust: any missing facets / empty ledger /
error → the prior, so it can never break the loop.

## 5. Authoring — facets + poor-fit signal  *(add-to-backlog skill)*

The author **describes** the task with facets (from `facets.json`, using scope paths as the layer
signal) and **no longer guesses difficulty** — the policy decides. If no value confidently fits, the
author does **not** invent one (that fragments the calibration) — it records a context-carrying
**poor-fit signal** to `facet-misfits.jsonl` and tags the task with the closest value. Poor-fit is
overwhelmingly a `layer` problem; `work-type` is universal and stable.

## 6. Layer evolution — the poor-fit gate  *(add-to-backlog skill)*

The vocabulary evolves **without a human babysitting it** — the harness is most productive early in a
project, exactly when structure is least defined, so misfits accumulate fastest when the vocabulary is
least mature; the gate self-front-loads, then quiets as things stabilise.

At task-add time, if the accumulated poor-fit count ≥ `policy.poorFitThreshold`, run a **layer
re-evaluation**: (1) an LLM re-clusters the recent backlog + misfits into an updated `layer` set;
(2) it's **surfaced to the human opening with a plain-language paragraph explaining what the harness
does and what they're deciding** (they may not know this machinery exists), then the proposed diff;
(3) on accept, **migrate history** — remap `outcomes.jsonl` facets + re-tag tasks + update
`facets.json` (else changed cells cold-start), then clear the counter (cooldown). The human
approves/nudges/declines; they never do the clustering. This evolves `layer` *values*; new *axes* are
rare and explicit.

## 7. Portability

The faceting *framework* (layer × work-type × risk + ladder + capture + calibration + policy + the
evolution gate) is universal and ships in the harness. Only the **values** differ per project:
`work-type`/`risk` are universal defaults; the **`layer` set is tailored to the repo at
create-harness time** (and self-evolves via §6); the **tier ladder** is set to the project's models.

## Invariant to preserve forever

The calibration aggregates **only from `outcomes.jsonl`** (row → its facets → its cell), never from a
task's status or authored difficulty. That keeps retro-tagged/done tasks and any metadata edit from
ever leaking into difficulty selection.
