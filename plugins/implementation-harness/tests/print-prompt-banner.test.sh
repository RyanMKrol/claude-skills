#!/usr/bin/env bash
#
# print-prompt-banner.test.sh — regression guard for run_claude()'s prompt handling in BOTH loop
# variants. As of 1.74.0 the FULL prompt is written to a PER-PHASE worklog file (.claude-prompt.<phase>)
# and the CONSOLE gets only a CONCISE cycle-boundary banner (task/phase/tier + a pointer to that file):
# the giant prompt no longer floods the terminal, so a human can see where each cycle starts/ends. The
# tier meta (model[/effort], plus "· rung N · attempt M" on BUILD only) is preserved on the concise
# banner (still the useful at-a-glance signal); the AUDIT banner omits rung/attempt (fixed AUDITOR tier).
#
# WHY STATIC + a behavioral anchor: the banner lives inside run_claude(), which can't be exercised
# end-to-end in CI without a live claude CLI. So we assert the fixed SHAPE is present in BOTH variants'
# source, and separately run faithful copies of the exact printf/_meta logic to prove it renders right.
#
# PLUGIN-SOURCE test: runs in the plugin's CI, not copied into a consumer .harness/.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../templates/scripts" && pwd)"
FAIL=0
assert() { local desc="$1"; shift; if "$@"; then echo "ok - $desc"; else echo "FAIL - $desc"; FAIL=1; fi; }
has()    { grep -qF -- "$1" "$2"; }
lacks()  { ! grep -qF -- "$1" "$2"; }

# ---- Static: both variants carry the fixed shape ----
for V in loop.sh loop.in-place.sh; do
  f="$SCRIPT_DIR/$V"
  assert "[$V] meta built from model + optional effort"        has '_meta="($model${effort:+ / $effort})"'                                              "$f"
  assert "[$V] rung·attempt appended ONLY on the build phase"  has '[ "$phase" = build ] && _meta="$_meta  ·  rung ${cur_rung:-0} · attempt $(( ${cur_attempts:-0} + 1 ))"' "$f"
  assert "[$V] full prompt written to a per-phase file"        has '.claude-prompt.${phase}'                                                            "$f"
  assert "[$V] prompt written to the file (redirect present)"  has '} > "$_pfile"'                                                                       "$f"
  assert "[$V] console banner points at the prompt file"       has 'full prompt → %s'                                                                    "$f"
  assert "[$V] old full-prompt-in-console END banner is gone"  lacks 'END %s PROMPT'                                                                     "$f"
done
assert "[in-place] prompt file in the primary worklog dir"     has 'local _pfile="$WORKLOG/.claude-prompt.${phase}"'                    "$SCRIPT_DIR/loop.in-place.sh"
assert "[worktree] prompt file in the worktree's worklog dir"  has 'local _pfile="$LOOP_WT/.harness/worklog/.claude-prompt.${phase}"'   "$SCRIPT_DIR/loop.sh"

# ---- Behavioral anchor: faithful copies of the two writes (mirror run_claude) ----
render_console() {   # <model> <effort> <phase> <cur_task> <cur_rung> <cur_attempts>
  local model="$1" effort="$2" phase="$3" cur_task="$4" cur_rung="$5" cur_attempts="$6"
  local _ph _meta _bar='========' _pfile="wl/.claude-prompt.$phase"
  _ph="$(printf '%s' "$phase" | tr '[:lower:]' '[:upper:]')"
  _meta="($model${effort:+ / $effort})"
  [ "$phase" = build ] && _meta="$_meta  ·  rung ${cur_rung:-0} · attempt $(( ${cur_attempts:-0} + 1 ))"
  printf '\n%s\n=====  %s  —  task %s  %s\n=====  full prompt → %s\n%s\n\n' \
    "$_bar" "$_ph" "${cur_task:-?}" "$_meta" "$_pfile" "$_bar"
}
render_file() {   # <model> <effort> <phase> <cur_task> <cur_rung> <cur_attempts> — the prompt-file body
  local model="$1" effort="$2" phase="$3" cur_task="$4" cur_rung="$5" cur_attempts="$6" pr="<PROMPT-BODY>"
  local _ph _meta _bar='========'
  _ph="$(printf '%s' "$phase" | tr '[:lower:]' '[:upper:]')"
  _meta="($model${effort:+ / $effort})"
  [ "$phase" = build ] && _meta="$_meta  ·  rung ${cur_rung:-0} · attempt $(( ${cur_attempts:-0} + 1 ))"
  printf '%s\n=====  %s PROMPT  —  task %s  %s\n%s\n%s\n' \
    "$_bar" "$_ph" "${cur_task:-?}" "$_meta" "$_bar" "$pr"
}

# console: concise banner shows the tier + points at the file, and does NOT dump the prompt body
assert "console banner shows model/effort + rung·attempt on build" \
  bash -c "$(declare -f render_console); render_console claude-sonnet-5 low build T389 0 0 | grep -qF '(claude-sonnet-5 / low)  ·  rung 0 · attempt 1'"
assert "console banner points at the prompt file" \
  bash -c "$(declare -f render_console); render_console claude-sonnet-5 low build T389 0 0 | grep -qF 'full prompt → '"
assert "console banner does NOT contain the prompt body" \
  bash -c "$(declare -f render_console); ! render_console claude-sonnet-5 low build T389 0 0 | grep -qF '<PROMPT-BODY>'"
assert "console banner attempt = cur_attempts + 1" \
  bash -c "$(declare -f render_console); render_console claude-sonnet-5 high build T412 2 1 | grep -qF 'rung 2 · attempt 2'"
assert "audit console banner has model/effort" \
  bash -c "$(declare -f render_console); render_console claude-opus-4-8 high audit T389 0 0 | grep -qF '(claude-opus-4-8 / high)'"
assert "audit console banner omits rung/attempt" \
  bash -c "$(declare -f render_console); ! render_console claude-opus-4-8 high audit T389 0 0 | grep -q 'rung'"
assert "effort-less build renders (model) with no stray slash" \
  bash -c "$(declare -f render_console); l=\"\$(render_console claude-haiku-4-5 '' build T500 0 0)\"; printf '%s' \"\$l\" | grep -qF '(claude-haiku-4-5)' && ! printf '%s' \"\$l\" | grep -qF 'haiku-4-5 /'"

# file: contains the prompt body AND the tier meta header
assert "prompt file contains the prompt body" \
  bash -c "$(declare -f render_file); render_file claude-haiku-4-5 '' build T500 0 0 | grep -qF '<PROMPT-BODY>'"
assert "prompt file header carries the tier meta" \
  bash -c "$(declare -f render_file); render_file claude-sonnet-5 low build T389 0 0 | grep -qF '(claude-sonnet-5 / low)'"

[ "$FAIL" = 0 ] && echo "ALL PASS" || { echo "SOME FAILED"; exit 1; }
