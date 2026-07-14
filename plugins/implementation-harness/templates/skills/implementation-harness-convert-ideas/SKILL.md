---
name: implementation-harness-convert-ideas
description: >-
  Use when the user wants to process the ideas inbox (.harness/tracking/IDEAS.jsonl) into real
  TASKS.json backlog tasks — phrases like "convert the ideas", "process the ideas inbox", "turn
  the ideas into tasks", "/convert-ideas". Sweeps the WHOLE inbox at once: dedupes near-duplicate
  ideas, converts each idea (or cluster) in PARALLEL via one sub-agent each, relays any genuine
  open questions back through a real AskUserQuestion, then runs a single locked consolidation pass
  that allocates real task ids, writes per-task specs, and removes converted ideas from the
  inbox. Requires the implementation harness to already be scaffolded.
argument-hint: "[optional: only convert idea #N, or a keyword filter]"
allowed-tools: Read, Write, Edit, Bash, Glob, Agent, AskUserQuestion, SendMessage, Artifact
---

# Convert the ideas inbox into backlog tasks

You are the COORDINATOR of a parallel ideas→tasks conversion sweep. You do the dedup/clustering
and the final consolidation yourself; you delegate the actual explore-and-shape work for each
idea (or cluster of related ideas) to one sub-agent per idea, running concurrently. Read this
whole file, then execute in order.

## 0. Pre-flight

- Require the harness: `.harness/docs/HARNESS.md`, `.harness/scripts/loop.sh`, and
  `.harness/tracking/TASKS.json` must exist. If any is missing, point the user at
  `implementation-harness:implementation-harness-create` first.
- Require `jq` and `node` on PATH.
- **Recovery check — do this BEFORE touching the current inbox.** An earlier sweep may have been
  interrupted (session ended mid-flight). Scan `.harness/.pending-tasks/` and
  `.harness/.pending-questions/`:
  - Leftover `.pending-tasks/*.json` files are drafts an agent finished shaping. A draft whose DoD is
    already **confirmed** — i.e. it has NO sibling `.pending-questions/<slug>.json` with unresolved
    questions — can go straight to consolidation (§5) without re-running exploration. Tell the user you
    found them and offer to consolidate before starting a new sweep.
  - Leftover `.pending-questions/*.json` files mean an idea still has questions the owner hasn't
    answered — including the mandatory definition-of-done confirmation (§3 step 5), which is why a
    sibling `.pending-tasks` draft must NOT be consolidated until they're resolved. Re-surface them via
    `AskUserQuestion` now (§4's format — summarize each idea's `ideaSummary` first, then batch its
    `questions`), then fold the answers into that idea's `.pending-tasks/<slug>.json` (resume its agent,
    or edit the file yourself) before consolidating.
  - **Stale already-converted ideas.** A prior sweep may have consolidated tasks but died before its
    idea-removal committed, leaving an inbox row whose task already exists. Skim
    `git log --oneline -15` for recent `consolidate-ideas`/backlog commits and the ~10 most recent
    `TASKS.json` task titles; if an inbox idea looks like it already became a task, **surface it to
    the owner** (name the idea + the matching task id) and only remove it if they confirm — never
    silently delete a row you're merely guessing was converted.
  - If all of the above are clear, proceed normally.

## 1. Read the inbox

Read `.harness/tracking/IDEAS.jsonl` — one JSON object per line, `{id, title, description,
capturedAt}`. Parse every line (skip a garbled one — flag it to the owner rather than silently
dropping their idea). If the user's argument names a specific idea id or a keyword, filter to
matching ideas (match the keyword against `title` and `description`); otherwise process the whole
inbox. If the inbox is empty, say so and stop.

## 2. Dedup + cluster pass (you do this, not an agent)

Two distinct sub-passes, both by reading (cheap — no agents):

**2a. Dedup — ask, don't auto-merge.** Find ideas that are genuinely the *same idea described twice*
(near-identical intent, not merely related) — compare `title` and `description`. Group each set of
suspected duplicates and **surface it to the owner via `AskUserQuestion`** — ask whether to merge them
into one, keep the clearer one, or treat them separately. **Do NOT silently collapse them yourself** —
a semantic near-match may be two real, distinct asks, and only the owner knows. Apply their decision
before clustering.

