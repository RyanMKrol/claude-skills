#!/usr/bin/env bash
#
# overlay-edit.test.sh — the shared overlay_edit lib's own matrix (C03), tested directly rather than
# only indirectly through mark-*.sh: no-op, invalid-mutate-output aborts untouched, off-main refusal
# (B05), pathspec isolation (B05 — an unrelated staged file never rides the commit), lock contention.
# Spins up throwaway git repos (mktemp -d) with a real origin.
#
# PLUGIN-SOURCE test: runs in the plugin's CI, not copied into a consumer .harness/.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../templates/scripts" && pwd)"
FAIL=0
TMPS=()
cleanup() { local d; for d in ${TMPS[@]+"${TMPS[@]}"}; do rm -rf "$d"; done; }
trap cleanup EXIT

assert() { local desc="$1"; shift; if "$@"; then echo "ok - $desc"; else echo "FAIL - $desc"; FAIL=1; fi; }

setup_repo() {   # echoes repo path; HARNESS_DIR = <repo>/.harness
  local d bare
  d="$(mktemp -d)"; bare="$(mktemp -d)"; TMPS+=("$d" "$bare")
  git init -q -b main "$d"
  ( cd "$d" && git config user.email t@t.com && git config user.name t )
  mkdir -p "$d/.harness/scripts" "$d/.harness/tracking"
  cp "$SCRIPT_DIR/repo-lock.sh" "$SCRIPT_DIR/overlay-edit.sh" "$d/.harness/scripts/"
  chmod +x "$d/.harness/scripts/"*.sh
  echo '{}' >"$d/.harness/tracking/test-overlay.json"
  ( cd "$d" && git add -A && git commit -q -m init )
  git init -q --bare "$bare"
  ( cd "$d" && git remote add origin "$bare" && git push -q -u origin main )
  echo "$d"
}

# run_scenario <repo> <mutate-body> <commit-msg> [env-prefix…] → runs a fresh bash process that
# sources overlay-edit.sh and calls overlay_edit once; echoes "<rc>|<stdout+stderr>".
run_scenario() {
  local d="$1" mutate_body="$2" msg="$3"; shift 3
  local out rc
  out="$(cd "$d" && env "$@" bash -c '
    set -uo pipefail
    HARNESS_DIR="'"$d"'/.harness"
    . "$HARNESS_DIR/scripts/overlay-edit.sh"
    _t_mutate() { '"$mutate_body"'; }
    overlay_edit "tracking/test-overlay.json" _t_mutate "'"$msg"'"
  ' 2>&1)"; rc=$?
  printf '%s|%s' "$rc" "$out"
}

# 1. NO-OP: mutate doesn't change anything → rc 2, no commit.
d="$(setup_repo)"
before="$(cd "$d" && git rev-list --count HEAD)"
res="$(run_scenario "$d" 'true' "no-op test [skip ci]")"
rc="${res%%|*}"
assert "[no-op] overlay_edit returns 2" [ "$rc" = 2 ]
assert "[no-op] no commit made" [ "$before" = "$(cd "$d" && git rev-list --count HEAD)" ]
rm -rf "$d"

# 2. INVALID MUTATE OUTPUT: mutate writes garbage → rc 1, ABORT message, overlay file byte-unchanged,
#    no commit.
d="$(setup_repo)"
before_hash="$(shasum "$d/.harness/tracking/test-overlay.json" | awk '{print $1}')"
before="$(cd "$d" && git rev-list --count HEAD)"
res="$(run_scenario "$d" 'printf "not json" > "$1"' "bad mutate [skip ci]")"
rc="${res%%|*}"; out="${res#*|}"
assert "[invalid-mutate] overlay_edit returns 1" [ "$rc" = 1 ]
assert "[invalid-mutate] ABORT message printed" bash -c '[[ "$1" == *ABORT* ]]' _ "$out"
assert "[invalid-mutate] overlay file byte-unchanged" \
  [ "$before_hash" = "$(shasum "$d/.harness/tracking/test-overlay.json" | awk '{print $1}')" ]
assert "[invalid-mutate] no commit made" [ "$before" = "$(cd "$d" && git rev-list --count HEAD)" ]
rm -rf "$d"

