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
ROOT="$(git -C "$HARNESS_DIR" rev-parse --show-toplevel)"
GIT_COMMON="$(git -C "$ROOT" rev-parse --git-common-dir)"
case "$GIT_COMMON" in /*) ;; *) GIT_COMMON="$ROOT/$GIT_COMMON" ;; esac
MAIN_BRANCH="${MAIN_BRANCH:-main}"

REPO_LOCK_WAIT=1
. "$SCRIPT_DIR/repo-lock.sh"

BACKLOG="$HARNESS_DIR/tracking/TASKS.json"
OVERLAY="$HARNESS_DIR/tracking/manual-fail.json"
command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 3; }

if [ "${1:-}" = "--undo" ]; then
  id="${2:-}"; [ -n "$id" ] || { echo "usage: mark-failed.sh --undo TNNN" >&2; exit 2; }
  acquire_lock; trap 'release_lock' EXIT INT TERM
  [ -f "$OVERLAY" ] || echo '{}' >"$OVERLAY"
  jq --arg id "$id" 'del(.[$id])' "$OVERLAY" >"$OVERLAY.tmp" && mv "$OVERLAY.tmp" "$OVERLAY"
  git -C "$ROOT" add "$OVERLAY" 2>/dev/null || true
  if git -C "$ROOT" diff --cached --quiet -- "$OVERLAY" 2>/dev/null; then echo "no change to commit (nothing to undo)"; exit 0; fi
  git -C "$ROOT" commit -q --no-gpg-sign -m "mark-failed: undo $id [skip ci]" || { echo "ERROR: commit failed" >&2; exit 1; }
  push_with_retry "$ROOT" "$MAIN_BRANCH" || { echo "WARN: committed locally but push failed after retries — push $MAIN_BRANCH manually" >&2; exit 1; }
  [ -n "${NO_PUSH:-}" ] || echo "undone: $id"; exit 0
fi

# Reason = ALL trailing args, so an unquoted multi-word reason works (mark-failed.sh T1 padlock never
# renders) instead of silently keeping only the first word.
id="${1:-}"; shift 2>/dev/null || true; reason="$*"
[ -n "$id" ] && [ -n "$reason" ] || { echo "usage: mark-failed.sh TNNN \"<reason>\"" >&2; exit 2; }
jq -e --arg id "$id" '.tasks[]|select(.id==$id)|(.status=="done" or .status=="blocked")' "$BACKLOG" >/dev/null 2>&1 \
  || { echo "ABORT: $id is not currently status:\"done\" or status:\"blocked\" — no changes made." >&2; exit 1; }

acquire_lock
trap 'release_lock' EXIT INT TERM

[ -f "$OVERLAY" ] || echo '{}' >"$OVERLAY"
ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
jq --arg id "$id" --arg reason "$reason" --arg ts "$ts" '.[$id] = {failed: true, reason: $reason, at: $ts}' "$OVERLAY" >"$OVERLAY.tmp" \
  && jq empty "$OVERLAY.tmp" && mv "$OVERLAY.tmp" "$OVERLAY" || { rm -f "$OVERLAY.tmp"; echo "ABORT: overlay write failed" >&2; exit 1; }

git -C "$ROOT" add "$OVERLAY" 2>/dev/null || true
if git -C "$ROOT" diff --cached --quiet -- "$OVERLAY" 2>/dev/null; then echo "no change to commit (overlay already in that state)"; exit 0; fi
git -C "$ROOT" commit -q --no-gpg-sign -m "mark-failed: $id — $reason [skip ci]" || { echo "ERROR: commit failed — the overlay is written but not committed." >&2; exit 1; }
push_with_retry "$ROOT" "$MAIN_BRANCH" || { echo "WARN: committed locally but push failed after retries — push $MAIN_BRANCH manually" >&2; exit 1; }
[ -n "${NO_PUSH:-}" ] || echo "failed: $id ($reason) → $OVERLAY (committed + pushed; the loop applies it on its next iteration)"
