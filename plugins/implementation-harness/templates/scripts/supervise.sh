#!/usr/bin/env bash
#
# supervise.sh — run loop.sh on a fixed cadence, in the FOREGROUND, so you can watch it.
#
# Leave it in a terminal for days. Each cycle runs the single sequential loop (loop.sh),
# which builds tasks one at a time in its own isolation worktree until the backlog is done,
# a human gate is hit, or tokens run out. The loop's lock makes a fresh cycle a no-op if a
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
# Tip: the loop streams its own progress; this just paces and re-launches it.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # .harness/scripts — this script's own dir
LOOP="${LOOP:-$SCRIPT_DIR/loop.sh}"
INTERVAL="${1:-18900}"
MAX_CYCLES="${2:-0}"
RETRY_INTERVAL="${RETRY_INTERVAL:-900}"

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
  [ "$rc" -ne 0 ] && echo "[supervise $(stamp)] loop exited non-zero ($rc) — continuing"

  if [ "$MAX_CYCLES" -gt 0 ] && [ "$cycle" -ge "$MAX_CYCLES" ]; then
    echo "[supervise $(stamp)] reached max cycles (${MAX_CYCLES}); exiting."
    exit 0
  fi

  # The loop self-handles usage limits (polls + resumes). If it nonetheless GAVE UP while still
  # rate-limited (exit 5), relaunch after the short RETRY_INTERVAL instead of the full window.
  base="$INTERVAL"
  [ "$rc" = 5 ] && { base="$RETRY_INTERVAL"; echo "[supervise $(stamp)] loop gave up rate-limited — short retry (${RETRY_INTERVAL}s)"; }
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
