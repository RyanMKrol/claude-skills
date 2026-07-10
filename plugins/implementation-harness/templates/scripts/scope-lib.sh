#!/usr/bin/env bash
#
# scope-lib.sh — THE single scope-matching implementation, sourced by loop.sh, loop.in-place.sh, and
# check-task-scope.sh. It used to be copy-pasted verbatim into all three, which drifted and re-broke
# repeatedly (the bracket bug below, plus 1.40.3 / 1.53.0). Now there is exactly ONE copy.
#
# Pure functions only — NO side effects, NO top-level execution — so it is safe to `source` from any of
# the consumers regardless of where they are in their own setup. Targets bash 3.2 (macOS default).

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
