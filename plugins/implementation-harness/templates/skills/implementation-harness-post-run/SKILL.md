---
name: implementation-harness-post-run
description: >-
  Use when the user wants the whole standard follow-up after an unattended loop run in ONE command —
  phrases like "run the follow-up", "post-run sweep", "triage the run", "do the after-run pass",
  "/post-run". Chains the existing skills IN ORDER, inline in this conversation:
  review-failed (only if failed/blocked tasks exist) → convert-ideas (only if the ideas inbox has
  rows) → pre-loop-checkin (always) → fix-scope-gaps (only when the check-in WARNs and the owner
  says yes). Every sub-skill runs FULLY — all of its questions and guardrails — nothing is
  streamlined away. Ends at the GO/NO-GO verdict; it NEVER starts the loop. Requires the harness
  scaffolded.
argument-hint: "[optional: stages to skip, e.g. 'skip ideas' or 'skip failed' — omit to run everything]"
allowed-tools: Read, Write, Edit, Bash, Glob, Grep, Agent, AskUserQuestion, SendMessage, Artifact, Skill
---

# Post-run follow-up (one command for the whole triage sequence)

You are the COORDINATOR of the standard post-run sequence the owner would otherwise type as four
separate commands. You add **no machinery of your own** — each stage IS the existing project-local
skill, executed faithfully. Your only jobs are: probe which stages are needed, run them in order,
keep a one-line status trail between stages, and stop at the final GO/NO-GO. Read this whole file,
then execute in order.

## How to run a stage (the one load-bearing rule)

For each stage below, **Read the named `SKILL.md` in full and execute it exactly as if the owner
had just invoked it themselves** — its guardrails, its agents/relays, and **ALL of its
`AskUserQuestion` rounds**. Being one hop inside an orchestrator changes NOTHING about a
sub-skill's behavior:

- **Never suppress, merge, summarize, or answer on the owner's behalf a question a sub-skill would
  ask.** The planning stage is the only cheap place to resolve ambiguity (the harness's
  front-load-clarification principle); an orchestrator that "streamlines" questions silently
  degrades every downstream build. If in doubt, the sub-skill's own text wins over brevity.
- Run stages **strictly sequentially** — a stage's writes (new tasks, rewires, scope fixes) are
  input to the next stage. Never overlap two stages' agent waves.
- Each sweep stage runs its own `consolidate-ideas.sh` commit+push. Two consolidation passes in one
  session is expected — it matches the manual sequence exactly.

## 0. Guards (before anything)

- `.harness/docs/HARNESS.md` must exist — otherwise stop: the harness isn't scaffolded here.
- **The loop must not be running.** Stages A/B/D mutate `TASKS.json`; never sweep under a live loop:
  ```bash
  T="$(git rev-parse --show-toplevel)"; GC="$(git rev-parse --git-common-dir)"
  [ -d "$GC/$(basename "$T")-loop.lock" ] && echo "LOCK HELD"
  ```
  If the lock is held (or a fresh loop heartbeat / `supervise.sh` process is evident), STOP and
  report — the owner either waits for the run to finish or investigates a stale lock via
  `/implementation-harness-loop-recover`. Do not proceed to any stage.
- Leftover `.harness/.pending-tasks/` / `.pending-questions/` drafts are fine — the first sweep
  stage's own Stage-0 recovery check adopts or clears them; just mention it.

## 1. Probe + announce the plan

```bash
failed_ct="$(jq '[.tasks[] | select(.status=="failed" or .status=="blocked")] | length' .harness/tracking/TASKS.json)"
ideas_ct="$(grep -c . .harness/tracking/IDEAS.jsonl 2>/dev/null || true)"
```

Honor `$ARGUMENTS` skips (e.g. "skip ideas" drops Stage B; "skip failed" drops Stage A). Then tell
the owner the plan in one or two lines — e.g. *"Post-run: A review-failed (3 failed/blocked) → B
convert-ideas (5 ideas) → C pre-loop-checkin → D fix-scope-gaps if WARNed"* — noting any stage
skipped and why (count is zero, or an `$ARGUMENTS` skip). **Do not ask for approval to start** —
the owner asked for this by invoking the command; the sub-skills ask the real questions.

## 2. The stages, in order

**Stage A — review-failed** (skip if `failed_ct` is 0): Read
`.claude/skills/implementation-harness-review-failed/SKILL.md` and execute it in full — the
per-task investigation agents, its relay + questions, its consolidation, AND its close-out
(`mark-failed.sh` / `mark-reviewed.sh` + rewires). Runs FIRST so its follow-up tasks and rewires
are already in `TASKS.json` when later stages read the backlog.

**Stage B — convert-ideas** (skip if `ideas_ct` is 0): Read
`.claude/skills/implementation-harness-convert-ideas/SKILL.md` and execute it in full — dedup, the
per-idea agents, its relay + questions (always confirming each definition of done), its
consolidation pass.

**Stage C — pre-loop-checkin** (always): Read
`.claude/skills/implementation-harness-pre-loop-checkin/SKILL.md` and execute it in full. It is
strictly read-only; it vets everything stages A/B just wrote plus the rest of the backlog, and ends
in a GO / NO-GO verdict.

**Stage D — fix-scope-gaps** (conditional): pre-loop-checkin itself offers this when its scope
check WARNs — keep that behavior: offer it via `AskUserQuestion`, and if the owner says yes, Read
`.claude/skills/implementation-harness-fix-scope-gaps/SKILL.md` and execute it, then **re-run Stage
C's scope check** (not the whole check-in) to confirm the WARNs cleared and restate the verdict.

Between stages, post exactly one short status line — what the stage changed, in plain counts
(e.g. *"Stage A done: 2 follow-ups authored (T091, T092), T388 closed + dependents rewired."*) —
then continue immediately.

## 3. Finish (and the hard line)

End with a compact wrap-up: per-stage one-liners + the final **GO / NO-GO**.

- On **GO**: remind the owner to start the run **themselves, from a real terminal** —
  `.harness/scripts/supervise.sh`. **NEVER run `supervise.sh` or `loop.sh` yourself, and never
  suggest a way around their `$CLAUDECODE` refusal** — starting the loop is a human-only action,
  by design, with no exception for this skill.
- On **NO-GO**: list the blockers and the right tool for each (a manual edit, another sweep,
  `/implementation-harness-loop-recover`), so the owner's next action is obvious.
- If a stage was aborted midway (owner cancel, error): say plainly which stages completed and
  which didn't, and that re-running `/implementation-harness-post-run` is safe — completed sweeps
  find nothing left to do, and an interrupted sweep's drafts are adopted by its own recovery check.
