# B05: mark-*/rewire/consolidate publish whatever branch/staging state the checkout is in

**Type**: bug · **Priority**: P1 · **Effort**: S (fix) — see C03 for the structural version
**Affected files**: `templates/scripts/mark-done.sh`, `mark-failed.sh`, `mark-reviewed.sh`, `rewire-dependents.sh`, `consolidate-ideas.sh`, `repo-lock.sh` (`push_with_retry`)
**Release**: PATCH/MINOR bump · MIGRATIONS entry (mechanism) · checksums · `bash -n`

## Problem

Two independent footguns, no branch or staging check anywhere:

1. **Feature branch published to main.** The scripts commit on the CURRENT branch and call
   `push_with_retry` (`repo-lock.sh`), which rebases the current branch onto `origin/main` and
   pushes `HEAD:main`. The worktree design explicitly sanctions the primary checkout sitting on
   another branch. So: owner mid-feature on `feature-x` with 5 WIP commits runs
   `mark-done.sh T017` → **all 5 WIP commits land on origin/main**.
2. **Unrelated staged changes swept into the commit.** `git commit -m "$msg"` commits everything
   staged, not just the overlay file — the `diff --cached --quiet -- "$OVERLAY"` check only gates
   the no-op case. Staged unrelated work gets committed as `mark-done: T017 [skip ci]` and pushed.

The dashboard's mutation endpoints shell out to these scripts, so the dashboard buttons inherit
both footguns.

## Proposed fix

In each script, before committing:

```bash
MAIN_BRANCH="${MAIN_BRANCH:-main}"
cur="$(git -C "$ROOT" symbolic-ref --short -q HEAD || echo DETACHED)"
[ "$cur" = "$MAIN_BRANCH" ] || { echo "ERROR: checkout is on '$cur', not $MAIN_BRANCH — refusing to publish. Switch to $MAIN_BRANCH (or stash your work) and re-run." >&2; exit 1; }
```

And commit with an explicit pathspec so only the intended files are included:

```bash
git commit -q --no-gpg-sign -m "$msg" -- "$OVERLAY"            # mark-*.sh
# rewire-dependents.sh / consolidate-ideas.sh: pathspec their own outputs
# (TASKS.json, tasks/*.md, tracking/IDEAS.jsonl, tracking/reviews.json as applicable)
```

Note `git commit -- <path>` commits the working-tree state of those paths regardless of staging —
which is exactly what these scripts want (they edit the file then commit it). Verify each script's
add/commit sequence still behaves under both "nothing else staged" and "unrelated file staged".

`rewire-dependents.sh` additionally hand-rolls its own commit+push (no rebase retry) — switch it to
`push_with_retry` while there.

## Acceptance criteria

- Running any of the five scripts from a non-main branch → hard refusal, nothing committed/pushed.
- With an unrelated file staged: the script's commit contains ONLY its own files; the unrelated
  file remains staged afterward.
- Existing behavior on a clean main checkout unchanged (mark-done-bulk.test.sh stays green).

## Test plan

Extend `templates/scripts/mark-done-bulk.test.sh` (or a new `mark-safety.test.sh` reusing its
`setup_repo`): (a) checkout a feature branch → assert refusal + no push; (b) stage a dummy file →
mark-done → assert the overlay commit excludes it and the dummy is still staged; (c) same two
cases for consolidate-ideas.sh and rewire-dependents.sh.

## Notes

C03 (shared `overlay-edit.sh`) is the structural home for this fix — if implementing both, do C03
and put the guards there once. If doing B05 alone, apply the guard to each script individually.
