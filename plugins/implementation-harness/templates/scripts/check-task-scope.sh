#!/usr/bin/env bash
#
# check-task-scope.sh — ADVISORY (non-blocking) scope-authoring linter. Catches a common backlog
# authoring mistake: a task's spec instructs editing a file that was never added to its `scope`
# array, so the loop's real structural scope-gate later refuses the edit and the task fails
# failed:blocked. This is a heuristic, false-positive-tolerant HEADS-UP, not a hard gate — it
# can't tell "edit this file" from "read this file for context" in the spec prose.
#
# Usage: check-task-scope.sh            # scan every pending, non-needs-human task
#        check-task-scope.sh T171       # scan one task
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOT="$(git -C "$HARNESS_DIR" rev-parse --show-toplevel)"
BACKLOG="$HARNESS_DIR/tracking/TASKS.json"
IGNORES_DIR="$HARNESS_DIR/.scope-gap-ignores"
command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 3; }

# Recognized repo-relative path prefixes for the spec path-extraction below — derived from the repo's
# REAL top-level directories (via tracked files), so a project's own dirs (e.g. `dashboard/`) are
# recognized generically, not just a hardcoded list that silently misses everything else. Dots are
# regex-escaped so `.harness` / `.github` stay anchored; fall back to the historical list if git yields
# nothing (e.g. a bare/unusual checkout).
PREFIX_ALT="$(git -C "$ROOT" ls-files 2>/dev/null | grep / | sed -e 's#/.*##' -e 's#\.#\\.#g' | sort -u | paste -sd'|' -)"
[ -n "$PREFIX_ALT" ] || PREFIX_ALT='src|\.harness|public|scripts|config|docs|tests?'

sha256_of_file() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  else shasum -a 256 "$1" | awk '{print $1}'
  fi
}

# is_dismissed <id> <path> <spec_hash> — true if fix-scope-gaps already judged <path> a false
# positive for <id> AND the spec hasn't changed since (specHash still matches). A gitignored,
# per-task scratch file (.harness/.scope-gap-ignores/<id>.json) — never committed, so this is local
# suppression state; a stale entry (spec since edited) just silently stops matching, nothing deletes
# it. See implementation-harness-fix-scope-gaps, the only writer.
is_dismissed() {
  local id="$1" path="$2" spec_hash="$3" f="$IGNORES_DIR/$id.json"
  [ -f "$f" ] || return 1
  jq -e --arg p "$path" --arg h "$spec_hash" '.dismissed[]? | select(.path==$p and .specHash==$h)' "$f" >/dev/null 2>&1
}

# normalize_scope_prefix + scope_match — kept IDENTICAL to loop.sh / loop.in-place.sh (their shared
# scope-matching implementation), so this linter matches exactly what the real gate will accept.
normalize_scope_prefix() {
  local s="$1"
  s="${s%/}"; s="${s%/\*\*}"; s="${s%/\*}"
  printf '%s' "$s"
}

# scope_match <file> <scope-entry> — exact path, directory prefix (trailing /, /**, /*, recursive),
# or single-level extension glob (`dir/*.ext`). Mirror of loop.sh's scope_match — keep in sync.
scope_match() {
  local f="$1" s d1 d2
  s="$(normalize_scope_prefix "$2")"
  case "$s" in
    *[*?[]*)
      # residual glob metacharacter → single-level glob: case-glob match, then require equal directory
      # depth so `*` can't span a `/` (an unquoted case `*` otherwise matches across directories).
      case "$f" in
        $s)
          d1="${f//[!\/]/}"; d2="${s//[!\/]/}"
          [ "${#d1}" -eq "${#d2}" ] && return 0
          ;;
      esac
      return 1
      ;;
    *)
      [ "$f" = "$s" ] && return 0
      [ "${f#"$s"/}" != "$f" ] && return 0
      return 1
      ;;
  esac
}

# unsupported_scope_shape <entry> — 0 if <entry>'s glob shape is one scope_match CANNOT honor, i.e. it
# would silently never match what the author intends: a `**` that survived trailing-`/**` normalization
# (a mid-path recursive glob), or brace expansion (glob matching doesn't expand `{a,b}`). Single-level
# globs at any fixed depth (`dir/*.ext`, `dir/*/*.ts`, `dir/[ab].ts`) ARE handled, so they're not flagged.
unsupported_scope_shape() {
  local s; s="$(normalize_scope_prefix "$1")"
  case "$s" in
    *'**'*)       return 0 ;;   # mid-path recursive glob — depth guard makes it never match nested files
    *'{'*|*'}'*)  return 0 ;;   # brace expansion is not glob-expanded by the matcher
  esac
  return 1
}

# in_scope <file> <scope-newline-list> — true if <file> matches any scope entry, via the shared
# scope_match (same rule as the real structural gate). For a FULL repo-relative path candidate.
in_scope() {
  local f="$1" scope="$2" s
  while IFS= read -r s; do
    [ -z "$s" ] && continue
    scope_match "$f" "$s" && return 0
  done <<SCOPE
$scope
SCOPE
  return 1
}

