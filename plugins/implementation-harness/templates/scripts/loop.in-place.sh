#!/usr/bin/env bash
# harness-loop-variant: in-place   # read by implementation-harness:upgrade to pick the right reference — do not remove
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
#   (below) that refuses to push if any sensitive/gitignored path is staged. See .harness/docs/HARNESS.md.
#
# Each iteration:
#   SELECT (shell)  — from TASKS.json: the next not-done task whose dependsOn are all done and
#                     which is NOT a 🔒 needs-human / blocked task. None → stop.
#   WORK   (claude) — one `claude -p` at the policy-chosen tier (facets + outcomes ledger; cold-start
#                     floor = harness.env) builds the task IN THIS CHECKOUT on main, runs the
#                     Definition of Done, and COMMITS (does NOT push).
#   GATE   (shell)  — pre-push guard (refuse if anything sensitive is staged) → push main → watch
#                     GitHub CI → green: mark the task done (+ optional integrate hook); red: STOP.
#
# Usage:  .harness/scripts/loop.sh [TNNN]          # optional: force a specific task id this run
#         DRY_RUN=1 .harness/scripts/loop.sh       # print the task it WOULD build, then exit
#         .harness/scripts/loop.sh --guard-selftest [path]  # verify the guard regex (or test one path), then exit
#         .harness/scripts/loop.sh --test-selftest <path>   # print TEST/NOT-TEST — is <path> seen as a test file? then exit
#         .harness/scripts/loop.sh --scope-exempt-selftest [globs path]  # verify SCOPE_EXEMPT_GLOBS matching, then exit
#         .harness/scripts/loop.sh --scope-selftest [entry file]  # verify scope-entry matching (extension globs), then exit
#         .harness/scripts/loop.sh --rl-selftest detect|wait …    # verify usage-limit detection + reset parsing, then exit
#         .harness/scripts/loop.sh --audit-parse-selftest <file>  # verify audit VERDICT sentinel extraction, then exit
#         .harness/scripts/loop.sh --audit-rl-cap-selftest <id>   # verify the audit-path RL_MAX_WAIT cap, then exit
#         .harness/scripts/loop.sh --struct-selftest <id>         # run structural_checks on the current checkout's commit, then exit
# Config: .harness/config/harness.env (sourced if present) and/or the environment.
# Extend: drop scripts under .harness/custom/hooks/ (on-<event>.sh) and patterns in
#         .harness/custom/sensitive-paths.txt — see .harness/docs/HARNESS.md "Extending the harness".
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

[ -f "$HARNESS_DIR/config/harness.env" ] && . "$HARNESS_DIR/config/harness.env"

# Shared mkdir-based repo lock (acquire_lock/release_lock) — sourced so its path derivation can
# never drift from other scripts (mark-*.sh, consolidate-ideas.sh) that coordinate with this loop.
. "$SCRIPT_DIR/repo-lock.sh"
# Shared scope-matching (normalize_scope_prefix + scope_match) — the SINGLE implementation, also sourced
# by loop.sh + check-task-scope.sh so the gate and the linter can never disagree.
. "$SCRIPT_DIR/scope-lib.sh"
# Shared loop logic (C01) — the RL_* rate-limit family so far (more moves in later stages). Sourced
# AFTER harness.env above so an env override of an RL_* knob still wins.
. "$SCRIPT_DIR/loop-lib.sh"

BACKLOG="$HARNESS_DIR/tracking/TASKS.json"
WORKLOG="$HARNESS_DIR/worklog"
# C01 seam for loop-lib.sh's run_claude/structural_checks: WORK_DIR is where the claude subprocess
# cd's to and where structural_checks' git-diff/actionlint/LOCAL_DOD run (the primary checkout here —
# no worktree); PROMPT_DIR is where the full per-phase prompt file AND the actionlint/local-dod logs
# are written (also the primary checkout — nothing to tear down, unlike the worktree variant).
# MAIN_BRANCH (below, near CI_WORKFLOW) is this variant's existing user-configurable knob, reused
# as-is by structural_checks — no new seam needed for it.
WORK_DIR="$ROOT"
PROMPT_DIR="$WORKLOG"
OUTCOMES="$HARNESS_DIR/ledgers/outcomes.jsonl"      # append-only escalation ledger — the SOLE input to difficulty calibration (forward-only)
FAILURES="$HARNESS_DIR/ledgers/failures.jsonl"      # append-only per-ATTEMPT diagnostics — never read by calibration
FACETS="$HARNESS_DIR/config/facets.json"            # facet vocabulary + global tier ladder + policy knobs
HUMAN_DONE="$HARNESS_DIR/tracking/human-done.json"  # owner overlay: needs-human task marked done
MANUAL_FAIL="$HARNESS_DIR/tracking/manual-fail.json" # owner overlay: a "done" task overturned as a false success
REVIEWS="$HARNESS_DIR/tracking/reviews.json"         # owner overlay: cosmetic reviewed-flag — the loop never reads/writes it
NAME="$(basename "$ROOT")"
MODEL="${MODEL:-claude-haiku-4-5}"              # COLD-START FLOOR — the cheapest tier; the policy tunes UP from here as it learns (pin the full id; the bare alias drifts)
EFFORT="${EFFORT:-}"                               # low|medium|high|xhigh|max, or empty for a model with no effort param (e.g. the default floor, Haiku) — the ladder escalates on failure
MAX_ATTEMPTS="${MAX_ATTEMPTS:-2}"                  # soft failures per rung before escalating (2: the global tier ladder is fine-grained, so fewer tries per rung bounds the total attempt budget)
MAX_ITERS="${MAX_ITERS:-100}"                      # global iteration backstop
WAIT_SECONDS="${WAIT_SECONDS:-30}"                 # backoff between retries / CI polls
CI_TIMEOUT="${CI_TIMEOUT:-1200}"                   # max seconds to wait for a CI run
CI_WORKFLOW="${CI_WORKFLOW:-CI}"                   # MUST match `name:` in the CI workflow yaml
REQUIRE_CI="${REQUIRE_CI:-1}"                      # 1 = never mark done without green CI
MAIN_BRANCH="${MAIN_BRANCH:-main}"
INTEGRATE_HOOK="${INTEGRATE_HOOK:-}"               # optional cmd run after each task integrates (deploy/restart)
VISUAL_VERIFY_HOOK="${VISUAL_VERIFY_HOOK:-${UI_VERIFY_HOOK:-}}"   # optional cmd for VISUAL verification (any platform); UI_VERIFY_HOOK is the back-compat alias
VISUAL_VERIFY_WORKTYPES="${VISUAL_VERIFY_WORKTYPES:-component style}"      # inherently-visual workTypes that auto-trigger on ANY layer
VISUAL_VERIFY_LAYERS="${VISUAL_VERIFY_LAYERS:-frontend}"                   # facet layers that auto-trigger (unless the workType is in SKIP below)
VISUAL_VERIFY_SKIP_WORKTYPES="${VISUAL_VERIFY_SKIP_WORKTYPES:-docs config logging}"   # workTypes with no visual surface — never auto-trigger on a VISUAL_VERIFY_LAYERS layer
SCOPE_EXEMPT_GLOBS="${SCOPE_EXEMPT_GLOBS:-}"       # optional space-separated extra path prefixes structural_checks always allows, beyond worklog+tests
PUSH_COOLDOWN_SECONDS="${PUSH_COOLDOWN_SECONDS:-0}"   # optional min seconds between integration pushes (0=off) — see harness.env
CLAUDE_BIN="${CLAUDE_BIN:-claude}"
CLAUDE_FLAGS="${CLAUDE_FLAGS:---dangerously-skip-permissions}"
PRINT_PROMPT="${PRINT_PROMPT:-1}"                # 1 = echo each prompt (the running phase only: build OR audit) to the console before invoking Claude; 0 = silence
# RL_* rate-limit knobs (poll/backoff/buffer defaults) live in loop-lib.sh, sourced above.
FORCE_TASK=""; [ "${1:-}" != "--guard-selftest" ] && [ "${1:-}" != "--scope-exempt-selftest" ] && [ "${1:-}" != "--scope-selftest" ] && [ "${1:-}" != "--rl-selftest" ] && [ "${1:-}" != "--test-selftest" ] && [ "${1:-}" != "--audit-parse-selftest" ] && [ "${1:-}" != "--audit-rl-cap-selftest" ] && [ "${1:-}" != "--struct-selftest" ] && FORCE_TASK="${1:-}"
POSTFLIGHT="$SCRIPT_DIR/postflight.sh"

