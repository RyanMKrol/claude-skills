#!/usr/bin/env bash
#
# mark-done.sh — owner CLI: mark one or more needs-human tasks done (or undo). Writes the
# tracking/human-done.json overlay; the loop's reconcile_overlays() promotes it into TASKS.json
# status on its next iteration. Never edits TASKS.json directly — the loop is the sole writer of
# task status; this only records owner INTENT. This is the exact mechanism a dashboard's "mark
# done" button also shells out to, so a click and a manual CLI run take the identical code path.
#
# Usage: mark-done.sh T017 [T042 ...]        # mark one or more needs-human tasks done
#        mark-done.sh --undo T017            # remove the overlay entry (does not touch TASKS.json)
#        NO_PUSH=1 mark-done.sh T017         # write+commit but don't push (offline use)
#
# Multiple ids in one invocation are ATOMIC: every id is validated before any write, and the whole
# batch lands in exactly ONE commit (see mark-done-bulk.test.sh).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_LOCK_WAIT=1   # an owner action should wait for the loop's lock, not silently no-op
. "$SCRIPT_DIR/overlay-edit.sh"   # sets ROOT/GIT_COMMON/MAIN_BRANCH/BACKLOG; provides overlay_edit

OVERLAY_REL="tracking/human-done.json"

UNDO=0
if [ "${1:-}" = "--undo" ]; then UNDO=1; shift; fi
[ "$#" -ge 1 ] || { echo "usage: mark-done.sh [--undo] TNNN [TNNN ...]" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 3; }

# Fail-fast validation — every id must be real (and, unless --undo, a needs-human task) BEFORE
# any write, so a bad id in a batch aborts the WHOLE batch rather than partially applying it.
for id in "$@"; do
  jq -e --arg id "$id" '.tasks[]|select(.id==$id)' "$BACKLOG" >/dev/null 2>&1 \
    || { echo "ABORT: $id is not a real task id in TASKS.json — no changes made." >&2; exit 1; }
  if [ "$UNDO" = 0 ]; then
    jq -e --arg id "$id" '.tasks[]|select(.id==$id)|.gate=="needs-human"' "$BACKLOG" >/dev/null 2>&1 \
      || { echo "ABORT: $id is not a needs-human task — no changes made." >&2; exit 1; }
  fi
done

# mutate fn for overlay_edit — closes over IDS/UNDO (plain globals; bash functions see script-level
# vars). Captured into an array BEFORE the call since "$@" inside the mutate fn would be ITS OWN args.
IDS=("$@")
_mark_done_mutate() {
  local tmp="$1" id ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  for id in "${IDS[@]}"; do
    if [ "$UNDO" = 1 ]; then
      jq --arg id "$id" 'del(.[$id])' "$tmp" >"$tmp.2" && mv "$tmp.2" "$tmp"
    else
      jq --arg id "$id" --arg ts "$ts" '.[$id] = {done: true, at: $ts}' "$tmp" >"$tmp.2" && mv "$tmp.2" "$tmp"
    fi
  done
}
if [ "$UNDO" = 1 ]; then msg="mark-done: undo ${IDS[*]} [skip ci]"; else msg="mark-done: ${IDS[*]} [skip ci]"; fi

rc=0; overlay_edit "$OVERLAY_REL" _mark_done_mutate "$msg" || rc=$?
case "$rc" in
  0) [ -n "${NO_PUSH:-}" ] || echo "done: ${IDS[*]} → $HARNESS_DIR/$OVERLAY_REL (committed + pushed; the loop applies it on its next iteration)" ;;
  2) echo "no change to commit (overlay already in that state)" ;;
  *) exit "$rc" ;;
esac
