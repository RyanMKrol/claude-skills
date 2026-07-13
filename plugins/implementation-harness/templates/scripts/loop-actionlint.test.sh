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
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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

# ---- Both loop variants: Part 1 (structural), Part 2 (wait_ci_green), Part 3 (idle) ----
for V in loop.sh loop.in-place.sh; do
  f="$SCRIPT_DIR/$V"
  # Part 1 — actionlint in structural_checks, scoped to workflow-file diffs, warn+skip when unavailable.
  assert "[$V] structural gate fires on .github/workflows diffs"   hasE '\^\\.github/workflows/.\+\\.\(yml\|yaml\)' "$f"
  assert "[$V] runs ensure-actionlint.sh (best-effort fetch)"      has 'ensure-actionlint.sh' "$f"
  assert "[$V] a bad workflow is STRUCT_FAIL_KIND=workflow-lint"   has 'STRUCT_FAIL_KIND="workflow-lint"' "$f"
  assert "[$V] fetch failure WARNs + SKIPs (does not block)"       has 'actionlint unavailable' "$f"
  assert "[$V] honors the LINT_WORKFLOW_FILES knob"                has 'LINT_WORKFLOW_FILES:-1' "$f"
  # Part 2 — wait_ci_green run-matching path-fallback + red-on-unresolved-name.
  assert "[$V] CI-run finder falls back to the workflow file PATH" has 'startswith(' "$f"
  assert "[$V] an unresolved workflow name is treated as RED"      has 'CI_NAME_UNRESOLVED' "$f"
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
