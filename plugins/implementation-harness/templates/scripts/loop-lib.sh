#!/usr/bin/env bash
#
# loop-lib.sh — shared logic sourced by BOTH loop.sh (worktree) and loop.in-place.sh (in-place). Used
# to be hand-copy-pasted into each variant and pinned byte-identical by tests/loop-parity.test.sh; that
# hand-mirroring is exactly where recent regressions lived (usage-limit detection 1.69.0, idle handling
# 1.65.0, the B08 CI-recheck parity gap) — same drift class scope-lib.sh/repo-lock.sh were extracted to
# fix. Being extracted in STAGES (see proposals/C01, or git history once the proposal file is gone):
# stage 1 = the rate-limit (RL_*) family; stage 2 = Claude invocation (run_claude), covered so far.
#
# NO top-level execution beyond the RL_* knob defaults below (plain `"${VAR:-default}"` — safe to
# source at any point AFTER the caller has sourced its own harness.env, so an env override still wins).
# Every function here reads only its own args, these knobs, or the SEAM variables documented at each
# use site (WORK_DIR, PROMPT_DIR — set by the caller BEFORE this is sourced would be nice, but since a
# function body is just text until CALLED, it's enough that the caller sets them before the main loop
# actually invokes run_claude; see loop.sh/loop.in-place.sh's own comments at their assignment). Targets
# bash 3.2.

# --- Rate-limit knobs (env override > harness.env > these defaults; see rl_reset_wait/rl_detect) -----
# Usage/session-limit handling: poll + resume the SAME task rather than exit (5.x / R rung retries), so
# the run resumes shortly after the quota resets instead of waiting out supervise's full cadence. A
# PARSED reset time is honoured directly (+ RL_BUFFER cushion, capped at RL_BACKOFF_MAX); when nothing
# parses, the build path backs off exponentially (RL_BACKOFF_MIN doubling to RL_EXP_MAX) instead of
# hammering a fixed poll — the notice usually means the window is exhausted for a while.
RL_POLL="${RL_POLL:-900}"                         # audit-path fallback poll while limited
RL_MAX_WAIT="${RL_MAX_WAIT:-21600}"               # give up + exit for supervise after ~6h limited
RL_BACKOFF_MIN="${RL_BACKOFF_MIN:-300}"           # exponential-fallback FIRST sleep (unknown reset)
RL_EXP_MAX="${RL_EXP_MAX:-3600}"                  # exponential-fallback cap (unknown-reset path only)
RL_BACKOFF_MAX="${RL_BACKOFF_MAX:-18000}"         # cap for a PARSED reset wait (~5h — a known reset can be hours away)
RL_BUFFER="${RL_BUFFER:-300}"  # seconds of slack added on top of a parsed reset time (5-min cushion — waking a hair early re-hits the same limit)
RL_RE='usage limit|session limit|hit your .*limit|limit.*reset|rate.?limit|429|resets? (at|in)|try again later|overloaded|quota|insufficient.*credit|exceeded your'
# Unambiguous "you have hit a usage/session limit" wording. Kept SEPARATE from (and tighter than) the
# broad RL_RE so it can classify a limit EVEN when the CLI exits 0 — which it frequently does, because
# the limit notice is a normal assistant message, not a process error. The tightness ensures ordinary
# task output is never misread as a limit on a genuinely successful run.
RL_HARD_RE='hit your (session|usage|account|weekly|5.?hour) limit|(session|usage|weekly|account) limit reached|reached your (usage|session|weekly) limit'

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
  # `|| true`: under set -o pipefail, a NO-MATCH grep (no "resets…" wording in the notice — a
  # perfectly normal genuine limit message) reports the pipeline as failed even though `tail -1`
  # itself succeeded — a bare assignment like this (not part of an if/&&/||) would then trip
  # set -e and kill the WHOLE SCRIPT right here (discovered via the B07 audit-cap selftest).
  reset_txt="$(grep -hoiE 'resets[^.)]{0,60}\)?' "$outf" "${outf}.jsonl" 2>/dev/null | tail -1 || true)"   # raw sibling too — the notice isn't a text_delta, so it's only in the .jsonl
  resume="$(date -v+"${secs}"S '+%a %H:%M %Z' 2>/dev/null || date -d "+${secs} seconds" '+%a %H:%M %Z' 2>/dev/null || echo "in $(_hms "$secs")")"
  log "══════════════════════════════════════════════════════════════════════"
  log "🛑 Claude usage/session limit hit — NOT a failure; the loop will auto-resume."
  [ -n "$reset_txt" ] && log "   Claude says: ${reset_txt}"
  [ -n "$note" ] && log "   $note"
  log "   ⏳ Sleeping $(_hms "$secs")  →  resuming ~${resume}, then RE-ATTEMPT COLD."
  log "   ✅ SAFE TO Ctrl-C NOW — nothing is running."
  log "══════════════════════════════════════════════════════════════════════"
}

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

