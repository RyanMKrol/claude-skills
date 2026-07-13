#!/usr/bin/env bash
#
# loop-ratelimit.test.sh — regression guard for usage/session-limit detection in BOTH loop variants,
# via each loop's --rl-selftest entry point. Spins up throwaway git repos (mktemp -d).
#
# THE BUG (fixed): run_claude rebuilds the file it greps ($out) from ONLY text_delta stream events
# (since the stream-json switch, 1.34.0). A usage-limit notice ("You've hit your session limit · resets
# 1am (Europe/London)") is NOT a text_delta — the CLI emits it on stderr / as a result event — so it's
# dropped from $out. Detection grepped ONLY $out, so it silently missed the limit and the loop tight-
# looped on the generic 30s crash backoff instead of sleeping until the reset. The notice IS in $raw
# (the .jsonl, via 2>&1|tee). Fix: rl_detect scans $raw too; rl_reset_wait reads the raw sibling.
#
# PLUGIN-SOURCE test: exercises BOTH loop variants (which only coexist in templates/); runs in the
# plugin's CI, not copied into a consumer .harness/.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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

# A session-limit notice as the CLI emits it in stream-json mode: a NON-text_delta result event (so the
# jq reassembly drops it from $out — it survives only in the raw .jsonl). No apostrophe → clean quoting.
NOTICE='{"type":"result","is_error":true,"result":"You have hit your session limit · resets 1am (Europe/London)"}'

for V in loop.sh loop.in-place.sh; do
  d="$(setup_repo)"
  rl() { ( cd "$d" && ".harness/scripts/$V" --rl-selftest "$@" 2>/dev/null ); }
  O="$d/out"; R="$d/out.jsonl"

  # 1. THE FIX: the limit is ONLY in the raw stream (a non-text_delta result event) → still detected.
  : > "$O"; printf '%s\n' "$NOTICE" > "$R"
  assert "[$V] limit in RAW stream only → detected (the fix)"       test "$(rl detect "$O" "$R" 1)" = LIMIT

  # 2. A plain crash with no limit wording anywhere → NOT a limit (no false positive).
  printf 'building... normal output, exit 1\n' > "$O"; printf '{"type":"stream_event"}\n' > "$R"
  assert "[$V] plain crash (no limit wording) → NOLIMIT"            test "$(rl detect "$O" "$R" 1)" = NOLIMIT

  # 3. Back-compat: a limit that DID land in the reassembled $out is still detected (exit 0 case).
  printf 'You have hit your session limit\n' > "$O"; : > "$R"
  assert "[$V] limit in reassembled \$out (exit 0) → detected"      test "$(rl detect "$O" "$R" 0)" = LIMIT

  # 4. Broad RL_RE stays $out-only: a limit-ish word in a RAW tool_result on a crash is NOT a limit
  #    (else building rate-limit handling — reading code that says "429"/"quota" — would misfire).
  : > "$O"; printf '{"type":"user","message":"tool_result: HTTP 429 quota exceeded in the fixture"}\n' > "$R"
  assert "[$V] broad limit-word in RAW only → NOLIMIT (no false positive)" test "$(rl detect "$O" "$R" 1)" = NOLIMIT

  # 4a. RL_HARD_RE tool_result guard: the agent READ a file whose own rate-limit detector contains the
  #     literal "usage limit reached" (a type:"user" event) and the build SUCCEEDED (rc 0, result:success)
  #     — must NOT be misread as a limit. This is the false-positive that soft-stalled the loop forever.
  : > "$O"
  { printf '%s\n' '{"type":"user","message":{"content":[{"type":"tool_result","content":"const RE = /claude usage limit reached|rate.?limit|429/;"}]}}'
    printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"api_error_status":null}'; } > "$R"
  assert "[$V] RL_HARD_RE wording in RAW tool_result + success → NOLIMIT (no false positive)" \
    test "$(rl detect "$O" "$R" 0)" = NOLIMIT

  # 4b. …but a GENUINE hard limit as a non-JSON stderr line (kept by rl_cli_said) is still detected.
  : > "$O"; printf 'Claude AI usage limit reached. resets 1am (Europe/London)\n' > "$R"
  assert "[$V] genuine hard limit on a non-JSON stderr line → detected" \
    test "$(rl detect "$O" "$R" 1)" = LIMIT

  # 5. Reset time is parsed from the raw sibling → a positive, bounded wait (not the exp-backoff fallback).
  : > "$O"; printf '%s\n' "$NOTICE" > "$O.jsonl"
  w="$(rl wait "$O")"
  assert "[$V] 'resets 1am (Europe/London)' parsed from raw → positive bounded wait" \
    bash -c 'case "$1" in ""|none|*[!0-9]*) exit 1;; esac; [ "$1" -gt 0 ] && [ "$1" -le 18000 ]' _ "$w"

  rm -rf "$d"
done

[ "$FAIL" = 0 ] && echo "ALL PASS" || { echo "SOME FAILED"; exit 1; }
