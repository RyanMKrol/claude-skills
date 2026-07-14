#!/usr/bin/env bash
#
# audit-parse.test.sh — regression guard for the audit verdict sentinel (B01), in BOTH loop variants,
# via each loop's --audit-parse-selftest entry point. Spins up throwaway git repos (mktemp -d).
#
# THE BUG (fixed): the verdict was parsed as `grep -oiE '\b(PASS|FAIL)\b' "$out" | head -1` over the
# auditor's ENTIRE reassembled transcript — case-insensitive, first match anywhere. An auditor that
# narrates "I'll run the tests to see if they pass" before concluding FAIL would false-match PASS on
# the prose word. Fix: the auditor's contract requires an exact `VERDICT: PASS` / `VERDICT: FAIL`
# sentinel as the FINAL non-empty line; audit_verdict_extract reads only that line.
#
# PLUGIN-SOURCE test: exercises BOTH loop variants (which only coexist in templates/); runs in the
# plugin's CI, not copied into a consumer .harness/.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../templates/scripts" && pwd)"
FAIL=0
assert() { local desc="$1"; shift; if "$@"; then echo "ok - $desc"; else echo "FAIL - $desc"; FAIL=1; fi; }

setup_repo() {
  local d; d="$(mktemp -d)"
  git init -q "$d"; ( cd "$d" && git config user.email t@t.com && git config user.name t )
  mkdir -p "$d/.harness/scripts" "$d/.harness/tracking"
  cp "$SCRIPT_DIR/repo-lock.sh" "$SCRIPT_DIR/scope-lib.sh" "$SCRIPT_DIR/loop.sh" "$SCRIPT_DIR/loop.in-place.sh" "$d/.harness/scripts/"
  chmod +x "$d/.harness/scripts/"*.sh
  printf '{"tasks":[]}' > "$d/.harness/tracking/TASKS.json"   # the in-place variant's preflight exits before the selftest dispatch without one
  ( cd "$d" && git add -A && git commit -q -m init )
  echo "$d"
}

for V in loop.sh loop.in-place.sh; do
  d="$(setup_repo)"
  ap() { ( cd "$d" && ".harness/scripts/$V" --audit-parse-selftest "$1" 2>/dev/null ); }
  F="$d/transcript.md"

  printf 'I will run the tests to see if they pass.\nLooks broken.\nVERDICT: FAIL\n' > "$F"
  assert "[$V] prose 'pass' before final VERDICT: FAIL → FAIL (not the old false-positive)" \
    test "$(ap "$F")" = FAIL

  printf 'This will probably fail at first glance but actually works.\nVERDICT: PASS\n' > "$F"
  assert "[$V] prose 'fail' before final VERDICT: PASS → PASS" \
    test "$(ap "$F")" = PASS

  printf 'VERDICT: PASS\n' > "$F"
  assert "[$V] sentinel-only transcript → PASS" \
    test "$(ap "$F")" = PASS

  printf 'Some reasoning about the diff, no sentinel at all.\n' > "$F"
  assert "[$V] no sentinel → NONE (treated as audit FAIL by audit_gate, distinct failure kind)" \
    test "$(ap "$F")" = NONE

  printf 'Reasoning here.\nVERDICT: FAIL   \n' > "$F"
  assert "[$V] trailing whitespace after sentinel → still FAIL" \
    test "$(ap "$F")" = FAIL

  printf 'VERDICT: pass\n' > "$F"
  assert "[$V] lowercase sentinel is NOT matched (case-sensitive contract) → NONE" \
    test "$(ap "$F")" = NONE

  rm -rf "$d"
done

[ "$FAIL" = 0 ] && echo "ALL PASS" || { echo "SOME FAILED"; exit 1; }
