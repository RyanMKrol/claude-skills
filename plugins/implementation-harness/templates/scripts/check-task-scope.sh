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

# in_scope <file> <scope-newline-list> — exact path or directory-prefix match, same rule the real
# structural scope gate in loop.sh / loop.in-place.sh uses. For a FULL repo-relative path candidate.
in_scope() {
  local f="$1" scope="$2" s
  while IFS= read -r s; do
    [ -z "$s" ] && continue
    # Normalize glob-style scope entries to a bare directory prefix (`src/foo/**`, `src/foo/*`,
    # `src/foo/` all mean "under src/foo"), matching the real structural gate — else a glob-suffixed
    # scope entry produces false-positive WARNs for files it actually covers.
    s="${s%/}"; s="${s%/\*\*}"; s="${s%/\*}"
    [ "$f" = "$s" ] && return 0
    [ "${f#"$s"/}" != "$f" ] && return 0
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

  # Extract candidate paths from the spec prose: backtick-quoted repo-relative paths (src/...,
  # .harness/..., public/...) and bare backtick-quoted filenames (`Foo.js`) — checked separately
  # below, since they need different matching rules.
  full_paths="$(grep -oE '\`(src|\.harness|public|scripts|config|docs|tests?)/[A-Za-z0-9_./-]+\`' "$spec_path" | tr -d '`' | sort -u)"
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
  return 0
}

if [ "${1:-}" != "" ]; then
  check_one "$1"
else
  for id in $(jq -r '.tasks[]|select(.status!="done")|select(.gate!="needs-human")|.id' "$BACKLOG"); do
    check_one "$id"
  done
fi
exit 0
