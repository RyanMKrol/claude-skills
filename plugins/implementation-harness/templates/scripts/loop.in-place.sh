#!/usr/bin/env bash
# harness-loop-variant: in-place   # read by implementation-harness-upgrade to pick the right reference — do not remove
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
#         .harness/scripts/loop.sh --scope-exempt-selftest [globs path]  # verify SCOPE_EXEMPT_GLOBS matching, then exit
#         .harness/scripts/loop.sh --scope-selftest [entry file]  # verify scope-entry matching (extension globs), then exit
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

BACKLOG="$HARNESS_DIR/tracking/TASKS.json"
WORKLOG="$HARNESS_DIR/worklog"
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
LOOP_AUTORESET="${LOOP_AUTORESET:-0}"              # opt-in: self-heal (stash+reset) a dirty tree at startup instead of refusing — dedicated checkouts only
CLAUDE_BIN="${CLAUDE_BIN:-claude}"
CLAUDE_FLAGS="${CLAUDE_FLAGS:---dangerously-skip-permissions}"
# Rate-limit-aware handling: when Claude hits a usage/session limit, resume the SAME task. A PARSED
# reset time is honoured directly (+ RL_BUFFER cushion, capped at RL_BACKOFF_MAX); when nothing
# parses, the build path backs off exponentially (RL_BACKOFF_MIN doubling to RL_EXP_MAX) instead of
# hammering a fixed poll — the notice usually means the window is exhausted for a while.
RL_POLL="${RL_POLL:-900}"                          # audit-path fallback poll while limited
RL_MAX_WAIT="${RL_MAX_WAIT:-21600}"                # give up + exit for supervise after ~6h limited
RL_BACKOFF_MIN="${RL_BACKOFF_MIN:-300}"            # exponential-fallback FIRST sleep (unknown reset)
RL_EXP_MAX="${RL_EXP_MAX:-3600}"                   # exponential-fallback cap (unknown-reset path only)
RL_BACKOFF_MAX="${RL_BACKOFF_MAX:-18000}"          # cap for a PARSED reset wait (~5h — a known reset can be hours away)
FORCE_TASK=""; [ "${1:-}" != "--guard-selftest" ] && [ "${1:-}" != "--scope-exempt-selftest" ] && [ "${1:-}" != "--scope-selftest" ] && FORCE_TASK="${1:-}"
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
  reset_txt="$(grep -oiE 'resets[^.)]{0,60}\)?' "$outf" 2>/dev/null | tail -1)"
  resume="$(date -v+"${secs}"S '+%a %H:%M %Z' 2>/dev/null || date -d "+${secs} seconds" '+%a %H:%M %Z' 2>/dev/null || echo "in $(_hms "$secs")")"
  log "══════════════════════════════════════════════════════════════════════"
  log "🛑 Claude usage/session limit hit — NOT a failure; the loop will auto-resume."
  [ -n "$reset_txt" ] && log "   Claude says: ${reset_txt}"
  [ -n "$note" ] && log "   $note"
  log "   ⏳ Sleeping $(_hms "$secs")  →  resuming ~${resume}, then RE-ATTEMPT COLD."
  log "   ✅ SAFE TO Ctrl-C NOW — nothing is running."
  log "══════════════════════════════════════════════════════════════════════"
}

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

