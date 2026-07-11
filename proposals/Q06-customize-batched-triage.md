# Q06: customize — batch the want-it? triage into one call

**Type**: skill-quality · **Priority**: P3 · **Effort**: S
**Affected files**: `plugins/implementation-harness/skills/implementation-harness-customize/SKILL.md` (§2 flow)
**Release**: PATCH bump · checksums (global skill — not under templates/, so NO MIGRATIONS entry needed; version bump still mandatory)

## Problem

customize §2 mandates "batch nothing — one feature at a time": six sequential AskUserQuestion
rounds on every create (and on upgrade's what's-new walk). Meanwhile the plugin's own sibling
skills explicitly champion batched questions (fix-scope-gaps: "mirror /…-upgrade's
batched-question pattern rather than asking one at a time"). Six rounds of yes/no is ceremony
without information.

## Proposed fix

Two-layer flow:

1. **Triage (one batched call)**: a single AskUserQuestion (multiSelect) listing every catalog
   feature in scope with a one-line pitch each — "which of these do you want to set up now?"
   (≤4 options per call — the catalog has ~6 features, so two calls or trim to the headline four
   with an "other features" option; respect the platform cap from Q01/convert-ideas §4).
2. **Drafting (unchanged, per selected feature)**: the existing one-at-a-time drafting interviews
   run ONLY for the selected features — that part of the current design is right (drafting needs
   focus), and this proposal must not erode it.

Guard: the plugin CLAUDE.md's front-load-clarification principle is about SUBSTANTIVE planning
questions, not opt-in triage; this change reduces rounds, not questioning depth — state that in
the commit message to pre-empt the re-assert guard.

## Acceptance criteria

- Fresh create: features presented in ≤2 triage calls; only selected features get drafting
  interviews; a "none for now" path exits gracefully with the pointer to run customize later.
- Upgrade's `--since` scoped walk uses the same triage over only-new features.
- Catalog remains the single source (no feature list duplicated into the triage prose — generate
  the options FROM the catalog section).