# rl_cli_said <raw> → stdout: raw lines minus type:"user"/tool_result events (keeps non-JSON stderr).
# rl_detect trusts RL_HARD_RE against the raw stream too (since the 1.34.0 stream-json switch, a
# usage-limit notice is not a text_delta so it never lands in the reassembled $out) — but ONLY over
# CLI-origin lines: $raw carries the CONTENTS of files the agent READ, and a repo whose own code
# contains the literal "usage limit reached" (e.g. its own rate-limit detector) would otherwise trip
# RL_HARD_RE on a genuinely SUCCESSFUL build.
rl_cli_said() {
  jq -Rr '. as $l | (fromjson? // null) as $o
          | if ($o|type=="object") and ($o.type=="user") then empty else $l end' "$1" 2>/dev/null
}

# rl_detect <out> <raw> <rc> — 0 iff the CLI hit a usage/session limit. Scans BOTH the reassembled text
# ($out) AND the raw stream ($raw) — see rl_cli_said for why $raw matters. RL_RE (the broad net) stays
# $out-only for the tool_result reason above.
rl_detect() {
  local out="$1" raw="$2" rc="$3"
  rl_cli_said "$raw" | grep -qiE "$RL_HARD_RE" && return 0   # hard wording, CLI-origin only (not read files)
  grep -qiE "$RL_HARD_RE" "$out" 2>/dev/null && return 0     # $out is text_delta-only, already safe
  [ "$rc" -ne 0 ] && grep -qiE "$RL_RE" "$out" 2>/dev/null && return 0
  return 1
}

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

# rl_build_wait <rl_waited> <rl_sleep> <out-file> — the BUILD path's usage-limit backoff decision,
# called when a build-phase run_claude returned 10 (rate-limited). A parsed reset time (rl_reset_wait)
# is honoured directly; otherwise falls back to exponential backoff (rl_sleep, doubling to RL_EXP_MAX).
# Sleeps, then echoes "NEW_RL_WAITED NEW_RL_SLEEP" on stdout — callers MUST capture both via
# `read -r rl_waited rl_sleep <<<"$(rl_build_wait "$rl_waited" "$rl_sleep" "$out")"` (a command
# substitution is a subshell, so a plain local reassignment inside this function can't otherwise
# propagate back to the caller — same reasoning as pick_base's explore-flag return). Gives up for
# good — calling `run_hook exhausted rate-limit; board; exit 5` directly and never returning — once
# RL_MAX_WAIT is exceeded, so callers don't need to special-case that themselves. Requires `log`,
# `run_hook`, `board`, and `heartbeat` to already be defined by the caller (they differ per variant,
# so stay out of this lib) — safe because bash resolves a function call at CALL time, not at this
# function's definition time, and this only ever runs deep into the main loop.
rl_build_wait() {
  local rl_waited="$1" rl_sleep="$2" out="$3" rlwait
  if [ "$rl_waited" -ge "$RL_MAX_WAIT" ]; then
    log "still usage/session-limited after ${rl_waited}s (cap ${RL_MAX_WAIT}s) — exiting for supervise to relaunch later."
    run_hook exhausted rate-limit; board; exit 5
  fi
  rlwait="$(rl_reset_wait "$out" || true)"
  if [ -n "$rlwait" ]; then
    rl_banner "$rlwait" "$out" "(that's the reported reset + a $(_hms "$RL_BUFFER") cushion; waited $(_hms "$rl_waited") so far)"
  else
    rlwait="$rl_sleep"
    rl_banner "$rlwait" "$out" "No reset time in the notice — exponential backoff (cap $(_hms "$RL_EXP_MAX"); waited $(_hms "$rl_waited") so far)."
    rl_sleep=$(( rl_sleep * 2 )); [ "$rl_sleep" -gt "$RL_EXP_MAX" ] && rl_sleep="$RL_EXP_MAX"
  fi
  heartbeat rate-limited
  sleep "$rlwait"
  printf '%s %s' "$(( rl_waited + rlwait ))" "$rl_sleep"
}

