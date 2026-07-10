#!/usr/bin/env bash
#
# scope-match.test.sh — regression tests for the SINGLE scope-matching implementation (scope-lib.sh:
# normalize_scope_prefix + scope_match), which the scope structural gate and check-task-scope.sh both
# rely on. Three parts:
#   A) source scope-lib.sh and run a CORPUS SEEDED FROM REAL REPO SCOPES (local-jobs + ryankrol.co.uk),
#      covering every shape — the bracket forms of Next.js dynamic routes are the class this guards.
#   B) a STRUCTURAL guard: the three consumers source scope-lib.sh and carry NO inline scope_match(), so
#      the copy-paste that caused this bug (and 1.40.3 / 1.53.0) can never silently return.
#   C) a runtime smoke: each loop variant's --scope-selftest still resolves the sourced functions.
#
# PLUGIN-SOURCE test: exercises both loop variants + scope-lib.sh, which only coexist here in templates/.
# Runs in the plugin's CI, not copied into a consumer's .harness/.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAIL=0
assert() { local desc="$1"; shift; if "$@"; then echo "ok - $desc"; else echo "FAIL - $desc"; FAIL=1; fi; }

# ── Part A: the real-scope corpus, run against scope-lib.sh directly ─────────────────────────────────
. "$SCRIPT_DIR/scope-lib.sh"
chk() {   # <file> <scope-entry> <IN|OUT>
  local got; if scope_match "$1" "$2"; then got=IN; else got=OUT; fi
  [ "$got" = "$3" ] && echo "ok - $3  scope=$2  file=$1" || { echo "FAIL - want $3 got $got  scope=$2  file=$1"; FAIL=1; }
}

# Bracket entries — copied verbatim from the two repos (the bug: a literal [name]/[id]/[...] segment must
# match its own path, NOT be treated as a character class). An in-scope file for each → IN.
chk "dashboard/app/jobs/[name]/page.tsx"                              "dashboard/app/jobs/[name]/page.tsx"                              IN
chk "dashboard/app/pipeline-runs/[id]/page.tsx"                      "dashboard/app/pipeline-runs/[id]/"                              IN   # bracket dir prefix (trailing /)
chk "dashboard/app/pipeline-runs/[id]/page.tsx"                      "dashboard/app/pipeline-runs/[id]/page.tsx"                      IN
chk "dashboard/app/pipelines/[name]/page.tsx"                        "dashboard/app/pipelines/[name]/page.tsx"                        IN
chk "dashboard/app/runs/[id]/page.tsx"                               "dashboard/app/runs/[id]/page.tsx"                               IN
chk "dashboard/app/workflow-runs/[id]/gates/x/page.tsx"             "dashboard/app/workflow-runs/[id]/**"                            IN   # bracket dir + ** (recursive)
chk "dashboard/app/workflow-runs/[id]/gates/[producer]/[key]/page.tsx" "dashboard/app/workflow-runs/[id]/gates/[producer]/[key]/page.tsx" IN   # MULTIPLE bracket segments
chk "dashboard/app/workflow-runs/[id]/page.tsx"                     "dashboard/app/workflow-runs/[id]/page.tsx"                      IN
chk "dashboard/app/workflows/[name]/gates/x/page.tsx"              "dashboard/app/workflows/[name]/**"                              IN
chk "dashboard/app/workflows/[name]/gates/[producer]/[key]/page.tsx" "dashboard/app/workflows/[name]/gates/[producer]/[key]/page.tsx" IN
chk "dashboard/app/workflows/[name]/page.tsx"                       "dashboard/app/workflows/[name]/page.tsx"                        IN   # T489 — the reported incident
chk "src/pages/api/exercises/history/[exerciseName].js"            "src/pages/api/exercises/history/[exerciseName].js"              IN   # bracket in the filename
chk "src/pages/exercises/[exerciseName].js"                        "src/pages/exercises/[exerciseName].js"                          IN
chk "src/pages/hot-takes/edit/[id].js"                             "src/pages/hot-takes/edit/[id].js"                               IN
chk "src/pages/reviews/albums/edit/[id].js"                        "src/pages/reviews/albums/edit/[id].js"                          IN
chk "src/pages/reviews/books/edit/[id].js"                         "src/pages/reviews/books/edit/[id].js"                           IN
chk "src/pages/reviews/movies/edit/[id].js"                        "src/pages/reviews/movies/edit/[id].js"                          IN
chk "src/pages/workouts/[id].js"                                   "src/pages/workouts/[id].js"                                     IN

