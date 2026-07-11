# N02: Rename post-run → loop-prepare — ✅ IMPLEMENTED (v1.71.0, commit f4b6513)

**Type**: new-idea (owner request, 2026-07-11) · **Status**: done — recorded here so the proposals
set covers every owner suggestion; nothing left to implement.

## The owner's reasoning (kept for the record)

The orchestrator skill shipped in 1.70.0 as `implementation-harness-post-run`. The owner rejected
the "post-run" framing: while it does triage what the previous run left behind, he thinks of it as
**the standard pattern for setting up a run** — the thing you do before starting the loop, not
cleanup after it. Candidate names offered: "loop setup and run", "loop setup", "loop prepare".

## What was done

- Chosen name: `implementation-harness-loop-prepare` — "prepare the loop" parallels the existing
  `loop-recover` (verb-after-loop family), and the skill's endpoint IS run-readiness (GO/NO-GO).
- Skill dir + frontmatter renamed; description/title/prose reframed from "follow-up after a run"
  to "get the NEXT unattended run ready"; behavior unchanged (review-failed → convert-ideas →
  pre-loop-checkin → fix-scope-gaps, ends at GO/NO-GO, never starts the loop).
- Every registration point updated: create (scaffold loop, validation, handoff), upgrade (skills
  table, validation loop, adoption note), templates/README.md, harness-CLAUDE.md, plugin
  README.md, plugin.json, marketplace.json.
- MIGRATIONS 1.70.1 → 1.71.0 entry records the rename (installs that scaffolded at exactly
  1.70.0–1.70.1 get the dir swapped on upgrade); checksums regenerated.

## Follow-up hooks

- If N01 (prefix retirement) lands, this skill becomes `loop-prepare` (option a) or
  `harness-loop-prepare` (option b) — it's just one of the nine in that migration.
- F14 (merged-wave v2) upgrades this skill's internals; the name is compatible with that framing.
