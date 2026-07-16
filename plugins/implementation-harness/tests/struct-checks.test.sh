#!/usr/bin/env bash
#
# struct-checks.test.sh — behavioral coverage for structural_checks in BOTH loop variants, via
# --struct-selftest (runs the REAL function against a real fixture commit, no claude/gh needed).
#
# Covers D01 (unauthorized [skip ci] must fail closed) PLUS a baseline for the pre-existing
# empty-diff/scope-creep checks, which had ZERO behavioral coverage before this — only static
# grep-based pinning (loop-actionlint.test.sh, for the workflow-lint path specifically).
#
# THE D01 BUG (fixed): [skip ci] was honored on ANY commit whose message contained it — written by
# the BUILDER itself, a cheap/weak tier with no authorization to skip the CI gate. A task's structural
# check now requires the task to carry ciSkipOk:true (set by the strong planner at authoring time,
# never the builder) before it will accept a [skip ci] commit; otherwise it's a structural failure
# (unauthorized-skip-ci), same bucket as scope-creep.
#
# PLUGIN-SOURCE test: runs in the plugin's CI, not copied into a consumer .harness/.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../templates/scripts" && pwd)"
FAIL=0
TMPS=()
cleanup() { local d; for d in ${TMPS[@]+"${TMPS[@]}"}; do rm -rf "$d"; done; }
trap cleanup EXIT

assert() { local desc="$1"; shift; if "$@"; then echo "ok - $desc"; else echo "FAIL - $desc"; FAIL=1; fi; }

# tasks_json <ciSkipOk-line-or-empty> [scope-json-array] — T001, scoped to a.txt by default.
tasks_json() {
  local extra="$1" scope="${2:-[\"a.txt\"]}"
  printf '{"tasks":[{"id":"T001","status":"pending","gate":null,"scope":%s%s}]}' "$scope" "$extra"
}

# --- worktree variant (loop.sh) -------------------------------------------------------------------
# setup_wt <ciSkipOk-json-fragment> <changed-file> <commit-msg> → echoes "<d> <wt>". A REAL `git
# worktree add` (not a plain directory) — structural_checks' unrelated git-diff calls need a genuine
# repo there, same reasoning as audit-trail-persistence.test.sh.
setup_wt() {
  local extra="$1" file="$2" msg="$3" scope="${4:-}" d bare wt
  d="$(mktemp -d)"; bare="$(mktemp -d)"; wt="$(mktemp -d)"; rm -rf "$wt"
  git init -q -b main "$d"
  ( cd "$d" && git config user.email t@t.com && git config user.name t )
  mkdir -p "$d/.harness/scripts" "$d/.harness/tracking"
  cp "$SCRIPT_DIR/repo-lock.sh" "$SCRIPT_DIR/scope-lib.sh" "$SCRIPT_DIR/loop-lib.sh" "$SCRIPT_DIR/policy.jq" "$SCRIPT_DIR/loop.sh" "$d/.harness/scripts/"
  chmod +x "$d/.harness/scripts/"*.sh
  tasks_json "$extra" "$scope" > "$d/.harness/tracking/TASKS.json"
  echo "a" > "$d/a.txt"
  ( cd "$d" && git add -A && git commit -q -m init )
  git init -q --bare -b main "$bare"
  ( cd "$d" && git remote add origin "$bare" && git push -q -u origin main )
  ( cd "$d" && git worktree add -q "$wt" -b tprobe main )
  if [ -n "$file" ]; then
    mkdir -p "$(dirname "$wt/$file")"; echo "changed" >> "$wt/$file"
    ( cd "$wt" && git add -A && git commit -q -m "$msg" )
  fi
  echo "$d $wt"
}
run_wt_struct() {   # run_wt_struct <d> <wt> → echoes STRUCT_FAIL_KIND or PASS
  ( cd "$1" && env -u CLAUDECODE LOOP_WT="$2" bash .harness/scripts/loop.sh --struct-selftest T001 2>/dev/null )
}

d_wt="" wt_wt=""
read -r d_wt wt_wt <<<"$(setup_wt "" "" "")"; TMPS+=("$d_wt")
assert "[worktree] empty diff → empty-diff (baseline, pre-existing check)" \
  [ "$(run_wt_struct "$d_wt" "$wt_wt")" = empty-diff ]
