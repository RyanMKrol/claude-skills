#!/usr/bin/env bash
#
# loop-actionlint.test.sh — regression guard for the GitHub-Actions-workflow-safety change (1.79.0):
#   Part 1: structural_checks runs actionlint on a changed .github/workflows/*.yml (best-effort local gate).
#   Part 2: wait_ci_green matches the CI run by FILE PATH when GitHub can't resolve its name (malformed
#           workflow) — treating it as RED instead of sitting out the full timeout as "indeterminate".
#   Part 3: the idle-reconcile path re-checks real CI status before marking done (idle-but-ci-red → block).
#
# WHY STATIC: these live inside run-time paths (structural_checks / wait_ci_green / the main-loop idle
# handler) that need a live `gh` + network to exercise end-to-end. So we assert the fixed SHAPE in source,
# in BOTH variants (parity), plus the standalone downloader's own shape (which IS exercised live elsewhere).
#
# PLUGIN-SOURCE test: runs in the plugin's CI, not copied into a consumer .harness/.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../templates/scripts" && pwd)"
TPL="$(cd "$SCRIPT_DIR/.." && pwd)"   # templates/
FAIL=0
assert() { local desc="$1"; shift; if "$@"; then echo "ok - $desc"; else echo "FAIL - $desc"; FAIL=1; fi; }
has()  { grep -qF -- "$1" "$2"; }
hasE() { grep -qE -- "$1" "$2"; }

# ---- ensure-actionlint.sh: pinned, checksum-verified, idempotent, bash-clean ----
al="$SCRIPT_DIR/ensure-actionlint.sh"
assert "[ensure-actionlint] bash syntax OK"             bash -n "$al"
assert "[ensure-actionlint] pins ACTIONLINT_VERSION"    has 'ACTIONLINT_VERSION:-'   "$al"
assert "[ensure-actionlint] verifies sha256 checksums"  has '_checksums.txt'         "$al"
assert "[ensure-actionlint] installs into .harness/.bin" has '.harness/.bin'         "$al"

# ---- Part 1 (structural) + Part 2's wait_ci_green half: as of C01 stage 3, structural_checks and
# wait_ci_green live ONCE in loop-lib.sh (sourced by both variants) rather than duplicated per variant.
LIB="$SCRIPT_DIR/loop-lib.sh"
assert "[loop-lib.sh] structural gate fires on .github/workflows diffs"   hasE '\^\\.github/workflows/.\+\\.\(yml\|yaml\)' "$LIB"
assert "[loop-lib.sh] runs ensure-actionlint.sh (best-effort fetch)"      has 'ensure-actionlint.sh' "$LIB"
assert "[loop-lib.sh] a bad workflow is STRUCT_FAIL_KIND=workflow-lint"   has 'STRUCT_FAIL_KIND="workflow-lint"' "$LIB"
assert "[loop-lib.sh] fetch failure WARNs + SKIPs (does not block)"      has 'actionlint unavailable' "$LIB"
assert "[loop-lib.sh] honors the LINT_WORKFLOW_FILES knob"               has 'LINT_WORKFLOW_FILES:-1' "$LIB"
assert "[loop-lib.sh] wait_ci_green treats an unresolved workflow name as RED" has 'CI_NAME_UNRESOLVED' "$LIB"

# ---- Both loop variants: Part 2's ci_find_run half (still local — unchanged) + Part 3 (idle) ----
for V in loop.sh loop.in-place.sh; do
  f="$SCRIPT_DIR/$V"
  # Part 2 — ci_find_run's run-matching path-fallback + red-on-unresolved-name (still local per variant,
  # pinned byte-identical by loop-parity.test.sh — only wait_ci_green itself moved to the lib).
  assert "[$V] CI-run finder falls back to the workflow file PATH" has 'startswith(' "$f"
  assert "[$V] an unresolved workflow name is set by ci_find_run"  has 'CI_NAME_UNRESOLVED' "$f"
  # Part 3 — idle-reconcile re-checks real CI before marking done.
  assert "[$V] idle path re-checks CI via ci_status_now"           has 'ci_status_now' "$f"
  assert "[$V] idle-but-CI-red blocks instead of marking done"     has 'idle-but-ci-red' "$f"
done

# ---- config + gitignore + backstop workflow ----
assert "[harness.env] LINT_WORKFLOW_FILES knob present"  has 'LINT_WORKFLOW_FILES:=1'  "$TPL/config/harness.env"
assert "[harness.env] ACTIONLINT_VERSION knob present"   has 'ACTIONLINT_VERSION:=1.7' "$TPL/config/harness.env"
assert "[gitignore] managed block ignores .harness/.bin/" has '.harness/.bin/'         "$SCRIPT_DIR/ensure-gitignore.sh"
assert "[backstop] lint-workflows.yml exists"            test -f "$TPL/.github/workflows/lint-workflows.yml"
assert "[backstop] it runs ensure-actionlint.sh independently" has 'ensure-actionlint.sh' "$TPL/.github/workflows/lint-workflows.yml"

[ "$FAIL" = 0 ] && echo "PASS: loop-actionlint" || { echo "FAIL: loop-actionlint"; exit 1; }
