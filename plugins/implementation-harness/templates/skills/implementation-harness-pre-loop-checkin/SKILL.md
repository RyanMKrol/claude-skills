---
name: implementation-harness-pre-loop-checkin
description: >-
  Use for a read-only GO/NO-GO check of the harness backlog BEFORE starting an unattended loop run —
  phrases like "is the backlog ready to run", "check before I start the loop", "pre-flight the
  harness", "/pre-loop-checkin". Reports needs-human blockers, session hygiene (dirty tree / running
  loop / lock), dependency short-circuits, and per-task definition quality (facets, spec, scope), then
  a plain GO / NO-GO verdict. Strictly READ-ONLY — it never edits, commits, or pushes anything.
  Requires the harness scaffolded.
argument-hint: "[optional: a task id to focus on, e.g. T042 — omit for a full sweep]"
allowed-tools: Read, Bash, Glob, AskUserQuestion, Skill
---

# Pre-loop check-in (read-only GO/NO-GO)

Vet the autonomous build harness (`.harness/scripts/loop.sh`, run via `.harness/scripts/supervise.sh`)
**BEFORE** the owner starts an unattended run. This is the pre-run mirror of
`/implementation-harness-loop-recover` — but where that command diagnoses AND FIXES state, this one
only **looks and reports**. Focus target: `$ARGUMENTS` (a task id narrows checks 1 and 4 to it but
still runs the global checks 2 and 3; empty = full sweep). Read this whole file, then run the checks.

For the plain "what's ready / blocked / done" status board, `.harness/scripts/postflight.sh` already
exists (zero-token). This command adds the pre-run **quality validation + a GO/NO-GO verdict** on top.

## ⚠️ Guardrails (read-only / advisory-ONLY — do not violate)

- **You MUST NOT edit `.harness/tracking/TASKS.json`** — not `status`, not `facets`, nothing. Read only.
- **You MUST NOT write, commit, or push ANY file.** No worklog entries, no ledger rows, no scratch. This
  is purely observational.
- **You MUST NOT touch the owner overlays** (`tracking/reviews.json`, `human-done.json`,
  `manual-fail.json`) — only READ them (to see whether a needs-human blocker is about to auto-reconcile).
- **No destructive/mutating git** — no `commit`, `push`, `add`, `reset`, `clean`, `restore`,
  `checkout --`, `rebase`, branch create/delete. `git status`/`log`/`fetch`/`rev-list`/`rev-parse` (read-only) are fine.
- If you find something that needs fixing, **report it** — don't fix it here. Point the owner at
  `/implementation-harness-loop-recover` (interrupt-shaped state damage) or a manual edit.

## 1. Runnable work + needs-human blockers

The question that decides this axis is **"does the loop have anything it can build on its next
pass?"** — NOT "is every branch of the DAG unblocked?". A needs-human task gating *some* tasks is
fine: the loop simply skips that branch and builds other eligible work. An unresolved needs-human
blocker is therefore a **note, not a stop** — it only becomes a NO-GO when it (together with unmet
dependencies) leaves the loop with **nothing at all to run**.

```bash
# tasks the loop could pick and build RIGHT NOW (pending, not needs-human-gated, every dep done)
jq -r '
  (.tasks | map({(.id): .status}) | add) as $st
  | [ .tasks[]
      | select(.status=="pending" and .gate==null)
      | select((.dependsOn // []) | map($st[.] == "done") | all) ]
  | (length|tostring) + " eligible: " + ([ .[].id ] | join(", "))
' .harness/tracking/TASKS.json

# every needs-human task id
jq -r '.tasks[]|select(.gate=="needs-human")|.id' .harness/tracking/TASKS.json
# for a given needs-human id NH, its buildable (pending, gate:null) dependents:
jq -r --arg nh "T<id>" '.tasks[]|select(.status=="pending" and .gate==null and (.dependsOn // []|index($nh)))|.id' .harness/tracking/TASKS.json
# is NH already owner-marked done (about to auto-reconcile on the loop's next pre-flight)?
jq -r --arg nh "T<id>" '.[$nh].done // false' .harness/tracking/human-done.json 2>/dev/null || echo "false"
```

Interpretation:
- **≥1 eligible task → the loop has work → needs-human blockers are GO-with-notes, not NO-GO.** Still
  report each blocker: its id, which tasks it gates, and whether `human-done.json` already has
  `done:true` for it (if so, it auto-reconciles to `status:"done"` on the loop's next pre-flight via
  `reconcile_overlays` and unblocks its dependents on its own — no action needed). The point of the
  note is that the owner *may* want to resolve it to open up more of the backlog over a long run — but
  the run is safe to start either way.
