#!/usr/bin/env bash
#
# loop.sh — IN-PLACE variant of the single SEQUENTIAL "Ralph loop". Builds a TASKS.json backlog
# ONE fully-verified task at a time, working DIRECTLY ON `main` in the primary checkout (NO git
# worktree, NO per-task branches).
#
# WHEN TO USE THIS VARIANT (vs the default worktree loop.sh):
#   The stock worktree loop builds each task in a throwaway worktree off origin/main, so it can
#   only see TRACKED files. Choose this in-place variant when the build/verify depends on
#   UNTRACKED or gitignored local state — private code in a public repo, local datasets/fixtures,
#   secrets-driven tests — that a clean worktree off origin/main literally can't see.
#
#   The trade-off: the loop commits on the real `main`, so the safety model is git itself (every
#   task is one commit; a bad one is a one-line `git revert`) PLUS a load-bearing pre-push guard
#   (below) that refuses to push if any sensitive/gitignored path is staged. See docs/HARNESS.md.
#
# Each iteration:
#   SELECT (shell)  — from TASKS.json: the next not-done task whose dependsOn are all done and
#                     which is NOT a 🚦 gate / 🔒 needs-human / blocked task. None → stop.
#   WORK   (claude) — one `claude -p` (per-task model/effort) builds the task IN THIS CHECKOUT on
#                     main, runs the Definition of Done, and COMMITS (does NOT push).
#   GATE   (shell)  — pre-push guard (refuse if anything sensitive is staged) → push main → watch
#                     GitHub CI → green: mark the task done (+ optional integrate hook); red: STOP.
#
# Usage:  scripts/loop.sh [TNNN]          # optional: force a specific task id this run
#         DRY_RUN=1 scripts/loop.sh       # print the task it WOULD build, then exit
#         scripts/loop.sh --guard-selftest  # verify the pre-push guard regex, then exit
# Config: scripts/harness.env (sourced if present) and/or the environment.
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
GIT_COMMON="$(git -C "$ROOT" rev-parse --git-common-dir)"
case "$GIT_COMMON" in /*) ;; *) GIT_COMMON="$ROOT/$GIT_COMMON" ;; esac   # make absolute

[ -f "$ROOT/scripts/harness.env" ] && . "$ROOT/scripts/harness.env"

BACKLOG="$ROOT/TASKS.json"
WORKLOG="$ROOT/worklog"
NAME="$(basename "$ROOT")"
MODEL="${MODEL:-claude-opus-4-8}"                 # pin EXACTLY — the bare alias drifts
EFFORT="${EFFORT:-high}"                           # low|medium|high|xhigh|max
MAX_ATTEMPTS="${MAX_ATTEMPTS:-3}"                  # soft failures per rung before escalating
MAX_ITERS="${MAX_ITERS:-100}"                      # global iteration backstop
WAIT_SECONDS="${WAIT_SECONDS:-30}"                 # backoff between retries / CI polls
CI_TIMEOUT="${CI_TIMEOUT:-1200}"                   # max seconds to wait for a CI run
CI_WORKFLOW="${CI_WORKFLOW:-CI}"                   # MUST match `name:` in the CI workflow yaml
REQUIRE_CI="${REQUIRE_CI:-1}"                      # 1 = never mark done without green CI
MAIN_BRANCH="${MAIN_BRANCH:-main}"
INTEGRATE_HOOK="${INTEGRATE_HOOK:-}"               # optional cmd run after each task integrates (deploy/restart)
CLAUDE_BIN="${CLAUDE_BIN:-claude}"
CLAUDE_FLAGS="${CLAUDE_FLAGS:---dangerously-skip-permissions}"
# Rate-limit-aware backoff: when Claude hits the usage limit, sleep and resume the SAME task.
RL_BACKOFF_MIN="${RL_BACKOFF_MIN:-300}"            # first backoff (5 min)
RL_BACKOFF_MAX="${RL_BACKOFF_MAX:-18000}"          # cap (~5h = the quota window)
FORCE_TASK=""; [ "${1:-}" != "--guard-selftest" ] && FORCE_TASK="${1:-}"
POSTFLIGHT="$ROOT/scripts/postflight.sh"

read -r -a FLAGS <<<"$CLAUDE_FLAGS"
log() { printf '[loop] %s\n' "$*" >&2; }
board() { [ -x "$POSTFLIGHT" ] && "$POSTFLIGHT" >/dev/null 2>&1 || true; }

command -v jq >/dev/null 2>&1 || { log "jq is required to parse TASKS.json — install it (e.g. brew install jq)"; exit 3; }

# Paths that must NEVER be pushed (data, secrets, browser profiles). TASKS.json + worklog/ ARE
# committed intentionally, so they are NOT blocked here. .env.example is a tracked placeholder
# template and is explicitly allowed past the guard (see guard_clean) — only the REAL .env* is blocked.
SENSITIVE_RE='(^|/)data/|(^|/)\.env($|\.)|chrome-profile|\.pem$|\.key$|\.p12$|service-account|credentials\.json'
GUARD_ALLOW_RE='(^|[/:])\.env\.example$'

# --- Pre-push guard: refuse to push if anything sensitive is in the new commits ----
guard_clean() {
  local bad
  bad="$(git -C "$ROOT" diff --name-only "origin/$MAIN_BRANCH..HEAD" 2>/dev/null | grep -nE "$SENSITIVE_RE" | grep -vE "$GUARD_ALLOW_RE" || true)"
  [ -z "$bad" ] && return 0
  log "PRE-PUSH GUARD TRIPPED — refusing to push. Sensitive paths in pending commits:"
  printf '   %s\n' $bad >&2
  return 1
}

# --guard-selftest: assert the guard regex blocks real secrets but allows tracked templates.
guard_selftest() {
  local fail=0 p exp got
  while read -r p exp; do
    [ -z "$p" ] && continue
    if printf '%s\n' "$p" | grep -nE "$SENSITIVE_RE" | grep -vE "$GUARD_ALLOW_RE" >/dev/null; then got=BLOCK; else got=ALLOW; fi
    [ "$got" = "$exp" ] || { echo "guard FAIL: '$p' expected $exp got $got"; fail=1; }
  done <<'CASES'
.env BLOCK
.env.local BLOCK
.env.production BLOCK
config/.env BLOCK
.env.example ALLOW
src/app/.env.example ALLOW
data/out.json BLOCK
src/jobs/x/data/raw.csv BLOCK
chrome-profile/Default BLOCK
config/credentials.json BLOCK
secrets/id.pem BLOCK
deploy/key.p12 BLOCK
service-account.json BLOCK
src/index.ts ALLOW
README.md ALLOW
TASKS.json ALLOW
worklog/T001.md ALLOW
CASES
  [ "$fail" = 0 ] && { echo "guard self-test OK (16 cases)"; return 0; } || return 1
}
[ "${1:-}" = "--guard-selftest" ] && { guard_selftest; exit $?; }

[ -f "$BACKLOG" ] || { log "no TASKS.json at repo root — nothing to build"; exit 3; }

# --- Concurrency guard: only one loop at a time (exit, don't queue) ----------
acquire_lock() {
  LOCK="$GIT_COMMON/${NAME}-loop.lock"
  while ! mkdir "$LOCK" 2>/dev/null; do
    local owner; owner="$(cat "$LOCK/pid" 2>/dev/null || true)"
    if [ -n "$owner" ] && ! kill -0 "$owner" 2>/dev/null; then
      log "stale loop lock (dead PID $owner) — reclaiming"; rm -f "$LOCK/pid"; rmdir "$LOCK" 2>/dev/null || true
    else
      log "another loop is already running (PID ${owner:-?}) — exiting."; exit 0
    fi
  done
  echo "$$" >"$LOCK/pid"
}
release_lock() {
  [ -n "${LOCK:-}" ] && [ -f "$LOCK/pid" ] && [ "$(cat "$LOCK/pid" 2>/dev/null)" = "$$" ] \
    && { rm -f "$LOCK/pid"; rmdir "$LOCK" 2>/dev/null || true; } || true
}

# --- TASKS.json helpers (read from the local backlog file) ------------------
tj()           { jq "$@" "$BACKLOG" 2>/dev/null; }
all_tasks()    { tj -r '.tasks[].id'; }
task_done()    { tj -e --arg id "$1" '.tasks[]|select(.id==$id)|.status=="done"' >/dev/null; }
deps_for()     { tj -r --arg id "$1" '.tasks[]|select(.id==$id)|.dependsOn[]?' | tr '\n' ' '; }
task_gated()   { tj -e --arg id "$1" '.tasks[]|select(.id==$id)|.gate!=null' >/dev/null; }   # "gate"/"needs-human"
task_blocked() { [ -f "$WORKLOG/$1.md" ] && grep -qiE 'failed:blocked|needs-human' "$WORKLOG/$1.md"; }

# Shell owns task status: set it done, then commit+push the one-line change (no CI needed). Sweeps
# worklog/ into the same commit so a stray worklog the agent forgot to stage can't dirty the tree
# (which would mislabel the next iteration as a "resume").
mark_done() {
  local id="$1" tmp; tmp="$(mktemp)"
  jq --arg id "$id" '(.tasks[]|select(.id==$id)|.status)="done"' "$BACKLOG" >"$tmp" \
    && mv "$tmp" "$BACKLOG" || { rm -f "$tmp"; log "WARN: failed to mark $id done"; return 1; }
  git -C "$ROOT" add "$BACKLOG" "$WORKLOG" 2>/dev/null || true
  git -C "$ROOT" commit -q -m "$id: mark done [skip ci]" 2>/dev/null || true
  git -C "$ROOT" push origin "HEAD:$MAIN_BRANCH" 2>/dev/null || log "WARN: couldn't push status update for $id"
}

# Optional post-integration hook (deploy/restart so the running product matches main).
run_integrate_hook() {
  [ -n "$INTEGRATE_HOOK" ] || return 0
  log "integrate hook: $INTEGRATE_HOOK"
  ( cd "$ROOT" && eval "$INTEGRATE_HOOK" ) || log "WARN: integrate hook failed (non-fatal)"
}

# task_ladder <id> — emit "MODEL<TAB>EFFORT" per build rung (rung 0 = primary, then escalations).
task_ladder() {
  tj -r --arg id "$1" '
    (.defaults.model // "") as $dm | (.defaults.effort // "") as $de |
    (.defaults.escalation // []) as $desc |
    .tasks[] | select(.id==$id) |
    ( [ { model:(.model // $dm), effort:(.effort // $de) } ]
      + ( (.escalation // $desc) | map({ model:(.model // $dm), effort:(.effort // $de) }) )
    ) | .[] | "\(.model)\t\(.effort)"'
}
ladder_len() { task_ladder "$1" | grep -c .; }
rung_at() {
  local r m e
  r="$(task_ladder "$1" | sed -n "$(( ${2:-0} + 1 ))p")"
  m="${r%%$'\t'*}"; e="${r##*$'\t'}"
  printf '%s %s' "${m:-$MODEL}" "${e:-$EFFORT}"
}

# SELECT — echo the next eligible task id; return 1 if nothing is eligible.
select_task() {
  local t d ok
  if [ -n "$FORCE_TASK" ]; then echo "$FORCE_TASK"; return 0; fi
  for t in $(all_tasks); do
    task_done "$t" && continue
    task_gated "$t" && continue       # 🚦 gate / 🔒 needs-human — a human must act
    task_blocked "$t" && continue     # a prior attempt recorded failed:blocked
    ok=1; for d in $(deps_for "$t"); do task_done "$d" || { ok=0; break; }; done
    [ "$ok" = 1 ] && { echo "$t"; return 0; }
  done
  return 1
}

# --- GitHub CI gate (watches the workflow run for the current main HEAD) -----
wait_ci_green() {   # 0=green 1=red 2=indeterminate
  local sha runid="" waited=0
  command -v gh >/dev/null 2>&1 || { log "gh not installed — cannot gate CI"; return 2; }
  sha="$(git -C "$ROOT" rev-parse HEAD)"
  log "waiting for CI ($CI_WORKFLOW) on ${sha}…"
  while [ "$waited" -lt "$CI_TIMEOUT" ]; do
    runid="$(gh run list --limit 20 --json databaseId,headSha,workflowName \
               --jq ".[] | select(.headSha==\"$sha\" and .workflowName==\"$CI_WORKFLOW\") | .databaseId" \
               2>/dev/null | head -1 || true)"
    [ -n "$runid" ] && break
    sleep "$WAIT_SECONDS"; waited=$((waited + WAIT_SECONDS))
  done
  [ -n "$runid" ] || { log "no '$CI_WORKFLOW' run appeared for $sha within ${CI_TIMEOUT}s"; return 2; }
  if gh run watch "$runid" --exit-status >/dev/null 2>&1; then log "CI GREEN (run $runid)"; return 0; fi
  log "CI RED (run $runid) — gh run view $runid --log-failed"; return 1
}

# --- Claude invocation with rate-limit detection ----------------------------
RL_RE='usage limit|rate.?limit|429|resets at|try again later|overloaded|quota|insufficient.*credit|exceeded your'
# run_claude <model> <effort> <prompt> → 0 ok | 10 rate-limited | other = failure
run_claude() {
  local model="$1" effort="$2" pr="$3" out="$WORKLOG/.claude-out" rc
  set +e
  ( cd "$ROOT" && "$CLAUDE_BIN" -p "$pr" --model "$model" --effort "$effort" "${FLAGS[@]}" ) 2>&1 | tee "$out"
  rc=${PIPESTATUS[0]}
  set -e
  if [ "$rc" -ne 0 ] && grep -qiE "$RL_RE" "$out"; then return 10; fi
  return "$rc"
}

# --- Per-task build prompt --------------------------------------------------
prompt() {
  local tid="$1"
  printf 'You are the autonomous builder for THIS repo. Build EXACTLY ONE task: %s, then stop.\n' "$tid"
  cat <<'EOF'
You work DIRECTLY on the `main` branch in the primary checkout — NO worktree, NO new branches.
Do NOT create/switch branches. Do NOT push. Do NOT merge. The loop pushes + gates on CI after you finish.
You run head-less and unattended. Obey CLAUDE.md, TASKS.json, and docs/HARNESS.md exactly.

1. ORIENT & RESUME. Read CLAUDE.md (conventions) and find this task:
   `jq '.tasks[]|select(.id=="<TASK>")' TASKS.json` (read its scope/doneWhen/verify; if its `design`
   field points to a docs/designs/… doc, READ and follow it). Read worklog/<TASK>.md if present
   (prior attempts — don't repeat dead ends). The working tree MAY hold partial work from an
   interrupted attempt — RECONCILE: do ONLY the outstanding work vs `doneWhen`, trusting the code
   over the worklog. Stay within the task's `scope` files.

2. DEFINITION OF DONE (docs/HARNESS.md §6 — all must hold before you report `done`):
   a. Run the project's full verification suite exactly as defined in CLAUDE.md / docs/HARNESS.md §6
      (format, lint, tests, build). These MIRROR CI — run them locally first; every check must pass.
      Add tests for new behaviour.
   b. Run the task's integration / end-to-end checks when their preconditions are met. A check that
      needs credentials, funds, or external resources you don't have: never silently skip a required
      one and call it "passed" — record failed:blocked if the task's core needs it.
   c. If the task's `verify` field names extra EMPIRICAL checks, perform them and record what you
      OBSERVED in worklog/<TASK>.md.

3. SECRETS / PRIVACY — NON-NEGOTIABLE. Stage files EXPLICITLY by path; NEVER `git add -A` / `git add .`.
   NEVER `git add` anything under a `data/` folder, a `chrome-profile/`, a real `.env*`, or any
   credential file, and never edit .gitignore to un-ignore them. The loop's pre-push guard HALTS the
   whole run if any sensitive path is staged — so stage precisely.

4. DOCS IN LOCKSTEP (same commit): update README.md / CLAUDE.md if a convention or feature changed,
   and add any new trade-off to docs/LIMITATIONS.md. Do NOT edit TASKS.json — the loop owns task
   status. Write your notes to worklog/<TASK>.md (a dated entry: what you did, checks run, what remains).

5. COMMIT `<TASK>: <summary>` (do NOT push), staging your intended files explicitly.

6. As your FINAL action, OVERWRITE worklog/.result with exactly ONE line:
     done <TASK>                     # built + committed (NOT pushed) — loop pushes + gates CI
     failed:soft <TASK> <reason>     # transient / partial — retry is worthwhile
     failed:blocked <TASK> <reason>  # needs-human / unmet prereq — do NOT retry
     waiting <TASK> <unmet-deps>     # a dependency is not done yet
     idle                            # nothing to do
EOF
}

# --- Dry run ----------------------------------------------------------------
if [ "${DRY_RUN:-0}" = "1" ]; then
  git -C "$ROOT" fetch origin --quiet 2>/dev/null || true
  sel="$(select_task || true)"
  [ -n "$sel" ] && echo "DRY-RUN → would build: $sel" \
                || echo "DRY-RUN → nothing eligible (backlog done or all gate/human-blocked)"
  exit 0
fi

# --- Main loop --------------------------------------------------------------
acquire_lock
trap 'release_lock' EXIT INT TERM

cur_task=""; cur_attempts=0; cur_rung=0
bump() {   # count a soft failure for $1; escalate at the cap; stop past the top rung
  local t="$1" last
  [ "$t" = "$cur_task" ] || { cur_task="$t"; cur_attempts=0; cur_rung=0; }
  last=$(( $(ladder_len "$t") - 1 ))
  cur_attempts=$((cur_attempts + 1))
  log "soft failure $cur_attempts/$MAX_ATTEMPTS on $t (rung $cur_rung/$last)"
  if (( cur_attempts >= MAX_ATTEMPTS )); then
    if (( cur_rung < last )); then
      cur_rung=$((cur_rung + 1)); cur_attempts=0
      log "escalating $t → rung $cur_rung: $(rung_at "$t" "$cur_rung")"
    else
      log "max attempts on $t at top rung — stopping for a human"; board; exit 2
    fi
  fi
  sleep "$WAIT_SECONDS"
}

log "starting — default model=$MODEL effort=$EFFORT, in-place on $MAIN_BRANCH, ci_gate=$REQUIRE_CI"
mkdir -p "$WORKLOG"
for ((i = 1; i <= MAX_ITERS; i++)); do
  git -C "$ROOT" fetch origin --quiet 2>/dev/null || true
  sel="$(select_task || true)"
  if [ -z "$sel" ]; then
    log "no eligible task — backlog complete or everything left is gate/human-blocked."
    board; exit 0
  fi
  task="$sel"
  [ "$task" = "$cur_task" ] || { cur_task="$task"; cur_attempts=0; cur_rung=0; }
  read -r tmodel teffort <<<"$(rung_at "$task" "$cur_rung")"
  mode="fresh"; [ -n "$(git -C "$ROOT" status --porcelain)" ] && mode="resume"
  log "iteration $i/$MAX_ITERS → $task ($mode) on $tmodel/$teffort (rung $cur_rung)"

  RESULT="$WORKLOG/.result"; rm -f "$RESULT"

  # Run Claude, pausing + auto-resuming on usage/rate limits (NOT counted as a failure).
  rl_sleep="$RL_BACKOFF_MIN"
  while :; do
    set +e; run_claude "$tmodel" "$teffort" "$(prompt "$task")"; rc=$?; set -e
    if [ "$rc" = 10 ]; then
      log "Claude usage/rate limit hit — backing off ${rl_sleep}s, will RESUME the same task (not a failure)."
      sleep "$rl_sleep"
      rl_sleep=$(( rl_sleep * 2 )); [ "$rl_sleep" -gt "$RL_BACKOFF_MAX" ] && rl_sleep="$RL_BACKOFF_MAX"
      continue
    fi
    break
  done
  if [ "$rc" -ne 0 ]; then
    log "claude exited $rc (crash / non-rate-limit) — backing off ${WAIT_SECONDS}s"; sleep "$WAIT_SECONDS"; continue
  fi
  [ -f "$RESULT" ] || { log "no result file written — backing off"; sleep "$WAIT_SECONDS"; continue; }

  read -r status rtask extra <"$RESULT" || true
  case "$status" in
    done)
      log "agent reports $task built + committed"
      if ! guard_clean; then log "guard tripped — STOPPING for a human (inspect the staged/committed sensitive paths)"; board; exit 2; fi
      if ! git -C "$ROOT" push origin "HEAD:$MAIN_BRANCH"; then
        log "push to $MAIN_BRANCH failed (remote moved or network) — STOPPING for a human"; board; exit 2
      fi
      if [ "$REQUIRE_CI" = "1" ]; then
        if wait_ci_green; then
          mark_done "$task"; run_integrate_hook; log "integrated $task → $MAIN_BRANCH (CI green)"; cur_task=""; cur_attempts=0; cur_rung=0
        else
          log "CI RED for $task — STOPPING for a human. Revert with: git revert HEAD && git push"; board; exit 2
        fi
      else
        mark_done "$task"; run_integrate_hook; log "marked $task done (REQUIRE_CI=0; local DoD only)"; cur_task=""; cur_attempts=0; cur_rung=0
      fi
      ;;
    failed:soft)    log "agent soft-failed $rtask: ${extra:-}"; bump "$task" ;;
    failed:blocked) log "hard blocker on $rtask: ${extra:-} — stopping for a human"; board; exit 2 ;;
    waiting)        log "waiting on deps for $rtask: ${extra:-}"; sleep "$WAIT_SECONDS" ;;
    idle)           log "agent reports idle — nothing to do"; board; exit 0 ;;
    *)              log "unrecognized result '$status' — backing off"; sleep "$WAIT_SECONDS" ;;
  esac
  board
done

log "reached MAX_ITERS=$MAX_ITERS — stopping"; board; exit 4
