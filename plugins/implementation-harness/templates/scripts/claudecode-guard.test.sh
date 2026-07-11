#!/usr/bin/env bash
#
# claudecode-guard.test.sh — pins the "only a human starts the loop" safety invariant (plugin
# CLAUDE.md, do-not-erode): supervise.sh and every loop variant present MUST hard-refuse (exit 1,
# ABORT wording, before doing ANYTHING) when $CLAUDECODE is set — i.e. when invoked from inside any
# Claude Code Bash subprocess. No override may exist. Also asserts the refusal fires even on the
# selftest entry points (the guard must run before arg parsing).
# Works in the plugin source tree (both variants present) AND in an install (one variant, as
# loop.sh): it tests whichever of the three scripts exist next to it. Run standalone:
#   .harness/scripts/claudecode-guard.test.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAIL=0

assert() { local desc="$1"; shift; if "$@"; then echo "ok - $desc"; else echo "FAIL - $desc"; FAIL=1; fi; }

# refuses <script> [args…] — true iff the script exits 1 AND prints the ABORT refusal.
refuses() {
  local s="$1"; shift
  local out rc=0
  out="$(CLAUDECODE=1 bash "$s" "$@" 2>&1)" || rc=$?
  [ "$rc" = 1 ] && printf '%s' "$out" | grep -q 'ABORT: this script must be run manually'
}

found=0
for s in loop.sh loop.in-place.sh supervise.sh; do
  p="$SCRIPT_DIR/$s"
  [ -f "$p" ] || continue
  found=$((found + 1))
  assert "$s refuses under CLAUDECODE=1 (exit 1 + ABORT wording)" refuses "$p"
done
assert "at least loop.sh + supervise.sh were present to test" [ "$found" -ge 2 ]

# The guard must precede argument handling: even a harmless selftest flag is refused.
assert "loop.sh --guard-selftest is refused too (guard precedes arg parsing)" \
  refuses "$SCRIPT_DIR/loop.sh" --guard-selftest

# And no environment knob may bypass it (spot-check the obvious shapes an override would take).
for s in loop.sh supervise.sh; do
  p="$SCRIPT_DIR/$s"; [ -f "$p" ] || continue
  if grep -qiE 'CLAUDECODE_(OVERRIDE|SKIP|ALLOW)|ALLOW_CLAUDECODE|SKIP_CLAUDECODE' "$p"; then
    echo "FAIL - $s contains what looks like a CLAUDECODE guard bypass knob"; FAIL=1
  else
    echo "ok - $s has no CLAUDECODE bypass knob"
  fi
done

if [ "$FAIL" = 0 ]; then echo "PASS: claudecode-guard"; else echo "FAIL: claudecode-guard"; exit 1; fi
