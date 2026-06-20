#!/usr/bin/env bash
#
# postflight.sh — read-only, ZERO-TOKEN status board for the single sequential loop.
#
# Counterpart to loop.sh: where loop.sh decides what to BUILD, postflight reports what
# the backlog looks like. It reads everything from `origin/main` (the integrated truth) —
# the same source loop.sh uses — plus the loop's branches/worklog, so the two never
# disagree. It never invokes Claude, so it's fast, reliable, and free to run every cycle.
#
# Output goes to stdout AND to worklog/STATUS.md (overwritten each run).
#
# Usage:  scripts/postflight.sh
# Exit:   0 always (a report is informational; it never fails a cycle).
set -uo pipefail

ROOT="$(git rev-parse --show-toplevel)"
NAME="$(basename "$ROOT")"
TASKS_REF="${TASKS_REF:-origin/main}"
STATUS_FILE="$ROOT/worklog/STATUS.md"
cd "$ROOT" || exit 0
mkdir -p worklog
git fetch origin --quiet 2>/dev/null || true

# All reads come from origin/main (mirrors loop.sh), so the board matches what runs.
blob()         { git show "$TASKS_REF:$1" 2>/dev/null || true; }
task_done()    { blob TASKS.md | grep -qE "^- \[x\] $1( |\$)"; }
all_tasks()    { blob TASKS.md | grep -oE '^- \[[ x~]\] T[0-9]{3,}' | grep -oE 'T[0-9]{3,}'; }
task_title()   { blob TASKS.md | grep -m1 -E "^- \[[ x~]\] $1 " | sed -E "s/^- \[[ x~]\] $1 +//" | sed -E 's/[[:space:]]*🚦.*$//; s/[[:space:]]*🔒.*$//'; }
deps_for()     { blob TASKS.md | sed -n "/^### $1 /,/^### T[0-9]/p" | grep -im1 'Depends on' | grep -oE 'T[0-9]{3,}' | tr '\n' ' '; }
is_gate()      { blob TASKS.md | grep -m1 -E "^- \[[ x~]\] $1 " | grep -q '🚦'; }
needs_human()  { blob TASKS.md | grep -m1 -E "^- \[[ x~]\] $1 " | grep -q '🔒'; }
task_blocked() { blob "worklog/$1.md" | grep -qiE 'failed:blocked|needs-human'; }
inprogress()   { git branch --format='%(refname:short)' | grep -E '^t[0-9]{3,}$' | head -1 || true; }

board=(); needs=(); ready=0; done_all=1
for t in $(all_tasks); do
  task_done "$t" && continue
  done_all=0
  title="$(task_title "$t")"
  if is_gate "$t"; then
    board+=("  🚦 gate         $t  $title")
    needs+=("$t — 🚦 gate: review the deliverable before dependents proceed ($title)")
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
if [ -n "$ip" ]; then out "🔨 In flight: branch \`$ip\` (a task is mid-build / awaiting CI)."
else out "(no task branch in flight — the loop is between tasks or idle)"; fi
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
echo "   (saved to worklog/STATUS.md)"
exit 0
