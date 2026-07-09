---
name: implementation-harness-loop-recover
description: >-
  Use to recover the autonomous build loop after it was MANUALLY interrupted (Ctrl-C / killed) and
  may have left inconsistent state behind — phrases like "the loop got interrupted", "clean up after
  the loop", "recover the harness", "/loop-recover". Diagnoses AND fixes orphaned tasks, stale locks,
  a dirty tree / leftover loop worktree, revert-cycle damage, and ledger noise, then leaves the loop
  restartable. This MUTATES committed state (TASKS.json status, outcomes.jsonl) and pushes to main —
  it does the correcting the stopped loop can't. Requires the harness scaffolded.
argument-hint: "[optional: a task id to focus on, e.g. T042 — omit for a full sweep]"
allowed-tools: Read, Edit, Bash, Glob
---

# Recover the loop after a manual interrupt

You are recovering the autonomous build loop (`.harness/scripts/loop.sh`, run via
`.harness/scripts/supervise.sh`) after it was **manually interrupted** (Ctrl-C). A clean interrupt is
rare to get exactly right — the loop can be killed mid-flow and leave inconsistent state. Your job:
**evaluate the loop's health, find every problem the interrupt caused, fix them properly, and leave the
loop ready to restart.** Focus target: `$ARGUMENTS` (a task id scopes the orphan checks to it but still
run the global health checks; empty = full sweep). Read this whole file, then execute in order.

**Key mental model:** `cold_reset` (`git reset --hard` + `git clean -fd`) discards **tracked** changes
but **gitignored files survive**. That's why audit logs / the failure buffer persist across attempts
while an uncommitted `status=done` change can silently vanish — the root of most interrupt damage.

## ⚠️ Guardrails (do not violate)

- **The loop MUST be stopped before you touch anything.** If a `loop.sh` / `supervise.sh` process is
  still alive, STOP and tell the user — its `cold_reset` would wipe your work and its pushes would race
  yours.
- **Never mark a task `done` unless you have VERIFIED it is genuinely complete** — code merged to
  `origin/main`, CI green on that commit, the project's Definition of Done passes on current `main`, and
  any audit file PASSed. If work isn't on main, CI is red/missing, or an audit FAILED, it is not an
  orphan — it's genuinely incomplete. STOP and surface it; never paper over it.
- **Never fabricate ledger data.** An outcome row must reflect what actually happened; record
  `verification: "audited"` ONLY if a real loop `<id>.audit.md` exists with a PASS. A review you did by
  hand is `ci-only`.
- **Git hygiene:** never `git add -A` / `git add .`, never a blanket `git clean`; stage explicit paths.
  Never stage secrets (`.env*`, `data/`, keys, `credentials.json`, anything the pre-push guard blocks).
- **Do not rewrite pushed `main` history** (harmless revert/build-summary churn commits included) unless
  the user explicitly asks.
- **Do not kill the project's own long-lived processes.** If the project runs a dev server, daemon, or
  deployed preview that coordinates with the loop via the shared repo lock, that's the *product*, not a
  loop artifact — leave it running. The loop's own artifacts are only its worktree/branch, its lock, and
  its `worklog/` scratch.

## 1. Confirm graceful shutdown

```bash
ps aux | grep -iE "loop\.sh|supervise\.sh|claude -p" | grep -v grep || echo "✓ no loop process"
# lock path = <git-common-dir>/<basename(repo)>-loop.lock
GC="$(git rev-parse --git-common-dir)"; case "$GC" in /*) ;; *) GC="$(pwd)/$GC";; esac
LOCK="$GC/$(basename "$(git rev-parse --show-toplevel)")-loop.lock"
ls -la "$LOCK" 2>/dev/null && cat "$LOCK/pid" 2>/dev/null || echo "✓ no lock"
```
- A live `loop.sh`/`supervise.sh` process → **STOP** (loop still running).
- Lock dir exists: if its `pid` is a **dead** PID → stale, remove it (`rm -f "$LOCK/pid"; rmdir "$LOCK"`).
  If the PID is **alive** → a loop is genuinely running; STOP.

## 2. Working tree, git state, and any leftover loop worktree

