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
allowed-tools: Read, Bash, Glob
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

## 1. Needs-human tasks blocking buildable work

```bash
# every needs-human task id
jq -r '.tasks[]|select(.gate=="needs-human")|.id' .harness/tracking/TASKS.json
# for a given needs-human id NH, its buildable (pending, gate:null) dependents:
jq -r --arg nh "T<id>" '.tasks[]|select(.status=="pending" and .gate==null and (.dependsOn // []|index($nh)))|.id' .harness/tracking/TASKS.json
# is NH already owner-marked done (about to auto-reconcile on the loop's next pre-flight)?
jq -r --arg nh "T<id>" '.[$nh].done // false' .harness/tracking/human-done.json 2>/dev/null || echo "false"
```
For each needs-human blocker with ≥1 buildable dependent, report: the blocker id + which tasks it
blocks; whether `human-done.json` already has `done:true` for it (if so, it will auto-reconcile to
`status:"done"` on the loop's next pre-flight via `reconcile_overlays` and unblock its dependents **on
its own — no action needed**); if NOT yet marked done, flag it as **owner action needed now**, else the
loop idles on that branch of the DAG for the whole run. If `$ARGUMENTS` names a task, narrow to blockers
that (transitively) gate it.

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
file" from "read this file for context" in spec prose), so treat each WARN as a **NO-GO (scope-gap
advisory — inspect the flagged file(s); override if it's a false positive)** rather than a silent
downgrade — an owner should see and judge it, not have it disappear into an informational note.

## Final report — GO / NO-GO

Consolidate into ONE glance-able report before the owner starts a run:
- **Needs-human blockers**: blocker id → blocked ids → auto-resolving (yes/no).
- **Session hygiene**: dirty tree? ahead/behind? loop already running / lock held?
- **Dependency short-circuits**: list or "none found".
- **Task definition quality**: tasks with issues (+ which check, a–e), or "all clear".
- **Verdict**: plain **GO** (safe to start `.harness/scripts/supervise.sh`), **NO-GO** (name the blocking
  issue + what to do — e.g. "mark T012 done in the dashboard first", "a loop is already running", "run
  `/implementation-harness-loop-recover` first", or a check-(e) scope-gap advisory — name the flagged
  task/file and let the owner confirm it's a false positive before overriding), or **GO with notes**
  (clean, but informational notes like short-circuits or auto-resolving blockers exist).

Remember: **you changed nothing.** If asked to fix anything found here, direct the owner to
`/implementation-harness-loop-recover` or a manual edit — never mutate from this command.
