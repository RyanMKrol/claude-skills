# C01: Extract `loop-lib.sh` — the shared ~70% of the two loop variants

**Progress**: Stage 1 (RL family) done — shipped 1.88.0. Stages 2–4 remaining.

**Type**: consolidation · **Priority**: P1 · **Effort**: L (do it in stages, one commit per stage)
**Affected files**: `templates/scripts/loop.sh`, `loop.in-place.sh`, NEW `templates/scripts/loop-lib.sh`, `tests/loop-parity.test.sh` (manifest shrinks as functions move), upgrade skill's file lists, `create`'s chmod/validation, MIGRATIONS
**Release**: MINOR bump per stage · MIGRATIONS entry per stage (new mechanism file first stage) · checksums · `bash -n`

## Problem / evidence

Measured during the evaluation: **22 function bodies are byte-identical** across the two variants
(~70% of each ~1400-line file); `rl_reset_wait` differs only in comments; `run_claude` differs
only in two path variables; the `outcome_row` jq program is duplicated verbatim as inline strings.
Every recent regression (idle-exit 1.65.0, usage-limit miss 1.69.0, the B08 parity gap) lived in
this hand-mirrored region. `scope-lib.sh` already proved the fix pattern — its header records that
inlined copies "drifted/re-broke repeatedly" until extraction.

`tests/loop-parity.test.sh` currently pins the 22 functions byte-identical; extraction is the
structural fix that makes the manifest shrink toward zero.

## Design

A sourced `loop-lib.sh` (exactly like `scope-lib.sh`/`repo-lock.sh`), with a small **variant seam**
of variables/functions each loop defines BEFORE sourcing:

- `WORK_DIR` (where builds happen: `$LOOP_WT` vs `$ROOT`), `WORKLOG_DIR`, `MAIN_BRANCH`,
- a `tj`/`blob` data-access pair (ref-side vs local-file reads),
- `diff_base` (the gate diff range — see D02).

Lib functions read only the seam + their args. The lib gets a `# harness-loop-lib` header; both
variants keep their `# harness-loop-variant:` markers (the upgrade skill keys on them).

## Staged plan (each stage independently shippable; run the full suite between)

1. **Stage 1 — the RL family** (where regression 1.69.0 lived): `RL_*` knob defaults, `rl_detect`,
   `rl_reset_wait` (reconcile the comment-only drift), `rl_banner`, `_hms`, `rl_selftest`, and the
   identical 25-line build-path RL backoff stanza as a function. Plus the new-file plumbing:
   `create` copies + chmods it, `upgrade`'s mechanism table gains a row, MIGRATIONS "new file",
   parity-test manifest drops the moved names (add a lib-presence assertion instead).
2. **Stage 2 — invocation**: `run_claude` (parameterize the two output paths via the seam),
   `prompt()`'s shared blocks if feasible (scope/expectsTest/preamble builders are identical;
   the spec-fetch line differs via `blob` — seam covers it).
3. **Stage 3 — gates**: `audit_gate` + `audit_prompt` (differ only via seam concepts),
   `structural_checks` (differs by git dir + dodlog path), `wait_ci_green` (optional branch arg —
   fixes B08's class permanently), `pick_base` + `outcome_row` (move the jq program to a
   `outcome-row.jq` FILE next to `policy.jq` — ends the verbatim duplication).
4. **Stage 4 — the long tail**: heartbeat family, `bump`, `record_failure`/`flush_failures`
   (reconcile the arg-shape drift: worktree takes `<id> <dest>` with `$1` unused; in-place takes
   none — pick one signature), tier helpers, guard/selftests, `throttled_push`, hooks dispatch.

Composition rule with the bug proposals: any of B01/B04/B07/B10/B12 that lands BEFORE its
function's stage is mirrored by hand as usual; any landing AFTER is fixed once in the lib. If
sequencing freely, do C01 stage 1 + B07 together, stage 3 + B01/B10 together.

## Acceptance criteria (per stage)

- Both variants source the lib; moved functions exist ONLY in the lib (parity test's
  no-reinline guard, copied from scope-match.test.sh's pattern, enforces it).
- Full test suite green, `--*-selftest` flags still work through both variants (they exercise the
  boot path incl. the new source line).
- `bash -n` on all three files; bash 3.2 run of the suite green.
- Upgrade path: a 1.71.x install upgrading past this version receives the new lib file
  (MIGRATIONS "new files" + checksums make it a clean add-candidate).

## Test plan

The existing suites are the net (they run the real scripts end-to-end via selftests + hermetic
repos). Add per-stage: a lib-sourcing smoke (`bash -c '. loop-lib.sh'` with a stub seam errors
loudly if a seam var is missing — make the lib validate its seam at source time with `:?` checks).
