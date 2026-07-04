---
name: implementation-harness-convert-ideas
description: >-
  Use when the user wants to process the ideas inbox (.harness/tracking/IDEAS.md) into real
  TASKS.json backlog tasks — phrases like "convert the ideas", "process the ideas inbox", "turn
  the ideas into tasks", "/convert-ideas". Sweeps the WHOLE inbox at once: dedupes near-duplicate
  ideas, converts each idea (or cluster) in PARALLEL via one sub-agent each, relays any genuine
  open questions back through a real AskUserQuestion, then runs a single locked consolidation pass
  that allocates real task ids, writes per-task specs, and removes converted bullets from the
  inbox. Requires the implementation harness to already be scaffolded.
argument-hint: "[optional: only convert idea #N, or a keyword filter]"
allowed-tools: Read, Write, Edit, Bash, Glob, Agent, AskUserQuestion, SendMessage
---

# Convert the ideas inbox into backlog tasks

You are the COORDINATOR of a parallel ideas→tasks conversion sweep. You do the dedup/clustering
and the final consolidation yourself; you delegate the actual explore-and-shape work for each
idea (or cluster of related ideas) to one sub-agent per idea, running concurrently. Read this
whole file, then execute in order.

## 0. Pre-flight

- Require the harness: `.harness/docs/HARNESS.md`, `.harness/scripts/loop.sh`, and
  `.harness/tracking/TASKS.json` must exist. If any is missing, point the user at
  `/implementation-harness-create` first.
- Require `jq` and `node` on PATH.
- **Recovery check — do this BEFORE touching the current inbox.** An earlier sweep may have been
  interrupted (session ended mid-flight). Scan `.harness/.pending-tasks/` and
  `.harness/.pending-questions/`:
  - Leftover `.pending-tasks/*.json` files are COMPLETE (an agent finished shaping them) — they can
    go straight to consolidation (§5) without re-running exploration. Tell the user you found them
    and offer to consolidate now before starting a new sweep.
  - Leftover `.pending-questions/*.json` files mean an agent was BLOCKED on a genuine open question
    when the prior sweep ended. Re-surface those questions via `AskUserQuestion` now (§4's format),
    then either resume that idea's shaping yourself (read the pending-questions file for the
    context it captured) or re-launch a fresh agent for just that idea with the answer folded in.
  - If both directories are empty, proceed normally.

## 1. Read the inbox

Read `.harness/tracking/IDEAS.md`. Extract every numbered bullet under `## Inbox`. If the user's
argument names a specific idea number or a keyword, filter to matching bullets; otherwise process
the whole inbox. If the inbox is empty, say so and stop.

## 2. Dedup / cluster pass (you do this, not an agent)

