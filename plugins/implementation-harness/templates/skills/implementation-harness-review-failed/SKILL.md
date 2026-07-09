---
name: implementation-harness-review-failed
description: >-
  Use when the user wants to review the harness's failed or blocked backlog tasks and turn what
  went wrong into better-specified follow-up tasks — phrases like "review the failed tasks",
  "why did these tasks fail", "fix the blocked backlog items", "/review-failed". Sweeps every task
  with status "failed" (owner overturned a false success) or "blocked" (the loop gave up) that
  hasn't already been reviewed, one investigation sub-agent per task in parallel, then a single
  locked consolidation pass that authors the follow-ups, closes out every reviewed "blocked" task
  (via mark-failed.sh) so it stops sitting in the dashboard's Human Tasks bucket forever, AND marks
  every investigated task reviewed (tracking/reviews.json) so a future sweep never re-investigates
  it. Reuses the ideas-pipeline machinery (consolidate-ideas.sh + the pending-tasks / pending-questions
  relay); never touches IDEAS.jsonl. Requires the harness scaffolded.
argument-hint: "[optional: a single task id, e.g. T042 — omit for a full sweep]"
allowed-tools: Read, Write, Edit, Bash, Glob, Agent, AskUserQuestion, SendMessage, Artifact
---

# Review failed / blocked tasks → better-specified follow-ups

Review backlog tasks the harness could NOT complete and turn each into a **demonstrably better**
follow-up task — never a blind retry of the same spec. Two ways a task lands here, both terminal (the
loop never re-selects or re-opens either on its own, so a human review is the only path back to progress):

