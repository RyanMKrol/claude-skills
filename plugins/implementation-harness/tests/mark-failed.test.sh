#!/usr/bin/env bash
#
# mark-failed.test.sh — baseline regression coverage for mark-failed.sh's CURRENT behavior, written
# BEFORE folding it onto the shared overlay-edit.sh lib (B05/C03), so the refactor has a net. Mirrors
# mark-done-bulk.test.sh's shape/setup. Spins up throwaway git repos (mktemp -d) with a real origin.
#
# PLUGIN-SOURCE test: runs in the plugin's CI, not copied into a consumer .harness/.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../templates/scripts" && pwd)"
MARK_FAILED="$SCRIPT_DIR/mark-failed.sh"
FAIL=0
assert() { local desc="$1"; shift; if "$@"; then echo "ok - $desc"; else echo "FAIL - $desc"; FAIL=1; fi; }

setup_repo() {   # echoes the repo path; T001=done, T002=blocked, T003=pending (neither done nor blocked)
  local d bare
  d="$(mktemp -d)"; bare="$(mktemp -d)"
  git init -q -b main "$d"   # explicit -b main: mark-failed.sh now branch-guards against MAIN_BRANCH
                              # (default "main") — don't rely on the host's init.defaultBranch (B05)
  ( cd "$d" && git config user.email t@t.com && git config user.name t )
  mkdir -p "$d/.harness/scripts" "$d/.harness/tracking"
  cp "$SCRIPT_DIR/repo-lock.sh" "$SCRIPT_DIR/overlay-edit.sh" "$MARK_FAILED" "$d/.harness/scripts/"
  chmod +x "$d/.harness/scripts/"*.sh
  cat >"$d/.harness/tracking/TASKS.json" <<'JSON'
{"version":1,"tasks":[
  {"id":"T001","status":"done","gate":null},
  {"id":"T002","status":"blocked","gate":null},
  {"id":"T003","status":"pending","gate":null}
]}
JSON
  echo '{}' >"$d/.harness/tracking/manual-fail.json"
  ( cd "$d" && git add -A && git commit -q -m init )
  git init -q --bare -b main "$bare"
  ( cd "$d" && git remote add origin "$bare" && git push -q -u origin HEAD )
  echo "$d"
}
run() { local d="$1"; shift; ( cd "$d" && bash .harness/scripts/mark-failed.sh "$@" ); }

# 1. A done task can be overturned: writes {failed:true, reason, at}, commits, pushes.
d="$(setup_repo)"
before="$(cd "$d" && git rev-list --count HEAD)"
run "$d" T001 "audit-missed regression" >/dev/null
after="$(cd "$d" && git rev-list --count HEAD)"
assert "mark-failed on a done task makes exactly one commit" [ "$((after - before))" = 1 ]
assert "overlay records failed:true"   bash -c "jq -e '.T001.failed==true' '$d/.harness/tracking/manual-fail.json' >/dev/null"
assert "overlay records the reason"    bash -c "jq -r '.T001.reason' '$d/.harness/tracking/manual-fail.json' | grep -qF 'audit-missed regression'"
assert "commit pushed to origin"       bash -c "cd '$d' && [ \"\$(git rev-parse HEAD)\" = \"\$(git rev-parse origin/main 2>/dev/null || git rev-parse origin/master)\" ]"
rm -rf "$d"

# 2. A blocked task can also be closed out this way (the review-failed use case).
d="$(setup_repo)"
run "$d" T002 "resolved elsewhere" >/dev/null
assert "mark-failed on a blocked task records the reason" \
  bash -c "jq -r '.T002.reason' '$d/.harness/tracking/manual-fail.json' | grep -qF 'resolved elsewhere'"
rm -rf "$d"

# 3. A pending task (neither done nor blocked) is REJECTED — no overlay write, no commit.
d="$(setup_repo)"
before="$(cd "$d" && git rev-list --count HEAD)"
if run "$d" T003 "should not apply" >/dev/null 2>&1; then
  echo "FAIL - mark-failed should reject a pending (not done/blocked) task"; FAIL=1
else
  echo "ok - mark-failed rejects a pending (not done/blocked) task"
fi
assert "no overlay entry created for rejected id" bash -c "! jq -e '.T003' '$d/.harness/tracking/manual-fail.json' >/dev/null 2>&1"
assert "no commit made for rejected id" [ "$before" = "$(cd "$d" && git rev-list --count HEAD)" ]
rm -rf "$d"

# 4. A bogus id is rejected outright.
d="$(setup_repo)"
if run "$d" T999 "nope" >/dev/null 2>&1; then
  echo "FAIL - mark-failed should reject a bogus id"; FAIL=1
