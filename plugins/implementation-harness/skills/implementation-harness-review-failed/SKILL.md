---
name: implementation-harness-review-failed
description: >-
  Use when the user wants to review the harness's failed or blocked backlog tasks and turn what
  went wrong into better-specified follow-up tasks — phrases like "review the failed tasks",
  "why did these tasks fail", "fix the blocked backlog items", "/review-failed". Sweeps every task
  with status "failed" (owner overturned a false success) or "blocked" (the loop gave up), one
  investigation sub-agent per task in parallel, then a single locked consolidation pass that
  authors the follow-ups. Reuses the ideas-pipeline machinery (consolidate-ideas.sh + the
  pending-tasks / pending-questions relay); never touches IDEAS.md. Requires the harness scaffolded.
argument-hint: "[optional: a single task id, e.g. T042 — omit for a full sweep]"
allowed-tools: Read, Write, Edit, Bash, Glob, Agent, AskUserQuestion, SendMessage
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
allocation, spec writing, `TASKS.json` merge, and single commit+push). It **never touches `IDEAS.md`**.
Read this whole file, then execute in order.

## Stage 0 — recovery check (before anything else)

Exactly like `implementation-harness-convert-ideas`'s pre-flight — a prior sweep may have been
interrupted. `mkdir -p .harness/.pending-tasks .harness/.pending-questions`, then:
- Leftover `.pending-tasks/*.json` are COMPLETE — go straight to Stage 3 (consolidate) before starting
  anything new. Tell the user and offer to consolidate first.
- Leftover `.pending-questions/*.json` mean an agent was BLOCKED on a question — re-surface them via
  `AskUserQuestion` (Stage 2's format), fold the answers in (resume or re-launch that unit), then Stage 3.
- Both empty → proceed.

Also require the harness (`.harness/docs/HARNESS.md`, `scripts/loop.sh`, `tracking/TASKS.json`) and
`jq` + `node` on PATH; if anything is missing, point the user at `/implementation-harness-create`.

## Stage 1 — build the worklist

```bash
jq -r '.tasks[]|select(.status=="failed" or .status=="blocked")|.id' .harness/tracking/TASKS.json
```

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
NOT have `AskUserQuestion`, and never touches `tracking/TASKS.json`, `tasks/`, `IDEAS.md`, or git.

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
> **3. Decide the outcome:**
> - **No follow-up needed** (already resolved elsewhere, or a stale/invalid signal — e.g. a framework
>   bug since fixed, not a real defect): write `.harness/.pending-tasks/<SLUG>.json` with
>   `{ "units": [], "ideaBullets": [], "report": "<why nothing further is needed>" }`.
> - **Genuine open question the owner must answer** before you can shape confidently (the ask itself was
>   ambiguous, or a real product/design decision is needed): write `.harness/.pending-questions/<SLUG>.json`
>   `{ "slug": "<SLUG>", "question": "For the review of <TNNN> (<original title>): <the exact question>", "context": "<what you found>", "ideaText": "<TNNN>: <original title>" }`,
>   and do not shape a task yet.
> - **Confident enough to shape** (root cause and fix are clear from the evidence): go to step 4.
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
>       "specOverview": "Name what this re-attempts and WHY the first attempt didn't land — e.g. 'Re-attempt of <TNNN>, blocked because its scope excluded the client helper the Done-when required.' One or two sentences; this is the task's traceability back to the failure.",
>       "specDo": "The corrected work — incorporate the actual lesson (see below), not a restatement of the original spec.",
>       "specDoneWhen": "The task-specific, runnable acceptance bar. Do NOT restate the universal DoD (format/lint/test/CI-green)."
>     }
>   ],
>   "ideaBullets": ["<TNNN>: <original title>"]
> }
> ```
> Read `.harness/config/facets.json` (`jq '.facets'`) for the controlled facet vocabulary; pick the
> closest `layer`/`workType`/`risk` and never invent a value. Rules specific to a review-derived task:
> - **`specDo` must incorporate the actual lesson**, not restate the original. If the cause was
>   scope-too-narrow, the new `scope` must genuinely cover what `## Done when` needs — verify that
>   yourself by reading the requirements against the scope, don't assume. If the cause was ambiguity,
>   resolve it explicitly in the text. If it was genuine difficulty, consider a smaller, further-atomised
>   task, or set `visualVerify: true` if the miss was visual.
> - **Do NOT set `dependsOn` to the original failed/blocked task** — it's terminal, nothing should wait
>   on it. Traceability lives in the `specOverview` (which names the re-attempt). Atomise into multiple
>   units if the review surfaces more than one separable follow-up.
> - `needs-human` units omit `facets` entirely. `ideaBullets` is `["<TNNN>: <original title>"]` — a
>   synthetic string (review agents have no real idea bullet) that keeps the file byte-compatible with
>   the consolidation script; it will not match anything in `IDEAS.md` (that's expected — see Stage 3).
>
> **5. Report back**: the root cause you found, which step-3 outcome you reached, the slug you used, and
> what you wrote (or didn't). The coordinator reads your file, not your prose.

## Stage 3 — relay questions, then consolidate

If any `.pending-questions/*.json` exist, batch them into ONE `AskUserQuestion` (each prefixed with
which `<TNNN>` it concerns), then fold each answer in — resume the agent via `SendMessage`, or write
that task's `.pending-tasks/<slug>.json` yourself. Delete each pending-questions file once answered.

Then run the consolidation (the ONLY step that touches git):

```bash
bash .harness/scripts/consolidate-ideas.sh      # NO_PUSH=1 … to commit locally only
```

It allocates real task ids, resolves `tempId` references, writes each unit's `tasks/TNNN.md` spec,
appends the tasks to `TASKS.json`, and commits + pushes under the repo lock. **Expected harmless log
line:** for each review-derived unit, the script tries to fuzzy-remove a matching bullet from
`IDEAS.md`; the synthetic `<TNNN>: <title>` `ideaBullets` string never matches, so it logs a "could not
find idea bullet" warning per unit. That is NOT a problem — do not go "clean up" a phantom bullet.

## Stage 4 — validate + report

`jq empty .harness/tracking/TASKS.json`; confirm no duplicate ids, every `dependsOn` id exists, every
buildable new task has `facets` from the vocabulary, and every new task's `spec` path has a matching
file; `.pending-tasks/` / `.pending-questions/` left empty. Summarize each reviewed task → its outcome
(a new follow-up id, "no follow-up needed" + why, or a question relayed + its answer).

**The reviewed tasks stay `status="failed"` / `"blocked"`** — this command never changes that (they're
terminal by design; a new task is how progress resumes, not a reopen). If the sweep produced ≥1 new
task, close by suggesting the user run `/implementation-harness-pre-loop-checkin` before the next
unattended loop run.