# --- Pre-push guard: refuse to push if anything sensitive is in the new commits ----
guard_clean() {
  local bad
  bad="$(git -C "$ROOT" diff --name-only "origin/$MAIN_BRANCH..HEAD" 2>/dev/null | grep -nE "$SENSITIVE_RE" | grep -vE "$GUARD_ALLOW_RE" || true)"
  [ -z "$bad" ] && return 0
  log "PRE-PUSH GUARD TRIPPED — refusing to push. Sensitive paths in pending commits:"
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

[ -f "$BACKLOG" ] || { log "no .harness/tracking/TASKS.json — nothing to build"; exit 3; }

# --- TASKS.json helpers (read from the local backlog file) ------------------
tj()           { jq "$@" "$BACKLOG" 2>/dev/null; }
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
      -c '.tasks[]|select(.id==$id)|{
        id:$id, ts:$ts, facets:(.facets // null), scopeSize:(.scope|length),
        startModel:$sm, startEffort:(if $se=="" then null else $se end),
        finalModel:$fm, finalEffort:(if $fe=="" then null else $fe end),
        succeededRung:(if $blocked then null else $rung end), topRung:$rung,
        attemptsAtRung:$atr, totalSoftFails:$total, blocked:$blocked, reason:$reason,
        verification:$verif
      }')"
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
heartbeat() {
  printf '{"task":"%s","phase":"%s","rung":%s,"attempt":%s,"base":%s,"model":"%s","effort":"%s","startedAt":"%s","updatedAt":"%s"}\n' \
    "${cur_task:-}" "$1" "${cur_rung:-0}" "${cur_attempts:-0}" "${cur_base:-0}" "${tmodel:-}" "${teffort:-}" "${hb_started:-}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$HEARTBEAT" 2>/dev/null || true
}
heartbeat_clear() { rm -f "$HEARTBEAT" 2>/dev/null || true; }
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
flush_failures() {
  [ -s "$FAILURES_BUF" ] || return 0
  cat "$FAILURES_BUF" >>"$FAILURES" 2>/dev/null || true
  : >"$FAILURES_BUF"
}

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
  git -C "$ROOT" push origin "HEAD:$MAIN_BRANCH" 2>/dev/null || log "WARN: couldn't push status update for $id"
}

# reconcile_overlays — promote owner-overlay verdicts into authoritative TASKS.json status: a
# needs-human task the owner marked done in tracking/human-done.json (dashboard or mark-done.sh),
# or a "done" task the owner overturned as a false success in tracking/manual-fail.json
# (mark-failed.sh). Run at the top of every iteration so an owner action taken mid-run (from a
# separate process on this same checkout) takes effect promptly. The loop remains the SOLE writer
# of TASKS.json — the overlay files themselves are read-only inputs here, never written.
reconcile_overlays() {
  local hd md tmp="$BACKLOG.tmp" new
  [ -f "$HUMAN_DONE" ] || echo '{}' >"$HUMAN_DONE"
  [ -f "$MANUAL_FAIL" ] || echo '{}' >"$MANUAL_FAIL"
  hd="$(cat "$HUMAN_DONE" 2>/dev/null || echo '{}')"
  md="$(cat "$MANUAL_FAIL" 2>/dev/null || echo '{}')"
  # human-done promotes ONLY a needs-human task (the overlay is authored only for those; the gate
  # guard stops a stray entry marking an ordinary task done without ever building it). manual-fail
  # overturns ANY not-yet-failed task (usually a "done" false success, but an owner may pre-fail a
  # task they know is wrong) — task_failed() then keeps it terminal in select_task.
  new="$(jq -c --argjson hd "$hd" --argjson md "$md" '
    .tasks |= map(
      if (.status != "failed") and ($md[.id].failed == true) then .status = "failed"
      elif (.gate == "needs-human") and (.status != "done") and ($hd[.id].done == true) then .status = "done"
      else . end
    )' "$BACKLOG" 2>/dev/null)"
  [ -n "$new" ] || return 0
  [ "$new" = "$(jq -c '.' "$BACKLOG" 2>/dev/null)" ] && return 0
  printf '%s\n' "$new" | jq '.' >"$tmp" && mv "$tmp" "$BACKLOG" || { rm -f "$tmp"; return 0; }
  git -C "$ROOT" add "$BACKLOG" 2>/dev/null || true
  git -C "$ROOT" commit -q -m "reconcile: apply owner overlays [skip ci]" 2>/dev/null || true
  git -C "$ROOT" push origin "HEAD:$MAIN_BRANCH" 2>/dev/null || log "WARN: couldn't push overlay reconciliation"
  log "reconcile: applied owner overlays to TASKS.json"
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
POLICY_EXPLORE_COOLDOWN_N="$(jq -r '.policy.exploreCooldownN // 40' "$FACETS" 2>/dev/null || echo 40)"
POLICY_JQ="$SCRIPT_DIR/policy.jq"                # .harness/scripts/policy.jq, alongside this loop
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

# tier_strength <model> <effort> — a total strength order over ANY (model, effort) pair, INDEPENDENT
# of the ladder (model dominates, then effort). Lets audit_gate compare the configured auditor tier
# (e.g. opus/medium) against the builder tier even when the auditor tuple isn't a ladder rung — the
# ladder-index approach would otherwise fall back to an arbitrary index and audit at the wrong tier.
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
  local chosen pm exploreIdx
  read -r chosen pm exploreIdx <<<"$(jq -rn -f "$POLICY_JQ" --slurpfile rows "$OUTCOMES" --argjson tiers "$tiers" \
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
  # `gh run watch --exit-status`'s bare exit CONFLATES a genuine CI failure with a watch hiccup and a
  # run that got CANCELLED by a newer push (concurrency cancel-in-progress). So watch to settle, then
  # read the run's ACTUAL conclusion and classify on THAT — only a real failure is RED. A
  # cancelled/skipped/stale/neutral result returns 2 (NOT red) so the caller never reverts good work
  # over a concurrency-cancel.
  gh run watch "$runid" --exit-status >/dev/null 2>&1 || true
  local latest concl
  latest="$(gh run list --limit 20 --json databaseId,headSha,workflowName \
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
      log "CI INDETERMINATE (run $runid, conclusion='${concl:-unknown}') — NOT treating as red (likely concurrency-cancelled/skipped, not a real failure)"; return 2 ;;
  esac
}

