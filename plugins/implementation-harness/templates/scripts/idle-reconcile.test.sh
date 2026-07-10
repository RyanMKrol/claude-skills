#!/usr/bin/env bash
#
# idle-reconcile.test.sh — regression guard for a HIGH-severity full-loop stall in BOTH loop variants.
#
# THE BUG (fixed): the `idle` verdict is PER-TASK ("this one task's Done-when is already met on main —
# nothing to build"), but the old handler treated it as GLOBAL ("backlog drained") and did `exit 0`,
# ending the whole cycle with other ready tasks unbuilt. Worse, it was STICKY: the trigger is a task whose
# work reached main but whose status stayed `pending` (a lost status flip), and select_task keys on
# status, so every subsequent cycle re-selected the same task, got `idle`, and exited again — a silent,
# permanent stall until a human intervened.
#
# THE FIX asserted here (both variants):
#   1. the idle handler no longer exits — it RECONCILES the one task (re-does the lost status=done flip:
#      record_outcome false in the worktree variant / mark_done in the in-place variant) and continues;
#   2. a consecutive-idle GUARD (idle_task/idle_count) BLOCKs a task that keeps reporting idle (its flip
#      won't persist) after 2, so it can never spin forever;
#   3. the status flip is hardened to PERSIST-OR-SHOUT (status_done_on_remote verify + retry + loud ERROR),
#      attacking the root-cause divergence at its source;
#   4. the ONLY exit-on-nothing-to-do is still the legitimate select_task-empty drain path.
#
# WHY STATIC (grep the source), like loop-nounset.test.sh: the full dispatch loop can't run in the plugin's
# CI without a live claude CLI, a GitHub remote + CI, and gh — so a behavioral end-to-end test isn't
# feasible here. We assert the fixed SHAPE is present in the source for both variants, plus one behavioral
# sanity anchor for the guard arithmetic itself.
#
# PLUGIN-SOURCE test: exercises BOTH loop variants (which only coexist in templates/); runs in the plugin's
# CI, not copied into a consumer .harness/.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAIL=0
assert()   { local desc="$1"; shift; if "$@"; then echo "ok - $desc"; else echo "FAIL - $desc"; FAIL=1; fi; }
has()      { grep -qF -- "$1" "$2"; }        # fixed-string present
lacks()    { ! grep -qF -- "$1" "$2"; }      # fixed-string absent

for V in loop.sh loop.in-place.sh; do
  f="$SCRIPT_DIR/$V"

  # (1) the old global-exit handler is GONE — no idle path logs "nothing to do", none routes through the
  # drained hook, and idle no longer sits on a line that exits the cycle.
  assert "[$V] old idle handler removed (no 'reports idle — nothing to do')"  lacks 'reports idle — nothing to do' "$f"
  assert "[$V] idle no longer fires the drained hook"                         lacks 'run_hook drained idle'         "$f"

  # (2) the new per-task handler: guard globals initialised, counted, and BLOCK on repeat.
  assert "[$V] idle guard globals initialised"           has 'idle_task=""; idle_count=0'                    "$f"
  assert "[$V] idle increments a per-task counter"       has 'idle_count=$((idle_count + 1))'                "$f"
  assert "[$V] repeated idle BLOCKs the task"            has 'block_task "$task" "repeated idle'             "$f"
  assert "[$V] idle handler clears the heartbeat"        has 'heartbeat_clear; cur_task=""'                  "$f"

  # (3) persist-or-shout hardening: a verify helper + the loud ERROR when a flip doesn't land.
  assert "[$V] status_done_on_remote verify helper present"  has 'status_done_on_remote()'                  "$f"
  assert "[$V] loud ERROR when a status flip doesn't persist" has 'did NOT persist'                         "$f"

  # (4) the legitimate 'backlog drained' exit still exists — we only removed the WRONG one.
  assert "[$V] select_task-empty drain exit still present"   has 'no eligible task — backlog complete'       "$f"
done

# variant-specific reconcile call (each uses its own status-flip primitive)
assert "[loop.sh] idle reconciles via record_outcome false"  bash -c 'grep -A14 "Done-when already met on main" "'"$SCRIPT_DIR"'/loop.sh" | grep -qF "record_outcome \"\$task\" false"'
assert "[loop.in-place.sh] idle reconciles via mark_done"    bash -c 'grep -A14 "Done-when already met on \$MAIN_BRANCH" "'"$SCRIPT_DIR"'/loop.in-place.sh" | grep -qF "mark_done \"\$task\""'

# Sanity anchor (behavioral): the consecutive-idle guard arithmetic blocks on the 2nd same-task idle and
# resets for a new task — documents the exact logic the source asserts above (passes on any bash).
guard_sim() {
  local idle_task="" idle_count=0 t out=""
  for t in "$@"; do
    if [ "$t" = "$idle_task" ]; then idle_count=$((idle_count + 1)); else idle_task="$t"; idle_count=1; fi
    if [ "$idle_count" -ge 2 ]; then out="$out block:$t"; idle_task=""; idle_count=0; else out="$out done:$t"; fi
  done
  printf '%s' "${out# }"
}
assert "guard: 2nd same-task idle blocks; a new task resets the counter" \
  test "$(guard_sim T1 T1 T2 T2 T2)" = "done:T1 block:T1 done:T2 block:T2 done:T2"

[ "$FAIL" = 0 ] && echo "ALL PASS" || { echo "SOME FAILED"; exit 1; }
