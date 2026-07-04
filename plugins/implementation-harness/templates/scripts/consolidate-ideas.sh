#!/usr/bin/env bash
#
# consolidate-ideas.sh — Stage 3 of the ideas→tasks pipeline. The ONLY step that touches git/the
# repo lock (the per-idea conversion agents in Stage 2 write to independent .pending-tasks/*.json
# scratch files with no shared-resource contention, so they need no lock). Waits for the loop's
# lock rather than exiting immediately (an owner-triggered conversion should queue behind a
# running loop, not silently no-op).
#
# Usage: consolidate-ideas.sh   (no args — processes every .pending-tasks/*.json present)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOT="$(git -C "$HARNESS_DIR" rev-parse --show-toplevel)"
GIT_COMMON="$(git -C "$ROOT" rev-parse --git-common-dir)"
case "$GIT_COMMON" in /*) ;; *) GIT_COMMON="$ROOT/$GIT_COMMON" ;; esac
MAIN_BRANCH="${MAIN_BRANCH:-main}"

REPO_LOCK_WAIT=1
. "$SCRIPT_DIR/repo-lock.sh"

command -v node >/dev/null 2>&1 || { echo "node is required for the ideas pipeline" >&2; exit 3; }
command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 3; }

PENDING_DIR="$HARNESS_DIR/.pending-tasks"
if [ ! -d "$PENDING_DIR" ] || [ -z "$(ls -A "$PENDING_DIR" 2>/dev/null)" ]; then
  echo "consolidate-ideas: no pending task files — nothing to do"
  exit 0
fi

acquire_lock
trap 'release_lock' EXIT INT TERM

# Snapshot which files we're about to consume BEFORE running the .mjs, so we only delete what we
# actually processed (a new idea agent could theoretically drop a file mid-run).
files_before="$(ls "$PENDING_DIR"/*.json 2>/dev/null || true)"

node "$SCRIPT_DIR/consolidate-ideas.mjs"

# Refuse to commit a corrupt backlog: if the .mjs produced invalid JSON, stop here (the pending files
# are preserved for a retry) rather than committing+pushing a broken TASKS.json that would break the loop.
jq empty "$HARNESS_DIR/tracking/TASKS.json" 2>/dev/null || { echo "ABORT: consolidate produced invalid TASKS.json — not committing (pending files kept)." >&2; exit 1; }

git -C "$ROOT" add "$HARNESS_DIR/tracking/TASKS.json" "$HARNESS_DIR/tracking/IDEAS.md" "$HARNESS_DIR/tasks" 2>/dev/null || true
if git -C "$ROOT" commit -q --no-gpg-sign -m "consolidate-ideas: apply pending task conversions [skip ci]" 2>/dev/null; then
  # Reuse the shared push-with-retry (fetch+rebase between attempts) so a moved origin/main doesn't
  # lose the conversion to a single failed push, matching the mark-*.sh resilience.
  push_with_retry "$ROOT" "$MAIN_BRANCH" || { echo "WARN: commit made locally but push failed after retries — push $MAIN_BRANCH manually" >&2; exit 1; }
  echo "consolidate-ideas: committed + pushed"
else
  echo "consolidate-ideas: nothing to commit"
fi

# Clean up the consumed pending files only after a successful commit+push.
if [ -n "$files_before" ]; then
  printf '%s\n' "$files_before" | xargs rm -f
fi
