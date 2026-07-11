# T01: Fake-claude / fake-gh end-to-end loop test harness

**Type**: testing (infrastructure — the highest-leverage single investment) · **Priority**: P1 · **Effort**: L
**Affected files**: NEW `templates/scripts/loop-e2e.test.sh` (+ optionally `loop-e2e-lib.sh` for the fixture builders), no production-code changes required (that's the point)
**Release**: PATCH bump · MIGRATIONS entry (new mechanism test files) · checksums · bash 3.2 clean

## Problem

The loop's dispatch state machine, git-mutation/persistence paths, escalation, and rate-limit
ROUTING are pinned today by static greps and hand-copied logic — the exact technique tier that let
the idle-exit (1.65.0) and rate-limit (1.69.0) regressions ship. The missing piece is
infrastructure: a way to run the REAL loop end-to-end without live `claude`/`gh`.

## Design

A fake-bin dir prepended to PATH in a hermetic repo (pattern proven by `mark-done-bulk.test.sh`'s
tmp repos + `supervise.test.sh`'s stubs):

- **fake `claude`**: a bash script that ignores flags, reads a per-invocation instruction from
  `$FAKE_PLAN_DIR/` (one file per expected call, shifted through in order). Per instruction it
  can: write a scripted `.result` (`done|failed:soft|failed:blocked|waiting|idle|garbage`), emit
  canned stream-json to stdout (including a synthetic `result` event — needed by F01/B07 tests),
  create+commit an in-scope (or deliberately out-of-scope) file in the cwd worktree, answer an
  audit prompt with `VERDICT: PASS`/`FAIL` when the prompt contains the auditor marker text.
- **fake `gh`**: reads `$FAKE_GH_SCRIPT` for a sequence of run-status answers (found/not-found,
  in_progress, completed/success, completed/failure, cancelled) keyed by call count.
- **Env recipe**: `env -u CLAUDECODE PATH="$tmp/bin:$PATH" WAIT_SECONDS=0 RL_BUFFER=0
  MAX_ITERS=3 REQUIRE_CI=0|1 SYNC_PRIMARY_ON_DONE=0 CLAUDE_BIN=claude` + a bare remote; audit
  sampling forced off (seed the ledger so pm=0) or on (risk-flagged task) per scenario.

**Scenario matrix (each an independent test function; grow over time):**
1. Happy path (both variants): ready task → build → gates → origin/main has status=done, ONE
   outcome row with correct start/final tier + verification, heartbeat cleared, branch gone.
2. Verdict dispatch: `idle` → reconcile + CONTINUE (the 1.65.0 class, behaviorally); double-idle →
   blocked; `failed:blocked` → status=blocked + blocked row; `failed:soft` ×MAX_ATTEMPTS →
   escalates one rung (assert via failures.jsonl rungs); garbage → backoff + reattempt.
3. Rate-limit routing (the 1.69.0 class): first call emits the limit notice as a result event with
   "resets in 2 seconds" → loop sleeps ~2s (assert wall-clock << 30s), attempt NOT charged, task
   completes on call 2.
4. Persist-or-shout: bare remote with a pre-receive hook rejecting once → status flip lands on
   retry (pairs with B12); rejecting always → the loud error after bounded retries.
5. CI matrix (REQUIRE_CI=1, fake gh): green → integrate; red → failure recorded (worktree) /
   revert lands on main (in-place — the most dangerous untested path); indeterminate →
   re-check then soft-fail (B08).
6. Structural gates in vivo: out-of-scope commit → scope-creep failure recorded, nothing merged.

## Acceptance criteria

- Whole suite runs in <60s, bash 3.2 + 5.x, both variants covered (parameterized like
  select-task.test.sh), no network, no real claude/gh anywhere on PATH during the run.
- Each scenario asserts on origin/main state + ledgers (not on log text where avoidable).
- CI runs it via the existing *.test.sh finder; add to the macos job implicitly.

## Notes

Build incrementally: land scenario 1 alone first (it forces the fixture builders into shape),
then grow. Several other proposals' test plans hang off this (B04, B08, B10, B11, B12, D01, D04,
F01, F02, F13) — revisit their "Test plan" sections as scenarios here once the harness exists.
