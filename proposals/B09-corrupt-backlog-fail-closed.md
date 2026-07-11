# B09: A corrupt/unreadable backlog must fail CLOSED (exit 3), not report "backlog complete"

**Type**: bug · **Priority**: P2 · **Effort**: S
**Affected files**: `templates/scripts/loop.sh` (startup pre-flight), `loop.in-place.sh` (extend its existing check)
**Release**: PATCH bump · MIGRATIONS entry (mechanism, both variants) · checksums · parity (new shared pre-flight block — consider adding to the parity manifest)

## Problem

The worktree variant's `tj()` swallows all errors (`… 2>/dev/null || true` on the `blob` git-show
and jq). If `TASKS.json` on `origin/main` is corrupt JSON, `origin/main` doesn't resolve (fresh
clone, wrong `TASKS_REF`), or the file is missing from the ref, then `all_tasks` is empty →
`select_task` returns 1 → the loop logs **"no eligible task — backlog complete"**, fires the
`drained` hook, runs `sync_primary_checkout`, and exits 0. `supervise.sh` treats exit 0 as success
and idles the full ~5h window. A corrupted backlog thus looks exactly like a finished one.

The in-place variant guards file EXISTENCE (`[ -f "$BACKLOG" ] || exit 3`) but not JSON validity.

## Proposed fix

A one-time startup pre-flight in BOTH variants, after config sourcing, before the main loop:

```bash
# worktree: validate the ref-side backlog is present and parseable
blob tracking/TASKS.json | jq empty 2>/dev/null \
  || { log "FATAL: $TASKS_REF:.harness/tracking/TASKS.json is missing or not valid JSON — refusing to run (a corrupt backlog must never read as 'backlog complete')."; exit 3; }
# in-place: extend the existing existence check with:  jq empty "$BACKLOG" || { …; exit 3; }
```

Exit 3 is correct: supervise already hard-stops on 3 with the "a prerequisite needs a human"
banner (see `supervise.sh`), which is exactly the semantics.

## Acceptance criteria

- Corrupt TASKS.json (either variant's source of truth) → loop exits 3 before selecting anything;
  supervise stops loudly; no `drained` hook fires; no sync of the primary checkout.
- Unresolvable `TASKS_REF` (worktree) → same.
- Healthy backlog → zero behavior change (drain path still exits 0).

## Test plan

Extend `templates/scripts/select-task.test.sh`: a fixture whose committed TASKS.json is truncated
garbage → run the loop (NOT dry-run — the pre-flight must fire before DRY_RUN too; decide and
assert the ordering: recommended is pre-flight BEFORE the DRY_RUN block so a dry run also
surfaces corruption) → assert exit 3 + the FATAL wording. Add a supervise composition case if
cheap (stub loop exiting 3 already covered by supervise.test.sh).