- **0 eligible tasks → NO-GO ("nothing to build").** Every remaining task is either done, terminal, or
  gated/blocked, so the loop would idle immediately. Name the needs-human task(s) and/or unmet-dependency
  chains that gate all remaining work — resolving one is what gives the next run something to do.
- **Auto-reconcile caveat when counting eligibility:** if a task's *only* unmet dependency is a
  needs-human task already marked `done:true` in `human-done.json`, treat that task as effectively
  eligible — the overlay reconciles to `status:"done"` before selection, so the loop *will* have work
  and it's not a NO-GO. Don't let the raw jq count (which keys off `status` alone) trigger a false
  "nothing to build".
- If `$ARGUMENTS` names a task, narrow the needs-human reporting to blockers that (transitively) gate it.

## 2. Session hygiene — uncommitted / unpushed work, running loop, lock

```bash
git fetch origin --quiet
git status --porcelain                       # dirty tree?
git status -sb | head -1                      # ahead/behind
git rev-list --count origin/main..HEAD        # unpushed
git rev-list --count HEAD..origin/main        # behind
ps aux | grep -iE "loop\.sh|supervise\.sh|claude -p" | grep -v grep || echo "✓ no loop process"
GC="$(git rev-parse --git-common-dir)"; case "$GC" in /*) ;; *) GC="$(pwd)/$GC";; esac
LOCK="$GC/$(basename "$(git rev-parse --show-toplevel)")-loop.lock"
ls -la "$LOCK" 2>/dev/null && cat "$LOCK/pid" 2>/dev/null || echo "✓ no repo lock held"
```
Report: dirty tree yes/no (if yes, list paths — the in-place loop refuses to start dirty); ahead/behind
vs `origin/main`; **if a `loop.sh`/`supervise.sh` process is alive OR the lock is held by a live PID**,
say so plainly and recommend **NOT** starting a second run (two loop processes step on each other's git
state). If the lock dir exists but its `pid` is dead, note it as **stale** — a human or
`/implementation-harness-loop-recover` can clear it; do not clear it yourself here.

## 3. Dependency short-circuits (informational only)

```bash
jq -r '
  .tasks as $all
  | ($all | map({(.id): .status}) | add) as $status
  | $all[] | select(.status != "done") | . as $t
  | ($t.dependsOn // [])[] | select($status[.] == "done")
  | "\($t.id) depends on \(.) which is already done"
' .harness/tracking/TASKS.json
```
List every match (or "none found"). Do **not** rewrite `dependsOn` — purely informational; a human
decides whether to prune the edge.

## 4. Per-task definition quality

For every `pending`, `gate:null` task (or just the focus task):
```bash
# a) facets present, with a layer + workType drawn from facets.json's controlled vocabulary
jq -r '.tasks[]|select(.status=="pending" and .gate==null)
  |select((.facets|not) or (.facets.layer|not) or (.facets.workType|not))|.id' .harness/tracking/TASKS.json
VALID_LAYERS="$(jq -r '.facets.layer.values|keys[]' .harness/config/facets.json)"
VALID_WORKTYPES="$(jq -r '.facets["work-type"].values|keys[]' .harness/config/facets.json)"
# then for each task WITH facets, confirm .facets.layer ∈ VALID_LAYERS and .facets.workType ∈ VALID_WORKTYPES — flag any that aren't

# b) spec file exists
jq -r '.tasks[]|select(.status=="pending" and .gate==null)|[.id,.spec]|@tsv' .harness/tracking/TASKS.json \
  | while IFS=$'\t' read -r id spec; do [ -f "$spec" ] || echo "$id: missing spec file $spec"; done

# c) each existing spec has a NON-EMPTY '## Do' AND '## Done when' (content before the next header)
# d) scope is a non-empty array
jq -r '.tasks[]|select(.status=="pending" and .gate==null)
  |select((.scope|type != "array") or (.scope|length==0))|.id' .harness/tracking/TASKS.json

# e) scope-authoring sweep — does the spec's OWN text agree with its OWN scope?
bash .harness/scripts/check-task-scope.sh
```
Report every task that fails any of (a)–(d), naming the specific check. (These are exactly the authoring
slips that make a task fail its first build — a missing scope entry, an empty spec, a facet outside the
vocabulary.) Check (e), below, runs separately over the whole backlog rather than per-task.

