# D02: Use three-dot (merge-base) diffs in the gates

**Type**: design-drift / latent bug · **Priority**: P2 · **Effort**: S
**Affected files**: `templates/scripts/loop.sh`, `loop.in-place.sh` — every `git diff origin/main..HEAD` (structural checks, audit diff, and the other gate-side diffs)
**Release**: PATCH bump · MIGRATIONS entry (mechanism, both variants) · checksums

## Problem

The gates diff with two dots (`origin/main..HEAD`) — an ENDPOINT diff. That is only safe while the
local `origin/main` ref cannot move between worktree/branch creation and the gate. True today
(no in-process fetch in that window, and the prompt doesn't tell the builder to fetch) — but
nothing enforces it: a builder that runs `git fetch` (nothing forbids it), or any future fetch
inserted into that window, silently converts unrelated upstream movement into (a) false
scope-creep failures and (b) a polluted audit diff containing other people's changes.

## Proposed fix

Switch the gate-side diffs to three dots (`origin/main...HEAD` = diff from the merge base), which
is invariant to upstream movement and costs nothing. Audit each `git diff` in both variants and
change the ones that mean "what did THIS task change": `structural_checks`' name-only diff, the
audit prompt's diff, the scope-selftest fixtures if they encode the range. Leave any diff that
genuinely means "endpoint delta" (none were found in the evaluation, but re-verify).

## Acceptance criteria

- With `origin/main` advanced by an unrelated commit after branch creation (simulate: fixture repo,
  advance remote, fetch): structural checks still see only the task's own files; the audit diff
  contains only the task's changes.
- All existing scope/structural tests green.

## Test plan

Extend `scope-match.test.sh`'s real-repo corpus or T02's fixtures with the advanced-remote case
above. Cheap and hermetic.
