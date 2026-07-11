# D03: Sunset the worklog-grep fallback in `task_blocked`

**Type**: design-drift / latent bug · **Priority**: P2 · **Effort**: S
**Affected files**: `templates/scripts/loop.sh` + `loop.in-place.sh` (`task_blocked`), `templates/dashboard/lib.js` if it mirrors the rule, `postflight*.sh` if they replicate it
**Release**: MINOR bump · MIGRATIONS entry (mechanism, both variants; note the behavior change) · checksums

## Problem

`task_blocked` falls back to a case-insensitive grep of the task's WHOLE worklog for
`failed:blocked|needs-human` when the status field isn't "blocked". This predates first-class
`status:"blocked"` (set by `block_task`). The fallback can permanently de-select a healthy pending
task whose worklog merely QUOTES the protocol — a builder note like "this does not need-human
input" or a pasted copy of the result protocol matches the regex. The task then silently never
builds, with no signal anywhere.

## Proposed fix

Remove the grep fallback so `task_blocked` = `status == "blocked"` only. Migration concern: tasks
blocked BEFORE first-class status existed have the worklog marker but not the status. Handle in
the ledger entry as a one-time manual-attention item with a detection one-liner the upgrade skill
can run, e.g.:

```bash
for f in .harness/worklog/T*.md; do id="$(basename "$f" .md)"; \
  grep -qiE 'failed:blocked' "$f" && jq -e --arg id "$id" '.tasks[]|select(.id==$id)|.status=="pending"' .harness/tracking/TASKS.json >/dev/null \
  && echo "legacy-blocked candidate: $id"; done
```

— the owner flips those to `status:"blocked"` (or lets them build again, which may be the RIGHT
outcome). Mirror the removal anywhere the rule is replicated (lib.js computeBacklog, postflight).

## Acceptance criteria

- A pending task whose worklog contains "needs-human" in prose IS selected by the loop.
- A task with `status:"blocked"` is still skipped everywhere (loop, dashboard, postflight agree).
- `select-task.test.sh` gains the quoting-worklog case; `lib.test.js` mirrors it if lib.js changes.
- MIGRATIONS entry carries the legacy-detection snippet under manual attention.
