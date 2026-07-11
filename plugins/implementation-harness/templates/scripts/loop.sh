#!/usr/bin/env bash
# harness-loop-variant: worktree   # read by implementation-harness-upgrade to pick the right reference — do not remove
#
# loop.sh — the single SEQUENTIAL "Ralph loop" that builds a TASKS.json backlog.
#
# Exactly ONE task is built at a time, fully verified, and merged into `main` only on
# green GitHub CI — so an interruption (token limit, crash) can ever damage at most one
# task. See .harness/docs/HARNESS.md for the full design and rationale.
#
# ISOLATION (why this uses a worktree even though it's sequential):
#   The machine is shared — other agents, a running app, or manual edits may all live in
#   the primary checkout. So the loop NEVER works in the primary checkout. It:
#     • reads its task decisions from `origin/main` (the integrated truth, branch-agnostic),
#     • does every task's build in its OWN dedicated sibling worktree (../<repo>-loop),
#     • integrates by fast-forwarding `main` via push — WHILE BUILDING it never checks `main` out anywhere.
#   The only shared state it writes is the git ref db (fetch/worktree/branch) and its lock.
#   ONCE THE BACKLOG IS DRAINED and the loop exits cleanly, it optionally leaves your PRIMARY checkout on
#   the latest `main` — a convenience so your local copy reflects everything that just landed. This is the
#   one time it touches the primary checkout, and it's SAFE + best-effort: it skips a dirty tree (never
#   clobbers uncommitted work), fast-forwards only, and is non-fatal. See sync_primary_checkout(); disable
#   with SYNC_PRIMARY_ON_DONE=0.
#
# CONCURRENCY GUARD:
#   A lock in the shared .git ensures two `loop.sh` instances can't run at once (the
#   second exits immediately). Combined with the worktree isolation above, the loop is
#   safe to run while other work happens on the box.
#
# Each iteration:
#   SELECT (shell)  — from origin/main: the next not-done task whose Depends-on are all done
#                     and which is NOT a 🔒 needs-human / blocked task. None → stop.
#   WORK   (claude) — one `claude -p` at the policy-chosen tier (facets + the outcomes ledger pick
#                     the cheapest model that reliably builds this kind of task; cold-start floor =
#                     harness.env) builds that task in a FRESH isolated worktree on branch `tNNN`
#                     (rebuilt COLD each attempt), runs the Definition of Done, commits, pushes.
#   GATE   (shell)  — watch the branch's CI; green → audit → fast-forward `main` (push) and tear the
#                     worktree/branch down; red / audit-fail → a failed attempt (tear down → COLD retry).
#
# Usage:  .harness/scripts/loop.sh [TNNN]  # optional: force a specific task id this run
#         .harness/scripts/loop.sh --guard-selftest [path]  # verify the guard regex (or test one path), then exit
#         .harness/scripts/loop.sh --scope-exempt-selftest [globs path]  # verify SCOPE_EXEMPT_GLOBS matching, then exit
#         .harness/scripts/loop.sh --scope-selftest [entry file]  # verify scope-entry matching (extension globs), then exit
#         .harness/scripts/loop.sh --rl-selftest detect|wait …    # verify usage-limit detection + reset parsing, then exit
# Extend: drop scripts under .harness/custom/hooks/ (on-<event>.sh) and patterns in
#         .harness/custom/sensitive-paths.txt — see .harness/docs/HARNESS.md "Extending the harness".
# Config: .harness/config/harness.env (sourced if present) and/or the environment override the
#         defaults below. Real environment > harness.env > built-in default.
set -euo pipefail

# ─── Refuse to run from inside a Claude Code process (no override, by design) ───────────────────
# Starting (or single-passing) the build loop is a deliberate, human-hands action from a real
# terminal — never something an agent decides on its own initiative (an interactive session
# "helpfully" spinning up the loop for an unrelated request, or a builder task recursively
# starting another loop instance mid-build). Claude Code sets CLAUDECODE=1 in every Bash tool
# subprocess it spawns, regardless of session mode (-p / interactive, --dangerously-skip-
# permissions or not) — detect and hard-refuse, unconditionally. No override env var exists on
# purpose: an agent that could be told to set one could just as easily be told to run this anyway.
if [ -n "${CLAUDECODE:-}" ]; then
  echo "ABORT: this script must be run manually, from a real terminal — never from within a Claude Code session (detected \$CLAUDECODE=1). If Claude suggested running this, decline; run it yourself." >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"    # .harness/scripts — this script's own dir
