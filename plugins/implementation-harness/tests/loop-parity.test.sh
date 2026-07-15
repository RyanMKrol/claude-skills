#!/usr/bin/env bash
#
# loop-parity.test.sh — mechanical enforcement of the "keep both loop variants in parity" rule
# (plugin CLAUDE.md). DEV-LEVEL test: it needs BOTH variants side by side, so it lives under the
# plugin's tests/ (never shipped into installs, which carry exactly one variant as loop.sh).
#
# The manifest below lists every function whose body is REQUIRED to stay byte-identical across
# loop.sh (worktree) and loop.in-place.sh. These are the shared-logic functions where every recent
# regression class lived (rate-limit detection 1.69.0, idle handling 1.65.0, banner 1.64.2) — a fix
# mirrored by hand into only one variant now fails CI instead of shipping silently.
#
# When this test fails you have two valid moves:
#   • you meant to change both variants → mirror the edit, byte-for-byte;
#   • the function legitimately diverged (a real isolation-model difference) → remove it from the
#     manifest here, in the same commit, with a comment saying why.
# Extraction relies on the repo's function style: `name() {` at column 0, closing `}` at column 0.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WT="$SCRIPT_DIR/../templates/scripts/loop.sh"
IP="$SCRIPT_DIR/../templates/scripts/loop.in-place.sh"
FAIL=0

assert() { local desc="$1"; shift; if "$@"; then echo "ok - $desc"; else echo "FAIL - $desc"; FAIL=1; fi; }

assert "worktree variant exists with its marker" grep -q '^# harness-loop-variant: worktree' "$WT"
assert "in-place variant exists with its marker" grep -q '^# harness-loop-variant: in-place' "$IP"

# C01: shared logic is being extracted, in stages, into loop-lib.sh (sourced by both variants) instead
# of hand-mirrored here. Stage 1 (RL family) moved _hms, rl_banner, rl_detect, rl_selftest, plus
# rl_reset_wait/rl_cli_said/rl_build_wait (never pinned below — rl_reset_wait genuinely diverged in
# comments pre-extraction, and rl_cli_said/rl_build_wait are new/never had a local copy to pin). A
# moved function must exist ONLY in the lib — never re-inlined locally by either variant (the
# no-reinline guard below) — and both variants must actually source the lib.
LIB="$SCRIPT_DIR/../templates/scripts/loop-lib.sh"
assert "loop-lib.sh exists" [ -f "$LIB" ]
assert "worktree variant sources loop-lib.sh" grep -qE '^\. "\$SCRIPT_DIR/loop-lib\.sh"' "$WT"
assert "in-place variant sources loop-lib.sh" grep -qE '^\. "\$SCRIPT_DIR/loop-lib\.sh"' "$IP"
MOVED_TO_LIB="_hms rl_banner rl_detect rl_reset_wait rl_cli_said rl_selftest rl_build_wait"
for fn in $MOVED_TO_LIB; do
  assert "$fn defined in loop-lib.sh" grep -qE "^$fn\(\) \{" "$LIB"
  assert "$fn NOT re-inlined in loop.sh" bash -c "! grep -qE '^$fn\(\) \{' '$WT'"
  assert "$fn NOT re-inlined in loop.in-place.sh" bash -c "! grep -qE '^$fn\(\) \{' '$IP'"
done

# Verified byte-identical at the time this manifest was authored (v1.70.x); shrinks as extraction
# (C01) moves a function into loop-lib.sh instead — see the lib-presence block above. Alphabetical.
MANIFEST="_custom_preamble _visual_verify_custom board bump ci_conclusion ci_find_run ci_status_now \
gtier guard_selftest heartbeat in_scope_exempt log rand_pm record_failure \
run_hook run_integrate_hook scope_exempt_selftest scope_selftest throttled_push tier_strength \
visual_verify_block"

carve() { sed -n "/^$1() {/,/^}/p" "$2"; }

for fn in $MANIFEST; do
  a="$(carve "$fn" "$WT")"
  b="$(carve "$fn" "$IP")"
  if [ -z "$a" ] || [ -z "$b" ]; then
    echo "FAIL - $fn: extraction came up empty (worktree: ${#a}B, in-place: ${#b}B) — renamed/moved? update the manifest"
    FAIL=1
    continue
  fi
  if [ "$a" = "$b" ]; then
    echo "ok - $fn identical across variants"
  else
    echo "FAIL - $fn DIVERGED between loop.sh and loop.in-place.sh — mirror the edit (or, if the divergence is a real isolation-model difference, remove it from this manifest with a comment)"
    diff <(printf '%s\n' "$a") <(printf '%s\n' "$b") | head -20
    FAIL=1
  fi
done

# Negative control: a function that legitimately differs (isolation-model core). If this ever
# reports identical, the carve technique itself is probably broken (extracting empties or the
# wrong region), so the SAME results above would be meaningless.
a="$(carve select_task "$WT")"; b="$(carve select_task "$IP")"
assert "negative control: select_task genuinely differs (carve technique is live)" [ "$a" != "$b" ]
assert "negative control extracted non-empty bodies" bash -c "[ -n '$(printf '%s' "$a" | head -c1)' ]"

if [ "$FAIL" = 0 ]; then echo "PASS: loop-parity"; else echo "FAIL: loop-parity"; exit 1; fi
