---
name: implementation-harness-fix-scope-gaps
description: >-
  Use to triage and fix `check-task-scope.sh`'s scope-authoring WARNs — phrases like "fix the scope
  gaps", "triage the scope warnings", "/fix-scope-gaps". Fans out one cheap-model subagent per WARN to
  independently judge real-gap vs false-positive against the spec's own prose, auto-applies confident
  real gaps to that task's `scope` array, and asks the owner only about genuinely ambiguous cases. This
  MUTATES `.harness/tracking/TASKS.json` (scope arrays only) and pushes to main. Requires the harness
  scaffolded.
argument-hint: "[optional: a task id to focus on, e.g. T042 — omit for a full sweep]"
allowed-tools: Read, Edit, Bash, Glob, Agent
---

# Triage and fix scope-authoring gaps

`check-task-scope.sh` is a heuristic, false-positive-tolerant linter (see its own header) — it flags
every backtick-quoted file-like mention in a task's spec that isn't in that task's declared `scope`, but
it can't tell "the spec means to edit this" from "the spec mentions this for context only." Your job:
run it, have a subagent independently judge EACH warning against the spec's own prose, auto-fix the
confident real gaps, and only bother the owner with what's genuinely ambiguous. Focus target:
`$ARGUMENTS` (a task id narrows the sweep to it; empty = every warning `check-task-scope.sh` finds).
Read this whole file, then execute in order.

This is the fix-side companion to `/implementation-harness-pre-loop-checkin`'s read-only check (e) —
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
  `/implementation-harness-loop-recover`'s own git-hygiene convention (never `git add -A`).
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
Parse every `WARN: <id> — spec mentions \`<path>\` ...` line into `(task_id, path)` pairs (the two WARN
phrasings — "not in this task's declared scope" and "no scope entry's filename matches it" — both carry
the same two fields). No warnings → report "all clear, nothing to triage", stop here.

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

- `FALSE_POSITIVE` (any confidence) → drop. No owner action, no mutation, don't mention it further than
  a count in the final report.
- `REAL_GAP` + `high` confidence → stage `(task_id, path)` for auto-apply.
- `REAL_GAP` + `low` confidence, or a subagent whose output didn't parse as a clean verdict line →
  collect for a single **batched `AskUserQuestion`** (one question per still-ambiguous pair, or grouped
  if there are many — mirror `/implementation-harness-upgrade`'s batched-question pattern rather than
  asking one at a time) so the owner only spends attention on what a cheap model genuinely couldn't
  resolve, not on everything `check-task-scope.sh` flagged.

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
and push.

## 6. Report

- **Auto-fixed** (high-confidence real gaps applied): task id, path, the judge's one-line reason.
- **Owner-confirmed and applied** (if any low-confidence cases were confirmed): same shape.
- **Dismissed as false positive**: a count (list them too if the owner would find it useful — don't
  hide the reasoning, just don't force them to read it).
- **Commit SHA**, or "nothing to commit" if every warning was a false positive.
- If the loop-running guardrail stopped you at step 1, that's the whole report — say so plainly and
  stop; don't proceed with any of the later steps.