HARNESS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"                    # the .harness/ dir (config/ docs/ ledgers/ scripts/ tasks/ tracking/ worklog/)
ROOT="$(git -C "$HARNESS_DIR" rev-parse --show-toplevel)"
GIT_COMMON="$(git -C "$ROOT" rev-parse --git-common-dir)"
case "$GIT_COMMON" in /*) ;; *) GIT_COMMON="$ROOT/$GIT_COMMON" ;; esac   # make absolute

# Optional project config (model, caps, CI workflow name, …). Uses `: "${VAR:=…}"` form,
# so anything already set in the real environment wins over it.
[ -f "$HARNESS_DIR/config/harness.env" ] && . "$HARNESS_DIR/config/harness.env"

# Shared mkdir-based repo lock (acquire_lock/release_lock) — sourced so its path derivation can
# never drift from other scripts (mark-*.sh, consolidate-ideas.sh) that coordinate with this loop.
. "$SCRIPT_DIR/repo-lock.sh"
# Shared scope-matching (normalize_scope_prefix + scope_match) — the SINGLE implementation, also sourced
# by loop.in-place.sh + check-task-scope.sh so the gate and the linter can never disagree.
. "$SCRIPT_DIR/scope-lib.sh"

NAME="$(basename "$ROOT")"                       # repo dir name → worktree + lock naming
MODEL="${MODEL:-claude-haiku-4-5}"              # COLD-START FLOOR — the cheapest tier; the policy tunes UP from here (pin the full id; the bare alias drifts)
EFFORT="${EFFORT:-}"                              # low|medium|high|xhigh|max, or empty for a model with no effort param (e.g. the default floor, Haiku) — the ladder escalates on failure
MAX_ATTEMPTS="${MAX_ATTEMPTS:-2}"                 # soft failures per rung before escalating (2: the global ladder is fine-grained, so fewer tries per rung bounds the total attempt budget)
MAX_ITERS="${MAX_ITERS:-100}"                     # global iteration cap (backstop)
WAIT_SECONDS="${WAIT_SECONDS:-30}"               # backoff between retries / CI polls
CI_TIMEOUT="${CI_TIMEOUT:-1200}"                 # max seconds to wait for a CI run to finish
CI_WORKFLOW="${CI_WORKFLOW:-CI}"                 # MUST match `name:` in your CI workflow yaml
REQUIRE_CI="${REQUIRE_CI:-1}"                     # 1 = never merge without green CI
INTEGRATE_HOOK="${INTEGRATE_HOOK:-}"             # optional cmd run after each task integrates (deploy/restart)
VISUAL_VERIFY_HOOK="${VISUAL_VERIFY_HOOK:-${UI_VERIFY_HOOK:-}}"   # optional cmd for VISUAL verification (any platform); UI_VERIFY_HOOK is the back-compat alias
VISUAL_VERIFY_WORKTYPES="${VISUAL_VERIFY_WORKTYPES:-component style}"      # inherently-visual workTypes that auto-trigger on ANY layer
VISUAL_VERIFY_LAYERS="${VISUAL_VERIFY_LAYERS:-frontend}"                   # facet layers that auto-trigger (unless the workType is in SKIP below)
VISUAL_VERIFY_SKIP_WORKTYPES="${VISUAL_VERIFY_SKIP_WORKTYPES:-docs config logging}"   # workTypes with no visual surface — never auto-trigger on a VISUAL_VERIFY_LAYERS layer
SCOPE_EXEMPT_GLOBS="${SCOPE_EXEMPT_GLOBS:-}"     # optional space-separated extra path prefixes structural_checks always allows, beyond worklog+tests
PUSH_COOLDOWN_SECONDS="${PUSH_COOLDOWN_SECONDS:-0}"   # optional min seconds between integration pushes (0=off) — see harness.env
TASKS_REF="${TASKS_REF:-origin/main}"            # decisions are read from here, never a worktree
LOOP_WT="${LOOP_WT:-$(dirname "$ROOT")/${NAME}-loop}"   # the loop's own isolation worktree
SYNC_PRIMARY_ON_DONE="${SYNC_PRIMARY_ON_DONE:-1}"   # when the loop finishes (backlog drained), leave the PRIMARY checkout on the latest main (safe/ff-only, skips a dirty tree); 0=never touch the primary checkout
CLAUDE_BIN="${CLAUDE_BIN:-claude}"
CLAUDE_FLAGS="${CLAUDE_FLAGS:---dangerously-skip-permissions}"
PRINT_PROMPT="${PRINT_PROMPT:-1}"                # 1 = echo each prompt (the running phase only: build OR audit) to the console before invoking Claude; 0 = silence
# Rate-limit handling: poll + resume the SAME task on a usage/session limit (don't exit), so we
# resume shortly after the quota resets rather than waiting out supervise's full cadence. A PARSED
# reset time is honoured directly (+ RL_BUFFER cushion, capped at RL_BACKOFF_MAX); when nothing
# parses, the build path backs off exponentially (RL_BACKOFF_MIN doubling to RL_EXP_MAX) instead of
# hammering a fixed poll — the notice usually means the window is exhausted for a while.
RL_POLL="${RL_POLL:-900}"                         # audit-path fallback poll while limited
RL_MAX_WAIT="${RL_MAX_WAIT:-21600}"               # give up + exit for supervise after ~6h limited
RL_BACKOFF_MIN="${RL_BACKOFF_MIN:-300}"           # exponential-fallback FIRST sleep (unknown reset)
RL_EXP_MAX="${RL_EXP_MAX:-3600}"                  # exponential-fallback cap (unknown-reset path only)
RL_BACKOFF_MAX="${RL_BACKOFF_MAX:-18000}"         # cap for a PARSED reset wait (~5h — a known reset can be hours away)
FORCE_TASK=""; [ "${1:-}" != "--guard-selftest" ] && [ "${1:-}" != "--scope-exempt-selftest" ] && [ "${1:-}" != "--scope-selftest" ] && [ "${1:-}" != "--rl-selftest" ] && FORCE_TASK="${1:-}"
POSTFLIGHT="$SCRIPT_DIR/postflight.sh"

read -r -a FLAGS <<<"$CLAUDE_FLAGS"
log() { printf '[loop] %s\n' "$*" >&2; }
board() { [ -x "$POSTFLIGHT" ] && "$POSTFLIGHT" >/dev/null 2>&1 || true; }

# run_hook <event> [args…] — run .harness/custom/hooks/on-<event>.sh if present. Child process
# (never sourced, cannot touch loop state), NON-FATAL, best-effort. Exports harness context. May
# recur (e.g. every supervise cycle that drains), so a hook MUST be cheap + idempotent.
run_hook() {
  local event="$1"; shift
  local hook="$HARNESS_DIR/custom/hooks/on-$event.sh"
  [ -f "$hook" ] || return 0
  log "lifecycle hook: on-$event ($*)"
  HARNESS_ROOT="$ROOT" HARNESS_DIR="$HARNESS_DIR" HARNESS_MAIN_BRANCH="${MAIN_BRANCH:-main}" \
    bash "$hook" "$@" || log "WARN: on-$event hook exited non-zero (non-fatal)"
}

# _hms <seconds> → human duration like "4h 34m" / "12m" / "45s"
_hms() {
  local s="$1" h m
  h=$(( s / 3600 )); m=$(( (s % 3600) / 60 ))
  if [ "$h" -gt 0 ]; then printf '%dh %dm' "$h" "$m"
  elif [ "$m" -gt 0 ]; then printf '%dm' "$m"
  else printf '%ds' "$s"; fi
}

# rl_banner <seconds> <claude-out-file> [note] — human-readable usage-limit banner: echoes what
# Claude reported, how long we sleep, and the WALL-CLOCK resume time (so an unattended overnight run
# is diagnosable from the log alone, and the sleep can be sanity-checked against the reset Claude
# quoted). Mirrors supervise.sh's boxed style.
rl_banner() {
  local secs="$1" outf="$2" note="${3:-}" reset_txt resume
  reset_txt="$(grep -hoiE 'resets[^.)]{0,60}\)?' "$outf" "${outf}.jsonl" 2>/dev/null | tail -1)"   # raw sibling too — the notice isn't a text_delta, so it's only in the .jsonl
  resume="$(date -v+"${secs}"S '+%a %H:%M %Z' 2>/dev/null || date -d "+${secs} seconds" '+%a %H:%M %Z' 2>/dev/null || echo "in $(_hms "$secs")")"
  log "══════════════════════════════════════════════════════════════════════"
  log "🛑 Claude usage/session limit hit — NOT a failure; the loop will auto-resume."
  [ -n "$reset_txt" ] && log "   Claude says: ${reset_txt}"
  [ -n "$note" ] && log "   $note"
  log "   ⏳ Sleeping $(_hms "$secs")  →  resuming ~${resume}, then RE-ATTEMPT COLD."
  log "   ✅ SAFE TO Ctrl-C NOW — nothing is running."
  log "══════════════════════════════════════════════════════════════════════"
}

# TASKS.json is parsed with jq throughout — fail fast if it's missing.
command -v jq >/dev/null 2>&1 || { log "jq is required to parse TASKS.json — install it (e.g. brew install jq)"; exit 3; }

# --- TASKS.json / worklog helpers (read from origin/main, NOT any working tree) -
# TASKS.json is the structured backlog (schema: .harness/docs/HARNESS.md §8.1), parsed with jq.
blob()         { git -C "$ROOT" show "$TASKS_REF:.harness/$1" 2>/dev/null || true; }
tj()           { blob tracking/TASKS.json | jq "$@" 2>/dev/null; }        # query TASKS.json
all_tasks()    { tj -r '.tasks[].id'; }                                   # in array (=dependency) order
task_done()    { tj -e --arg id "$1" '.tasks[]|select(.id==$id)|.status=="done"' >/dev/null; }
deps_for()     { tj -r --arg id "$1" '.tasks[]|select(.id==$id)|.dependsOn[]?' | tr '\n' ' '; }
task_gated()   { tj -e --arg id "$1" '.tasks[]|select(.id==$id)|.gate=="needs-human"' >/dev/null; }   # 🔒 needs-human — the loop never selects it
# A task the owner marked FAILED, reconciled into TASKS.json status="failed" by reconcile_overlays().
# TERMINAL: never (re)select it — else reconcile flips the false-success done→failed each iteration
# while select_task keeps rebuilding it, an infinite loop that also reverts the owner's verdict.
task_failed()  { tj -e --arg id "$1" '.tasks[]|select(.id==$id)|.status=="failed"' >/dev/null; }
# A loop-exhausted task: status="blocked" is set directly by block_task() — a first-class TASKS.json
# status value, so the dashboard can see it the same way it sees a manual-fail. The worklog-marker
# check is a fallback for tasks blocked before this existed; a task blocked going forward gets both.
task_blocked() {
  tj -e --arg id "$1" '.tasks[]|select(.id==$id)|.status=="blocked"' >/dev/null 2>&1 \
    || blob "worklog/$1.md" | grep -qiE 'failed:blocked|needs-human'
}
# A task's do/done-when live in a per-task Markdown spec, referenced by the JSON `spec` field
# (a repo-relative path, e.g. .harness/tasks/T001.md, with sections '## Do' / '## Done when').
task_spec_rel() { tj -r --arg id "$1" '.tasks[]|select(.id==$id)|.spec // empty'; }

# --- Difficulty auto-tuning (see .harness/docs/designs/difficulty-autotune.md) -----------------------------
# The loop rides ONE global difficulty ladder (facets.json .tiers.ladder, cheapest→priciest) offset
# by a policy-chosen START tier (cur_base). Tasks carry NO per-task model/effort/escalation — `facets`
# drive the policy and the global ladder is the safety net; the cold-start prior is the cheapest tier.
# WORKTREE MODEL: decisions/state are read from origin/main via `blob` (never a working tree), and
# the outcome ledger is committed to main through a detached worktree (like block_task).
POLICY_JQ="$SCRIPT_DIR/policy.jq"                # .harness/scripts/policy.jq, alongside this loop
TIER_TUPLES=()   # portable (bash 3.2 — no mapfile): read the ladder into an array
while IFS= read -r _t; do TIER_TUPLES+=("$_t"); done \
  < <(blob config/facets.json | jq -r '.tiers.ladder[] | "\(.model) \(.effort // "")"' 2>/dev/null)
[ "${#TIER_TUPLES[@]}" -gt 0 ] || TIER_TUPLES=("$MODEL $EFFORT")    # fallback if facets.json absent
POLICY_FLOOR="$(blob config/facets.json | jq -r '.policy.floor // 0.75' 2>/dev/null)"; POLICY_FLOOR="${POLICY_FLOOR:-0.75}"
POLICY_MINN="$(blob config/facets.json | jq -r '.policy.minN // 6' 2>/dev/null)"; POLICY_MINN="${POLICY_MINN:-6}"
# Downward exploration (designs/difficulty-autotune.md): per-mille chance an eligible task probes one
# untested rung below the policy's normal pick. 0 (default) preserves today's behavior exactly.
POLICY_EXPLORE_PM="$(blob config/facets.json | jq -r '.policy.exploreProbabilityPM // 0' 2>/dev/null)"; POLICY_EXPLORE_PM="${POLICY_EXPLORE_PM:-0}"
# Periodic recheck of a rejected exploration rung: rows of other cell activity that must land since
# that rung's last touch before it's offered again (batch-boundary judgment — see policy.jq header).
POLICY_EXPLORE_COOLDOWN_N="$(blob config/facets.json | jq -r '.policy.exploreCooldownN // 20' 2>/dev/null)"; POLICY_EXPLORE_COOLDOWN_N="${POLICY_EXPLORE_COOLDOWN_N:-20}"
# Verification-aware calibration knobs (the blocking audit gate — designs/audit-verification.md §4.6). Read from origin/main via blob.
AUDIT_START_N="$(blob config/facets.json | jq -r '.policy.auditStartN // 3' 2>/dev/null)"; AUDIT_START_N="${AUDIT_START_N:-3}"
AUDIT_FLOOR_N="$(blob config/facets.json | jq -r '.policy.auditFloorN // 8' 2>/dev/null)"; AUDIT_FLOOR_N="${AUDIT_FLOOR_N:-8}"
AUDIT_FLOOR_PM="$(blob config/facets.json | jq -r '((.policy.auditFloor // 0.10) * 1000) | round' 2>/dev/null)"; AUDIT_FLOOR_PM="${AUDIT_FLOOR_PM:-100}"
AUDITOR_MODEL="$(blob config/facets.json | jq -r '.policy.auditorModel // "claude-opus-4-8"' 2>/dev/null)"; AUDITOR_MODEL="${AUDITOR_MODEL:-claude-opus-4-8}"
AUDITOR_EFFORT="$(blob config/facets.json | jq -r '.policy.auditorEffort // "medium"' 2>/dev/null)"; AUDITOR_EFFORT="${AUDITOR_EFFORT:-medium}"
LOCAL_DOD="${LOCAL_DOD:-}"   # optional cheap gate run before the audit; empty = rely on CI (which the worktree variant already has)
FAILURES_BUF="$HARNESS_DIR/worklog/.failures.buf"   # gitignored, in the PRIMARY checkout (survives worktree rebuilds); per-current-task, flushed into ledgers/failures.jsonl at each terminal outcome

# ─── Heartbeat: the dashboard's live "Now" view, AND the escalation-ladder resume signal ────────
# worklog/.current.json in the PRIMARY checkout — a best-effort breadcrumb of what the loop is doing
# RIGHT NOW (task, phase, rung, attempt, base tier). Written at phase transitions; cleared ONLY at a
# genuine terminal outcome for the current task (block_task(), a done-integration branch, or the
# drained-backlog exit) — NOT in the EXIT/INT/TERM trap. So a heartbeat still present at process
# START means the PRIOR process never reached one of those terminal points: a hard kill/crash, or
# (via supervise.sh) a relaunch after exit 4 (MAX_ITERS) or exit 5 (rate-limit) — i.e. a genuinely
# interrupted mid-climb, not a fresh cold start. That leftover file IS read back once, near the top
# of the main loop below, to resume cur_rung/cur_attempts/cur_base instead of cold-starting the
# ladder — see the "resume an interrupted mid-climb" block. Every write is still `|| true`; it lives
# among the gitignored worklog scratch so it can never be committed or affect a diff.
HEARTBEAT="$HARNESS_DIR/worklog/.current.json"
heartbeat() {
  printf '{"task":"%s","phase":"%s","rung":%s,"attempt":%s,"base":%s,"model":"%s","effort":"%s","startedAt":"%s","updatedAt":"%s"}\n' \
    "${cur_task:-}" "$1" "${cur_rung:-0}" "${cur_attempts:-0}" "${cur_base:-0}" "${tmodel:-}" "${teffort:-}" "${hb_started:-}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$HEARTBEAT" 2>/dev/null || true
}
heartbeat_clear() { rm -f "$HEARTBEAT" 2>/dev/null || true; }

# gtier <idx> — echo "model effort" for the ladder tier at idx, clamped to [0, top].
gtier() {
  local idx="$1" last=$(( ${#TIER_TUPLES[@]} - 1 ))
  (( idx < 0 )) && idx=0; (( idx > last )) && idx=$last
  printf '%s' "${TIER_TUPLES[$idx]}"
}

# tier_strength <model> <effort> — total strength order over ANY (model, effort) pair, INDEPENDENT of
# the ladder (model dominates, then effort). Lets audit_gate honour a configured auditor tier that
# isn't a ladder rung, instead of snapping it to an arbitrary ladder index.
tier_strength() {
  local m="$1" e="$2" mr er
  case "$m" in *opus*) mr=1 ;; *) mr=0 ;; esac
  case "$e" in low) er=0 ;; medium) er=1 ;; high) er=2 ;; xhigh) er=3 ;; max) er=4 ;; *) er=0 ;; esac
  echo $(( mr * 10 + er ))
}

# rand_pm — uniform integer in 0..999. $RANDOM spans 0..32767, and 32768 % 1000 != 0, so a bare
# `RANDOM % 1000` over-weights 0..767 — enough to skew the sampled audit rate slightly below the
# configured per-mille. Rejection-sample below 32000 (32 exact cycles of 1000) before reducing.
rand_pm() {
  local r
  while :; do r=$RANDOM; [ "$r" -lt 32000 ] && break; done
  echo $(( r % 1000 ))
}

# pick_base <id> — prints TWO space-separated tokens: the policy's chosen START tier INDEX
# (cheapest ladder tier whose (layer × work-type) cell clears the floor with >= minN samples; else
# the harness.env MODEL/EFFORT floor / cold-start prior), and whether this call rolled into a
# downward-exploration probe (1) or not (0) — the caller must capture BOTH via
# `read -r cur_base cur_explored <<<"$(pick_base "$id")"`, never `cur_base="$(pick_base "$id")"`
# alone (command substitution is a subshell; a variable set INSIDE this function cannot escape it,
# which is why the explored flag is returned on stdout instead). facets are the ONLY per-task
# difficulty signal — a stray hand-added per-task "model"/"effort" field is deliberately ignored,
# never an override. Reads facets + ledger from origin/main via `blob`. Robust: any gap → the prior.
pick_base() {
  local id="$1" layer wt cold tiers rows
  tiers="$(blob config/facets.json | jq -c '.tiers.ladder' 2>/dev/null)"
  cold="$(jq -n --argjson t "${tiers:-[]}" --arg m "$MODEL" --arg e "$EFFORT" '($t|map(.model==$m and .effort==($e|if .=="" then null else . end))|index(true)) // 1' 2>/dev/null)"; cold="${cold:-0}"
  layer="$(tj -r --arg id "$id" '.tasks[]|select(.id==$id)|.facets.layer // empty')"
  wt="$(tj -r --arg id "$id" '.tasks[]|select(.id==$id)|.facets.workType // empty')"
  rows="$(blob ledgers/outcomes.jsonl | jq -s -c '.' 2>/dev/null)"
  if [ -z "$layer" ] || [ -z "$wt" ] || [ -z "$tiers" ] || [ -z "$rows" ] || [ "$rows" = "[]" ]; then printf '%s 0' "$cold"; return; fi
  local mf risk; mf="$(blob tracking/manual-fail.json)"; [ -n "$mf" ] || mf='{}'
  risk="$(tj -c --arg id "$id" '.tasks[]|select(.id==$id)|.facets.risk // []')"; [ -n "$risk" ] || risk='[]'
  local chosen pm exploreIdx _erem   # _erem = policy.jq's 4th field (dashboard cooldown state) — unused here
  read -r chosen pm exploreIdx _erem <<<"$(jq -rn --argjson rows "$rows" --argjson tiers "$tiers" --arg layer "$layer" --arg wt "$wt" \
     --argjson floor "$POLICY_FLOOR" --argjson minN "$POLICY_MINN" --argjson coldIdx "$cold" \
     --argjson manualFail "$mf" --argjson risk "$risk" --argjson explorePM "$POLICY_EXPLORE_PM" --argjson exploreCooldownN "$POLICY_EXPLORE_COOLDOWN_N" \
     --argjson auditCount -1 --argjson auditStartN "$AUDIT_START_N" --argjson auditFloorN "$AUDIT_FLOOR_N" --argjson auditFloorPM "$AUDIT_FLOOR_PM" \
     -f "$POLICY_JQ" 2>/dev/null)"
  chosen="${chosen:-$cold}"; pm="${pm:-0}"; exploreIdx="${exploreIdx:--1}"
  if [ "$exploreIdx" -ge 0 ] && [ "$(rand_pm)" -lt "$pm" ]; then
    log "explore: $id cell (${layer:-?}×${wt:-?}) probing untested tier $exploreIdx (pm=${pm}) instead of calibrated tier $chosen"
    printf '%s 1' "$exploreIdx"; return
  fi
  printf '%s 0' "$chosen"
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
     --arg verif "${cur_verification:-ci-only}" \
     -c '.tasks[]|select(.id==$id)|{
       id:$id, ts:$ts, facets:(.facets // null), scopeSize:(.scope|length),
       startModel:$sm, startEffort:(if $se=="" then null else $se end),
       finalModel:$fm, finalEffort:(if $fe=="" then null else $fe end),
       succeededRung:(if $blocked then null else $rung end), topRung:$rung,
       attemptsAtRung:$atr, totalSoftFails:$total, blocked:$blocked, reason:$reason,
       verification:$verif
     }'
}

# record_failure <id> <kind> [detail] — buffer ONE per-attempt diagnostic row locally (never
# committed directly). Diagnostics only — never read by calibration (policy.jq reads only
# ledgers/outcomes.jsonl). Flushed into ledgers/failures.jsonl by flush_failures at the task's next
# terminal outcome (done or blocked), so a task with 3 soft failures then a success gets 3 failure
# rows + 1 outcome row, all in the same terminal commit.
record_failure() {
  local id="$1" kind="$2" detail="${3:-}" ts m e facets
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  read -r m e <<<"$(rung_at "$id" "${cur_rung:-0}")"   # the ACTUAL rung this attempt ran at, not the cold-start floor
  facets="$(tj -c --arg id "$id" '.tasks[]|select(.id==$id)|.facets // null' 2>/dev/null || echo null)"; facets="${facets:-null}"
  jq -nc --arg id "$id" --arg ts "$ts" --arg kind "$kind" --argjson rung "${cur_rung:-0}" \
     --argjson attempt "${cur_attempts:-0}" --arg m "$m" --arg e "$e" --argjson facets "$facets" --arg detail "$detail" \
     '{id:$id, ts:$ts, kind:$kind, rung:$rung, attempt:$attempt, model:$m, effort:$e, facets:$facets, detail:$detail}' \
     >>"$FAILURES_BUF" 2>/dev/null || true
}

# flush_failures <id> <dest> — append the buffered rows into <dest> (a ledgers/failures.jsonl path
# inside the commit worktree; the caller stages + commits it), then clear the buffer for the next task.
flush_failures() {
  local dest="$2"
  [ -s "$FAILURES_BUF" ] || return 0
  mkdir -p "$(dirname "$dest")"
  cat "$FAILURES_BUF" >>"$dest" 2>/dev/null || true
  : >"$FAILURES_BUF"
}

# status_done_on_remote <id> — true iff origin/main's TASKS.json ALREADY records $id as done. Used to
# VERIFY a status flip actually persisted: a lost flip (a push that never landed) is silently reverted
# by the next cold rebuild off origin/main, orphaning the task on main as pending-though-done — the
# exact trigger for the idle-verdict stall. Best-effort read; any gap → false, so the caller retries.
status_done_on_remote() {
  local id="$1"
  git -C "$ROOT" fetch origin --quiet 2>/dev/null || true
  git -C "$ROOT" show "origin/main:.harness/tracking/TASKS.json" 2>/dev/null \
    | jq -e --arg id "$id" 'any(.tasks[]; .id==$id and .status=="done")' >/dev/null 2>&1
}

# record_outcome <id> <blocked> [reason] — append an outcome row to the ledger ON MAIN, committed
# via a detached worktree (mirrors block_task). Used for the SUCCESS case; block_task folds the row
# into its own commit. Forward-only + best-effort — never fails the caller.
record_outcome() {
  local id="$1" blocked="$2" line; line="$(outcome_row "$id" "$blocked" "${3:-}")"
  [ -n "$line" ] || { log "WARN: couldn't build outcome row for $id"; return 0; }
  git -C "$ROOT" fetch origin --quiet 2>/dev/null || true
  remove_wt
  if git -C "$ROOT" worktree add --quiet --force --detach "$LOOP_WT" origin/main 2>/dev/null; then
    mkdir -p "$LOOP_WT/.harness/ledgers"
    printf '%s\n' "$line" >>"$LOOP_WT/.harness/ledgers/outcomes.jsonl"
    flush_failures "$id" "$LOOP_WT/.harness/ledgers/failures.jsonl"
    # Split add: a combined add including an absent failures.jsonl aborts atomically and would drop the
    # outcome row (the sole calibration input). Stage outcomes always, failures.jsonl iff present.
    git -C "$LOOP_WT" add .harness/ledgers/outcomes.jsonl 2>/dev/null || true
    [ -f "$LOOP_WT/.harness/ledgers/failures.jsonl" ] && git -C "$LOOP_WT" add .harness/ledgers/failures.jsonl 2>/dev/null || true
    if [ "$blocked" = false ]; then
      # The LOOP — not the builder — owns .harness/tracking/TASKS.json status (§6 TODO fix): flip it
      # here, in the SAME commit as the outcome row, now that the task has cleared structural_checks
      # + the audit gate. Mirrors the in-place variant's mark_done().
      local tasks_path="$LOOP_WT/.harness/tracking/TASKS.json" tmp="$LOOP_WT/.harness/tracking/TASKS.json.tmp"
      if jq --arg id "$id" '(.tasks[]|select(.id==$id)|.status)="done"' "$tasks_path" >"$tmp" 2>/dev/null; then
        mv "$tmp" "$tasks_path"
        git -C "$LOOP_WT" add .harness/tracking/TASKS.json 2>/dev/null || true
      else
        rm -f "$tmp"; log "WARN: couldn't set status=done for $id in TASKS.json"
      fi
    fi
    git -C "$LOOP_WT" commit -q -m "$id: record outcome [skip ci]" 2>/dev/null || true
    if [ "$blocked" = false ]; then
      # Persist-or-shout: on the SUCCESS flip, VERIFY status=done actually reached origin/main; retry
      # the push once; if it STILL hasn't landed, log an ERROR so a human sees the divergence rather
      # than it silently re-appearing as pending next cold rebuild (the idle-stall precondition).
      local _persisted=0 _try
      for _try in 1 2; do
        git -C "$LOOP_WT" push --quiet origin HEAD:main 2>/dev/null || true
        if status_done_on_remote "$id"; then _persisted=1; break; fi
        sleep 1
      done
      [ "$_persisted" = 1 ] || log "ERROR: status=done for $id did NOT persist to main after 2 tries — it may re-appear as pending (idle-stall risk); mark it done by hand if so."
    else
      git -C "$LOOP_WT" push --quiet origin HEAD:main 2>/dev/null || log "WARN: couldn't push outcome for $id"
    fi
    remove_wt
  fi
}

# reconcile_overlays — promote owner-overlay verdicts (tracking/human-done.json "done",
# tracking/manual-fail.json "failed") into authoritative TASKS.json status on origin/main, via a
# detached-worktree commit (mirrors record_outcome/block_task). Read-only inputs; run once per
# iteration (after the fetch, before select_task) so an owner action taken mid-run takes effect
# promptly. Cheap no-op when nothing changed — only touches a worktree if a flip is needed.
reconcile_overlays() {
  local hd md tasks new
  hd="$(blob tracking/human-done.json)"; [ -n "$hd" ] || hd='{}'
  md="$(blob tracking/manual-fail.json)"; [ -n "$md" ] || md='{}'
  tasks="$(blob tracking/TASKS.json)"; [ -n "$tasks" ] || return 0
  # human-done promotes ONLY a needs-human task (the gate guard stops a stray entry marking an
  # ordinary task done unbuilt); manual-fail overturns ANY not-yet-failed task, kept terminal by
  # task_failed() in select_task.
  new="$(jq -c --argjson hd "$hd" --argjson md "$md" '
    .tasks |= map(
      if (.status != "failed") and ($md[.id].failed == true) then .status = "failed"
      elif (.gate == "needs-human") and (.status != "done") and ($hd[.id].done == true) then .status = "done"
      else . end
    )' <<<"$tasks" 2>/dev/null)"
  [ -n "$new" ] || return 0
  [ "$new" = "$(jq -c '.' <<<"$tasks" 2>/dev/null)" ] && return 0
  remove_wt
  if git -C "$ROOT" worktree add --quiet --force --detach "$LOOP_WT" origin/main 2>/dev/null; then
    printf '%s\n' "$new" | jq '.' >"$LOOP_WT/.harness/tracking/TASKS.json"
    git -C "$LOOP_WT" add .harness/tracking/TASKS.json 2>/dev/null || true
    git -C "$LOOP_WT" commit -q -m "reconcile: apply owner overlays [skip ci]" 2>/dev/null || true
    git -C "$LOOP_WT" push --quiet origin HEAD:main 2>/dev/null || log "WARN: couldn't push overlay reconciliation"
    remove_wt
  fi
  log "reconcile: applied owner overlays to TASKS.json"
}

# sync_primary_checkout — leave the owner's PRIMARY checkout ($ROOT) on the latest main once the loop
# has finished. The loop builds in an isolated worktree and integrates by pushing to origin/main, so the
# primary checkout stays on whatever it was — stale relative to the work that just landed. Called ONLY at
# the clean "backlog drained / idle" exits (never mid-run, never on a rate-limit pause), this fetches and
# fast-forwards the primary checkout onto main. SAFE + best-effort by design: it refuses on a dirty tree
# (never stashes or clobbers uncommitted work), fast-forwards only (never rewrites local commits), and is
# fully non-fatal (every failure just logs and returns). It only ever fast-forwards a checkout that is
# ALREADY on main — a checkout deliberately left on another branch (or detached) is never switched.
# Set SYNC_PRIMARY_ON_DONE=0 to keep the worktree variant's strict "never touch the primary checkout"
# behavior.
sync_primary_checkout() {
  [ "${SYNC_PRIMARY_ON_DONE:-1}" = 1 ] || return 0
  git -C "$ROOT" fetch origin --quiet 2>/dev/null || { log "sync: couldn't fetch origin — leaving primary checkout as-is"; return 0; }
  if [ -n "$(git -C "$ROOT" status --porcelain 2>/dev/null)" ]; then
    log "sync: primary checkout has uncommitted changes — leaving it as-is (not switching to main)"; return 0
  fi
  local cur; cur="$(git -C "$ROOT" symbolic-ref --quiet --short HEAD 2>/dev/null || echo '(detached)')"
  if [ "$cur" != main ]; then
    log "sync: primary checkout is on '$cur', not main — deliberate checkout; leaving it alone."; return 0
  fi
  if git -C "$ROOT" merge --ff-only --quiet origin/main 2>/dev/null; then
    log "sync: primary checkout is on the latest main."
  else
    log "sync: primary checkout on main but not fast-forwardable to origin/main (unpushed local commits?) — leaving as-is."
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
  local t d ok
  # Cold-only: never resume a leftover in-progress branch — every task is built FRESH (the main loop
  # tears the branch + worktree down and rebuilds off origin/main on each attempt).
  if [ -n "$FORCE_TASK" ]; then
    # SAFETY: a forced id MUST be a real task in TASKS.json — never build a bogus id (typo / stray flag).
    if ! tj -e --arg id "$FORCE_TASK" '.tasks[]|select(.id==$id)' >/dev/null 2>&1; then
      log "FORCE_TASK '$FORCE_TASK' is not a real task id in TASKS.json — refusing to build it."; return 1
    fi
    echo "$FORCE_TASK $(task_branch "$FORCE_TASK") fresh"; return 0
  fi
  for t in $(all_tasks); do
    task_done "$t" && continue
    task_failed "$t" && continue      # owner overturned a false success — terminal, never rebuild
    task_gated "$t" && continue       # 🔒 needs-human — a human must act
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
  # `gh run watch --exit-status`'s bare exit conflates a genuine CI failure with a watch hiccup and a
  # run CANCELLED by a newer push. Watch to settle, then read the run's ACTUAL conclusion and classify
  # on THAT — only a real failure is RED; cancelled/skipped/stale/neutral returns 2 (indeterminate).
  gh run watch "$runid" --exit-status >/dev/null 2>&1 || true
  local latest concl
  latest="$(gh run list --branch "$branch" --limit 20 --json databaseId,headSha,workflowName \
              --jq ".[] | select(.headSha==\"$sha\" and .workflowName==\"$CI_WORKFLOW\") | .databaseId" \
              2>/dev/null | head -1 || true)"
  [ -n "$latest" ] && runid="$latest"
  concl="$(gh run view "$runid" --json status,conclusion --jq '.status + "/" + (.conclusion // "")' 2>/dev/null || true)"
  case "$concl" in
    completed/success)
      log "CI GREEN (run $runid)"; return 0 ;;
    completed/failure|completed/timed_out|completed/startup_failure|completed/action_required)
      log "CI RED (run $runid, $concl) — gh run view $runid --log-failed"; return 1 ;;
    *)
      log "CI INDETERMINATE (run $runid, conclusion='${concl:-unknown}') — NOT treating as red (likely concurrency-cancelled/skipped)"; return 2 ;;
  esac
}

# Integrate by fast-forwarding main. Single-flight keeps it a ff; if main moved
# (another actor pushed), the ff is rejected and we soft-fail so the agent absorbs it.
# throttled_push <dir> <push-args...> — like `git -C <dir> push <push-args...>`, but enforces
# PUSH_COOLDOWN_SECONDS between successful pushes (persisted in a gitignored-equivalent file under
# .git, so it survives across loop.sh invocations). 0 (default) = no throttle, zero overhead.
PUSH_COOLDOWN_FILE="$GIT_COMMON/${NAME}-last-push"
throttled_push() {
  local dir="$1"; shift
  if [ "$PUSH_COOLDOWN_SECONDS" -gt 0 ] 2>/dev/null; then
    local last now elapsed wait
    last="$(cat "$PUSH_COOLDOWN_FILE" 2>/dev/null || echo 0)"
    now=$(date +%s); elapsed=$(( now - last ))
    if [ "$elapsed" -lt "$PUSH_COOLDOWN_SECONDS" ]; then
      wait=$(( PUSH_COOLDOWN_SECONDS - elapsed ))
      log "push cooldown: waiting ${wait}s (PUSH_COOLDOWN_SECONDS=$PUSH_COOLDOWN_SECONDS)"
      sleep "$wait"
    fi
  fi
  git -C "$dir" push "$@"; local rc=$?
  [ "$rc" = 0 ] && date +%s >"$PUSH_COOLDOWN_FILE" 2>/dev/null
  return "$rc"
}

# --- Pre-integrate secret guard (mirrors the in-place variant) --------------------
# The worktree builds off a clean origin/main, so untracked local secrets aren't present — but a
# builder can still CREATE and commit a .env / credentials.json / *.pem etc. on its branch, which
# would then fast-forward onto public main unchecked. Refuse to integrate if the branch's diff vs
# main contains a sensitive path (.env.example is explicitly allowed).
SENSITIVE_RE='(^|/)data/|(^|/)\.env($|\.)|chrome-profile|\.pem$|\.key$|\.p12$|service-account|credentials\.json'
GUARD_ALLOW_RE='(^|[/:])\.env\.example$'

# Optional project-appendable denylist: .harness/custom/sensitive-paths.txt (one ERE fragment per
# line; blank/#-comment lines ignored). APPEND-ONLY — it can only TIGHTEN the guard, never loosen it.
# A pattern that won't compile is ignored with a WARN (base guard stays fully active — never wedged).
SENSITIVE_EXTRA_FILE="$HARNESS_DIR/custom/sensitive-paths.txt"
if [ -f "$SENSITIVE_EXTRA_FILE" ]; then
  extra="$(grep -vE '^[[:space:]]*(#|$)' "$SENSITIVE_EXTRA_FILE" 2>/dev/null | paste -sd'|' - || true)"
  if [ -n "$extra" ]; then
    candidate="$SENSITIVE_RE|$extra"
    if printf '' | grep -qE "$candidate" 2>/dev/null; then
      SENSITIVE_RE="$candidate"                          # matched (n/a on empty) → valid
    else
      rc=$?                                              # exit of the if-condition (set -e exempt)
      if [ "$rc" -le 1 ]; then SENSITIVE_RE="$candidate"    # 1 = valid ERE, just no match → accept
      else log "WARN: custom/sensitive-paths.txt has an invalid regex — ignoring it; using base guard only."; fi
    fi
  fi
fi
guard_clean() {   # <branch> — 0 = clean, 1 = a sensitive path is staged for integration
  local branch="$1" bad
  bad="$(git -C "$ROOT" diff --name-only "origin/main..origin/$branch" 2>/dev/null | grep -nE "$SENSITIVE_RE" | grep -vE "$GUARD_ALLOW_RE" || true)"
  [ -z "$bad" ] && return 0
  log "PRE-INTEGRATE GUARD TRIPPED — refusing to fast-forward $branch → main. Sensitive paths:"
  printf '   %s\n' $bad >&2
  return 1
}

# --guard-selftest [path]: with no arg, assert the (effective) guard regex blocks real secrets but
# allows tracked templates. With a path arg, print BLOCK/ALLOW for that ONE path against the effective
# guard (base + any custom/sensitive-paths.txt) — a "does the guard catch this?" probe.
guard_selftest() {
  if [ -n "${1:-}" ]; then
    if printf '%s\n' "$1" | grep -nE "$SENSITIVE_RE" | grep -vE "$GUARD_ALLOW_RE" >/dev/null; then echo BLOCK; else echo ALLOW; fi
    return 0
  fi
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
[ "${1:-}" = "--guard-selftest" ] && { guard_selftest "${2:-}"; exit $?; }

integrate() {
  local branch="$1"
  guard_clean "$branch" || return 1
  throttled_push "$LOOP_WT" --quiet origin "$branch:main" 2>/dev/null && return 0
  log "ff to main rejected (main moved under us) — soft"; return 1
}

# Optional post-integration hook (deploy/restart so the running product matches main).
run_integrate_hook() {
  [ -n "$INTEGRATE_HOOK" ] || return 0
  log "integrate hook: $INTEGRATE_HOOK"
  ( cd "$ROOT" && eval "$INTEGRATE_HOOK" ) || log "WARN: integrate hook failed (non-fatal)"
}

# visual_verify_block <id> [audit] — print an instruction block telling the reader to run
# VISUAL_VERIFY_HOOK and actually LOOK at its output. Fires when the hook is set AND the task opts in:
# a task-level `visualVerify:true` fires it on ANY platform (browser, native/desktop, a mobile
# simulator, a generated image); `visualVerify:false` suppresses it; with no flag it falls back to a
# heuristic — the task's workType is in VISUAL_VERIFY_WORKTYPES (default "component"). No-op (prints
# nothing) otherwise, so non-visual tasks and projects pay zero cost. The optional second arg "audit"
# frames it for the independent auditor (a PASS/FAIL decision) instead of the builder (record + declare
# done). See docs/designs/visual-verification.md for the rationale and worked per-platform examples.
#
# A project can enrich the block (without forking the loop) by dropping custom/visual-verify-build.md
# and/or custom/visual-verify-audit.md — appended below when the block fires. See _visual_verify_custom.
_visual_verify_custom() {   # <build|audit> — append a project snippet from the custom/ overlay if present
  local mode="$1"
  local f="$HARNESS_DIR/custom/visual-verify-${mode}.md"   # separate line: ${mode} must be assigned first
  [ -f "$f" ] || return 0
  printf '\n--- PROJECT-SPECIFIC VISUAL VERIFICATION GUIDANCE ---\n'
  cat "$f"
  printf '\n'
}

# _custom_preamble <build|audit> — append a project-supplied prompt block from the custom/ overlay if
# present. Convention-located (like custom/hooks, custom/sensitive-paths.txt, custom/visual-verify-*.md);
# absent → no output → byte-identical prior prompt. UNCONDITIONAL when present (a standing project rule on
# EVERY build/audit), unlike the visual snippet which is gated on the task opting in. mode ∈ build|audit.
_custom_preamble() {
  local mode="$1" label
  local f="$HARNESS_DIR/custom/${mode}-preamble.md"   # separate line: ${mode} must be assigned first
  [ -f "$f" ] || return 0
  label="$([ "$mode" = audit ] && echo AUDIT || echo BUILD)"
  printf '\n--- PROJECT-SPECIFIC %s GUIDANCE (required — project rules on top of the generic instructions above) ---\n' "$label"
  cat "$f"
  printf '\n'
}
visual_verify_block() {
  local tid="$1" mode="${2:-build}" vv wt ly fire
  [ -n "$VISUAL_VERIFY_HOOK" ] || return 0
  # NB: read .visualVerify WITHOUT `// empty` — jq's `//` treats a literal `false` as empty too, which
  # would drop an explicit opt-OUT. Absent → "null"/"" (falls through to the facets heuristic); false → "false".
  vv="$(tj -r --arg id "$tid" '.tasks[]|select(.id==$id)|.visualVerify')"
  [ "$vv" = false ] && return 0
  if [ "$vv" != true ]; then
    # Facets heuristic (two ways to auto-fire): (a) an INHERENTLY-visual work-type (VISUAL_VERIFY_WORKTYPES,
    # default "component style") fires on any layer; (b) else a VISUAL_VERIFY_LAYERS layer (default
    # "frontend") fires UNLESS the work-type is clearly non-visual (VISUAL_VERIFY_SKIP_WORKTYPES, default
    # "docs config logging"). Maybe-visual work-types (bugfix/feature/migration on a non-frontend layer)
    # are NOT auto-fired here — the authoring skills ask/judge and set visualVerify:true when warranted.
    wt="$(tj -r --arg id "$tid" '.tasks[]|select(.id==$id)|.facets.workType // empty')"
    ly="$(tj -r --arg id "$tid" '.tasks[]|select(.id==$id)|.facets.layer // empty')"
    fire=0
    case " $VISUAL_VERIFY_WORKTYPES " in *" $wt "*) fire=1 ;; esac
    if [ "$fire" = 0 ] && [ -n "$ly" ]; then
      case " $VISUAL_VERIFY_LAYERS " in *" $ly "*)
        case " $VISUAL_VERIFY_SKIP_WORKTYPES " in *" $wt "*) ;; *) fire=1 ;; esac ;;
      esac
    fi
    [ "$fire" = 1 ] || return 0
  fi
  if [ "$mode" = audit ]; then
    printf '\n--- VISUAL EVIDENCE (this is a visual task — a text-diff review is NOT sufficient) ---\n'
    printf 'Run `%s` and LOOK at what it produces. Judge whether the rendered output actually satisfies\n' "$VISUAL_VERIFY_HOOK"
    printf 'every visual "## Done when" item — the intended element is present AND painted/visible, not merely\n'
    printf 'in the DOM/tree. FAIL if a screenshot contradicts a "## Done when" claim, if the visual check exits\n'
    printf 'non-zero, or if a visual requirement is not evidenced by what actually renders.\n'
    _visual_verify_custom audit
    return 0
  fi
  printf '\n--- VISUAL VERIFICATION (required before reporting done — see docs/designs/visual-verification.md) ---\n'
  printf 'This task produces visual output. Passing tests/build alone is NOT sufficient.\n'
  printf 'Run `%s` and actually LOOK at what it produces (screenshots / rendered output) to confirm the\n' "$VISUAL_VERIFY_HOOK"
  printf 'change renders and behaves as intended. Record what you OBSERVED (not just "ran it") in the worklog.\n'
  _visual_verify_custom build
}

# --- Per-task build prompt --------------------------------------------------
prompt() {
  local tid="$1" branch="$2"
  printf 'You are the autonomous builder for THIS repo. Build EXACTLY ONE task: %s, then stop.\n' "$tid"
  printf 'You are in a DEDICATED git worktree already checked out on branch `%s`. Work HERE only — do NOT switch branches, create branches, or touch any other checkout on this machine.\n' "$branch"
  cat <<'EOF'

Obey CLAUDE.md, .harness/tracking/TASKS.json, and .harness/docs/HARNESS.md exactly. You run
head-less and unattended. First read CLAUDE.md (conventions) and README.md (the current implemented state).

1. BUILD COLD. You are starting FRESH on a clean branch off origin/main — do NOT look for or rely on
   any prior-attempt state (worklog, partial commits); build this task from the spec alone. Read this
   task's object in .harness/tracking/TASKS.json (find it with `jq '.tasks[]|select(.id=="<TASK>")'
   .harness/tracking/TASKS.json`); if its `design` field points to a `.harness/docs/designs/…` doc,
   READ and follow it. The task's `do` + `done-when` live in the Markdown spec at the JSON `spec`
   path (.harness/tasks/<TASK>.md, sections '## Do' / '## Done when') — its FULL TEXT is appended at
   the end of this prompt. Stay within the task's `scope` — the exact allowed-files list + the
   HARD-GATE rule are shown under "SCOPE" at the end of this prompt.
2. DEFINITION OF DONE (.harness/docs/HARNESS.md §6 — all must hold before you report `done`):
   a. Run the project's full verification suite exactly as defined in CLAUDE.md /
      .harness/docs/HARNESS.md §6 (format, lint, tests, build). These MIRROR CI — if CI runs it,
      run it locally first. Every check must pass.
   b. Run the task's relevant integration / end-to-end tests when their preconditions are
      met. Tests that need credentials, funds, or external resources you don't have: leave
      them as they are and record `failed:blocked` if the task's core needs them — never
      silently skip a required check and call it "passed".
   c. If the task's `verify` field names extra EMPIRICAL checks (e.g. run the app against
      real input for a bounded window and observe it behaves), perform them and record what
      you OBSERVED in the worklog. The bar is the behaviour the task specifies.
3. DO NOT edit .harness/tracking/TASKS.json — the loop, not the builder, sets `"status"` to `"done"`
   itself once your build clears the structural checks + audit gate below, in a follow-up commit
   the loop makes on its own. If a doc (README.md, .harness/docs/LIMITATIONS.md, …) genuinely needs
   updating for THIS task, update it only if it's listed in your `scope` below — otherwise leave it.
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
  # Inject the task's `scope` as an explicit HARD boundary. structural_checks fails the build if the
  # diff touches anything outside it, so the builder must know it.
  local sc
  sc="$(tj -r --arg id "$tid" '.tasks[]|select(.id==$id)|.scope[]?' 2>/dev/null)"
  printf '\n--- SCOPE — HARD GATE (a script checks your diff against this; staying inside it is mandatory) ---\n'
  printf 'You may change ONLY these files:\n'
  if [ -n "$sc" ]; then printf '%s\n' "$sc" | sed 's/^/  - /'; else printf '  (none declared — keep the diff minimal)\n'; fi
  printf '%s\n' 'PLUS you may always add/change TEST files and your own .harness/worklog/<TASK>.md. Touching ANY OTHER file — including .harness/tracking/TASKS.json (the loop owns it) or a doc not listed above — AUTO-FAILS this task. If you genuinely need a file that is not listed, do NOT edit it: record `failed:blocked <TASK> needs <file> (out of scope)` so a human can fix the scope.'
  # If the task is marked expectsTest, make writing a test an EXPLICIT REQUIREMENT here. structural_checks
  # already AUTO-FAILS a diff that changes no test file (STRUCT_FAIL_KIND=test-missing), but nothing else
  # told the builder — so it would fail blind, and (since the SCOPE block frames tests as merely
  # "allowed") a cost-minimizing builder is if anything nudged to skip them. State it as mandatory and
  # tie it back to scope so there's no ambiguity that tests belong in this task.
  if tj -e --arg id "$tid" '.tasks[]|select(.id==$id)|.expectsTest==true' >/dev/null 2>&1; then
    printf '\n--- TESTS — REQUIRED for this task (it is marked expectsTest) ---\n'
    printf 'You MUST add or change at least one TEST file that exercises the behaviour in "## Do" and pins the\n'
    printf '"## Done when" acceptance items. Test files are ALWAYS in scope (see SCOPE above) — so this is a\n'
    printf 'REQUIREMENT of this task, not a scope exception you can skip. A diff that changes NO test file\n'
    printf 'AUTO-FAILS this task (structural gate: test-missing); a green run against the EXISTING tests only\n'
    printf 'is NOT sufficient. Write the test to what "## Done when" says it must assert, and keep it hermetic\n'
    printf '(a scratch/throwaway resource — never the real prod DB, live services, or real data).\n'
  fi
  _custom_preamble build
  visual_verify_block "$tid"
  # Append the task's Markdown spec (## Do / ## Done when) verbatim — read from the git ref. The
  # `spec` field is ALREADY a full repo-relative path (.harness/tasks/<TASK>.md), so read it directly
  # with `git show "$TASKS_REF:$rel"` — do NOT route it through blob() (which re-prefixes .harness/).
  local rel="" md
  rel="$(task_spec_rel "$tid")"
  if [ -n "$rel" ]; then
    md="$(git -C "$ROOT" show "$TASKS_REF:$rel" 2>/dev/null || true)"
    if [ -n "$md" ]; then
      printf '\n\n--- Task %s spec (%s) ---\n%s\n' "$tid" "$rel" "$md"
    else
      printf '\n\n(WARNING: spec file %s referenced by %s is missing at %s — read the task via jq.)\n' "$rel" "$tid" "$TASKS_REF"
    fi
  fi
}

# --- Claude invocation with rate-limit detection ----------------------------
RL_RE='usage limit|session limit|hit your .*limit|limit.*reset|rate.?limit|429|resets? (at|in)|try again later|overloaded|quota|insufficient.*credit|exceeded your'
# Unambiguous "you have hit a usage/session limit" wording. Kept SEPARATE from (and tighter than) the
# broad RL_RE so it can classify a limit EVEN when the CLI exits 0 — which it frequently does, because
# the limit notice is a normal assistant message, not a process error. The tightness ensures ordinary
# task output is never misread as a limit on a genuinely successful run.
RL_HARD_RE='hit your (session|usage|account|weekly|5.?hour) limit|(session|usage|weekly|account) limit reached|reached your (usage|session|weekly) limit'
RL_BUFFER="${RL_BUFFER:-300}"  # seconds of slack added on top of a parsed reset time (5-min cushion — waking a hair early re-hits the same limit)

# rl_reset_wait <output-file> — best-effort: parse a reset time out of Claude's own rate-limit
# message and echo how many seconds to sleep until then (+ RL_BUFFER slack, capped at
# RL_BACKOFF_MAX). Returns non-zero (echoes NOTHING) when no reset time is found or it fails to
# parse — callers fall back (build path: exponential backoff; audit path: RL_POLL). Call it
# `… || true` inside a command substitution: a bare failing $( ) assignment would trip set -e.
# Handles three shapes Claude's CLI has been observed to use: an absolute clock time
# ("resets at 3:45 PM"), a relative duration ("resets in 45 minutes"), and an ISO-8601 timestamp.
rl_reset_wait() {
  local out="$1" now line target iso n unit clock secs
  now=$(date +%s)
  line="$(grep -hoiE 'resets?[^.]{0,40}' "$out" "${out}.jsonl" 2>/dev/null | tail -1)"   # scan the raw sibling too (the limit notice is only in the .jsonl, not the reassembled text)
  [ -n "$line" ] || return 1

  iso="$(printf '%s' "$line" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(Z|[+-][0-9]{2}:?[0-9]{2})?' | head -1)"
  if [ -n "$iso" ]; then
    case "$iso" in
      *Z) target="$(TZ=UTC date -j -f '%Y-%m-%dT%H:%M:%S' "${iso:0:19}" +%s 2>/dev/null || TZ=UTC date -d "${iso:0:19}" +%s 2>/dev/null || true)" ;;
      *)  target="$(date -j -f '%Y-%m-%dT%H:%M:%S' "${iso:0:19}" +%s 2>/dev/null || date -d "$iso" +%s 2>/dev/null || true)" ;;
    esac
  fi

  if [ -z "${target:-}" ]; then
    read -r n unit <<<"$(printf '%s' "$line" | grep -oiE '[0-9]+ *(second|minute|hour)s?' | head -1 | sed -E 's/([0-9]+) *([a-zA-Z]+)s?/\1 \2/')"
    if [ -n "$n" ]; then
      case "$unit" in
        [Ss]econd*) target=$((now + n)) ;;
        [Mm]inute*) target=$((now + n * 60)) ;;
        [Hh]our*)   target=$((now + n * 3600)) ;;
      esac
    fi
  fi

  if [ -z "${target:-}" ]; then
    # Clock time — OPTIONAL minutes + OPTIONAL timezone: "resets 3am (Europe/London)", "resets
    # 2:30pm (Europe/London)", "resets 9:25 pm". If a (TZ) is stated, compute the next occurrence in
    # that zone; else local time. (The old regex required colon+minutes and ignored the zone.)
    if [[ "$line" =~ ([0-9]{1,2})(:([0-9]{2}))?[[:space:]]*([AaPp][Mm])([[:space:]]*\(([A-Za-z_/]+)\))? ]]; then
      local h mm ap tz hh24 today
      h="${BASH_REMATCH[1]}"; mm="${BASH_REMATCH[3]:-00}"
      ap="$(printf '%s' "${BASH_REMATCH[4]}" | tr 'APM' 'apm')"; tz="${BASH_REMATCH[6]:-}"
      hh24="$h"
      [ "$ap" = pm ] && [ "$h" -lt 12 ] && hh24=$((h + 12))
      [ "$ap" = am ] && [ "$h" -eq 12 ] && hh24=0
      if [ -n "$tz" ]; then
        today="$(TZ="$tz" date +%Y-%m-%d 2>/dev/null || true)"
        [ -n "$today" ] && target="$(TZ="$tz" date -j -f '%Y-%m-%d %H:%M' "$today $(printf '%02d' "$hh24"):$mm" +%s 2>/dev/null || TZ="$tz" date -d "$today $hh24:$mm" +%s 2>/dev/null || true)"
      else
        today="$(date +%Y-%m-%d 2>/dev/null || true)"
        [ -n "$today" ] && target="$(date -j -f '%Y-%m-%d %H:%M' "$today $(printf '%02d' "$hh24"):$mm" +%s 2>/dev/null || date -d "$today $hh24:$mm" +%s 2>/dev/null || true)"
      fi
      [ -n "${target:-}" ] && [ "$target" -le "$now" ] && target=$((target + 86400))
    fi
  fi

  if [ -n "${target:-}" ] && [ "$target" -gt "$now" ]; then
    secs=$(( target - now + RL_BUFFER ))
    [ "$secs" -gt "$RL_BACKOFF_MAX" ] && secs="$RL_BACKOFF_MAX"
    printf '%s' "$secs"
  else
    return 1
  fi
}

# rl_detect <out> <raw> <rc> — 0 iff the CLI hit a usage/session limit. Scans BOTH the reassembled text
# ($out) AND the raw stream ($raw). This matters: since the stream-json switch (1.34.0), $out is rebuilt
# from ONLY text_delta events, but a usage-limit notice ("You've hit your session limit · resets 1am
# (Europe/London)") is NOT a text_delta — the CLI prints it on stderr / as a result event — so it never
# lands in $out. Grepping $out alone silently misses the limit and the loop tight-loops on the generic
# 30s crash backoff instead of sleeping until reset. The notice IS in $raw (the .jsonl, via 2>&1|tee).
# RL_HARD_RE (the unambiguous "hit your session limit" wording) is trusted in the raw too; RL_RE (the
# broad net) stays $out-only, so limit-ish words inside tool_result file contents on a crashed build
# can't be misread as a limit.
rl_detect() {
  local out="$1" raw="$2" rc="$3"
  grep -qiE "$RL_HARD_RE" "$out" "$raw" 2>/dev/null && return 0
  [ "$rc" -ne 0 ] && grep -qiE "$RL_RE" "$out" 2>/dev/null && return 0
  return 1
}

# run_claude <model> <effort> <prompt> <phase: build|audit> → 0 ok | 10 rate/usage-limited | other = failure
#
# Invokes claude in --output-format stream-json mode (--verbose is MANDATORY for stream-json in
# --print mode — the CLI refuses to start without it) so output arrives incrementally instead of one
# buffered dump at process exit (plain -p mode never streams to a pipe — confirmed empirically: a
# 500-word response sat at a flat byte count for the entire generation, then landed in a single write
# right as the process exited). The raw event stream goes to `.claude-out.<phase>.jsonl` (what the
# dashboard tails live, per phase); `.claude-out.<phase>` itself is reconstructed via jq into PLAIN
# TEXT and keeps its role from before phase-separation — every existing consumer (RL_HARD_RE/RL_RE
# below, rl_reset_wait's reset-time parsing, the audit's PASS/FAIL grep, the worklog .audit.md copy)
# just needed its path updated to the phase-specific file, not its logic.
#
# `<phase>` is load-bearing, not cosmetic: build and audit used to share ONE fixed filename, so the
# very first byte of the audit's output truncated (via `tee`) the builder's still-fresh output before
# a human ever saw it. Per-phase files mean both stay readable independently until their own NEXT run.
#
# The jq extraction MUST be `-R … | fromjson? | …`, not the naive `select(...)` on parsed JSON input:
# `2>&1` means an occasional non-JSON stderr line can land mid-stream, and plain `jq 'select(...)'`
# treats one parse error as fatal — SILENTLY DROPPING every text_delta after that point for the rest
# of the invocation (confirmed empirically). `-R` (read each line as a raw string) + `fromjson?` (the
# `?` turns a parse failure into `empty` for just that line) skips a bad line and keeps going.
run_claude() {
  local model="$1" effort="$2" pr="$3" phase="$4"
  local raw="$LOOP_WT/.harness/worklog/.claude-out.${phase}.jsonl"   # raw stream events — dashboard's live tail
  local out="$LOOP_WT/.harness/worklog/.claude-out.${phase}"          # reassembled plain text — unchanged meaning
  local rc
  local -a eff=(); [ -n "$effort" ] && eff=(--effort "$effort")   # some models (e.g. Haiku) have no effort param — omit the flag entirely
  # Echo the EXACT prompt handed to Claude (build or audit), wrapped in a heavy banner, so a human
  # watching the console can read what the agent was actually asked. To stderr (never into claude's
  # stdin/stdout pipeline below). PRINT_PROMPT=0 in harness.env silences it.
  if [ "${PRINT_PROMPT:-1}" = 1 ]; then
    local _ph _meta _bar='================================================================================'
    _ph="$(printf '%s' "$phase" | tr '[:lower:]' '[:upper:]')"
    # Repeat the model/effort on BOTH the opening and END lines so a human scrolling the console
    # doesn't have to jump back up past the prompt to see which tier ran. Build banners also show the
    # escalation position (rung/attempt — WHY this tier); the audit runs at the fixed AUDITOR tier,
    # not a ladder rung, so rung/attempt is meaningless there and omitted.
    _meta="($model${effort:+ / $effort})"
    [ "$phase" = build ] && _meta="$_meta  ·  rung ${cur_rung:-0} · attempt $(( ${cur_attempts:-0} + 1 ))"
    { printf '\n%s\n=====  %s PROMPT  —  task %s  %s\n%s\n%s\n%s\n=====  END %s PROMPT  —  task %s  %s\n%s\n\n' \
        "$_bar" "$_ph" "${cur_task:-?}" "$_meta" "$_bar" "$pr" "$_bar" "$_ph" "${cur_task:-?}" "$_meta" "$_bar"; } >&2
  fi
  set +e
  # `${arr[@]+"${arr[@]}"}` (guard, NOT a bare "${arr[@]}") — on bash < 4.4 (macOS ships 3.2) expanding a
  # declared-but-EMPTY array under `set -u` throws `unbound variable` and crashes run_claude BEFORE claude
  # runs. That's exactly the effort-less cold-start floor (Haiku), so a fresh install crash-loops on task 1.
  ( cd "$LOOP_WT" && "$CLAUDE_BIN" -p "$pr" --model "$model" ${eff[@]+"${eff[@]}"} \
      --output-format stream-json --include-partial-messages --verbose ${FLAGS[@]+"${FLAGS[@]}"} ) 2>&1 \
    | tee "$raw" \
    | jq -Rrj 'fromjson? | select(.type=="stream_event" and .event.delta.type? == "text_delta") | .event.delta.text' \
    > "$out"
  rc=${PIPESTATUS[0]}
  set -e
  # Limit detection (see rl_detect): scans the RAW stream too — the notice isn't a text_delta, so it
  # never lands in the reassembled $out. return 10 → the caller runs the reset-aware backoff; the loop
  # never exits on a usage limit.
  if rl_detect "$out" "$raw" "$rc"; then return 10; fi
  return "$rc"
}

# --- Verification-aware Definition of Done (designs/audit-verification.md) -------------------------
# Worktree variant: the build lives in $LOOP_WT on branch tNNN; the audit runs AFTER branch CI is
# green and BEFORE the fast-forward to main, so unaudited work never reaches main. Cold-ness is
# enforced by tearing the branch/worktree down on every capability failure (see the done/fail paths).

# normalize_scope_prefix + scope_match live in the shared scope-lib.sh (sourced at the top of this
# script, next to repo-lock.sh) — the SINGLE implementation shared with loop.in-place.sh and
# check-task-scope.sh. It used to be duplicated verbatim in all three and drifted/re-broke; don't inline
# it here again (scope-match.test.sh fails if any of the three grows its own copy).

# in_scope_exempt <file> — true if <file> matches one of SCOPE_EXEMPT_GLOBS (space-separated
# repo-relative path entries, same matching rule as `scope` itself via scope_match).
# Empty SCOPE_EXEMPT_GLOBS (the default) exempts nothing.
in_scope_exempt() {
  local f="$1" g
  for g in $SCOPE_EXEMPT_GLOBS; do
    [ -z "$g" ] && continue
    scope_match "$f" "$g" && return 0
  done
  return 1
}

# --scope-exempt-selftest [globs path]: with two args, print EXEMPT/NOT-EXEMPT for that ONE
# (SCOPE_EXEMPT_GLOBS, path) pair against in_scope_exempt. With no args, run the built-in
# regression table (the trailing-slash / glob-suffix normalization cases that once silently
# exempted nothing).
scope_exempt_selftest() {
  if [ -n "${1:-}" ] && [ -n "${2:-}" ]; then
    SCOPE_EXEMPT_GLOBS="$1"
    if in_scope_exempt "$2"; then echo EXEMPT; else echo NOT-EXEMPT; fi
    return 0
  fi
  local fail=0 globs file exp got
  while read -r globs file exp; do
    [ -z "$globs" ] && continue
    SCOPE_EXEMPT_GLOBS="$globs"
    if in_scope_exempt "$file"; then got=EXEMPT; else got=NOT-EXEMPT; fi
    [ "$got" = "$exp" ] || { echo "scope-exempt FAIL: globs='$globs' file='$file' expected $exp got $got"; fail=1; }
  done <<'CASES'
scripts/ scripts/_visual-harness.mjs EXEMPT
scripts/** scripts/_visual-harness.mjs EXEMPT
scripts/* scripts/_visual-harness.mjs EXEMPT
scripts scripts/_visual-harness.mjs EXEMPT
scripts/visual-check.mjs scripts/visual-check.mjs EXEMPT
scripts/visual-check.mjs scripts/other.mjs NOT-EXEMPT
CASES
  [ "$fail" = 0 ] && { echo "scope-exempt self-test OK (6 cases)"; return 0; } || return 1
}
[ "${1:-}" = "--scope-exempt-selftest" ] && { scope_exempt_selftest "${2:-}" "${3:-}"; exit $?; }

# --scope-selftest [entry file]: with two args, print IN/OUT for that ONE (scope-entry, path) pair
# against scope_match. With no args, run the built-in regression table — the extension-glob cases the
# old trailing-slash-only normalization could never match, plus the exact/prefix cases that must not
# regress. Mirrors --scope-exempt-selftest; covered across BOTH loop variants by scope-match.test.sh.
scope_selftest() {
  if [ -n "${1:-}" ] && [ -n "${2:-}" ]; then
    if scope_match "$2" "$1"; then echo IN; else echo OUT; fi
    return 0
  fi
  local fail=0 entry file exp got
  while read -r entry file exp; do
    [ -z "$entry" ] && continue
    if scope_match "$file" "$entry"; then got=IN; else got=OUT; fi
    [ "$got" = "$exp" ] || { echo "scope-match FAIL: entry='$entry' file='$file' expected $exp got $got"; fail=1; }
  done <<'CASES'
components/*.tsx components/CategoryTable.tsx IN
components/*.tsx components/sub/Foo.tsx OUT
components/*.tsx components/CategoryTable.ts OUT
dashboard/app/components/*.tsx dashboard/app/components/CategoryTable.tsx IN
src/feature/** src/feature/x/y.ts IN
src/foo/* src/foo/bar/a.ts IN
src/auth/session.ts src/auth/session.ts IN
src/auth/session.ts src/auth/other.ts OUT
CASES
  [ "$fail" = 0 ] && { echo "scope-match self-test OK (8 cases)"; return 0; } || return 1
}
[ "${1:-}" = "--scope-selftest" ] && { scope_selftest "${2:-}" "${3:-}"; exit $?; }

# --rl-selftest detect <out> <raw> <rc> → LIMIT|NOLIMIT ; --rl-selftest wait <out> → <seconds>|none.
# Exercises usage/session-limit detection (that it scans the RAW stream, not just the reassembled text)
# and reset-time parsing off-line. Covered by loop-ratelimit.test.sh across BOTH loop variants.
rl_selftest() {
  case "${1:-}" in
    detect) if rl_detect "${2:-/dev/null}" "${3:-/dev/null}" "${4:-0}"; then echo LIMIT; else echo NOLIMIT; fi ;;
    wait)   local s; s="$(rl_reset_wait "${2:-/dev/null}" || true)"; [ -n "$s" ] && echo "$s" || echo none ;;
    *) echo "usage: loop.sh --rl-selftest detect <out> <raw> <rc> | wait <out>" >&2; return 2 ;;
  esac
}
[ "${1:-}" = "--rl-selftest" ] && { rl_selftest "${2:-}" "${3:-}" "${4:-}" "${5:-}"; exit $?; }

# structural_checks <id> — cheap, model-agnostic gate on the branch diff, BEFORE the audit. 0=pass 1=fail.
structural_checks() {
  local id="$1" changed want_test scope creep f s inscope
  STRUCT_FAIL_KIND=""; STRUCT_FAIL_DETAIL=""   # set on each fail path so the ledger records WHICH check failed
  changed="$(git -C "$LOOP_WT" diff --name-only origin/main..HEAD 2>/dev/null)"
  if [ -z "$changed" ]; then STRUCT_FAIL_KIND="empty-diff"; log "structural: $id produced an EMPTY diff — fail"; return 1; fi
  # Scope-creep gate: every changed file must be WITHIN the task's declared `scope` (exact path or
  # under a scope directory) — except the always-allowed worklog + test files. The strong planner's
  # `scope` is a binding contract; any other file the cheap builder touched is a failed attempt.
  scope="$(tj -r --arg id "$id" '.tasks[]|select(.id==$id)|.scope[]?' 2>/dev/null)"
  creep=""
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    # STRICT — same allowlist as the in-place variant: only the task's own worklog + test files,
    # plus any project-declared SCOPE_EXEMPT_GLOBS (e.g. a shared UI-verification harness script).
    # The loop (not the builder) owns .harness/tracking/TASKS.json status (record_outcome, after
    # this gate + the audit pass), so it is never exempted here; a task needing README/LIMITATIONS
    # updated declares that file in its own `scope` like any other file.
    case "$f" in .harness/worklog/*) continue ;; esac
    # Lockfiles are always allowed regardless of scope: a task scoped to package.json (etc.) but not
    # its lockfile would otherwise trip scope-creep the moment `npm install` (etc.) rewrites it as a
    # side effect of the manifest change — a real incident this exemption exists to prevent.
    case "$f" in */package-lock.json|package-lock.json|*/yarn.lock|yarn.lock|*/pnpm-lock.yaml|pnpm-lock.yaml) continue ;; esac
    if printf '%s\n' "$f" | grep -qiE '(\.test\.|\.spec\.|_test\.|(^|/)test_|(^|/)tests?/)'; then continue; fi
    if in_scope_exempt "$f"; then continue; fi
    inscope=0
    while IFS= read -r s; do
      [ -z "$s" ] && continue
      # Exact path, directory prefix (trailing /, /**, /*), or single-level extension glob (`dir/*.ext`)
      # — via the shared scope_match (same rule as in_scope_exempt + check-task-scope.sh).
      if scope_match "$f" "$s"; then inscope=1; break; fi
    done <<SCOPE
