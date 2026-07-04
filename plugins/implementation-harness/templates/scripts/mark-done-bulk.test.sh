#!/usr/bin/env bash
#
# mark-done-bulk.test.sh — hermetic test suite for mark-done.sh's bulk/atomic behavior. Spins up
# throwaway git repos (mktemp -d) so it never touches a real harness. Run standalone:
#   .harness/scripts/mark-done-bulk.test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MARK_DONE="$SCRIPT_DIR/mark-done.sh"
FAIL=0

setup_repo() {   # echoes the repo path
  local d bare
  d="$(mktemp -d)"
  git init -q "$d"
  ( cd "$d" && git config user.email t@t.com && git config user.name t )
  mkdir -p "$d/.harness/scripts" "$d/.harness/tracking"
  cp "$SCRIPT_DIR/repo-lock.sh" "$d/.harness/scripts/"
  cp "$MARK_DONE" "$SCRIPT_DIR/mark-reviewed.sh" "$d/.harness/scripts/"
  chmod +x "$d/.harness/scripts/"*.sh
  cat >"$d/.harness/tracking/TASKS.json" <<'JSON'
{"version":1,"tasks":[
  {"id":"T001","status":"pending","gate":"needs-human"},
  {"id":"T002","status":"pending","gate":"needs-human"},
  {"id":"T003","status":"pending","gate":null},
  {"id":"T004","status":"done","gate":null}
]}
JSON
  echo '{}' >"$d/.harness/tracking/human-done.json"
  echo '{}' >"$d/.harness/tracking/reviews.json"
  ( cd "$d" && git add -A && git commit -q -m init )
  bare="$(mktemp -d)"; git init -q --bare "$bare"
  ( cd "$d" && git remote add origin "$bare" && git push -q -u origin HEAD )
  echo "$d"
}

assert() { local desc="$1"; shift; if "$@"; then echo "ok - $desc"; else echo "FAIL - $desc"; FAIL=1; fi; }

# Test 1: a bulk call (2 ids) makes exactly ONE commit, both ids land in the overlay.
d="$(setup_repo)"
before="$(cd "$d" && git rev-list --count HEAD)"
( cd "$d" && .harness/scripts/mark-done.sh T001 T002 >/dev/null )
after="$(cd "$d" && git rev-list --count HEAD)"
assert "bulk mark-done makes exactly one commit" [ "$((after - before))" = 1 ]
assert "T001 recorded in overlay" bash -c "jq -e '.T001.done==true' '$d/.harness/tracking/human-done.json' >/dev/null"
assert "T002 recorded in overlay" bash -c "jq -e '.T002.done==true' '$d/.harness/tracking/human-done.json' >/dev/null"
rm -rf "$d"

# Test 2: fail-fast — one bad id aborts the WHOLE batch; overlay is byte-unchanged, no commit.
d="$(setup_repo)"
before_hash="$(shasum "$d/.harness/tracking/human-done.json" | awk '{print $1}')"
before_commits="$(cd "$d" && git rev-list --count HEAD)"
if ( cd "$d" && .harness/scripts/mark-done.sh T001 T999-does-not-exist >/dev/null 2>&1 ); then
  echo "FAIL - bad id in batch should have aborted (exit nonzero)"; FAIL=1
else
  echo "ok - bad id in batch aborts (nonzero exit)"
fi
after_hash="$(shasum "$d/.harness/tracking/human-done.json" | awk '{print $1}')"
after_commits="$(cd "$d" && git rev-list --count HEAD)"
assert "overlay file byte-unchanged after aborted batch" [ "$before_hash" = "$after_hash" ]
assert "no commit made after aborted batch" [ "$before_commits" = "$after_commits" ]
rm -rf "$d"

# Test 3: single-id commit subject format is unchanged (compat with any tooling parsing it).
d="$(setup_repo)"
( cd "$d" && .harness/scripts/mark-done.sh T001 >/dev/null )
msg="$(cd "$d" && git log -1 --format=%s)"
assert "single-id commit subject mentions T001" bash -c "[[ '$msg' == *T001* ]]"
rm -rf "$d"

# Test 4: --undo removes the overlay entry in exactly one more commit.
d="$(setup_repo)"
( cd "$d" && .harness/scripts/mark-done.sh T001 >/dev/null )
before="$(cd "$d" && git rev-list --count HEAD)"
( cd "$d" && .harness/scripts/mark-done.sh --undo T001 >/dev/null )
after="$(cd "$d" && git rev-list --count HEAD)"
assert "--undo makes exactly one more commit" [ "$((after - before))" = 1 ]
assert "T001 removed from overlay" bash -c "! jq -e '.T001' '$d/.harness/tracking/human-done.json' >/dev/null 2>&1"
rm -rf "$d"

# Test 5: mark-done rejects a non-needs-human id (T003, gate:null) — no overlay entry, no commit.
d="$(setup_repo)"
before_commits="$(cd "$d" && git rev-list --count HEAD)"
if ( cd "$d" && .harness/scripts/mark-done.sh T003 >/dev/null 2>&1 ); then
  echo "FAIL - mark-done should reject a non-needs-human id"; FAIL=1
else
  echo "ok - mark-done rejects a non-needs-human (gate:null) id"
fi
assert "no overlay entry created for rejected id" bash -c "! jq -e '.T003' '$d/.harness/tracking/human-done.json' >/dev/null 2>&1"
assert "no commit made for rejected id" [ "$before_commits" = "$(cd "$d" && git rev-list --count HEAD)" ]
rm -rf "$d"

# Test 6: mark-reviewed bulk (2 ids) makes exactly ONE commit; both land; --undo removes the key.
d="$(setup_repo)"
before="$(cd "$d" && git rev-list --count HEAD)"
( cd "$d" && .harness/scripts/mark-reviewed.sh T004 T001 >/dev/null )
after="$(cd "$d" && git rev-list --count HEAD)"
assert "bulk mark-reviewed makes exactly one commit" [ "$((after - before))" = 1 ]
assert "T004 recorded reviewed" bash -c "jq -e '.T004.reviewed==true' '$d/.harness/tracking/reviews.json' >/dev/null"
( cd "$d" && .harness/scripts/mark-reviewed.sh --undo T004 >/dev/null )
assert "mark-reviewed --undo removes the key entirely" bash -c "! jq -e '.T004' '$d/.harness/tracking/reviews.json' >/dev/null 2>&1"
rm -rf "$d"

if [ "$FAIL" = 0 ]; then echo "mark-done-bulk.test.sh: ALL PASS"; else echo "mark-done-bulk.test.sh: FAILURES"; exit 1; fi