# --- Claude invocation with rate-limit detection ----------------------------
RL_RE='usage limit|session limit|hit your .*limit|limit.*reset|rate.?limit|429|resets? (at|in)|try again later|overloaded|quota|insufficient.*credit|exceeded your'
# Unambiguous "you have hit a usage/session limit" wording. Kept SEPARATE from (and tighter than) the
# broad RL_RE so it can classify a limit EVEN when the CLI exits 0 — which it frequently does, because
# the limit notice is a normal assistant message, not a process error. The tightness ensures ordinary
# task output is never misread as a limit on a genuinely successful run.
RL_HARD_RE='hit your (session|usage|account|weekly|5.?hour) limit|(session|usage|weekly|account) limit reached|reached your (usage|session|weekly) limit'
RL_BUFFER="${RL_BUFFER:-300}"   # seconds of slack added on top of a parsed reset time

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
  line="$(grep -oiE 'resets?[^.]{0,40}' "$out" 2>/dev/null | tail -1)"
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
    # Clock time — with OPTIONAL minutes and an OPTIONAL timezone, matching the real CLI wording:
    # "resets 3am (Europe/London)", "resets 2:30pm (Europe/London)", "resets 9:25 pm". Anchored on
    # am/pm. If a (TZ) is stated, compute the next occurrence of that time IN that zone; otherwise
    # local time. (The old regex required a colon+minutes and ignored the zone, so "3am (Europe/London)"
    # fell through to the coarse poll and a zoned clock was read in the runner's local tz.)
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

# run_claude <model> <effort> <prompt> <phase: build|audit> → 0 ok | 10 rate-limited | other = failure
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
  local raw="$WORKLOG/.claude-out.${phase}.jsonl"   # raw stream events — dashboard's live tail
  local out="$WORKLOG/.claude-out.${phase}"          # reassembled plain text — unchanged meaning
  local rc
  local -a eff=(); [ -n "$effort" ] && eff=(--effort "$effort")   # some models (e.g. Haiku) have no effort param — omit the flag entirely
  set +e
  ( cd "$ROOT" && "$CLAUDE_BIN" -p "$pr" --model "$model" "${eff[@]}" \
      --output-format stream-json --include-partial-messages --verbose "${FLAGS[@]}" ) 2>&1 \
    | tee "$raw" \
    | jq -Rrj 'fromjson? | select(.type=="stream_event" and .event.delta.type? == "text_delta") | .event.delta.text' \
    > "$out"
  rc=${PIPESTATUS[0]}
  set -e
  # Limit detection: RL_HARD_RE signals a limit regardless of exit code (the CLI often prints the
  # notice yet still exits 0); RL_RE (broader) only counts when the command ALSO failed. Either way
  # return 10 so the caller runs the reset-aware backoff — the loop never exits on a usage limit.
  if grep -qiE "$RL_HARD_RE" "$out"; then return 10; fi
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
You run head-less and unattended. Obey CLAUDE.md, .harness/tracking/TASKS.json, and .harness/docs/HARNESS.md exactly.

