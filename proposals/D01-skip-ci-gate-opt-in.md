# D01: `[skip ci]` must be a task-level opt-in, not builder-controlled

**Type**: design-drift · **Priority**: P1 · **Effort**: S
**Affected files**: `templates/scripts/loop.sh` + `loop.in-place.sh` (the `[skip ci]` short-circuit in the done path), task schema docs (`templates/docs/HARNESS.md` §8.1), authoring skills if a field is added
**Release**: MINOR bump · MIGRATIONS entry (mechanism + possibly schema) · checksums · parity

## Problem

Both done paths skip the CI gate entirely when the build commit's MESSAGE contains `[skip ci]`.
Legitimate for operational/docs-only tasks — but the **builder writes the commit message**, so a
cheap tier that (even innocently, copying house style from git log) tags `[skip ci]` removes the
model-agnostic gate; only the sampled audit remains. This violates PRINCIPLES.md P2: "a gate that
can be satisfied by text the builder itself writes" is exactly the listed drift smell.

## Proposed fix

Make the bypass authorization come from the PLANNER, not the builder:

1. Add an optional task field (e.g. `"ciSkipOk": true`, or reuse an existing tag convention) that
   the strong planner sets at authoring time for genuinely CI-irrelevant tasks.
2. The loop honors `[skip ci]` in the commit message ONLY when the task carries the field.
   A `[skip ci]` message WITHOUT the field = a **structural failure** (`record_failure` kind e.g.
   `unauthorized-skip-ci`) — a failed attempt, same as scope creep — so the calibration learns.
3. Document the field in HARNESS.md §8.1 and teach `add-to-backlog`/`convert-ideas` to set it only
   for docs/config-only work (one line each in their authoring guidance).
4. Note: GitHub itself skips CI on such commits, so on an unauthorized `[skip ci]` there is no run
   for `wait_ci_green` to find — the structural check must fire BEFORE the CI wait, at commit
   inspection time.

## Acceptance criteria

- Builder writes `[skip ci]` on a task without the field → attempt fails with a distinct failure
  kind; nothing merges.
- Task WITH the field + `[skip ci]` → today's behavior (gate skipped, audit still sampled).
- Task with the field but no `[skip ci]` in the message → normal CI gating (the field permits, it
  doesn't force).
- Schema documented; MIGRATIONS notes the additive schema field (config/schema class → precise
  ACTION line: no change to existing tasks needed, field is optional).

## Test plan

T02 (`--struct-selftest`) or T01 scenarios: the three cases above. Before those land, a focused
check inside the existing structural-checks region is testable via T02's harness — consider
landing D01 together with T02.
