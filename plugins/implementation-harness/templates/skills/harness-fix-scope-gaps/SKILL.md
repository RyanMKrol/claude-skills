---
name: harness-fix-scope-gaps
description: >-
  Internal fix-side companion to `harness-pre-loop-checkin`'s check (e) — invoke this
  when a pre-loop-checkin report (or the owner directly) flags scope-authoring WARNs from
  `check-task-scope.sh` and wants them triaged. Not meant to be run blind/standalone without a reason —
  it's the follow-up step after warnings are already known. Fans out one cheap-model subagent per WARN
  to independently judge real-gap vs false-positive against the spec's own prose, auto-applies confident
  real gaps to that task's `scope` array, and asks the owner only about genuinely ambiguous cases. This
  MUTATES `.harness/tracking/TASKS.json` (scope arrays only) and pushes to main. Requires the harness
  scaffolded.
argument-hint: "[optional: a task id to focus on, e.g. T042 — omit for a full sweep]"
allowed-tools: Read, Edit, Bash, Glob, Agent
user-invocable: false
---

# Triage and fix scope-authoring gaps

`check-task-scope.sh` is a heuristic, false-positive-tolerant linter (see its own header) — it flags
every backtick-quoted file-like mention in a task's spec that isn't in that task's declared `scope`, but
it can't tell "the spec means to edit this" from "the spec mentions this for context only." Your job:
run it, have a subagent independently judge EACH warning against the spec's own prose, auto-fix the
confident real gaps, and only bother the owner with what's genuinely ambiguous. Focus target:
`$ARGUMENTS` (a task id narrows the sweep to it; empty = every warning `check-task-scope.sh` finds).
Read this whole file, then execute in order.

This is the fix-side companion to `/harness-pre-loop-checkin`'s read-only check (e) —
that command only ever reports raw warnings; this one is where they get resolved.

## ⚠️ Guardrails (do not violate)

- **The loop MUST NOT be running.** This skill mutates `.harness/tracking/TASKS.json` — exactly what
  the loop reads and writes. If a `loop.sh`/`supervise.sh` process is alive, or the repo lock is held by
  a live PID, STOP and tell the owner; do not proceed.
- **Scope only.** Never touch `status`, `facets`, `dependsOn`, or any other task field — the only
  mutation this skill ever makes is appending a path to a task's `scope` array.
- **Never invent a scope entry the judge didn't actually recommend.** The subagent fan-out is the
  source of truth for what gets added; don't add anything based on your own independent guess.
- **One commit for the whole sweep**, staging only `.harness/tracking/TASKS.json` — mirrors
  `/harness-loop-recover`'s own git-hygiene convention (never `git add -A`).
  `.harness/.scope-gap-ignores/*.json` (step 6) is gitignored local scratch — never staged, never
  committed, same as `.pending-tasks/*.json` never being committed.
- **Judge subagents are read-only** — they return a verdict, they never edit `TASKS.json` themselves.
  Applying fixes happens once, single-threaded, after every subagent has returned — parallel subagents
  editing the same JSON file would race each other.

## 1. Confirm the loop isn't running

```bash
ps aux | grep -iE "loop\.sh|supervise\.sh|claude -p" | grep -v grep || echo "✓ no loop process"
GC="$(git rev-parse --git-common-dir)"; case "$GC" in /*) ;; *) GC="$(pwd)/$GC";; esac
LOCK="$GC/$(basename "$(git rev-parse --show-toplevel)")-loop.lock"
ls -la "$LOCK" 2>/dev/null && cat "$LOCK/pid" 2>/dev/null || echo "✓ no repo lock held"
```
A live process or a lock held by a live PID → STOP, tell the owner, do not proceed.

## 2. Gather the warnings

