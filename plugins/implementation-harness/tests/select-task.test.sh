#!/usr/bin/env bash
#
# select-task.test.sh — hermetic test of the loop's AUTHORITATIVE task selection, exercised through
# the real script via its DRY_RUN=1 entry point (no lock, no build, no claude/gh). This is the shell
# mirror of dashboard/lib.test.js's computeBacklog tests — the two implementations can drift, and
# only this one decides what actually gets built. Pins, per variant present:
#   • array-order pick of the first eligible task;
#   • skips: unmet dependsOn, gate:"needs-human", status:"failed" (owner-overturned, terminal),
#     status:"blocked" (loop-exhausted);
#   • FORCE_TASK safety guard: a bogus forced id is REFUSED, never built (DESIGN.md §9/§12);
#   • FORCE_TASK on a done/failed/gated/blocked id is REFUSED too — the forced path applies the same
#     terminal-status skips as the normal path (B03), so a forced-done task is never cold-rebuilt;
#   • a valid forced id is honored; a drained backlog reports nothing eligible.
# Spins throwaway repos (mktemp -d); worktree-variant decisions are read from origin/main (a bare
# remote), in-place from the local checkout — each fixture matches its variant's contract.
# Run standalone: plugins/implementation-harness/tests/select-task.test.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../templates/scripts" && pwd)"
FAIL=0
TMPS=()
cleanup() { local d; for d in ${TMPS[@]+"${TMPS[@]}"}; do rm -rf "$d"; done; }
trap cleanup EXIT

assert() { local desc="$1"; shift; if "$@"; then echo "ok - $desc"; else echo "FAIL - $desc"; FAIL=1; fi; }

BACKLOG_JSON='{"version":1,"tasks":[
  {"id":"T001","status":"done","dependsOn":[],"gate":null},
  {"id":"T002","status":"pending","dependsOn":["T009"],"gate":null},
  {"id":"T003","status":"pending","dependsOn":[],"gate":"needs-human"},
  {"id":"T004","status":"failed","dependsOn":[],"gate":null},
  {"id":"T005","status":"blocked","dependsOn":[],"gate":null},
  {"id":"T006","status":"pending","dependsOn":["T001"],"gate":null},
  {"id":"T009","status":"pending","dependsOn":["T003"],"gate":null}
]}'
DRAINED_JSON='{"version":1,"tasks":[
  {"id":"T001","status":"done","dependsOn":[],"gate":null},
  {"id":"T002","status":"pending","dependsOn":[],"gate":"needs-human"}
]}'
# Overlay preview: T001 is needs-human (loop skips it) and T002 depends on it. With no overlay the
# backlog is stuck; once the owner marks T001 done in human-done.json, the DRY_RUN preview must
# reconcile in-memory and show T002 as eligible — matching the next real iteration.
OVERLAY_JSON='{"version":1,"tasks":[
  {"id":"T001","status":"pending","dependsOn":[],"gate":"needs-human"},
  {"id":"T002","status":"pending","dependsOn":["T001"],"gate":null}
]}'

setup_repo() {  # setup_repo <loop-src-path> <backlog-json> → echoes repo path
  local src="$1" backlog="$2" d bare
  d="$(mktemp -d)"; bare="$(mktemp -d)"; TMPS+=("$d" "$bare")
  git init -q -b main "$d"
  ( cd "$d" && git config user.email t@t.com && git config user.name t )
  mkdir -p "$d/.harness/scripts" "$d/.harness/tracking" "$d/.harness/worklog" "$d/.harness/config"
  cp "$src" "$d/.harness/scripts/loop.sh"
  cp "$SCRIPT_DIR/repo-lock.sh" "$SCRIPT_DIR/scope-lib.sh" "$SCRIPT_DIR/policy.jq" "$d/.harness/scripts/"
  chmod +x "$d/.harness/scripts/"*.sh
  printf '%s\n' "$backlog" >"$d/.harness/tracking/TASKS.json"
  ( cd "$d" && git add -A && git commit -q -m init )
  git init -q --bare -b main "$bare"
  ( cd "$d" && git remote add origin "$bare" && git push -q -u origin main )
  echo "$d"
}

dryrun() {  # dryrun <repo> [force-task] → combined stdout+stderr
  local d="$1"; shift
  ( cd "$d" && env -u CLAUDECODE DRY_RUN=1 bash .harness/scripts/loop.sh "$@" 2>&1 )
}

write_human_done() {  # write_human_done <repo> <json> — commit+push an owner human-done overlay
  local d="$1" json="$2"
  printf '%s\n' "$json" >"$d/.harness/tracking/human-done.json"
  ( cd "$d" && git add -A && git commit -q -m overlay && git push -q origin main 2>/dev/null || true )
}