# basename_in_scope <name> <scope-newline-list> — true if ANY scope entry's basename equals <name>.
# For a BARE filename candidate (e.g. `Foo.js`) — in_scope()'s exact/prefix rule would almost never
# match a real scope entry like `src/components/Foo.js`, since the bare name has no path prefix at
# all; comparing basenames is the correct check here.
basename_in_scope() {
  local name="$1" scope="$2" s
  while IFS= read -r s; do
    [ -z "$s" ] && continue
    [ "${s##*/}" = "$name" ] && return 0
  done <<SCOPE
$scope
SCOPE
  return 1
}

check_one() {
  local id="$1" spec_rel spec_path scope full_paths bare_names p spec_hash
  spec_rel="$(jq -r --arg id "$id" '.tasks[]|select(.id==$id)|.spec // empty' "$BACKLOG")"
  [ -n "$spec_rel" ] || return 0
  spec_path="$ROOT/$spec_rel"
  [ -f "$spec_path" ] || { echo "WARN: $id — spec file $spec_rel is missing"; return 0; }
  scope="$(jq -r --arg id "$id" '.tasks[]|select(.id==$id)|.scope[]?' "$BACKLOG")"
  spec_hash="$(sha256_of_file "$spec_path")"

  # Extract candidate paths from the spec prose: backtick-quoted repo-relative paths (under any real
  # top-level dir — see PREFIX_ALT) and bare backtick-quoted filenames (`Foo.js`) — checked separately
  # below, since they need different matching rules.
  full_paths="$(grep -oE "\`($PREFIX_ALT)/[A-Za-z0-9_./-]+\`" "$spec_path" | tr -d '`' | sort -u)"
  # bare_names requires a REAL code/asset extension (not any `word.word` token) — an open-ended
  # `\.[A-Za-z0-9]+` suffix also matches CSS values (`0.3rem`) and property/method chains
  # (`workoutStats.totalVolume`, `Promise.all`, `console.log`) as if they were filenames. This still
  # can't tell "a real file, but only mentioned as read-only background" from "a real file the spec
  # means to edit" (e.g. a path cited as a SCOPE_EXEMPT_GLOBS reference) — that class needs the
  # mention's surrounding prose actually read, which is what implementation-harness-fix-scope-gaps'
  # judge fan-out is for.
  bare_names="$(grep -oE '\`[A-Za-z0-9_-]+\.(js|jsx|ts|tsx|mjs|cjs|vue|svelte|py|rb|go|java|kt|kts|swift|c|h|cc|cpp|hpp|cs|php|rs|sql|graphql|gql|css|scss|sass|less|html|htm|json|jsonc|yaml|yml|md|mdx|sh|bash|zsh|toml|xml|svg|env|txt|csv|ini|conf|lock|prisma|proto)\`' "$spec_path" | tr -d '`' | sort -u)"

  while IFS= read -r p; do
    [ -z "$p" ] && continue
    if ! in_scope "$p" "$scope" && ! is_dismissed "$id" "$p" "$spec_hash"; then
      echo "WARN: $id — spec mentions \`$p\` but it is not in this task's declared scope"
    fi
  done <<FULLPATHS
$full_paths
FULLPATHS

  while IFS= read -r p; do
    [ -z "$p" ] && continue
    if ! basename_in_scope "$p" "$scope" && ! is_dismissed "$id" "$p" "$spec_hash"; then
      echo "WARN: $id — spec mentions \`$p\` but no scope entry's filename matches it"
    fi
  done <<BARENAMES
$bare_names
BARENAMES

  # Defense-in-depth: flag scope ENTRIES whose glob shape the real gate can't honor, so an authoring
  # slip like `dir/**/*.ts` is caught HERE (at pre-loop-checkin) instead of silently failing every
  # build attempt as unrecoverable scope-creep. Mirrors "fail loud on a malformed config value".
  while IFS= read -r s; do
    [ -z "$s" ] && continue
    if unsupported_scope_shape "$s"; then
      echo "WARN: $id — scope entry \`$s\` uses an unsupported glob shape (supported: an exact path, \`dir/\`, \`dir/**\`, \`dir/*\`, or a single-level \`dir/*.ext\`)"
    fi
  done <<SCOPE
$scope
SCOPE
  return 0
}

if [ "${1:-}" != "" ]; then
  check_one "$1"
else
  # Only tasks PENDING EXECUTION — the ones the loop will actually build (the dashboard's Ready /
  # Waiting / Waiting-on-Human buckets, all `status:"pending"`). Terminal tasks (`done`, `failed`,
  # `blocked`) are excluded: the loop never re-selects them, so a scope-authoring gap on one can't
  # affect any run — flagging it is pure noise. (`failed`/`blocked` are NOT `done`, so the old
  # `status!="done"` filter wrongly swept them.) needs-human tasks are the human-step gate itself,
  # never loop-built, so they're excluded too — a pending task merely *waiting* on one is still
  # `status:"pending"`/`gate:null` and IS scanned.
  for id in $(jq -r '.tasks[]|select(.status=="pending")|select(.gate!="needs-human")|.id' "$BACKLOG"); do
    check_one "$id"
  done
fi
exit 0
