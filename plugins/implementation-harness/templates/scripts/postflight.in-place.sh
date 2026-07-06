#!/usr/bin/env bash
#
# postflight.in-place.sh — read-only, ZERO-TOKEN status board for the IN-PLACE loop variant.
#
# Same board as postflight.sh, but for the in-place loop: that variant builds directly on the primary
# checkout's `main` (no isolation worktree, no per-task `tNNN` branches), so this reads the LOCAL
# checkout — the working truth — instead of `git show origin/main` blobs (which would be empty on a
# no-remote in-place install, and always stale relative to mid-task local state). In-flight is detected
# from a dirty working tree (a build in progress leaves uncommitted changes) rather than a task branch,
# which the in-place variant never creates.
#
# Both variants install under the name `postflight.sh`; create/upgrade pick the file by the loop variant.
#
# Output goes to stdout AND to .harness/worklog/STATUS.md (overwritten each run).
#
# Usage:  .harness/scripts/postflight.sh
# Exit:   0 always (a report is informational; it never fails a cycle).
set -uo pipefail

ROOT="$(git rev-parse --show-toplevel)"
NAME="$(basename "$ROOT")"
STATUS_FILE="$ROOT/.harness/worklog/STATUS.md"
cd "$ROOT" || exit 0
mkdir -p .harness/worklog

# All reads come from the LOCAL checkout (the in-place loop works directly on main), so the board
# matches what's on disk right now. TASKS.json schema: .harness/docs/HARNESS.md §8.1.
command -v jq >/dev/null 2>&1 || { echo "[postflight] jq is required to parse TASKS.json — install it (e.g. brew install jq)" >&2; exit 0; }
TASKS_FILE="$ROOT/.harness/tracking/TASKS.json"
WORKLOG="$ROOT/.harness/worklog"
tj()           { jq "$@" "$TASKS_FILE" 2>/dev/null; }
all_tasks()    { tj -r '.tasks[].id'; }
task_done()    { tj -e --arg id "$1" '.tasks[]|select(.id==$id)|.status=="done"' >/dev/null; }
task_title()   { tj -r --arg id "$1" '.tasks[]|select(.id==$id)|.title'; }
deps_for()     { tj -r --arg id "$1" '.tasks[]|select(.id==$id)|.dependsOn[]?' | tr '\n' ' '; }
needs_human()  { tj -e --arg id "$1" '.tasks[]|select(.id==$id)|.gate=="needs-human"' >/dev/null; }
# status="blocked"/"failed" are first-class TASKS.json values the LOOP sets (block_task / manual-fail
# reconcile) — check them directly, falling back to the legacy worklog marker, so the board matches the loop.
task_blocked() {
  tj -e --arg id "$1" '.tasks[]|select(.id==$id)|.status=="blocked"' >/dev/null 2>&1 && return 0
  [ -f "$WORKLOG/$1.md" ] && grep -qiE 'failed:blocked|needs-human' "$WORKLOG/$1.md"
}
task_failed()  { tj -e --arg id "$1" '.tasks[]|select(.id==$id)|.status=="failed"' >/dev/null; }
# In-place has no `tNNN` task branches; a dirty working tree means a build is mid-flight. (STATUS.md and
# the other worklog scratch are gitignored, so writing this board never dirties the tree.)
inprogress()   { [ -n "$(git status --porcelain 2>/dev/null)" ] && echo dirty || true; }

board=(); needs=(); ready=0; done_all=1
for t in $(all_tasks); do
  task_done "$t" && continue
  done_all=0
  title="$(task_title "$t")"
  if task_failed "$t"; then
    board+=("  ❌ failed        $t  $title")
    needs+=("$t — ❌ failed (owner overturned a false success): $title — the re-do is a separate follow-up task")
  elif needs_human "$t" || task_blocked "$t"; then
    board+=("  🔒 needs you     $t  $title")
    needs+=("$t — 🔒 needs-human: $title")
  else
    unmet=""
    for d in $(deps_for "$t"); do task_done "$d" || unmet="$unmet $d"; done
    if [ -n "$unmet" ]; then
      board+=("  ⏳ waiting deps  $t  (needs:${unmet} )")
    else
      board+=("  ▶︎  ready         $t  $title")
      ready=$((ready + 1))
    fi
  fi
done

ip="$(inprogress)"
: >"$STATUS_FILE"
out() { printf '%s\n' "$*"; printf '%s\n' "$*" >>"$STATUS_FILE"; }

out "# $NAME — loop status ($(date '+%Y-%m-%d %H:%M:%S'))"
out ""
if [ -n "$ip" ]; then out "🔨 In flight: the working tree is dirty (a task is mid-build / awaiting CI)."
else out "(clean working tree — the loop is between tasks or idle)"; fi
out ""
if [ "$done_all" -eq 1 ]; then
  out "✅ Every task in the backlog is done."
else
  out "## Backlog (not-done)"
  for l in ${board[@]+"${board[@]}"}; do out "$l"; done
  out ""
  out "$ready task(s) ready to build now."
fi
out ""
out "## Needs you"
if [ "${#needs[@]}" -eq 0 ]; then
  out "  (nothing — all clear)"
else
  for n in ${needs[@]+"${needs[@]}"}; do out "  $n"; done
fi

echo
echo "   (saved to .harness/worklog/STATUS.md)"
exit 0