run_variant_suite() {  # run_variant_suite <label> <loop-src-path>
  local label="$1" src="$2" d out

  d="$(setup_repo "$src" "$BACKLOG_JSON")"
  out="$(dryrun "$d")"
  assert "[$label] picks T006 — first eligible in array order (skipping unmet-dep, gated, failed, blocked)" \
    bash -c "printf '%s' \"\$1\" | grep -q 'would build: T006'" _ "$out"
  for skipped in T002 T003 T004 T005; do
    assert "[$label] $skipped not selected" \
      bash -c "! printf '%s' \"\$1\" | grep -q \"would build: \$2\"" _ "$out" "$skipped"
  done

  out="$(dryrun "$d" T999)"
  assert "[$label] FORCE_TASK bogus id is refused (safety guard)" \
    bash -c "printf '%s' \"\$1\" | grep -qi 'not a real task id.*refusing'" _ "$out"
  assert "[$label] FORCE_TASK bogus id → nothing built" \
    bash -c "printf '%s' \"\$1\" | grep -q 'nothing eligible'" _ "$out"

  out="$(dryrun "$d" T006)"
  assert "[$label] FORCE_TASK with a real pending id is honored" \
    bash -c "printf '%s' \"\$1\" | grep -q 'would build: T006'" _ "$out"

  # B03: FORCE_TASK must not bypass the SAME terminal-status skips the normal path applies — else a
  # forced-done task gets cold-rebuilt (idle → repeated idle blocks a task that already succeeded),
  # and forcing a gated/failed/blocked id builds something the loop is never supposed to touch itself.
  out="$(dryrun "$d" T001)"   # T001: status=done
  assert "[$label] FORCE_TASK on a DONE task is refused (terminal, never rebuilt)" \
    bash -c "printf '%s' \"\$1\" | grep -qF \"FORCE_TASK 'T001' is already status=done\"" _ "$out"
  assert "[$label] FORCE_TASK on a DONE task → nothing built" \
    bash -c "! printf '%s' \"\$1\" | grep -q 'would build'" _ "$out"

  out="$(dryrun "$d" T003)"   # T003: gate=needs-human
  assert "[$label] FORCE_TASK on a gated (needs-human) task is refused" \
    bash -c "printf '%s' \"\$1\" | grep -qF \"FORCE_TASK 'T003' is gate:needs-human\"" _ "$out"
  assert "[$label] FORCE_TASK on a gated task → nothing built" \
    bash -c "! printf '%s' \"\$1\" | grep -q 'would build'" _ "$out"

  out="$(dryrun "$d" T004)"   # T004: status=failed (owner-overturned)
  assert "[$label] FORCE_TASK on a failed (owner-overturned) task is refused" \
    bash -c "printf '%s' \"\$1\" | grep -qF \"FORCE_TASK 'T004' is status=failed\"" _ "$out"
  assert "[$label] FORCE_TASK on a failed task → nothing built" \
    bash -c "! printf '%s' \"\$1\" | grep -q 'would build'" _ "$out"

  out="$(dryrun "$d" T005)"   # T005: status=blocked (loop-exhausted)
  assert "[$label] FORCE_TASK on a blocked (loop-exhausted) task is refused" \
    bash -c "printf '%s' \"\$1\" | grep -qF \"FORCE_TASK 'T005' is status=blocked\"" _ "$out"
  assert "[$label] FORCE_TASK on a blocked task → nothing built" \
    bash -c "! printf '%s' \"\$1\" | grep -q 'would build'" _ "$out"

  d="$(setup_repo "$src" "$DRAINED_JSON")"
  out="$(dryrun "$d")"
  assert "[$label] drained backlog (done + needs-human only) → nothing eligible" \
    bash -c "printf '%s' \"\$1\" | grep -q 'nothing eligible'" _ "$out"

  # DRY_RUN reflects owner overlays in-memory (regression: preview used to skip reconcile and
  # under-report eligible work between an overlay action and the next real iteration).
  d="$(setup_repo "$src" "$OVERLAY_JSON")"
  out="$(dryrun "$d")"
  assert "[$label] overlay preview: before human-done, needs-human T001 blocks its dependent → nothing eligible" \
    bash -c "printf '%s' \"\$1\" | grep -q 'nothing eligible'" _ "$out"
  write_human_done "$d" '{"T001":{"done":true}}'
  out="$(dryrun "$d")"
  assert "[$label] overlay preview: after owner marks needs-human T001 done, dependent T002 is eligible" \
    bash -c "printf '%s' \"\$1\" | grep -q 'would build: T002'" _ "$out"

  # B09: a corrupt/unparseable backlog must fail CLOSED (exit 3) at startup, BEFORE the DRY_RUN
  # select — never drain-and-exit-0 (which supervise would treat as "backlog complete" and idle on).
  # The exit-3 (not 0) is the load-bearing assertion: it proves the pre-flight fired ahead of the
  # DRY_RUN block, which would otherwise have exited 0.
  d="$(setup_repo "$src" '{"tasks":[ truncated garbage — not valid json')"
  out="$(dryrun "$d")"; rc=$?
  assert "[$label] corrupt TASKS.json → exit 3 (fail closed, not 'backlog complete')" \
    [ "$rc" -eq 3 ]
  assert "[$label] corrupt TASKS.json → FATAL wording (not 'nothing eligible'/'would build')" \
    bash -c "printf '%s' \"\$1\" | grep -qi 'FATAL.*not valid JSON'" _ "$out"
}

# Plugin source tree carries both variants; an install carries exactly one (as loop.sh, identified
# by its # harness-loop-variant: header). Test every distinct variant file present here.
ran=0
if grep -q '^# harness-loop-variant: worktree' "$SCRIPT_DIR/loop.sh" 2>/dev/null; then
  run_variant_suite worktree "$SCRIPT_DIR/loop.sh"; ran=$((ran+1))
elif grep -q '^# harness-loop-variant: in-place' "$SCRIPT_DIR/loop.sh" 2>/dev/null; then
  run_variant_suite in-place "$SCRIPT_DIR/loop.sh"; ran=$((ran+1))
fi
if [ -f "$SCRIPT_DIR/loop.in-place.sh" ]; then
  run_variant_suite in-place "$SCRIPT_DIR/loop.in-place.sh"; ran=$((ran+1))
fi
assert "at least one loop variant was found and tested" [ "$ran" -ge 1 ]

if [ "$FAIL" = 0 ]; then echo "PASS: select-task"; else echo "FAIL: select-task"; exit 1; fi
