#!/usr/bin/env bash
#
# mark-reviewed.sh — owner CLI: set/clear the purely cosmetic "reviewed" flag on one or more
# tasks (tracking/reviews.json). The loop NEVER reads or writes this file — it exists only for a
# dashboard, or the owner's own bookkeeping, to track which "done" tasks have been eyeballed.
#
# Usage: mark-reviewed.sh TNNN [TNNN ...]        # mark reviewed
#        mark-reviewed.sh --undo TNNN [TNNN ...] # clear the reviewed flag
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOT="$(git -C "$HARNESS_DIR" rev-parse --show-toplevel)"
GIT_COMMON="$(git -C "$ROOT" rev-parse --git-common-dir)"
case "$GIT_COMMON" in /*) ;; *) GIT_COMMON="$ROOT/$GIT_COMMON" ;; esac

REPO_LOCK_WAIT=1
. "$SCRIPT_DIR/repo-lock.sh"

BACKLOG="$HARNESS_DIR/tracking/TASKS.json"
OVERLAY="$HARNESS_DIR/tracking/reviews.json"
command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 3; }

UNDO=0
if [ "${1:-}" = "--undo" ]; then UNDO=1; shift; fi
[ "$#" -ge 1 ] || { echo "usage: mark-reviewed.sh [--undo] TNNN [TNNN ...]" >&2; exit 2; }

for id in "$@"; do
  jq -e --arg id "$id" '.tasks[]|select(.id==$id)' "$BACKLOG" >/dev/null 2>&1 \
    || { echo "ABORT: $id is not a real task id in TASKS.json — no changes made." >&2; exit 1; }
done

acquire_lock
trap 'release_lock' EXIT INT TERM

[ -f "$OVERLAY" ] || echo '{}' >"$OVERLAY"
tmp="$OVERLAY.tmp"; cp "$OVERLAY" "$tmp"
ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
for id in "$@"; do
  if [ "$UNDO" = 1 ]; then
    jq --arg id "$id" --arg ts "$ts" '.[$id] = {reviewed: false, at: $ts}' "$tmp" >"$tmp.2" && mv "$tmp.2" "$tmp"
  else
    jq --arg id "$id" --arg ts "$ts" '.[$id] = {reviewed: true, at: $ts}' "$tmp" >"$tmp.2" && mv "$tmp.2" "$tmp"
  fi
done
jq empty "$tmp" || { echo "ABORT: overlay write produced invalid JSON — no changes made." >&2; rm -f "$tmp"; exit 1; }
mv "$tmp" "$OVERLAY"

git -C "$ROOT" add "$OVERLAY" 2>/dev/null || true
git -C "$ROOT" commit -q -m "mark-reviewed: $* [skip ci]" 2>/dev/null || { echo "nothing to commit"; exit 0; }
git -C "$ROOT" push origin HEAD 2>/dev/null || { echo "WARN: commit made locally but push failed — push manually" >&2; exit 1; }
echo "reviewed: $*"
