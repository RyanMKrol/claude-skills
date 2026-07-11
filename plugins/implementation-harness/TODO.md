# implementation-harness — deferred design TODO

Items we identified but deliberately deferred, captured so they're not lost. (Dev-only file — not
under `templates/`, so it isn't installed into scaffolded projects and needs no version bump.)

## From the 2026-07-11 full evaluation (multi-agent review; owner to prioritize)

> **⚠️ Now specced per-item in the repo-root [`/proposals/`](../../proposals/README.md) folder —
> that folder is the working queue** (one self-sufficient implementation spec per finding, with
> ground rules, priorities, and a recommended order). The summaries below are kept as the compact
> overview; when a proposal lands, its file moves to `proposals/done/`.

The evaluation shipped: PRINCIPLES.md (drift guard), the post-run orchestrator skill (1.70.0),
four regression test suites + the loop-parity gate + a bash-3.2 CI job (1.70.1). Everything below
was FOUND but deliberately not fixed in that pass — each loop fix needs both variants + a
migration entry, so they deserve their own focused commits.

### Bugs (verified against the code; ranked)

1. **Audit verdict = first "pass"/"fail" ANYWHERE in the auditor output** (`loop.sh` audit_gate
   verdict grep, both variants): `grep -oiE '\b(PASS|FAIL)\b' | head -1` over the auditor's whole
   agentic transcript — prose like "I'll run the tests to see if they pass" before a FAIL verdict
   flips the gate to PASS. Defeats the false-success defense the audit exists for. Fix: require an
   uppercase sentinel (e.g. `VERDICT: PASS`) on the last non-empty line.
2. **Signal traps don't exit** (`trap 'release_lock' EXIT INT TERM`, both variants + mark-*.sh):
   a trap that doesn't `exit` resumes the script — Ctrl-C/kill releases the lock but the loop KEEPS
   RUNNING (verified empirically), voiding the concurrency guard. Fix: `trap 'release_lock; exit
   130' INT`, `…exit 143' TERM`, plain release on EXIT.
3. **`FORCE_TASK` skips terminal-status checks and is never cleared**: a forced run rebuilds the
   task forever (idle → idle → block_task flips a DONE task to blocked), and can build
   failed/gated tasks. Fix: apply the terminal skips on the forced path + clear/exit after one
   terminal outcome.
4. **Worktree variant destroys the audit trail**: `worklog/<id>.audit.md` (and `.claude-out.*`) are
   written INSIDE the task worktree and deleted by cleanup seconds later — DESIGN.md's "audit
   reasons go to a separate log" is a no-op on worktree installs. Write them to the primary
   checkout's worklog (like FAILURES_BUF already does).
5. **mark-*.sh / rewire-dependents / consolidate-ideas publish whatever the checkout has**: no
   current-branch check (a feature-branch checkout gets rebased+pushed to main by
   `push_with_retry`), and `git commit` without a pathspec sweeps unrelated STAGED changes into the
   overlay commit. Fix: refuse when HEAD ≠ main + commit with `-- <overlay>` pathspec.
6. **Owner CLIs starve for the whole run**: the loop holds the repo lock per-RUN (hours), the mark
   scripts wait with no `REPO_LOCK_MAX_WAIT` default → dashboard buttons/CLIs hang forever;
   "overlay applied on the next iteration" is unreachable mid-run. Rethink lock granularity (loop
   holds it only around its own git-mutating sections) or default a max wait.
