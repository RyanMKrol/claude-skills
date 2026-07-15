#!/usr/bin/env bash
#
# force-task-lifecycle.test.sh — regression guard for B03: FORCE_TASK bypassing terminal-status
# checks and never being "one-shot". Complements select-task.test.sh (which pins select_task's
# DRY_RUN decision logic, including the new forced-terminal-status refusals) by exercising the REAL
# (non-DRY_RUN) loop end-to-end for the exact failure scenario from the bug report: forcing an
# already-done or gated task must refuse and exit cleanly WITHOUT ever attempting a cold rebuild —
# no claude/gh needed here, since the refusal fires in select_task before either is ever invoked.
#
# THE BUG (fixed): the forced path in select_task only checked the id EXISTS, so `loop.sh T014` on an
# already-done T014 would cold-rebuild it; the builder finds nothing to do (idle), and two consecutive
# idles BLOCK the task — a forced run could end by flipping its own already-successful task to
# "blocked". Fix: the forced path applies the same terminal-status skips as the normal path, and the
# main loop's "nothing eligible" exit now names the forced task distinctly from an actually-drained
# backlog.
#
# PLUGIN-SOURCE test: exercises BOTH loop variants (which only coexist in templates/); runs in the
# plugin's CI, not copied into a consumer .harness/.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../templates/scripts" && pwd)"
FAIL=0
TMPS=()
cleanup() { local d; for d in ${TMPS[@]+"${TMPS[@]}"}; do rm -rf "$d"; done; }
trap cleanup EXIT

assert() { local desc="$1"; shift; if "$@"; then echo "ok - $desc"; else echo "FAIL - $desc"; FAIL=1; fi; }

BACKLOG_JSON='{"version":1,"tasks":[
  {"id":"T001","status":"done","dependsOn":[],"gate":null},
  {"id":"T002","status":"pending","dependsOn":[],"gate":null},
  {"id":"T003","status":"pending","dependsOn":[],"gate":"needs-human"}
]}'

setup_repo() {  # setup_repo <loop-src-path> → echoes repo path
  local src="$1" d bare
  d="$(mktemp -d)"; bare="$(mktemp -d)"; TMPS+=("$d" "$bare")
  git init -q -b main "$d"
  ( cd "$d" && git config user.email t@t.com && git config user.name t )
  mkdir -p "$d/.harness/scripts" "$d/.harness/tracking" "$d/.harness/worklog" "$d/.harness/config"
  cp "$src" "$d/.harness/scripts/loop.sh"
  cp "$SCRIPT_DIR/repo-lock.sh" "$SCRIPT_DIR/scope-lib.sh" "$SCRIPT_DIR/loop-lib.sh" "$SCRIPT_DIR/policy.jq" "$d/.harness/scripts/"
  chmod +x "$d/.harness/scripts/"*.sh
  printf '%s\n' "$BACKLOG_JSON" >"$d/.harness/tracking/TASKS.json"
  ( cd "$d" && git add -A && git commit -q -m init )
  git init -q --bare -b main "$bare"
  ( cd "$d" && git remote add origin "$bare" && git push -q -u origin main )
  echo "$d"
}

# realrun <repo> <force-task> → combined stdout+stderr from the REAL loop (no DRY_RUN, no lock reuse
# across calls since each repo is fresh). Bounded by MAX_ITERS=1 as a backstop; the forced-terminal
# refusal exits on iteration 1 regardless.
realrun() {
  local d="$1" ft="$2"
  ( cd "$d" && env -u CLAUDECODE MAX_ITERS=1 bash .harness/scripts/loop.sh "$ft" 2>&1 )
}

run_variant_suite() {  # run_variant_suite <label> <loop-src-path>
  local label="$1" src="$2" d out rc

  # 1. Forcing an already-DONE task: refuses, exits 0, NEVER attempts a build.
  d="$(setup_repo "$src")"
  out="$(realrun "$d" T001)"; rc=$?
  assert "[$label] force a DONE task → exits 0 (clean, not an error)" [ "$rc" = 0 ]
  assert "[$label] force a DONE task → the specific terminal refusal is logged" \
    bash -c "printf '%s' \"\$1\" | grep -qF \"FORCE_TASK 'T001' is already status=done\"" _ "$out"
  assert "[$label] force a DONE task → the one-shot forced-exit message fires (not the generic drained one)" \
    bash -c "printf '%s' \"\$1\" | grep -qF 'forced task T001 is not eligible to build'" _ "$out"
  assert "[$label] force a DONE task → NEVER attempts a cold rebuild (no iteration/build line)" \
    bash -c "! printf '%s' \"\$1\" | grep -qE 'iteration [0-9]+/'" _ "$out"
  assert "[$label] force a DONE task → status stays done (not vandalized to blocked)" \
    bash -c "jq -e '.tasks[]|select(.id==\"T001\")|.status==\"done\"' \"\$1/.harness/tracking/TASKS.json\" >/dev/null" _ "$d"

  # 2. Forcing a gated (needs-human) task: same shape — refused, never built.
  d="$(setup_repo "$src")"
  out="$(realrun "$d" T003)"; rc=$?
  assert "[$label] force a gated task → exits 0" [ "$rc" = 0 ]
  assert "[$label] force a gated task → the specific terminal refusal is logged" \
    bash -c "printf '%s' \"\$1\" | grep -qF \"FORCE_TASK 'T003' is gate:needs-human\"" _ "$out"
  assert "[$label] force a gated task → NEVER attempts a cold rebuild (no iteration/build line)" \
    bash -c "! printf '%s' \"\$1\" | grep -qE 'iteration [0-9]+/'" _ "$out"

  # 3. Sanity control: forcing the eligible PENDING task still selects it (would attempt to build —
  #    we don't run a real build here, just confirm it gets PAST select_task, unlike cases 1/2).
  d="$(setup_repo "$src")"
  out="$(realrun "$d" T002)"
  assert "[$label] force an eligible PENDING task → DOES reach the build iteration (selection succeeds)" \
    bash -c "printf '%s' \"\$1\" | grep -qE 'iteration [0-9]+/.*T002'" _ "$out"
}

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

if [ "$FAIL" = 0 ]; then echo "PASS: force-task-lifecycle"; else echo "FAIL: force-task-lifecycle"; exit 1; fi
