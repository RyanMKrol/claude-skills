# F05: Wire facet-misfits from convert-ideas/review-failed into the poor-fit gate

**Type**: feature (fixing a dead data-flow) · **Priority**: P2 · **Effort**: S
**Affected files**: `templates/skills/harness-convert-ideas/SKILL.md` (§3 step 2), `harness-review-failed/SKILL.md` (follow-up authoring step), `templates/scripts/consolidate-ideas.mjs`, `harness-add-to-backlog/SKILL.md` (threshold check reference)
**Release**: MINOR bump · MIGRATIONS entry (mechanism) · checksums

## Problem

The layer-vocabulary self-evolution gate (DESIGN.md §2.4; facets.json `poorFitThreshold`) lives
ONLY in add-to-backlog §1, reading `config/facet-misfits.jsonl`. But the owner's primary authoring
path is capture-idea → convert-ideas — and there the signal is dropped end-to-end:

- convert-ideas §3 tells its agents to record misfits in a `factMisfits` array (note the TYPO —
  "fact" not "facet") in their pending-tasks draft;
- `consolidate-ideas.mjs` reads only `units`/`ideaIds`/`rewire*` — it never reads that field and
  never writes `facet-misfits.jsonl`;
- convert-ideas never runs the threshold check; review-failed doesn't mention misfits at all.

Net: for the capture→convert workflow the vocabulary can never evolve — the "feature sat unused"
failure mode at the data-flow level.

## Proposed fix

1. Fix the field name to `facetMisfits` in convert-ideas' agent instructions (and add the same
   optional field to review-failed's follow-up-authoring JSON shape).
2. `consolidate-ideas.mjs`: read `facetMisfits` from each pending file (accept the `factMisfits`
   typo too, for interrupted-sweep drafts written by the old prose) and append each entry as a row
   to `.harness/config/facet-misfits.jsonl` in the same consolidation commit.
3. convert-ideas' pre-flight: after consolidation, count the misfit ledger; at/over
   `poorFitThreshold`, tell the owner to run add-to-backlog's re-clustering flow (don't duplicate
   the re-clustering logic — point at the single implementation).
4. Keep the misfit row schema identical to what add-to-backlog §1 already writes/reads (open the
   skill and copy the shape exactly — do not invent a second schema).

## Acceptance criteria

- A convert-ideas sweep whose agent reports a misfit → a new row in `config/facet-misfits.jsonl`
  after consolidation, committed with the sweep.
- Threshold reached → the owner is told, with the exact skill to run.
- add-to-backlog's existing gate still reads the same ledger unchanged.
- consolidate-rewire.test.sh green; add a misfit-passthrough case to it (or T05's suite).
