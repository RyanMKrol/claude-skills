#!/usr/bin/env bash
#
# scope-match.test.sh — regression tests for scope_match()'s scope-entry matching (exact path,
# directory prefix, and the single-level extension glob `dir/*.ext`), via each loop variant's
# --scope-selftest debug flag. Spins up a throwaway git repo (mktemp -d) so it never touches a real
# harness — scope_match()'s dispatch point is only reached after the script's top-level ROOT
# detection + repo-lock.sh sourcing, so it can't be invoked standalone outside a real git repo.
#
# This is a PLUGIN-SOURCE test: it exercises BOTH loop variants, which only coexist here in
# templates/. It runs in the plugin's CI and is NOT copied into a consumer's .harness/ (an install
# has only one variant). Run it from the plugin checkout:
#   plugins/.../templates/scripts/scope-match.test.sh
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
  # --guard-selftest if tracking/TASKS.json is absent — needs a minimal placeholder here.
  echo '{"tasks":[]}' > "$d/.harness/tracking/TASKS.json"
  ( cd "$d" && git add -A && git commit -q -m init )
  echo "$d"
}

probe() { ( cd "$1" && ".harness/scripts/$2" --scope-selftest "$3" "$4" 2>/dev/null ); }   # <repo> <variant> <entry> <file>

for V in loop.sh loop.in-place.sh; do
  d="$(setup_repo)"

  assert "[$V] built-in regression table"                          bash -c "( cd '$d' && .harness/scripts/$V --scope-selftest >/dev/null 2>&1 )"

  # the bug this fixes — a single-level extension glob must match a real file directly in the dir
  assert "[$V] dir/*.ext matches a file directly in dir"           test "$(probe "$d" "$V" 'components/*.tsx' 'components/CategoryTable.tsx')" = IN
  assert "[$V] real-world dashboard/*.tsx case matches"            test "$(probe "$d" "$V" 'dashboard/app/components/*.tsx' 'dashboard/app/components/CategoryTable.tsx')" = IN

  # single-level, not recursive; extension is significant
  assert "[$V] dir/*.ext does NOT match a nested file"             test "$(probe "$d" "$V" 'components/*.tsx' 'components/sub/Foo.tsx')" = OUT
  assert "[$V] dir/*.ext does NOT match a wrong extension"         test "$(probe "$d" "$V" 'components/*.tsx' 'components/CategoryTable.ts')" = OUT

  # no regression — the shapes that already worked
  assert "[$V] dir/** stays recursive (no regression)"            test "$(probe "$d" "$V" 'src/feature/**' 'src/feature/x/y.ts')" = IN
  assert "[$V] dir/* stays recursive (no regression)"             test "$(probe "$d" "$V" 'src/foo/*' 'src/foo/bar/a.ts')" = IN
  assert "[$V] exact path matches (no regression)"                 test "$(probe "$d" "$V" 'src/auth/session.ts' 'src/auth/session.ts')" = IN
  assert "[$V] exact path rejects a sibling (no regression)"       test "$(probe "$d" "$V" 'src/auth/session.ts' 'src/auth/other.ts')" = OUT

  rm -rf "$d"
done

echo
[ "$FAIL" = 0 ] && echo "ALL PASS" || echo "SOME FAILED"
exit "$FAIL"
