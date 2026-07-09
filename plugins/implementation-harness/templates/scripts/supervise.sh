#!/usr/bin/env bash
#
# supervise.sh — run loop.sh on a fixed cadence, in the FOREGROUND, so you can watch it.
#
# Leave it in a terminal for days. Each cycle runs the single sequential loop (loop.sh),
# which builds tasks one at a time (in an isolation worktree or in-place, per the installed
# variant) until the backlog is done, a human gate is hit, or tokens run out. The loop's lock
# makes a fresh cycle a no-op if a
# previous loop is somehow still running, so overlap is harmless. Stop with Ctrl-C (cleanest
# between cycles — the banner tells you when it's idle).
#
# Cadence is measured from the START of each cycle, so cycles line up with the token-refresh
# window no matter how long a cycle takes. Default 5h + 15m buffer (tokens refresh ~5h after
# first use; the buffer avoids firing just before reset). Tune for your own quota window.
#
# Usage:  .harness/scripts/supervise.sh [interval_seconds] [max_cycles]
#   interval_seconds  default 18900 (5h15m) — normal cadence between cycles
#   max_cycles        default 0 (run forever)
#   RETRY_INTERVAL    env, default 900 (15m) — used INSTEAD of interval when the loop gave up
#                     while rate/usage-limited (exit 5), so we retry soon after the quota resets
#                     instead of idling out the full window. (The loop also polls + resumes
#                     limits itself; this is the backstop for when it exits anyway.)
#   SUPERVISE_ERROR_BACKOFF env, default 300 (5m) — used INSTEAD of interval when the loop exits
#                     non-zero for a NON-rate-limit, NON-prerequisite reason (a crash, a git error).
#                     Retrying in 5 min beats idling the full ~5h window after an early crash. (An
#                     exit 3 — dirty tree / missing jq / no TASKS.json — is NOT retried: it needs a
#                     human, so the supervised run STOPS loudly instead; see the exit-3 handler below.)
# Tip: the loop streams its own progress; this just paces and re-launches it.
set -uo pipefail

# ─── Refuse to run from inside a Claude Code process (no override, by design) ───────────────────
# Starting the build loop is a deliberate, human-hands action from a real terminal — never
# something an agent decides on its own initiative (an interactive session "helpfully" spinning up
# the loop for an unrelated request, or a builder task recursively starting another loop instance
# mid-build). Claude Code sets CLAUDECODE=1 in every Bash tool subprocess it spawns, regardless of
# session mode (-p / interactive, --dangerously-skip-permissions or not) — detect and hard-refuse,
# unconditionally. No override env var exists on purpose: an agent that could be told to set one
# could just as easily be told to run this anyway.
if [ -n "${CLAUDECODE:-}" ]; then
  echo "ABORT: this script must be run manually, from a real terminal — never from within a Claude Code session (detected \$CLAUDECODE=1). If Claude suggested running this, decline; run it yourself." >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # .harness/scripts — this script's own dir
LOOP="${LOOP:-$SCRIPT_DIR/loop.sh}"
INTERVAL="${1:-18900}"
MAX_CYCLES="${2:-0}"
RETRY_INTERVAL="${RETRY_INTERVAL:-900}"
SUPERVISE_ERROR_BACKOFF="${SUPERVISE_ERROR_BACKOFF:-300}"

stamp() { date '+%Y-%m-%d %H:%M:%S'; }
cycle=0
trap 'echo; echo "[supervise $(stamp)] stopped (after ${cycle} cycle(s))."; exit 0' INT TERM

echo "[supervise $(stamp)] starting — run loop.sh every ${INTERVAL}s (from each cycle's start). Ctrl-C to stop."
while :; do
  cycle=$((cycle + 1))
  start=$(date +%s)
  echo "======================================================================"
  echo "[supervise $(stamp)] cycle ${cycle}: launching loop.sh"
  echo "======================================================================"
  rc=0; "$LOOP" || rc=$?
  # exit 3 = a prerequisite a HUMAN must fix before the loop can do anything: a dirty working tree
  # (the in-place loop refuses rather than touch it), missing jq, or no TASKS.json. Re-launching on a
  # timer can never clear these — it just re-prints the loop's own refusal every cycle, burying it in
  # retry noise. So STOP the whole supervised run here, loudly, instead of backing off and retrying.
  if [ "$rc" = 3 ]; then
    echo "══════════════════════════════════════════════════════════════════════"
    echo "🛑 [supervise $(stamp)] loop REFUSED to run (exit 3) — a prerequisite needs a human."
    echo "   See the loop's message just above (dirty working tree / missing jq / no TASKS.json)."
    echo "   Retrying on a timer cannot fix this, so the supervised run is STOPPING now."
    echo "   → Fix the issue above, then re-run supervise.sh."
    echo "══════════════════════════════════════════════════════════════════════"
    exit 3
  fi
  [ "$rc" -ne 0 ] && echo "[supervise $(stamp)] loop exited non-zero ($rc) — continuing"

  if [ "$MAX_CYCLES" -gt 0 ] && [ "$cycle" -ge "$MAX_CYCLES" ]; then
    echo "[supervise $(stamp)] reached max cycles (${MAX_CYCLES}); exiting."
    exit 0
  fi

  # The loop self-handles usage limits (polls + resumes). Pick the next cadence (exit 3 already
  # hard-stopped the whole run above — a human-fixable prerequisite is never retried on a timer):
  #   exit 5  → gave up rate-limited: relaunch after RETRY_INTERVAL (retry soon after quota resets)
  #   other ≠0 → a crash / git error: relaunch after the short error backoff instead of idling the
  #             full window (which wastes hours after an early exit)
  #   exit 0  → normal cadence (full INTERVAL from cycle start, aligned to the quota window)
  base="$INTERVAL"
  if [ "$rc" = 5 ]; then
    base="$RETRY_INTERVAL"; echo "[supervise $(stamp)] loop gave up rate-limited — short retry (${RETRY_INTERVAL}s)"
  elif [ "$rc" -ne 0 ]; then
    base="$SUPERVISE_ERROR_BACKOFF"; echo "[supervise $(stamp)] loop exited non-zero ($rc, non-rate-limit) — short retry (${SUPERVISE_ERROR_BACKOFF}s)"
  fi
  elapsed=$(( $(date +%s) - start ))
  remain=$(( base - elapsed ))
  printf '\a'   # terminal bell: cycle finished, loop idle
  if [ "$remain" -gt 0 ]; then
    next=$(date -v+"${remain}"S '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "in ${remain}s")
    echo "══════════════════════════════════════════════════════════════════════"
    echo "🔔 [supervise $(stamp)] cycle ${cycle} complete (ran ${elapsed}s)."
    echo "   The loop is idle until the next cycle ~${next}."
    echo "   ✅ SAFE TO Ctrl-C NOW — nothing is running. Re-run supervise.sh to resume."
    echo "══════════════════════════════════════════════════════════════════════"
    sleep "$remain"
  else
    echo "🔔 [supervise $(stamp)] cycle ${cycle} ran ${elapsed}s (≥ interval) — launching next now."
  fi
done
