# B04: The worktree variant destroys its own audit trail

**Type**: bug · **Priority**: P1 · **Effort**: S
**Affected files**: `templates/scripts/loop.sh` (`audit_gate` output path; `run_claude` claude-out path)
**Release**: PATCH/MINOR bump · MIGRATIONS entry (mechanism, worktree variant; verify in-place is already correct) · checksums

## Problem

In the worktree variant, `audit_gate` writes the auditor's output to
`out="$LOOP_WT/.harness/worklog/$id.audit.md"` — **inside the throwaway task worktree** — and the
path is gitignored (`*.audit.md` in `ensure-gitignore.sh`'s managed block). On audit FAIL the done
path immediately runs `cleanup_task` → `remove_wt` → the reasons file is deleted seconds after the
log says "reasons → $out". On PASS, `record_outcome` also tears the worktree down. Net: DESIGN.md
§4.3's "audit reasons go to `worklog/<id>.audit.md`" **does not exist on worktree installs** — a
human reviewing why audits failed has nothing.

Same problem for the build/audit stream transcripts (`.claude-out.build`/`.claude-out.audit` and
their `.jsonl` raw siblings, written under `$LOOP_WT`): the dashboard's live-tail reads them until
the worktree is destroyed per attempt. The in-place variant does not have this problem (it writes
into the primary checkout's `worklog/`), and `FAILURES_BUF` already solves it for failure rows —
its comment says "survives worktree rebuilds" because it deliberately lives in the PRIMARY
checkout's `$HARNESS_DIR/worklog/`.

## Proposed fix

Follow the `FAILURES_BUF` precedent: point the audit output file and the claude-out files at the
**primary checkout's** `$HARNESS_DIR/worklog/` instead of `$LOOP_WT/.harness/worklog/`:

- `audit_gate`: `out="$HARNESS_DIR/worklog/$id.audit.md"`.
- `run_claude` (or its call sites): claude-out paths under `$HARNESS_DIR/worklog/`.

Both are already gitignored by the managed block (`*.audit.md`, `.claude-out*`), so nothing new is
committed; they just survive worktree teardown. Check the dashboard's `claudeOutTailFor` path
derivation still matches (it reads the primary checkout — this fix makes worktree installs' live
tail MORE reliable, not less).

## Acceptance criteria

- After a worktree-variant audit FAIL, `<primary>/.harness/worklog/<id>.audit.md` exists and
  contains the auditor output; the worktree is gone.
- The dashboard live-tail shows build output for worktree installs across attempt teardowns.
- No new files become committed (gitignore managed block already covers the names).
- PRINCIPLES P4 preserved: the audit file must still never be fed into a retry prompt.

## Test plan

Hard to e2e without T01 (fake-claude harness). Minimum: a static test asserting the audit `out=`
path in `loop.sh` anchors on `$HARNESS_DIR` not `$LOOP_WT` (grep-shape, loud comment), upgraded to
behavioral once T01 lands (fake auditor writes output → assert the file survives cleanup_task).
