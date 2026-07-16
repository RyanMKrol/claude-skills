# Proposals — the implementation-harness improvement queue

One file per improvement, produced by the full plugin evaluation on 2026-07-11 (five parallel
review agents: loop scripts, skills/feature gaps, test coverage, dashboard, skill-composition
research) plus the owner's own requests. Each file is a self-sufficient spec: an implementing
agent should be able to work from the file alone, without the original conversation.

## Ground rules for the implementing agent (read before ANY proposal)

1. **Read first**: the repo-root `CLAUDE.md`, `plugins/implementation-harness/CLAUDE.md`,
   `plugins/implementation-harness/PRINCIPLES.md` (the constitution — check your change against
   it), and skim `plugins/implementation-harness/DESIGN.md` for rationale. If a proposal seems to
   contradict a principle, stop and surface that to the owner before proceeding.
2. **One proposal = one focused commit** (or a small series). Don't bundle proposals.
3. **The release discipline is non-negotiable** (enforced by CI): any plugin change bumps
   `plugin.json` `version` in the same commit; any `templates/` change adds a
   `MIGRATIONS.md` entry; every bump reruns `gen-checksums.sh --append` as the literal last step;
   `bash -n` every edited script (target bash 3.2 — no bash-4 builtins, no `mapfile`).
4. **Variant parity**: any change to `templates/scripts/loop.sh` logic that lives in shared code
   must be mirrored byte-identically in `loop.in-place.sh` (and vice versa).
   `plugins/implementation-harness/tests/loop-parity.test.sh` enforces the 22 shared functions —
   run it locally. If your change legitimately diverges a manifest function, update the manifest
   in the same commit with a comment.
5. **Run the tests**: `find plugins -name '*.test.sh' -exec bash {} \;` (from a NON-Claude shell
   or with `env -u CLAUDECODE` — several suites exercise the CLAUDECODE refusal) and
   `node plugins/implementation-harness/templates/dashboard/lib.test.js`.
6. Line numbers in these specs are approximate (v1.71.0) — anchor on function names.
7. When a proposal is completed, **delete its file** in the implementing commit — git history and
   the `MIGRATIONS.md` ledger are the durable record, so a finished spec shouldn't linger in the
   queue (and its index row below is removed too).

## Recommended order

**Now (correctness/safety):** *(Q04, Q03, Q01, B09, B01, B02, B03, B05, C03, B07, B04, D01, C01 — done; B06 — abandoned, see its file)*
**Next (high value):** F01 *(T01 — done: `tests/loop-e2e.test.sh`, the fake-claude/fake-gh e2e harness; scenarios: happy-path, idle-reconcile, failed:blocked, soft-fail escalation, scope-creep, garbage — both variants. CI/rate-limit/persist-or-shout scenarios grow with B08/B10/B12.)*
**Then:** the rest of B/D, F02/F03, Q02 (before F14), remaining F/T by taste. *(N01, the big skill-name rename, landed in 1.94.0.)*

## Index

| ID | Title | Type | Priority | Effort |
|----|-------|------|----------|--------|
| B06 | Lock granularity — owner CLIs starve for the whole run | bug | P1 | M |
| B08 | CI-indeterminate re-check parity (in-place) | bug | P2 | S |
| B10 | Bound the CI watch (`gh run watch`) | bug | P2 | S |
| B12 | Loop status pushes must rebase-and-retry | bug | P2 | S |
| B14 | Dashboard hardening batch (escaping, EADDRINUSE, readBody, spec path) | bug | P2 | S |
| B15 | Dashboard performance (tail reads, async spawns, parse-error banner) | bug | P2 | M |
| D02 | Use three-dot diffs for the gates | design-drift | P2 | S |
| D03 | Sunset the worklog-grep blocked fallback | design-drift | P2 | S |
| D04 | Pass prompts/diffs via stdin, not argv | design-drift | P2 | S |
| D05 | Generalize `tier_strength` beyond opus | design-drift | P2 | S |
| C02 | Dedupe the postflight pair | consolidation | P3 | M |
| F01 | Cost/usage ledger from the stream-json | feature | P1 | M |
| F02 | Stop-file graceful shutdown | feature | P1 | S |
| F03 | `prioritize.sh` — supported backlog reordering | feature | P2 | S |
| F04 | Harness-health report (read-only aggregation) | feature | P2 | M |
| F05 | Wire facet-misfits from convert-ideas/review-failed | feature | P2 | S |
| F06 | Notification starter pack for hooks | feature | P2 | S |
| F07 | Redo-done-task front-end (manual-fail authoring) | feature | P2 | M |
| F08 | Fleet status across harness repos | feature | P3 | M |
| F09 | Dashboard: escalation/cost view | feature | P2 | M |
| F10 | Dashboard: per-task attempt timeline | feature | P3 | S |
| F11 | Dashboard: stranded-dependents list | feature | P3 | S |
| F12 | Dashboard: extract the inline client app | feature | P2 | M |
| F13 | Auditor observations → ideas inbox | feature | P3 | M |
| F14 | loop-prepare v2: merged agent wave, one relay, one consolidation | feature | P3 | M |
| Q02 | Shared relay-protocol reference (dedupe ~60 lines ×2) | skill-quality | P1 | M |
| Q05 | Origin marker on shared scratch drafts | skill-quality | P2 | S |
| Q06 | customize: batch the want-it triage | skill-quality | P3 | S |
| T02 | `--struct-selftest` for structural_checks | testing | P2 | M |
| T03 | reconcile_overlays test (both variants) | testing | P2 | S |
| T04 | rl_reset_wait parse-matrix test | testing | P2 | S |
| T05 | Mutation-CLI tests (consolidate-ideas, mark-failed) | testing | P3 | S |
| T06 | Skill non-ASCII lint + dashboard server smoke | testing | P3 | S |
