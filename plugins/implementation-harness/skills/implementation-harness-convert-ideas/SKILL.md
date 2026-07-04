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
  - **Stale already-converted bullets.** A prior sweep may have consolidated tasks but died before its
    bullet-removal committed, leaving an inbox bullet whose task already exists. Skim
    `git log --oneline -15` for recent `consolidate-ideas`/backlog commits and the ~10 most recent
    `TASKS.json` task titles; if an inbox bullet looks like it already became a task, **surface it to
    the owner** (name the bullet + the matching task id) and only remove it if they confirm — never
    silently delete a bullet you're merely guessing was converted.
  - If all of the above are clear, proceed normally.

## 1. Read the inbox

Read `.harness/tracking/IDEAS.md`. Extract every numbered bullet under `## Inbox`. If the user's
argument names a specific idea number or a keyword, filter to matching bullets; otherwise process
the whole inbox. If the inbox is empty, say so and stop.

## 2. Dedup + cluster pass (you do this, not an agent)

Two distinct sub-passes, both by reading (cheap — no agents):

**2a. Dedup — ask, don't auto-merge.** Find bullets that are genuinely the *same idea described twice*
(near-identical intent, not merely related). Group each set of suspected duplicates and **surface it to
the owner via `AskUserQuestion`** — ask whether to merge them into one, keep the clearer one, or treat
them separately. **Do NOT silently collapse them yourself** — a semantic near-match may be two real,
distinct asks, and only the owner knows. Apply their decision before clustering.

