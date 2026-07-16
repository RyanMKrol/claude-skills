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
#         .harness/scripts/loop.sh --test-selftest <path>   # print TEST/NOT-TEST — is <path> seen as a test file? then exit
#         .harness/scripts/loop.sh --scope-exempt-selftest [globs path]  # verify SCOPE_EXEMPT_GLOBS matching, then exit
#         .harness/scripts/loop.sh --scope-selftest [entry file]  # verify scope-entry matching (extension globs), then exit
#         .harness/scripts/loop.sh --rl-selftest detect|wait …    # verify usage-limit detection + reset parsing, then exit
#         .harness/scripts/loop.sh --audit-parse-selftest <file>  # verify audit VERDICT sentinel extraction, then exit
#         .harness/scripts/loop.sh --audit-rl-cap-selftest <id>   # verify the audit-path RL_MAX_WAIT cap, then exit
#         .harness/scripts/loop.sh --audit-trail-selftest <id> <PASS|FAIL>  # verify audit output survives worktree teardown, then exit
#         .harness/scripts/loop.sh --struct-selftest <id>         # run structural_checks on the current worktree commit, then exit
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
# Shared loop logic (C01) — the RL_* rate-limit family so far (more moves in later stages). Sourced
# AFTER harness.env above so an env override of an RL_* knob still wins.
. "$SCRIPT_DIR/loop-lib.sh"

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
# C01 seam for loop-lib.sh's run_claude/structural_checks: WORK_DIR is where the claude subprocess
# cd's to and where structural_checks' git-diff/actionlint/LOCAL_DOD run (the isolated worktree
# here); PROMPT_DIR is where the full per-phase prompt file AND the actionlint/local-dod logs are
# written (stays IN the worktree — lost on teardown, deliberately, per B04's scope note). MAIN_BRANCH
# is FIXED at "main" here (NOT user-configurable, unlike the in-place variant's own MAIN_BRANCH knob)
# — this variant hardcodes "main" throughout (TASKS_REF, worktree adds, etc.); naming it here only
# lets structural_checks share code with the in-place variant, it does not add new configurability.
WORK_DIR="$LOOP_WT"
PROMPT_DIR="$LOOP_WT/.harness/worklog"
MAIN_BRANCH="main"
SYNC_PRIMARY_ON_DONE="${SYNC_PRIMARY_ON_DONE:-1}"   # when the loop finishes (backlog drained), leave the PRIMARY checkout on the latest main (safe/ff-only, skips a dirty tree); 0=never touch the primary checkout
CLAUDE_BIN="${CLAUDE_BIN:-claude}"
CLAUDE_FLAGS="${CLAUDE_FLAGS:---dangerously-skip-permissions}"
PRINT_PROMPT="${PRINT_PROMPT:-1}"                # 1 = echo each prompt (the running phase only: build OR audit) to the console before invoking Claude; 0 = silence
# RL_* rate-limit knobs (poll/backoff/buffer defaults) live in loop-lib.sh, sourced above.
FORCE_TASK=""; [ "${1:-}" != "--guard-selftest" ] && [ "${1:-}" != "--scope-exempt-selftest" ] && [ "${1:-}" != "--scope-selftest" ] && [ "${1:-}" != "--rl-selftest" ] && [ "${1:-}" != "--test-selftest" ] && [ "${1:-}" != "--audit-parse-selftest" ] && [ "${1:-}" != "--audit-rl-cap-selftest" ] && [ "${1:-}" != "--audit-trail-selftest" ] && [ "${1:-}" != "--struct-selftest" ] && FORCE_TASK="${1:-}"
POSTFLIGHT="$SCRIPT_DIR/postflight.sh"

read -r -a FLAGS <<<"$CLAUDE_FLAGS"


# _hms + rl_banner live in loop-lib.sh, sourced above.

# TASKS.json is parsed with jq throughout — fail fast if it's missing.
command -v jq >/dev/null 2>&1 || { log "jq is required to parse TASKS.json — install it (e.g. brew install jq)"; exit 3; }

# --- TASKS.json / worklog helpers (read from origin/main, NOT any working tree) -
# TASKS.json is the structured backlog (schema: .harness/docs/HARNESS.md §8.1), parsed with jq.
blob()         { git -C "$ROOT" show "$TASKS_REF:.harness/$1" 2>/dev/null || true; }
# tj — query TASKS.json. Normally reads the committed backlog from $TASKS_REF. When DRY_TASKS is set
# (the DRY_RUN preview, see below), it queries THAT in-memory JSON instead, so the preview selects
# against the SAME overlay-reconciled view the real run builds — without reconcile_overlays' write.
tj()           { if [ -n "${DRY_TASKS:-}" ]; then jq "$@" <<<"$DRY_TASKS" 2>/dev/null; else blob tracking/TASKS.json | jq "$@" 2>/dev/null; fi; }
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
OUTCOME_ROW_JQ="$SCRIPT_DIR/outcome-row.jq"      # the shared ledger-row filter (C01) — see outcome_row()
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
     -c -f "$OUTCOME_ROW_JQ"
}