Read through the extracted bullets and group any that share the **same underlying feature or
answer-space** — not just literal duplicates, but ideas that would require exploring the same code
and would produce overlapping or dependent tasks. Two bullets about the same UI component, or two
bullets that are really "the same bug, described twice," become ONE cluster handled by ONE agent
(so it doesn't duplicate exploration or produce two conflicting task sets). Bullets with no overlap
each become their own singleton cluster. This pass is cheap — do it by reading, not by launching
agents.

## 3. Fan out — one agent per idea/cluster, in parallel

For each cluster, launch a **general-purpose** agent (send all clusters' Agent calls in a single
message so they run concurrently). Each agent gets its own idea/cluster text and writes ONLY to its
own scratch file — zero lock contention between agents, since none of them touch git or
`TASKS.json` directly.

**Agent prompt template** (fill in `<IDEA TEXT>` and `<SLUG>`, a short kebab-case tag for this
idea/cluster used in its scratch filenames):

> You are converting a raw idea into implementation-harness backlog tasks for this repo. Read this
> whole prompt, then act.
>
> **The idea:** <IDEA TEXT>
>
> **Your job:**
> 1. Explore the codebase enough to decompose this into atomic, dependency-ordered task units. Cite
>    concrete files/lines/identifiers where you find them — the spec you write is the ENTIRE brief
>    a fresh, context-free builder agent will get, so ambiguity here becomes a wrong build later.
> 2. Read `.harness/config/facets.json` (`jq '.facets'`) — the controlled facet vocabulary. Classify
>    each buildable unit's `layer` (from the unit's own file paths) and `workType`
>    (style/docs/config/component/endpoint/bugfix/feature/migration/refactor/…), plus any `risk`
>    flags. If nothing fits, pick the CLOSEST value and note the mismatch in your output's
>    `factMisfits` array — do NOT invent a new vocabulary value.
> 3. **Pair every "options to choose between" idea with a review + hardcode follow-up** — never a
>    chooser task alone. If the idea implies building multiple variants for a human to pick among,
>    emit THREE linked units: (a) a buildable chooser that builds the options behind a switch, (b) a
>    `"gate": "needs-human"` review unit that `dependsOn` the chooser, (c) a buildable
>    hardcode-the-winner unit that `dependsOn` the review and removes the switch.
> 4. **Split a decision/unknown into its own `needs-human` unit** if the idea hinges on a human
>    decision or an unknown that needs probing before the real work can be specified — a
>    `needs-human` decision unit, plus a dependent buildable follow-up once it's answered.
> 5. If you hit a genuinely open question you cannot resolve yourself (you do NOT have
>    `AskUserQuestion` — do not attempt to call it), STOP shaping that specific unit and instead
>    write `.harness/.pending-questions/<SLUG>.json`:
>    `{ "slug": "<SLUG>", "question": "<the exact question>", "context": "<what you've found so far>", "ideaText": "<IDEA TEXT>" }`
>    then finish shaping whatever OTHER units from this idea don't depend on the answer, and write
>    those to `.pending-tasks/<SLUG>.json` as normal (partial output is fine — the coordinator will
>    relay your question and either resume you or re-run this idea once answered).
> 6. Otherwise, write `.harness/.pending-tasks/<SLUG>.json`:
>    ```json
>    {
>      "units": [
>        {
>          "tempId": "<SLUG>-a", "title": "...", "dependsOn": ["<SLUG>-a" or a real "TNNN" id],
>          "gate": null, "tags": [...], "scope": ["files this unit should touch"],
>          "design": null, "verify": [], "expectsTest": false,
>          "facets": { "layer": "...", "workType": "...", "risk": [] },
>          "specDo": "1-3 sentences: the work.",
>          "specDoneWhen": "The task-specific, concrete, runnable acceptance bar. Do NOT restate the universal DoD (format/lint/test/CI-green) — that's already covered once, globally."
>        }
>      ],
>      "ideaBullets": ["<the exact original bullet text from IDEAS.md, for fuzzy removal>"]
>    }
>    ```
>    `needs-human` units omit `facets` entirely. `tempId`s only need to be unique within YOUR file;
>    `dependsOn` may reference your own `tempId`s or a real existing `TNNN` id if this idea builds on
>    an existing task. Your final message should just confirm what you wrote — the coordinator
>    reads the file, not your response text.

## 4. Relay pending questions

After all agents finish, check `.harness/.pending-questions/*.json`. If any exist, read them all and
batch them into **one** real `AskUserQuestion` call (don't ask one at a time). For each answer, either:
- resume that agent via `SendMessage` (if it's still addressable) with the answer, so it can finish
  writing its `.pending-tasks/<slug>.json`, or
- if the agent session is gone, incorporate the answer yourself and write that idea's
  `.pending-tasks/<slug>.json` directly, following the same schema as §3 step 6.

Delete a `.pending-questions/*.json` file once its question has been answered and folded in.

## 5. Consolidate

Run `.harness/scripts/consolidate-ideas.sh`. This is the ONLY step that touches git: it acquires
the harness's repo lock (waiting if the loop currently holds it, rather than failing), allocates
real sequential task ids, resolves every `tempId` reference (dropping and logging any that don't
resolve), writes each unit's `tasks/TNNN.md` spec, appends the new task objects to `TASKS.json`,
fuzzy-removes the converted bullets from `IDEAS.md`, and commits + pushes. Read its output.

## 6. Report

Summarize for the user: how many ideas were processed, the resulting task ids (grouped by which
idea they came from), any `dependsOn` that had to be dropped (a real authoring problem to flag, not
silently ignore), and any ideas still sitting in the inbox (skipped by a filter, or still blocked on
an unanswered question). Do NOT claim an idea is "done" — converting it to tasks means the loop can
now build it, not that it has been built.

If the sweep produced ≥1 new task, close by suggesting the user run
`/implementation-harness-pre-loop-checkin` before the next unattended loop run — it vets the new tasks'
facets/spec/scope quality and needs-human blockers, and gives a GO/NO-GO verdict.