- **`status: "failed"`** — the OWNER overturned a false success via `tracking/manual-fail.json` (its
  `reason` field is the owner's own words for why the recorded success was wrong).
- **`status: "blocked"`** — the LOOP itself gave up: an agent-reported blocker, or `MAX_ATTEMPTS`
  exhausted at the top model tier (a `worklog/<id>.md` `failed:blocked` marker + `ledgers/*.jsonl` rows).

This is a **deliberate, human-invoked review** — nothing in the loop's run path ever calls it. You are
the COORDINATOR: you build the worklist and do the final consolidation; you delegate the actual
investigate-and-shape work to one sub-agent per task, running concurrently. It **reuses the exact same
pending-tasks / consolidation machinery as `implementation-harness-convert-ideas`** (each agent writes
only its own `.harness/.pending-tasks/<slug>.json`; `scripts/consolidate-ideas.sh` does the id
allocation, spec writing, `TASKS.json` merge, and single commit+push). It **never touches `IDEAS.jsonl`**.
Every review also ends with the **original task closed out AND recorded reviewed** — the coordinator
(never a per-task agent, which never touches git in this skill's design) runs
`.harness/scripts/mark-failed.sh` against each reviewed `"blocked"` task in Stage 3, then
`.harness/scripts/mark-reviewed.sh` against every task the sweep investigated (both originally-`"failed"`
and originally-`"blocked"`) — so a review doesn't just produce a follow-up, it also retires the task it
investigated AND ensures a future sweep never re-investigates it (Stage 1's worklist query excludes
anything already recorded reviewed). Read this whole file, then execute in order.

## Stage 0 — recovery check (before anything else)

Exactly like `implementation-harness-convert-ideas`'s pre-flight — a prior sweep may have been
interrupted. `mkdir -p .harness/.pending-tasks .harness/.pending-questions`, then:
- Leftover `.pending-tasks/*.json` are drafts an agent finished shaping. A draft whose DoD is already
  **confirmed** — no sibling `.pending-questions/<slug>.json` with unresolved questions — can go straight
  to Stage 3 (consolidate). Tell the user and offer to consolidate first.
- Leftover `.pending-questions/*.json` mean a review still has questions the owner hasn't answered —
  including the mandatory definition-of-done confirmation (Stage 2 step 4b), so a sibling `.pending-tasks`
  draft must NOT be consolidated until they're resolved. Re-surface them via `AskUserQuestion` (Stage 3's
  format — summarize each review's `ideaSummary` first, then batch its `questions`), fold the answers into
  that follow-up's `.pending-tasks/<slug>.json`, then Stage 3.
- Both empty → proceed.

Also require the harness (`.harness/docs/HARNESS.md`, `scripts/loop.sh`, `tracking/TASKS.json`) and
`jq` + `node` on PATH; if anything is missing, point the user at `implementation-harness:implementation-harness-create`.

## Stage 1 — build the worklist

```bash
jq -r --argjson rv "$(cat .harness/tracking/reviews.json 2>/dev/null || echo '{}')" \
  '.tasks[]|select(.status=="failed" or .status=="blocked")|select(($rv[.id].reviewed // false)|not)|.id' \
  .harness/tracking/TASKS.json
```

The `reviews.json` exclusion is what makes this sweep-safe to re-run: Stage 3 below records every task
this sweep investigates as reviewed, so a task a PAST sweep already closed out is never re-selected here.
**The very first run of this command after that mechanism ships will still re-investigate every
currently-`failed`/`blocked` task once more** — none of them have a `reviews.json` entry yet, since
nothing wrote one before now. That's expected and self-healing (each gets its entry this time, so it
never resurfaces again), not a bug to work around.

If `$ARGUMENTS` names a task id, confirm it is actually `failed` or `blocked` (if not, tell the user
this command only reviews failed/blocked tasks and stop). If the worklist is empty, say so and stop.

**No dedup or clustering pass** (unlike convert-ideas): each failed/blocked task is already a distinct,
unique input with its own history. Two tasks sharing a root cause is rare — an agent that notices it
during its own investigation can flag it in its report for the owner to connect by hand. Every task in
the worklist gets its own review agent, all launched in ONE wave (agents only write their own file, so
there is nothing to contend over).

## Stage 2 — parallel per-task review agents

For each task, launch a **general-purpose** agent (send all the Agent calls in a single message so they
run concurrently). Each agent investigates one task and writes ONLY to its own scratch file — it does
NOT have `AskUserQuestion`, and never touches `tracking/TASKS.json`, `tasks/`, `IDEAS.jsonl`, or git.

**Agent prompt template** (fill in `<TNNN>`, `<STATUS>`, and `<SLUG>` — a short kebab-case tag like
`review-t042`):

> You are reviewing ONE failed/blocked backlog task (id `<TNNN>`, status `<STATUS>`) to understand what
> went wrong and, if warranted, author a better-specified follow-up. Other agents are reviewing OTHER
> tasks concurrently; do only this one.
>
> **1. Gather every piece of evidence — do not guess.**
> - The original task: `jq '.tasks[]|select(.id=="<TNNN>")' .harness/tracking/TASKS.json` (title, scope,
>   facets, dependsOn, gate) and its spec `.harness/tasks/<TNNN>.md` (`## Do` / `## Done when`).
> - **If `status=="failed"`**: read `.harness/tracking/manual-fail.json`'s entry for this id — the
>   `reason` is the owner's words for why the recorded success was wrong. Usually the single most
>   important piece of evidence; take it at face value.
> - **If `status=="blocked"`**: read `.harness/worklog/<TNNN>.md` in full (the `failed:blocked` marker
>   plus everything the builder/auditor narrated across every attempt — usually rich); every
>   `.harness/ledgers/failures.jsonl` row (`jq -c 'select(.id=="<TNNN>")' .harness/ledgers/failures.jsonl`
>   — the full escalation history: what failed at each rung, and whether the causes were the same kind or
>   genuinely different); and the `.harness/ledgers/outcomes.jsonl` row (`topRung` / `totalSoftFails` /
>   terminal `reason`). If `.harness/worklog/<TNNN>.audit.md` exists, read it too (an audit FAIL is a
>   distinct, richer failure mode than a scope/CI failure — understand what the auditor flagged).
> - **Check it's still relevant.** Read the CURRENT state of what the task's `scope` touches, and grep
>   recent `git log` for those paths — has a later task or manual work already fixed the underlying
>   problem? If so, conclude "no follow-up needed" (step 3).
>
> **2. Find the ROOT CAUSE, not just the proximate failure.** A blocked task's proximate cause is often
> mechanical (scope-creep, a needed file missing from `scope`, CI red, attempts exhausted) — the useful
> question is WHY. The most common real cause is **the original `scope` was too narrow for what the
> `## Done when` actually required**. Others: an ambiguous/under-specified spec; a dependency that
> wasn't really ready; or genuine difficulty that needed more escalation than `MAX_ATTEMPTS` allowed. A
> failed task's owner `reason` may point at something subtler — an audit that passed but shouldn't have,
> a `## Done when` met technically but missing the real intent. Your follow-up must be **demonstrably
> better at the specific thing that went wrong** — an identical-spec retry would just fail the same way.
>
> **3. Decide the outcome — one of three. You are in the planning stage — bias TOWARD asking, but only
> where a real judgment call is being made.** This review runs with a human reachable (via the
> coordinator's relay); the eventual follow-up gets built by a weaker, unattended builder from the spec
> alone, with no chance to ask. So resolve ambiguity with the owner now rather than guessing — whenever a
> decision changes *what gets built* or *what "done" means*, surface it. Every outcome below ends with the
> ORIGINAL task being closed out (`status` flips to `"failed"`, terminal, dashboard-bucketed as reviewed)
> — the coordinator does this in Stage 3, not you; your job here is only to decide, and record, which
> outcome fired and why.
> - **Already resolved** — the investigation found this is PROVABLY fixed/stale/non-issue: a framework bug
>   since patched upstream, a later task or manual commit that already touched the same scope and fixed
>   it, a failure mode that no longer reproduces. This is a FACTUAL finding, not a judgment call. Write
>   `.harness/.pending-tasks/<SLUG>.json` with `{ "units": [], "ideaBullets": [], "report": "<why nothing
>   further is needed>" }`. **No question needed** — the coordinator closes the original out automatically
>   in Stage 3, citing your report as the reason.
> - **Follow-up authored** — go to step 4 to shape it. You do NOT have `AskUserQuestion` — you relay
>   through the coordinator, and for every follow-up you author you MUST (step 4b) confirm its definition
>   of done with the owner, plus surface any other decision that changes what gets built. Once confirmed
>   and consolidated, the coordinator closes the ORIGINAL out automatically alongside it, citing the new
>   follow-up's id as the reason — this is bookkeeping, not a fresh judgment call, since the follow-up's
>   own `specOverview` already carries the traceability back to the original.
> - **Not worth pursuing** — the root cause is real and still present, but on reflection the task itself
>   isn't worth building: it was already deprioritized, the underlying ask is stale/no longer wanted, or a
>   proper fix's cost isn't justified relative to its value. Unlike "already resolved," this ABANDONS
>   something the backlog once wanted — that IS a judgment call, so it must be confirmed, not closed
>   silently. Write `.harness/.pending-tasks/<SLUG>.json` with the same `{ "units": [], "ideaBullets": [],
>   "report": "<why you think it's not worth pursuing>" }` shape as "already resolved" (your `report` text
>   is what distinguishes them for the coordinator), AND relay a confirm-first question per step 4c below.
>
> **4. Shape the follow-up — no lock, no git, no `TASKS.json` edit.** Write
> `.harness/.pending-tasks/<SLUG>.json` in this exact shape (the same one
> `implementation-harness-convert-ideas` uses, so the consolidation script reads it unchanged):
> ```json
> {
>   "units": [
>     {
>       "tempId": "<SLUG>-a", "title": "...", "dependsOn": [],
>       "gate": null, "tags": [...], "scope": ["files this unit should touch"],
>       "design": null, "verify": [], "expectsTest": false,
>       "facets": { "layer": "...", "workType": "...", "risk": [] },
>       "visualVerify": true,   // OPTIONAL — set only if the follow-up should be visually verified (see below); omit for auto-covered / non-visual.
>       "specOverview": "Name what this re-attempts and WHY the first attempt didn't land — e.g. 'Re-attempt of <TNNN>, blocked because its scope excluded the client helper the Done-when required.' One or two sentences; this is the task's traceability back to the failure.",
>       "specDo": "The corrected work — incorporate the actual lesson (see below), not a restatement of the original spec.",
>       "specDoneWhen": "The task-specific, runnable acceptance bar. Do NOT restate the universal DoD (format/lint/test/CI-green)."
>     }
>   ]
> }
> ```
> Read `.harness/config/facets.json` (`jq '.facets'`) for the controlled facet vocabulary; pick the
> closest `layer`/`workType`/`risk` and never invent a value. Rules specific to a review-derived task:
> - **`specDo` must incorporate the actual lesson**, not restate the original. If the cause was
>   scope-too-narrow, the new `scope` must genuinely cover what `## Done when` needs — verify that
>   yourself by reading the requirements against the scope, don't assume. If the cause was ambiguity,
>   resolve it explicitly in the text. If it was genuine difficulty, consider a smaller, further-atomised task.
> - **Visual verification (facets-driven, same rule as convert-ideas):** a `frontend`-layer (non
>   docs/config/logging) or `style`/`component` follow-up is auto-covered — leave `visualVerify` unset.
>   For a `bugfix`/`feature`/`migration` follow-up on a non-frontend layer, set `"visualVerify": true` if
>   the fix plausibly changes a visual surface (especially if the ORIGINAL miss was visual — an audit
>   that passed on a broken render is exactly the case this catches).
> - **Do NOT set `dependsOn` to the original failed/blocked task** — it's terminal, nothing should wait
>   on it. Traceability lives in the `specOverview` (which names the re-attempt). Atomise into multiple
>   units if the review surfaces more than one separable follow-up.
> - `needs-human` units omit `facets` entirely. Omit `ideaIds` entirely too — a review-derived
>   follow-up has no real idea in `IDEAS.jsonl` to remove; the consolidation script simply does
>   nothing idea-side for a unit set with no `ideaIds` (see Stage 3).
>
> **4b. Confirm the definition of done with the owner (mandatory for every follow-up you author).** Also
> write `.harness/.pending-questions/<SLUG>.json` — the DoD question *confirms* the `specDoneWhen` you
> drafted, so shape the task fully and let the owner adjust it; don't block on it:
> ```json
> { "slug": "<SLUG>", "ideaText": "<TNNN>: <original title>",
>   "ideaSummary": "ONE short plain-language paragraph — what <TNNN> was, the root cause you found, and the follow-up you're proposing; the coordinator shows it to the owner BEFORE the questions so they know which review is being discussed.",
>   "context": "<what you found>",
>   "questions": [
>     { "topic": "definition-of-done", "question": "For the re-attempt of <TNNN>, I'm planning done-when to be: <the acceptance bar you drafted>. Does this match, or should it differ?" },
>     { "topic": "other", "question": "<another decision that changes what's built — include only if real>" }
>   ] }
> ```
> `questions` MUST hold ≥1 entry and ≥1 with `topic: "definition-of-done"`. Hold a unit OUT of your
> pending-tasks file only when it is genuinely un-shapeable until a `topic: "other"` answer lands.
>
> **4c. "Not worth pursuing" needs owner confirmation before closing (mandatory for that outcome only).**
> Write `.harness/.pending-questions/<SLUG>.json` (same shape as 4b's DoD confirmation), with one
> question:
> ```json
> { "slug": "<SLUG>", "ideaText": "<TNNN>: <original title>",
>   "ideaSummary": "ONE short plain-language paragraph — what <TNNN> was, the root cause you found, and why you think it's not worth pursuing further.",
>   "context": "<what you found>",
>   "questions": [
>     { "topic": "close-without-followup", "question": "Investigated <TNNN>: <root cause, one sentence>. My assessment: not worth pursuing further, no follow-up. OK to close this out as reviewed (no rebuild), or would you prefer a follow-up be drafted instead?" }
>   ] }
> ```
> If the owner says to draft a follow-up instead, this task's outcome MOVES to "follow-up authored" —
> resume your agent (or the coordinator folds it in directly) back to step 4 to shape one, same as any
> other pending-questions answer that opens new work.
>
> **5. Report back**: the root cause you found, which step-3 outcome you reached, the slug you used, and
> what you wrote (both files). The coordinator reads your files, not your prose.

## Stage 3 — relay questions (summarize each review first), consolidate, then close out

Every authored follow-up left a `.pending-questions/<slug>.json` (Stage 2 step 4b or 4c), so this relay
runs on essentially every sweep. Read them all, then:

**Publish a reference Artifact before asking anything** — the owner can't confirm a definition of done
they can't see. Load the `artifact-design` skill first (its own required process), then build ONE page
covering every currently-unresolved `.pending-questions/<slug>.json`: one section per review, headed by
its `ideaText` (the `<TNNN>` + original title) and `ideaSummary` (the root cause + proposed follow-up),
then every unit from that slug's matching `.pending-tasks/<slug>.json` in full — title, `specOverview`,
`specDo`, and `specDoneWhen` called out visually distinct from the rest — followed by that slug's own
pending `questions` text, so the owner reads the exact draft (or, for a `close-without-followup`
question, the exact investigation report) a question refers to right next to the question itself. This
is a **utilitarian reference doc for a decision in progress**, not a landing page — clean hierarchy and
real spacing, no hero, no marketing framing; build it from the REAL current content, never placeholder
text. **Give it a persistent left-hand outline to navigate by** — a sweep can span many reviews, and a
single long scroll is hard to move around in. Render a sidebar (table of contents) listing one entry per
review (its `<TNNN>` + title, with that review's unit titles nested under it), each anchor-linking
(`href="#<slug>"`) to the matching section — give every review section a corresponding `id="<slug>"`.
Keep the outline visible while the content scrolls (a sticky/fixed sidebar that itself scrolls when the
list is long), and on a narrow screen let it collapse above the content rather than overlapping it or
forcing horizontal scroll. These are plain in-page `#id` anchors — no external requests, so they're
CSP-safe inside an Artifact; no JavaScript is required for the jump-to behavior. Write the page to your
own scratchpad directory and call the `Artifact` tool (favicon 🔍) to publish it. **If the relay loops across multiple rounds**, regenerate and redeploy to the SAME file path
each round — the owner keeps one tab open for the whole sweep instead of chasing a new link every round.
Zero pending questions → skip this entirely, nothing to relay.

**Summarize before asking**: emit a short markdown recap — one line per review: its `ideaSummary` (and
the `<TNNN>` it concerns) — plus the artifact URL from above ("Full drafted context: `<url>` — keep this
open while answering below") — then make ONE `AskUserQuestion` batching **every** question from **every**
file (each may carry several — a definition-of-done confirmation, a `close-without-followup`
confirmation, plus other build-changing decisions), each with a `<TNNN>`-naming header/label. Fold each
answer back to its `(slug, question)`:
for a `definition-of-done` answer, update that follow-up's `.pending-tasks/<slug>.json` `specDoneWhen` if
the owner adjusted it (resume the agent via `SendMessage`, or edit the file yourself), else leave the
draft; for a `close-without-followup` answer, either leave the `{ "units": [] }` draft as-is (owner
confirmed closing with no follow-up) or, if the owner asked for a follow-up instead, fold that request in
and shape one per Stage 2 step 4 (the outcome moves from "not worth pursuing" to "follow-up authored");
for a `topic: "other"` answer, fold it in the same way. If an answer opens a NEW question, **append** it
to the same file's `questions` array and relay again (no cap); delete a `.pending-questions/<slug>.json`
only once ALL its questions resolve.

Then run the consolidation:

```bash
bash .harness/scripts/consolidate-ideas.sh      # NO_PUSH=1 … to commit locally only
```

It allocates real task ids, resolves `tempId` references, writes each unit's `tasks/TNNN.md` spec,
appends the tasks to `TASKS.json`, and commits + pushes under the repo lock. Since a review-derived
unit set carries no `ideaIds` (Stage 2 step 4), the script's `IDEAS.jsonl` cleanup is simply a no-op
for these units — no warning, nothing to "clean up."

**Then close out every reviewed `status=="blocked"` task in this sweep's worklist** whose outcome is now
settled (already resolved / follow-up consolidated / not-worth-pursuing confirmed) — this is what moves
it out of the dashboard's Human Tasks bucket permanently:

```bash
bash .harness/scripts/mark-failed.sh <TNNN> "review-failed: <one-line outcome>"
```

Run one call per closed-out task, sequentially. Template the reason by which outcome fired:
- Already resolved: `"review-failed: no follow-up needed — <the agent's report, condensed>"`.
- Follow-up authored: `"review-failed: superseded by <TNNN2> — <why the follow-up is better-specified>"`.
- Not worth pursuing: `"review-failed: not worth pursuing — owner confirmed; <the agent's report>"`.

Worklist entries that were already `status=="failed"` need **no** `mark-failed.sh` call — they're already
terminal; `mark-failed.sh`'s own guard would reject a redundant call against one anyway, so just skip them
for this step (they still need the reviewed-marking step below).

**Then, in ONE batched call, mark every task this sweep investigated as reviewed** — both
originally-`"failed"` ids (skipped above, since they needed no status change) and originally-`"blocked"`
ids just closed out, for every outcome that's now fully settled (skip only an id still mid-relay on an
unresolved pending-question):

```bash
bash .harness/scripts/mark-reviewed.sh <TNNN1> <TNNN2> ...   # every settled id from this sweep's worklist
```

One call, all ids, one commit (`mark-reviewed.sh` supports bulk ids atomically, has no gate/status guard,
and safely accepts a `status=="failed"` id — the exact case skipped above). This is what makes Stage 1's
`reviews.json` exclusion actually take effect on the next sweep: without it, an originally-`"failed"` task
would never get an entry and would be re-investigated forever, since it needs no `mark-failed.sh` call to
close out.

This is now the ONLY stage that touches git — Stages 0–2 and the relay above are read/scratch-file only.

## Stage 4 — validate + report

`jq empty .harness/tracking/TASKS.json`; confirm no duplicate ids, every `dependsOn` id exists, every
buildable new task has `facets` from the vocabulary, and every new task's `spec` path has a matching
file; `.pending-tasks/` / `.pending-questions/` left empty. Confirm every task in the original worklist
either now has a `tracking/reviews.json` entry (and, if originally `"blocked"`, was also closed out via
`mark-failed.sh`) or has a documented reason it doesn't yet (still awaiting an owner answer). Summarize
each reviewed task → its outcome (already resolved / a new follow-up id / not worth pursuing) and its
closure action.

Originally-`"failed"` tasks stay `status="failed"` (unchanged, already terminal) and are now also recorded
reviewed in `tracking/reviews.json`; originally-`"blocked"` tasks now also read `status="failed"` after
Stage 3's closeout AND are recorded reviewed — moving them out of both the dashboard's Human Tasks bucket
and its "Failed — Pending Review" bucket, into Done permanently. Neither is ever re-selected by a future
`/review-failed` sweep, since Stage 1's query excludes anything already recorded reviewed. If the sweep
produced ≥1 new task, close by suggesting the user run `/implementation-harness-pre-loop-checkin` before
the next unattended loop run.