1. ORIENT. Read CLAUDE.md (conventions) and README.md (the current implemented state), then find this task:
   `jq '.tasks[]|select(.id=="<TASK>")' .harness/tracking/TASKS.json` (read its scope/verify and orchestration
   fields; if its `design` field points to a .harness/docs/designs/… doc, READ and follow it). The task's
   `do` + `done-when` live in the Markdown spec at the JSON `spec` path (.harness/tasks/<TASK>.md,
   sections '## Do' / '## Done when') — its FULL TEXT is appended at the end of this prompt. You are
   starting COLD on a CLEAN tree: do NOT look for or rely on any prior-attempt state (worklog, partial
   work) — build this task FRESH from the spec alone. Stay within the task's `scope` — the exact
   allowed-files list + the HARD-GATE rule are shown under "SCOPE" at the end of this prompt.

2. DEFINITION OF DONE (.harness/docs/HARNESS.md §6 — all must hold before you report `done`):
   a. Run the project's full verification suite exactly as defined in CLAUDE.md / .harness/docs/HARNESS.md §6
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

4. DOCS IN LOCKSTEP (same commit) — but ONLY docs that are in your SCOPE. If a convention/feature
   change needs README.md / CLAUDE.md / .harness/docs/LIMITATIONS.md AND that file is in your scope, update it; if a
   needed doc is NOT in scope, do NOT edit it (it trips the scope gate) — record `failed:blocked` noting the
   missing doc. Do NOT edit .harness/tracking/TASKS.json — the loop owns task status. Write your notes to
   .harness/worklog/<TASK>.md (always allowed; a dated entry: what you did, checks run, what remains).

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
  # Inject the task's `scope` as an explicit HARD boundary. structural_checks fails the build if the
  # diff touches anything outside it (except test files + the worklog), so the builder must know it.
  local sc
  sc="$(tj -r --arg id "$tid" '.tasks[]|select(.id==$id)|.scope[]?' 2>/dev/null)"
  printf '\n--- SCOPE — HARD GATE (a script checks your diff against this; staying inside it is mandatory) ---\n'
  printf 'You may change ONLY these files:\n'
  if [ -n "$sc" ]; then printf '%s\n' "$sc" | sed 's/^/  - /'; else printf '  (none declared — keep the diff minimal)\n'; fi
  printf '%s\n' 'PLUS you may always add/change TEST files and your own .harness/worklog/<TASK>.md. Touching ANY OTHER file — including a doc (README/CLAUDE/LIMITATIONS) not listed above — AUTO-FAILS this task. If you genuinely need a file that is not listed, do NOT edit it: record `failed:blocked <TASK> needs <file> (out of scope)` so a human can fix the scope.'
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

# normalize_scope_prefix <raw> — strip a trailing `/`, `/**`, or `/*` so a directory-style glob
# becomes a bare prefix. Shared by `scope` entries (structural_checks) and SCOPE_EXEMPT_GLOBS
# (in_scope_exempt) — keep both on this ONE implementation; they drifted apart once already.
normalize_scope_prefix() {
  local s="$1"
  s="${s%/}"; s="${s%/\*\*}"; s="${s%/\*}"
  printf '%s' "$s"
}

