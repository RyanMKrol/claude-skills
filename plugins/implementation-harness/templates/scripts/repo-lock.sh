#!/usr/bin/env bash
#
# repo-lock.sh — shared mkdir-based lock so the loop and any ancillary script that writes to this
# repo (mark-done.sh, mark-failed.sh, mark-reviewed.sh, consolidate-ideas.sh) never race each
# other's git operations. Source it, then call acquire_lock / release_lock — every caller derives
# the lock path from ROOT + GIT_COMMON (set by the caller before calling), so it can never drift
# between scripts.
#
# acquire_lock — mkdir-based acquire. By default EXITS THE WHOLE PROCESS immediately if the lock is
#                held (the loop's behaviour: don't queue, just skip this run). Set REPO_LOCK_WAIT=1
#                before calling to retry/wait instead (what ancillary scripts want — they'd rather
#                wait a few seconds for the loop than silently no-op).
# release_lock — safe to call even if this PID never held the lock.
#
# Run this file directly with --selftest to exercise acquire/release + stale-PID reclaim in a
# throwaway repo (used by the create-harness validation gate).
set -uo pipefail

acquire_lock() {
  : "${ROOT:?acquire_lock: ROOT must be set}"; : "${GIT_COMMON:?acquire_lock: GIT_COMMON must be set}"
  LOCK="$GIT_COMMON/$(basename "$ROOT")-loop.lock"
  local waited=0 retry="${REPO_LOCK_RETRY:-2}"
  while ! mkdir "$LOCK" 2>/dev/null; do
    local owner; owner="$(cat "$LOCK/pid" 2>/dev/null || true)"
    if [ -n "$owner" ] && ! kill -0 "$owner" 2>/dev/null; then
      echo "[repo-lock] stale lock (dead PID $owner) — reclaiming" >&2
      rm -f "$LOCK/pid"; rmdir "$LOCK" 2>/dev/null || true
      continue
    fi
    if [ "${REPO_LOCK_WAIT:-0}" != "1" ]; then
      echo "[repo-lock] another process holds the lock (PID ${owner:-?}) — exiting." >&2
      exit 0
    fi
    sleep "$retry"; waited=$((waited + retry))
    if [ -n "${REPO_LOCK_MAX_WAIT:-}" ] && [ "$waited" -ge "${REPO_LOCK_MAX_WAIT}" ]; then
      echo "[repo-lock] gave up waiting after ${waited}s (held by PID ${owner:-?})" >&2
      return 1
    fi
  done
  echo "$$" >"$LOCK/pid"
}

release_lock() {
  [ -n "${LOCK:-}" ] && [ -f "$LOCK/pid" ] && [ "$(cat "$LOCK/pid" 2>/dev/null)" = "$$" ] \
    && { rm -f "$LOCK/pid"; rmdir "$LOCK" 2>/dev/null || true; } || true
}

# push_with_retry <dir> <branch> — push HEAD to origin/<branch>, retrying up to 3x with a
# fetch+rebase between attempts (handles the remote moving under us — e.g. the loop or another
# owner action pushed first). Honors NO_PUSH=1 (commit-only, offline use) by skipping the push
# entirely and returning success. Used by the mark-*.sh owner CLIs.
push_with_retry() {
  local dir="$1" branch="$2" ok=0 i
  if [ -n "${NO_PUSH:-}" ]; then echo "committed (NO_PUSH set — not pushed)"; return 0; fi
  for i in 1 2 3; do
    git -C "$dir" fetch origin >/dev/null 2>&1 || true
    git -C "$dir" rebase "origin/$branch" >/dev/null 2>&1 || git -C "$dir" rebase --abort >/dev/null 2>&1 || true
    if git -C "$dir" push origin "HEAD:$branch" >/dev/null 2>&1; then ok=1; break; fi
  done
  [ "$ok" = 1 ]
}

_repo_lock_selftest() {
  local tmp rc=0; tmp="$(mktemp -d)"
  git init -q "$tmp"
  (
    set -e
    ROOT="$tmp"; GIT_COMMON="$tmp/.git"
    acquire_lock
    [ -d "$GIT_COMMON/$(basename "$ROOT")-loop.lock" ] || { echo "selftest FAIL: lock dir missing after acquire"; exit 1; }
    release_lock
    [ -d "$GIT_COMMON/$(basename "$ROOT")-loop.lock" ] && { echo "selftest FAIL: lock dir still present after release"; exit 1; }
    mkdir -p "$GIT_COMMON/$(basename "$ROOT")-loop.lock"
    echo 999999 >"$GIT_COMMON/$(basename "$ROOT")-loop.lock/pid"   # simulate a stale/dead-PID holder
    acquire_lock
    [ -d "$GIT_COMMON/$(basename "$ROOT")-loop.lock" ] || { echo "selftest FAIL: did not reclaim a stale lock"; exit 1; }
    release_lock
    echo "repo-lock self-test OK (acquire/release/stale-PID reclaim)"
  ) || rc=1
  rm -rf "$tmp"
  return $rc
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  case "${1:-}" in
    --selftest) _repo_lock_selftest; exit $? ;;
    *) echo "usage: source repo-lock.sh (after setting ROOT + GIT_COMMON), or run: repo-lock.sh --selftest" >&2; exit 2 ;;
  esac
fi