**2b. Cluster — group by shared answer-space.** Of the survivors, group any that share the **same
underlying feature or code area** — ideas that would require exploring the same code and would produce
overlapping or dependent tasks — into ONE cluster handled by ONE agent (so it doesn't duplicate
exploration or emit conflicting task sets). Bullets with no overlap each become their own singleton
cluster. Clustering is a scheduling choice (one agent vs many), not a merge — it doesn't drop any idea.

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
> 2b. **Decide visual verification, driven by the facets you just set.** A task that produces visual
>    output should be built + audited with the project's VISUAL_VERIFY_HOOK ("actually LOOK at it").
>    - `layer=="frontend"` (unless workType is docs/config/logging), or workType `style`/`component`:
>      **auto-covered** by the loop — leave `visualVerify` UNSET.
>    - workType `bugfix`/`feature`/`migration` on a **non-frontend** layer: **judge** whether the change
>      plausibly alters a visual surface a human would eyeball (a backend migration changing an API the
>      UI reads, a bugfix that fixes a rendering issue, a feature that adds UI). If yes → set
>      `"visualVerify": true`. If you genuinely can't tell, relay it as a question (step 5).
>    - anything clearly non-visual: leave it unset.
> 3. **Pair every "options to choose between" idea with a review + hardcode follow-up** — never a
>    chooser task alone. If the idea implies building multiple variants for a human to pick among,
>    emit THREE linked units: (a) a buildable chooser that builds the options behind a switch, (b) a
>    `"gate": "needs-human"` review unit that `dependsOn` the chooser, (c) a buildable
>    hardcode-the-winner unit that `dependsOn` the review and removes the switch.
> 4. **Split a decision/unknown into its own `needs-human` unit** if the idea hinges on a human
>    decision or an unknown that needs probing before the real work can be specified — a
>    `needs-human` decision unit, plus a dependent buildable follow-up once it's answered.
> 5. **Prefer a judgment call over manufacturing a question.** For a low-stakes, reasonable-default
>    decision (a naming choice, which of two obvious spots to put something), just DECIDE it, note the
>    call in your unit's `report`, and keep going — don't block the owner on it. Only escalate a
>    GENUINELY open question you cannot responsibly resolve (a real product/design decision, an
>    ambiguity where guessing wrong wastes a build). When you must: you do NOT have `AskUserQuestion`
>    (do not attempt to call it) — STOP shaping the affected unit and write
>    `.harness/.pending-questions/<SLUG>.json`:
>    `{ "slug": "<SLUG>", "question": "For idea <SLUG> (<short idea gist>): <the exact question>", "context": "<what you've found so far>", "ideaText": "<IDEA TEXT>" }`
>    — **the question MUST name which idea it's about** (several agents relay questions concurrently;
>    an unlabelled one is ambiguous). Then finish shaping whatever OTHER units from this idea don't
>    depend on the answer and write those to `.pending-tasks/<SLUG>.json` as normal (partial output is
>    fine — the coordinator relays your question and resumes/re-runs you once answered).
> 6. If you conclude **no task is actually warranted** (the idea is already done, is a non-issue, or on
>    investigation doesn't hold up), still write `.harness/.pending-tasks/<SLUG>.json` but with
>    `"units": []`, a `"report"` explaining why, AND the `ideaBullets` — so consolidation removes the
>    converted bullet from the inbox (the report is the record of why nothing was authored).
>    Otherwise, write `.harness/.pending-tasks/<SLUG>.json` with the shaped units:
>    ```json
>    {
>      "units": [
>        {
>          "tempId": "<SLUG>-a", "title": "...", "dependsOn": ["<SLUG>-a" or a real "TNNN" id],
>          "gate": null, "tags": [...], "scope": ["files this unit should touch"],
>          "design": null, "verify": [], "expectsTest": false,
>          "facets": { "layer": "...", "workType": "...", "risk": [] },
>          "visualVerify": true,   // OPTIONAL — include ONLY per step 2b (a maybe-visual task you judged visual). Omit for auto-covered / non-visual tasks.
>          "specOverview": "ONE or TWO plain-language sentences — the 'what are we actually doing here, and why, at a glance' line. It's read FIRST and fastest, before the denser Do / Done-when detail.",
>          "specDo": "1-3 sentences: the work.",
>          "specDoneWhen": "The task-specific, concrete, runnable acceptance bar. Do NOT restate the universal DoD (format/lint/test/CI-green) — that's already covered once, globally."
>        }
>      ],
>      "ideaBullets": ["<the exact original bullet text from IDEAS.md, for fuzzy removal>"],
>      "report": "optional: any judgment calls you made, or why no task was warranted (units: [])."
>    }
>    ```
>    `needs-human` units omit `facets` entirely. `tempId`s only need to be unique within YOUR file;
>    `dependsOn` may reference your own `tempId`s or a real existing `TNNN` id if this idea builds on
>    an existing task. Your final message should just confirm what you wrote — the coordinator
>    reads the file, not your response text.

## 4. Relay pending questions (multi-round — no cap)

Use durable files, not conversation memory — an agent's question and the owner's answer must survive a
dropped session. After all agents finish, check `.harness/.pending-questions/*.json`. If any exist,
read them all and batch them into **one** real `AskUserQuestion` call (don't ask one at a time; each
question already names its idea). For each answer:
- **resume that agent** via `SendMessage` (if still addressable) with the answer so it finishes its
  `.pending-tasks/<slug>.json`, or **incorporate the answer yourself** and write that idea's
  `.pending-tasks/<slug>.json` directly (same schema as §3 step 6) if the agent is gone.
- **The answer may not fully settle it.** If it does, delete the `.pending-questions/<slug>.json`. If
  the answer opens a genuinely NEW question, that idea's agent (or you) **overwrites the same
  `.pending-questions/<slug>.json`** (same file, same schema) with the follow-up — then relay again.
  **There is no cap on rounds** — loop §4 until every pending-questions file is resolved or deleted.
- **If the owner defers or declines the idea entirely**, do NOT write a `.pending-tasks` file for it
  and DELETE its pending-questions file — with no pending-tasks entry, consolidation won't touch its
  bullet, so the idea simply **stays in the inbox** for a future sweep (nothing is authored, nothing removed).

## 5. Consolidate

Run `.harness/scripts/consolidate-ideas.sh`. This is the ONLY step that touches git: it acquires
the harness's repo lock (waiting if the loop currently holds it, rather than failing), allocates
real sequential task ids, resolves every `tempId` reference (dropping and logging any that don't
resolve), writes each unit's `tasks/TNNN.md` spec, appends the new task objects to `TASKS.json`,
fuzzy-removes the converted bullets from `IDEAS.md`, and commits + pushes. Read its output.

## 6. Validate

Before reporting, confirm consolidation left the backlog sound (catches a corrupt write or a shaping bug):
- `jq empty .harness/tracking/TASKS.json` — valid JSON.
- No duplicate task ids; every `dependsOn` id exists in `TASKS.json`.
- Every new **buildable** task has `facets` with `layer`/`workType` drawn from `config/facets.json`'s
  vocabulary; every `needs-human` task has none.
- Every new task's `spec` path exists on disk with non-empty `## Do` / `## Done when`.
- `.harness/.pending-tasks/` and `.harness/.pending-questions/` are empty (no straggler left un-consolidated).
- Converted bullets are gone from `IDEAS.md`; ideas you deferred/declined are still there.

If any check fails, fix it (or flag it) before the report — don't report success over a broken backlog.

## 7. Report

Summarize for the user: how many ideas were processed, the resulting task ids (grouped by which
idea they came from), any `dependsOn` that had to be dropped (a real authoring problem to flag, not
silently ignore), any ideas where **no task was warranted** (with the agent's reason), and any ideas
still sitting in the inbox (deferred/declined, skipped by a filter, or still blocked on an unanswered
question). Do NOT claim an idea is "done" — converting it to tasks means the loop can now build it,
not that it has been built.

If the sweep produced ≥1 new task, close by suggesting the user run
`/implementation-harness-pre-loop-checkin` before the next unattended loop run — it vets the new tasks'
facets/spec/scope quality and needs-human blockers, and gives a GO/NO-GO verdict.