# scope_match <file> <scope-entry> — true if <file> is within <scope-entry>. THE single scope-matching
# implementation, shared by `scope` (structural_checks) and SCOPE_EXEMPT_GLOBS (in_scope_exempt), and
# mirrored verbatim in loop.sh + check-task-scope.sh — keep all four identical. Supports:
#   • an exact path                          (src/auth/session.ts)
#   • a directory prefix, recursive          (dir/  dir/**  dir/*  → everything under dir)
#   • a single-level extension glob          (dir/*.tsx → any *.tsx DIRECTLY in dir, not nested)
# A double-quoted ${f#"$s"/} treats `*` as a literal, so an extension glob like dir/*.tsx used to match
# NOTHING (permanent scope-creep). The single-level case below matches with an UNQUOTED case pattern —
# which does expand `*`/`?`/`[…]` — engaged ONLY when a metacharacter survives normalization, so every
# entry that worked before (no residual metachar) still takes the identical exact/prefix path.
scope_match() {
  local f="$1" s d1 d2
  s="$(normalize_scope_prefix "$2")"
  case "$s" in
    *[*?[]*)
      # residual glob metacharacter → single-level glob: case-glob match, then require equal directory
      # depth so `*` can't span a `/` (an unquoted case `*` otherwise matches across directories).
      case "$f" in
        $s)
          d1="${f//[!\/]/}"; d2="${s//[!\/]/}"
          [ "${#d1}" -eq "${#d2}" ] && return 0
          ;;
      esac
      return 1
      ;;
    *)
      [ "$f" = "$s" ] && return 0
      [ "${f#"$s"/}" != "$f" ] && return 0
      return 1
      ;;
  esac
}

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

# structural_checks <id> — cheap, model-agnostic gate on the build commit, BEFORE the audit. Any
# fail = a failed attempt. 0 = pass, 1 = fail.
structural_checks() {
  local id="$1" changed want_test scope creep f s inscope
  STRUCT_FAIL_KIND=""; STRUCT_FAIL_DETAIL=""   # set on each fail path so the ledger records WHICH check failed
  changed="$(git -C "$ROOT" diff --name-only "origin/$MAIN_BRANCH..HEAD" 2>/dev/null)"
  if [ -z "$changed" ]; then STRUCT_FAIL_KIND="empty-diff"; log "structural: $id produced an EMPTY diff — fail"; return 1; fi
  # Scope-creep gate: every changed file must be WITHIN the task's declared `scope` (exact path or
  # under a scope directory) — except the always-allowed worklog + test files (and any
  # SCOPE_EXEMPT_GLOBS). The strong planner's `scope` is a binding contract; any other file the
  # cheap builder touched is a failed attempt.
  scope="$(tj -r --arg id "$id" '.tasks[]|select(.id==$id)|.scope[]?' 2>/dev/null)"
  creep=""
  while IFS= read -r f; do
    [ -z "$f" ] && continue
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
    # Capture output so a LOCAL_DOD failure gives a "why" (the last lines go into the failure ledger
    # detail + the log), instead of the silent >/dev/null that left no diagnostic trail.
    local dodlog="$WORKLOG/.local-dod.log"
    if ! ( cd "$ROOT" && eval "$LOCAL_DOD" ) >"$dodlog" 2>&1; then
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

--- IMPLEMENTATION DIFF (origin/$MAIN_BRANCH..HEAD) ---
$diff
EOF
  visual_verify_block "$id" audit
  _custom_preamble audit
}