# flush_failures lives in loop-lib.sh, sourced above (loop.sh always passes an explicit <id> <dest>).

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
# overlay_apply <tasks-json> — PURE transform: echo TASKS.json with owner-overlay verdicts applied
# in-memory (human-done "done" for a needs-human task; manual-fail "failed" for any not-yet-failed
# task). NO writes, NO git. Shared by reconcile_overlays (which then persists) and the DRY_RUN preview
# (which must NOT persist). human-done promotes ONLY a needs-human task (the gate guard stops a stray
# entry marking an ordinary task done unbuilt); manual-fail is kept terminal by task_failed() in select_task.
overlay_apply() {
  local tasks="$1" hd md
  [ -n "$tasks" ] || return 1
  hd="$(blob tracking/human-done.json)"; [ -n "$hd" ] || hd='{}'
  md="$(blob tracking/manual-fail.json)"; [ -n "$md" ] || md='{}'
  jq -c --argjson hd "$hd" --argjson md "$md" '
    .tasks |= map(
      if (.status != "failed") and ($md[.id].failed == true) then .status = "failed"
      elif (.gate == "needs-human") and (.status != "done") and ($hd[.id].done == true) then .status = "done"
      else . end
    )' <<<"$tasks" 2>/dev/null
}

reconcile_overlays() {
  local tasks new
  tasks="$(blob tracking/TASKS.json)"; [ -n "$tasks" ] || return 0
  new="$(overlay_apply "$tasks")"
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
    # A forced id still must not bypass the SAME terminal-status skips the normal path applies below
    # (B03) — otherwise a forced-done task gets cold-rebuilt (the builder finds nothing to do → idle →
    # repeated idle flips a genuinely-finished task to blocked), and forcing a gated/failed/blocked id
    # builds something the loop is never supposed to touch on its own. Once this refuses, the caller's
    # empty-select exit is naturally one-shot: FORCE_TASK is never cleared, but the task's status on
    # origin/main won't change again either, so a re-run of this same check keeps refusing it.
    if task_done "$FORCE_TASK"; then
      log "FORCE_TASK '$FORCE_TASK' is already status=done — refusing to rebuild a terminal task."; return 1
    fi
    if task_failed "$FORCE_TASK"; then
      log "FORCE_TASK '$FORCE_TASK' is status=failed (owner-overturned) — refusing to rebuild a terminal task."; return 1
    fi
    if task_gated "$FORCE_TASK"; then
      log "FORCE_TASK '$FORCE_TASK' is gate:needs-human — the loop never selects it, even when forced."; return 1
    fi
    if task_blocked "$FORCE_TASK"; then
      log "FORCE_TASK '$FORCE_TASK' is status=blocked (loop-exhausted) — refusing to rebuild a terminal task."; return 1
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
# ci_find_run <branch-or-empty> <sha> — echo the databaseId of the CI run for <sha>, matching the
# workflow by NAME ($CI_WORKFLOW) first, then falling back to its FILE PATH. GitHub reports a run's
# workflowName as ".github/workflows/…" (the raw path) instead of the resolved `name:` when the workflow
# file itself can't be parsed — so a path-shaped workflowName is the signature of a MALFORMED workflow
# (a valid-YAML-but-invalid-schema CI file). Without this fallback the exact-name match finds nothing and
# the caller sits out the full CI_TIMEOUT then calls it "indeterminate". Sets CI_NAME_UNRESOLVED=1 when
# the fallback matched (caller warns + treats as red), else 0. (Shared with ci_status_now / the idle guard.)
CI_NAME_UNRESOLVED=0



# wait_ci_green lives in loop-lib.sh, sourced above (loop.sh always passes its tNNN branch).

# Integrate by fast-forwarding main. Single-flight keeps it a ff; if main moved
# (another actor pushed), the ff is rejected and we soft-fail so the agent absorbs it.
# throttled_push <dir> <push-args...> — like `git -C <dir> push <push-args...>`, but enforces
# PUSH_COOLDOWN_SECONDS between successful pushes (persisted in a gitignored-equivalent file under
# .git, so it survives across loop.sh invocations). 0 (default) = no throttle, zero overhead.
PUSH_COOLDOWN_FILE="$GIT_COMMON/${NAME}-last-push"

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
# Project-defined test-file patterns (custom/test-file-patterns.txt) → TEST_FILE_EXTRA_RE, so
# structural_checks' expectsTest gate + the test-file scope exemption recognise this repo's own
# convention (e.g. Xcode UITests/). Built-in conventions always stay active; a bad regex is ignored.
test_patterns_load "$HARNESS_DIR" || log "WARN: custom/test-file-patterns.txt has an invalid regex — ignoring it; using the built-in test-file conventions only."

guard_clean() {   # <branch> — 0 = clean, 1 = a sensitive path is staged for integration
  local branch="$1" bad
  bad="$(git -C "$ROOT" diff --name-only "origin/main..origin/$branch" 2>/dev/null | grep -nE "$SENSITIVE_RE" | grep -vE "$GUARD_ALLOW_RE" || true)"
  [ -z "$bad" ] && return 0
  log "PRE-INTEGRATE GUARD TRIPPED — refusing to fast-forward $branch → main. Sensitive paths:"
  printf '   %s\n' $bad >&2
  return 1
}

[ "${1:-}" = "--guard-selftest" ] && { guard_selftest "${2:-}"; exit $?; }
# --test-selftest <path>: print TEST / NOT-TEST for <path> against the EFFECTIVE test-file matcher (built-in
# conventions + any custom/test-file-patterns.txt) — a "does the harness see this as a test?" probe. Handy
# to confirm an unusual convention (e.g. Xcode UITests/) is recognized before relying on expectsTest.
[ "${1:-}" = "--test-selftest" ] && { if is_test_path "${2:-}"; then echo TEST; else echo "NOT-TEST"; fi; exit 0; }

integrate() {
  local branch="$1"
  guard_clean "$branch" || return 1
  # SINGLE-COMMIT INVARIANT — collapse the branch's commit(s) into ONE before fast-forwarding `main`, so a
  # task lands as exactly one commit (clean history + a one-line revert later). The prompt asks the builder
  # for one commit (amend to iterate), but a cheap model may stack several; the loop guarantees it here. The
  # squashed commit keeps the SAME TREE CI validated (reset --soft preserves it) and its parent is
  # origin/main, so the push below stays a fast-forward; --no-verify makes it a pure history collapse.
  local n
  n="$(git -C "$LOOP_WT" rev-list --count "origin/main..$branch" 2>/dev/null || echo 0)"
  if [ "${n:-0}" -gt 1 ]; then
    local subj body
    subj="$(git -C "$LOOP_WT" log --reverse --format='%s' "origin/main..$branch" 2>/dev/null | head -1)"
    body="$(git -C "$LOOP_WT" log --reverse --format='%B' "origin/main..$branch" 2>/dev/null)"
    if git -C "$LOOP_WT" reset --soft "origin/main" 2>/dev/null \
       && git -C "$LOOP_WT" commit -q --no-verify -m "${subj:-$branch}" -m "$body"; then
      log "squashed $n commits into one before integrating $branch (single-commit history)"
    else
      log "WARN: squash failed for $branch — integrating $n commits as-is."
    fi
  fi
  throttled_push "$LOOP_WT" --quiet origin "$branch:main" 2>/dev/null && return 0
  log "ff to main rejected (main moved under us) — soft"; return 1
}




# --- Per-task build prompt --------------------------------------------------
prompt() {
  local tid="$1" branch="$2"
  printf 'You are the autonomous builder for THIS repo. Build EXACTLY ONE task: %s, then stop.\n' "$tid"
  printf 'You are in a DEDICATED git worktree already checked out on branch `%s`. Work HERE only — do NOT switch branches, create branches, or touch any other checkout on this machine.\n' "$branch"
  cat <<'EOF'

Obey CLAUDE.md, .harness/tracking/TASKS.json, and .harness/docs/HARNESS.md exactly. You run
head-less and unattended. First read CLAUDE.md (conventions) and README.md (for product context).

1. BUILD COLD. You are starting FRESH on a clean branch off origin/main — do NOT look for or rely on
   any prior-attempt state (worklog, partial commits); build this task from the spec alone. Read this
   task's object in .harness/tracking/TASKS.json (find it with `jq '.tasks[]|select(.id=="<TASK>")'
   .harness/tracking/TASKS.json`); if its `design` field points to a `.harness/docs/designs/…` doc,
   READ and follow it. The task's `do` + `done-when` live in the Markdown spec at the JSON `spec`
   path (.harness/tasks/<TASK>.md, sections '## Do' / '## Done when') — its FULL TEXT is appended at
   the end of this prompt. Stay within the task's `scope` — the exact allowed-files list + the
   HARD-GATE rule are shown under "SCOPE" at the end of this prompt.
2. DEFINITION OF DONE (.harness/docs/HARNESS.md §5 — all must hold before you report `done`):
   a. Run the project's full verification suite exactly as defined in CLAUDE.md /
      .harness/docs/HARNESS.md §5 (format, lint, tests, build). These MIRROR CI — if CI runs it,
      run it locally first. Every check must pass. Run every check to COMPLETION and read its real
      exit status: for a SLOW check (a multi-minute build/test), request an extended tool timeout or
      run it in the background and POLL to completion — never fire it under a default-timeout blocking
      call and assume it passed. A check that times out, is still running, or whose result you did not
      OBSERVE is NOT a pass — that is `failed:soft` (retryable), never `done`.
   b. Run the task's relevant integration / end-to-end tests when their preconditions are
      met. Tests that need credentials, funds, or external resources you don't have: leave
      them as they are and record `failed:blocked` if the task's core needs them — never
      silently skip a required check and call it "passed".
   c. If the task's `verify` field names extra EMPIRICAL checks (e.g. run the app against
      real input for a bounded window and observe it behaves), perform them and record what
      you OBSERVED in the worklog. The bar is the behaviour the task specifies.
3. DO NOT edit .harness/tracking/TASKS.json — the loop, not the builder, sets `"status"` to `"done"`
   itself once your build clears the structural checks + audit gate below, in a follow-up commit
   the loop makes on its own. NEVER edit the repo-root README.md — it is maintainer-owned product
   documentation, NOT a status log, and touching it AUTO-FAILS this task (the loop never updates it).
   Keeping project documentation current is the maintainers' job, not yours: build only what the spec
   asks, and if the spec itself names a doc file to change AND that file is inside your `scope`, change
   that file — otherwise touch no docs.
4. COMMIT — produce EXACTLY ONE commit for the whole task, `<TASK>: <summary>` (INCLUDING
   `.harness/worklog/<TASK>.md` with a dated entry: what you did, checks run, what remains). If you iterate,
   fold changes into that SAME commit with `git commit --amend` — do NOT stack multiple commits (the loop
   integrates a task as one commit). Do NOT push and do NOT merge — **NEVER `git push`**, not ever, even if
   your global git guidance says to always push after committing (that rule does NOT apply here). The loop is
   the SOLE pusher: after you finish it runs your checks (structural + LOCAL_DOD), pushes your `<branch>`,
   watches GitHub CI, and fast-forwards `main` on green — a push from you is BLOCKED by a git hook and
   bypasses that local gate. `HARNESS_AGENT` is the loop's private env marker: never set, unset, or pass it
   to any command. Your CI is LOCAL (step 2) — run it yourself; you never push to see CI.
5. As your FINAL action, OVERWRITE `.harness/worklog/.result` with exactly ONE line. Report `done` ONLY
   when every Definition-of-Done check has FINISHED and PASSED — never while a check is still running or its
   outcome is unknown (that is `failed:soft`):
     done <TASK> <branch>                 # built + committed on <branch> (NOT pushed) — loop pushes + gates CI
     failed:soft <TASK> <reason>          # transient / partial — retry is worthwhile
     failed:blocked <TASK> <reason>       # needs-human / unmet prereq — do NOT retry
     waiting <TASK> <unmet-deps>          # a dependency is not merged yet
     idle                                 # nothing to do for this task
EOF
  # SCOPE — HARD GATE + expectsTest blocks: shared with loop.in-place.sh via loop-lib.sh's
  # scope_gate_block/expects_test_block. The final "PLUS you may always…" line stays HERE (not in the
  # shared block) — it legitimately differs per variant (see scope_gate_block's own comment).
  scope_gate_block "$tid"
  printf '%s\n' 'PLUS you may always add/change TEST files and your own .harness/worklog/<TASK>.md. Touching ANY OTHER file — including .harness/tracking/TASKS.json (the loop owns it) or a doc not listed above — AUTO-FAILS this task. If you genuinely need a file that is not listed, do NOT edit it: record `failed:blocked <TASK> needs <file> (out of scope)` so a human can fix the scope.'
  expects_test_block "$tid"
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
# RL_RE/RL_HARD_RE/RL_BUFFER + rl_reset_wait/rl_cli_said/rl_detect/run_claude live in loop-lib.sh,
# sourced above (run_claude reads the WORK_DIR/PROMPT_DIR seam assigned near LOOP_WT above).

# --- Verification-aware Definition of Done (designs/audit-verification.md) -------------------------
# Worktree variant: the build lives in $LOOP_WT on branch tNNN; the audit runs AFTER branch CI is
# green and BEFORE the fast-forward to main, so unaudited work never reaches main. Cold-ness is
# enforced by tearing the branch/worktree down on every capability failure (see the done/fail paths).

# normalize_scope_prefix + scope_match live in the shared scope-lib.sh (sourced at the top of this
# script, next to repo-lock.sh) — the SINGLE implementation shared with loop.in-place.sh and
# check-task-scope.sh. It used to be duplicated verbatim in all three and drifted/re-broke; don't inline
# it here again (scope-match.test.sh fails if any of the three grows its own copy).


[ "${1:-}" = "--scope-exempt-selftest" ] && { scope_exempt_selftest "${2:-}" "${3:-}"; exit $?; }

[ "${1:-}" = "--scope-selftest" ] && { scope_selftest "${2:-}" "${3:-}"; exit $?; }

# rl_selftest lives in loop-lib.sh, sourced above.
[ "${1:-}" = "--rl-selftest" ] && { rl_selftest "${2:-}" "${3:-}" "${4:-}" "${5:-}"; exit $?; }

# structural_checks lives in loop-lib.sh, sourced above (reads the WORK_DIR/PROMPT_DIR/MAIN_BRANCH
# seam assigned near LOOP_WT above).

# --struct-selftest <id> — runs the REAL structural_checks against whatever is ALREADY committed on
# $LOOP_WT's current branch (the caller sets up the fixture: a real worktree, a task in TASKS.json on
# origin/main, a diverging commit) and prints STRUCT_FAIL_KIND, or PASS if it returns 0. No claude
# subprocess, no gh/network — actionlint/LOCAL_DOD checks are naturally skipped unless the fixture's
# diff/env actually trigger them. Covers D01 (unauthorized [skip ci]) plus a baseline for the
# pre-existing empty-diff/scope-creep checks, which had no behavioral coverage before this — see
# tests/struct-checks.test.sh.
if [ "${1:-}" = "--struct-selftest" ]; then
  structural_checks "${2:-T001}" || true
  echo "${STRUCT_FAIL_KIND:-PASS}"
  exit 0
fi

# audit_prompt lives in loop-lib.sh, sourced above.

# audit_verdict_extract <file> — reads the auditor's FINAL non-empty line and extracts a sentinel
# verdict (`VERDICT: PASS` / `VERDICT: FAIL`, case-sensitive, trailing whitespace tolerated). Echoes
# PASS, FAIL, or nothing if the sentinel is absent/malformed — NEVER greps the whole transcript, since
# auditor prose narrating "I'll check if tests pass" would otherwise false-match (B01).
audit_verdict_extract() {
  awk 'NF{last=$0} END{print last}' "$1" 2>/dev/null | sed 's/[[:space:]]*$//' \
    | grep -oE '^VERDICT: (PASS|FAIL)$' | grep -oE 'PASS|FAIL' || true
}
# --audit-parse-selftest <transcript-file> → PASS|FAIL|NONE. Exercises audit_verdict_extract off-line
# against fixture transcripts (prose-pass-then-FAIL, prose-fail-then-PASS, sentinel-only, no-sentinel,
# trailing-whitespace) — see tests/audit-parse.test.sh.
if [ "${1:-}" = "--audit-parse-selftest" ]; then
  v="$(audit_verdict_extract "${2:-/dev/null}")"; [ -n "$v" ] && echo "$v" || echo NONE
  exit 0
fi

# audit_gate <id> — per-cell SAMPLED blocking audit (§4.3/4.6) on the CI-green branch. Sets
# cur_verification. Spawns a fresh, independent auditor at max(opus-medium, builder tier) ONLY if
# sampled. 0 = pass (or not sampled), 1 = audit FAIL (a failed attempt).
audit_gate() {
  local id="$1" layer wt count pm bi ai am ae rel spec="" diff out verdict arc rlpoll rl_waited
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
  # B04: the PRIMARY checkout's worklog, not $LOOP_WT — see the matching comment on run_claude's
  # raw/out derivation for why (the worktree tears down within seconds of this attempt ending).
  out="$HARNESS_DIR/worklog/$id.audit.md"
  rl_waited=0   # B07 fix 2: cap the audit-path RL loop like the build path — it used to retry forever
  while :; do
    # `… || arc=$?` (NOT `; arc=$?`) — run_claude flips `set -e` back ON internally before it
    # `return`s, so a bare `; arc=$?` would let a nonzero return KILL loop.sh right here (before arc
    # is ever captured) instead of triggering the auditor rate-limit backoff below. The `||` keeps
    # the call in an AND-OR list, which `set -e` never aborts on.
    arc=0; set +e; run_claude "$am" "$ae" "$(audit_prompt "$id" "$spec" "$diff")" audit || arc=$?; set -e
    if [ "$arc" = 10 ]; then
      # B07 fix 2: same rl_waited/RL_MAX_WAIT accounting as the build path (the ONLY difference from
      # there is the fallback poll interval on a reset time we can't parse — RL_POLL, not exponential
      # backoff, since the audit path doesn't need the build path's own-attempt-budget shape). Without
      # this a genuine, prolonged limit during the audit step slept the loop forever with no way out.
      if [ "$rl_waited" -ge "$RL_MAX_WAIT" ]; then
        log "audit: still usage/session-limited after ${rl_waited}s (cap ${RL_MAX_WAIT}s) — exiting for supervise to relaunch later."
        run_hook exhausted rate-limit; board; exit 5
      fi
      rlpoll="$(rl_reset_wait "$HARNESS_DIR/worklog/.claude-out.audit" || true)"; rlpoll="${rlpoll:-$RL_POLL}"
      rl_banner "$rlpoll" "$HARNESS_DIR/worklog/.claude-out.audit" "(this is the AUDIT step, not the build — NOT an audit fail; waited $(_hms "$rl_waited") so far)"
      sleep "$rlpoll"; rl_waited=$(( rl_waited + rlpoll )); continue
    fi
    break
  done
  cp "$HARNESS_DIR/worklog/.claude-out.audit" "$out" 2>/dev/null || true
  verdict="$(audit_verdict_extract "$out")"
  if [ "$verdict" = "PASS" ]; then cur_verification="audited"; log "audit: PASS for $id (reasons → $out)"; return 0; fi
  if [ -z "$verdict" ]; then
    cur_audit_kind="audit-unparseable"
    log "audit: UNPARSEABLE verdict for $id — no 'VERDICT: PASS' / 'VERDICT: FAIL' sentinel on the final line (reasons → $out) — treating as FAIL"
  else
    cur_audit_kind="audit-fail"
    log "audit: FAIL for $id (verdict='$verdict', reasons → $out)"
  fi
  return 1
}

# --audit-rl-cap-selftest <id> — exercises B07 fix 2 (the audit-path RL_MAX_WAIT cap) IN-PROCESS: no
# real claude subprocess, no real audit sampling decision. Redefines run_claude (last definition
# wins in bash) to ALWAYS report rate-limited with no parseable reset time, forces a mandatory audit
# via cur_explored=1 (skips the sampling roll), then calls the real audit_gate and lets its retry
# loop run for real — asserting it actually gives up (process exit 5) once RL_MAX_WAIT is exceeded,
# rather than sleeping forever. Caller sets RL_MAX_WAIT/RL_POLL small and prepares a repo + LOOP_WT
# with a real task id — see tests/loop-ratelimit.test.sh.
if [ "${1:-}" = "--audit-rl-cap-selftest" ]; then
  run_claude() {
    local phase="$4"
    # B04: matches where the REAL run_claude now writes (the primary checkout, not $LOOP_WT) — this
    # override exists to simulate exactly what real run_claude would produce.
    printf 'Claude AI usage limit reached.\n' > "$HARNESS_DIR/worklog/.claude-out.$phase"
    : > "$HARNESS_DIR/worklog/.claude-out.$phase.jsonl"
    return 10
  }
  cur_explored=1; cur_base=0; cur_rung=0
  mkdir -p "$HARNESS_DIR/worklog"
  audit_gate "${2:-T001}"
  exit $?
fi

# --audit-trail-selftest <id> <PASS|FAIL> — exercises B04 (the worktree variant's audit output must
# survive worktree teardown) IN-PROCESS: no real claude subprocess. Redefines run_claude (last
# definition wins in bash) to write a sentinel VERDICT line and return 0 (no rate-limit branch),
# forces a mandatory audit via cur_explored=1, then calls the real audit_gate. Does NOT tear the
# worktree down itself — the caller does that (simulating cleanup_task) AFTER this process exits, then
# checks $HARNESS_DIR/worklog/<id>.audit.md survived — see tests/audit-trail-persistence.test.sh.
if [ "${1:-}" = "--audit-trail-selftest" ]; then
  run_claude() {
    local phase="$4"
    # B04: matches where the REAL run_claude now writes (the primary checkout, not $LOOP_WT).
    printf 'auditor reasoning here\nVERDICT: %s\n' "${_AUDIT_TRAIL_VERDICT:-FAIL}" > "$HARNESS_DIR/worklog/.claude-out.$phase"
    : > "$HARNESS_DIR/worklog/.claude-out.$phase.jsonl"
    return 0
  }
  _AUDIT_TRAIL_VERDICT="${3:-FAIL}"
  cur_explored=1; cur_base=0; cur_rung=0
  mkdir -p "$HARNESS_DIR/worklog"
  audit_gate "${2:-T001}"
  exit $?
fi

# --- Corrupt-backlog pre-flight: a backlog that won't parse must fail CLOSED (exit 3) ------------
# tj()/select_task swallow all errors (blob's `|| true`, jq's `2>/dev/null`), so a missing, empty,
# unparseable, or unresolvable-ref TASKS.json would otherwise make select_task return "nothing
# eligible" → the loop logs "backlog complete", fires `drained`, syncs, and exits 0 → supervise
# treats that as success and idles the whole token-refresh window. A corrupt backlog must NEVER read
# as a finished one. Runs before the DRY_RUN block so a dry run surfaces corruption too. (jq empty
# exits 0 on empty/zero input, so guard non-emptiness explicitly.)
_backlog_blob="$(blob tracking/TASKS.json)"
if ! { [ -n "$_backlog_blob" ] && printf '%s' "$_backlog_blob" | jq empty 2>/dev/null; }; then
  log "FATAL: $TASKS_REF:.harness/tracking/TASKS.json is missing, empty, or not valid JSON — refusing to run (a corrupt backlog must never read as 'backlog complete'). Fix the backlog or TASKS_REF, then restart."
  exit 3
fi
unset _backlog_blob

# --- Dry run: print the task SELECT would build next, then exit (no lock, no work) ---
if [ "${DRY_RUN:-0}" = "1" ]; then
  git -C "$ROOT" fetch origin --quiet 2>/dev/null || true
  # Match the real run's POST-reconcile view (an owner's human-done/manual-fail overlay takes effect on
  # the next real iteration) WITHOUT reconcile_overlays' write/commit/push — apply the overlays in
  # memory only, so a just-marked-done needs-human task's dependents show as eligible here too.
  DRY_TASKS="$(overlay_apply "$(blob tracking/TASKS.json)" || true)"
  sel="$(select_task || true)"
  [ -n "$sel" ] && echo "DRY-RUN → would build: $sel" \
                || echo "DRY-RUN → nothing eligible (backlog done or all gate/human-blocked)"
  exit 0
fi

# --- Main loop --------------------------------------------------------------
acquire_lock
# A trap that doesn't `exit` just returns control to wherever the script was interrupted — the loop
# would keep running after releasing the lock (verified: `kill -TERM` left it alive). Explicit
# `trap - EXIT` before the exit stops the EXIT trap from firing a second time (B02).
trap 'release_lock' EXIT
trap 'release_lock; trap - EXIT; exit 130' INT
trap 'release_lock; trap - EXIT; exit 143' TERM

cur_task=""; cur_attempts=0; cur_rung=0; cur_base=0; cur_explored=0; cur_verification="ci-only"; cur_audit_kind="audit-fail"; hb_started=""
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
    if [ -n "$FORCE_TASK" ]; then
      # FORCE_TASK is one-shot BY CONSTRUCTION (B03): it's never cleared, but once the forced task
      # reaches a terminal outcome (integrated → done, or blocked), select_task's forced-path check
      # refuses to re-select it on the next iteration — so this exit fires right after, distinct from
      # an actually-drained backlog.
      log "forced task $FORCE_TASK is not eligible to build (see the refusal above) or already reached its outcome for this run — exiting; run supervise.sh (or loop.sh with no argument) to work the rest of the backlog."
    else
      log "no eligible task — backlog complete or everything left is gate/human-blocked."
    fi
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
      # C01: the backoff decision (parsed-reset vs. exponential, banner, sleep, RL_MAX_WAIT give-up)
      # lives in loop-lib.sh's rl_build_wait — identical across both variants except which out-file
      # path they pass in.
      read -r rl_waited rl_sleep <<<"$(rl_build_wait "$rl_waited" "$rl_sleep" "$HARNESS_DIR/worklog/.claude-out.build")"
      continue
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
      log "task $rtask built + committed on $branch (local — loop gates, then pushes)"
      # DETERMINISTIC LOCAL GATE FIRST — structural_checks (scope/empty-diff/expectsTest + LOCAL_DOD) runs
      # on the local branch HEAD in the worktree, BEFORE the branch ever reaches origin/CI. A build that
      # fails it is a failed attempt that never pushed anything — no wasted CI run, no branch on origin.
      # (This is the fix for LOCAL_DOD running post-CI; the LOOP — not the builder — now pushes, per P5.)
      if ! structural_checks "$task"; then
        record_failure "$task" "${STRUCT_FAIL_KIND:-structural}" "${STRUCT_FAIL_DETAIL:-}"
        if [ "${STRUCT_FAIL_KIND:-}" = scope-creep ]; then
          # Scope-creep is NOT a difficulty signal — it means the task's declared `scope` is wrong/too
          # narrow, which a retry or a stronger model can't fix (it would just burn the whole attempt
          # budget on a doomed task AND poison the (layer×workType) calibration with a fake "hard cell").
          # So block after ONE attempt for a human to correct the scope (or split the task). block_task
          # tears the branch/worktree down itself, so no cleanup_task here.
          log "structural: $task touched files OUTSIDE its declared scope (${STRUCT_FAIL_DETAIL:-}) — blocking after one attempt (a wrong scope isn't fixed by a retry or a stronger model)."
          block_task "$task" "scope-creep: diff touched files outside declared scope (${STRUCT_FAIL_DETAIL:-}) — the task's scope is likely too narrow or wrong; fix the scope (or split the task), then re-open"
          board; continue
        fi
        log "structural checks failed for $task — discarding (never pushed) + cold retry."; cleanup_task "$branch"; bump "$task"; board; continue
      fi
      # Local gate passed → the LOOP pushes the branch (sole pusher, P5) so CI can run and integrate can ff it.
      # A PLAIN push (not throttled_push): PUSH_COOLDOWN_SECONDS throttles *main integration* pushes, not the
      # per-attempt branch push. cleanup_task deletes any stale remote `tNNN` before each cold attempt, so a
      # non-ff rejection here means a genuine race → soft-fail + cold retry (never force-clobber).
      heartbeat pushing
      if ! git -C "$LOOP_WT" push --quiet origin "$branch"; then
        log "push of $branch rejected (remote moved / race) — tearing down for a COLD retry."; cleanup_task "$branch"; record_failure "$task" "push-race" "couldn't push $branch to origin"; bump "$task"; board; continue
      fi
      # A [skip ci]-tagged build commit never creates a workflow run, so wait_ci_green would sit out
      # the full CI_TIMEOUT and then loop on indeterminate. Skip the CI wait for such commits (an
      # operational / scope:[] task) and go straight to the audit gate.
      if [ "$REQUIRE_CI" = "1" ] && git -C "$ROOT" log -1 --format=%s "origin/$branch" 2>/dev/null | grep -qF '[skip ci]'; then
        log "[skip ci] build on $branch — no CI run expected; proceeding to audit gate."
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
      # Blocking audit AFTER CI green (deliberate divergence from in-place: don't pay for the expensive
      # audit until free CI confirms the build), BEFORE integrating — so nothing unaudited reaches main.
      # (structural_checks/LOCAL_DOD already ran above, pre-push.) A fail = a failed attempt (cold retry).
      heartbeat auditing
      if ! audit_gate "$task"; then
        log "AUDIT FAILED for $task — tearing down branch (never integrated) + cold retry."; cleanup_task "$branch"; record_failure "$task" "${cur_audit_kind:-audit-fail}"; bump "$task"; board; continue
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
        # GUARD: "work already on main" is NOT proof CI verified it — a prior wait_ci_green that couldn't
        # find a run (e.g. a malformed workflow file GitHub reported by path, not name) can leave a commit
        # on main, unmarked and un-reverted; the next cold attempt then reads it as idle. Re-check the
        # ACTUAL CI status for origin/main HEAD (point-in-time, no wait) before flipping status=done.
        idle_sha="$(git -C "$ROOT" rev-parse "$TASKS_REF" 2>/dev/null || true)"
        idle_ci=2; if [ -n "$idle_sha" ]; then idle_ci=0; ci_status_now "" "$idle_sha" || idle_ci=$?; fi
        if [ "$idle_ci" = 1 ]; then
          log "idle on $task but CI for origin/main ($idle_sha) is RED — refusing to reconcile done; BLOCKING for a human (a prior revert-on-red didn't happen, or the workflow file is broken)."
          block_task "$task" "idle-but-ci-red: work is on main but its CI is failing — needs a human (check the latest CI run / the .github/workflows file)"
          idle_task=""; idle_count=0
        else
          log "agent reports idle on $task — Done-when already met on main ($([ "$idle_ci" = 0 ] && echo 'CI green' || echo 'CI status unconfirmed — proceeding as before')); reconciling status=done and continuing."
          record_outcome "$task" false
          heartbeat_clear; cur_task=""; cur_attempts=0; cur_rung=0; cur_base=0; cur_explored=0
        fi
      fi
      ;;
    *)              log "unrecognized result '$status' — backing off"; sleep "$WAIT_SECONDS" ;;
  esac
  board
done

log "reached MAX_ITERS=$MAX_ITERS — stopping"; run_hook exhausted max-iters; board; exit 4
