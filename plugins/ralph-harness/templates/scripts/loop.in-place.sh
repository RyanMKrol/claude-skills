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
OUTCOMES="$ROOT/outcomes.jsonl"                    # append-only escalation ledger — the SOLE input to difficulty calibration (forward-only)
FACETS="$ROOT/facets.json"                         # facet vocabulary + global tier ladder + policy knobs
NAME="$(basename "$ROOT")"
MODEL="${MODEL:-claude-opus-4-8}"                 # pin EXACTLY — the bare alias drifts
EFFORT="${EFFORT:-high}"                           # low|medium|high|xhigh|max
MAX_ATTEMPTS="${MAX_ATTEMPTS:-2}"                  # soft failures per rung before escalating (2: the global tier ladder is fine-grained, so fewer tries per rung bounds the total attempt budget)
MAX_ITERS="${MAX_ITERS:-100}"                      # global iteration backstop
WAIT_SECONDS="${WAIT_SECONDS:-30}"                 # backoff between retries / CI polls
CI_TIMEOUT="${CI_TIMEOUT:-1200}"                   # max seconds to wait for a CI run
CI_WORKFLOW="${CI_WORKFLOW:-CI}"                   # MUST match `name:` in the CI workflow yaml
REQUIRE_CI="${REQUIRE_CI:-1}"                      # 1 = never mark done without green CI
MAIN_BRANCH="${MAIN_BRANCH:-main}"
INTEGRATE_HOOK="${INTEGRATE_HOOK:-}"               # optional cmd run after each task integrates (deploy/restart)
CLAUDE_BIN="${CLAUDE_BIN:-claude}"
CLAUDE_FLAGS="${CLAUDE_FLAGS:---dangerously-skip-permissions}"
# Rate-limit-aware handling: when Claude hits a usage/session limit, POLL on a fixed short
# interval and resume the SAME task — so we retry soon after the quota resets, not hours later.
RL_POLL="${RL_POLL:-900}"                          # poll again every 15 min while limited
RL_MAX_WAIT="${RL_MAX_WAIT:-21600}"                # give up + exit for supervise after ~6h limited
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
# record_outcome <id> <blocked:true|false> [reason] — append ONE escalation-outcome row to the
# ledger (the sole input to difficulty calibration). FORWARD-ONLY: only fires for tasks the loop
# actually builds, so gated/needs-human tasks (never selected) are excluded by construction.
# Each escalation = exactly MAX_ATTEMPTS soft failures, so totalSoftFails is derivable. Best-effort —
# never fails the caller. cur_rung/cur_attempts are the live success (or top) rung at call time.
record_outcome() {
  local id="$1" blocked="$2" reason="${3:-}" line ts sm se fm fe
  local total=$(( cur_rung * MAX_ATTEMPTS + cur_attempts ))
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  read -r sm se <<<"$(rung_at "$id" 0)"             # start (cold-start prior) tier
  read -r fm fe <<<"$(rung_at "$id" "$cur_rung")"   # final tier actually used
  line="$(tj --arg id "$id" --argjson blocked "$blocked" --arg reason "$reason" \
      --argjson rung "$cur_rung" --argjson atr "$cur_attempts" --argjson total "$total" \
      --arg sm "$sm" --arg se "$se" --arg fm "$fm" --arg fe "$fe" --arg ts "$ts" \
      -c '.tasks[]|select(.id==$id)|{
        id:$id, ts:$ts, facets:(.facets // null), scopeSize:(.scope|length),
        startModel:$sm, startEffort:$se, finalModel:$fm, finalEffort:$fe,
        succeededRung:(if $blocked then null else $rung end), topRung:$rung,
        attemptsAtRung:$atr, totalSoftFails:$total, blocked:$blocked, reason:$reason
      }')"
  if [ -n "$line" ]; then printf '%s\n' "$line" >>"$OUTCOMES"; else log "WARN: couldn't record outcome for $id"; fi
}