$scope
SCOPE
    [ "$inscope" = 1 ] || creep="$creep $f"
  done <<CHANGED
$changed
CHANGED
  if [ -n "$creep" ]; then STRUCT_FAIL_KIND="scope-creep"; STRUCT_FAIL_DETAIL="${creep# }"; log "structural: $id changed files OUTSIDE scope (scope creep):$creep — fail"; return 1; fi
  want_test="$(tj -r --arg id "$id" '.tasks[]|select(.id==$id)|.expectsTest // false')"
  if [ "$want_test" = "true" ] && ! printf '%s\n' "$changed" | grep -qiE '(\.test\.|\.spec\.|_test\.|(^|/)test_|(^|/)tests?/)'; then
    STRUCT_FAIL_KIND="test-missing"; log "structural: $id has expectsTest=true but no test file changed — fail"; return 1
  fi
  if [ -n "$LOCAL_DOD" ]; then
    log "structural: running LOCAL_DOD → $LOCAL_DOD"
    # Capture output so a LOCAL_DOD failure records a "why" instead of a silent >/dev/null.
    local dodlog="$LOOP_WT/.harness/worklog/.local-dod.log"
    if ! ( cd "$LOOP_WT" && eval "$LOCAL_DOD" ) >"$dodlog" 2>&1; then
      STRUCT_FAIL_KIND="local-dod"; STRUCT_FAIL_DETAIL="$(tail -n 20 "$dodlog" 2>/dev/null | tr '\n' '⏎')"
      log "structural: LOCAL_DOD failed for $id — fail (last lines:)"; tail -n 20 "$dodlog" 2>/dev/null | sed 's/^/    /' >&2
      return 1
    fi
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

