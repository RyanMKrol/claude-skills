#!/usr/bin/env bash
#
# scope-exempt.test.sh — regression tests for in_scope_exempt()'s SCOPE_EXEMPT_GLOBS normalization,
# via each loop variant's --scope-exempt-selftest debug flag. Spins up a throwaway git repo
# (mktemp -d) so it never touches a real harness — in_scope_exempt()'s own dispatch point is only
# reached after the script's top-level ROOT detection + repo-lock.sh sourcing, so it can't be
# invoked standalone outside a real git repo.
#
# This is a PLUGIN-SOURCE test: it exercises BOTH loop variants, which only coexist here in
# templates/. It runs in the plugin's CI and is NOT copied into a consumer's .harness/ (an install
# has only one variant). Run it from the plugin checkout:
#   plugins/.../templates/scripts/scope-exempt.test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAIL=0
assert() { local desc="$1"; shift; if "$@"; then echo "ok - $desc"; else echo "FAIL - $desc"; FAIL=1; fi; }

setup_repo() {   # echoes the repo path — a git repo whose .harness/scripts holds both loop variants
  local d
  d="$(mktemp -d)"
  git init -q "$d"
  ( cd "$d" && git config user.email t@t.com && git config user.name t )
  mkdir -p "$d/.harness/scripts" "$d/.harness/config" "$d/.harness/tracking"
  cp "$SCRIPT_DIR/repo-lock.sh" "$SCRIPT_DIR/loop.sh" "$SCRIPT_DIR/loop.in-place.sh" "$d/.harness/scripts/"
  chmod +x "$d/.harness/scripts/"*.sh
  # loop.in-place.sh's own top-level setup exits 3 before reaching ANY dispatch flag past
  # --guard-selftest if tracking/TASKS.json is absent (loop.sh's worktree variant has no such
  # check this early — it defers to a fetched origin/main) — needs a minimal placeholder here.
  echo '{"tasks":[]}' > "$d/.harness/tracking/TASKS.json"
  ( cd "$d" && git add -A && git commit -q -m init )
  echo "$d"
}

probe() { ( cd "$1" && ".harness/scripts/$2" --scope-exempt-selftest "$3" "$4" 2>/dev/null ); }   # <repo> <variant> <globs> <file>

for V in loop.sh loop.in-place.sh; do
  d="$(setup_repo)"

  assert "[$V] built-in regression table"                            bash -c "( cd '$d' && .harness/scripts/$V --scope-exempt-selftest >/dev/null 2>&1 )"

  # previously-broken forms — these silently exempted nothing before the fix
  assert "[$V] directory-prefix form (trailing slash) exempts"       test "$(probe "$d" "$V" 'scripts/' 'scripts/_visual-harness.mjs')" = EXEMPT
  assert "[$V] glob-suffix form (/**) exempts"                       test "$(probe "$d" "$V" 'scripts/**' 'scripts/_visual-harness.mjs')" = EXEMPT
  assert "[$V] glob-suffix form (/*) exempts"                        test "$(probe "$d" "$V" 'scripts/*' 'scripts/_visual-harness.mjs')" = EXEMPT

  # previously-working forms — no regression
  assert "[$V] bare directory form still exempts (no regression)"    test "$(probe "$d" "$V" 'scripts' 'scripts/_visual-harness.mjs')" = EXEMPT
  assert "[$V] exact-file form still exempts (no regression)"        test "$(probe "$d" "$V" 'scripts/visual-check.mjs' 'scripts/visual-check.mjs')" = EXEMPT

  # no over-broadening
  assert "[$V] unrelated file NOT exempt (no over-broadening)"       test "$(probe "$d" "$V" 'scripts/visual-check.mjs' 'scripts/other.mjs')" = NOT-EXEMPT

  rm -rf "$d"
done

echo
[ "$FAIL" = 0 ] && echo "ALL PASS" || echo "SOME FAILED"
exit "$FAIL"