```bash
git fetch origin --quiet
git status -sb | head -1                       # ahead/behind
git status --porcelain                         # dirty?
git rev-list --count origin/main..HEAD         # unpushed
git worktree list                              # worktree variant: a leftover loop worktree?
git branch --list 't[0-9]*'; git branch -r --list 'origin/t[0-9]*'   # stray task branches
```
- **In-place variant — a dirty primary tree** is throwaway in-flight build leftover (the loop builds
  COLD, discarding prior work each attempt). Discard it **surgically — never a blanket clean**:
  `git restore <the tracked files the attempt touched>` and `git clean -fd <the specific untracked
  task dir>`. Confirm `git status --porcelain` is then empty (the in-place startup guard refuses a dirty tree).
- **Worktree variant — a leftover loop worktree** (a sibling dir from `git worktree list` that the loop
  adds/removes per task) → remove it: `git worktree remove --force <path>`. Prune stray `tNNN` task
  branches the interrupt left behind, local and remote (`git branch -D tNNN`; `git push origin --delete tNNN`).
- **Unpushed commits**: inspect each (`git log origin/main..HEAD`). Often a stray worklog / `Revert …`
  commit — harmless; it rides along with your recovery push.

## 3. Transient scratch / logs

```bash
ls -la .harness/worklog/.result .harness/worklog/.claude-out .harness/worklog/.failures.buf 2>/dev/null
```
- `.result` / `.claude-out` — transient per-run scratch; `rm -f` them.
- **`.failures.buf`** — per-attempt failures **buffered but not yet flushed** to `ledgers/failures.jsonl`
  (flush happens only at a terminal `mark_done`/`block_task`). Inspect (`cat`/`jq -c . …`). If the rows
  are **bogus** — e.g. a `ci-red`/`ci-indeterminate` from a revert-cycle on a task that was actually
  done — **discard** (`rm -f`); do NOT flush bogus failures into the committed ledger. If they describe a
  genuine failure, that's real signal — leave them / handle with the task.
- `worklog/<id>.audit.md` — gitignored audit records; **keep** them (they're the evidence behind any
  `verification: "audited"` you record).

## 4. Detect & fix orphaned tasks  ← the main event

**The interrupt-orphan pattern:** a task is `status: pending` but its work is **already on `origin/main`
and CI-green** — the interrupt hit between the code push and `mark_done`, or `mark_done` wrote
`status=done` + the outcome row locally but never pushed, and a later `cold_reset` reverted those
*tracked* changes (while the gitignored `<id>.audit.md` survived — the tell-tale signature).

**The revert-cycle variant:** a pending-but-already-merged task is re-selected; the cold rebuild finds
the work present so it produces only a `[skip ci]`-tagged commit; CI never creates a run for `[skip ci]`,
so the loop reverts + retries forever. Symptom: alternating `<id>: … [skip ci]` / `Revert …` commits and
a `ci-red`/`ci-indeterminate` ladder climb on a task still `pending`. (Newer loops short-circuit
`[skip ci]` builds, but an interrupt from an older run can still leave this state.)

**Detect** (per pending task, or the focus task):
```bash
jq -r '.tasks[]|select(.status=="pending")|.id' .harness/tracking/TASKS.json
git log --oneline -25 | grep -iE "T<id>"                 # code commit? mark-done commit?
gh run list --workflow "$(grep -m1 CI_WORKFLOW .harness/config/harness.env | cut -d= -f2 | tr -d '\"{} :')" \
  --limit 30 --json headSha,status,conclusion --jq '.[]|select(.headSha=="<full-sha>")|"\(.status)/\(.conclusion)"'
grep -c '"id":"T<id>"' .harness/ledgers/outcomes.jsonl   # outcome row present?
ls .harness/worklog/T<id>.audit.md 2>/dev/null           # was it audited?
```
A task is an **orphan to fix** when: its code is on `origin/main` + CI green, but `status=pending` with
no outcome row and no `mark-done` commit.