# run_claude <model> <effort> <prompt> <phase: build|audit> → 0 ok | 10 rate/usage-limited | other = failure
#
# Invokes claude in --output-format stream-json mode (--verbose is MANDATORY for stream-json in
# --print mode — the CLI refuses to start without it) so output arrives incrementally instead of one
# buffered dump at process exit (plain -p mode never streams to a pipe — confirmed empirically: a
# 500-word response sat at a flat byte count for the entire generation, then landed in a single write
# right as the process exited). The raw event stream goes to `.claude-out.<phase>.jsonl` (what the
# dashboard tails live, per phase); `.claude-out.<phase>` itself is reconstructed via jq into PLAIN
# TEXT and keeps its role from before phase-separation — every existing consumer (RL_HARD_RE/RL_RE,
# rl_reset_wait's reset-time parsing, the audit's PASS/FAIL grep, the worklog .audit.md copy) just
# needed its path updated to the phase-specific file, not its logic. `raw`/`out` are always under the
# PRIMARY checkout's worklog (`$HARNESS_DIR/worklog` — identical in both variants; B04) so a
# transcript survives a worktree teardown seconds later.
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
#
# SEAM (C01): reads $WORK_DIR (where the claude subprocess cd's to — the isolated worktree for
# loop.sh, the primary checkout for loop.in-place.sh) and $PROMPT_DIR (where the FULL per-phase
# prompt file is written — same split: lost on worktree teardown for loop.sh, durable for
# loop.in-place.sh) — both assigned by the caller before this is ever CALLED (see their own comments
# at the assignment site). Also reads $HARNESS_DIR, $CLAUDE_BIN, $FLAGS, $ROOT, $cur_task,
# $cur_rung, $cur_attempts, $PRINT_PROMPT — all identically named/computed in both variants.
run_claude() {
  local model="$1" effort="$2" pr="$3" phase="$4"
  local raw="$HARNESS_DIR/worklog/.claude-out.${phase}.jsonl"   # raw stream events — dashboard's live tail
  local out="$HARNESS_DIR/worklog/.claude-out.${phase}"          # reassembled plain text — unchanged meaning
  local rc
  local -a eff=(); [ -n "$effort" ] && eff=(--effort "$effort")   # some models (e.g. Haiku) have no effort param — omit the flag entirely
  # The FULL prompt handed to Claude (build or audit) goes to a PER-PHASE FILE under worklog/, NOT the
  # console: the prompts are huge and used to bury the cycle boundaries in the terminal, making it hard to
  # see where each iteration starts/ends. The console now gets only a concise boundary banner (which
  # task/phase/tier is starting + where to read the prompt). The prompt file is gitignored scratch (like
  # .claude-out.*), viewable any time. Neither write ever touches claude's stdin/stdout pipeline below.
  local _ph _meta _bar='================================================================================'
  _ph="$(printf '%s' "$phase" | tr '[:lower:]' '[:upper:]')"
  # Build banners show the escalation position (rung/attempt — WHY this tier); the audit runs at the fixed
  # AUDITOR tier, not a ladder rung, so rung/attempt is meaningless there and omitted.
  _meta="($model${effort:+ / $effort})"
  [ "$phase" = build ] && _meta="$_meta  ·  rung ${cur_rung:-0} · attempt $(( ${cur_attempts:-0} + 1 ))"
  local _pfile="$PROMPT_DIR/.claude-prompt.${phase}"
  { printf '%s\n=====  %s PROMPT  —  task %s  %s\n%s\n%s\n' \
      "$_bar" "$_ph" "${cur_task:-?}" "$_meta" "$_bar" "$pr"; } > "$_pfile" 2>/dev/null || true
  # CONCISE cycle-boundary banner → console (PRINT_PROMPT=0 silences it). No prompt body; points at the file.
  if [ "${PRINT_PROMPT:-1}" = 1 ]; then
    { printf '\n%s\n=====  %s  —  task %s  %s\n=====  full prompt → %s\n%s\n\n' \
        "$_bar" "$_ph" "${cur_task:-?}" "$_meta" "$_pfile" "$_bar"; } >&2
  fi
  set +e
  # `${arr[@]+"${arr[@]}"}` (guard, NOT a bare "${arr[@]}") — on bash < 4.4 (macOS ships 3.2) expanding a
  # declared-but-EMPTY array under `set -u` throws `unbound variable` and crashes run_claude BEFORE claude
  # runs. That's exactly the effort-less cold-start floor (Haiku), so a fresh install crash-loops on task 1.
  # PUSH BLOCK (both variants) — the builder/auditor must NOT push (worktree: its tNNN branch; in-place:
  # main directly) — the LOOP is the sole pusher (P5), so the deterministic local gate (structural_checks /
  # LOCAL_DOD) runs BEFORE anything reaches origin/CI. We scope git's pre-push hook to THIS agent
  # subprocess via GIT_CONFIG_* env — NOT a persistent `core.hooksPath`, which would disable the repo's own
  # husky/pre-commit hooks for the loop and humans too. HARNESS_AGENT=1 is what .harness/scripts/pre-push
  # checks; the loop's own pushes and human pushes never carry it, so they're never blocked. The hooks dir
  # is the PRIMARY checkout's `.harness/scripts` (for loop.sh, the worktree shares $ROOT's .git;
  # core.hooksPath is an absolute path, not a worktree-relative ref, so it resolves correctly). chmod keeps
  # the hook executable even if an install/copy dropped the bit (git silently ignores a non-executable hook
  # = no enforcement).
  chmod +x "$ROOT/.harness/scripts/pre-push" 2>/dev/null || true
  ( cd "$WORK_DIR" \
      && HARNESS_AGENT=1 GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0="$ROOT/.harness/scripts" \
         "$CLAUDE_BIN" -p "$pr" --model "$model" ${eff[@]+"${eff[@]}"} \
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

# --- Shared prompt() blocks (C01 stage 2) -----------------------------------------------------------
# scope_gate_block <tid> — the SCOPE — HARD GATE section of the build prompt: lists exactly which
# files the builder may touch (reads $tid's `scope` via the caller's own `tj`). Each caller prints its
# OWN final "PLUS you may always…" line immediately after calling this — that line legitimately
# differs per variant (each references what its OWN prompt already said elsewhere about who owns
# TASKS.json), so it deliberately stays OUT of this shared block rather than forcing a false
# unification of two sentences that mean different things in context.
scope_gate_block() {
  local tid="$1" sc
  sc="$(tj -r --arg id "$tid" '.tasks[]|select(.id==$id)|.scope[]?' 2>/dev/null)"
  printf '\n--- SCOPE — HARD GATE (a script checks your diff against this; staying inside it is mandatory) ---\n'
  printf 'You may change ONLY these files:\n'
  if [ -n "$sc" ]; then printf '%s\n' "$sc" | sed 's/^/  - /'; else printf '  (none declared — keep the diff minimal)\n'; fi
}

# expects_test_block <tid> — the "TESTS — REQUIRED" section of the build prompt, printed only when
# the task is marked expectsTest. Byte-identical across both variants before this extraction (verified
# via loop-parity.test.sh's manifest) — no seam needed.
expects_test_block() {
  local tid="$1"
  if tj -e --arg id "$tid" '.tasks[]|select(.id==$id)|.expectsTest==true' >/dev/null 2>&1; then
    printf '\n--- TESTS — REQUIRED for this task (it is marked expectsTest) ---\n'
    printf 'You MUST add or change at least one TEST file that exercises the behaviour in "## Do" and pins the\n'
    printf '"## Done when" acceptance items. Test files are ALWAYS in scope (see SCOPE above) — so this is a\n'
    printf 'REQUIREMENT of this task, not a scope exception you can skip. A diff that changes NO test file\n'
    printf 'AUTO-FAILS this task (structural gate: test-missing); a green run against the EXISTING tests only\n'
    printf 'is NOT sufficient. Write the test to what "## Done when" says it must assert, and keep it hermetic\n'
    printf '(a scratch/throwaway resource — never the real prod DB, live services, or real data).\n'
    printf 'PREFER TEST-FIRST: write that test FROM "## Done when" and run it BEFORE you implement — confirm it\n'
    printf 'FAILS first for the right reason (a test that is already green before you have written any code\n'
    printf 'asserts nothing), then build until it passes. Re-run the suite as many times as you need while you\n'
    printf 'iterate — there is NO per-attempt limit on how often you run the tests.\n'
  fi
}

# structural_checks <id> — cheap, model-agnostic gate on the build diff, BEFORE the audit. Any fail =
# a failed attempt. 0 = pass, 1 = fail. Sets STRUCT_FAIL_KIND/STRUCT_FAIL_DETAIL on every fail path so
# the ledger records WHICH check failed.
#
# SEAM (C01): reads $WORK_DIR (the git dir the diff/actionlint/LOCAL_DOD run against/in — the
# isolated worktree for loop.sh, the primary checkout for loop.in-place.sh), $PROMPT_DIR (where the
# actionlint/local-dod logs are written — reused from run_claude's seam, same "this build's own
# worklog dir" concept), and $MAIN_BRANCH (the branch the diff is measured against — FIXED at "main"
# for loop.sh, user-configurable for loop.in-place.sh; see each variant's own comment at assignment).
# Also reads $LOCAL_DOD, $LINT_WORKFLOW_FILES, $ROOT — identically named/computed in both variants.
structural_checks() {
  local id="$1" changed want_test scope creep f s inscope
  STRUCT_FAIL_KIND=""; STRUCT_FAIL_DETAIL=""   # set on each fail path so the ledger records WHICH check failed
  changed="$(git -C "$WORK_DIR" diff --name-only "origin/$MAIN_BRANCH..HEAD" 2>/dev/null)"
  if [ -z "$changed" ]; then STRUCT_FAIL_KIND="empty-diff"; log "structural: $id produced an EMPTY diff — fail"; return 1; fi
  # The repo-root README.md is MAINTAINER-OWNED product documentation — the loop NEVER edits it
  # (CLAUDE.md golden rule 3). A builder diff that touches it AUTO-FAILS, regardless of the task's
  # scope: the root README is never a valid scope target for the loop. Status/backlog live in
  # TASKS.json + the dashboard (always current), and human-facing product docs are a deliberate
  # maintainer act, not a build output. `grep -qx` matches the WHOLE line, so a nested sub-doc like
  # `docs/README.md` or `packages/x/README.md` is NOT caught — only the repo-root `README.md`.
  if printf '%s\n' "$changed" | grep -qx 'README.md'; then
    STRUCT_FAIL_KIND="readme-edit"
    log "structural: $id's diff touches the root README.md — the loop never edits it (maintainer-owned product doc) — fail"
    return 1
  fi
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
    if is_test_path "$f"; then continue; fi
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
  # D01: [skip ci] is a PLANNER-granted permission (ciSkipOk on the task), never something the
  # builder's own commit message can self-authorize (PRINCIPLES.md P2 — a gate satisfiable by text
  # the builder itself writes is exactly the listed drift smell). Checked here (BEFORE the push/CI
  # wait) since GitHub itself never creates a run for a [skip ci] commit — there'd be nothing for
  # wait_ci_green to find on an unauthorized one, so this must fire at commit-inspection time.
  if git -C "$WORK_DIR" log -1 --format=%s HEAD 2>/dev/null | grep -qF '[skip ci]'; then
    if [ "$(tj -r --arg id "$id" '.tasks[]|select(.id==$id)|.ciSkipOk // false')" != "true" ]; then
      STRUCT_FAIL_KIND="unauthorized-skip-ci"
      log "structural: $id's commit contains [skip ci] but the task has no ciSkipOk:true — fail"
      return 1
    fi
  fi
  want_test="$(tj -r --arg id "$id" '.tasks[]|select(.id==$id)|.expectsTest // false')"
  if [ "$want_test" = "true" ] && ! printf '%s\n' "$changed" | any_test_path; then
    STRUCT_FAIL_KIND="test-missing"; log "structural: $id has expectsTest=true but no test file changed — fail"; return 1
  fi
  # GitHub Actions workflow validation (see ensure-actionlint.sh) — a change to .github/workflows/*.yml
  # can be perfectly valid YAML yet REJECTED by GitHub's own schema (e.g. a flow-sequence where a scalar
  # is required), which kills the whole run at parse time — something LOCAL_DOD (the project's own
  # typecheck/test/build) can't catch. actionlint validates the schema LOCALLY, before the push. Fires
  # ONLY when the diff touches a workflow file (the common task pays nothing). Best-effort: if the linter
  # can't be fetched (offline / rate-limited) WARN + SKIP rather than block — the scaffolded
  # lint-workflows.yml CI job is the authoritative catch. LINT_WORKFLOW_FILES=0 disables it.
  if [ "${LINT_WORKFLOW_FILES:-1}" != 0 ]; then
    local wf al allog
    wf="$(printf '%s\n' "$changed" | grep -E '^\.github/workflows/.+\.(yml|yaml)$' | while IFS= read -r f; do [ -f "$WORK_DIR/$f" ] && printf '%s\n' "$f"; done)"
    if [ -n "$wf" ]; then
      if al="$("$ROOT/.harness/scripts/ensure-actionlint.sh" "$ROOT" 2>/dev/null)" && [ -x "$al" ]; then
        allog="$PROMPT_DIR/.actionlint.log"
        if ! ( cd "$WORK_DIR" && printf '%s\n' "$wf" | xargs "$al" ) >"$allog" 2>&1; then
          STRUCT_FAIL_KIND="workflow-lint"; STRUCT_FAIL_DETAIL="$(tail -n 20 "$allog" 2>/dev/null | tr '\n' '⏎')"
          log "structural: $id — actionlint REJECTED a .github/workflows change (invalid GitHub Actions schema) — fail (last lines:)"; tail -n 20 "$allog" 2>/dev/null | sed 's/^/    /' >&2
          return 1
        fi
        log "structural: actionlint OK on changed workflow file(s)"
      else
        log "structural: WARN — actionlint unavailable (couldn't fetch); SKIPPING local workflow-YAML validation for $id. The lint-workflows.yml CI job still gates it; set LINT_WORKFLOW_FILES=0 to silence."
      fi
    fi
  fi
  if [ -n "$LOCAL_DOD" ]; then
    log "structural: running LOCAL_DOD → $LOCAL_DOD"
    # Capture output so a LOCAL_DOD failure gives a "why" (the last lines go into the failure ledger
    # detail + the log), instead of the silent >/dev/null that left no diagnostic trail.
    local dodlog="$PROMPT_DIR/.local-dod.log"
    if ! ( cd "$WORK_DIR" && eval "$LOCAL_DOD" ) >"$dodlog" 2>&1; then
      STRUCT_FAIL_KIND="local-dod"; STRUCT_FAIL_DETAIL="$(tail -n 20 "$dodlog" 2>/dev/null | tr '\n' '⏎')"
      log "structural: LOCAL_DOD failed for $id — fail (last lines:)"; tail -n 20 "$dodlog" 2>/dev/null | sed 's/^/    /' >&2
      return 1
    fi
  fi
  return 0
}

# wait_ci_green [branch] — 0=green 1=red 2=indeterminate. <branch> is OPTIONAL: loop.sh always passes
# its tNNN branch (gating it via `origin/<branch>` before the fast-forward to main); loop.in-place.sh
# never passes one (there is no separate branch — it gates the CURRENT HEAD directly, since the build
# already happened on main). Before C01 this was two near-identical copies differing only by this
# branch-vs-HEAD sha resolution and a couple of log-line/comment wordings (reconciled here to the more
# detailed of the two, no behavior change) — unifying the signature is also what closes B10's bug class
# (a caller that forgets which shape to pass) rather than leaving it to reopen on the next hand-edit.
wait_ci_green() {
  local branch="${1:-}" sha runid="" waited=0
  command -v gh >/dev/null 2>&1 || { log "gh not installed — cannot gate CI"; return 2; }
  if [ -n "$branch" ]; then
    sha="$(git -C "$ROOT" rev-parse "origin/$branch" 2>/dev/null || true)"
    [ -n "$sha" ] || { log "cannot resolve origin/$branch"; return 2; }
  else
    sha="$(git -C "$ROOT" rev-parse HEAD)"
  fi
  log "waiting for CI ($CI_WORKFLOW) on ${branch:+$branch (}${sha}${branch:+)}…"
  while [ "$waited" -lt "$CI_TIMEOUT" ]; do
    runid="$(ci_find_run "$branch" "$sha")"
    [ -n "$runid" ] && break
    sleep "$WAIT_SECONDS"; waited=$((waited + WAIT_SECONDS))
  done
  [ -n "$runid" ] || { log "no '$CI_WORKFLOW' run appeared for $sha within ${CI_TIMEOUT}s"; return 2; }
  # A run GitHub reported by FILE PATH (name unresolved) is the signature of a malformed workflow file —
  # treat as RED immediately (never wait it out or merge over it) with a loud, actionable warning.
  if [ "${CI_NAME_UNRESOLVED:-0}" = 1 ]; then
    log "⚠ CI RED (run $runid): GitHub could NOT resolve the workflow's name (reported it by file path) for $sha — the .github/workflows file is almost certainly MALFORMED. Run: gh run view $runid --log-failed"
    return 1
  fi
  # BOUNDED poll for the run to SETTLE — CI_TIMEOUT bounds the WHOLE wait (finding the run AND watching
  # it finish), continuing the $waited budget from the find-loop above. The old blocking
  # `gh run watch --exit-status` had NO timeout, so a run stuck in_progress (hung runner, awaiting manual
  # approval, a queue/GitHub outage) hung the loop forever at `awaiting-ci` with supervise unable to
  # regain control (B10). Poll `gh run view` instead — the same idiom the find-loop uses — and give up as
  # indeterminate at the cap. (Not `gh run watch`, whose bare exit also conflated a real failure with a
  # concurrency-cancel; we classify via ci_conclusion below regardless.) The increment is floored at 1 so
  # a WAIT_SECONDS=0 config still makes progress toward the cap rather than spinning forever.
  local st_now
  while :; do
    st_now="$(gh run view "$runid" --json status,conclusion --jq '.status + "/" + (.conclusion // "")' 2>/dev/null || echo unknown)"
    case "$st_now" in completed/*) break ;; esac
    waited=$(( waited + (WAIT_SECONDS > 0 ? WAIT_SECONDS : 1) ))
    if [ "$waited" -ge "$CI_TIMEOUT" ]; then
      log "CI run $runid still not finished after ${CI_TIMEOUT}s — treating as indeterminate"; return 2
    fi
    sleep "$WAIT_SECONDS"
  done
  local latest; latest="$(ci_find_run "$branch" "$sha")"; [ -n "$latest" ] && runid="$latest"
  ci_conclusion "$runid"; local st=$?
  case "$st" in
    0) log "CI GREEN (run $runid)"; return 0 ;;
    1) log "CI RED (run $runid) — gh run view $runid --log-failed"; return 1 ;;
    *) log "CI INDETERMINATE (run $runid) — NOT treating as red (likely concurrency-cancelled/skipped, not a real failure)"; return 2 ;;
  esac
}

# audit_prompt <id> <spec> <diff> — the independent auditor's prompt (strict PASS/FAIL on ## Done
# when). Byte-identical across both variants before this extraction once the diff-range label reads
# $MAIN_BRANCH (loop.sh's is FIXED at "main" — see its own comment near LOOP_WT).
audit_prompt() {
  local id="$1" spec="$2" diff="$3"
  cat <<EOF
You are an INDEPENDENT AUDITOR. You did NOT write this code and you carry NO prior context. Another
agent implemented task $id; your ONLY job is to judge whether the implementation genuinely satisfies
the task's "## Done when" criteria below.

Give your reasoning in as much prose as you need. Then, as the ABSOLUTE LAST LINE of your entire
response — nothing after it, nothing else on that line — output exactly one of:
VERDICT: PASS
VERDICT: FAIL

That final sentinel line is the ONLY thing the harness parses; your prose above it is for a human
log only, so don't rely on the word "pass" or "fail" appearing anywhere else to convey your verdict.
PASS only if the diff meets EVERY "## Done when" item for real. FAIL if any item is unmet, faked,
stubbed, or only superficially addressed. Be strict — do not give the benefit of the doubt.

--- TASK $id SPEC ---
$spec

--- IMPLEMENTATION DIFF (origin/$MAIN_BRANCH..HEAD) ---
$diff
EOF
  visual_verify_block "$id" audit
  _custom_preamble audit
}

# --- C01 stage 4: the long tail (byte-identical pre-extraction; moved verbatim) ---

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

# flush_failures [id] [dest] — append the buffered rows into <dest> (default: $FAILURES, the primary
# checkout's ledgers/failures.jsonl — what loop.in-place.sh always calls this with NO args to use),
# then clear the buffer for the next task. loop.sh always passes an explicit <id> <dest> (id unused;
# dest is a path INSIDE the detached commit worktree, which the caller stages + commits) — `mkdir -p`
# is unconditional here (a harmless no-op on an already-existing dir) since loop.sh's dest directory
# may not exist yet in a freshly-created worktree.
flush_failures() {
  local dest="${2:-$FAILURES}"
  [ -s "$FAILURES_BUF" ] || return 0
  mkdir -p "$(dirname "$dest")"
  cat "$FAILURES_BUF" >>"$dest" 2>/dev/null || true
  : >"$FAILURES_BUF"
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

# ci_conclusion <runid> — 0 green | 1 red | 2 indeterminate, from the run's SETTLED conclusion. Only a
# real failure is RED; cancelled/skipped/stale/neutral is indeterminate (never revert good work over a
# concurrency-cancel).
ci_conclusion() {
  local concl; concl="$(gh run view "$1" --json status,conclusion --jq '.status + "/" + (.conclusion // "")' 2>/dev/null || true)"
  case "$concl" in
    completed/success) return 0 ;;
    completed/failure|completed/timed_out|completed/startup_failure|completed/action_required) return 1 ;;
    *) return 2 ;;
  esac
}

ci_find_run() {
  local br="$1" sha="$2" id; local -a ba=(); [ -n "$br" ] && ba=(--branch "$br")
  CI_NAME_UNRESOLVED=0
  id="$(gh run list ${ba[@]+"${ba[@]}"} --limit 20 --json databaseId,headSha,workflowName \
          --jq ".[] | select(.headSha==\"$sha\" and .workflowName==\"$CI_WORKFLOW\") | .databaseId" 2>/dev/null | head -1 || true)"
  if [ -z "$id" ]; then
    id="$(gh run list ${ba[@]+"${ba[@]}"} --limit 20 --json databaseId,headSha,workflowName \
            --jq ".[] | select(.headSha==\"$sha\" and (.workflowName|startswith(\".github/workflows/\"))) | .databaseId" 2>/dev/null | head -1 || true)"
    [ -n "$id" ] && CI_NAME_UNRESOLVED=1
  fi
  printf '%s' "$id"
}

# ci_status_now <branch-or-empty> <sha> — POINT-IN-TIME CI status for <sha> (NO waiting): 0 green | 1 red
# | 2 indeterminate/no-run. Used by the idle-reconcile guard so a task is never marked done while its
# main-HEAD CI is red or was never confirmed.
ci_status_now() {
  command -v gh >/dev/null 2>&1 || return 2
  local id; id="$(ci_find_run "$1" "$2")"
  [ -n "$id" ] || return 2
  [ "${CI_NAME_UNRESOLVED:-0}" = 1 ] && return 1
  ci_conclusion "$id"
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

# Optional post-integration hook (deploy/restart so the running product matches main).
run_integrate_hook() {
  [ -n "$INTEGRATE_HOOK" ] || return 0
  log "integrate hook: $INTEGRATE_HOOK"
  ( cd "$ROOT" && eval "$INTEGRATE_HOOK" ) || log "WARN: integrate hook failed (non-fatal)"
}