( cd "$d_wt" && git worktree remove --force "$wt_wt" 2>/dev/null || true )

read -r d_wt wt_wt <<<"$(setup_wt "" "b.txt" "touch b.txt")"; TMPS+=("$d_wt")
assert "[worktree] out-of-scope file → scope-creep (baseline, pre-existing check)" \
  [ "$(run_wt_struct "$d_wt" "$wt_wt")" = scope-creep ]
( cd "$d_wt" && git worktree remove --force "$wt_wt" 2>/dev/null || true )

read -r d_wt wt_wt <<<"$(setup_wt "" "a.txt" "edit a.txt")"; TMPS+=("$d_wt")
assert "[worktree] in-scope diff, no [skip ci], no ciSkipOk → PASS (baseline sanity)" \
  [ "$(run_wt_struct "$d_wt" "$wt_wt")" = PASS ]
( cd "$d_wt" && git worktree remove --force "$wt_wt" 2>/dev/null || true )

read -r d_wt wt_wt <<<"$(setup_wt ',"ciSkipOk":true' "a.txt" "edit a.txt [skip ci]")"; TMPS+=("$d_wt")
assert "[worktree] [skip ci] WITH ciSkipOk:true → PASS (D01 — authorized)" \
  [ "$(run_wt_struct "$d_wt" "$wt_wt")" = PASS ]
( cd "$d_wt" && git worktree remove --force "$wt_wt" 2>/dev/null || true )

read -r d_wt wt_wt <<<"$(setup_wt "" "a.txt" "edit a.txt [skip ci]")"; TMPS+=("$d_wt")
assert "[worktree] [skip ci] WITHOUT ciSkipOk → unauthorized-skip-ci (D01 — THE FIX)" \
  [ "$(run_wt_struct "$d_wt" "$wt_wt")" = unauthorized-skip-ci ]
( cd "$d_wt" && git worktree remove --force "$wt_wt" 2>/dev/null || true )

read -r d_wt wt_wt <<<"$(setup_wt ',"ciSkipOk":true' "a.txt" "edit a.txt")"; TMPS+=("$d_wt")
assert "[worktree] ciSkipOk:true but no [skip ci] in message → PASS (permits, doesn't force)" \
  [ "$(run_wt_struct "$d_wt" "$wt_wt")" = PASS ]
( cd "$d_wt" && git worktree remove --force "$wt_wt" 2>/dev/null || true )

# README hard-block (maintainer-owned): a builder diff touching the ROOT README.md auto-fails,
# regardless of scope — the loop never edits it. readme-edit fires BEFORE scope-creep.
read -r d_wt wt_wt <<<"$(setup_wt "" "README.md" "touch README")"; TMPS+=("$d_wt")
assert "[worktree] root README.md edit (not in scope) → readme-edit (fires before scope-creep)" \
  [ "$(run_wt_struct "$d_wt" "$wt_wt")" = readme-edit ]
( cd "$d_wt" && git worktree remove --force "$wt_wt" 2>/dev/null || true )

read -r d_wt wt_wt <<<"$(setup_wt "" "README.md" "touch README" '["a.txt","README.md"]')"; TMPS+=("$d_wt")
assert "[worktree] root README.md edit EVEN WHEN in scope → readme-edit (scope can't authorize it)" \
  [ "$(run_wt_struct "$d_wt" "$wt_wt")" = readme-edit ]
( cd "$d_wt" && git worktree remove --force "$wt_wt" 2>/dev/null || true )

read -r d_wt wt_wt <<<"$(setup_wt "" "docs/README.md" "touch nested README" '["docs/README.md"]')"; TMPS+=("$d_wt")
assert "[worktree] NESTED docs/README.md (in scope) → PASS (only the ROOT README is blocked)" \
  [ "$(run_wt_struct "$d_wt" "$wt_wt")" = PASS ]
( cd "$d_wt" && git worktree remove --force "$wt_wt" 2>/dev/null || true )

