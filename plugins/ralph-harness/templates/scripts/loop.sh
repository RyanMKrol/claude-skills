#!/usr/bin/env bash
#
# loop.sh — the single SEQUENTIAL "Ralph loop" that builds a TASKS.json backlog.
#
# Exactly ONE task is built at a time, fully verified, and merged into `main` only on
# green GitHub CI — so an interruption (token limit, crash) can ever damage at most one
# task. See .harness/HARNESS.md for the full design and rationale.
#
# ISOLATION (why this uses a worktree even though it's sequential):
#   The machine is shared — other agents, a running app, or manual edits may all live in
#   the primary checkout. So the loop NEVER works in the primary checkout. It:
#     • reads its task decisions from `origin/main` (the integrated truth, branch-agnostic),
#     • does every task's build in its OWN dedicated sibling worktree (../<repo>-loop),
#     • integrates by fast-forwarding `main` via push — it never checks `main` out anywhere.
#   The only shared state it writes is the git ref db (fetch/worktree/branch) and its lock.
#
# CONCURRENCY GUARD:
#   A lock in the shared .git ensures two `loop.sh` instances can't run at once (the
#   second exits immediately). Combined with the worktree isolation above, the loop is
#   safe to run while other work happens on the box.
#
# Each iteration:
#   SELECT (shell)  — from origin/main: a resumable in-progress `tNNN` branch if one
#                     exists, else the next not-done task whose Depends-on are all done
#                     and which is NOT a 🚦 gate / 🔒 needs-human / blocked task. None → stop.
#   WORK   (claude) — one `claude -p` on the task's OWN model/effort (TASKS.json, defaults
#                     applied) builds that task in the isolated
#                     worktree on branch `tNNN`, runs the Definition of Done, commits, pushes.
#   GATE   (shell)  — watch that branch's GitHub CI run; green → fast-forward `main` (push)
#                     and tear the worktree/branch down; red → soft failure (agent fixes on resume).
#
# Usage:  .harness/loop.sh [TNNN]      # optional: force a specific task id this run
# Config: .harness/harness.env (sourced if present) and/or the environment override the
#         defaults below. Real environment > harness.env > built-in default.
set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # the .harness/ dir this script lives in
ROOT="$(git -C "$HARNESS_DIR" rev-parse --show-toplevel)"
GIT_COMMON="$(git -C "$ROOT" rev-parse --git-common-dir)"
case "$GIT_COMMON" in /*) ;; *) GIT_COMMON="$ROOT/$GIT_COMMON" ;; esac   # make absolute

# Optional project config (model, caps, CI workflow name, …). Uses `: "${VAR:=…}"` form,
# so anything already set in the real environment wins over it.
[ -f "$HARNESS_DIR/harness.env" ] && . "$HARNESS_DIR/harness.env"

NAME="$(basename "$ROOT")"                       # repo dir name → worktree + lock naming
MODEL="${MODEL:-claude-sonnet-4-6}"              # COLD-START FLOOR — the cheapest tier; the policy tunes UP from here (pin the full id; the bare alias drifts)
EFFORT="${EFFORT:-low}"                           # low|medium|high|xhigh|max — cheapest by default (bias-cheap; the ladder escalates on failure)
MAX_ATTEMPTS="${MAX_ATTEMPTS:-2}"                 # soft failures per rung before escalating (2: the global ladder is fine-grained, so fewer tries per rung bounds the total attempt budget)
MAX_ITERS="${MAX_ITERS:-100}"                     # global iteration cap (backstop)
WAIT_SECONDS="${WAIT_SECONDS:-30}"               # backoff between retries / CI polls
CI_TIMEOUT="${CI_TIMEOUT:-1200}"                 # max seconds to wait for a CI run to finish
CI_WORKFLOW="${CI_WORKFLOW:-CI}"                 # MUST match `name:` in your CI workflow yaml
REQUIRE_CI="${REQUIRE_CI:-1}"                     # 1 = never merge without green CI
INTEGRATE_HOOK="${INTEGRATE_HOOK:-}"             # optional cmd run after each task integrates (deploy/restart)
TASKS_REF="${TASKS_REF:-origin/main}"            # decisions are read from here, never a worktree
LOOP_WT="${LOOP_WT:-$(dirname "$ROOT")/${NAME}-loop}"   # the loop's own isolation worktree
LOCK="$GIT_COMMON/${NAME}-loop.lock"
CLAUDE_BIN="${CLAUDE_BIN:-claude}"
CLAUDE_FLAGS="${CLAUDE_FLAGS:---dangerously-skip-permissions}"
# Rate-limit handling: poll + resume the SAME task on a usage/session limit (don't exit), so we
# resume shortly after the quota resets rather than waiting out supervise's full cadence.
RL_POLL="${RL_POLL:-900}"                         # poll again every 15 min while limited
RL_MAX_WAIT="${RL_MAX_WAIT:-21600}"               # give up + exit for supervise after ~6h limited
FORCE_TASK="${1:-}"
POSTFLIGHT="$HARNESS_DIR/postflight.sh"

read -r -a FLAGS <<<"$CLAUDE_FLAGS"
log() { printf '[loop] %s\n' "$*" >&2; }
board() { [ -x "$POSTFLIGHT" ] && "$POSTFLIGHT" >/dev/null 2>&1 || true; }

# TASKS.json is parsed with jq throughout — fail fast if it's missing.
command -v jq >/dev/null 2>&1 || { log "jq is required to parse TASKS.json — install it (e.g. brew install jq)"; exit 3; }

# --- Concurrency guard: only one loop at a time (exit, don't queue) ---------
acquire_lock() {
  while ! mkdir "$LOCK" 2>/dev/null; do
    local owner; owner="$(cat "$LOCK/pid" 2>/dev/null || true)"
    if [ -n "$owner" ] && ! kill -0 "$owner" 2>/dev/null; then
      log "stale loop lock (dead PID $owner) — reclaiming"
      rm -f "$LOCK/pid"; rmdir "$LOCK" 2>/dev/null || true
    else
      log "another loop is already running (PID ${owner:-?}) — exiting."; exit 0
    fi
  done
  echo "$$" >"$LOCK/pid"
}
release_lock() {
  [ -f "$LOCK/pid" ] && [ "$(cat "$LOCK/pid" 2>/dev/null)" = "$$" ] \
    && { rm -f "$LOCK/pid"; rmdir "$LOCK" 2>/dev/null || true; } || true
}

# --- TASKS.json / worklog helpers (read from origin/main, NOT any working tree) -
# TASKS.json is the structured backlog (schema: .harness/HARNESS.md §8.1), parsed with jq.
blob()         { git -C "$ROOT" show "$TASKS_REF:.harness/$1" 2>/dev/null || true; }
tj()           { blob TASKS.json | jq "$@" 2>/dev/null; }                 # query TASKS.json
all_tasks()    { tj -r '.tasks[].id'; }                                   # in array (=dependency) order
task_done()    { tj -e --arg id "$1" '.tasks[]|select(.id==$id)|.status=="done"' >/dev/null; }
deps_for()     { tj -r --arg id "$1" '.tasks[]|select(.id==$id)|.dependsOn[]?' | tr '\n' ' '; }
task_gated()   { tj -e --arg id "$1" '.tasks[]|select(.id==$id)|.gate!=null' >/dev/null; }   # "gate"/"needs-human"
task_blocked() { blob "worklog/$1.md" | grep -qiE 'failed:blocked|needs-human'; }

# task_ladder <id> — print the task's build rungs, one "MODEL<TAB>EFFORT" per line, in order:
#   rung 0 = the primary (per-task model/effort, else .defaults); then each escalation rung.
# Escalation rungs (per-task `escalation`, else `defaults.escalation`) are the stronger models
# the loop climbs to after MAX_ATTEMPTS soft-failures on the rung below (.harness/HARNESS.md §3,§7).
task_ladder() {
  tj -r --arg id "$1" '
    (.defaults.model // "") as $dm | (.defaults.effort // "") as $de |
    (.defaults.escalation // []) as $desc |
    .tasks[] | select(.id==$id) |
    ( [ { model:(.model // $dm), effort:(.effort // $de) } ]
      + ( (.escalation // $desc) | map({ model:(.model // $dm), effort:(.effort // $de) }) )
    ) | .[] | "\(.model)\t\(.effort)"'
}
# --- Difficulty auto-tuning (see .harness/designs/difficulty-autotune.md) -----------------------------
# The loop no longer escalates a PER-TASK ladder; it rides ONE global difficulty ladder
# (facets.json .tiers.ladder, cheapest→priciest) offset by a policy-chosen START tier (cur_base).
# WORKTREE MODEL: decisions/state are read from origin/main via `blob` (never a working tree), and
# the outcome ledger is committed to main through a detached worktree (like block_task).
# (task_ladder above is retained but unused.)
POLICY_JQ="$HARNESS_DIR/policy.jq"               # .harness/policy.jq, alongside this loop
TIER_TUPLES=()   # portable (bash 3.2 — no mapfile): read the ladder into an array
while IFS= read -r _t; do TIER_TUPLES+=("$_t"); done \
  < <(blob facets.json | jq -r '.tiers.ladder[] | "\(.model) \(.effort)"' 2>/dev/null)
[ "${#TIER_TUPLES[@]}" -gt 0 ] || TIER_TUPLES=("$MODEL $EFFORT")    # fallback if facets.json absent
POLICY_FLOOR="$(blob facets.json | jq -r '.policy.floor // 0.75' 2>/dev/null)"; POLICY_FLOOR="${POLICY_FLOOR:-0.75}"
POLICY_MINN="$(blob facets.json | jq -r '.policy.minN // 6' 2>/dev/null)"; POLICY_MINN="${POLICY_MINN:-6}"

# gtier <idx> — echo "model effort" for the ladder tier at idx, clamped to [0, top].
gtier() {
  local idx="$1" last=$(( ${#TIER_TUPLES[@]} - 1 ))
  (( idx < 0 )) && idx=0; (( idx > last )) && idx=$last
  printf '%s' "${TIER_TUPLES[$idx]}"
}

# pick_base <id> — the policy's chosen START tier INDEX: cheapest ladder tier whose
# (layer × work-type) cell clears the floor with >= minN samples; else the authored difficulty
# (cold-start prior). Reads facets + ledger from origin/main via `blob`. Robust: any gap → the prior.
pick_base() {
  local id="$1" layer wt am ae cold tiers rows
  am="$(tj -r --arg id "$id" '.tasks[]|select(.id==$id)|.model // empty')"; am="${am:-$MODEL}"
  ae="$(tj -r --arg id "$id" '.tasks[]|select(.id==$id)|.effort // empty')"; ae="${ae:-$EFFORT}"
  tiers="$(blob facets.json | jq -c '.tiers.ladder' 2>/dev/null)"
  cold="$(jq -n --argjson t "${tiers:-[]}" --arg m "$am" --arg e "$ae" '($t|map(.model==$m and .effort==$e)|index(true)) // 1' 2>/dev/null)"; cold="${cold:-0}"
  layer="$(tj -r --arg id "$id" '.tasks[]|select(.id==$id)|.facets.layer // empty')"
  wt="$(tj -r --arg id "$id" '.tasks[]|select(.id==$id)|.facets.workType // empty')"
  rows="$(blob outcomes.jsonl | jq -s -c '.' 2>/dev/null)"
  if [ -z "$layer" ] || [ -z "$wt" ] || [ -z "$tiers" ] || [ -z "$rows" ] || [ "$rows" = "[]" ]; then printf '%s' "$cold"; return; fi
  jq -n --argjson rows "$rows" --argjson tiers "$tiers" --arg layer "$layer" --arg wt "$wt" \
     --argjson floor "$POLICY_FLOOR" --argjson minN "$POLICY_MINN" --argjson coldIdx "$cold" \
     -f "$POLICY_JQ" 2>/dev/null || printf '%s' "$cold"
}

# outcome_row <id> <blocked:true|false> [reason] — build ONE ledger JSON line (no I/O).
# cur_rung/cur_attempts are the live success (or top) rung; totalSoftFails is derivable.
outcome_row() {
  local id="$1" blocked="$2" reason="${3:-}" ts sm se fm fe
  local total=$(( cur_rung * MAX_ATTEMPTS + cur_attempts ))
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  read -r sm se <<<"$(rung_at "$id" 0)"
  read -r fm fe <<<"$(rung_at "$id" "$cur_rung")"
  tj --arg id "$id" --argjson blocked "$blocked" --arg reason "$reason" \
     --argjson rung "$cur_rung" --argjson atr "$cur_attempts" --argjson total "$total" \
     --arg sm "$sm" --arg se "$se" --arg fm "$fm" --arg fe "$fe" --arg ts "$ts" \
     -c '.tasks[]|select(.id==$id)|{
       id:$id, ts:$ts, facets:(.facets // null), scopeSize:(.scope|length),
       startModel:$sm, startEffort:$se, finalModel:$fm, finalEffort:$fe,
       succeededRung:(if $blocked then null else $rung end), topRung:$rung,
       attemptsAtRung:$atr, totalSoftFails:$total, blocked:$blocked, reason:$reason
     }'
}

# record_outcome <id> <blocked> [reason] — append an outcome row to the ledger ON MAIN, committed
# via a detached worktree (mirrors block_task). Used for the SUCCESS case; block_task folds the row
# into its own commit. Forward-only + best-effort — never fails the caller.
record_outcome() {
  local id="$1" line; line="$(outcome_row "$id" "$2" "${3:-}")"
  [ -n "$line" ] || { log "WARN: couldn't build outcome row for $id"; return 0; }
  git -C "$ROOT" fetch origin --quiet 2>/dev/null || true
  remove_wt
  if git -C "$ROOT" worktree add --quiet --force --detach "$LOOP_WT" origin/main 2>/dev/null; then
    printf '%s\n' "$line" >>"$LOOP_WT/.harness/outcomes.jsonl"
    git -C "$LOOP_WT" add .harness/outcomes.jsonl 2>/dev/null || true
    git -C "$LOOP_WT" commit -q -m "$id: record outcome [skip ci]" 2>/dev/null || true
    git -C "$LOOP_WT" push --quiet origin HEAD:main 2>/dev/null || log "WARN: couldn't push outcome for $id"
    remove_wt
  fi
}

# Rung machinery, now on the global ladder offset by cur_base (the policy's per-task start tier).
ladder_len() { echo $(( ${#TIER_TUPLES[@]} - cur_base )); }
rung_at()    { gtier $(( cur_base + ${2:-0} )); }

task_branch()  { printf 't%s' "${1#T}"; }                              # T014 -> t014
branch_task()  { printf '%s' "$1" | sed -E 's/^t([0-9]{3,})$/T\1/'; }  # t014 -> T014
inprogress_branch() { git -C "$ROOT" branch --format='%(refname:short)' | grep -E '^t[0-9]{3,}$' | head -1 || true; }

# SELECT — echo "TASK BRANCH fresh|resume"; return 1 if nothing is eligible.
select_task() {
  local br t d ok
  br="$(inprogress_branch)"
  if [ -n "$br" ]; then echo "$(branch_task "$br") $br resume"; return 0; fi
  if [ -n "$FORCE_TASK" ]; then echo "$FORCE_TASK $(task_branch "$FORCE_TASK") fresh"; return 0; fi
  for t in $(all_tasks); do
    task_done "$t" && continue
    task_gated "$t" && continue       # 🚦 gate / 🔒 needs-human — a human must act
    task_blocked "$t" && continue     # a prior attempt recorded failed:blocked
    ok=1; for d in $(deps_for "$t"); do task_done "$d" || { ok=0; break; }; done
    [ "$ok" = 1 ] && { echo "$t $(task_branch "$t") fresh"; return 0; }
  done
  return 1
}

# --- Isolated worktree management -------------------------------------------
remove_wt() {
  if [ -d "$LOOP_WT" ]; then
    git -C "$ROOT" worktree remove --force "$LOOP_WT" 2>/dev/null || rm -rf "$LOOP_WT"
  fi
  git -C "$ROOT" worktree prune 2>/dev/null || true
}
prepare_wt() {   # $1=branch  $2=fresh(1)|resume(0)
  local branch="$1" fresh="$2"
  git -C "$ROOT" fetch origin --quiet 2>/dev/null || true
  if [ "$fresh" = 1 ]; then
    remove_wt
    git -C "$ROOT" worktree add -b "$branch" "$LOOP_WT" origin/main
  else
    # Resume: reuse the worktree as-is if it's already on the branch (keep uncommitted
    # work); otherwise (re)attach it to the existing branch.
    if [ -d "$LOOP_WT" ] && [ "$(git -C "$LOOP_WT" rev-parse --abbrev-ref HEAD 2>/dev/null)" = "$branch" ]; then
      return 0
    fi
    remove_wt
    git -C "$ROOT" worktree add "$LOOP_WT" "$branch"
  fi
}
cleanup_task() {   # tear down after a successful integrate
  local branch="$1"
  remove_wt
  git -C "$ROOT" branch -D "$branch" 2>/dev/null || true
  git -C "$ROOT" push --quiet origin --delete "$branch" 2>/dev/null || true
}

# --- GitHub CI gate ---------------------------------------------------------
wait_ci_green() {   # 0=green 1=red 2=indeterminate
  local branch="$1" sha runid="" waited=0
  command -v gh >/dev/null 2>&1 || { log "gh not installed — cannot gate CI"; return 2; }
  sha="$(git -C "$ROOT" rev-parse "origin/$branch" 2>/dev/null || true)"
  [ -n "$sha" ] || { log "cannot resolve origin/$branch"; return 2; }
  log "waiting for CI ($CI_WORKFLOW) on $branch ($sha)…"
  while [ "$waited" -lt "$CI_TIMEOUT" ]; do
    runid="$(gh run list --branch "$branch" --limit 20 \
               --json databaseId,headSha,workflowName \
               --jq ".[] | select(.headSha==\"$sha\" and .workflowName==\"$CI_WORKFLOW\") | .databaseId" \
               2>/dev/null | head -1 || true)"
    [ -n "$runid" ] && break
    sleep "$WAIT_SECONDS"; waited=$((waited + WAIT_SECONDS))
  done
  [ -n "$runid" ] || { log "no '$CI_WORKFLOW' run appeared for $sha within ${CI_TIMEOUT}s"; return 2; }
  if gh run watch "$runid" --exit-status >/dev/null 2>&1; then
    log "CI GREEN (run $runid)"; return 0
  fi
  log "CI RED (run $runid) — gh run view $runid --log-failed"; return 1
}

# Integrate by fast-forwarding main. Single-flight keeps it a ff; if main moved
# (another actor pushed), the ff is rejected and we soft-fail so the agent absorbs it.
integrate() {
  local branch="$1"
  git -C "$LOOP_WT" push --quiet origin "$branch:main" 2>/dev/null && return 0
  log "ff to main rejected (main moved under us) — soft"; return 1
}

# Optional post-integration hook (deploy/restart so the running product matches main).
run_integrate_hook() {
  [ -n "$INTEGRATE_HOOK" ] || return 0
  log "integrate hook: $INTEGRATE_HOOK"
  ( cd "$ROOT" && eval "$INTEGRATE_HOOK" ) || log "WARN: integrate hook failed (non-fatal)"
}

# --- Per-task build prompt --------------------------------------------------
prompt() {
  local tid="$1" branch="$2"
  printf 'You are the autonomous builder for THIS repo. Build EXACTLY ONE task: %s, then stop.\n' "$tid"
  printf 'You are in a DEDICATED git worktree already checked out on branch `%s`. Work HERE only — do NOT switch branches, create branches, or touch any other checkout on this machine.\n' "$branch"
  cat <<'EOF'

Obey CLAUDE.md, .harness/TASKS.json, and .harness/HARNESS.md exactly. You run head-less and unattended.

1. RESUME, DON'T RESTART. This branch may already hold partial work from an interrupted
   attempt (commits and/or uncommitted changes) — keep it and CONTINUE. Read
   `.harness/worklog/<TASK>.md` (prior attempts) and this task's object in .harness/TASKS.json (find it with
   `jq '.tasks[]|select(.id=="<TASK>")' .harness/TASKS.json`); if its `design` field points to a
   `.harness/designs/…` doc, READ and follow it. RECONCILE THE DELTA: inspect what already
   exists/passes and do ONLY the outstanding work vs the task's `doneWhen`. Trust the code
   over the worklog. Stay within the task's `scope` files.
2. DEFINITION OF DONE (.harness/HARNESS.md §6 — all must hold before you report `done`):
   a. Run the project's full verification suite exactly as defined in CLAUDE.md /
      .harness/HARNESS.md §6 (format, lint, tests, build). These MIRROR CI — if CI runs it,
      run it locally first. Every check must pass.
   b. Run the task's relevant integration / end-to-end tests when their preconditions are
      met. Tests that need credentials, funds, or external resources you don't have: leave
      them as they are and record `failed:blocked` if the task's core needs them — never
      silently skip a required check and call it "passed".
   c. If the task's `verify` field names extra EMPIRICAL checks (e.g. run the app against
      real input for a bounded window and observe it behaves), perform them and record what
      you OBSERVED in the worklog. The bar is the behaviour the task specifies.
3. DOCS IN LOCKSTEP (same commit): set this task's `"status"` to `"done"` in .harness/TASKS.json (edit
   the JSON; keep it valid — `jq empty .harness/TASKS.json` must pass), flip its README.md status row,
   and add any new trade-off/limitation to .harness/LIMITATIONS.md.
4. COMMIT `<TASK>: <summary>` (INCLUDING `.harness/worklog/<TASK>.md` with a dated entry: what you did,
   checks run, what remains). Then push THIS branch: `git push -u origin HEAD`. Do NOT merge
   into `main` — the loop watches GitHub CI and fast-forwards main on green. If a previous
   push's CI for this branch failed, run `gh run view --log-failed` and fix the cause first.
5. As your FINAL action, OVERWRITE `.harness/worklog/.result` with exactly ONE line:
     done <TASK> <branch>                 # built, committed, pushed — ready for CI + merge
     failed:soft <TASK> <reason>          # transient / partial — retry is worthwhile
     failed:blocked <TASK> <reason>       # needs-human / unmet prereq — do NOT retry
     waiting <TASK> <unmet-deps>          # a dependency is not merged yet
     idle                                 # nothing to do for this task
EOF
}

# --- Claude invocation with rate-limit detection ----------------------------
RL_RE='usage limit|session limit|hit your .*limit|limit.*reset|rate.?limit|429|resets? (at|in)|try again later|overloaded|quota|insufficient.*credit|exceeded your'
# run_claude <model> <effort> <prompt> → 0 ok | 10 rate/usage-limited | other = failure
run_claude() {
  local model="$1" effort="$2" pr="$3" out="$LOOP_WT/.harness/worklog/.claude-out" rc
  set +e
  ( cd "$LOOP_WT" && "$CLAUDE_BIN" -p "$pr" --model "$model" --effort "$effort" "${FLAGS[@]}" ) 2>&1 | tee "$out"
  rc=${PIPESTATUS[0]}
  set -e
  if [ "$rc" -ne 0 ] && grep -qiE "$RL_RE" "$out"; then return 10; fi
  return "$rc"
}

# --- Dry run: print the task SELECT would build next, then exit (no lock, no work) ---
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

cur_task=""; cur_attempts=0; cur_rung=0; cur_base=0

# Give up on ONE task WITHOUT halting the loop: tear down its branch/worktree, record a
# failed:blocked marker on main (select_task reads worklog from origin/main, so it then skips the
# task), and move on. A human reviews blocked tasks later; the loop keeps progressing on the rest.
block_task() {
  local id="$1" reason="$2" br; br="$(task_branch "$id")"
  cleanup_task "$br"                                   # remove the loop worktree + delete tNNN (local+remote)
  git -C "$ROOT" fetch origin --quiet 2>/dev/null || true
  remove_wt
  if git -C "$ROOT" worktree add --quiet --force --detach "$LOOP_WT" origin/main 2>/dev/null; then
    mkdir -p "$LOOP_WT/worklog"
    printf '\n---\nfailed:blocked %s — %s\n' "$id" "$reason" >>"$LOOP_WT/.harness/worklog/$id.md"
    outcome_row "$id" true "$reason" >>"$LOOP_WT/.harness/outcomes.jsonl"   # fold the blocked outcome into THIS commit
    git -C "$LOOP_WT" add ".harness/worklog/$id.md" .harness/outcomes.jsonl 2>/dev/null || true
    git -C "$LOOP_WT" commit -q -m "$id: blocked, needs human — skipping [skip ci]" 2>/dev/null || true
    git -C "$LOOP_WT" push --quiet origin HEAD:main 2>/dev/null || log "WARN: couldn't push block marker for $id"
    remove_wt
  fi
  log "BLOCKED $id ($reason) — recorded on main; moving on to the next task."
  cur_task=""; cur_attempts=0; cur_rung=0; cur_base=0
}

bump() {   # count a soft failure for $1; escalate at the cap; BLOCK + move on past the top rung (never halt)
  local t="$1" last
  [ "$t" = "$cur_task" ] || { cur_task="$t"; cur_attempts=0; cur_rung=0; cur_base="$(pick_base "$t")"; }
  last=$(( $(ladder_len "$t") - 1 ))
  cur_attempts=$((cur_attempts + 1))
  log "soft failure $cur_attempts/$MAX_ATTEMPTS on $t (rung $cur_rung/$last)"
  if (( cur_attempts >= MAX_ATTEMPTS )); then
    if (( cur_rung < last )); then
      cur_rung=$((cur_rung + 1)); cur_attempts=0
      log "escalating $t → rung $cur_rung: $(rung_at "$t" "$cur_rung")"
    else
      block_task "$t" "exhausted $MAX_ATTEMPTS attempts at the top model rung"
      return 0
    fi
  fi
  sleep "$WAIT_SECONDS"
}

log "starting — default model=$MODEL effort=$EFFORT (per-task overrides from TASKS.json), isolated worktree=$LOOP_WT, ci_gate=$REQUIRE_CI"
# Pre-flight (difficulty auto-tuning): warn about BUILDABLE tasks missing facets. Non-fatal — the
# policy degrades to the authored prior. needs-human/gated tasks are correctly excluded (carved out).
_missing_facets="$(tj -r '[.tasks[]|select(.status!="done" and (.gate==null) and ((.facets|not) or (.facets.layer|not)))|.id]|join(", ")' 2>/dev/null || true)"
if [ -n "$_missing_facets" ]; then log "WARN: buildable tasks MISSING facets (no auto-tuning until tagged — see facets.json): $_missing_facets"; fi
for ((i = 1; i <= MAX_ITERS; i++)); do
  git -C "$ROOT" fetch origin --quiet 2>/dev/null || true
  sel="$(select_task || true)"
  if [ -z "$sel" ]; then
    log "no eligible task — backlog complete or everything left is gate/human-blocked."
    board; exit 0
  fi
  read -r task branch mode <<<"$sel"
  if [ "$task" != "$cur_task" ]; then
    cur_task="$task"; cur_attempts=0; cur_rung=0
    cur_base="$(pick_base "$task")"          # difficulty auto-tuning: policy picks the start tier
    log "policy: $task → start tier $cur_base ($(gtier "$cur_base")), ladder rungs $(ladder_len "$task")"
  fi
  read -r tmodel teffort <<<"$(rung_at "$task" "$cur_rung")"   # global-ladder tier at cur_base+cur_rung
  log "iteration $i/$MAX_ITERS → $task (branch $branch, $mode) on $tmodel/$teffort (rung $cur_rung)"

  fresh=0; [ "$mode" = "fresh" ] && fresh=1
  prepare_wt "$branch" "$fresh"

  RESULT="$LOOP_WT/.harness/worklog/.result"; rm -f "$RESULT"
  # Run Claude, polling + auto-resuming on usage/session limits (NOT a failure) so we resume soon
  # after the quota resets rather than waiting out supervise's full cadence.
  rl_waited=0
  while :; do
    set +e; run_claude "$tmodel" "$teffort" "$(prompt "$task" "$branch")"; rc=$?; set -e
    if [ "$rc" = 10 ]; then
      if [ "$rl_waited" -ge "$RL_MAX_WAIT" ]; then
        log "still usage/session-limited after ${rl_waited}s (cap ${RL_MAX_WAIT}s) — exiting for supervise to relaunch later."
        board; exit 5
      fi
      log "Claude usage/session limit hit — RESUMING the same task in ${RL_POLL}s (not a failure; waited ${rl_waited}s so far)."
      sleep "$RL_POLL"; rl_waited=$(( rl_waited + RL_POLL )); continue
    fi
    break
  done
  if [ "$rc" -ne 0 ]; then
    log "claude exited $rc (crash / out of tokens) — backing off ${WAIT_SECONDS}s"
    sleep "$WAIT_SECONDS"; continue
  fi
  [ -f "$RESULT" ] || { log "no result file written — backing off"; sleep "$WAIT_SECONDS"; continue; }

  read -r status rtask extra <"$RESULT" || true
  case "$status" in
    done)
      log "task $rtask built on branch $branch"
      if [ "$REQUIRE_CI" = "1" ] && ! wait_ci_green "$branch"; then
        log "CI not green for $task — soft (agent fixes on resume)"; bump "$task"; board; continue
      fi
      if integrate "$branch"; then
        record_outcome "$task" false                # difficulty auto-tuning: record the success on main
        log "integrated $task → main"; cleanup_task "$branch"; run_integrate_hook; cur_task=""; cur_attempts=0; cur_rung=0; cur_base=0
      else
        bump "$task"
      fi
      ;;
    failed:soft)    log "agent soft-failed $rtask: ${extra:-}"; bump "$task" ;;
    failed:blocked) log "agent reports blocker on $rtask: ${extra:-}"; block_task "$task" "agent reported failed:blocked — ${extra:-}" ;;
    waiting)        log "waiting on deps for $rtask: ${extra:-}"; sleep "$WAIT_SECONDS" ;;
    idle)           log "agent reports idle — nothing to do"; board; exit 0 ;;
    *)              log "unrecognized result '$status' — backing off"; sleep "$WAIT_SECONDS" ;;
  esac
  board
done

log "reached MAX_ITERS=$MAX_ITERS — stopping"; board; exit 4
