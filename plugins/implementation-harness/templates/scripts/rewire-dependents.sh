#!/usr/bin/env bash
#
# rewire-dependents.sh — repair a task STRANDED on a terminal (failed/blocked) dependency.
#
# WHY THIS EXISTS: /review-failed's step 4d rewires a failed task's dependents, but ONLY while that task
# is still in its worklist (failed/blocked AND not-yet-`reviewed`). Once a failed task is marked
# `reviewed`, Stage 1 excludes it forever, so step 4d can never re-fire — any dependent still pointing at
# it is stranded with no in-skill path to fix it (nothing records a dead→replacement mapping either).
# `pre-loop-checkin`'s stranded-on-failure scan DETECTS these and prints the exact command below; this
# script is the owner-driven FIX. (New stranding is already prevented at review time by step 4d; this is
# for the legacy / "owner chose to leave them" cases that predate or opt out of that.)
#
# Usage (run with the loop STOPPED — this edits the backlog the loop owns):
#   rewire-dependents.sh <stranded_id> <dead_dep> <new_dep>   # REWIRE: swap dead_dep → new_dep in dependsOn
#   rewire-dependents.sh <stranded_id> <dead_dep> --drop      # DROP:   remove dead_dep from dependsOn (it was spurious)
#   rewire-dependents.sh <stranded_id> --abandon "<reason>"   # ABANDON: mark the stranded task itself failed (manual-fail overlay; reverse with mark-failed.sh --undo)
#
# rewire/drop edit .harness/tracking/TASKS.json (dependsOn) and commit+push; --abandon writes the
# tracking/manual-fail.json overlay (reversible). NO_PUSH=1 commits without pushing (offline).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOT="$(git -C "$HARNESS_DIR" rev-parse --show-toplevel)"
BACKLOG="$HARNESS_DIR/tracking/TASKS.json"
MAIN_BRANCH="${MAIN_BRANCH:-main}"
command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 3; }

usage() {
  echo "usage: rewire-dependents.sh <stranded_id> <dead_dep> <new_dep>|--drop" >&2
  echo "       rewire-dependents.sh <stranded_id> --abandon \"<reason>\"" >&2
  exit 2
}

id="${1:-}"; [ -n "$id" ] || usage
[ -f "$BACKLOG" ] || { echo "rewire-dependents: no TASKS.json at $BACKLOG" >&2; exit 1; }

# Refuse while the loop is running — this mutates TASKS.json, exactly what the loop reads/writes (same
# guardrail as fix-scope-gaps). The owner runs this pre-loop, from pre-loop-checkin's report.
GC="$(git -C "$ROOT" rev-parse --git-common-dir)"; case "$GC" in /*) ;; *) GC="$ROOT/$GC";; esac
LOCK="$GC/$(basename "$ROOT")-loop.lock"
if [ -d "$LOCK" ]; then
  lpid="$(cat "$LOCK/pid" 2>/dev/null || true)"
  if [ -n "$lpid" ] && kill -0 "$lpid" 2>/dev/null; then
    echo "rewire-dependents: the loop is running (lock held by PID $lpid) — stop it first; this edits TASKS.json." >&2; exit 1
  fi
fi

jq -e --arg id "$id" '.tasks[]|select(.id==$id)' "$BACKLOG" >/dev/null 2>&1 \
  || { echo "rewire-dependents: no task $id in TASKS.json" >&2; exit 1; }

commit_push() {   # <file-to-stage> <commit-msg>
  git -C "$ROOT" add "$1"
  if git -C "$ROOT" diff --cached --quiet -- "$1" 2>/dev/null; then echo "no change to commit (already in that state)"; exit 0; fi
  git -C "$ROOT" commit -q --no-gpg-sign -m "$2 [skip ci]" || { echo "ERROR: commit failed" >&2; exit 1; }
  [ -n "${NO_PUSH:-}" ] || git -C "$ROOT" push -q origin "HEAD:$MAIN_BRANCH" 2>/dev/null || echo "WARN: committed locally but push failed — push $MAIN_BRANCH manually" >&2
}

case "${2:-}" in
  --abandon)
    reason="${3:-}"; [ -n "$reason" ] || { echo "rewire-dependents: --abandon needs a reason" >&2; usage; }
    OVERLAY="$HARNESS_DIR/tracking/manual-fail.json"
    [ -f "$OVERLAY" ] || echo '{}' >"$OVERLAY"
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    jq --arg id "$id" --arg r "$reason" --arg ts "$ts" '.[$id] = {failed: true, reason: $r, at: $ts}' "$OVERLAY" >"$OVERLAY.tmp" \
      && jq empty "$OVERLAY.tmp" && mv "$OVERLAY.tmp" "$OVERLAY" || { rm -f "$OVERLAY.tmp"; echo "ABORT: overlay write failed" >&2; exit 1; }
    commit_push "$OVERLAY" "rewire-dependents: abandon $id — $reason"
    echo "abandoned: $id (manual-fail overlay; the loop marks it failed on its next iteration — reverse with mark-failed.sh --undo $id)"
    ;;
  ""|--drop) usage ;;   # rewire/drop need <dead_dep> in the 2nd slot (…<dead_dep> --drop), not --drop alone
  *)
    dead="$2"; target="${3:-}"; [ -n "$target" ] || usage
    jq -e --arg id "$id" --arg d "$dead" '.tasks[]|select(.id==$id)|((.dependsOn // [])|index($d))' "$BACKLOG" >/dev/null 2>&1 \
      || { echo "rewire-dependents: $id does not depend on $dead — nothing to rewire." >&2; exit 1; }
    tmp="$BACKLOG.tmp"
    if [ "$target" = --drop ]; then
      jq --arg id "$id" --arg d "$dead" \
        '(.tasks[]|select(.id==$id)|.dependsOn) |= ((. // []) | map(select(. != $d)))' "$BACKLOG" >"$tmp"
      msg="rewire-dependents: drop dead dep $dead from $id"
    else
      jq -e --arg t "$target" '.tasks[]|select(.id==$t)' "$BACKLOG" >/dev/null 2>&1 \
        || { echo "rewire-dependents: replacement $target is not a task in TASKS.json" >&2; exit 1; }
      # swap dead→target, then de-dup preserving order (in case target was already a dep)
      jq --arg id "$id" --arg d "$dead" --arg t "$target" \
        '(.tasks[]|select(.id==$id)|.dependsOn) |=
           ((. // []) | map(if . == $d then $t else . end) | reduce .[] as $x ([]; if index($x) then . else . + [$x] end))' \
        "$BACKLOG" >"$tmp"
      msg="rewire-dependents: $id dependsOn $dead → $target"
    fi
    jq -e '.tasks|length' "$tmp" >/dev/null 2>&1 || { echo "rewire-dependents: write produced invalid JSON — aborting." >&2; rm -f "$tmp"; exit 1; }
    mv "$tmp" "$BACKLOG"
    commit_push "$BACKLOG" "$msg"
    echo "$msg"
    ;;
esac
