#!/usr/bin/env bash
#
# pre-push.test.sh — the in-place push-block hook (scripts/pre-push) refuses a push made from a
# harness AGENT session (HARNESS_AGENT set) and allows every other push. This is the mechanical
# enforcement of P5 ("the loop owns pushes") for the in-place variant — see loop.in-place.sh
# run_claude, which points ONLY the agent subprocess's git at this hook via GIT_CONFIG_* env.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/pre-push"
FAIL=0
assert() { local d="$1"; shift; if "$@"; then echo "ok - $d"; else echo "FAIL - $d"; FAIL=1; fi; }

# git invokes a pre-push hook as `pre-push <remote> <url>` with ref updates on stdin; this hook decides
# from the environment alone, so feed empty stdin and dummy args.
blocked() { ! HARNESS_AGENT=1 "$HOOK" origin https://example.invalid </dev/null >/dev/null 2>&1; }
allowed() { env -u HARNESS_AGENT "$HOOK" origin https://example.invalid </dev/null >/dev/null 2>&1; }
allowed_when_empty() { HARNESS_AGENT= "$HOOK" origin https://example.invalid </dev/null >/dev/null 2>&1; }

assert "hook exists and is executable (git ignores a non-executable hook = no enforcement)" test -x "$HOOK"
assert "HARNESS_AGENT=1 → push REFUSED (non-zero exit)" blocked
assert "HARNESS_AGENT unset → push ALLOWED (exit 0) — the loop's own & human pushes" allowed
assert "HARNESS_AGENT set-but-empty → push ALLOWED (guard uses -n, not just defined)" allowed_when_empty

[ "$FAIL" = 0 ] && { echo "PASS: pre-push"; exit 0; } || { echo "FAIL: pre-push"; exit 1; }