read -r -a FLAGS <<<"$CLAUDE_FLAGS"


# _hms + rl_banner live in loop-lib.sh, sourced above.

command -v jq >/dev/null 2>&1 || { log "jq is required to parse TASKS.json — install it (e.g. brew install jq)"; exit 3; }

# Paths that must NEVER be pushed (data, secrets, browser profiles). TASKS.json + worklog/ ARE
# committed intentionally, so they are NOT blocked here. .env.example is a tracked placeholder
# template and is explicitly allowed past the guard (see guard_clean) — only the REAL .env* is blocked.
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

# --- Pre-push guard: refuse to push if anything sensitive is in the new commits ----
guard_clean() {
  local bad
  bad="$(git -C "$ROOT" diff --name-only "origin/$MAIN_BRANCH..HEAD" 2>/dev/null | grep -nE "$SENSITIVE_RE" | grep -vE "$GUARD_ALLOW_RE" || true)"
  [ -z "$bad" ] && return 0
  log "PRE-PUSH GUARD TRIPPED — refusing to push. Sensitive paths in pending commits:"
  printf '   %s\n' $bad >&2
  return 1
}

[ "${1:-}" = "--guard-selftest" ] && { guard_selftest "${2:-}"; exit $?; }
# --test-selftest <path>: print TEST / NOT-TEST for <path> against the EFFECTIVE test-file matcher (built-in
# conventions + any custom/test-file-patterns.txt) — a "does the harness see this as a test?" probe. Handy
# to confirm an unusual convention (e.g. Xcode UITests/) is recognized before relying on expectsTest.
[ "${1:-}" = "--test-selftest" ] && { if is_test_path "${2:-}"; then echo TEST; else echo "NOT-TEST"; fi; exit 0; }

[ -f "$BACKLOG" ] || { log "no .harness/tracking/TASKS.json — nothing to build"; exit 3; }
# A backlog that exists but won't parse (truncated/corrupt) or is empty must ALSO fail CLOSED
# (exit 3), never read as "backlog complete" (exit 0): select_task swallows jq errors, so a corrupt
# backlog would otherwise select nothing → the loop logs "backlog complete" and supervise idles the
# whole token-refresh window on it. (jq empty exits 0 on empty/zero input, so guard emptiness too.)
if ! { [ -s "$BACKLOG" ] && jq empty "$BACKLOG" 2>/dev/null; }; then
  log "FATAL: $BACKLOG is empty or not valid JSON — refusing to run (a corrupt backlog must never read as 'backlog complete'). Fix the backlog, then restart."
  exit 3
fi

# --- TASKS.json helpers (read from the local backlog file) ------------------
# tj — query TASKS.json. Normally reads the local $BACKLOG. When DRY_TASKS is set (the DRY_RUN preview,
# see below), it queries THAT in-memory JSON instead, so the preview selects against the SAME overlay-
# reconciled view the real run builds — without reconcile_overlays' write.
tj()           { if [ -n "${DRY_TASKS:-}" ]; then jq "$@" <<<"$DRY_TASKS" 2>/dev/null; else jq "$@" "$BACKLOG" 2>/dev/null; fi; }
all_tasks()    { tj -r '.tasks[].id'; }
task_done()    { tj -e --arg id "$1" '.tasks[]|select(.id==$id)|.status=="done"' >/dev/null; }
deps_for()     { tj -r --arg id "$1" '.tasks[]|select(.id==$id)|.dependsOn[]?' | tr '\n' ' '; }
task_gated()   { tj -e --arg id "$1" '.tasks[]|select(.id==$id)|.gate=="needs-human"' >/dev/null; }   # 🔒 needs-human — the loop never selects it
# A loop-exhausted task: status="blocked" is set directly by block_task() — a first-class TASKS.json
# status value, so the dashboard can see it the same way it sees a manual-fail. The worklog-marker
# check is a fallback for tasks blocked before this existed; a task blocked going forward gets both.
task_blocked() {
  tj -e --arg id "$1" '.tasks[]|select(.id==$id)|.status=="blocked"' >/dev/null 2>&1 \
    || { [ -f "$WORKLOG/$1.md" ] && grep -qiE 'failed:blocked|needs-human' "$WORKLOG/$1.md"; }
}
# A task the owner marked FAILED, reconciled into TASKS.json status="failed" by reconcile_overlays().
# TERMINAL: the loop must NEVER (re)select it — the re-do is a separate follow-up task, not an
# auto-reopen. Without this skip, reconcile flips the false-success done→failed every iteration while
# select_task keeps rebuilding it (not done, not gated, not blocked) → an infinite rebuild that also
# silently reverts the owner's "this success was wrong" verdict.
task_failed()  { tj -e --arg id "$1" '.tasks[]|select(.id==$id)|.status=="failed"' >/dev/null; }
# set_task_status <id> <status> — atomic, field-scoped edit of TASKS.json (temp-file + rename),
# leaving every other field/task verbatim. Returns non-zero (and leaves TASKS.json untouched) on
# jq failure.
set_task_status() {
  local id="$1" s="$2" tmp="$BACKLOG.tmp"
  jq --arg id "$id" --arg s "$s" '(.tasks[]|select(.id==$id)|.status)=$s' "$BACKLOG" >"$tmp" \
    && mv "$tmp" "$BACKLOG" || { rm -f "$tmp"; return 1; }
}
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
      -c -f "$OUTCOME_ROW_JQ")"
  if [ -n "$line" ]; then printf '%s\n' "$line" >>"$OUTCOMES"; else log "WARN: couldn't record outcome for $id"; fi
}

# record_failure <id> <kind> [detail] — buffer ONE per-attempt diagnostic row locally (never
# committed directly). Diagnostics only — never read by calibration (policy.jq reads only
# ledgers/outcomes.jsonl). Flushed into ledgers/failures.jsonl by flush_failures at the task's next
# terminal outcome (mark_done or block_task), alongside the outcome row, in the SAME commit.
FAILURES_BUF="$WORKLOG/.failures.buf"   # gitignored; survives cold_reset (git clean -fd doesn't remove ignored files)

