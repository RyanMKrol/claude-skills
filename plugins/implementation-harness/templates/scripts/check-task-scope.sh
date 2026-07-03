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
command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 3; }

# in_scope <file> <scope-newline-list> — exact path or directory-prefix match, same rule the real
# structural scope gate in loop.sh / loop.in-place.sh uses.
in_scope() {
  local f="$1" scope="$2" s
  while IFS= read -r s; do
    [ -z "$s" ] && continue
    [ "$f" = "$s" ] && return 0
    [ "${f#"$s"/}" != "$f" ] && return 0
  done <<SCOPE
$scope
SCOPE
  return 1
}

check_one() {
  local id="$1" spec_rel spec_path scope paths hits=0 p
  spec_rel="$(jq -r --arg id "$id" '.tasks[]|select(.id==$id)|.spec // empty' "$BACKLOG")"
  [ -n "$spec_rel" ] || return 0
  spec_path="$ROOT/$spec_rel"
  [ -f "$spec_path" ] || { echo "WARN: $id — spec file $spec_rel is missing"; return 0; }
  scope="$(jq -r --arg id "$id" '.tasks[]|select(.id==$id)|.scope[]?' "$BACKLOG")"

  # Extract candidate paths from the spec prose: backtick-quoted repo-relative paths (src/...,
  # .harness/..., public/...) and bare backtick-quoted filenames (`Foo.js`).
  paths="$( { grep -oE '\`(src|\.harness|public|scripts|config|docs|tests?)/[A-Za-z0-9_./-]+\`' "$spec_path" | tr -d '`'
              grep -oE '\`[A-Za-z0-9_-]+\.[A-Za-z0-9]+\`' "$spec_path" | tr -d '`'
            } | sort -u)"
  [ -n "$paths" ] || return 0

  while IFS= read -r p; do
    [ -z "$p" ] && continue
    if ! in_scope "$p" "$scope"; then
      echo "WARN: $id — spec mentions \`$p\` but it is not in this task's declared scope"
      hits=$((hits + 1))
    fi
  done <<PATHS
$paths
PATHS
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
