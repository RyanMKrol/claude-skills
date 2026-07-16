#!/usr/bin/env bash
#
# scope-gap-dismiss.sh <task_id> <path> [reason] — record (or refresh) a scope-gap FALSE-POSITIVE
# dismissal so check-task-scope.sh (and therefore pre-loop-checkin) stops re-flagging <path> for
# <task_id> while that task's spec is unchanged. Writes the gitignored per-task scratch file
# .harness/.scope-gap-ignores/<id>.json — never committed. Idempotent: replaces any existing entry
# for the same <path> (so repeated runs don't grow the file). The ONLY writer of these files;
# check-task-scope.sh is the reader (is_dismissed matches on .path + .specHash).
#
# WHY THIS IS A SCRIPT (not an inline command in harness-fix-scope-gaps' step 6):
# the dismissal `reason` is free-form, house-style prose that routinely contains non-ASCII (em dashes).
# Interpolating that into a MULTI-LINE shell command handed to an agent's Bash tool intermittently
# corrupts the shell's parsing of the FOLLOWING lines — every command after the multibyte character
# becomes "command not found" (a real, reproduced failure). Passing the reason as a single positional
# argument to this script, invoked on ONE line, keeps the free text off any multi-line shell program.
# The heavy jq/hash/nested-command-substitution logic lives here, quoted once and correctly.
#
# Field/format/path contract MUST stay in lockstep with check-task-scope.sh (HARNESS_DIR, IGNORES_DIR,
# spec_path=$ROOT/$spec_rel, sha256_of_file, {path,specHash} match). scope-gap-dismiss.test.sh locks
# the round-trip (dismiss → suppressed) so the two can't silently drift.
set -euo pipefail

id="${1:-}"; path="${2:-}"; reason="${3:-}"
[ -n "$id" ] && [ -n "$path" ] || { echo "usage: scope-gap-dismiss.sh <task_id> <path> [reason]" >&2; exit 2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"                      # mirrors check-task-scope.sh
ROOT="$(git -C "$HARNESS_DIR" rev-parse --show-toplevel)"
BACKLOG="$HARNESS_DIR/tracking/TASKS.json"
IGNORES_DIR="$HARNESS_DIR/.scope-gap-ignores"
command -v jq >/dev/null 2>&1 || { echo "scope-gap-dismiss: jq is required" >&2; exit 3; }

sha256_of_file() {   # identical to check-task-scope.sh's, so the specHash matches
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  else shasum -a 256 "$1" | awk '{print $1}'
  fi
}

spec_rel="$(jq -r --arg id "$id" '.tasks[]|select(.id==$id)|.spec // empty' "$BACKLOG")"
[ -n "$spec_rel" ] || { echo "scope-gap-dismiss: task $id not found (or has no spec) in $BACKLOG" >&2; exit 1; }
spec_path="$ROOT/$spec_rel"
[ -f "$spec_path" ] || { echo "scope-gap-dismiss: spec file $spec_rel missing for $id" >&2; exit 1; }
spec_hash="$(sha256_of_file "$spec_path")"

mkdir -p "$IGNORES_DIR"
f="$IGNORES_DIR/$id.json"
[ -f "$f" ] || printf '{"dismissed":[]}' >"$f"
at="$(date +%Y-%m-%d)"

tmp="$f.tmp"
jq --arg p "$path" --arg h "$spec_hash" --arg r "$reason" --arg d "$at" '
  .dismissed = ((.dismissed // []) | map(select(.path != $p)) + [{"path":$p,"specHash":$h,"reason":$r,"at":$d}])
' "$f" >"$tmp" && mv "$tmp" "$f"

echo "dismissed: $id  $path  (specHash ${spec_hash:0:12}…)"