Check (e) is a stronger version of (d): a non-empty `scope` array can still omit a file the spec
explicitly instructs touching — `check-task-scope.sh` catches that gap by cross-referencing the spec's
own prose against its own `scope`. Fold every `WARN: <id> — spec mentions \`<file>\` but it is not in
this task's declared scope` line into the report verbatim (task id + file) — don't re-derive or suppress
the linter's own output. This check is heuristic and false-positive-tolerant (it can't tell "edit this
file" from "read this file for context" in spec prose).

**Split the WARNs by the flagged task's status** — `check-task-scope.sh` sweeps the WHOLE backlog,
including terminal tasks the loop will never select. Look up each WARN'd id's `status` in `TASKS.json`:
- A WARN on a **pending, `gate:null`** task (one the loop can actually pick) is a **NO-GO (scope-gap
  advisory — inspect the flagged file(s); override if it's a false positive)** rather than a silent
  downgrade — an owner should see and judge it, not have it disappear into an informational note.
- A WARN on a **terminal task** (`failed`/`done`) or a **needs-human** task is **backlog-hygiene only,
  not run-blocking** — the loop never selects it, so the WARN can't affect the upcoming run. Report it
  as a note (worth cleaning up someday), not a NO-GO.

Offer
to triage and fix them via `implementation-harness-fix-scope-gaps` (it fans out a cheap-model judge per
warning and only asks about genuinely ambiguous cases) — that skill is `user-invocable: false` (not in
the owner's own `/` menu; a deliberate follow-up step, not something to run blind), so surface the offer
via the `AskUserQuestion` flow in the Final report section below rather than a command to type
themselves, the same way this command already points at `/implementation-harness-loop-recover` (which IS
directly invocable) for other fixable categories; this command itself never fixes anything, it only
reports — any fix only happens as an explicit follow-up step once the owner confirms.

## Final report — GO / NO-GO

Consolidate into ONE glance-able report before the owner starts a run:
- **Runnable work**: the eligible-now count + ids (what the loop will build next pass).
- **Needs-human blockers**: blocker id → blocked ids → auto-resolving (yes/no). Mark whether the run
  still has other eligible work (note) or the blocker gates *all* remaining work (NO-GO).
- **Session hygiene**: dirty tree? ahead/behind? loop already running / lock held?
- **Dependency short-circuits**: list or "none found".
- **Task definition quality**: tasks with issues (+ which check, a–e), or "all clear".
- **Verdict**: plain **GO** (safe to start `.harness/scripts/supervise.sh`), **NO-GO**, or **GO with
  notes** (clean and runnable, but informational notes like short-circuits, hygiene-only scope WARNs on
  terminal tasks, or unresolved needs-human blockers with other work still eligible). A verdict is
  **NO-GO only** when one of these would actually break or stall the next run — name it + what to do:
  - **Nothing to build** — 0 eligible tasks (every remaining task is gated/blocked); resolve a
    needs-human task or unmet dependency first (e.g. "mark T012 done in the dashboard first").
  - **A loop is already running / a live lock is held** — don't start a second one; run
    `/implementation-harness-loop-recover` first if the lock is stale.
  - **A scope-gap advisory on a pending, buildable task** (check (e)) — name the flagged task/file.
  An unresolved needs-human blocker on its own, when other work is still eligible, is **GO with notes**,
  not NO-GO.

## Offer any fix via `AskUserQuestion` — don't make the owner type it out

If the verdict names a concrete follow-up fix the owner could run right now (today that's only the
check-(e) scope-gap advisory → `implementation-harness-fix-scope-gaps`, since that's the one companion
skill this command knows about), close the report with **one `AskUserQuestion` call** instead of ending
on a prose question the owner has to answer by typing — a clickable option is strictly easier than
composing a reply:
- Question: something like "Scope-gap advisory on N task(s) — triage and fix now?"
- Options: `Yes, triage and fix them` (recommended, first) / `No, I'll review manually`. Mention in each
  option's description what happens (`Yes` → runs `implementation-harness-fix-scope-gaps`, which mutates
  `TASKS.json` scope arrays and pushes to main; `No` → nothing changes, verdict stands as NO-GO).
- If the owner picks **Yes**, invoke the `Skill` tool for `implementation-harness-fix-scope-gaps` right
  then (it's `user-invocable: false` — not in the `/` menu — but still directly invocable by you once the
  owner has explicitly confirmed via the question). Report back what it did.
- If **No** (or any other blocking issue with no companion skill, e.g. "a loop is already running"),
  stop here — don't ask again, don't fix anything yourself. Point at `/implementation-harness-loop-recover`
  or a manual edit as before.

Remember: **this check-in itself changes nothing.** Any mutation only ever happens as an explicit
follow-up the owner opted into via the question above, through a separate skill — never silently, and
never as a side effect of running this command.
