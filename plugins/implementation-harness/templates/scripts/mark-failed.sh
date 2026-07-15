#!/usr/bin/env bash
#
# mark-failed.sh — owner CLI: close out a task as a reviewed, non-success outcome. Two uses:
#   - overturn a "done" task as a false success (an audit-missed bug, a visual regression the
#     automated checks didn't catch, etc).
#   - close out a "blocked" task once implementation-harness-review-failed has investigated it
#     (already resolved elsewhere / a better-specified follow-up was authored / not worth pursuing) —
#     without this, a reviewed "blocked" task has no way to leave the dashboard's Human Tasks bucket.
# Writes the tracking/manual-fail.json overlay with a REQUIRED reason; the loop's reconcile_overlays()
# flips TASKS.json status to "failed" on its next iteration, and both calibration readers (policy.jq's
# tier branch and audit_gate's confirmed-audited-count query) subtract the overlay at read time so the
# false success stops inflating that (layer × work-type) cell's calibration — see
# docs/designs/manual-fail-signal.md. Both transitions land on status:"failed", which dashboard/lib.js's
# computeBacklog() already buckets into Done and tags implicitly reviewed. Terminal: this does NOT
# re-open the task; a human decides whether/how to redo it.
#
# Usage: mark-failed.sh TNNN "<reason>"
#        mark-failed.sh --undo TNNN
#        NO_PUSH=1 mark-failed.sh TNNN "<reason>"   # write+commit but don't push (offline use)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_LOCK_WAIT=1
. "$SCRIPT_DIR/overlay-edit.sh"   # sets ROOT/GIT_COMMON/MAIN_BRANCH/BACKLOG; provides overlay_edit

OVERLAY_REL="tracking/manual-fail.json"
command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 3; }

if [ "${1:-}" = "--undo" ]; then
  id="${2:-}"; [ -n "$id" ] || { echo "usage: mark-failed.sh --undo TNNN" >&2; exit 2; }
  _mark_failed_undo_mutate() { jq --arg id "$id" 'del(.[$id])' "$1" >"$1.2" && mv "$1.2" "$1"; }
  rc=0; overlay_edit "$OVERLAY_REL" _mark_failed_undo_mutate "mark-failed: undo $id [skip ci]" || rc=$?
  case "$rc" in
    0) [ -n "${NO_PUSH:-}" ] || echo "undone: $id" ;;
    2) echo "no change to commit (nothing to undo)" ;;
    *) exit "$rc" ;;
  esac
  exit 0
fi

# Reason = ALL trailing args, so an unquoted multi-word reason works (mark-failed.sh T1 padlock never
# renders) instead of silently keeping only the first word.
id="${1:-}"; shift 2>/dev/null || true; reason="$*"
[ -n "$id" ] && [ -n "$reason" ] || { echo "usage: mark-failed.sh TNNN \"<reason>\"" >&2; exit 2; }
jq -e --arg id "$id" '.tasks[]|select(.id==$id)|(.status=="done" or .status=="blocked")' "$BACKLOG" >/dev/null 2>&1 \
  || { echo "ABORT: $id is not currently status:\"done\" or status:\"blocked\" — no changes made." >&2; exit 1; }

_mark_failed_mutate() {
  local tmp="$1" ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  jq --arg id "$id" --arg reason "$reason" --arg ts "$ts" '.[$id] = {failed: true, reason: $reason, at: $ts}' "$tmp" >"$tmp.2" && mv "$tmp.2" "$tmp"
}
rc=0; overlay_edit "$OVERLAY_REL" _mark_failed_mutate "mark-failed: $id — $reason [skip ci]" || rc=$?
case "$rc" in
  0) [ -n "${NO_PUSH:-}" ] || echo "failed: $id ($reason) → $HARNESS_DIR/$OVERLAY_REL (committed + pushed; the loop applies it on its next iteration)" ;;
  2) echo "no change to commit (overlay already in that state)" ;;
  *) exit "$rc" ;;
esac
