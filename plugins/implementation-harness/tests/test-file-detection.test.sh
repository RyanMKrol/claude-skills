#!/usr/bin/env bash
#
# test-file-detection.test.sh — the shared test-file matcher in scope-lib.sh (is_test_path / any_test_path /
# test_patterns_load), used by BOTH loop variants' structural_checks for the `expectsTest: true` gate and the
# test-file scope-creep exemption. Regression guard for the 1.81.0 fix: Apple's own `UITests/` convention
# ("UI" glued onto "Tests", no separator) was NOT recognized by the old `(^|/)tests?/` anchor, so an iOS
# task with a UITest looped forever failing "no test file" (real incident, basket T019).
#
# PLUGIN-SOURCE test (plugin CI only). Sources the shared lib directly — no loop startup / gh / git needed.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../templates/scripts" && pwd)"
FAIL=0
assert() { local desc="$1"; shift; if "$@"; then echo "ok - $desc"; else echo "FAIL - $desc"; FAIL=1; fi; }

# shellcheck disable=SC1090
. "$SCRIPT_DIR/scope-lib.sh"
TEST_FILE_EXTRA_RE=""   # start with no project patterns

not_test()  { ! is_test_path "$1"; }
has_test()  { printf '%s\n' "$@" | any_test_path; }
no_test_in(){ ! has_test "$@"; }

# ---- built-in conventions MATCH (the bug case first) ----
for p in \
  "BasketUITests/RenameFlowTests.swift" "app/UITests/Login.swift" \
  "Tests/FooTests.swift" "Bar/BarTest.kt" \
  "src/foo.test.ts" "src/foo.spec.js" "pkg/foo_test.go" "tests/x.py" "test_foo.py"; do
  assert "built-in MATCH: $p" is_test_path "$p"
done

# ---- non-tests do NOT match (false-positive guards — the CamelCase rule needs a capital T) ----
for p in \
  "releases/latest/notes.md" "src/contest.js" "docs/greatest.md" \
  "src/manifest.json" "src/App.swift" "src/index.ts" "README.md"; do
  assert "non-test SKIP: $p" not_test "$p"
done

# ---- any_test_path over a changed-file list ----
assert "any_test_path finds the test in a mixed list" has_test "src/rename.swift" "BasketUITests/RenameFlowTests.swift"
assert "any_test_path false when no test present"     no_test_in "src/rename.swift" "src/App.swift"

# ---- project-defined patterns via test_patterns_load(custom/test-file-patterns.txt) ----
D="$(mktemp -d)"; trap 'rm -rf "$D"' EXIT; mkdir -p "$D/custom"
printf '# my project\n(^|/)androidTest/\n\\.feature$\n' > "$D/custom/test-file-patterns.txt"
rc=0; test_patterns_load "$D" || rc=$?
assert "custom load succeeded (exit 0)"          test "$rc" -eq 0
assert "custom pattern androidTest/ now matches" is_test_path "app/src/androidTest/Foo.kt"
assert "custom pattern .feature now matches"     is_test_path "features/login.feature"
assert "a non-matching path still NOT a test"    not_test "src/main/Foo.kt"

# ---- missing file → empty extra, built-ins still work ----
rm -f "$D/custom/test-file-patterns.txt"
rc=0; test_patterns_load "$D" || rc=$?
assert "missing custom file → EXTRA_RE empty"    test -z "$TEST_FILE_EXTRA_RE"
assert "built-ins still active after empty load"  is_test_path "tests/x.py"

# ---- invalid regex → REJECTED (returns 1), built-ins stay active ----
printf '(^|/)UITests/\n[unterminated\n' > "$D/custom/test-file-patterns.txt"
rc=0; test_patterns_load "$D" || rc=$?
assert "invalid custom regex → returns 1"        test "$rc" -eq 1
assert "invalid custom regex → EXTRA_RE empty"   test -z "$TEST_FILE_EXTRA_RE"
assert "built-ins STILL active after bad file"   is_test_path "app/UITests/Login.swift"

[ "$FAIL" = 0 ] && echo "PASS: test-file-detection" || { echo "FAIL: test-file-detection"; exit 1; }