# audit_gate <id> — per-cell SAMPLED blocking audit (§4.3/4.6). Sets cur_verification. Spawns a fresh,
# independent auditor at max(opus-medium, builder tier) ONLY if sampled. 0 = pass (or not sampled),
# 1 = audit FAIL (a failed attempt).
audit_gate() {
  local id="$1" layer wt count pm bi ai am ae rel spec="" diff out verdict arc rlpoll
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
  while :; do
    # `… || arc=$?` (NOT `; arc=$?`) — run_claude flips `set -e` back ON internally before it
    # `return`s, so a bare `; arc=$?` would let a nonzero return KILL loop.sh right here (before arc
    # is ever captured) instead of triggering the auditor rate-limit backoff below. The `||` keeps
    # the call in an AND-OR list, which `set -e` never aborts on.
    arc=0; set +e; run_claude "$am" "$ae" "$(audit_prompt "$id" "$spec" "$diff")" audit || arc=$?; set -e
    if [ "$arc" = 10 ]; then
      rlpoll="$(rl_reset_wait "$WORKLOG/.claude-out.audit" || true)"; rlpoll="${rlpoll:-$RL_POLL}"
      rl_banner "$rlpoll" "$WORKLOG/.claude-out.audit" "(this is the AUDIT step, not the build — NOT an audit fail)"
      sleep "$rlpoll"; continue
    fi
    break
  done
  cp "$WORKLOG/.claude-out.audit" "$out" 2>/dev/null || true
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
# startup, that's external work the loop must NOT destroy — refuse to run (commit/stash first),
# UNLESS LOOP_AUTORESET=1 (opt-in, default off): appropriate ONLY for a checkout dedicated solely
# to this loop, where a dirty tree at startup is virtually always orphaned partial work from an
# interrupted prior run, not a human's in-progress edits. Default-off preserves the safe behavior
# for anyone who hasn't deliberately opted in; this guard exists because of a real incident (a
# forced task id + a destructive cold_reset once destroyed real uncommitted work).
if [ -n "$(git -C "$ROOT" status --porcelain 2>/dev/null)" ]; then
  if [ "${LOOP_AUTORESET:-0}" = "1" ]; then
    stash_ref="loop-autoreset-$(date -u +%Y%m%dT%H%M%SZ)"
    log "LOOP_AUTORESET=1: '$ROOT' is dirty — stashing as '$stash_ref' (recoverable via git stash) and self-healing."
    git -C "$ROOT" stash push -u -m "$stash_ref" >/dev/null 2>&1 || true
  else
    log "REFUSING TO RUN: '$ROOT' has uncommitted changes. The in-place loop cold-resets (git reset --hard) and would discard them. Commit or stash first, or set LOOP_AUTORESET=1 if this checkout is dedicated solely to the loop."
    exit 3
  fi
fi

cur_task=""; cur_attempts=0; cur_rung=0; cur_base=0; cur_explored=0; cur_verification="ci-only"; hb_started=""

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
    log "no eligible task — backlog complete or everything left is gate/human-blocked."
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
      if [ "$rl_waited" -ge "$RL_MAX_WAIT" ]; then
        log "still usage/session-limited after ${rl_waited}s (cap ${RL_MAX_WAIT}s) — exiting for supervise to relaunch later."
        run_hook exhausted rate-limit; board; exit 5
      fi
      rlwait="$(rl_reset_wait "$WORKLOG/.claude-out.build" || true)"
      if [ -n "$rlwait" ]; then
        rl_banner "$rlwait" "$WORKLOG/.claude-out.build" "(that's the reported reset + a $(_hms "$RL_BUFFER") cushion; waited $(_hms "$rl_waited") so far)"
      else
        rlwait="$rl_sleep"
        rl_banner "$rlwait" "$WORKLOG/.claude-out.build" "No reset time in the notice — exponential backoff (cap $(_hms "$RL_EXP_MAX"); waited $(_hms "$rl_waited") so far)."
        rl_sleep=$(( rl_sleep * 2 )); [ "$rl_sleep" -gt "$RL_EXP_MAX" ] && rl_sleep="$RL_EXP_MAX"
      fi
      heartbeat rate-limited
      sleep "$rlwait"; rl_waited=$(( rl_waited + rlwait )); continue
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
        log "structural checks failed for $task — discarding commit + soft retry."
        cold_reset; record_failure "$task" "${STRUCT_FAIL_KIND:-structural}" "${STRUCT_FAIL_DETAIL:-}"; bump "$task"; board; continue
      fi
      heartbeat auditing
      if ! audit_gate "$task"; then
        log "AUDIT FAILED for $task — discarding the commit (never pushed) + soft retry."
        cold_reset; record_failure "$task" "audit-fail"; bump "$task"; board; continue
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
    idle)           log "agent reports idle — nothing to do"; run_hook drained idle; board; exit 0 ;;
    *)              log "unrecognized result '$status' — backing off"; sleep "$WAIT_SECONDS" ;;
  esac
  board
done

log "reached MAX_ITERS=$MAX_ITERS — stopping"; run_hook exhausted max-iters; board; exit 4
