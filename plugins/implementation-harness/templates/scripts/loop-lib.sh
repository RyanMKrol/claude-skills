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