--- IMPLEMENTATION DIFF (origin/main..HEAD) ---
$diff
EOF
  visual_verify_block "$id" audit
  _custom_preamble audit
}

# audit_gate <id> — per-cell SAMPLED blocking audit (§4.3/4.6) on the CI-green branch. Sets
# cur_verification. Spawns a fresh, independent auditor at max(opus-medium, builder tier) ONLY if
# sampled. 0 = pass (or not sampled), 1 = audit FAIL (a failed attempt).
audit_gate() {
  local id="$1" layer wt count pm bi ai am ae rel spec="" diff out verdict arc rlpoll
  cur_verification="ci-only"
  layer="$(tj -r --arg id "$id" '.tasks[]|select(.id==$id)|.facets.layer // empty')"
  wt="$(tj -r --arg id "$id" '.tasks[]|select(.id==$id)|.facets.workType // empty')"
  local mf risk; mf="$(blob tracking/manual-fail.json)"; [ -n "$mf" ] || mf='{}'
  risk="$(tj -c --arg id "$id" '.tasks[]|select(.id==$id)|.facets.risk // []')"; [ -n "$risk" ] || risk='[]'
  count="$(blob ledgers/outcomes.jsonl | jq -s --arg l "$layer" --arg w "$wt" --argjson mf "$mf" '[.[]|select(.facets!=null and .facets.layer==$l and .facets.workType==$w and .blocked==false and .verification=="audited" and ($mf[.id].failed!=true))]|length' 2>/dev/null || echo 0)"
  count="${count:-0}"
  # A task started via downward exploration (cur_explored=1) is, by definition, untested ground —
  # it always gets a mandatory audit, bypassing the cell's normal confirmed-success decay entirely,
  # exactly like a risk-flagged task's mandatory audit above (designs/difficulty-autotune.md).
  if [ "${cur_explored:-0}" = "1" ]; then
    pm=1000
    log "audit: $id cell (${layer:-?}×${wt:-?}) EXPLORE-forced mandatory audit (untested tier probed)"
  else
    pm="$(jq -n -f "$POLICY_JQ" --argjson auditCount "$count" --argjson risk "$risk" \
          --argjson auditStartN "$AUDIT_START_N" --argjson auditFloorN "$AUDIT_FLOOR_N" --argjson auditFloorPM "$AUDIT_FLOOR_PM" \
          --argjson rows '[]' --argjson tiers '[]' --arg layer '' --arg wt '' --argjson floor 0 --argjson minN 0 --argjson coldIdx 0 --argjson manualFail '{}' \
          --argjson explorePM 0 --argjson exploreCooldownN 0 2>/dev/null || echo 1000)"
  fi
  pm="${pm:-1000}"
  if [ "$(rand_pm)" -ge "$pm" ]; then
    log "audit: $id cell (${layer:-?}×${wt:-?}) $count confirmed, p=${pm}per-mille → NOT sampled (ci-only)"; return 0
  fi
  # The auditor runs at its CONFIGURED tier (AUDITOR_MODEL/EFFORT, which need NOT be a ladder rung),
  # bumped up to the builder's tier only when the builder was stronger — compared via tier_strength so
  # an off-ladder auditor tier is honoured exactly rather than snapped to an arbitrary ladder index.
  read -r bm be <<<"$(gtier $(( cur_base + cur_rung )))"   # the builder's tier
  if [ "$(tier_strength "$bm" "$be")" -gt "$(tier_strength "$AUDITOR_MODEL" "$AUDITOR_EFFORT")" ]; then
    am="$bm"; ae="$be"
  else
    am="$AUDITOR_MODEL"; ae="$AUDITOR_EFFORT"
  fi
  log "audit: $id cell (${layer:-?}×${wt:-?}) $count confirmed, p=${pm}per-mille → AUDITING at $am/$ae (auditor $AUDITOR_MODEL/$AUDITOR_EFFORT, bumped to builder tier if stronger)"
  diff="$(git -C "$LOOP_WT" diff origin/main..HEAD 2>/dev/null)"
  rel="$(task_spec_rel "$id")"; [ -n "$rel" ] && [ -f "$LOOP_WT/$rel" ] && spec="$(cat "$LOOP_WT/$rel")"
  out="$LOOP_WT/.harness/worklog/$id.audit.md"
  while :; do
    # `… || arc=$?` (NOT `; arc=$?`) — run_claude flips `set -e` back ON internally before it
    # `return`s, so a bare `; arc=$?` would let a nonzero return KILL loop.sh right here (before arc
    # is ever captured) instead of triggering the auditor rate-limit backoff below. The `||` keeps
    # the call in an AND-OR list, which `set -e` never aborts on.
    arc=0; set +e; run_claude "$am" "$ae" "$(audit_prompt "$id" "$spec" "$diff")" audit || arc=$?; set -e
    if [ "$arc" = 10 ]; then
      rlpoll="$(rl_reset_wait "$LOOP_WT/.harness/worklog/.claude-out.audit" || true)"; rlpoll="${rlpoll:-$RL_POLL}"
      rl_banner "$rlpoll" "$LOOP_WT/.harness/worklog/.claude-out.audit" "(this is the AUDIT step, not the build — NOT an audit fail)"
      sleep "$rlpoll"; continue
    fi
    break
  done
  cp "$LOOP_WT/.harness/worklog/.claude-out.audit" "$out" 2>/dev/null || true
  verdict="$(grep -oiE '\b(PASS|FAIL)\b' "$out" 2>/dev/null | head -1 | tr '[:lower:]' '[:upper:]')"
  if [ "$verdict" = "PASS" ]; then cur_verification="audited"; log "audit: PASS for $id (reasons → $out)"; return 0; fi
  log "audit: FAIL for $id (verdict='${verdict:-none}', reasons → $out)"; return 1
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

cur_task=""; cur_attempts=0; cur_rung=0; cur_base=0; cur_explored=0; cur_verification="ci-only"; hb_started=""
idle_task=""; idle_count=0   # consecutive-idle guard: a task reporting idle repeatedly (its status won't persist) is BLOCKED, never spun on

# ─── Resume an interrupted mid-climb from a leftover heartbeat ──────────────────────────────────
# See the heartbeat block above for why a leftover file here means a genuine interruption. Bounded
# by age (a heartbeat from long enough ago is probably an unrelated, stale session) and gated on the
# task still being pending. LOOP_IGNORE_HEARTBEAT=1 forces a clean cold restart for one run.
resume_task=""; resume_rung=0; resume_attempts=0; resume_base=0; resume_started=""
if [ -z "${LOOP_IGNORE_HEARTBEAT:-}" ] && [ -f "$HEARTBEAT" ]; then
  hb_json="$(cat "$HEARTBEAT" 2>/dev/null || true)"
  hb_task="$(jq -r '.task // empty' <<<"$hb_json" 2>/dev/null || true)"
  hb_updated="$(jq -r '.updatedAt // empty' <<<"$hb_json" 2>/dev/null || true)"
  if [ -n "$hb_task" ] && [ -n "$hb_updated" ]; then
    hb_epoch="$(date -j -f '%Y-%m-%dT%H:%M:%SZ' "$hb_updated" +%s 2>/dev/null || date -d "$hb_updated" +%s 2>/dev/null || echo 0)"
    hb_age=$(( $(date -u +%s) - hb_epoch ))
    hb_status="$(tj -r --arg id "$hb_task" '.tasks[]|select(.id==$id)|.status' 2>/dev/null || true)"
    if [ "$hb_age" -le "${LOOP_HEARTBEAT_RESUME_MAX_AGE:-21600}" ] && { [ "$hb_status" = "pending" ] || [ -z "$hb_status" ]; }; then
      resume_task="$hb_task"
      resume_rung="$(jq -r '.rung // 0' <<<"$hb_json" 2>/dev/null || echo 0)"
      resume_attempts="$(jq -r '.attempt // 0' <<<"$hb_json" 2>/dev/null || echo 0)"
      resume_base="$(jq -r '.base // 0' <<<"$hb_json" 2>/dev/null || echo 0)"
      resume_started="$(jq -r '.startedAt // empty' <<<"$hb_json" 2>/dev/null || true)"
      log "found a leftover heartbeat for $resume_task (rung $resume_rung, attempt $resume_attempts, ${hb_age}s old) — will resume its climb if it's selected next, instead of cold-starting the ladder."
    else
      log "found a leftover heartbeat for ${hb_task:-?} but ignoring it (age ${hb_age}s, cap ${LOOP_HEARTBEAT_RESUME_MAX_AGE:-21600}s, or task no longer pending) — starting cold."
    fi
  fi
fi

# Give up on ONE task WITHOUT halting the loop: tear down its branch/worktree, record a
# failed:blocked marker on main (select_task reads worklog from origin/main, so it then skips the
# task), and move on. A human reviews blocked tasks later; the loop keeps progressing on the rest.
block_task() {
  local id="$1" reason="$2" br; br="$(task_branch "$id")"
  cleanup_task "$br"                                   # remove the loop worktree + delete tNNN (local+remote)
  git -C "$ROOT" fetch origin --quiet 2>/dev/null || true
  remove_wt
  if git -C "$ROOT" worktree add --quiet --force --detach "$LOOP_WT" origin/main 2>/dev/null; then
    mkdir -p "$LOOP_WT/.harness/worklog" "$LOOP_WT/.harness/ledgers"
    printf '\n---\nfailed:blocked %s — %s\n' "$id" "$reason" >>"$LOOP_WT/.harness/worklog/$id.md"
    # status="blocked" is a first-class TASKS.json value (mirrors the in-place variant), so the
    # dashboard sees a blocked task the same way it sees a manual-fail.
    local tasks_path="$LOOP_WT/.harness/tracking/TASKS.json" tmp="$LOOP_WT/.harness/tracking/TASKS.json.tmp"
    if jq --arg id "$id" '(.tasks[]|select(.id==$id)|.status)="blocked"' "$tasks_path" >"$tmp" 2>/dev/null; then
      mv "$tmp" "$tasks_path"
    else
      rm -f "$tmp"; log "WARN: couldn't set status=blocked for $id in TASKS.json"
    fi
    outcome_row "$id" true "$reason" >>"$LOOP_WT/.harness/ledgers/outcomes.jsonl"   # fold the blocked outcome into THIS commit
    flush_failures "$id" "$LOOP_WT/.harness/ledgers/failures.jsonl"
    # Split add: a combined add including an absent failures.jsonl aborts atomically → the status=blocked
    # flip + worklog marker + outcome row would ALL silently fail to stage. Stage present files, then FAILURES iff present.
    git -C "$LOOP_WT" add ".harness/worklog/$id.md" .harness/tracking/TASKS.json .harness/ledgers/outcomes.jsonl 2>/dev/null || true
    [ -f "$LOOP_WT/.harness/ledgers/failures.jsonl" ] && git -C "$LOOP_WT" add .harness/ledgers/failures.jsonl 2>/dev/null || true
    git -C "$LOOP_WT" commit -q -m "$id: blocked, needs human — skipping [skip ci]" 2>/dev/null || true
    git -C "$LOOP_WT" push --quiet origin HEAD:main 2>/dev/null || log "WARN: couldn't push block marker for $id"
    remove_wt
  fi
  log "BLOCKED $id ($reason) — recorded on main; moving on to the next task."
  run_hook blocked "$id" "$reason"
  heartbeat_clear; cur_task=""; cur_attempts=0; cur_rung=0; cur_base=0; cur_explored=0
}

bump() {   # count a soft failure for $1; escalate at the cap; BLOCK + move on past the top rung (never halt)
  local t="$1" last
  [ "$t" = "$cur_task" ] || { cur_task="$t"; cur_attempts=0; cur_rung=0; read -r cur_base cur_explored <<<"$(pick_base "$t")"; }
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
# Pre-flight: warn about BUILDABLE tasks that touch .harness/** — self-modifying edits to the
# harness's own machinery are uniquely dangerous unsupervised (can corrupt TASKS.json or defeat the
# loop's own safety rails) and MUST be authored gate:"needs-human", never buildable. Non-fatal —
# matches this loop's established idiom for backlog-hygiene issues (see the missing-facets WARN).
_harness_scope_tasks="$(tj -r '[.tasks[]|select(.status!="done" and (.gate==null) and (((.scope // [])|any(startswith(".harness/"))) or (.facets.layer=="harness")))|.id]|join(", ")' 2>/dev/null || true)"
if [ -n "$_harness_scope_tasks" ]; then log "WARN: buildable tasks touch .harness/ (scope or facets.layer==harness) — these MUST be gate:needs-human, never buildable: $_harness_scope_tasks"; fi
for ((i = 1; i <= MAX_ITERS; i++)); do
  git -C "$ROOT" fetch origin --quiet 2>/dev/null || true
  reconcile_overlays
  sel="$(select_task || true)"
  if [ -z "$sel" ]; then
    log "no eligible task — backlog complete or everything left is gate/human-blocked."
    heartbeat_clear; run_hook drained drained; board; sync_primary_checkout; exit 0
  fi
  read -r task branch mode <<<"$sel"
  if [ "$task" != "$cur_task" ]; then
    if [ -n "$resume_task" ] && [ "$task" = "$resume_task" ]; then
      # Resuming an interrupted mid-climb — restore scheduling metadata only (which tier to
      # cold-start the next attempt at). This does NOT resume a partial build diff: every attempt
      # still tears down and rebuilds a fresh worktree off origin/main below, same as always.
      cur_task="$task"; cur_attempts="$resume_attempts"; cur_rung="$resume_rung"; cur_base="$resume_base"
      cur_verification="ci-only"; hb_started="${resume_started:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
      log "resuming $task at rung $cur_rung (attempt $cur_attempts/$MAX_ATTEMPTS) — restored from the interrupted run's heartbeat."
      resume_task=""   # one-shot: never re-applies once consumed
    else
      # cur_verification resets here too: a task that terminates BEFORE its audit_gate runs
      # (structural fail / CI red / blocked) must not inherit the previous task's "audited" into
      # its ledger row.
      cur_task="$task"; cur_attempts=0; cur_rung=0; cur_verification="ci-only"; hb_started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      read -r cur_base cur_explored <<<"$(pick_base "$task")"          # difficulty auto-tuning: policy picks the start tier
    fi
    log "policy: $task → start tier $cur_base ($(gtier "$cur_base")), ladder rungs $(ladder_len "$task")"
  fi
  read -r tmodel teffort <<<"$(rung_at "$task" "$cur_rung")"   # global-ladder tier at cur_base+cur_rung
  log "iteration $i/$MAX_ITERS → $task (branch $branch, cold) on $tmodel/$teffort (rung $cur_rung)"

  RESULT="$LOOP_WT/.harness/worklog/.result"
  # Run Claude COLD — every (re)attempt tears down + rebuilds a FRESH worktree off origin/main, so it
  # measures one cold pass of this tier (designs/audit-verification.md §4.1). On a usage/rate limit we
  # pause and RE-ATTEMPT COLD (not a failure); we accept the re-work to keep each measured pass clean.
  rl_waited=0; rl_sleep="$RL_BACKOFF_MIN"
  while :; do
    cleanup_task "$branch"        # discard any prior state (leftover crash branch OR a previous attempt)
    prepare_wt "$branch" 1        # FRESH worktree off origin/main — cold
    rm -f "$RESULT"
    heartbeat building
    # `… || rc=$?` (NOT `; rc=$?`) — run_claude flips `set -e` back ON internally before it
    # `return`s, so a bare `; rc=$?` would let a nonzero return KILL loop.sh right here (before rc is
    # ever captured) instead of triggering the reset-aware backoff below. The `||` keeps the call in
    # an AND-OR list, which `set -e` never aborts on.
    rc=0; set +e; run_claude "$tmodel" "$teffort" "$(prompt "$task" "$branch")" build || rc=$?; set -e
    if [ "$rc" = 10 ]; then
      if [ "$rl_waited" -ge "$RL_MAX_WAIT" ]; then
        log "still usage/session-limited after ${rl_waited}s (cap ${RL_MAX_WAIT}s) — exiting for supervise to relaunch later."
        run_hook exhausted rate-limit; board; exit 5
      fi
      rlwait="$(rl_reset_wait "$LOOP_WT/.harness/worklog/.claude-out.build" || true)"
      if [ -n "$rlwait" ]; then
        rl_banner "$rlwait" "$LOOP_WT/.harness/worklog/.claude-out.build" "(that's the reported reset + a $(_hms "$RL_BUFFER") cushion; waited $(_hms "$rl_waited") so far)"
      else
        rlwait="$rl_sleep"
        rl_banner "$rlwait" "$LOOP_WT/.harness/worklog/.claude-out.build" "No reset time in the notice — exponential backoff (cap $(_hms "$RL_EXP_MAX"); waited $(_hms "$rl_waited") so far)."
        rl_sleep=$(( rl_sleep * 2 )); [ "$rl_sleep" -gt "$RL_EXP_MAX" ] && rl_sleep="$RL_EXP_MAX"
      fi
      heartbeat rate-limited
      sleep "$rlwait"; rl_waited=$(( rl_waited + rlwait )); continue
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
      # A [skip ci]-tagged build commit never creates a workflow run, so wait_ci_green would sit out
      # the full CI_TIMEOUT and then loop on indeterminate. Skip the CI wait for such commits (an
      # operational / scope:[] task) and go straight to the structural + audit gates.
      if [ "$REQUIRE_CI" = "1" ] && git -C "$ROOT" log -1 --format=%s "origin/$branch" 2>/dev/null | grep -qF '[skip ci]'; then
        log "[skip ci] build on $branch — no CI run expected; proceeding to structural + audit gates."
      elif [ "$REQUIRE_CI" = "1" ]; then
        heartbeat awaiting-ci
        ci_rc=0; wait_ci_green "$branch" || ci_rc=$?
        if [ "$ci_rc" = 2 ]; then
          # INDETERMINATE (no run appeared / cancelled / skipped / stale / neutral) isn't the same as
          # red — give it one re-check before counting it as a failed attempt against this task's
          # difficulty calibration, so a merely-slow/superseded CI run doesn't cost a soft failure.
          log "CI INDETERMINATE for $task — re-checking once after ${WAIT_SECONDS}s before deciding."
          sleep "$WAIT_SECONDS"
          ci_rc=0; wait_ci_green "$branch" || ci_rc=$?
        fi
        if [ "$ci_rc" != 0 ]; then
          # WT integrates only AFTER green, so nothing is on main to revert either way. RED = a real
          # failed attempt; still-INDETERMINATE = inconclusive (cancelled/skipped/no-run) — both tear
          # down for a COLD retry and bump (so a permanently-broken CI still eventually BLOCKS rather
          # than looping forever), but the ledger records which it was.
          if [ "$ci_rc" = 2 ]; then
            log "CI still INDETERMINATE for $task — inconclusive; tearing down for a COLD retry."; cleanup_task "$branch"; record_failure "$task" "ci-indeterminate" "CI produced no definitive result (cancelled/skipped/no-run)"; bump "$task"; board; continue
          fi
          log "CI RED for $task — failed attempt; tearing down for a COLD retry."; cleanup_task "$branch"; record_failure "$task" "ci-red" "CI checks failed on the branch"; bump "$task"; board; continue
        fi
      fi
      # Structural gate THEN the blocking audit, on the CI-green branch, BEFORE integrating — so
      # nothing unaudited reaches main. Either fail = a failed attempt (tear down → cold retry).
      if ! structural_checks "$task"; then
        log "structural checks failed for $task — tearing down branch + cold retry."; cleanup_task "$branch"; record_failure "$task" "${STRUCT_FAIL_KIND:-structural}" "${STRUCT_FAIL_DETAIL:-}"; bump "$task"; board; continue
      fi
      heartbeat auditing
      if ! audit_gate "$task"; then
        log "AUDIT FAILED for $task — tearing down branch (never integrated) + cold retry."; cleanup_task "$branch"; record_failure "$task" "audit-fail"; bump "$task"; board; continue
      fi
      heartbeat integrating
      if integrate "$branch"; then
        record_outcome "$task" false                # difficulty auto-tuning: record the success on main (verification in the row)
        log "integrated $task → main (${cur_verification})"; cleanup_task "$branch"; run_integrate_hook; run_hook integrated "$task" "${cur_verification:-}"; heartbeat_clear; cur_task=""; cur_attempts=0; cur_rung=0; cur_base=0; cur_explored=0
      else
        record_failure "$task" "integrate-race" "ff to main rejected"; bump "$task"
      fi
      ;;
    failed:soft)    log "agent soft-failed $rtask: ${extra:-} — tearing down for a COLD retry."; cleanup_task "$branch"; record_failure "$task" "agent-soft-fail" "${extra:-}"; bump "$task" ;;
    failed:blocked) log "agent reports blocker on $rtask: ${extra:-}"; record_failure "$task" "agent-blocked" "${extra:-}"; block_task "$task" "agent reported failed:blocked — ${extra:-}" ;;
    waiting)        log "waiting on deps for $rtask: ${extra:-}"; sleep "$WAIT_SECONDS" ;;
    idle)
      # A per-task "nothing to do" — NOT a drained backlog. The agent cold-read origin/main and found
      # THIS task's Done-when already met: its work reached main in a prior attempt, but the status flip
      # was lost (pending-though-done divergence). Reconcile the ONE task (re-do the lost status=done
      # flip) and CONTINUE — the genuine "backlog drained" exit is the select_task-empty path at the top
      # of the loop, never here. GUARD: if the same task reports idle repeatedly the reconcile itself
      # isn't persisting, so BLOCK after 2 to surface it to a human instead of spinning forever (and
      # starving every other ready task, which is exactly the bug this handler replaces).
      if [ "$task" = "$idle_task" ]; then idle_count=$((idle_count + 1)); else idle_task="$task"; idle_count=1; fi
      if [ "$idle_count" -ge 2 ]; then
        log "agent reported idle on $task ${idle_count}× — its done status isn't persisting; BLOCKING for a human."
        block_task "$task" "repeated idle: work appears on main but status never persisted to done — needs a human to mark it done or fix the divergence"
        idle_task=""; idle_count=0
      else
        log "agent reports idle on $task — Done-when already met on main; reconciling status=done and continuing."
        record_outcome "$task" false
        heartbeat_clear; cur_task=""; cur_attempts=0; cur_rung=0; cur_base=0; cur_explored=0
      fi
      ;;
    *)              log "unrecognized result '$status' — backing off"; sleep "$WAIT_SECONDS" ;;
  esac
  board
done

log "reached MAX_ITERS=$MAX_ITERS — stopping"; run_hook exhausted max-iters; board; exit 4
