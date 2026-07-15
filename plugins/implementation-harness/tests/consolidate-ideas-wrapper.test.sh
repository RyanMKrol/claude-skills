#!/usr/bin/env bash
#
# consolidate-ideas-wrapper.test.sh — baseline + B05 coverage for consolidate-ideas.sh's GIT wrapper
# (commit/push/cleanup), written BEFORE adding the branch-guard + pathspec fix so the change has a
# net. Distinct from consolidate-rewire.test.sh, which only exercises the underlying
# consolidate-ideas.mjs (pure data processing, no git). Spins up throwaway git repos (mktemp -d).
#
# PLUGIN-SOURCE test: runs in the plugin's CI, not copied into a consumer .harness/.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../templates/scripts" && pwd)"
FAIL=0
TMPS=()
cleanup() { local d; for d in ${TMPS[@]+"${TMPS[@]}"}; do rm -rf "$d"; done; }
trap cleanup EXIT

assert() { local desc="$1"; shift; if "$@"; then echo "ok - $desc"; else echo "FAIL - $desc"; FAIL=1; fi; }

setup_repo() {   # echoes repo path
  local d bare
  d="$(mktemp -d)"; bare="$(mktemp -d)"; TMPS+=("$d" "$bare")
  git init -q -b main "$d"
  ( cd "$d" && git config user.email t@t.com && git config user.name t )
  mkdir -p "$d/.harness/scripts" "$d/.harness/tracking" "$d/.harness/tasks" "$d/.harness/.pending-tasks"
  cp "$SCRIPT_DIR/repo-lock.sh" "$SCRIPT_DIR/consolidate-ideas.sh" "$SCRIPT_DIR/consolidate-ideas.mjs" "$d/.harness/scripts/"
  chmod +x "$d/.harness/scripts/"*.sh
  cat >"$d/.harness/tracking/TASKS.json" <<'JSON'
{"tasks":[]}
JSON
  : >"$d/.harness/tracking/IDEAS.jsonl"
  ( cd "$d" && git add -A && git commit -q -m init )
  git init -q --bare -b main "$bare"
  ( cd "$d" && git remote add origin "$bare" && git push -q -u origin main )
  echo "$d"
}

write_pending() {   # write_pending <repo> <slug> — a minimal valid pending-tasks unit
  local d="$1" slug="$2"
  cat >"$d/.harness/.pending-tasks/$slug.json" <<'JSON'
{"units":[{"tempId":"idea1-a","title":"a new task","dependsOn":[],"gate":null,"tags":[],"scope":["x"],
  "verify":[],"expectsTest":false,"facets":{"layer":"backend","workType":"feature","risk":[]},
  "specOverview":"overview","specDo":"do the thing","specDoneWhen":"it is done"}],"ideaIds":[]}
JSON
}

run() { local d="$1"; ( cd "$d" && bash .harness/scripts/consolidate-ideas.sh ); }

# 1. Happy path: a pending file → commit made, pushed, TASKS.json gains the task, pending file removed.
d="$(setup_repo)"
write_pending "$d" idea1
before="$(cd "$d" && git rev-list --count HEAD)"
run "$d" >/dev/null
after="$(cd "$d" && git rev-list --count HEAD)"
assert "consolidation makes exactly one commit" [ "$((after - before))" = 1 ]
assert "TASKS.json gained the new task" bash -c "jq -e '.tasks|length==1' '$d/.harness/tracking/TASKS.json' >/dev/null"
assert "commit pushed to origin" bash -c "cd '$d' && [ \"\$(git rev-parse HEAD)\" = \"\$(git rev-parse origin/main)\" ]"
assert "pending file removed after success" [ ! -f "$d/.harness/.pending-tasks/idea1.json" ]
rm -rf "$d"

# 2. No pending files → "nothing to do", exit 0, no commit.
d="$(setup_repo)"
before="$(cd "$d" && git rev-list --count HEAD)"
out="$(run "$d")"; rc=$?
assert "no pending files → exit 0" [ "$rc" = 0 ]
assert "no pending files → 'nothing to do' message" bash -c "[[ '$out' == *'nothing to do'* ]]"
assert "no pending files → no commit made" [ "$before" = "$(cd "$d" && git rev-list --count HEAD)" ]
rm -rf "$d"

# 3. Commit subject is the expected fixed string (compat with any tooling parsing it).
d="$(setup_repo)"
write_pending "$d" idea1
run "$d" >/dev/null
msg="$(cd "$d" && git log -1 --format=%s)"
assert "commit subject is the expected consolidate-ideas message" \
  bash -c "[[ '$msg' == *'consolidate-ideas: apply pending task conversions'* ]]"
rm -rf "$d"

# 4. B05: off-main refusal — checkout a feature branch, run consolidate-ideas → refuses, no commit,
#    no push, pending file PRESERVED (so a retry after switching back to main can still apply it).
d="$(setup_repo)"
write_pending "$d" idea1
( cd "$d" && git checkout -q -b feature-x )
before="$(cd "$d" && git rev-list --count HEAD)"
if run "$d" >/dev/null 2>&1; then
  echo "FAIL - consolidate-ideas.sh should refuse off-main"; FAIL=1
else
  echo "ok - consolidate-ideas.sh refuses to publish from a non-main branch (B05)"
fi
assert "no commit made when off-main" [ "$before" = "$(cd "$d" && git rev-list --count HEAD)" ]
assert "pending file preserved when refused (retryable)" [ -f "$d/.harness/.pending-tasks/idea1.json" ]
rm -rf "$d"

# 5. B05: pathspec isolation — an unrelated staged file must not ride the consolidation commit.
d="$(setup_repo)"
write_pending "$d" idea1
echo "unrelated WIP" >"$d/unrelated.txt"
( cd "$d" && git add unrelated.txt )
run "$d" >/dev/null
assert "the commit does NOT include the unrelated file" \
  bash -c "cd '$d' && ! git show --name-only --format= HEAD | grep -qF unrelated.txt"
assert "the unrelated staged file is still staged (not committed, not lost)" \
  bash -c "cd '$d' && git diff --cached --name-only | grep -qF unrelated.txt"
rm -rf "$d"

if [ "$FAIL" = 0 ]; then echo "PASS: consolidate-ideas-wrapper"; else echo "FAIL: consolidate-ideas-wrapper"; exit 1; fi
