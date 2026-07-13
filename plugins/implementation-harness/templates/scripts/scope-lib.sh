#!/usr/bin/env bash
#
# scope-lib.sh — THE single scope-matching implementation, sourced by loop.sh, loop.in-place.sh, and
# check-task-scope.sh. It used to be copy-pasted verbatim into all three, which drifted and re-broke
# repeatedly (the bracket bug below, plus 1.40.3 / 1.53.0). Now there is exactly ONE copy.
#
# NO top-level execution — nothing runs at `source` time, so it is safe to `source` from any of the
# consumers regardless of where they are in their own setup. The matchers are pure; the one loader
# (`test_patterns_load`) reads its custom pattern file only when explicitly CALLED. Targets bash 3.2.

# normalize_scope_prefix <raw> — strip a trailing `/`, `/**`, or `/*` so a directory-style scope entry
# becomes a bare prefix (dir/  dir/**  dir/*  →  dir).
normalize_scope_prefix() {
  local s="$1"
  s="${s%/}"; s="${s%/\*\*}"; s="${s%/\*}"
  printf '%s' "$s"
}

# scope_match <file> <scope-entry> — true if <file> is within <scope-entry>. Supports:
#   • an exact path                          (src/auth/session.ts)
#   • a directory prefix, recursive          (dir/  dir/**  dir/*  → everything under dir)
#   • a single-level extension glob          (dir/*.tsx → any *.tsx DIRECTLY in dir, not nested)
#   • LITERAL path metacharacters            (Next.js dynamic routes: app/[name]/page.tsx, [id].js,
#                                             app/[...slug]/…, multi-segment app/[a]/x/[b]/page.tsx)
#
# It tries the LITERAL interpretations FIRST (a double-quoted expansion keeps `[ ] ? *` literal, so a
# `[name]` segment matches its own exact path / directory prefix). Only THEN is a surviving `*` treated as
# the documented single-level extension glob — and `[ ] ?` are escaped so `*` is the ONLY active
# metacharacter (a `[name]` is a literal path part, never a character class; `*.ext` is the only glob we
# support). This is why an unquoted-glob-only implementation used to reject a literal `[name]` path as
# scope-creep: `[name]` collapsed to a one-char class and never matched itself.
#
# NOT supported (a SEPARATE, pre-existing shape — check-task-scope.sh flags it as an unsupported glob):
# a MID-PATH `**` such as `src/**/*.test.ts`; only trailing `/**` `/*` (via normalize) and a single-level
# `dir/*.ext` are honoured.
scope_match() {
  local f="$1" s d1 d2 g
  s="$(normalize_scope_prefix "$2")"
  # 1) Literal first — quoted expansions keep every metacharacter literal.
  [ "$f" = "$s" ] && return 0                       # exact path
  [ "${f#"$s"/}" != "$f" ] && return 0              # directory prefix
  # 2) Only a surviving `*` is a glob. Escape `[ ] ?` so ONLY `*` stays active, then require equal
  #    directory depth so `*` can't span a `/` (an unquoted case `*` otherwise matches across dirs).
  case "$s" in
    *'*'*)
      g="$s"; g="${g//\[/\\[}"; g="${g//\]/\\]}"; g="${g//\?/\\?}"
      case "$f" in
        $g)
          d1="${f//[!\/]/}"; d2="${s//[!\/]/}"
          [ "${#d1}" -eq "${#d2}" ] && return 0
          ;;
      esac
      ;;
  esac
  return 1
}

# --- Test-file detection (the SINGLE matcher — was 4 inline greps in the two loop variants) -----------
# Used by structural_checks for BOTH the `expectsTest: true` gate ("did this build include a test?") and
# the scope-creep exemption ("a NEW test file is allowed outside the task's scope"). A path counts as a
# test file if it matches a BUILT-IN convention OR a project-defined pattern:
#   • built-in, case-INSENSITIVE — the common JS/Python/Go/Ruby shapes: `.test.` / `.spec.` / `_test.` in
#     the filename, or a `test_` / `tests?` PATH SEGMENT (foo.test.ts, foo_test.go, tests/, test_foo.py);
#   • built-in, case-SENSITIVE CamelCase — a segment ENDING in `Test`/`Tests`: `UITests/`, `FooTests/`,
#     `RenameFlowTests.swift`, `BarTest.kt` (Swift/Java/Kotlin/Xcode). The capital `T` is deliberate — it
#     recognises Apple's own `UITests/` convention (UI glued onto Tests, no separator) WITHOUT matching
#     plain-English dirs like `latest/` or `contest/` that merely END in a lowercase "test".
#   • project-defined — any ERE fragment in `.harness/custom/test-file-patterns.txt` (loaded into
#     TEST_FILE_EXTRA_RE by test_patterns_load), so a consumer can teach the harness their own convention
#     without forking the loop. See docs/HARNESS.md "Extending the harness".
is_test_path() {  # <path> — 0 iff <path> looks like a test file
  local f="$1"
  if printf '%s\n' "$f" | grep -qiE '(\.test\.|\.spec\.|_test\.|(^|/)test_|(^|/)tests?/)'; then return 0; fi
  if printf '%s\n' "$f" | grep -qE  '((^|/)[A-Za-z0-9]*Tests?/|[A-Za-z0-9]*Tests?\.[A-Za-z0-9]+$)'; then return 0; fi
  if [ -n "${TEST_FILE_EXTRA_RE:-}" ] && printf '%s\n' "$f" | grep -qiE "$TEST_FILE_EXTRA_RE"; then return 0; fi
  return 1
}

any_test_path() {  # reads newline-separated paths on stdin — 0 iff ANY line is a test file
  local f
  while IFS= read -r f; do [ -z "$f" ] && continue; is_test_path "$f" && return 0; done
  return 1
}

# test_patterns_load <harness-dir> — populate TEST_FILE_EXTRA_RE from custom/test-file-patterns.txt (one
# ERE fragment per line; blank/#-comment lines ignored), joined with `|`. Missing file → empty (built-ins
# only). A pattern that won't compile is REJECTED (returns 1, TEST_FILE_EXTRA_RE stays empty) so the caller
# can WARN — the built-in conventions always stay active, never wedged. Mirrors the sensitive-paths load.
# (Reads a file when CALLED — no top-level execution, so scope-lib is still safe to `source` anywhere.)
test_patterns_load() {
  local file="$1/custom/test-file-patterns.txt" extra rc
  TEST_FILE_EXTRA_RE=""
  [ -f "$file" ] || return 0
  extra="$(grep -vE '^[[:space:]]*(#|$)' "$file" 2>/dev/null | paste -sd'|' - || true)"
  [ -n "$extra" ] || return 0
  if printf '' | grep -qiE "$extra" 2>/dev/null; then TEST_FILE_EXTRA_RE="$extra"; return 0
  else rc=$?; if [ "$rc" -le 1 ]; then TEST_FILE_EXTRA_RE="$extra"; return 0; else return 1; fi; fi
}