**2b. Cluster — group by shared answer-space.** Of the survivors, group any that share the **same
underlying feature or code area** — ideas that would require exploring the same code and would produce
overlapping or dependent tasks — into ONE cluster handled by ONE agent (so it doesn't duplicate
exploration or emit conflicting task sets). Ideas with no overlap each become their own singleton
cluster. Clustering is a scheduling choice (one agent vs many), not a merge — it doesn't drop any idea.

## 3. Fan out — one agent per idea/cluster, in parallel

For each cluster, launch a **general-purpose** agent (send all clusters' Agent calls in a single
message so they run concurrently). Each agent gets its own idea/cluster text and writes ONLY to its
own scratch file — zero lock contention between agents, since none of them touch git or
`TASKS.json` directly.

**Agent prompt template** (fill in `<IDEA(S)>` — each idea's `id`, `title`, and full `description`
verbatim from `IDEAS.jsonl` (a cluster gets more than one), and `<SLUG>`, a short kebab-case tag for
this idea/cluster used in its scratch filenames):

> You are converting a raw idea into implementation-harness backlog tasks for this repo. Read this
> whole prompt, then act.
>
> **The idea(s):**
> <IDEA(S) — for each: "id: N — title: <title>" then the full description text>
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
> 5. **You are in the planning stage — bias TOWARD asking.** This is the one point where a human is
>    reachable and a strong model is shaping the spec; a weaker, unattended builder later implements it
>    blind, from the spec alone, with no chance to ask. Resolve ambiguity with the owner NOW rather than
>    guessing — whenever a decision changes *what gets built* or *what "done" means*, surface it. Decide
>    silently only the genuinely cosmetic/mechanical (a variable name, which of two equivalent spots),
>    noting those in the unit's `report`. When in doubt, ask. You do NOT have `AskUserQuestion` (do not
>    call it) — you relay through the coordinator by writing a questions file (below).
>    - **Always confirm the definition of done (mandatory).** For every idea you author a task for, relay
>      ≥1 question, and ≥1 MUST confirm the acceptance bar — restate the `specDoneWhen` you're proposing
>      and ask the owner to confirm or adjust it ("propose + confirm"). Add any other build-changing
>      decisions as further questions.
>    - Write `.harness/.pending-questions/<SLUG>.json`:
>      ```json
>      { "slug": "<SLUG>", "ideaIds": [<the id(s) of the idea(s) in this cluster>],
>        "ideaSummary": "ONE short plain-language paragraph — what this idea is, why, and what will change; the coordinator shows it to the owner BEFORE the questions so they know which idea is being discussed.",
>        "context": "<what you've found so far>",
>        "questions": [
>          { "topic": "definition-of-done", "question": "For idea #<N> (<one-sentence restatement of what this idea is, drawn from ideaSummary>): I'm planning done-when to be: <the acceptance bar you drafted>. Does this match what you want, or should it differ?" },
>          { "topic": "other", "question": "For idea #<N> (<same one-sentence restatement>): <another decision that changes what's built — include only if real>" }
>        ] }
>      ```
>      `questions` MUST hold ≥1 entry and ≥1 with `topic: "definition-of-done"`. **Every `question` string
>      must open with a one-sentence, self-contained restatement of which idea it's about** — "For idea
>      #<N> (<one-sentence gist of the idea>): ..." — a full sentence, not just a couple of words; with
>      several ideas in flight there isn't always enough distinguishing signal in a short phrase. Don't
>      rely on the file's `ideaSummary` or a header chip alone: the coordinator batches questions in
>      groups of ≤4 across possibly several calls (§4), so a given question may be read well after its
>      idea's one-time upfront recap has scrolled out of view — each question has to carry its own
>      context, not borrow it from something shown earlier.
>    - **Always write BOTH files.** Also write your best-draft `.pending-tasks/<SLUG>.json` (step 6): the
>      DoD question *confirms* the bar you drafted, so shape the task fully and let the owner adjust it —
>      don't block. Hold a unit OUT of pending-tasks only when it is genuinely un-shapeable until a
>      `topic: "other"` answer lands (partial output is fine — the coordinator relays and resumes/re-runs you).
>    - **Exemption:** if you conclude **no task is warranted** (`units: []`, step 6), skip the DoD
>      question — nothing is being built; just record why in `report`.
> 6. If you conclude **no task is actually warranted** (the idea is already done, is a non-issue, or on
>    investigation doesn't hold up), still write `.harness/.pending-tasks/<SLUG>.json` but with
>    `"units": []`, a `"report"` explaining why, AND the `ideaIds` — so consolidation removes the
>    converted idea(s) from the inbox (the report is the record of why nothing was authored).
>    Otherwise, write `.harness/.pending-tasks/<SLUG>.json` with the shaped units:
>    ```json
>    {
>      "units": [
>        {
>          "tempId": "<SLUG>-a", "title": "...", "dependsOn": ["<SLUG>-a" or a real "TNNN" id],
>          "gate": null, "tags": [...], "scope": ["files this unit should touch"],
>          "design": null, "verify": [], "expectsTest": false,   // true → the loop REQUIRES a test file in the diff; if you set it, say in specDoneWhen WHAT the test must assert (else the builder can only write a token one)
>          "facets": { "layer": "...", "workType": "...", "risk": [] },
>          "visualVerify": true,   // OPTIONAL — include ONLY per step 2b (a maybe-visual task you judged visual). Omit for auto-covered / non-visual tasks.
>          "specOverview": "ONE or TWO plain-language sentences — the 'what are we actually doing here, and why, at a glance' line. It's read FIRST and fastest, before the denser Do / Done-when detail.",
>          "specDo": "1-3 sentences: the work.",
>          "specDoneWhen": "The task-specific, concrete, runnable acceptance bar. Do NOT restate the universal DoD (format/lint/test/CI-green) — that's already covered once, globally."
>        }
>      ],
>      "ideaIds": [<the id(s), from IDEAS.jsonl, of every idea this unit set consumed>],
>      "report": "optional: any judgment calls you made, or why no task was warranted (units: [])."
>    }
>    ```
>    `needs-human` units omit `facets` entirely. `tempId`s only need to be unique within YOUR file;
>    `dependsOn` may reference your own `tempId`s or a real existing `TNNN` id if this idea builds on
>    an existing task.
> 6a. **`scope` is a high-stakes field — self-check it before you finalize.** It's a hard structural
>    gate, and the loop now **blocks a task on its very first out-of-scope edit** (no retry, no model
>    escalation), so a too-narrow scope silently wastes the whole task. **Prefer a directory-level
>    entry** (`src/foo/**`) over an exhaustive file list wherever the work is contained in a directory —
>    it's more robust to files you didn't foresee and still gates the real risk (straying into an
>    unrelated subsystem). Then do the coverage self-check: for every unit, re-read your OWN `specDo`
>    (and `specOverview`) text and list every file it instructs creating/editing/touching. Confirm each
>    one appears in that SAME unit's `scope` array — an exact path, or a directory entry that covers it
>    (`src/foo/**` covers `src/foo/bar.js`). If a file `specDo` promises to touch isn't in `scope`, fix
>    your draft NOW, before writing the file: add the missing path to `scope`, or narrow `specDo` so it
>    no longer promises an out-of-scope edit. This is the same gap `.harness/scripts/check-task-scope.sh`
>    catches after the fact — catching it here means the loop's real structural scope gate never has to
>    block the build. This is a mechanical/self-contained check, not a "what should be built" ambiguity
>    — fix it silently, no question needed.
>
>    Your final message should just confirm what you wrote — the coordinator
>    reads the file, not your response text.

## 4. Relay pending questions — every question self-contained (multi-round, batched ≤4/call)

Use durable files, not conversation memory — questions and answers must survive a dropped session. Every
idea an agent authored a task for left a `.harness/.pending-questions/<slug>.json` (§3 step 5), so this
relay runs on essentially every sweep. Read them all, then:

- **Publish a plain-Markdown reference Artifact before asking anything — the owner can't confirm a
  definition of done they can't see.** Do NOT hand-author an HTML page and do NOT load `artifact-design`:
  write a structured **Markdown** file and hand it straight to the `Artifact` tool (favicon 🧩). A
  Markdown Artifact renders, **auto-opens, and takes focus exactly like an HTML one** — the owner gets the
  same "it opens itself" reading experience for a fraction of the effort (no CSS, no bespoke layout, no
  design pass). Build it from the REAL current draft content, never placeholder text, with this shape:
  - An `#` H1 title, then one italic line of intro (what this is — confirm each task's Done-when; the
    questions are also being asked directly, this page is the full context).
  - **A top "On this page" list** — the navigation, since a Markdown Artifact has no sticky sidebar. One
    bullet per idea (its `ideaSummary` title) with that idea's unit titles nested beneath, each a
    `[title](#anchor)` jump link. Anchors are the GitHub-style lowercased-hyphenated heading slug, so give
    each idea an `## Idea #N — <title>` heading and each unit a `### <title>` heading and the links resolve.
  - **One `##` section per idea**, covering every currently-unresolved `.pending-questions/<slug>.json`:
    the `ideaSummary`, then every unit from that idea's matching `.pending-tasks/<slug>.json` in full —
    each a `###` heading with its `specOverview` and `specDo`, and its **`specDoneWhen` on its own bolded
    "✅ Done when" line** (it's the thing actually being confirmed — keep it visually distinct) — followed
    by that idea's own pending `questions` text, so the owner reads the exact draft a question refers to
    right next to the question itself.

  Write the `.md` to your own scratchpad directory and publish it. **If the relay loops across multiple
  rounds** (an answer opens a new question — see below), regenerate and redeploy to the SAME file path
  each round rather than creating a new one — the tool redeploys in place, so the owner keeps one tab open
  for the whole session instead of chasing a new link every round. Zero pending questions → skip this
  entirely, nothing to relay.
- **Summarize before asking, but don't rely on it.** Emit a short markdown recap — one line per idea: its
  `ideaSummary` (and slug) — plus the artifact URL from above ("Full drafted context: `<url>` — keep this
  open while answering below") — so the owner has the full list up front. This recap is a courtesy
  overview, **not** the question's only source of context: every individual question also opens with its
  own one-sentence restatement (§3 step 5), because the recap can scroll out of view long before a later
  question is actually answered.
- **Batch in groups of ≤4 — `AskUserQuestion` hard-caps a single call at 4 questions.** Gather every
  question from every pending-questions file, then split into calls of at most 4. Keep one idea's own
  questions together within the same call where possible (don't split a single idea's DoD confirmation
  from its "other" question across two calls). More than 4 questions total means multiple sequential
  `AskUserQuestion` calls — that's expected, not an error; never try to cram everything into "one" call.
  Give each question an idea-naming header/label too (still useful as a quick visual scan, just not
  load-bearing on its own anymore).
- **Fold each answer back to its `(slug, question)`.** For a `definition-of-done` answer: if the owner
  adjusted the bar, update that idea's `.pending-tasks/<slug>.json` `specDoneWhen` (and any unit that
  depends on it) — resume the idea's agent via `SendMessage` if still addressable, else edit the file
  yourself; if they confirmed as-is, leave the draft. For a `topic: "other"` answer: fold it in the same
  way, finishing any unit that was held pending it.
- **The answer may open a NEW question.** If so, **append** it to the same file's `questions` array (keep
  `ideaSummary` and the already-answered entries) and relay again. Delete a `.pending-questions/<slug>.json`
  only once ALL its questions are resolved. **There is no cap on rounds** — loop §4 until every
  pending-questions file is drained.
- **If the owner defers or declines the idea entirely**, delete BOTH its `.pending-questions/<slug>.json`
  AND its draft `.pending-tasks/<slug>.json` — with no pending-tasks entry, consolidation won't touch its
  row, so the idea simply **stays in the inbox** for a future sweep (nothing authored, nothing removed).

## 5. Consolidate

Run `.harness/scripts/consolidate-ideas.sh`. This is the ONLY step that touches git: it acquires
the harness's repo lock (waiting if the loop currently holds it, rather than failing), allocates
real sequential task ids, resolves every `tempId` reference (dropping and logging any that don't
resolve), writes each unit's `tasks/TNNN.md` spec, appends the new task objects to `TASKS.json`,
removes the converted ideas from `IDEAS.jsonl` by `id`, and commits + pushes. Read its output.

## 6. Validate

Before reporting, confirm consolidation left the backlog sound (catches a corrupt write or a shaping bug):
- `jq empty .harness/tracking/TASKS.json` — valid JSON.
- No duplicate task ids; every `dependsOn` id exists in `TASKS.json`.
- Every new **buildable** task has `facets` with `layer`/`workType` drawn from `config/facets.json`'s
  vocabulary; every `needs-human` task has none.
- Every new task's `spec` path exists on disk with non-empty `## Do` / `## Done when`.
- `.harness/.pending-tasks/` and `.harness/.pending-questions/` are empty (no straggler left un-consolidated).
- Converted ideas are gone from `IDEAS.jsonl`; ideas you deferred/declined are still there.

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