# --- in-place variant (loop.in-place.sh) ------------------------------------------------------------
# No separate worktree: the in-place loop operates directly in $ROOT, so the fixture commits its
# diverging change straight onto the SAME checkout, one commit ahead of origin/main.
setup_inplace() {   # setup_inplace <ciSkipOk-json-fragment> <changed-file> <commit-msg> [scope-json] → echoes <d>
  local extra="$1" file="$2" msg="$3" scope="${4:-}" d bare
  d="$(mktemp -d)"; bare="$(mktemp -d)"
  git init -q -b main "$d"
  ( cd "$d" && git config user.email t@t.com && git config user.name t )
  mkdir -p "$d/.harness/scripts" "$d/.harness/tracking"
  cp "$SCRIPT_DIR/repo-lock.sh" "$SCRIPT_DIR/scope-lib.sh" "$SCRIPT_DIR/loop-lib.sh" "$SCRIPT_DIR/policy.jq" "$SCRIPT_DIR/loop.in-place.sh" "$d/.harness/scripts/"
  chmod +x "$d/.harness/scripts/"*.sh
  tasks_json "$extra" "$scope" > "$d/.harness/tracking/TASKS.json"
  echo "a" > "$d/a.txt"
  ( cd "$d" && git add -A && git commit -q -m init )
  git init -q --bare -b main "$bare"
  ( cd "$d" && git remote add origin "$bare" && git push -q -u origin main )
  if [ -n "$file" ]; then
    mkdir -p "$(dirname "$d/$file")"; echo "changed" >> "$d/$file"
    ( cd "$d" && git add -A && git commit -q -m "$msg" )
  fi
  echo "$d"
}
run_inplace_struct() { ( cd "$1" && env -u CLAUDECODE bash .harness/scripts/loop.in-place.sh --struct-selftest T001 2>/dev/null ); }

d="$(setup_inplace "" "" "")"; TMPS+=("$d")
assert "[in-place] empty diff → empty-diff (baseline, pre-existing check)" \
  [ "$(run_inplace_struct "$d")" = empty-diff ]

d="$(setup_inplace "" "b.txt" "touch b.txt")"; TMPS+=("$d")
assert "[in-place] out-of-scope file → scope-creep (baseline, pre-existing check)" \
  [ "$(run_inplace_struct "$d")" = scope-creep ]

d="$(setup_inplace "" "a.txt" "edit a.txt")"; TMPS+=("$d")
assert "[in-place] in-scope diff, no [skip ci], no ciSkipOk → PASS (baseline sanity)" \
  [ "$(run_inplace_struct "$d")" = PASS ]

d="$(setup_inplace ',"ciSkipOk":true' "a.txt" "edit a.txt [skip ci]")"; TMPS+=("$d")
assert "[in-place] [skip ci] WITH ciSkipOk:true → PASS (D01 — authorized)" \
  [ "$(run_inplace_struct "$d")" = PASS ]

d="$(setup_inplace "" "a.txt" "edit a.txt [skip ci]")"; TMPS+=("$d")
assert "[in-place] [skip ci] WITHOUT ciSkipOk → unauthorized-skip-ci (D01 — THE FIX)" \
  [ "$(run_inplace_struct "$d")" = unauthorized-skip-ci ]

d="$(setup_inplace ',"ciSkipOk":true' "a.txt" "edit a.txt")"; TMPS+=("$d")
assert "[in-place] ciSkipOk:true but no [skip ci] in message → PASS (permits, doesn't force)" \
  [ "$(run_inplace_struct "$d")" = PASS ]

# README hard-block (maintainer-owned) — same as the worktree cases above.
d="$(setup_inplace "" "README.md" "touch README")"; TMPS+=("$d")
assert "[in-place] root README.md edit (not in scope) → readme-edit (fires before scope-creep)" \
  [ "$(run_inplace_struct "$d")" = readme-edit ]

d="$(setup_inplace "" "README.md" "touch README" '["a.txt","README.md"]')"; TMPS+=("$d")
assert "[in-place] root README.md edit EVEN WHEN in scope → readme-edit (scope can't authorize it)" \
  [ "$(run_inplace_struct "$d")" = readme-edit ]

d="$(setup_inplace "" "docs/README.md" "touch nested README" '["docs/README.md"]')"; TMPS+=("$d")
assert "[in-place] NESTED docs/README.md (in scope) → PASS (only the ROOT README is blocked)" \
  [ "$(run_inplace_struct "$d")" = PASS ]

[ "$FAIL" = 0 ] && echo "ALL PASS" || { echo "SOME FAILED"; exit 1; }
