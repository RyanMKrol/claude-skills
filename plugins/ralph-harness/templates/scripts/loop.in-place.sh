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
#   (below) that refuses to push if any sensitive/gitignored path is staged. See .harness/HARNESS.md.
#
# Each iteration:
#   SELECT (shell)  — from TASKS.json: the next not-done task whose dependsOn are all done and
#                     which is NOT a 🚦 gate / 🔒 needs-human / blocked task. None → stop.
#   WORK   (claude) — one `claude -p` at the policy-chosen tier (facets + outcomes ledger; cold-start
#                     floor = harness.env) builds the task IN THIS CHECKOUT on main, runs the
#                     Definition of Done, and COMMITS (does NOT push).
#   GATE   (shell)  — pre-push guard (refuse if anything sensitive is staged) → push main → watch
#                     GitHub CI → green: mark the task done (+ optional integrate hook); red: STOP.
#
# Usage:  .harness/loop.sh [TNNN]          # optional: force a specific task id this run
#         DRY_RUN=1 .harness/loop.sh       # print the task it WOULD build, then exit
#         .harness/loop.sh --guard-selftest  # verify the pre-push guard regex, then exit
# Config: .harness/harness.env (sourced if present) and/or the environment.
set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # the .harness/ dir this script lives in
ROOT="$(git -C "$HARNESS_DIR" rev-parse --show-toplevel)"
GIT_COMMON="$(git -C "$ROOT" rev-parse --git-common-dir)"
case "$GIT_COMMON" in /*) ;; *) GIT_COMMON="$ROOT/$GIT_COMMON" ;; esac   # make absolute

[ -f "$HARNESS_DIR/harness.env" ] && . "$HARNESS_DIR/harness.env"

BACKLOG="$HARNESS_DIR/TASKS.json"
WORKLOG="$HARNESS_DIR/worklog"
OUTCOMES="$HARNESS_DIR/outcomes.jsonl"             # append-only escalation ledger — the SOLE input to difficulty calibration (forward-only)
FACETS="$HARNESS_DIR/facets.json"                  # facet vocabulary + global tier ladder + policy knobs
NAME="$(basename "$ROOT")"
MODEL="${MODEL:-claude-sonnet-4-6}"               # COLD-START FLOOR — the cheapest tier; the policy tunes UP from here as it learns (pin the full id; the bare alias drifts)
EFFORT="${EFFORT:-low}"                            # low|medium|high|xhigh|max — cheapest by default (bias-cheap; the ladder escalates on failure)
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
POSTFLIGHT="$HARNESS_DIR/postflight.sh"

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

[ -f "$BACKLOG" ] || { log "no .harness/TASKS.json — nothing to build"; exit 3; }

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
# A task's do/done-when live in a per-task Markdown spec, referenced by the JSON `spec` field
# (a repo-relative path, e.g. .harness/tasks/T001.md, with sections '## Do' / '## Done when').
task_spec_rel() { tj -r --arg id "$1" '.tasks[]|select(.id==$id)|.spec // empty'; }

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
      --arg verif "${cur_verification:-ci-only}" \
      -c '.tasks[]|select(.id==$id)|{
        id:$id, ts:$ts, facets:(.facets // null), scopeSize:(.scope|length),
        startModel:$sm, startEffort:$se, finalModel:$fm, finalEffort:$fe,
        succeededRung:(if $blocked then null else $rung end), topRung:$rung,
        attemptsAtRung:$atr, totalSoftFails:$total, blocked:$blocked, reason:$reason,
        verification:$verif
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

# --- Difficulty auto-tuning: global tier ladder + the calibration policy --------------------------
# The loop rides ONE global difficulty ladder (facets.json .tiers.ladder, cheapest→priciest) offset
# by a policy-chosen START tier (cur_base). rung 0 = the policy's start tier; escalation walks UP the
# global ladder. Tasks carry NO per-task model/effort/escalation — `facets` drive the policy and the
# global ladder is the safety net; the cold-start prior is just the cheapest tier. See .harness/HARNESS.md §6.
TIER_TUPLES=()   # portable (bash 3.2 — no mapfile): read the ladder into an array
while IFS= read -r _t; do TIER_TUPLES+=("$_t"); done \
  < <(jq -r '.tiers.ladder[] | "\(.model) \(.effort)"' "$FACETS" 2>/dev/null)
[ "${#TIER_TUPLES[@]}" -gt 0 ] || TIER_TUPLES=("$MODEL $EFFORT")     # fallback if facets.json absent
POLICY_FLOOR="$(jq -r '.policy.floor // 0.75' "$FACETS" 2>/dev/null || echo 0.75)"
POLICY_MINN="$(jq -r '.policy.minN // 6' "$FACETS" 2>/dev/null || echo 6)"
POLICY_JQ="$HARNESS_DIR/policy.jq"               # .harness/policy.jq, alongside this loop
# Verification-aware calibration knobs (the blocking audit gate — designs/audit-verification.md §4.6).
AUDIT_START_N="$(jq -r '.policy.auditStartN // 3' "$FACETS" 2>/dev/null || echo 3)"
AUDIT_FLOOR_N="$(jq -r '.policy.auditFloorN // 8' "$FACETS" 2>/dev/null || echo 8)"
AUDIT_FLOOR_PM="$(jq -r '((.policy.auditFloor // 0.10) * 1000) | round' "$FACETS" 2>/dev/null || echo 100)"
AUDITOR_MODEL="$(jq -r '.policy.auditorModel // "claude-opus-4-8"' "$FACETS" 2>/dev/null || echo claude-opus-4-8)"
AUDITOR_EFFORT="$(jq -r '.policy.auditorEffort // "medium"' "$FACETS" 2>/dev/null || echo medium)"
# Optional in-place "local DoD" gate the loop runs before the audit (the cheap CI-proxy). Empty =
# skip (CI still gates). Set in harness.env, e.g. LOCAL_DOD="<your format/lint/test/build commands>".
LOCAL_DOD="${LOCAL_DOD:-}"

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
     --argjson coldIdx "$cold" \
     --argjson auditCount -1 --argjson auditStartN "$AUDIT_START_N" --argjson auditFloorN "$AUDIT_FLOOR_N" --argjson auditFloorPM "$AUDIT_FLOOR_PM" \
     2>/dev/null || printf '%s' "$cold"
}

# Rung machinery, now on the global ladder offset by cur_base (the policy's per-task start tier).
ladder_len() { echo $(( ${#TIER_TUPLES[@]} - cur_base )); }
rung_at()    { gtier $(( cur_base + ${2:-0} )); }

# SELECT — echo the next eligible task id; return 1 if nothing is eligible.
select_task() {
  local t d ok
  if [ -n "$FORCE_TASK" ]; then
    # SAFETY: a forced id MUST be a real task in TASKS.json. Echoing a bogus id (typo, a stray flag
    # like --guard-selftest, an empty-ish value) would hand it to the builder and trigger a
    # destructive cold_reset build of a non-task. Refuse instead.
    if ! tj -e --arg id "$FORCE_TASK" '.tasks[]|select(.id==$id)' >/dev/null 2>&1; then
      log "FORCE_TASK '$FORCE_TASK' is not a real task id in TASKS.json — refusing to build it."
      return 1
    fi
    echo "$FORCE_TASK"; return 0
  fi
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
You run head-less and unattended. Obey CLAUDE.md, .harness/TASKS.json, and .harness/HARNESS.md exactly.

1. ORIENT. Read CLAUDE.md (conventions) and find this task:
   `jq '.tasks[]|select(.id=="<TASK>")' .harness/TASKS.json` (read its scope/verify and orchestration
   fields; if its `design` field points to a .harness/designs/… doc, READ and follow it). The task's
   `do` + `done-when` live in the Markdown spec at the JSON `spec` path (.harness/tasks/<TASK>.md,
   sections '## Do' / '## Done when') — its FULL TEXT is appended at the end of this prompt. You are
   starting COLD on a CLEAN tree: do NOT look for or rely on any prior-attempt state (worklog, partial
   work) — build this task FRESH from the spec alone. Stay within the task's `scope` files.

2. DEFINITION OF DONE (.harness/HARNESS.md §6 — all must hold before you report `done`):
   a. Run the project's full verification suite exactly as defined in CLAUDE.md / .harness/HARNESS.md §6
      (format, lint, tests, build). These MIRROR CI — run them locally first; every check must pass.
      Add tests for new behaviour.
   b. Run the task's integration / end-to-end checks when their preconditions are met. A check that
      needs credentials, funds, or external resources you don't have: never silently skip a required
      one and call it "passed" — record failed:blocked if the task's core needs it.
   c. If the task's `verify` field names extra EMPIRICAL checks, perform them and record what you
      OBSERVED in .harness/worklog/<TASK>.md.

3. SECRETS / PRIVACY — NON-NEGOTIABLE. Stage files EXPLICITLY by path; NEVER `git add -A` / `git add .`.
   NEVER `git add` anything under a `data/` folder, a `chrome-profile/`, a real `.env*`, or any
   credential file, and never edit .gitignore to un-ignore them. The loop's pre-push guard HALTS the
   whole run if any sensitive path is staged — so stage precisely.

4. DOCS IN LOCKSTEP (same commit): update README.md / CLAUDE.md if a convention or feature changed,
   and add any new trade-off to .harness/LIMITATIONS.md. Do NOT edit .harness/TASKS.json — the loop owns task
   status. Write your notes to .harness/worklog/<TASK>.md (a dated entry: what you did, checks run, what remains).

5. COMMIT `<TASK>: <summary>` (do NOT push), staging your intended files explicitly. Your commit
   MUST include `.harness/worklog/<TASK>.md` — stage it alongside your code. A task is not complete if its
   worklog isn't committed.

6. As your FINAL action, OVERWRITE .harness/worklog/.result with exactly ONE line:
     done <TASK>                     # built + committed (NOT pushed) — loop pushes + gates CI
     failed:soft <TASK> <reason>     # transient / partial — retry is worthwhile
     failed:blocked <TASK> <reason>  # needs-human / unmet prereq — do NOT retry
     waiting <TASK> <unmet-deps>     # a dependency is not done yet
     idle                            # nothing to do
EOF
  # Append the task's Markdown spec (## Do / ## Done when) verbatim — the SOLE source of do/done-when.
  local rel="" path
  rel="$(task_spec_rel "$tid")"
  if [ -n "$rel" ]; then
    path="$ROOT/$rel"
    if [ -f "$path" ]; then
      printf '\n\n--- Task %s spec (%s) ---\n' "$tid" "$rel"
      cat "$path"
    else
      printf '\n\n(WARNING: spec file %s referenced by %s is missing — read the task via jq.)\n' "$rel" "$tid"
    fi
  fi
}

# --- Verification-aware Definition of Done (designs/audit-verification.md) -------------------------
# cold_reset — discard ALL local state so every build attempt is an INDEPENDENT cold measurement (no
# worklog carryover, no partial-work resume). gitignored data/ is preserved (clean without -x).
cold_reset() {
  git -C "$ROOT" reset --hard "origin/$MAIN_BRANCH" >/dev/null 2>&1 || true
  git -C "$ROOT" clean -fd >/dev/null 2>&1 || true
}

# structural_checks <id> — cheap, model-agnostic gate on the build commit, BEFORE the audit. Any
# fail = a failed attempt. 0 = pass, 1 = fail.
structural_checks() {
  local id="$1" changed want_test
  changed="$(git -C "$ROOT" diff --name-only "origin/$MAIN_BRANCH..HEAD" 2>/dev/null)"
  if [ -z "$changed" ]; then log "structural: $id produced an EMPTY diff — fail"; return 1; fi
  want_test="$(tj -r --arg id "$id" '.tasks[]|select(.id==$id)|.expectsTest // false')"
  if [ "$want_test" = "true" ] && ! printf '%s\n' "$changed" | grep -qiE '(\.test\.|\.spec\.|_test\.|(^|/)test_|(^|/)tests?/)'; then
    log "structural: $id has expectsTest=true but no test file changed — fail"; return 1
  fi
  if [ -n "$LOCAL_DOD" ]; then
    log "structural: running LOCAL_DOD → $LOCAL_DOD"
    if ! ( cd "$ROOT" && eval "$LOCAL_DOD" ) >/dev/null 2>&1; then log "structural: LOCAL_DOD failed for $id — fail"; return 1; fi
  fi
  return 0
}

# audit_prompt <id> <spec> <diff> — the independent auditor's prompt (strict PASS/FAIL on ## Done when).
audit_prompt() {
  local id="$1" spec="$2" diff="$3"
  cat <<EOF
You are an INDEPENDENT AUDITOR. You did NOT write this code and you carry NO prior context. Another
agent implemented task $id; your ONLY job is to judge whether the implementation genuinely satisfies
the task's "## Done when" criteria below.

Respond with EXACTLY one word on the FIRST LINE: PASS or FAIL. Then, on following lines, give concise
reasons. PASS only if the diff meets EVERY "## Done when" item for real. FAIL if any item is unmet,
faked, stubbed, or only superficially addressed. Be strict — do not give the benefit of the doubt.

--- TASK $id SPEC ---
$spec

--- IMPLEMENTATION DIFF (origin/$MAIN_BRANCH..HEAD) ---
$diff
EOF
}

# audit_gate <id> — per-cell SAMPLED blocking audit (§4.3/4.6). Sets cur_verification. Spawns a fresh,
# independent auditor at max(opus-medium, builder tier) ONLY if sampled. 0 = pass (or not sampled),
# 1 = audit FAIL (a failed attempt).
audit_gate() {
  local id="$1" layer wt count pm bi ai am ae rel spec="" diff out verdict arc rlpoll
  cur_verification="ci-only"
  layer="$(tj -r --arg id "$id" '.tasks[]|select(.id==$id)|.facets.layer // empty')"
  wt="$(tj -r --arg id "$id" '.tasks[]|select(.id==$id)|.facets.workType // empty')"
  if [ -n "$layer" ] && [ -n "$wt" ] && [ -s "$OUTCOMES" ]; then
    count="$(jq -s --arg l "$layer" --arg w "$wt" '[.[]|select(.facets!=null and .facets.layer==$l and .facets.workType==$w and .blocked==false and .verification=="audited")]|length' "$OUTCOMES" 2>/dev/null || echo 0)"
  else count=0; fi
  count="${count:-0}"
  pm="$(jq -n -f "$POLICY_JQ" --argjson auditCount "$count" \
        --argjson auditStartN "$AUDIT_START_N" --argjson auditFloorN "$AUDIT_FLOOR_N" --argjson auditFloorPM "$AUDIT_FLOOR_PM" \
        --argjson rows '[]' --argjson tiers '[]' --arg layer '' --arg wt '' --argjson floor 0 --argjson minN 0 --argjson coldIdx 0 2>/dev/null || echo 1000)"
  pm="${pm:-1000}"
  if [ "$(( RANDOM % 1000 ))" -ge "$pm" ]; then
    log "audit: $id cell (${layer:-?}×${wt:-?}) $count confirmed, p=${pm}per-mille → NOT sampled (ci-only)"; return 0
  fi
  bi=$(( cur_base + cur_rung ))
  ai="$(jq -n --argjson t "$(jq -c '.tiers.ladder' "$FACETS" 2>/dev/null)" --arg m "$AUDITOR_MODEL" --arg e "$AUDITOR_EFFORT" '($t|map(.model==$m and .effort==$e)|index(true)) // 3' 2>/dev/null || echo 3)"
  (( ai > bi )) && bi=$ai
  read -r am ae <<<"$(gtier "$bi")"
  log "audit: $id cell (${layer:-?}×${wt:-?}) $count confirmed, p=${pm}per-mille → AUDITING at $am/$ae (max of opus-medium + builder rung)"
  diff="$(git -C "$ROOT" diff "origin/$MAIN_BRANCH..HEAD" 2>/dev/null)"
  rel="$(task_spec_rel "$id")"; [ -n "$rel" ] && [ -f "$ROOT/$rel" ] && spec="$(cat "$ROOT/$rel")"
  out="$WORKLOG/$id.audit.md"
  rlpoll="${RL_POLL:-${RL_BACKOFF_MIN:-300}}"
  while :; do
    set +e; run_claude "$am" "$ae" "$(audit_prompt "$id" "$spec" "$diff")"; arc=$?; set -e
    [ "$arc" = 10 ] && { log "auditor rate-limited — waiting ${rlpoll}s (NOT an audit fail)"; sleep "$rlpoll"; continue; }
    break
  done
  cp "$WORKLOG/.claude-out" "$out" 2>/dev/null || true
  verdict="$(grep -oiE '\b(PASS|FAIL)\b' "$out" 2>/dev/null | head -1 | tr '[:lower:]' '[:upper:]')"
  if [ "$verdict" = "PASS" ]; then cur_verification="audited"; log "audit: PASS for $id (reasons → $out)"; return 0; fi
  log "audit: FAIL for $id (verdict='${verdict:-none}', reasons → $out)"; return 1
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

# SAFETY: the in-place loop cold-resets the working tree (`git reset --hard origin/main`) between
# every attempt, which DISCARDS any uncommitted work in this checkout. If the tree is dirty at
# startup, that's external work the loop must NOT destroy — refuse to run (commit/stash first).
if [ -n "$(git -C "$ROOT" status --porcelain 2>/dev/null)" ]; then
  log "REFUSING TO RUN: '$ROOT' has uncommitted changes. The in-place loop cold-resets (git reset --hard) and would discard them. Commit or stash first."
  exit 3
fi

cur_task=""; cur_attempts=0; cur_rung=0; cur_base=0; cur_verification="ci-only"

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
# Pre-flight (difficulty auto-tuning): warn about BUILDABLE tasks missing facets. Non-fatal — the
# policy degrades to the authored prior, but a facet-less task gets no tuning + adds nothing to
# calibration. needs-human/gated tasks are correctly excluded (carved out).
_missing_facets="$(tj -r '[.tasks[]|select(.status!="done" and (.gate==null) and ((.facets|not) or (.facets.layer|not)))|.id]|join(", ")' 2>/dev/null || true)"
if [ -n "$_missing_facets" ]; then log "WARN: buildable tasks MISSING facets (no auto-tuning until tagged — see facets.json): $_missing_facets"; fi
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
  log "iteration $i/$MAX_ITERS → $task (cold) on $tmodel/$teffort (rung $cur_rung)"

  RESULT="$WORKLOG/.result"; rm -f "$RESULT"

  # Run Claude COLD, polling + auto-resuming on usage/session limits (NOT counted as a failure). Every
  # (re)attempt resets to a CLEAN tree first, so it measures one cold pass of this tier (§4.1).
  rl_waited=0
  while :; do
    cold_reset
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
      # Cheap structural gate (in-place local DoD) THEN the blocking audit — both BEFORE the push, so
      # a failure never reaches the remote (designs/audit-verification.md §3). Either fail = a failed
      # attempt: discard the commit + soft-retry (cold), escalating per the existing ladder.
      if ! structural_checks "$task"; then
        log "structural checks failed for $task — discarding commit + soft retry."
        cold_reset; bump "$task"; board; continue
      fi
      if ! audit_gate "$task"; then
        log "AUDIT FAILED for $task — discarding the commit (never pushed) + soft retry."
        cold_reset; bump "$task"; board; continue
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
