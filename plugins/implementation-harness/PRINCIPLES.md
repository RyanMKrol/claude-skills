# PRINCIPLES.md — the harness constitution (drift guard)

This is the **checkable statement of what the implementation harness is for and the principles it
must not drift from.** It is dev-level (not installed into scaffolds). DESIGN.md holds the full
rationale and trade-offs; this file is the short list you audit a change against. **If a proposed
change contradicts a principle here, stop and surface that to the owner explicitly** — the change
may still be right, but it must be a deliberate, informed decision, never an accident.

How to use it: when reviewing a diff (yours or a PR), read the principle titles and ask "does this
change weaken any of these?" For mechanical invariant checks, DESIGN.md §12 lists the code-level
assertions and where they live.

## Mission

Build a `TASKS.json` backlog **unattended**, one fully-verified task at a time, **as cheaply as
correctness allows**. The two goals pull against each other; every principle below exists to resolve
that tension. When in doubt: **a false success is worse than a false failure** — failures
self-correct (the ladder escalates), false successes silently ship wrong work *and* poison the
calibration.

## Principles

**P1 — Cheap-first, escalate on evidence.** Every task starts at the cheapest tier history supports
(cold-start floor when there's no history) and climbs one global ladder only on failure. Difficulty
is owned by the policy + ledger, never configured per task. **Escalation is for difficulty failures
only:** a failure that a stronger model can't fix — notably **scope-creep** (a wrong `scope`
declaration) — exits to `failed:blocked` after one attempt instead of climbing, since escalating
would waste the budget and fake a "hard cell." *Drift smells:* a per-task `model`/`effort` field;
hardcoding a strong model "to be safe"; skipping rungs without ledger evidence; escalating a
non-difficulty failure (scope-creep) up the ladder.

**P2 — The builder's self-judgement never advances a task.** Only objective signals may mark work
done: structural checks (diff non-empty, scope, expectsTest), the local DoD / CI, and the sampled
**independent, ≥-builder-tier** audit. *Drift smells:* trusting the builder's `.result` beyond
routing; letting the builder edit statuses/ledgers; weakening the audit's independence or tier
floor; a gate that can be satisfied by text the builder itself writes (commit messages, worklog).

**P3 — Strong planner, cheap builder; ambiguity dies at planning time.** The planning-stage skills
(convert-ideas, review-failed, add-to-backlog) run with a human present and a strong model — they
MUST bias toward asking (always confirm the definition of done). The unattended loop never
clarifies; a real unknown is `failed:blocked` for a human. *Drift smells:* planning skills gaining
"prefer a reasonable default" language; the loop prompt inviting the builder to interpret intent.

**P4 — Every attempt is cold.** No worklog carryover, no prior-attempt context, no audit feedback to
the builder — each outcome measures "can this tier do this spec, standalone," which is the signal
calibration depends on. Audit reasons go to a separate log the builder never reads. *Drift smells:*
any retry that resumes; feeding failure detail into the next attempt's prompt.

**P5 — The loop is the sole orchestrator and sole state writer.** Models are stateless
subprocesses invoked for one step. The loop owns pushes, CI-watching, `TASKS.json` status flips,
and every ledger row. *Drift smells:* a builder/auditor prompt that pushes, marks done, or appends
to a ledger.

**P6 — The repo is the memory.** All durable state lives in git (statuses, worklogs, ledgers, the
work itself); conversations are disposable. Ledgers are **append-only, forward-only** — never
backfilled or rewritten. *Drift smells:* state in a process, a temp dir, or a rewritten ledger.

**P7 — Sequential, single-flight.** At most one task in motion, so an interruption damages at most
one task. This is the simplicity lever everything else leans on. *Drift smells:* parallel builds;
overlapping loop instances; a second writer to `TASKS.json` while the loop runs.

**P8 — Only a human starts the loop.** `supervise.sh` / both loop variants hard-refuse under
`$CLAUDECODE`, no override. An agent may *prepare* a run (and a skill may end at GO/NO-GO), but the
start is always human hands in a real terminal. *Drift smells:* any bypass flag, env override, or
skill instruction that launches the loop.

**P9 — The two loop variants stay in parity.** Worktree and in-place differ ONLY where the
isolation model genuinely requires it; all other logic must be identical (ideally extracted to a
shared sourced lib, like `scope-lib.sh`). Every recent regression class lived in hand-mirrored
duplicate code. *Drift smells:* a fix landing in one variant; new logic pasted into both instead of
extracted.

**P10 — Changes propagate only through the release discipline.** Version bump in the same commit as
any plugin change; a `MIGRATIONS.md` entry for every `templates/` change; `gen-checksums.sh
--append` on every bump; `bash -n` (target bash 3.2) on every edited script. A skipped step ships
work that silently never reaches consumers. *Drift smells:* "it's a tiny change, no bump needed."

**P11 — Destructive git actions require a verified-safe precondition.** The loop cold-resets and
pushes; therefore it refuses dirty trees, validates `FORCE_TASK` against real task ids, and helper
scripts must never publish anything but their own overlay commit. *Drift smells:* a new
`reset`/`push` path without its guard; widening what a helper commits or which branch it pushes.

## Non-goals (deliberate, do not "fix")

- **No resume-on-interrupt / partial-work recovery** — cold-only is the measurement model (P4);
  atomic task sizing is the remedy for tasks too big for one cold pass.
- **No feedback loop into the builder** — hints would inflate the tier's measured ability (P4).
- **No parallelism** — single-flight is load-bearing (P7).
- **No per-task difficulty knobs** — the policy owns difficulty (P1).
- **No agent-startable loop** — ever (P8).

## Where the enforcement lives

- Code-level invariants + locations: `DESIGN.md` §12.
- Re-assert guards (planning-stage questioning, human-only loop start): `CLAUDE.md` (this dir).
- Release discipline: `CLAUDE.md` (this dir) + repo-root `CLAUDE.md`.
- Tests pinning invariants: `templates/scripts/*.test.sh`, `tests/` (dev-level), CI at
  `.github/workflows/ci.yml` (repo root).
