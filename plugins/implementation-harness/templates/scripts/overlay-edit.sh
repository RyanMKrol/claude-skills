#!/usr/bin/env bash
#
# overlay-edit.sh — shared machinery for the owner-overlay CLIs (mark-done.sh, mark-failed.sh,
# mark-reviewed.sh), extracted because the three scripts shared a ~70% hand-maintained skeleton:
# path derivation, lock acquisition + signal traps, overlay-file init, jq edit + validate, staged-
# diff no-op check, pathspec-scoped commit, push_with_retry, messaging. B02 (traps) and B05
# (branch guard + pathspec commit) land ONCE here instead of three times (C03).
#
# Source this file (it sources repo-lock.sh itself), THEN call:
#   overlay_edit <overlay-relpath> <mutate-fn> <commit-msg>
# where <mutate-fn> is a function name the caller defines, called as `mutate-fn <tmp-file>` — it
# must mutate <tmp-file> IN PLACE (typically one or more `jq ... "$1" >"$1.2" && mv "$1.2" "$1"`
# calls; the caller owns any per-id looping, e.g. a bulk mark-done batch). overlay_edit then:
#   - refuses if HEAD isn't on $MAIN_BRANCH (B05 — never publish whatever branch/WIP is checked out);
#   - acquires the repo lock (REPO_LOCK_WAIT semantics are the CALLER's — set it before sourcing)
#     and installs the exit-cleanly signal traps (B02), releasing on every path;
#   - seeds the overlay file with '{}' if absent, copies to a tmp file, runs the mutate-fn;
#   - jq-validates the result — invalid JSON aborts, the real overlay file is left untouched;
#   - no-op exits (return 2) if the staged diff is empty — nothing to commit;
#   - commits with an EXPLICIT PATHSPEC on just the overlay file (B05 — never sweep up unrelated
#     staged changes) using --no-gpg-sign, then push_with_retry.
# Return codes: 0 = committed + pushed; 2 = no-op (nothing changed); 1 = hard failure (branch guard,
# invalid JSON, commit, or push all print their own message to stderr).
#
# Requires HARNESS_DIR to already be set by the caller (it derives ROOT/GIT_COMMON/MAIN_BRANCH/
# BACKLOG off of it here, once, instead of each of the three callers repeating the derivation).
set -uo pipefail

: "${HARNESS_DIR:?overlay-edit.sh: HARNESS_DIR must be set by the caller before sourcing}"
ROOT="$(git -C "$HARNESS_DIR" rev-parse --show-toplevel)"
GIT_COMMON="$(git -C "$ROOT" rev-parse --git-common-dir)"
case "$GIT_COMMON" in /*) ;; *) GIT_COMMON="$ROOT/$GIT_COMMON" ;; esac
MAIN_BRANCH="${MAIN_BRANCH:-main}"
BACKLOG="$HARNESS_DIR/tracking/TASKS.json"

_OVERLAY_EDIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$_OVERLAY_EDIT_DIR/repo-lock.sh"

overlay_edit() {
  local rel="$1" mutate="$2" msg="$3" overlay tmp cur mrc
  overlay="$HARNESS_DIR/$rel"

  # B05: never publish whatever branch (and whatever WIP is on it) the checkout happens to be on —
  # push_with_retry rebases + pushes THE CURRENT BRANCH onto origin/$MAIN_BRANCH.
  cur="$(git -C "$ROOT" symbolic-ref --short -q HEAD || echo DETACHED)"
  if [ "$cur" != "$MAIN_BRANCH" ]; then
    echo "ERROR: checkout is on '$cur', not $MAIN_BRANCH — refusing to publish. Switch to $MAIN_BRANCH (or stash your work) and re-run." >&2
    return 1
  fi

  # acquire_lock only ever RETURNS nonzero in the REPO_LOCK_WAIT=1 + REPO_LOCK_MAX_WAIT-exceeded
  # path (the no-wait "another process holds it" path calls `exit 0` directly, by its own contract) —
  # but that return must still be checked here, or a timed-out wait would fall through and mutate the
  # overlay without ever actually holding the lock.
  if ! acquire_lock; then
    echo "ERROR: could not acquire the repo lock — try again once the loop/another owner action finishes." >&2
    return 1
  fi
  # See B02: a trap without `exit` doesn't stop the script — Ctrl-C/kill would release the lock and
  # then keep running.
  trap 'release_lock' EXIT
  trap 'release_lock; trap - EXIT; exit 130' INT
  trap 'release_lock; trap - EXIT; exit 143' TERM

  [ -f "$overlay" ] || echo '{}' >"$overlay"
  tmp="$overlay.tmp"
  cp "$overlay" "$tmp"
  # Capture the mutate fn's OWN exit status explicitly (don't rely on `set -e` propagating through
  # this call — it doesn't reliably, since overlay_edit itself is invoked via `|| rc=$?` by every
  # caller) — a mutate failure (e.g. its jq program errors) must abort loudly, never silently no-op
  # by leaving $tmp as the untouched copy.
  mrc=0; "$mutate" "$tmp" || mrc=$?
  if [ "$mrc" != 0 ] || ! jq empty "$tmp" 2>/dev/null; then
    echo "ABORT: overlay write produced invalid JSON — no changes made." >&2
    rm -f "$tmp"
    trap - EXIT INT TERM; release_lock
    return 1
  fi
  mv "$tmp" "$overlay"

  git -C "$ROOT" add "$overlay" 2>/dev/null || true
  # Distinguish "no change" from "commit errored": check the staged diff FIRST, then commit
  # hard-failing on error (--no-gpg-sign avoids a signing prompt/failure silently aborting it).
  if git -C "$ROOT" diff --cached --quiet -- "$overlay" 2>/dev/null; then
    trap - EXIT INT TERM; release_lock
    return 2
  fi
  # B05: an explicit pathspec means ONLY the overlay file is committed — any unrelated file the
  # owner happened to have staged rides along otherwise (`git commit` with no pathspec commits
  # everything staged, not just what THIS script edited).
  if ! git -C "$ROOT" commit -q --no-gpg-sign -m "$msg" -- "$overlay"; then
    echo "ERROR: commit failed — the overlay is written but not committed." >&2
    trap - EXIT INT TERM; release_lock
    return 1
  fi
  if ! push_with_retry "$ROOT" "$MAIN_BRANCH"; then
    echo "WARN: committed locally but push failed after retries — push $MAIN_BRANCH manually" >&2
    trap - EXIT INT TERM; release_lock
    return 1
  fi
  trap - EXIT INT TERM
  release_lock
  return 0
}