# ─── Heartbeat: the dashboard's live "Now" view, AND the escalation-ladder resume signal ────────
# worklog/.current.json — a best-effort breadcrumb of what the loop is doing RIGHT NOW (task, phase,
# rung, attempt, base tier). Written at phase transitions; cleared ONLY at a genuine terminal outcome
# for the current task (block_task(), a done-integration branch, or the drained-backlog exit) — NOT
# in the EXIT/INT/TERM trap. So a heartbeat still present at process START means the PRIOR process
# never reached one of those terminal points: a hard kill/crash, or (via supervise.sh) a relaunch
# after exit 4 (MAX_ITERS) or exit 5 (rate-limit) — i.e. a genuinely interrupted mid-climb, not a
# fresh cold start. That leftover file IS read back once, near the top of the main loop below, to
# resume cur_rung/cur_attempts/cur_base instead of cold-starting the ladder — see the "resume an
# interrupted mid-climb" block. Every write is still `|| true`; it lives among the gitignored
# worklog scratch so it can never be committed or affect a diff.
HEARTBEAT="$WORKLOG/.current.json"
# record_failure lives in loop-lib.sh, sourced above.
# flush_failures lives in loop-lib.sh, sourced above (loop.in-place.sh always calls it with NO
# argument, so it uses the default $FAILURES).

# throttled_push <dir> <push-args...> — like `git -C <dir> push <push-args...>`, but enforces
# PUSH_COOLDOWN_SECONDS between successful pushes (persisted in a gitignored-equivalent file under
# .git, so it survives across loop.sh invocations). 0 (default) = no throttle, zero overhead.
PUSH_COOLDOWN_FILE="$GIT_COMMON/${NAME}-last-push"

# status_done_on_remote <id> — true iff origin/$MAIN_BRANCH's TASKS.json ALREADY records $id as done.
# Used to VERIFY a status flip actually persisted: a lost flip (a push that never landed, or a no-op
# commit) is silently reverted by the next cold_reset, orphaning the task on main as pending-though-done
# — the exact trigger for the idle-verdict stall. Best-effort read; any gap → false (caller retries).
status_done_on_remote() {
  local id="$1"
  git -C "$ROOT" fetch origin --quiet 2>/dev/null || true
  git -C "$ROOT" show "origin/$MAIN_BRANCH:.harness/tracking/TASKS.json" 2>/dev/null \
    | jq -e --arg id "$id" 'any(.tasks[]; .id==$id and .status=="done")' >/dev/null 2>&1
}

mark_done() {
  local id="$1" tmp="$BACKLOG.tmp"   # same-dir temp → mv is an atomic rename (no cross-fs partial reads)
  jq --arg id "$id" '(.tasks[]|select(.id==$id)|.status)="done"' "$BACKLOG" >"$tmp" \
    && mv "$tmp" "$BACKLOG" || { rm -f "$tmp"; log "WARN: failed to mark $id done"; return 1; }
  record_outcome "$id" false                        # success → ledger row (succeededRung=cur_rung)
  flush_failures
  # Stage always-present files first, then failures.jsonl ONLY if it exists. A single combined
  # `git add … "$FAILURES"` fails ATOMICALLY when failures.jsonl is absent (the common first-try
  # success case — flush_failures only creates it after a soft failure), staging NOTHING, so the
  # commit silently no-ops and status=done never persists → next cold_reset wipes it → orphaned task.
  # Do NOT recombine these adds.
  git -C "$ROOT" add "$BACKLOG" "$WORKLOG" "$OUTCOMES" 2>/dev/null || true
  [ -f "$FAILURES" ] && git -C "$ROOT" add "$FAILURES" 2>/dev/null || true
  git -C "$ROOT" commit -q -m "$id: mark done [skip ci]" 2>/dev/null || true
  # Persist-or-shout: VERIFY status=done actually reached origin/$MAIN_BRANCH; retry the push once; if it
  # STILL hasn't landed, log an ERROR so a human sees the divergence rather than it silently re-appearing
  # as pending after the next cold_reset (the precondition for the idle-verdict stall).
  local _persisted=0 _try
  for _try in 1 2; do
    git -C "$ROOT" push origin "HEAD:$MAIN_BRANCH" 2>/dev/null || true
    if status_done_on_remote "$id"; then _persisted=1; break; fi
    sleep 1
  done
  [ "$_persisted" = 1 ] || log "ERROR: status=done for $id did NOT persist to $MAIN_BRANCH after 2 tries — it may re-appear as pending (idle-stall risk); mark it done by hand if so."
}

# reconcile_overlays — promote owner-overlay verdicts into authoritative TASKS.json status: a
# needs-human task the owner marked done in tracking/human-done.json (dashboard or mark-done.sh),
# or a "done" task the owner overturned as a false success in tracking/manual-fail.json
# (mark-failed.sh). Run at the top of every iteration so an owner action taken mid-run (from a
# separate process on this same checkout) takes effect promptly. The loop remains the SOLE writer
# of TASKS.json — the overlay files themselves are read-only inputs here, never written.
# overlay_apply <tasks-json> — PURE transform: echo TASKS.json with owner-overlay verdicts applied
# in-memory (human-done "done" for a needs-human task; manual-fail "failed" for any not-yet-failed
# task). NO writes, NO git. Shared by reconcile_overlays (which then persists) and the DRY_RUN preview
# (which must NOT persist). human-done promotes ONLY a needs-human task (the overlay is authored only for
# those; the gate guard stops a stray entry marking an ordinary task done unbuilt). manual-fail overturns
# ANY not-yet-failed task — task_failed() then keeps it terminal in select_task.
overlay_apply() {
  local tasks="$1" hd md
  [ -n "$tasks" ] || return 1
  hd="$(cat "$HUMAN_DONE" 2>/dev/null)"; [ -n "$hd" ] || hd='{}'
  md="$(cat "$MANUAL_FAIL" 2>/dev/null)"; [ -n "$md" ] || md='{}'
  jq -c --argjson hd "$hd" --argjson md "$md" '
    .tasks |= map(
      if (.status != "failed") and ($md[.id].failed == true) then .status = "failed"
      elif (.gate == "needs-human") and (.status != "done") and ($hd[.id].done == true) then .status = "done"
      else . end
    )' <<<"$tasks" 2>/dev/null
}

reconcile_overlays() {
  local tmp="$BACKLOG.tmp" new
  [ -f "$HUMAN_DONE" ] || echo '{}' >"$HUMAN_DONE"
  [ -f "$MANUAL_FAIL" ] || echo '{}' >"$MANUAL_FAIL"
  new="$(overlay_apply "$(cat "$BACKLOG" 2>/dev/null)")"
  [ -n "$new" ] || return 0
  [ "$new" = "$(jq -c '.' "$BACKLOG" 2>/dev/null)" ] && return 0
  printf '%s\n' "$new" | jq '.' >"$tmp" && mv "$tmp" "$BACKLOG" || { rm -f "$tmp"; return 0; }
  git -C "$ROOT" add "$BACKLOG" 2>/dev/null || true
  git -C "$ROOT" commit -q -m "reconcile: apply owner overlays [skip ci]" 2>/dev/null || true
  git -C "$ROOT" push origin "HEAD:$MAIN_BRANCH" 2>/dev/null || log "WARN: couldn't push overlay reconciliation"
  log "reconcile: applied owner overlays to TASKS.json"
}




