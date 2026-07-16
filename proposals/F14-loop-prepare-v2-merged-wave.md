# F14: loop-prepare v2 — one merged agent wave, one relay, one consolidation

**Type**: feature · **Priority**: P3 (after Q02) · **Effort**: M
**Affected files**: `templates/skills/harness-loop-prepare/SKILL.md`; depends hard on Q02 (shared relay protocol) landing first
**Release**: MINOR bump · MIGRATIONS entry · checksums

## Problem

loop-prepare v1 (shipped 1.70.0 as post-run, renamed 1.71.0) runs review-failed and convert-ideas
strictly sequentially, each with its OWN relay Artifact + AskUserQuestion rounds + its OWN
`consolidate-ideas.sh` commit. The owner sits through two full question ceremonies and two
consolidation pushes. The machinery was explicitly built for merging: both skills write
heterogeneous drafts to the SAME `.pending-tasks/`/`.pending-questions/` dirs, and
`consolidate-ideas.mjs` already merges drafts with and without `ideaIds` in one pass.

## Design

Replace v1's stages A+B with a combined phase:

1. **One agent wave**: launch review-failed's per-task investigation agents AND convert-ideas'
   per-idea agents concurrently (both skills' Stage-agent specs verbatim — the sub-skill files
   remain the source of truth for the agent prompts; loop-prepare only orchestrates timing).
2. **One merged relay**: a single Artifact with a Reviews section and an Ideas section, and one
   ≤4-per-call AskUserQuestion stream over ALL questions (Q02's shared relay protocol is the spec
   for this — v2 becomes its third consumer; the DoD-confirmation mandate applies to every
   authored task from either source).
3. **One consolidation**: a single locked `consolidate-ideas.sh` run over the merged pending dir
   (Q05's origin markers tell review-failed's close-out which drafts were its own).
4. **review-failed's close-out still runs** (mark-failed/mark-reviewed + rewires) — driven by the
   origin-marked drafts (this is why Q05 is a dependency too).
5. Then pre-loop-checkin / fix-scope-gaps exactly as v1.

## Acceptance criteria

- A repo with 2 failed tasks + 3 ideas: exactly one relay artifact, one question stream, one
  consolidation commit; both failed tasks closed out with follow-ups; ideas converted/removed.
- Interrupted mid-wave → each sub-skill's recovery semantics still hold on re-run (the origin
  markers keep the close-out correct).
- The "never suppress a sub-skill's question" rule survives the merge — merged batching may
  REORDER questions, never drop or answer them.
- Doc parity: v1's sequential description replaced; README/harness-CLAUDE.md wording updated.

## Notes / dependencies

Order: Q02 (shared relay) → Q05 (origin markers) → F14. Do not attempt without those — building
against two divergent relay specs is how the current drift happened.