else
  echo "ok - mark-failed rejects a bogus id"
fi
rm -rf "$d"

# 5. Missing reason is a usage error (exit 2), not a silent no-op.
d="$(setup_repo)"
if run "$d" T001 >/dev/null 2>&1; then
  echo "FAIL - mark-failed should require a reason"; FAIL=1
else
  echo "ok - mark-failed requires a reason"
fi
rm -rf "$d"

# 6. --undo removes the overlay entry in exactly one more commit.
d="$(setup_repo)"
run "$d" T001 "audit-missed regression" >/dev/null
before="$(cd "$d" && git rev-list --count HEAD)"
run "$d" --undo T001 >/dev/null
after="$(cd "$d" && git rev-list --count HEAD)"
assert "--undo makes exactly one more commit" [ "$((after - before))" = 1 ]
assert "T001 removed from overlay" bash -c "! jq -e '.T001' '$d/.harness/tracking/manual-fail.json' >/dev/null 2>&1"
rm -rf "$d"

# 7. --undo on an id with no entry is a clean no-op (no commit, exit 0).
d="$(setup_repo)"
before="$(cd "$d" && git rev-list --count HEAD)"
run "$d" --undo T002 >/dev/null
assert "--undo with nothing to undo makes no commit" [ "$before" = "$(cd "$d" && git rev-list --count HEAD)" ]
rm -rf "$d"

# 8. Commit subject mentions the id and the reason (compat with any tooling parsing it).
d="$(setup_repo)"
run "$d" T001 "audit-missed regression" >/dev/null
msg="$(cd "$d" && git log -1 --format=%s)"
assert "commit subject mentions the id"     bash -c "[[ '$msg' == *T001* ]]"
assert "commit subject mentions the reason" bash -c "[[ '$msg' == *'audit-missed regression'* ]]"
rm -rf "$d"

# 9. NO_PUSH=1 commits without pushing.
d="$(setup_repo)"
( cd "$d" && NO_PUSH=1 bash .harness/scripts/mark-failed.sh T001 "offline test" >/dev/null )
local_head="$(cd "$d" && git rev-parse HEAD)"
remote_head="$(cd "$d" && git rev-parse origin/main 2>/dev/null || git rev-parse origin/master 2>/dev/null || echo none)"
assert "NO_PUSH=1 commits locally but does not push" [ "$local_head" != "$remote_head" ]
rm -rf "$d"

# 10/11 (B05/C03 wiring — the lib's own matrix lives in overlay-edit.test.sh; these confirm
# mark-failed.sh is actually WIRED to it end-to-end through the real CLI, at BOTH call sites).
d="$(setup_repo)"
( cd "$d" && git checkout -q -b feature-x )
before="$(cd "$d" && git rev-list --count HEAD)"
if run "$d" T001 "should not publish" >/dev/null 2>&1; then
  echo "FAIL - mark-failed.sh should refuse off-main (main path)"; FAIL=1
else
  echo "ok - mark-failed.sh refuses to publish from a non-main branch (main path, B05)"
fi
assert "no commit made when off-main (main path)" [ "$before" = "$(cd "$d" && git rev-list --count HEAD)" ]
rm -rf "$d"

d="$(setup_repo)"
run "$d" T001 "audit-missed regression" >/dev/null
( cd "$d" && git checkout -q -b feature-x )
before="$(cd "$d" && git rev-list --count HEAD)"
if run "$d" --undo T001 >/dev/null 2>&1; then
  echo "FAIL - mark-failed.sh --undo should refuse off-main"; FAIL=1
else
  echo "ok - mark-failed.sh --undo refuses to publish from a non-main branch (B05)"
fi
assert "no commit made when off-main (--undo path)" [ "$before" = "$(cd "$d" && git rev-list --count HEAD)" ]
rm -rf "$d"

d="$(setup_repo)"
echo "unrelated WIP" >"$d/unrelated.txt"
( cd "$d" && git add unrelated.txt )
run "$d" T001 "audit-missed regression" >/dev/null
assert "mark-failed.sh's commit touches ONLY its overlay file (B05 pathspec isolation)" \
  bash -c "cd '$d' && [ \"\$(git show --name-only --format= HEAD)\" = '.harness/tracking/manual-fail.json' ]"
assert "the unrelated staged file is untouched (still staged, not committed)" \
  bash -c "cd '$d' && git diff --cached --name-only | grep -qF unrelated.txt"
rm -rf "$d"

if [ "$FAIL" = 0 ]; then echo "PASS: mark-failed"; else echo "FAIL: mark-failed"; exit 1; fi