# --- Difficulty auto-tuning: global tier ladder + the calibration policy --------------------------
# The loop rides ONE global difficulty ladder (facets.json .tiers.ladder, cheapest→priciest) offset
# by a policy-chosen START tier (cur_base). rung 0 = the policy's start tier; escalation walks UP the
# global ladder. Tasks carry NO per-task model/effort/escalation — `facets` drive the policy and the
# global ladder is the safety net; the cold-start prior is just the cheapest tier. See .harness/docs/HARNESS.md §6.
TIER_TUPLES=()   # portable (bash 3.2 — no mapfile): read the ladder into an array
while IFS= read -r _t; do TIER_TUPLES+=("$_t"); done \
  < <(jq -r '.tiers.ladder[] | "\(.model) \(.effort // "")"' "$FACETS" 2>/dev/null)
[ "${#TIER_TUPLES[@]}" -gt 0 ] || TIER_TUPLES=("$MODEL $EFFORT")     # fallback if facets.json absent
POLICY_FLOOR="$(jq -r '.policy.floor // 0.75' "$FACETS" 2>/dev/null || echo 0.75)"
POLICY_MINN="$(jq -r '.policy.minN // 6' "$FACETS" 2>/dev/null || echo 6)"
# Downward exploration (designs/difficulty-autotune.md): per-mille chance an eligible task probes one
# untested rung below the policy's normal pick. 0 (default) preserves today's behavior exactly.
POLICY_EXPLORE_PM="$(jq -r '.policy.exploreProbabilityPM // 0' "$FACETS" 2>/dev/null || echo 0)"
# Periodic recheck of a rejected exploration rung: rows of other cell activity that must land since
# that rung's last touch before it's offered again (batch-boundary judgment — see policy.jq header).
POLICY_EXPLORE_COOLDOWN_N="$(jq -r '.policy.exploreCooldownN // 20' "$FACETS" 2>/dev/null || echo 20)"
POLICY_JQ="$SCRIPT_DIR/policy.jq"                # .harness/scripts/policy.jq, alongside this loop
OUTCOME_ROW_JQ="$SCRIPT_DIR/outcome-row.jq"      # the shared ledger-row filter (C01) — see record_outcome()
# Verification-aware calibration knobs (the blocking audit gate — designs/audit-verification.md §4.6).
AUDIT_START_N="$(jq -r '.policy.auditStartN // 3' "$FACETS" 2>/dev/null || echo 3)"
AUDIT_FLOOR_N="$(jq -r '.policy.auditFloorN // 8' "$FACETS" 2>/dev/null || echo 8)"
AUDIT_FLOOR_PM="$(jq -r '((.policy.auditFloor // 0.10) * 1000) | round' "$FACETS" 2>/dev/null || echo 100)"
AUDITOR_MODEL="$(jq -r '.policy.auditorModel // "claude-opus-4-8"' "$FACETS" 2>/dev/null || echo claude-opus-4-8)"
AUDITOR_EFFORT="$(jq -r '.policy.auditorEffort // "medium"' "$FACETS" 2>/dev/null || echo medium)"
# Optional in-place "local DoD" gate the loop runs before the audit (the cheap CI-proxy). Empty =
# skip (CI still gates). Set in harness.env, e.g. LOCAL_DOD="<your format/lint/test/build commands>".
LOCAL_DOD="${LOCAL_DOD:-}"


# tier_strength lives in loop-lib.sh, sourced above.


# pick_base <id> — prints TWO space-separated tokens: the policy's chosen START tier INDEX
# (cheapest ladder tier whose (layer × work-type) cell historically clears the floor with >= minN
# samples; else the harness.env MODEL/EFFORT floor / cold-start prior), and whether this call rolled
# into a downward-exploration probe (1) or not (0) — the caller must capture BOTH via
# `read -r cur_base cur_explored <<<"$(pick_base "$id")"`, never `cur_base="$(pick_base "$id")"`
# alone (command substitution is a subshell; a variable set INSIDE this function cannot escape it,
# which is why the explored flag is returned on stdout instead). facets are the ONLY per-task
# difficulty signal — a stray hand-added per-task "model"/"effort" field is deliberately ignored,
# never an override. Robust: missing facets / empty ledger / any error → the prior.
pick_base() {
  local id="$1" layer wt cold tiers
  tiers="$(jq -c '.tiers.ladder' "$FACETS" 2>/dev/null)"
  cold="$(jq -n --argjson t "${tiers:-[]}" --arg m "$MODEL" --arg e "$EFFORT" '($t|map(.model==$m and .effort==($e|if .=="" then null else . end))|index(true)) // 1' 2>/dev/null)"; cold="${cold:-0}"
  layer="$(tj -r --arg id "$id" '.tasks[]|select(.id==$id)|.facets.layer // empty')"
  wt="$(tj -r --arg id "$id" '.tasks[]|select(.id==$id)|.facets.workType // empty')"
  if [ -z "$layer" ] || [ -z "$wt" ] || [ ! -s "$OUTCOMES" ] || [ -z "$tiers" ] || [ ! -f "$POLICY_JQ" ]; then printf '%s 0' "$cold"; return; fi
  local mf risk; mf="$(cat "$MANUAL_FAIL" 2>/dev/null || echo '{}')"
  risk="$(tj -c --arg id "$id" '.tasks[]|select(.id==$id)|.facets.risk // []')"; [ -n "$risk" ] || risk='[]'
  local chosen pm exploreIdx _erem   # _erem = policy.jq's 4th field (dashboard cooldown state) — unused here
  read -r chosen pm exploreIdx _erem <<<"$(jq -rn -f "$POLICY_JQ" --slurpfile rows "$OUTCOMES" --argjson tiers "$tiers" \
     --arg layer "$layer" --arg wt "$wt" --argjson floor "$POLICY_FLOOR" --argjson minN "$POLICY_MINN" \
     --argjson coldIdx "$cold" --argjson manualFail "$mf" --argjson risk "$risk" --argjson explorePM "$POLICY_EXPLORE_PM" --argjson exploreCooldownN "$POLICY_EXPLORE_COOLDOWN_N" \
     --argjson auditCount -1 --argjson auditStartN "$AUDIT_START_N" --argjson auditFloorN "$AUDIT_FLOOR_N" --argjson auditFloorPM "$AUDIT_FLOOR_PM" \
     2>/dev/null)"
  chosen="${chosen:-$cold}"; pm="${pm:-0}"; exploreIdx="${exploreIdx:--1}"
  if [ "$exploreIdx" -ge 0 ] && [ "$(rand_pm)" -lt "$pm" ]; then
    log "explore: $id cell (${layer:-?}×${wt:-?}) probing untested tier $exploreIdx (pm=${pm}) instead of calibrated tier $chosen"
    printf '%s 1' "$exploreIdx"; return
  fi
  printf '%s 0' "$chosen"
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
    # A forced id still must not bypass the SAME terminal-status skips the normal path applies below
    # (B03) — otherwise a forced-done task gets cold-rebuilt (the builder finds nothing to do → idle →
    # repeated idle flips a genuinely-finished task to blocked), and forcing a gated/failed/blocked id
    # builds something the loop is never supposed to touch on its own. Once this refuses, the caller's
    # empty-select exit is naturally one-shot: FORCE_TASK is never cleared, but the task's status on
    # $MAIN_BRANCH won't change again either, so a re-run of this same check keeps refusing it.
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
    echo "$FORCE_TASK"; return 0
  fi
  for t in $(all_tasks); do
    task_done "$t" && continue
    task_failed "$t" && continue      # owner overturned a false success — terminal, never rebuild
    task_gated "$t" && continue       # 🔒 needs-human — a human must act
    task_blocked "$t" && continue     # a prior attempt recorded failed:blocked
    ok=1; for d in $(deps_for "$t"); do task_done "$d" || { ok=0; break; }; done
    [ "$ok" = 1 ] && { echo "$t"; return 0; }
  done
  return 1
}

