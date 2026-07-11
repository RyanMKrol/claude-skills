# D05: Generalize `tier_strength` beyond "opus beats everything"

**Type**: design-drift · **Priority**: P2 · **Effort**: S
**Affected files**: `templates/scripts/loop.sh` + `loop.in-place.sh` (`tier_strength` — parity-manifest function, keep byte-identical), possibly `templates/config/facets.json` (ladder as the strength source)
**Release**: MINOR bump · MIGRATIONS entry (mechanism, both variants) · checksums · parity manifest stays satisfied

## Problem

`tier_strength <model> <effort>` hardcodes a total order in which any "opus" model outranks
everything else. It backs the auditor-tier rule "auditor = max(opus-medium, builder)"
(DESIGN.md §4.5). If the owner ladders a future non-opus strong model (e.g. a Fable-class tier)
above opus, `tier_strength` ranks it BELOW opus/low — silently inverting the "auditor never weaker
than the work" invariant: a strong-model build would be audited by a weaker auditor.

## Proposed fix

Derive strength from the ladder itself, which is already the single ordered source of truth
(`facets.json .tiers.ladder`, cheapest → priciest): a tier's strength = its ladder index; tiers
not on the ladder (e.g. the auditor floor `claude-opus-4-8/medium` if it isn't a rung) get
strength = position they'd occupy, which needs a fallback rule — simplest robust design:

1. If (model, effort) matches a ladder rung → strength = rung index (+ a large base).
2. Else fall back to the current heuristic (model family rank × effort rank) so behavior today is
   unchanged for today's ladders.

Keep the function byte-identical across variants (it's in the parity manifest). Document in
`facets.json`'s comments (or docs/designs/difficulty-autotune.md) that ladder ORDER is the
strength authority.

## Acceptance criteria

- With today's shipped ladder: `tier_strength` ordering unchanged (regression: opus/high >
  opus/medium > sonnet/high > … exactly as now — enumerate in a test).
- With a hypothetical ladder ending in a non-opus model above opus rungs: that model outranks
  opus, and `audit_gate` raises the auditor to it when it built the work.
- `update-ladder` skill needs no change (verify its prose doesn't restate the old rule).

## Test plan

A small `tier-strength.test.sh` driving the function via a new selftest flag (pattern:
`--rl-selftest`) with both ladder shapes; assert full orderings.
