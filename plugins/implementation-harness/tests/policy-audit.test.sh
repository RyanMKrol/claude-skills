#!/usr/bin/env bash
#
# policy-audit.test.sh — pins policy.jq's AUDIT mode (the dual-mode second branch: auditCount >= 0
# returns a per-mille audit probability). policy.test.sh covers only the tier branch (it always
# passes auditCount -1), so the entire audit-sampling decay curve was previously untested. This is
# DESIGN.md §12's own drift smoke — 100% until auditStartN (3) audit-confirmed successes, linear
# taper to the auditFloor (100pm) at auditFloorN (8), never below the floor — plus the risk clamp
# (any risk flag ⇒ mandatory 1000pm, bypassing the decay entirely). The invocation mirrors
# audit_gate's exact arg shape in loop.sh (the tier-branch args are inert dummies here).
# Run standalone: plugins/implementation-harness/tests/policy-audit.test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../templates/scripts" && pwd)"
POLICY_JQ="$SCRIPT_DIR/policy.jq"
FAIL=0

assert() { local desc="$1"; shift; if "$@"; then echo "ok - $desc"; else echo "FAIL - $desc"; FAIL=1; fi; }

run_audit_pm() {  # run_audit_pm <auditCount> <riskJson> → per-mille
  jq -n -f "$POLICY_JQ" --argjson auditCount "$1" --argjson risk "$2" \
     --argjson auditStartN 3 --argjson auditFloorN 8 --argjson auditFloorPM 100 \
     --argjson rows '[]' --argjson tiers '[]' --arg layer '' --arg wt '' \
     --argjson floor 0 --argjson minN 0 --argjson coldIdx 0 --argjson manualFail '{}' \
     --argjson explorePM 0 --argjson exploreCooldownN 0
}

assert "auditCount=0 → 1000pm (new cell: audit everything)"         [ "$(run_audit_pm 0 '[]')" = "1000" ]
assert "auditCount=3 → 1000pm (decay starts only past auditStartN)" [ "$(run_audit_pm 3 '[]')" = "1000" ]
assert "auditCount=5 → 640pm (linear taper midpoint)"               [ "$(run_audit_pm 5 '[]')" = "640" ]
assert "auditCount=8 → 100pm (floor reached at auditFloorN)"        [ "$(run_audit_pm 8 '[]')" = "100" ]
assert "auditCount=20 → 100pm (floor is permanent, never zero)"     [ "$(run_audit_pm 20 '[]')" = "100" ]
assert "risk-flagged task → mandatory 1000pm regardless of decay"   [ "$(run_audit_pm 20 '["touches-schema"]')" = "1000" ]

if [ "$FAIL" = 0 ]; then echo "PASS: policy audit mode"; else echo "FAIL: policy audit mode"; exit 1; fi
