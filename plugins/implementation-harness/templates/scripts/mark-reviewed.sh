#!/usr/bin/env bash
#
# mark-reviewed.sh — owner CLI: set/clear the purely cosmetic "reviewed" flag on one or more
# tasks (tracking/reviews.json). The loop NEVER reads or writes this file — it exists only for a
# dashboard, or the owner's own bookkeeping, to track which "done" tasks have been eyeballed.
#
# Usage: mark-reviewed.sh TNNN [TNNN ...]        # mark reviewed
#        mark-reviewed.sh --undo TNNN [TNNN ...] # clear the reviewed flag
#        NO_PUSH=1 mark-reviewed.sh TNNN         # write+commit but don't push (offline use)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_LOCK_WAIT=1
. "$SCRIPT_DIR/overlay-edit.sh"   # sets ROOT/GIT_COMMON/MAIN_BRANCH/BACKLOG; provides overlay_edit

OVERLAY_REL="tracking/reviews.json"
command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 3; }

UNDO=0
if [ "${1:-}" = "--undo" ]; then UNDO=1; shift; fi
[ "$#" -ge 1 ] || { echo "usage: mark-reviewed.sh [--undo] TNNN [TNNN ...]" >&2; exit 2; }

for id in "$@"; do
  jq -e --arg id "$id" '.tasks[]|select(.id==$id)' "$BACKLOG" >/dev/null 2>&1 \
    || { echo "ABORT: $id is not a real task id in TASKS.json — no changes made." >&2; exit 1; }
done

# mutate fn for overlay_edit — closes over IDS/UNDO (plain globals). Captured into an array BEFORE
# the call since "$@" inside the mutate fn would be ITS OWN args.
IDS=("$@")
_mark_reviewed_mutate() {
  local tmp="$1" id ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  for id in "${IDS[@]}"; do
    if [ "$UNDO" = 1 ]; then
      # Undo REMOVES the entry entirely (not {reviewed:false}) so reviews.json doesn't grow unbounded
      # with cleared flags — key-absent and reviewed:false are equivalent to every reader.
      jq --arg id "$id" 'del(.[$id])' "$tmp" >"$tmp.2" && mv "$tmp.2" "$tmp"
    else
      jq --arg id "$id" --arg ts "$ts" '.[$id] = {reviewed: true, at: $ts}' "$tmp" >"$tmp.2" && mv "$tmp.2" "$tmp"
    fi
  done
}

rc=0; overlay_edit "$OVERLAY_REL" _mark_reviewed_mutate "mark-reviewed: ${IDS[*]} [skip ci]" || rc=$?
case "$rc" in
  0) [ -n "${NO_PUSH:-}" ] || echo "reviewed: ${IDS[*]}" ;;
  2) echo "no change to commit (already in that state)" ;;
  *) exit "$rc" ;;
esac