7. **Usage-limit detection can false-positive on repo content; the AUDIT-path RL loop is uncapped**:
   `RL_HARD_RE` greps the raw stream incl. tool_results (a repo whose files contain the limit
   wording — e.g. the harness's own installed rl test fixtures — trips it every attempt), and the
   audit-path retry loop has no `RL_MAX_WAIT` counter → permanently wedged. Cap it + scope the raw
   grep to result/stderr events.
8. **Parity drift: CI-indeterminate single re-check exists only in the worktree variant** —
   in-place charges a soft failure (calibration pollution) for a merely-slow CI run. Mirror it.
9. **Corrupt/unreadable TASKS.json fails OPEN**: worktree `tj()` swallows errors → "backlog
   complete", exit 0, supervise idles 5h. Add a one-time `jq empty` pre-flight, exit 3.
10. **`gh run watch` has no timeout** (CI_TIMEOUT only bounds finding the run id) — a stuck CI run
    hangs the loop forever.
11. **Worktree idle path leaks the `tNNN` branch** (idle handler never runs cleanup_task) —
    postflight shows a phantom "in flight" forever.
12. **The loop's own status-flip pushes don't rebase-retry** (plain push ×2, 1s apart) while
    `push_with_retry` sits sourced+unused — this is the residual idle-stall precondition.
13. Minor: `consolidate-ideas.mjs` uses `new URL(import.meta.url).pathname` → breaks on paths with
    spaces (use `fileURLToPath`); client-side dashboard `esc()` doesn't escape quotes → attribute
    breakage when failure detail contains `"` (server-side escHtml has the same latent gap);
    dashboard has no `server.listen` error handler (EADDRINUSE = raw crash); `readBody` >1MB
    destroys the socket without settling the promise; `task.spec` path is read without a
    stays-under-ROOT check.

### Fragility / design-drift (not bugs yet)

- **Builder-controlled `[skip ci]`** commit message bypasses the CI gate — gate it on a task
  opt-in, not the builder's own text (P2 smell).
- **Two-dot diffs** (`origin/main..HEAD`) everywhere — safe only while nothing fetches mid-window;
  three-dot is strictly safer.
- **`task_blocked` worklog-grep fallback** can permanently de-select a pending task whose worklog
  merely QUOTES "needs-human"; sunset now that status:"blocked" is first-class.
- **Prompt/diff passed as argv** can exceed ARG_MAX on lockfile-heavy diffs → misclassified crash.
- **`tier_strength` hardcodes opus>all** — a future non-opus strong model silently inverts the
  auditor floor.
- **DASHBOARD scale**: whole-file re-read + full JSONL re-parse of the live transcript every 5s
  poll; sync execFileSync jq/git spawns block the single-threaded server.

### Consolidation (structural fix for the regression pattern)

~70% of the two loop variants is byte-identical (22 functions now CI-pinned by
`tests/loop-parity.test.sh`). Next step: extract a sourced `loop-lib.sh` (the scope-lib.sh
pattern) — start with the RL family, `run_claude`, `audit_gate`+`audit_prompt`,
`structural_checks`, `outcome_row`'s jq (duplicated verbatim), `wait_ci_green`. Also: postflight
pair (~85% identical), a shared `overlay-edit.sh` for the three mark-* scripts (also the home for
bug 5's fix). Each extraction shrinks the hand-mirroring surface the parity test currently guards.

### Feature ideas (fit the design; owner to pick)

- **Cost/usage ledger** (highest value): `run_claude` already saves the raw stream whose `result`
  event carries usage + `total_cost_usd` — and discards it. Loop appends tokens/cost per attempt
  (failures.jsonl) + per task (outcomes.jsonl); dashboard gains per-cell avg cost + spend strip.
  The whole thesis is cost and nothing measures it.
- **Stop-file graceful shutdown** (`.harness/worklog/.stop` checked between iterations/attempts) +
  a `prioritize.sh TNNN` (lock-guarded array reorder). Makes most loop-recover runs unnecessary.
- **Harness-health report** (read-only skill or dashboard tab): aggregate failures.jsonl +
  outcomes.jsonl — failure kinds per cell, escalation trends, audit-FAIL rate, manual-fail
  recurrence. failures.jsonl is currently write-only.
- **Wire facet-misfits from convert-ideas/review-failed** into the poor-fit gate (today only
  add-to-backlog feeds it; convert-ideas' `factMisfits` [sic — typo] output is consumed by NOTHING,
  so the vocabulary can never evolve via the owner's main authoring path).
- **Notification starter pack** for hooks (osascript/terminal-notifier/ntfy one-liners as
  commented presets in the .example stubs + a "just notify me" customize preset).
- **Redo-done-task front-end** (the manual-fail overlay has no authoring skill; cloning the
  original spec/scope as the follow-up draft).
- **Fleet status** (global skill over a small project registry: lock/backlog/blockers/version per
  repo — the two hand-forked consumer installs would have surfaced via this).
- **Dashboard**: escalation/cost view (succeededRung/attempts/totalSoftFails are recorded, only
  finalModel is shown), per-task attempt timeline from failures.jsonl, stranded-dependents list
  (pairs with rewire-dependents.sh), extract renderPage()'s ~870-line inline client JS to a
  static app.js so it's testable (the force-scroll class).

### Skill-quality fixes (small, mostly doc-level)

- review-failed Stage 3 still says "ONE AskUserQuestion batching every question" — contradicts the
  4-question hard cap convert-ideas §4 already documents; back-port the ≤4 batching + the
  self-contained-question rule.
- ~60 lines of relay/Artifact machinery duplicated between convert-ideas §4 and review-failed
  Stage 3 (already drifted once) → extract a shared relay-protocol reference; post-run makes a
  third consumer.
- add-to-backlog SKILL.md uses paths WITHOUT the `.harness/` prefix throughout its jq commands
  (`tracking/TASKS.json` etc.) — wrong from the repo root, where every other skill anchors.
- Stale §-references: the build prompt in BOTH loop variants + HARNESS.md §8.1 + add-to-backlog
  cite the DoD as HARNESS.md **§6**; it's **§5** (§6 is single-flight). Every cold builder is
  pointed at the wrong section.
- review-failed step-3 JSON shapes still teach a phantom `ideaBullets` field (consolidator reads
  only `ideaIds`).
- harness.env's `MAX_ATTEMPTS` comment describes pre-ladder behavior ("before the loop stops and
  asks a human" — it's per-RUNG before escalating).
- pre-loop-checkin's final report says "checks a–e" but defines a–f, and flattens the two (e)
  WARN classes it carefully distinguishes earlier.
- convert-ideas/review-failed shared scratch drafts carry no origin marker — a convert-ideas
  recovery of review-failed leftovers skips review-failed's mandatory close-out (add
  `"origin": "<skill>"` to drafts).
- customize's 6× one-at-a-time interview could batch the want-it? triage into one call (its own
  sibling skills mandate the batched pattern).

Nothing else currently deferred — see "Done" below for the most recent resolved items.

---

## Done (kept for reference)

- **Scope structural gate** — *implemented in v0.9.4.* `structural_checks()` (both loop variants +
  local-jobs) now fails any task whose diff touches a file outside its declared `scope`, with the
  worklog + test files allowlisted and docs requiring explicit declaration.
- **`risk` facet wired — v1.5.0.** `policy.jq` now takes a `$risk` arg (the task's `facets.risk`
  array): AUDIT mode returns mandatory 1000 per-mille whenever `risk` is non-empty (bypassing the
  per-cell decay curve entirely); TIER mode clamps the eligible starting index to `>= 1` (never the
  cheapest rung) for a risky task, even if historical calibration would otherwise let index 0 clear
  the floor. Both loop variants' `pick_base`/`audit_gate` now extract and pass the current task's
  risk flags. See `docs/designs/difficulty-autotune.md`.
- **Worktree done-protocol reconciled with the scope gate — v1.6.0.** Moved `TASKS.json`
  status-ownership out of the worktree builder and into `loop.sh` itself: `record_outcome()` now
  flips `status:"done"` in the SAME detached-worktree commit as the outcome-ledger row, after
  structural checks + the audit gate pass — mirroring the in-place variant's `mark_done()`. The
  builder's prompt no longer mentions `TASKS.json`/README/LIMITATIONS bookkeeping, and
  `structural_checks`' 3-file stopgap allowlist is gone — it's strict (worklog + tests only) like
  the in-place variant now.