```bash
bash .harness/scripts/check-task-scope.sh $ARGUMENTS
```
`check-task-scope.sh` already consults `.harness/.scope-gap-ignores/<id>.json` itself and suppresses
anything already validly dismissed (spec unchanged since) — so what comes back here is only genuinely
new or spec-changed-since-dismissal warnings; nothing to filter yourself. Parse every `WARN: <id> —
spec mentions \`<path>\` ...` line into `(task_id, path)` pairs (the two WARN phrasings — "not in this
task's declared scope" and "no scope entry's filename matches it" — both carry the same two fields).
No warnings → report "all clear, nothing to triage", stop here.

## 3. Judge fan-out — one subagent per pair, launched in parallel

For each `(task_id, path)` pair, look up that task's `spec` file path from `TASKS.json`. Then launch
**all** the judge subagents together, in a single message with multiple `Agent` tool calls (not one at
a time) — each call:
- Uses `model: claude-haiku-4-5` — this is a scoped, single-file yes/no judgment call, not open-ended
  reasoning, so a cheap/fast model is enough and keeps the sweep cheap even over a large backlog.
- Gets a tightly-scoped prompt containing ONLY: the task id, the flagged path/name, the spec file's
  path, and this instruction — *"Read the spec file. Find where it mentions `<path>`. Judge: does the
  spec's `## Do` clearly instruct CREATING or EDITING this file (→ REAL_GAP, it should be added to this
  task's scope), or is it mentioned only as background/read-only/an exemption reference — something the
  spec explicitly says NOT to touch, or cites for context only (→ FALSE_POSITIVE)? Also say if it isn't
  a real file at all (→ FALSE_POSITIVE). Return exactly one line: `VERDICT: REAL_GAP|FALSE_POSITIVE
  CONFIDENCE: high|low REASON: <one sentence>`."*
- Subagents don't need write access — they read the one spec file and return their verdict line as
  their final text. Nothing else.

## 4. Aggregate verdicts (single-threaded, after every subagent has returned)

- `FALSE_POSITIVE` (any confidence) → stage `(task_id, path, reason)` to be recorded as a dismissal
  (step 6) — no owner action needed, but it DOES get written so this exact warning doesn't resurface
  on the next `pre-loop-checkin`/`fix-scope-gaps` run against the same spec content.
- `REAL_GAP` + `high` confidence → stage `(task_id, path)` for auto-apply (step 5).
- `REAL_GAP` + `low` confidence, or a subagent whose output didn't parse as a clean verdict line →
  collect for a single **batched `AskUserQuestion`** (one question per still-ambiguous pair, or grouped
  if there are many — mirror `/implementation-harness:upgrade`'s batched-question pattern rather than
  asking one at a time) so the owner only spends attention on what a cheap model genuinely couldn't
  resolve, not on everything `check-task-scope.sh` flagged. The owner's answer to each resolves it the
  same way: "add to scope" → step 5, "false positive / leave it" → step 6.

## 5. Apply confirmed fixes

For every `(task_id, path)` confirmed (auto-applied high-confidence + owner-confirmed low-confidence),
append `path` to that task's `scope` array — idempotent (skip if already present):
```bash
jq --arg id "$task_id" --arg p "$path" '
  (.tasks[] | select(.id==$id) | .scope) |=
    (if index($p) then . else . + [$p] end)
' .harness/tracking/TASKS.json > .harness/tracking/TASKS.json.tmp \
  && jq -e '.tasks|length' .harness/tracking/TASKS.json.tmp >/dev/null \
  && mv .harness/tracking/TASKS.json.tmp .harness/tracking/TASKS.json
```
Apply all confirmed pairs, THEN validate once (`jq -e '.tasks|length' .harness/tracking/TASKS.json`),
THEN make **one commit** covering every fix in this sweep (stage only `.harness/tracking/TASKS.json`),
and push. No real gaps this run → skip the commit, move on to step 6.

## 6. Record dismissals (false positives, so they stop resurfacing)

For every `(task_id, path, reason)` staged in step 4, record that task's dismissal — this is what makes
`check-task-scope.sh` (and therefore `pre-loop-checkin`) stop re-flagging it, without ever needing to be
actively deleted. Run the dismissal script **once per false positive**, each as its own standalone,
**single-line** command:
```bash
bash .harness/scripts/scope-gap-dismiss.sh "T042" "src/foo/bar.js" "spec cites it as a read-only exemption reference, not an edit target"
```
The script does the spec-hash + idempotent JSON write internally (writing `.harness/.scope-gap-ignores/<id>.json`),
so you just pass the task id, the flagged path, and the one-sentence reason.

⚠️ **Keep each call on ONE physical line, and put the reason INLINE as the third argument** — do not set
it on a separate `reason=…` assignment line, and do not wrap these in a heredoc or a multi-line `for`
loop. The reason is free-form prose that routinely contains an em dash (`—`) or other non-ASCII, and a
**multi-line** shell command with a multibyte character in it intermittently corrupts the Bash tool's
parsing of the following lines (every later command reads as `command not found` — a real, reproduced
failure). A single-line invocation with the reason as one quoted argument avoids that class entirely; if
you have several dismissals, run several separate single-line commands (or separate Bash calls), never one
multi-line block.

This is local, gitignored scratch — **no commit, no push** for this step (see guardrails). The script is
idempotent (re-running for the same `id`+`path` replaces that entry rather than appending a duplicate) and
stamps the current spec hash, so a dismissal auto-expires — stops matching — if the spec later changes.

## 7. Report

- **Auto-fixed** (high-confidence real gaps applied): task id, path, the judge's one-line reason.
- **Owner-confirmed and applied** (if any low-confidence cases were confirmed): same shape.
- **Recorded as false positive** (won't resurface unless the spec changes): task id, path, reason —
  don't hide the reasoning, but make clear these needed no owner action.
- **Commit SHA** for the scope fixes, or "nothing to commit" if every warning was a false positive.
- If the loop-running guardrail stopped you at step 1, that's the whole report — say so plainly and
  stop; don't proceed with any of the later steps.