# 3. INVALID MUTATE EXIT CODE (jq itself fails, output untouched by the failed pipeline): mutate's
#    internal jq errors — `&&` short-circuit leaves $1 as the untouched copy — must still ABORT, not
#    silently no-op (the mutate fn's own nonzero exit is what overlay_edit checks for this).
d="$(setup_repo)"
before="$(cd "$d" && git rev-list --count HEAD)"
res="$(run_scenario "$d" 'jq "this is not valid jq syntax(((" "$1" >"$1.2" && mv "$1.2" "$1"' "broken jq [skip ci]")"
rc="${res%%|*}"; out="${res#*|}"
assert "[broken-mutate] overlay_edit returns 1 (not a silent no-op)" [ "$rc" = 1 ]
assert "[broken-mutate] ABORT message printed" bash -c '[[ "$1" == *ABORT* ]]' _ "$out"
assert "[broken-mutate] no commit made" [ "$before" = "$(cd "$d" && git rev-list --count HEAD)" ]
rm -rf "$d"

# 4. OFF-MAIN REFUSAL (B05): checkout a feature branch → refuses, no commit, no push.
d="$(setup_repo)"
( cd "$d" && git checkout -q -b feature-x )
before="$(cd "$d" && git rev-list --count HEAD)"
res="$(run_scenario "$d" 'jq ".marker=true" "$1" >"$1.2" && mv "$1.2" "$1"' "should not land [skip ci]")"
rc="${res%%|*}"; out="${res#*|}"
assert "[off-main] overlay_edit returns 1" [ "$rc" = 1 ]
assert "[off-main] refusal names the branch" bash -c '[[ "$1" == *"is on '\''feature-x'\''"* ]]' _ "$out"
assert "[off-main] no commit made" [ "$before" = "$(cd "$d" && git rev-list --count HEAD)" ]
assert "[off-main] origin/main unmoved" \
  bash -c "cd '$d' && [ \"\$(git rev-parse origin/main)\" = \"\$(git rev-parse main)\" ]"
rm -rf "$d"

# 5. PATHSPEC ISOLATION (B05): an unrelated file staged before the call → the commit contains ONLY
#    the overlay; the unrelated file stays staged afterward (never swept in, never lost).
d="$(setup_repo)"
echo "unrelated WIP" >"$d/unrelated.txt"
( cd "$d" && git add unrelated.txt )
res="$(run_scenario "$d" 'jq ".marker=true" "$1" >"$1.2" && mv "$1.2" "$1"' "pathspec isolation [skip ci]")"
rc="${res%%|*}"
assert "[pathspec] overlay_edit still succeeds (rc 0)" [ "$rc" = 0 ]
assert "[pathspec] the commit touches ONLY the overlay file" \
  bash -c "cd '$d' && [ \"\$(git show --name-only --format= HEAD)\" = '.harness/tracking/test-overlay.json' ]"
assert "[pathspec] the unrelated file is STILL staged (never committed)" \
  bash -c "cd '$d' && git diff --cached --name-only | grep -qF unrelated.txt"
rm -rf "$d"

# 6. LOCK CONTENTION: a live PID holds the lock; REPO_LOCK_WAIT=1 + a short REPO_LOCK_MAX_WAIT → gives
#    up, returns 1 (not a silent success, not a hang), no commit, no mutation applied.
d="$(setup_repo)"
GC="$d/.git"; LOCK="$GC/$(basename "$d")-loop.lock"
mkdir -p "$LOCK"; echo "$$" >"$LOCK/pid"   # $$ = this test shell — alive, so never reclaimed as stale
before="$(cd "$d" && git rev-list --count HEAD)"
res="$(run_scenario "$d" 'jq ".marker=true" "$1" >"$1.2" && mv "$1.2" "$1"' "should not land [skip ci]" \
  REPO_LOCK_WAIT=1 REPO_LOCK_MAX_WAIT=1 REPO_LOCK_RETRY=1)"
rc="${res%%|*}"
assert "[lock-contention] overlay_edit returns 1 after giving up (not a hang, not a silent success)" [ "$rc" = 1 ]
assert "[lock-contention] no commit made" [ "$before" = "$(cd "$d" && git rev-list --count HEAD)" ]
rm -rf "$LOCK"; rm -rf "$d"

if [ "$FAIL" = 0 ]; then echo "PASS: overlay-edit"; else echo "FAIL: overlay-edit"; exit 1; fi
