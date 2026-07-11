# Q02: Extract the shared relay protocol (convert-ideas §4 ≙ review-failed Stage 3)

**Type**: skill-quality / consolidation · **Priority**: P1 · **Effort**: M
**Affected files**: `templates/skills/implementation-harness-convert-ideas/SKILL.md` §4, `implementation-harness-review-failed/SKILL.md` Stage 3, NEW shared reference (recommended: `templates/docs/relay-protocol.md`), `implementation-harness-loop-prepare/SKILL.md` (pointer), create/upgrade plumbing for the new doc, MIGRATIONS
**Release**: MINOR bump · MIGRATIONS entry (new mechanism doc + two skill edits) · checksums

## Problem

~60 lines of relay machinery are near-verbatim twins in the two sweep skills: the Markdown-
Artifact spec (favicon rules, H1 + italic intro, "On this page" anchors, the ✅ Done-when line,
redeploy-to-the-same-path rule), the fold-back rules (how answers get folded into pending drafts),
and the Stage-0 recovery pre-flight. They have ALREADY drifted once (the 4-question cap + self-
contained-question rules landed only in convert-ideas — see Q01). Every future relay improvement
must currently land twice, and loop-prepare v2 (F14) would make a third copy.

## Proposed fix

1. Create `templates/docs/relay-protocol.md` — the single normative text: artifact format,
   question batching (≤4, sequential, self-contained restatements, DoD-confirmation mandate),
   fold-back semantics, recovery pre-flight, the pending-files schema shared by both skills
   (including `origin` once Q05 lands, and `facetMisfits` once F05 lands — coordinate).
2. Each sweep skill's relay section shrinks to: its skill-SPECIFIC deltas (what goes in ITS
   artifact sections; its question sources) + "follow `.harness/docs/relay-protocol.md` for the
   relay mechanics". Keep the deltas short — anything generic belongs in the shared doc.
3. Plumb the new doc: it ships under `docs/` (mechanism class, upgrade content-diffs it);
   remember the plugin CLAUDE.md rule — a new plugin-owned prose file needs its `custom/` overlay
   stub + include pointer in the same change.
4. Land Q01 first or fold it in (the shared doc is written WITH the cap rules).

## Acceptance criteria

- The two skills' relay sections no longer duplicate mechanics; a diff of their relay text shows
  only skill-specific content.
- The shared doc reads standalone (an agent given only it + a pending dir can run a correct
  relay).
- custom/ overlay stub + pointer exist for the new doc; create validation includes it; upgrade
  table row added.
- Both skills' flows re-read end-to-end for coherence after the cut (no dangling "as above"
  references).
