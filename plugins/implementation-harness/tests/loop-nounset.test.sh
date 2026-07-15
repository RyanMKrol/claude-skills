#!/usr/bin/env bash
#
# loop-nounset.test.sh — regression guard for a HIGH-severity bash 3.2 crash in run_claude().
#
# run_claude() builds optional CLI flags as arrays that may be EMPTY: `eff` (no --effort for effort-less
# models like the Haiku cold-start floor) and `FLAGS` (empty if a user sets CLAUDE_FLAGS=""). On bash
# < 4.4 — which includes macOS's stock /bin/bash 3.2.57 — expanding a declared-but-empty array as a BARE
# "${arr[@]}" under `set -u` throws `unbound variable`, crashing the loop BEFORE claude ever runs. Because
# that crash is treated as a transient (non-attempt-counting) failure, the task never escalates — it
# crash-loops for ~MAX_ITERS (~50 min). The fix is the set -u-safe guard `${arr[@]+"${arr[@]}"}`. This
# test locks that guard in for BOTH variants.
#
# WHY STATIC, not behavioral: the plugin's own CI runs on a modern bash (>= 4.4) where the BARE form does
# NOT crash — a runtime test would pass even with the bug present (that is exactly how this shipped
# undetected). So we assert the guarded FORM is in the source, independent of the runner's bash version.
# A behavioral check that the guard idiom itself survives an empty expansion under `set -u` is included as
# a sanity anchor.
#
# PLUGIN-SOURCE test: exercises BOTH loop variants (which only coexist in templates/); runs in the
# plugin's CI, not copied into a consumer .harness/.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../templates/scripts" && pwd)"
FAIL=0
assert()   { local desc="$1"; shift; if "$@"; then echo "ok - $desc"; else echo "FAIL - $desc"; FAIL=1; fi; }
has()      { grep -qF -- "$1" "$2"; }        # fixed-string present
lacks()    { ! grep -qF -- "$1" "$2"; }      # fixed-string absent

# run_claude()'s optional-flag arrays MUST expand with the set -u guard, never bare, on the command
# line. As of C01 stage 2, run_claude lives ONCE in loop-lib.sh (sourced by both variants) rather than
# duplicated per variant, so the guard only needs checking there.
LIB="$SCRIPT_DIR/loop-lib.sh"
assert "[loop-lib.sh] eff expanded with set -u guard"    has   '--model "$model" ${eff[@]+"${eff[@]}"}'   "$LIB"
assert "[loop-lib.sh] no BARE eff expansion remains"      lacks '--model "$model" "${eff[@]}"'             "$LIB"
assert "[loop-lib.sh] FLAGS expanded with set -u guard"   has   '--verbose ${FLAGS[@]+"${FLAGS[@]}"}'      "$LIB"
assert "[loop-lib.sh] no BARE FLAGS expansion remains"    lacks '--verbose "${FLAGS[@]}"'                  "$LIB"
assert "run_claude lives in loop-lib.sh, not re-inlined in either variant" \
  bash -c "grep -qE '^run_claude\(\) \{' '$LIB' && ! grep -qE '^run_claude\(\) \{' '$SCRIPT_DIR/loop.sh' && ! grep -qE '^run_claude\(\) \{' '$SCRIPT_DIR/loop.in-place.sh'"

# Sanity anchor: the guard idiom really is nounset-safe for an EMPTY array on THIS bash (passes on any
# version; documents the mechanism the asserts above protect).
assert "guard idiom survives empty-array expansion under set -u" \
  bash -uc 'a=(); printf "%s" "${a[@]+"${a[@]}"}"; exit 0'

[ "$FAIL" = 0 ] && echo "ALL PASS" || { echo "SOME FAILED"; exit 1; }
