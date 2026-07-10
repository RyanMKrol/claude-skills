#!/usr/bin/env bash
#
# print-prompt-banner.test.sh — regression guard for the PRINT_PROMPT banner (1.64.2) in BOTH loop
# variants' run_claude(). The banner echoes the exact prompt to the console wrapped in a heavy border.
# The fix this locks in:
#   • the model/effort parenthetical is repeated on the END line (not just the opening line), so a human
#     scrolling past a long prompt can see which tier ran without scrolling back up;
#   • BUILD banners also show "· rung N · attempt M" (the escalation position); AUDIT banners must NOT
#     (the auditor runs at the fixed AUDITOR tier, not a ladder rung — rung/attempt is meaningless there);
#   • the effort-less case (e.g. the Haiku floor) renders "(model)" with no stray " / ".
#
# WHY STATIC + a behavioral anchor (like loop-nounset.test.sh): the banner lives inside run_claude(),
# which can't be exercised end-to-end in CI without a live claude CLI. So we assert the fixed SHAPE is
# present in BOTH variants' source, and separately run a faithful copy of the exact printf/_meta logic to
# prove that shape renders correctly for build / audit / effort-less.
#
# PLUGIN-SOURCE test: runs in the plugin's CI, not copied into a consumer .harness/.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAIL=0
assert() { local desc="$1"; shift; if "$@"; then echo "ok - $desc"; else echo "FAIL - $desc"; FAIL=1; fi; }
has()    { grep -qF -- "$1" "$2"; }
lacks()  { ! grep -qF -- "$1" "$2"; }

# ---- Static: both variants carry the fixed banner shape ----
for V in loop.sh loop.in-place.sh; do
  f="$SCRIPT_DIR/$V"
  assert "[$V] meta built from model + optional effort"        has '_meta="($model${effort:+ / $effort})"'                                              "$f"
  assert "[$V] rung·attempt appended ONLY on the build phase"  has '[ "$phase" = build ] && _meta="$_meta  ·  rung ${cur_rung:-0} · attempt $(( ${cur_attempts:-0} + 1 ))"' "$f"
  assert "[$V] END line renders the meta (model/effort)"       has 'END %s PROMPT  —  task %s  %s'                                                       "$f"
  assert "[$V] old meta-less END line is gone"                 lacks 'END %s PROMPT  —  task %s\n'                                                       "$f"
done

# ---- Behavioral anchor: a faithful copy of the exact banner logic (mirrors run_claude) ----
render() {   # <model> <effort> <phase> <cur_task> <cur_rung> <cur_attempts>
  local model="$1" effort="$2" phase="$3" cur_task="$4" cur_rung="$5" cur_attempts="$6" pr="<prompt>"
  local _ph _meta _bar='========'
  _ph="$(printf '%s' "$phase" | tr '[:lower:]' '[:upper:]')"
  _meta="($model${effort:+ / $effort})"
  [ "$phase" = build ] && _meta="$_meta  ·  rung ${cur_rung:-0} · attempt $(( ${cur_attempts:-0} + 1 ))"
  printf '\n%s\n=====  %s PROMPT  —  task %s  %s\n%s\n%s\n%s\n=====  END %s PROMPT  —  task %s  %s\n%s\n\n' \
    "$_bar" "$_ph" "${cur_task:-?}" "$_meta" "$_bar" "$pr" "$_bar" "$_ph" "${cur_task:-?}" "$_meta" "$_bar"
}

# build, fresh: END line repeats model/effort AND shows rung 0 / attempt 1 (cur_attempts 0 → display 1)
assert "build END line repeats model/effort + rung·attempt" \
  bash -c "$(declare -f render); render claude-sonnet-5 low build T389 0 0 | grep -F 'END' | grep -qF '(claude-sonnet-5 / low)  ·  rung 0 · attempt 1'"

# escalated build: cur_attempts=1 → "attempt 2"; rung reflected
assert "build END line shows attempt = cur_attempts + 1" \
  bash -c "$(declare -f render); render claude-sonnet-5 high build T412 2 1 | grep -F 'END' | grep -qF 'rung 2 · attempt 2'"

# audit: END line carries model/effort but NO rung/attempt
assert "audit END line has model/effort" \
  bash -c "$(declare -f render); render claude-opus-4-8 high audit T389 0 0 | grep -F 'END' | grep -qF '(claude-opus-4-8 / high)'"
assert "audit END line omits rung/attempt" \
  bash -c "$(declare -f render); ! render claude-opus-4-8 high audit T389 0 0 | grep -F 'END' | grep -q 'rung'"

# effort-less (Haiku floor): "(model)" with no stray ' / '
assert "effort-less build renders (model) with no stray slash" \
  bash -c "$(declare -f render); l=\"\$(render claude-haiku-4-5 '' build T500 0 0 | grep -F 'END')\"; printf '%s' \"\$l\" | grep -qF '(claude-haiku-4-5)' && ! printf '%s' \"\$l\" | grep -qF 'haiku-4-5 /'"

[ "$FAIL" = 0 ] && echo "ALL PASS" || { echo "SOME FAILED"; exit 1; }
