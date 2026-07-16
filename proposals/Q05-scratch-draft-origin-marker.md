# Q05: Origin marker on shared scratch drafts

**Type**: skill-quality · **Priority**: P2 · **Effort**: S
**Affected files**: `templates/skills/harness-convert-ideas/SKILL.md` (draft schema + Stage-0 recovery), `harness-review-failed/SKILL.md` (same), `templates/scripts/consolidate-ideas.mjs` (tolerate/ignore the field), later `relay-protocol.md` if Q02 lands
**Release**: PATCH/MINOR bump · MIGRATIONS entry · checksums

## Problem

convert-ideas and review-failed deliberately share the `.harness/.pending-tasks/` /
`.pending-questions/` scratch dirs, and each skill's Stage-0 recovery check adopts whatever
leftovers it finds — including the OTHER skill's. Drafts carry no marker saying which skill
produced them, and the question schemas differ (`ideaIds` array vs `ideaText` string).
Consolidation is safe either way, but: **a convert-ideas run that adopts review-failed's
interrupted leftovers will consolidate them and then skip review-failed's mandatory close-out**
(mark-failed/mark-reviewed + dependent rewires) — the original blocked task sits in the Human
Tasks bucket forever, the exact bug that close-out stage was built to fix.

## Proposed fix

1. Both skills write `"origin": "convert-ideas"` / `"origin": "review-failed"` into every draft
   file they produce.
2. Each skill's Stage-0 recovery check inspects origins of leftovers: own-origin (or unmarked
   legacy) → adopt as today; other-origin → tell the owner which skill they belong to and
   recommend running THAT skill to finish properly (adopting them is still allowed on explicit
   confirmation, with the warning that the other skill's close-out won't run).
3. `consolidate-ideas.mjs`: ignore the field (verify it doesn't choke on unknown keys — it
   shouldn't; add it to the documented draft schema).
4. If/when F14 (merged wave) lands, origin markers are its mechanism for running the right
   close-outs — note the forward dependency.

## Acceptance criteria

- Drafts from each skill carry the correct origin; consolidation output unchanged.
- Recovery text in both skills describes the cross-origin behavior; a simulated leftover from the
  other skill (fixture file) routes to the recommendation, not silent adoption.
- consolidate-rewire.test.sh green with origin fields present in fixtures.