# --- GitHub CI gate (watches the workflow run for the current main HEAD) -----
# ci_find_run <branch-or-empty> <sha> — echo the databaseId of the CI run for <sha>, matching the
# workflow by NAME ($CI_WORKFLOW) first, then falling back to its FILE PATH. GitHub reports a run's
# workflowName as ".github/workflows/…" (the raw path) instead of the resolved `name:` when the workflow
# file itself can't be parsed — so a path-shaped workflowName is the signature of a MALFORMED workflow
# (a valid-YAML-but-invalid-schema CI file). Without this fallback the exact-name match finds nothing and
# the caller sits out the full CI_TIMEOUT then calls it "indeterminate". Sets CI_NAME_UNRESOLVED=1 when
# the fallback matched (caller warns + treats as red), else 0. (Shared with ci_status_now / the idle guard.)
CI_NAME_UNRESOLVED=0



# wait_ci_green lives in loop-lib.sh, sourced above (loop.in-place.sh always calls it with NO
# argument, so it gates the current HEAD directly).

# --- Claude invocation with rate-limit detection ----------------------------
# RL_RE/RL_HARD_RE/RL_BUFFER + rl_reset_wait/rl_cli_said/rl_detect/run_claude live in loop-lib.sh,
# sourced above (run_claude reads the WORK_DIR/PROMPT_DIR seam assigned near WORKLOG above).

