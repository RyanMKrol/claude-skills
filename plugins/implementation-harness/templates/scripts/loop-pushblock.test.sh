#!/usr/bin/env bash
#
# loop-pushblock.test.sh — regression guard for the "loop is the sole pusher" invariant (P5) in BOTH
# loop variants. As of 1.78.0 the WORKTREE variant no longer lets the builder push its own `tNNN`
# branch: the loop runs the deterministic local gate (structural_checks + LOCAL_DOD) FIRST, and only
# then pushes the branch — so a locally-broken build never burns a CI run or lands on origin. This
# brings the worktree variant in line with the in-place variant (which already blocked agent pushes).
#
# WHY STATIC: the push-block wiring lives inside run_claude()/the main-loop done-path, which can't be
# exercised end-to-end in CI without a live claude CLI + gh. So we assert the fixed SHAPE in source.
#
# PLUGIN-SOURCE test: runs in the plugin's CI, not copied into a consumer .harness/.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAIL=0
assert() { local desc="$1"; shift; if "$@"; then echo "ok - $desc"; else echo "FAIL - $desc"; FAIL=1; fi; }
has()    { grep -qF -- "$1" "$2"; }
lacks()  { ! grep -qF -- "$1" "$2"; }
# before <needleA> <needleB> <file> — first line matching A precedes first line matching B.
before() {
  local a b; a="$(grep -nF -- "$1" "$3" | head -1 | cut -d: -f1)"; b="$(grep -nF -- "$2" "$3" | head -1 | cut -d: -f1)"
  [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]
}

# ---- Both variants: run_claude blocks the agent push via the shared pre-push hook ----
for V in loop.sh loop.in-place.sh; do
  f="$SCRIPT_DIR/$V"
  assert "[$V] run_claude marks the agent subprocess HARNESS_AGENT=1"        has 'HARNESS_AGENT=1 GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0="$ROOT/.harness/scripts"' "$f"
  assert "[$V] run_claude keeps the pre-push hook executable"                has 'chmod +x "$ROOT/.harness/scripts/pre-push"' "$f"
  assert "[$V] DoD prompt hardened: run slow checks to completion (poll)"    has 'POLL to completion' "$f"
  assert "[$V] DoD prompt: an unobserved/incomplete check is failed:soft"    has 'OBSERVE is NOT a pass' "$f"
done

# ---- Worktree-specific: loop owns the tNNN push; local gate runs BEFORE it ----
f="$SCRIPT_DIR/loop.sh"
assert "[loop.sh] the LOOP pushes the branch (sole pusher)"                  has 'git -C "$LOOP_WT" push --quiet origin "$branch"' "$f"
assert "[loop.sh] structural gate (LOCAL_DOD) runs BEFORE the branch push"   before 'if ! structural_checks "$task"; then' 'heartbeat pushing' "$f"
assert "[loop.sh] the branch push runs BEFORE the CI wait"                   before 'heartbeat pushing' 'heartbeat awaiting-ci' "$f"
assert "[loop.sh] build prompt no longer tells the agent to push"           lacks 'git push -u origin HEAD' "$f"
assert "[loop.sh] done self-report says the branch is NOT pushed"           has 'built + committed on <branch> (NOT pushed)' "$f"

# ---- pre-push hook: still guards on HARNESS_AGENT, and its comment reflects BOTH variants ----
p="$SCRIPT_DIR/pre-push"
assert "[pre-push] still refuses only HARNESS_AGENT-marked pushes"          has 'if [ -n "${HARNESS_AGENT:-}" ]; then' "$p"
assert "[pre-push] comment no longer claims worktree omits the hook"        lacks 'WORKTREE variant deliberately does NOT activate' "$p"

[ "$FAIL" = 0 ] && echo "PASS: loop-pushblock" || { echo "FAIL: loop-pushblock"; exit 1; }