**Verify it's genuinely done before marking it done — run the project's Definition of Done on current `main`:**
```bash
# the project's local DoD (if configured) — the same gate the loop runs before the audit:
[ -n "$(grep -m1 '^: \"\${LOCAL_DOD' .harness/config/harness.env)" ] && ( set -a; . .harness/config/harness.env; set +a; eval "$LOCAL_DOD" )
# plus: the format/lint/test/build commands from .harness/docs/HARNESS.md §5, and confirm the task's
# OWN test actually ran; plus CI green on the code commit; plus, if <id>.audit.md exists, its verdict PASSes.
```
**If any of these fail / the code isn't on main / CI is red / the audit FAILED → STOP and report. Do
not mark it done.**

**Fix each verified orphan** (mirror what `mark_done` would have written — the loop is the normal writer;
here you're standing in for it while it's stopped):
```bash
# a) status -> done (atomic, validated)
jq '(.tasks[]|select(.id=="T<id>")|.status)="done"' .harness/tracking/TASKS.json > .harness/tracking/TASKS.json.tmp \
  && jq -e '.tasks|length' .harness/tracking/TASKS.json.tmp >/dev/null && mv .harness/tracking/TASKS.json.tmp .harness/tracking/TASKS.json

# b) ONE accurate outcome row — match the EXACT shape of existing rows in ledgers/outcomes.jsonl
#    (and the loop's outcome_row() in scripts/loop.sh). Append one JSON object, then re-validate:
#    jq -e . .harness/ledgers/outcomes.jsonl >/dev/null   # must stay one valid object per line
```
Outcome-row rules:
- `facets` copied from the task in TASKS.json; `scopeSize` = its `.scope|length`.
- start/final model+effort — the authoritative record of what actually ran — and `succeededRung`/
  `topRung` (diagnostic-only position labels, not read by `policy.jq`): use what **actually happened**
  if recoverable (a loop console line, or the audit file). With no escalation evidence, default to the
  **cold-start tier** (`MODEL`/`EFFORT` from `harness.env`, rung 0). A rung's effort may be `null` for
  a model with no effort parameter (e.g. Haiku) — write real JSON `null`, not the string `"null"` or
  `""`, so it matches the ladder. **Never fabricate escalations, and never record soft-fails caused by
  a harness/framework bug** (e.g. a scope-matcher glitch) — excluding them keeps the difficulty
  calibration honest.
- `verification`: `"audited"` ONLY if a real `<id>.audit.md` exists with a PASS; else `"ci-only"`.
- The task's `worklog/<id>.md` is usually already in the code commit — confirm it's sane; don't clobber a good one.

## 5. Clean ledger noise

- Remove **stale/wrong** `outcomes.jsonl` rows (e.g. a `blocked` row for a task later re-scoped and
  actually done, or rows whose `(model, effort)` tuple is no longer on the ladder — `effort` may
  legitimately be `null` here, that alone is not a sign of staleness). Keep the file valid
  (`jq -e . .harness/ledgers/outcomes.jsonl`), one JSON object per line.
- Leave the harmless revert / build-summary churn commits in history (see guardrails).

## 6. Final readiness verification

```bash
DRY_RUN=1 .harness/scripts/loop.sh 2>&1 | grep -iE "would build|nothing eligible|REFUS"  # proves the orphan won't be re-selected
gh auth status 2>&1 | grep -i "logged in"                                                  # the loop needs gh to gate CI
grep CI_WORKFLOW .harness/config/harness.env; grep -m1 '^name:' .github/workflows/ci.yml   # names must match
git status --porcelain                                                                     # empty -> in-place startup guard passes
```

## 7. Commit, push, report

- Stage **only** the files you changed (`.harness/tracking/TASKS.json`, `.harness/ledgers/outcomes.jsonl`,
  any `worklog/<id>.md`). One commit whose message explains the interrupt-orphan recovery and what was
  fixed, then `git push`. Report the SHA.
- Finish with a concise **report**: a health line for each area (processes / lock / tree / worktree /
  scratch / ledger / CI / dry-run) and a per-task line for every orphan fixed (or "none found"), plus
  anything **suspicious** you saw but did NOT change (so the owner can look). Never claim a task is done
  that you couldn't fully verify — surface it instead.
