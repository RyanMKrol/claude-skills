# F11: Dashboard — stranded-dependents list (pairs with rewire-dependents.sh)

**Type**: feature · **Priority**: P3 · **Effort**: S
**Affected files**: `templates/dashboard/lib.js` (reducer + tests), `server.js` (render in the failed/closed sections)
**Release**: MINOR bump · MIGRATIONS entry (mechanism) · checksums

## Problem

When a task is terminally failed/blocked, its transitive dependents are stranded — the exact
condition `rewire-dependents.sh` (1.67.0) exists to fix, and the historical incident class
(T389→T473) that produced it. `lib.js` already computes transitive blockage (`isStuck`), but the
UI only prose-warns that dependents "may be stranded" — it never LISTS which tasks are stranded by
which terminal task, so the owner can't see the blast radius or know the exact rewire command to
run.

## Design

A `strandedBy(tasks)` reducer: for each terminal (failed/blocked, not reviewed-and-resolved) task,
the transitive set of pending dependents reachable only through it. Render under each terminal
task's card: "strands N tasks: T473, T475…" plus the ready-to-paste command the harness already
emits elsewhere (`.harness/scripts/rewire-dependents.sh <old> <new>|--drop|--abandon` — match
pre-loop-checkin's wording exactly so the two surfaces agree). Also a reverse view in the task
expander: "blocked on: T388 (failed)" for any stranded task.

## Acceptance criteria

- A diamond dependency (stranded via two paths, one healthy) is NOT listed as stranded — only
  tasks unreachable without the terminal node count (test this case explicitly).
- Reviewed/closed failed tasks whose dependents were already rewired show zero stranded.
- lib.test.js: chain, diamond, already-rewired fixtures.
