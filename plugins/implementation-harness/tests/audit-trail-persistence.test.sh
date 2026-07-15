#!/usr/bin/env bash
#
# audit-trail-persistence.test.sh — regression guard for B04: the worktree variant's audit output and
# build/audit transcripts must survive the throwaway task worktree's teardown. Exercised via loop.sh's
# --audit-trail-selftest, which overrides run_claude in-process (no real claude subprocess) to write a
# sentinel VERDICT, runs the REAL audit_gate, then the test itself tears the worktree down (simulating
# cleanup_task/remove_wt) and confirms the primary checkout's worklog/ still has both the per-task
# audit.md AND the raw claude-out transcript.
#
# THE BUG (fixed): audit_gate wrote its output to $LOOP_WT/.harness/worklog/$id.audit.md — INSIDE the
# throwaway worktree — and cleanup_task deletes that worktree within seconds of every attempt ending
# (structural fail, CI red, audit fail, AND success). A human reviewing why an audit failed found
# nothing there. Same for run_claude's build/audit transcripts (what the dashboard live-tails). Fix:
# both now write to the PRIMARY checkout's worklog/ (like FAILURES_BUF/HEARTBEAT already did), which
# survives teardown.
#
# The in-place variant is unaffected (it already writes into the primary checkout) — no selftest
# there; nothing to regression-guard.
#
# PLUGIN-SOURCE test: runs in the plugin's CI, not copied into a consumer .harness/.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../templates/scripts" && pwd)"
FAIL=0
TMPS=()
cleanup() { local d; for d in ${TMPS[@]+"${TMPS[@]}"}; do rm -rf "$d"; done; }
trap cleanup EXIT

assert() { local desc="$1"; shift; if "$@"; then echo "ok - $desc"; else echo "FAIL - $desc"; FAIL=1; fi; }

# setup_repo → echoes "<primary-checkout-path> <worktree-path>". The worktree is a REAL `git worktree
# add`, not a plain directory: audit_gate's (unrelated to B04) `git -C "$LOOP_WT" diff origin/main..HEAD`
# needs a genuine repo there — a plain non-repo directory there is a separate, pre-existing footgun
# this test sidesteps rather than exercises.
setup_repo() {
  local d bare wt; d="$(mktemp -d)"; bare="$(mktemp -d)"; wt="$(mktemp -d)"; rm -rf "$wt"   # `git worktree add` wants a non-existent target
  git init -q -b main "$d"
  ( cd "$d" && git config user.email t@t.com && git config user.name t )
  mkdir -p "$d/.harness/scripts" "$d/.harness/tracking"
  cp "$SCRIPT_DIR/repo-lock.sh" "$SCRIPT_DIR/scope-lib.sh" "$SCRIPT_DIR/policy.jq" "$SCRIPT_DIR/loop.sh" "$d/.harness/scripts/"
  chmod +x "$d/.harness/scripts/"*.sh
  printf '{"tasks":[{"id":"T001","status":"pending","gate":null,"facets":{"layer":"backend","workType":"feature"}}]}' > "$d/.harness/tracking/TASKS.json"
  ( cd "$d" && git add -A && git commit -q -m init )
  git init -q --bare -b main "$bare"
  ( cd "$d" && git remote add origin "$bare" && git push -q -u origin main )
  ( cd "$d" && git worktree add -q "$wt" -b tworktree-probe main )
  echo "$d $wt"
}

# --- FAIL path -----------------------------------------------------------------------------------
read -r d wt <<<"$(setup_repo)"
TMPS+=("$d")   # $wt is removed via `git worktree remove` below, not a plain rm -rf

set +e
out="$(cd "$d" && env -u CLAUDECODE LOOP_WT="$wt" bash .harness/scripts/loop.sh --audit-trail-selftest T001 FAIL 2>&1)"
rc=$?
set -e
assert "selftest: audit_gate returns 1 (FAIL verdict)" [ "$rc" = 1 ]
assert "selftest: audit.md written to the PRIMARY checkout, not the worktree" \
  [ -f "$d/.harness/worklog/T001.audit.md" ]
assert "selftest: claude-out transcript written to the PRIMARY checkout" \
  [ -f "$d/.harness/worklog/.claude-out.audit" ]
assert "selftest: nothing written under the worktree's own worklog dir (moved, not duplicated)" \
  [ ! -e "$wt/.harness/worklog/T001.audit.md" ]

# Simulate cleanup_task's remove_wt: tear the worktree down for real.
( cd "$d" && git worktree remove --force "$wt" )
( cd "$d" && git branch -D tworktree-probe 2>/dev/null || true )

assert "TEARDOWN: the worktree is genuinely gone" [ ! -d "$wt" ]
assert "AFTER TEARDOWN: audit.md still exists in the primary checkout — THE B04 FIX" \
  bash -c "grep -qF 'VERDICT: FAIL' '$d/.harness/worklog/T001.audit.md'"
assert "AFTER TEARDOWN: the build/audit transcript still exists too" \
  [ -f "$d/.harness/worklog/.claude-out.audit" ]

# --- PASS path sanity check (audit_gate's other branch writes the same way) ----------------------
read -r d2 wt2 <<<"$(setup_repo)"
TMPS+=("$d2")
set +e
( cd "$d2" && env -u CLAUDECODE LOOP_WT="$wt2" bash .harness/scripts/loop.sh --audit-trail-selftest T001 PASS >/dev/null 2>&1 )
rc2=$?
set -e
( cd "$d2" && git worktree remove --force "$wt2" 2>/dev/null || true )
assert "PASS path: audit_gate returns 0" [ "$rc2" = 0 ]
assert "PASS path: audit.md survives worktree teardown too" \
  bash -c "grep -qF 'VERDICT: PASS' '$d2/.harness/worklog/T001.audit.md'"

[ "$FAIL" = 0 ] && echo "ALL PASS" || { echo "SOME FAILED"; exit 1; }
