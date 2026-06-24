#!/usr/bin/env bash
#
# postflight.sh — read-only, ZERO-TOKEN status board for the single sequential loop.
#
# Counterpart to loop.sh: where loop.sh decides what to BUILD, postflight reports what
# the backlog looks like. It reads everything from `origin/main` (the integrated truth) —
# the same source loop.sh uses — plus the loop's branches/worklog, so the two never
# disagree. It never invokes Claude, so it's fast, reliable, and free to run every cycle.
#
# Output goes to stdout AND to .harness/worklog/STATUS.md (overwritten each run).
#
# Usage:  .harness/postflight.sh
# Exit:   0 always (a report is informational; it never fails a cycle).
set -uo pipefail

ROOT="$(git rev-parse --show-toplevel)"
NAME="$(basename "$ROOT")"
TASKS_REF="${TASKS_REF:-origin/main}"
STATUS_FILE="$ROOT/.harness/worklog/STATUS.md"
cd "$ROOT" || exit 0
mkdir -p .harness/worklog
git fetch origin --quiet 2>/dev/null || true

# All reads come from origin/main (mirrors loop.sh), so the board matches what runs.
# TASKS.json (schema: .harness/HARNESS.md §8.1) is parsed with jq — same as loop.sh.
command -v jq >/dev/null 2>&1 || { echo "[postflight] jq is required to parse TASKS.json — install it (e.g. brew install jq)" >&2; exit 0; }
blob()         { git show "$TASKS_REF:.harness/$1" 2>/dev/null || true; }
tj()           { blob TASKS.json | jq "$@" 2>/dev/null; }
all_tasks()    { tj -r '.tasks[].id'; }
task_done()    { tj -e --arg id "$1" '.tasks[]|select(.id==$id)|.status=="done"' >/dev/null; }
task_title()   { tj -r --arg id "$1" '.tasks[]|select(.id==$id)|.title'; }
task_model()   { tj -r --arg id "$1" '(.defaults.model // "") as $dm | .tasks[]|select(.id==$id)|(.model // $dm)'; }
deps_for()     { tj -r --arg id "$1" '.tasks[]|select(.id==$id)|.dependsOn[]?' | tr '\n' ' '; }
is_gate()      { tj -e --arg id "$1" '.tasks[]|select(.id==$id)|.gate=="gate"' >/dev/null; }
needs_human()  { tj -e --arg id "$1" '.tasks[]|select(.id==$id)|.gate=="needs-human"' >/dev/null; }
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
      m="$(task_model "$t")"; [ -n "$m" ] && m=" [$m]"
      board+=("  ▶︎  ready         $t  $title$m")
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
echo "   (saved to .harness/worklog/STATUS.md)"
exit 0
