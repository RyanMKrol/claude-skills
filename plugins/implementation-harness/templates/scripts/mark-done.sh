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
#
# Multiple ids in one invocation are ATOMIC: every id is validated before any write, and the whole
# batch lands in exactly ONE commit (see mark-done-bulk.test.sh).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOT="$(git -C "$HARNESS_DIR" rev-parse --show-toplevel)"
GIT_COMMON="$(git -C "$ROOT" rev-parse --git-common-dir)"
case "$GIT_COMMON" in /*) ;; *) GIT_COMMON="$ROOT/$GIT_COMMON" ;; esac

REPO_LOCK_WAIT=1   # an owner action should wait for the loop's lock, not silently no-op
. "$SCRIPT_DIR/repo-lock.sh"

BACKLOG="$HARNESS_DIR/tracking/TASKS.json"
OVERLAY="$HARNESS_DIR/tracking/human-done.json"

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

acquire_lock
trap 'release_lock' EXIT INT TERM

[ -f "$OVERLAY" ] || echo '{}' >"$OVERLAY"
tmp="$OVERLAY.tmp"
cp "$OVERLAY" "$tmp"
ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
for id in "$@"; do
  if [ "$UNDO" = 1 ]; then
    jq --arg id "$id" 'del(.[$id])' "$tmp" >"$tmp.2" && mv "$tmp.2" "$tmp"
  else
    jq --arg id "$id" --arg ts "$ts" '.[$id] = {done: true, at: $ts}' "$tmp" >"$tmp.2" && mv "$tmp.2" "$tmp"
  fi
done
jq empty "$tmp" || { echo "ABORT: overlay write produced invalid JSON — no changes made." >&2; rm -f "$tmp"; exit 1; }
mv "$tmp" "$OVERLAY"

git -C "$ROOT" add "$OVERLAY" 2>/dev/null || true
if [ "$UNDO" = 1 ]; then msg="mark-done: undo $* [skip ci]"; else msg="mark-done: $* [skip ci]"; fi
git -C "$ROOT" commit -q -m "$msg" 2>/dev/null || { echo "nothing to commit"; exit 0; }
git -C "$ROOT" push origin HEAD 2>/dev/null || { echo "WARN: commit made locally but push failed — push manually" >&2; exit 1; }
echo "done: $* → $OVERLAY (committed + pushed; the loop applies it on its next iteration)"