mark_done() {
  local id="$1" tmp="$BACKLOG.tmp"   # same-dir temp → mv is an atomic rename (no cross-fs partial reads)
  jq --arg id "$id" '(.tasks[]|select(.id==$id)|.status)="done"' "$BACKLOG" >"$tmp" \
    && mv "$tmp" "$BACKLOG" || { rm -f "$tmp"; log "WARN: failed to mark $id done"; return 1; }
  record_outcome "$id" false                        # success → ledger row (succeededRung=cur_rung)
  git -C "$ROOT" add "$BACKLOG" "$WORKLOG" "$OUTCOMES" 2>/dev/null || true
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
# --- Difficulty auto-tuning: global tier ladder + the calibration policy --------------------------
# The loop no longer escalates a PER-TASK ladder; it rides ONE global difficulty ladder
# (facets.json .tiers.ladder, cheapest→priciest) offset by a policy-chosen START tier (cur_base).
# rung 0 = the policy's start tier; escalation walks UP the global ladder. The authored model/effort
# is only the cold-start prior. (task_ladder above is retained but unused.) See docs/HARNESS.md §6.
TIER_TUPLES=()   # portable (bash 3.2 — no mapfile): read the ladder into an array
while IFS= read -r _t; do TIER_TUPLES+=("$_t"); done \
  < <(jq -r '.tiers.ladder[] | "\(.model) \(.effort)"' "$FACETS" 2>/dev/null)
[ "${#TIER_TUPLES[@]}" -gt 0 ] || TIER_TUPLES=("$MODEL $EFFORT")     # fallback if facets.json absent
POLICY_FLOOR="$(jq -r '.policy.floor // 0.75' "$FACETS" 2>/dev/null || echo 0.75)"
POLICY_MINN="$(jq -r '.policy.minN // 6' "$FACETS" 2>/dev/null || echo 6)"
POLICY_JQ="$(dirname "$0")/policy.jq"               # scripts/policy.jq, alongside this loop

# gtier <idx> — echo "model effort" for the ladder tier at idx, clamped to [0, top].
gtier() {
  local idx="$1" last=$(( ${#TIER_TUPLES[@]} - 1 ))
  (( idx < 0 )) && idx=0; (( idx > last )) && idx=$last
  printf '%s' "${TIER_TUPLES[$idx]}"
}

# pick_base <id> — the policy's chosen START tier INDEX: the cheapest ladder tier whose
# (layer × work-type) cell historically clears the floor with >= minN samples; else the authored
# difficulty (cold-start prior). Robust: missing facets / empty ledger / any error → the prior.
pick_base() {
  local id="$1" layer wt am ae cold tiers
  am="$(tj -r --arg id "$id" '.tasks[]|select(.id==$id)|.model // empty')"; am="${am:-$MODEL}"
  ae="$(tj -r --arg id "$id" '.tasks[]|select(.id==$id)|.effort // empty')"; ae="${ae:-$EFFORT}"
  tiers="$(jq -c '.tiers.ladder' "$FACETS" 2>/dev/null)"
  cold="$(jq -n --argjson t "${tiers:-[]}" --arg m "$am" --arg e "$ae" '($t|map(.model==$m and .effort==$e)|index(true)) // 1' 2>/dev/null)"; cold="${cold:-0}"
  layer="$(tj -r --arg id "$id" '.tasks[]|select(.id==$id)|.facets.layer // empty')"
  wt="$(tj -r --arg id "$id" '.tasks[]|select(.id==$id)|.facets.workType // empty')"
  if [ -z "$layer" ] || [ -z "$wt" ] || [ ! -s "$OUTCOMES" ] || [ -z "$tiers" ] || [ ! -f "$POLICY_JQ" ]; then printf '%s' "$cold"; return; fi
  jq -n -f "$POLICY_JQ" --slurpfile rows "$OUTCOMES" --argjson tiers "$tiers" \
     --arg layer "$layer" --arg wt "$wt" --argjson floor "$POLICY_FLOOR" --argjson minN "$POLICY_MINN" \
     --argjson coldIdx "$cold" 2>/dev/null || printf '%s' "$cold"
}

# Rung machinery, now on the global ladder offset by cur_base (the policy's per-task start tier).
ladder_len() { echo $(( ${#TIER_TUPLES[@]} - cur_base )); }
rung_at()    { gtier $(( cur_base + ${2:-0} )); }

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
RL_RE='usage limit|session limit|hit your .*limit|limit.*reset|rate.?limit|429|resets? (at|in)|try again later|overloaded|quota|insufficient.*credit|exceeded your'
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

5. COMMIT `<TASK>: <summary>` (do NOT push), staging your intended files explicitly. Your commit
   MUST include `worklog/<TASK>.md` — stage it alongside your code. A task is not complete if its
   worklog isn't committed.

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

cur_task=""; cur_attempts=0; cur_rung=0; cur_base=0

# Give up on ONE task WITHOUT halting the loop: discard any local unpushed work, record a
# failed:blocked marker in the task's worklog (so select_task skips it from now on), push that,
# and move on. A human reviews blocked tasks later; the loop keeps making progress on everything
# else — one bad task never costs hours of idle.
block_task() {
  local id="$1" reason="$2"
  git -C "$ROOT" reset --hard "origin/$MAIN_BRANCH" 2>/dev/null || true   # drop any local unpushed commit/changes
  mkdir -p "$WORKLOG"
  printf '\n---\nfailed:blocked %s — %s\n' "$id" "$reason" >>"$WORKLOG/$id.md"
  record_outcome "$id" true "$reason"               # blocked → ledger row (succeededRung=null, topRung=cur_rung)
  git -C "$ROOT" add "$WORKLOG/$id.md" "$OUTCOMES" 2>/dev/null || true
  git -C "$ROOT" commit -q -m "$id: blocked, needs human — skipping [skip ci]" 2>/dev/null || true
  git -C "$ROOT" push origin "HEAD:$MAIN_BRANCH" 2>/dev/null || log "WARN: couldn't push block marker for $id"
  log "BLOCKED $id ($reason) — recorded for a human; moving on to the next task."
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
  if [ "$task" != "$cur_task" ]; then
    cur_task="$task"; cur_attempts=0; cur_rung=0
    cur_base="$(pick_base "$task")"          # difficulty auto-tuning: policy picks the start tier
    log "policy: $task → start tier $cur_base ($(gtier "$cur_base")), ladder rungs $(ladder_len "$task")"
  fi
  read -r tmodel teffort <<<"$(rung_at "$task" "$cur_rung")"
  mode="fresh"; [ -n "$(git -C "$ROOT" status --porcelain)" ] && mode="resume"
  log "iteration $i/$MAX_ITERS → $task ($mode) on $tmodel/$teffort (rung $cur_rung)"

  RESULT="$WORKLOG/.result"; rm -f "$RESULT"

  # Run Claude, polling + auto-resuming on usage/session limits (NOT counted as a failure) so we
  # pick the task back up shortly after the quota resets rather than waiting out a long backoff.
  rl_waited=0
  while :; do
    set +e; run_claude "$tmodel" "$teffort" "$(prompt "$task")"; rc=$?; set -e
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
    log "claude exited $rc (crash / non-rate-limit) — backing off ${WAIT_SECONDS}s"; sleep "$WAIT_SECONDS"; continue
  fi
  [ -f "$RESULT" ] || { log "no result file written — backing off"; sleep "$WAIT_SECONDS"; continue; }

  read -r status rtask extra <"$RESULT" || true
  case "$status" in
    done)
      log "agent reports $task built + committed"
      if ! guard_clean; then
        log "PRE-PUSH GUARD tripped on $task — sensitive path staged; discarding the commit + blocking."
        block_task "$task" "pre-push guard tripped (sensitive path staged)"; board; continue
      fi
      if ! git -C "$ROOT" push origin "HEAD:$MAIN_BRANCH"; then
        log "push to $MAIN_BRANCH failed (remote moved / network) — soft retry."
        bump "$task"; board; continue
      fi
      if [ "$REQUIRE_CI" = "1" ]; then
        if wait_ci_green; then
          mark_done "$task"; run_integrate_hook; log "integrated $task → $MAIN_BRANCH (CI green)"; cur_task=""; cur_attempts=0; cur_rung=0; cur_base=0
        else
          # NEVER halt the whole loop on one red CI: revert the pushed commit to restore main, then
          # soft-retry the task. If it keeps failing, bump eventually BLOCKS it and the loop moves on.
          log "CI RED for $task — reverting the pushed commit to restore $MAIN_BRANCH, then retrying."
          if git -C "$ROOT" revert --no-edit HEAD 2>/dev/null && git -C "$ROOT" push origin "HEAD:$MAIN_BRANCH" 2>/dev/null; then
            log "reverted $task; $MAIN_BRANCH is clean again."
          else
            log "WARN: auto-revert/push failed — main may need a manual: git revert HEAD && git push"
          fi
          bump "$task"
        fi
      else
        mark_done "$task"; run_integrate_hook; log "marked $task done (REQUIRE_CI=0; local DoD only)"; cur_task=""; cur_attempts=0; cur_rung=0; cur_base=0
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