# --- Per-task build prompt --------------------------------------------------
prompt() {
  local tid="$1"
  printf 'You are the autonomous builder for THIS repo. Build EXACTLY ONE task: %s, then stop.\n' "$tid"
  cat <<'EOF'
You work DIRECTLY on the `main` branch in the primary checkout — NO worktree, NO new branches.
Do NOT create/switch branches. Do NOT merge. **NEVER push** — no `git push`, no flags, not ever, even if
your global/personal git guidance says to always push after committing (that rule does NOT apply here). The
loop is the SOLE pusher: it runs your checks, pushes, and gates CI after you finish — a push from you is
BLOCKED by a git hook and bypasses that gate. `HARNESS_AGENT` is the loop's private env marker: never set,
unset, or pass it to any command. Your CI is LOCAL (step 2) — run it yourself; you never push to see CI.
You run head-less and unattended. Obey CLAUDE.md, .harness/tracking/TASKS.json, and .harness/docs/HARNESS.md exactly.

1. ORIENT. Read CLAUDE.md (conventions) and README.md (for product context), then find this task:
   `jq '.tasks[]|select(.id=="<TASK>")' .harness/tracking/TASKS.json` (read its scope/verify and orchestration
   fields; if its `design` field points to a .harness/docs/designs/… doc, READ and follow it). The task's
   `do` + `done-when` live in the Markdown spec at the JSON `spec` path (.harness/tasks/<TASK>.md,
   sections '## Do' / '## Done when') — its FULL TEXT is appended at the end of this prompt. You are
   starting COLD on a CLEAN tree: do NOT look for or rely on any prior-attempt state (worklog, partial
   work) — build this task FRESH from the spec alone. Stay within the task's `scope` — the exact
   allowed-files list + the HARD-GATE rule are shown under "SCOPE" at the end of this prompt.

2. DEFINITION OF DONE (.harness/docs/HARNESS.md §5 — all must hold before you report `done`):
   a. Run the project's full verification suite exactly as defined in CLAUDE.md /
      .harness/docs/HARNESS.md §5 (format, lint, tests, build). These MIRROR CI — run them locally
      first; every check must pass. Run every check to COMPLETION and read its real exit status: for a
      SLOW check (a multi-minute build/test), request an extended tool timeout or run it in the
      background and POLL to completion — never fire it under a default-timeout blocking call and assume
      it passed. A check that times out, is still running, or whose result you did not
      OBSERVE is NOT a pass — that is `failed:soft` (retryable), never `done`. If ANY check comes back
      RED, FIX IT and RE-RUN — re-run the suite as many times as you need; there is NO limit on how
      often you run it in one attempt. Report `done` ONLY after you have SEEN every check pass. Report
      `failed:soft` only when you genuinely cannot get it green this attempt (the fix is outside your
      `scope`, or needs a human or a resource you don't have) — not the moment a check first goes red.
   b. Run the task's integration / end-to-end checks when their preconditions are met. A check that
      needs credentials, funds, or external resources you don't have: never silently skip a required
      one and call it "passed" — record failed:blocked if the task's core needs it.
   c. If the task's `verify` field names extra EMPIRICAL checks, perform them and record what you
      OBSERVED in .harness/worklog/<TASK>.md.

3. SECRETS / PRIVACY — NON-NEGOTIABLE. Stage files EXPLICITLY by path; NEVER `git add -A` / `git add .`.
   NEVER `git add` anything under a `data/` folder, a `chrome-profile/`, a real `.env*`, or any
   credential file, and never edit .gitignore to un-ignore them. The loop's pre-push guard HALTS the
   whole run if any sensitive path is staged — so stage precisely.

4. DOCS ARE NOT YOUR JOB. Keeping project documentation current is the maintainers' responsibility, not
   the build loop's — do NOT go update docs to reflect your change. NEVER edit the repo-root README.md: it
   is maintainer-owned product documentation, NOT a status log, and touching it AUTO-FAILS this task. Do
   NOT edit .harness/tracking/TASKS.json either — the loop owns task status. The ONLY doc you write is your
   own .harness/worklog/<TASK>.md (always allowed; a dated entry: what you did, checks run, what remains).
   If the spec ITSELF names a doc file to change AND that file is inside your `scope`, change that one file;
   otherwise touch no docs.

5. COMMIT — produce EXACTLY ONE commit for the whole task, `<TASK>: <summary>` (do NOT push), staging your
   intended files explicitly. If you iterate — add a test, fix a failing check after running the DoD — fold
   it into that SAME commit with `git commit --amend`; NEVER stack a second commit. The loop integrates your
   one commit and, if CI is red, rolls it back with a single `git revert HEAD` — that clean rollback only
   works if the whole task is ONE commit. Your commit MUST include `.harness/worklog/<TASK>.md` — stage it
   alongside your code. A task is not complete if its worklog isn't committed.

6. As your FINAL action, OVERWRITE .harness/worklog/.result with exactly ONE line. Report `done` ONLY when
   every Definition-of-Done check has FINISHED and PASSED — never while a check is still running or its
   outcome is unknown (that is `failed:soft`):
     done <TASK>                     # built + committed (NOT pushed) — loop pushes + gates CI
     failed:soft <TASK> <reason>     # transient / partial — retry is worthwhile
     failed:blocked <TASK> <reason>  # needs-human / unmet prereq — do NOT retry
     waiting <TASK> <unmet-deps>     # a dependency is not done yet
     idle                            # nothing to do
EOF
  # SCOPE — HARD GATE + expectsTest blocks: shared with loop.sh via loop-lib.sh's
  # scope_gate_block/expects_test_block. The final "PLUS you may always…" line stays HERE (not in the
  # shared block) — it legitimately differs per variant (see scope_gate_block's own comment).
  scope_gate_block "$tid"
  printf '%s\n' 'PLUS you may always add/change TEST files and your own .harness/worklog/<TASK>.md. Touching ANY OTHER file — including a doc (README/CLAUDE/LIMITATIONS) not listed above — AUTO-FAILS this task. If you genuinely need a file that is not listed, do NOT edit it: record `failed:blocked <TASK> needs <file> (out of scope)` so a human can fix the scope.'
  expects_test_block "$tid"
  _custom_preamble build
  visual_verify_block "$tid"
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

# normalize_scope_prefix + scope_match live in the shared scope-lib.sh (sourced at the top of this
# script, next to repo-lock.sh) — the SINGLE implementation shared with loop.sh and check-task-scope.sh.
# It used to be duplicated verbatim in all three and drifted/re-broke; don't inline it here again
# (scope-match.test.sh fails if any of the three grows its own copy).


[ "${1:-}" = "--scope-exempt-selftest" ] && { scope_exempt_selftest "${2:-}" "${3:-}"; exit $?; }

[ "${1:-}" = "--scope-selftest" ] && { scope_selftest "${2:-}" "${3:-}"; exit $?; }

# rl_selftest lives in loop-lib.sh, sourced above.
[ "${1:-}" = "--rl-selftest" ] && { rl_selftest "${2:-}" "${3:-}" "${4:-}" "${5:-}"; exit $?; }

# structural_checks lives in loop-lib.sh, sourced above (reads the WORK_DIR/PROMPT_DIR/MAIN_BRANCH
# seam assigned near WORKLOG above).

# --struct-selftest <id> — runs the REAL structural_checks against whatever is ALREADY committed on
# $ROOT's current branch (the caller sets up the fixture: a task in TASKS.json on origin/$MAIN_BRANCH,
# a diverging local commit) and prints STRUCT_FAIL_KIND, or PASS if it returns 0. No claude subprocess,
# no gh/network — actionlint/LOCAL_DOD checks are naturally skipped unless the fixture's diff/env
# actually trigger them. Covers D01 (unauthorized [skip ci]) plus a baseline for the pre-existing
# empty-diff/scope-creep checks, which had no behavioral coverage before this — see
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

# audit_gate <id> — per-cell SAMPLED blocking audit (§4.3/4.6). Sets cur_verification. Spawns a fresh,
# independent auditor at max(opus-medium, builder tier) ONLY if sampled. 0 = pass (or not sampled),
# 1 = audit FAIL (a failed attempt).
audit_gate() {
  local id="$1" layer wt count pm bi ai am ae rel spec="" diff out verdict arc rlpoll rl_waited
  cur_verification="ci-only"
  layer="$(tj -r --arg id "$id" '.tasks[]|select(.id==$id)|.facets.layer // empty')"
  wt="$(tj -r --arg id "$id" '.tasks[]|select(.id==$id)|.facets.workType // empty')"
  local mf risk; mf="$(cat "$MANUAL_FAIL" 2>/dev/null || echo '{}')"
  risk="$(tj -c --arg id "$id" '.tasks[]|select(.id==$id)|.facets.risk // []')"; [ -n "$risk" ] || risk='[]'
  if [ -n "$layer" ] && [ -n "$wt" ] && [ -s "$OUTCOMES" ]; then
    count="$(jq -s --arg l "$layer" --arg w "$wt" --argjson mf "$mf" '[.[]|select(.facets!=null and .facets.layer==$l and .facets.workType==$w and .blocked==false and .verification=="audited" and ($mf[.id].failed!=true))]|length' "$OUTCOMES" 2>/dev/null || echo 0)"
  else count=0; fi
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
  # The auditor runs at its CONFIGURED tier (AUDITOR_MODEL/EFFORT — e.g. opus/medium, which need NOT
  # be a ladder rung), bumped UP to the builder's tier ONLY when the builder was stronger. Compared via
  # tier_strength so an off-ladder auditor tier is honoured exactly, not snapped to an arbitrary index.
  read -r bm be <<<"$(gtier $(( cur_base + cur_rung )))"   # the builder's tier
  if [ "$(tier_strength "$bm" "$be")" -gt "$(tier_strength "$AUDITOR_MODEL" "$AUDITOR_EFFORT")" ]; then
    am="$bm"; ae="$be"
  else
    am="$AUDITOR_MODEL"; ae="$AUDITOR_EFFORT"
  fi
  log "audit: $id cell (${layer:-?}×${wt:-?}) $count confirmed, p=${pm}per-mille → AUDITING at $am/$ae (auditor $AUDITOR_MODEL/$AUDITOR_EFFORT, bumped to builder tier if stronger)"
  diff="$(git -C "$ROOT" diff "origin/$MAIN_BRANCH..HEAD" 2>/dev/null)"
  rel="$(task_spec_rel "$id")"; [ -n "$rel" ] && [ -f "$ROOT/$rel" ] && spec="$(cat "$ROOT/$rel")"
  out="$WORKLOG/$id.audit.md"
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
      rlpoll="$(rl_reset_wait "$WORKLOG/.claude-out.audit" || true)"; rlpoll="${rlpoll:-$RL_POLL}"
      rl_banner "$rlpoll" "$WORKLOG/.claude-out.audit" "(this is the AUDIT step, not the build — NOT an audit fail; waited $(_hms "$rl_waited") so far)"
      sleep "$rlpoll"; rl_waited=$(( rl_waited + rlpoll )); continue
    fi
    break
  done
  cp "$WORKLOG/.claude-out.audit" "$out" 2>/dev/null || true
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
# rather than sleeping forever. Caller sets RL_MAX_WAIT/RL_POLL small and prepares a repo + WORKLOG
# with a real task id — see tests/loop-ratelimit.test.sh.
if [ "${1:-}" = "--audit-rl-cap-selftest" ]; then
  run_claude() {
    local phase="$4"
    printf 'Claude AI usage limit reached.\n' > "$WORKLOG/.claude-out.$phase"
    : > "$WORKLOG/.claude-out.$phase.jsonl"
    return 10
  }
  cur_explored=1; cur_base=0; cur_rung=0
  mkdir -p "$WORKLOG"
  audit_gate "${2:-T001}"
  exit $?
fi

# --- Dry run ----------------------------------------------------------------
if [ "${DRY_RUN:-0}" = "1" ]; then
  git -C "$ROOT" fetch origin --quiet 2>/dev/null || true
  # Match the real run's POST-reconcile view (an owner's human-done/manual-fail overlay takes effect on
  # the next real iteration) WITHOUT reconcile_overlays' write/commit/push — apply the overlays in
  # memory only, so a just-marked-done needs-human task's dependents show as eligible here too.
  DRY_TASKS="$(overlay_apply "$(cat "$BACKLOG" 2>/dev/null)" || true)"
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

# SAFETY: the in-place loop cold-resets the working tree (`git reset --hard origin/main`) between
# every attempt, which DISCARDS any uncommitted work in this checkout. So a dirty tree at startup is
# work the loop must NEVER touch: it HARD-STOPS here, loudly, and does nothing else — it does not
# stash, does not reset, does not build. Recovery is a deliberate HUMAN action (commit, stash, or
# discard, then re-run); the loop will not decide it for you, precisely so nothing depends on a human
# spotting a buried log line. (History: a `LOOP_AUTORESET=1` opt-in once stashed-and-proceeded here —
# removed, because a self-heal that silently relocates your work and then keeps building is exactly
# the "did something, hope someone noticed" failure mode this guard now forecloses. This also traces
# to a real incident: a forced task id + a destructive cold-reset once destroyed uncommitted work.)
if [ -n "$(git -C "$ROOT" status --porcelain 2>/dev/null)" ]; then
  log "══════════════════════════════════════════════════════════════════════"
  log "🛑 REFUSING TO RUN — the working tree at '$ROOT' has UNCOMMITTED changes."
  log "   The in-place loop cold-resets (git reset --hard origin/$MAIN_BRANCH) between attempts and"
  log "   would DESTROY this work. It will NOT stash, reset, or build while the tree is dirty."
  log "   → Commit, stash, or discard the changes below, then re-run. Nothing here was touched."
  log "══════════════════════════════════════════════════════════════════════"
  git -C "$ROOT" status --short >&2 2>/dev/null || true
  exit 3
fi

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

# Give up on ONE task WITHOUT halting the loop: discard any local unpushed work, record a
# failed:blocked marker in the task's worklog (so select_task skips it from now on), push that,
# and move on. A human reviews blocked tasks later; the loop keeps making progress on everything
# else — one bad task never costs hours of idle.
block_task() {
  local id="$1" reason="$2"
  git -C "$ROOT" reset --hard "origin/$MAIN_BRANCH" 2>/dev/null || true   # drop any local unpushed commit/changes
  mkdir -p "$WORKLOG"
  printf '\n---\nfailed:blocked %s — %s\n' "$id" "$reason" >>"$WORKLOG/$id.md"
  set_task_status "$id" blocked || log "WARN: failed to set status=blocked for $id"
  record_outcome "$id" true "$reason"               # blocked → ledger row (succeededRung=null, topRung=cur_rung)
  flush_failures
  # Split add (see mark_done): a combined add with an absent failures.jsonl aborts atomically and the
  # status=blocked marker would silently never persist. Stage always-present files, then FAILURES iff present.
  git -C "$ROOT" add "$BACKLOG" "$WORKLOG/$id.md" "$OUTCOMES" 2>/dev/null || true
  [ -f "$FAILURES" ] && git -C "$ROOT" add "$FAILURES" 2>/dev/null || true
  git -C "$ROOT" commit -q -m "$id: blocked, needs human — skipping [skip ci]" 2>/dev/null || true
  git -C "$ROOT" push origin "HEAD:$MAIN_BRANCH" 2>/dev/null || log "WARN: couldn't push block marker for $id"
  log "BLOCKED $id ($reason) — recorded for a human; moving on to the next task."
  run_hook blocked "$id" "$reason"
  heartbeat_clear; cur_task=""; cur_attempts=0; cur_rung=0; cur_base=0; cur_explored=0
}


log "starting — default model=$MODEL effort=$EFFORT, in-place on $MAIN_BRANCH, ci_gate=$REQUIRE_CI"
mkdir -p "$WORKLOG"
# Pre-flight (difficulty auto-tuning): warn about BUILDABLE tasks missing facets. Non-fatal — the
# policy degrades to the authored prior, but a facet-less task gets no tuning + adds nothing to
# calibration. needs-human/gated tasks are correctly excluded (carved out).
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
    heartbeat_clear; run_hook drained drained; board; exit 0
  fi
  task="$sel"
  if [ "$task" != "$cur_task" ]; then
    if [ -n "$resume_task" ] && [ "$task" = "$resume_task" ]; then
      # Resuming an interrupted mid-climb — restore scheduling metadata only (which tier to
      # cold-start the next attempt at). This does NOT resume a partial build diff: every attempt
      # still resets to a clean tree first, same as always.
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
  read -r tmodel teffort <<<"$(rung_at "$task" "$cur_rung")"
  log "iteration $i/$MAX_ITERS → $task (cold) on $tmodel/$teffort (rung $cur_rung)"

  RESULT="$WORKLOG/.result"; rm -f "$RESULT"

  # Run Claude COLD, polling + auto-resuming on usage/session limits (NOT counted as a failure). Every
  # (re)attempt resets to a CLEAN tree first, so it measures one cold pass of this tier (§4.1).
  rl_waited=0; rl_sleep="$RL_BACKOFF_MIN"
  while :; do
    cold_reset
    heartbeat building
    # `… || rc=$?` (NOT `; rc=$?`) — run_claude flips `set -e` back ON internally before it
    # `return`s, so a bare `; rc=$?` would let a nonzero return KILL loop.sh right here (before rc is
    # ever captured) instead of triggering the reset-aware backoff below. The `||` keeps the call in
    # an AND-OR list, which `set -e` never aborts on.
    rc=0; set +e; run_claude "$tmodel" "$teffort" "$(prompt "$task")" build || rc=$?; set -e
    if [ "$rc" = 10 ]; then
      # C01: the backoff decision (parsed-reset vs. exponential, banner, sleep, RL_MAX_WAIT give-up)
      # lives in loop-lib.sh's rl_build_wait — identical across both variants except which out-file
      # path they pass in.
      read -r rl_waited rl_sleep <<<"$(rl_build_wait "$rl_waited" "$rl_sleep" "$WORKLOG/.claude-out.build")"
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
      if ! guard_clean; then
        log "PRE-PUSH GUARD tripped on $task — sensitive path staged; discarding the commit + blocking."
        record_failure "$task" "guard-tripped"; block_task "$task" "pre-push guard tripped (sensitive path staged)"; board; continue
      fi
      # Cheap structural gate (in-place local DoD) THEN the blocking audit — both BEFORE the push, so
      # a failure never reaches the remote (designs/audit-verification.md §3). Either fail = a failed
      # attempt: discard the commit + soft-retry (cold), escalating per the existing ladder.
      if ! structural_checks "$task"; then
        record_failure "$task" "${STRUCT_FAIL_KIND:-structural}" "${STRUCT_FAIL_DETAIL:-}"
        if [ "${STRUCT_FAIL_KIND:-}" = scope-creep ]; then
          # See loop.sh: a scope-creep failure is a wrong/too-narrow `scope`, not a too-weak model, so
          # escalating up the ladder can't fix it (it just wastes the attempt budget + poisons the cell
          # calibration). Block after ONE attempt for a human to correct the scope. block_task discards
          # the local commit itself (reset --hard origin/main), so no cold_reset here.
          log "structural: $task touched files OUTSIDE its declared scope (${STRUCT_FAIL_DETAIL:-}) — blocking after one attempt (a wrong scope isn't fixed by a retry or a stronger model)."
          block_task "$task" "scope-creep: diff touched files outside declared scope (${STRUCT_FAIL_DETAIL:-}) — the task's scope is likely too narrow or wrong; fix the scope (or split the task), then re-open"
          board; continue
        fi
        log "structural checks failed for $task — discarding commit + soft retry."
        cold_reset; bump "$task"; board; continue
      fi
      heartbeat auditing
      if ! audit_gate "$task"; then
        log "AUDIT FAILED for $task — discarding the commit (never pushed) + soft retry."
        cold_reset; record_failure "$task" "${cur_audit_kind:-audit-fail}"; bump "$task"; board; continue
      fi
      # SINGLE-COMMIT INVARIANT — collapse the agent's commit(s) into exactly ONE before pushing, so a
      # red-CI revert stays a single `git revert HEAD` ("every task is one commit"). The prompt asks the
      # builder for one commit (amend to iterate), but a cheap model may stack several; the loop guarantees
      # it mechanically here. --no-verify: the tree already passed structural + audit — this is a pure
      # history collapse that must neither re-run hooks nor alter the tree.
      _sq_n="$(git -C "$ROOT" rev-list --count "origin/$MAIN_BRANCH..HEAD" 2>/dev/null || echo 0)"
      if [ "${_sq_n:-0}" -gt 1 ]; then
        _sq_subj="$(git -C "$ROOT" log --reverse --format='%s' "origin/$MAIN_BRANCH..HEAD" 2>/dev/null | head -1)"
        _sq_body="$(git -C "$ROOT" log --reverse --format='%B' "origin/$MAIN_BRANCH..HEAD" 2>/dev/null)"
        if git -C "$ROOT" reset --soft "origin/$MAIN_BRANCH" 2>/dev/null \
           && git -C "$ROOT" commit -q --no-verify -m "${_sq_subj:-$task: build}" -m "$_sq_body"; then
          log "squashed $_sq_n commits into one for $task (clean single-commit revert on red CI)"
        else
          log "WARN: squash failed for $task — pushing $_sq_n commits as-is; a red-CI revert may be partial."
        fi
      fi
      heartbeat integrating
      if ! throttled_push "$ROOT" origin "HEAD:$MAIN_BRANCH"; then
        log "push to $MAIN_BRANCH failed (remote moved / network) — soft retry."
        record_failure "$task" "push-race"; bump "$task"; board; continue
      fi
      # A [skip ci]-tagged build commit never creates a workflow run, so wait_ci_green would sit out
      # the whole CI_TIMEOUT, return indeterminate, and soft-retry forever. Short-circuit to done —
      # there is deliberately no CI to wait for (e.g. an operational / scope:[] task).
      if [ "$REQUIRE_CI" = "1" ] && git -C "$ROOT" log -1 --format=%s 2>/dev/null | grep -qF '[skip ci]'; then
        mark_done "$task"; run_integrate_hook; run_hook integrated "$task" "${cur_verification:-}"; log "integrated $task → $MAIN_BRANCH ([skip ci] build — no CI run expected)"; heartbeat_clear; cur_task=""; cur_attempts=0; cur_rung=0; cur_base=0; cur_explored=0
      elif [ "$REQUIRE_CI" = "1" ]; then
        heartbeat awaiting-ci
        ci_rc=0; wait_ci_green || ci_rc=$?
        if [ "$ci_rc" = 0 ]; then
          mark_done "$task"; run_integrate_hook; run_hook integrated "$task" "${cur_verification:-}"; log "integrated $task → $MAIN_BRANCH (CI green)"; heartbeat_clear; cur_task=""; cur_attempts=0; cur_rung=0; cur_base=0; cur_explored=0
        elif [ "$ci_rc" = 1 ]; then
          # CI genuinely RED. NEVER halt the whole loop on one red: revert the pushed commit to restore
          # main, then soft-retry. If it keeps failing, bump eventually BLOCKS it and the loop moves on.
          log "CI RED for $task — reverting the pushed commit to restore $MAIN_BRANCH, then retrying."
          if git -C "$ROOT" revert --no-edit HEAD 2>/dev/null && git -C "$ROOT" push origin "HEAD:$MAIN_BRANCH" 2>/dev/null; then
            log "reverted $task; $MAIN_BRANCH is clean again."
          else
            log "WARN: auto-revert/push failed — main may need a manual: git revert HEAD && git push"
          fi
          record_failure "$task" "ci-red" "CI checks failed on the pushed commit"; bump "$task"
        else
          # INDETERMINATE (cancelled / skipped / stale / neutral / no-run / timeout) — CI did NOT fail.
          # Do NOT revert good work: a concurrency-cancel by a newer push says nothing about whether
          # the code is broken. Leave the commit on $MAIN_BRANCH, do NOT mark done (unverified), and
          # soft-retry; a later cycle re-checks CI and reconciles.
          log "CI INDETERMINATE for $task — leaving commit on $MAIN_BRANCH (NOT reverting, NOT marking done); will reconcile on a later cycle."
          record_failure "$task" "ci-indeterminate" "CI produced no definitive result (cancelled/skipped/no-run)"; bump "$task"
        fi
      else
        mark_done "$task"; run_integrate_hook; run_hook integrated "$task" "${cur_verification:-}"; log "marked $task done (REQUIRE_CI=0; local DoD only)"; heartbeat_clear; cur_task=""; cur_attempts=0; cur_rung=0; cur_base=0; cur_explored=0
      fi
      ;;
    failed:soft)    log "agent soft-failed $rtask: ${extra:-}"; record_failure "$task" "agent-soft-fail" "${extra:-}"; bump "$task" ;;
    failed:blocked) log "agent reports blocker on $rtask: ${extra:-}"; record_failure "$task" "agent-blocked" "${extra:-}"; block_task "$task" "agent reported failed:blocked — ${extra:-}" ;;
    waiting)        log "waiting on deps for $rtask: ${extra:-}"; sleep "$WAIT_SECONDS" ;;
    idle)
      # A per-task "nothing to do" — NOT a drained backlog. The agent cold-read $MAIN_BRANCH and found
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
        # ACTUAL CI status for main HEAD (point-in-time, no wait) before flipping status=done.
        idle_sha="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || true)"
        idle_ci=2; if [ -n "$idle_sha" ]; then idle_ci=0; ci_status_now "" "$idle_sha" || idle_ci=$?; fi
        if [ "$idle_ci" = 1 ]; then
          log "idle on $task but CI for $MAIN_BRANCH HEAD ($idle_sha) is RED — refusing to mark done; BLOCKING for a human (a prior revert-on-red didn't happen, or the workflow file is broken)."
          block_task "$task" "idle-but-ci-red: work is on main but its CI is failing — needs a human (check the latest CI run / the .github/workflows file)"
          idle_task=""; idle_count=0
        else
          log "agent reports idle on $task — Done-when already met on $MAIN_BRANCH ($([ "$idle_ci" = 0 ] && echo 'CI green' || echo 'CI status unconfirmed — proceeding as before')); reconciling status=done and continuing."
          mark_done "$task"
          heartbeat_clear; cur_task=""; cur_attempts=0; cur_rung=0; cur_base=0; cur_explored=0
        fi
      fi
      ;;
    *)              log "unrecognized result '$status' — backing off"; sleep "$WAIT_SECONDS" ;;
  esac
  board
done

log "reached MAX_ITERS=$MAX_ITERS — stopping"; run_hook exhausted max-iters; board; exit 4