# Brackets must stay LITERAL — a different segment / value must NOT over-match.
chk "dashboard/app/jobs/[other]/page.tsx"     "dashboard/app/jobs/[name]/page.tsx"          OUT   # [other] != [name]
chk "src/pages/workouts/99.js"                "src/pages/workouts/[id].js"                  OUT   # 99 != [id]
chk "dashboard/app/workflows/[name]/other.tsx" "dashboard/app/workflows/[name]/page.tsx"    OUT   # exact entry, different file

# Representative non-bracket shapes (real entries) — unchanged behaviour.
chk "dashboard/app/components/CategoryTable.tsx" "dashboard/app/components/*.tsx"            IN    # dir/*.ext
chk "dashboard/app/components/sub/X.tsx"         "dashboard/app/components/*.tsx"            OUT   # not nested
chk "dashboard/app/components/X.ts"              "dashboard/app/components/*.tsx"            OUT   # wrong extension
chk "src/jobs/plex/a/b.ts"                       "src/jobs/plex/**"                         IN    # dir/** recursive
chk "src/workflows/perfumes/index.ts"           "src/workflows/perfumes/*.ts"              IN
chk "src/workflows/perfumes/sub/x.ts"           "src/workflows/perfumes/*.ts"              OUT
chk "src/components/v2/Foo.tsx"                  "src/components/**"                         IN
chk "src/pages/api/books/search.js"             "src/pages/api/books/**"                    IN
chk "public/img/logo.png"                        "public/**"                                IN
chk "src/pages/api/books/search.js"             "src/pages/api/books/search.js"            IN    # exact path
chk "src/pages/api/books/other.js"              "src/pages/api/books/search.js"            OUT   # exact rejects a sibling

# Residual that Candidate B additionally handles: a literal bracket segment + a real extension glob.
chk "dashboard/app/[name]/page.tsx"              "dashboard/app/[name]/*.tsx"               IN

# ── Part B: the de-dup structural guard — no copy can silently return ────────────────────────────────
for s in loop.sh loop.in-place.sh check-task-scope.sh; do
  assert "[$s] sources scope-lib.sh"                grep -q 'scope-lib.sh' "$SCRIPT_DIR/$s"
  assert "[$s] carries NO inline scope_match()"     bash -c "! grep -qE '^scope_match\\(\\)' '$SCRIPT_DIR/$s'"
done
assert "scope-lib.sh defines scope_match"           grep -qE '^scope_match\(\)' "$SCRIPT_DIR/scope-lib.sh"
assert "scope-lib.sh defines normalize_scope_prefix" grep -qE '^normalize_scope_prefix\(\)' "$SCRIPT_DIR/scope-lib.sh"

# ── Part C: runtime smoke — each loop variant sources scope-lib.sh and dispatches --scope-selftest ───
setup_repo() {
  local d; d="$(mktemp -d)"
  git init -q "$d"; ( cd "$d" && git config user.email t@t.com && git config user.name t )
  mkdir -p "$d/.harness/scripts" "$d/.harness/config" "$d/.harness/tracking"
  cp "$SCRIPT_DIR/repo-lock.sh" "$SCRIPT_DIR/scope-lib.sh" "$SCRIPT_DIR/loop.sh" "$SCRIPT_DIR/loop.in-place.sh" "$d/.harness/scripts/"
  chmod +x "$d/.harness/scripts/"*.sh
  echo '{"tasks":[]}' > "$d/.harness/tracking/TASKS.json"
  ( cd "$d" && git add -A && git commit -q -m init ); echo "$d"
}
probe() { ( cd "$1" && env -u CLAUDECODE ".harness/scripts/$2" --scope-selftest "$3" "$4" 2>/dev/null ); }
for V in loop.sh loop.in-place.sh; do
  d="$(setup_repo)"
  assert "[$V] runtime: sourced scope_match matches a bracket path" \
    test "$(probe "$d" "$V" 'app/[name]/page.tsx' 'app/[name]/page.tsx')" = IN
  assert "[$V] runtime: built-in --scope-selftest table passes" \
    bash -c "( cd '$d' && env -u CLAUDECODE .harness/scripts/$V --scope-selftest >/dev/null 2>&1 )"
  rm -rf "$d"
done

echo
[ "$FAIL" = 0 ] && echo "ALL PASS" || echo "SOME FAILED"
exit "$FAIL"
