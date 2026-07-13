#!/usr/bin/env bash
#
# supervise.test.sh — hermetic test of supervise.sh's exit-code contract with the loop, via its
# LOOP= stub override (no real loop, no git, no network). The contract this pins:
#   exit 3  → a HUMAN-fixable prerequisite (dirty tree / missing jq / no TASKS.json): supervise
#             STOPS the whole run loudly with exit 3 — never retries on a timer;
#   exit 5  → the loop gave up rate-limited: relaunch after RETRY_INTERVAL (short), not the window;
#   other≠0 → crash/git error: relaunch after SUPERVISE_ERROR_BACKOFF (short);
#   exit 0  → normal cadence; MAX_CYCLES bounds the run.
# A mislabeled exit either buries a human-fixable error in retry noise or idles a healthy run for
# hours — this is load-bearing unattended-operation logic. Run standalone:
#   plugins/implementation-harness/tests/supervise.test.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../templates/scripts" && pwd)"
SUPERVISE="$SCRIPT_DIR/supervise.sh"
FAIL=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

assert() { local desc="$1"; shift; if "$@"; then echo "ok - $desc"; else echo "FAIL - $desc"; FAIL=1; fi; }

mkstub() {  # mkstub <name> <body…>  → echoes the stub path
  local p="$TMP/$1"; shift
  printf '#!/usr/bin/env bash\n%s\n' "$*" >"$p"; chmod +x "$p"; echo "$p"
}

# 1. exit 3 → hard stop, exit 3, the REFUSED banner, and exactly ONE launch (no retry).
stub="$(mkstub loop3 'echo launched >>"'"$TMP"'/count3"; exit 3')"
out="$(env -u CLAUDECODE LOOP="$stub" bash "$SUPERVISE" 1 5 2>&1)"; rc=$?
assert "exit 3 → supervise exits 3" [ "$rc" = 3 ]
assert "exit 3 → REFUSED banner shown" bash -c "printf '%s' \"\$1\" | grep -q 'REFUSED to run (exit 3)'" _ "$out"
assert "exit 3 → stopped after exactly one launch" [ "$(wc -l <"$TMP/count3" | tr -d ' ')" = 1 ]

# 2. exit 5 → the rate-limited short-retry branch fires (RETRY_INTERVAL, not the full interval),
#    and the run continues to the next cycle (2 launches under MAX_CYCLES=2).
stub="$(mkstub loop5 'echo launched >>"'"$TMP"'/count5"; exit 5')"
out="$(env -u CLAUDECODE LOOP="$stub" RETRY_INTERVAL=1 bash "$SUPERVISE" 60 2 2>&1)"; rc=$?
assert "exit 5 → supervise itself exits 0 at max cycles" [ "$rc" = 0 ]
assert "exit 5 → rate-limited short-retry branch chosen" bash -c "printf '%s' \"\$1\" | grep -q 'gave up rate-limited — short retry (1s)'" _ "$out"
assert "exit 5 → relaunched (2 cycles ran)" [ "$(wc -l <"$TMP/count5" | tr -d ' ')" = 2 ]

# 3. generic non-zero (exit 1) → the error-backoff branch (SUPERVISE_ERROR_BACKOFF), still retries.
stub="$(mkstub loop1 'echo launched >>"'"$TMP"'/count1"; exit 1')"
out="$(env -u CLAUDECODE LOOP="$stub" SUPERVISE_ERROR_BACKOFF=1 bash "$SUPERVISE" 60 2 2>&1)"; rc=$?
assert "exit 1 → supervise exits 0 at max cycles" [ "$rc" = 0 ]
assert "exit 1 → error-backoff branch chosen (not rate-limit, not full interval)" \
  bash -c "printf '%s' \"\$1\" | grep -q 'non-rate-limit) — short retry (1s)'" _ "$out"
assert "exit 1 → relaunched (2 cycles ran)" [ "$(wc -l <"$TMP/count1" | tr -d ' ')" = 2 ]

# 4. exit 0 + MAX_CYCLES=1 → clean stop after one cycle.
stub="$(mkstub loop0 'exit 0')"
out="$(env -u CLAUDECODE LOOP="$stub" bash "$SUPERVISE" 1 1 2>&1)"; rc=$?
assert "exit 0 → clean stop at max cycles" [ "$rc" = 0 ]
assert "exit 0 → max-cycles message shown" bash -c "printf '%s' \"\$1\" | grep -q 'reached max cycles (1)'" _ "$out"

# 5. The CLAUDECODE hard-refusal (also covered by claudecode-guard.test.sh; kept here so this
#    contract file is self-contained about who may even start supervise).
out="$(CLAUDECODE=1 bash "$SUPERVISE" 1 1 2>&1)"; rc=$?
assert "CLAUDECODE=1 → supervise refuses with exit 1" [ "$rc" = 1 ]
assert "CLAUDECODE=1 → ABORT wording" bash -c "printf '%s' \"\$1\" | grep -q 'ABORT: this script must be run manually'" _ "$out"

if [ "$FAIL" = 0 ]; then echo "PASS: supervise contract"; else echo "FAIL: supervise contract"; exit 1; fi
