#!/usr/bin/env bash
#
# rewire-dependents.test.sh — hermetic tests for the stranded-dependent repair tool. Spins up a
# throwaway git repo (mktemp -d); uses NO_PUSH=1 so no remote is needed.
#
# Covers the T389→T388 class: an orphan (T389) waiting on a terminal failed dep (T388) that was already
# `reviewed`, so /review-failed can't fix it. The three actions (rewire onto a replacement, drop the
# spurious dep, abandon the orphan) plus the argument/guardrail edges.
#
# PLUGIN-SOURCE test: runs in the plugin's CI, not copied into a consumer .harness/.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../templates/scripts" && pwd)"
FAIL=0
assert() { local desc="$1"; shift; if "$@"; then echo "ok - $desc"; else echo "FAIL - $desc"; FAIL=1; fi; }

d="$(mktemp -d)"
git init -q -b main "$d"   # explicit -b main: rewire-dependents.sh now branch-guards against MAIN_BRANCH
                            # (default "main") — don't rely on the host's init.defaultBranch (B05)
( cd "$d" && git config user.email t@t.com && git config user.name t )
mkdir -p "$d/.harness/scripts" "$d/.harness/tracking"
cp "$SCRIPT_DIR/rewire-dependents.sh" "$SCRIPT_DIR/repo-lock.sh" "$d/.harness/scripts/"
chmod +x "$d/.harness/scripts/"*.sh

# reset_tasks '<dependsOn json array for T389>'
reset_tasks() {
  cat > "$d/.harness/tracking/TASKS.json" <<JSON
{ "tasks": [
  { "id": "T100", "status": "done", "gate": null, "scope": [] },
  { "id": "T388", "status": "failed", "gate": null, "scope": [] },
  { "id": "T473", "status": "pending", "gate": null, "scope": [], "facets": {"layer":"frontend","workType":"bugfix"} },
  { "id": "T389", "status": "pending", "gate": null, "scope": [], "dependsOn": $1, "facets": {"layer":"frontend","workType":"bugfix"} }
] }
JSON
}
deps() { jq -c '.tasks[]|select(.id=="T389")|.dependsOn' "$d/.harness/tracking/TASKS.json"; }
run() { ( cd "$d" && NO_PUSH=1 bash .harness/scripts/rewire-dependents.sh "$@" ); }

reset_tasks '["T388","T100"]'; ( cd "$d" && git add -A && git commit -q -m init )

# 1. REWIRE: swap the dead dep onto the replacement, preserving the unrelated dep
run T389 T388 T473 >/dev/null
assert "rewire: T389 dependsOn swapped T388 → T473 (T100 preserved)"  test "$(deps)" = '["T473","T100"]'

# 2. DROP: remove the dead dep entirely
reset_tasks '["T388","T100"]'
run T389 T388 --drop >/dev/null
assert "drop: T389 no longer depends on T388"                        test "$(deps)" = '["T100"]'

# 3. REWIRE with the target already present → de-dup, no duplicate T473
reset_tasks '["T388","T473","T100"]'
run T389 T388 T473 >/dev/null
assert "rewire de-dups when target already a dep"                    test "$(deps)" = '["T473","T100"]'

# 4. ABANDON: writes the manual-fail overlay for the orphan itself
reset_tasks '["T388","T100"]'
run T389 --abandon "stranded on terminal T388 — no replacement" >/dev/null
assert "abandon: manual-fail overlay marks T389 failed" \
  bash -c 'jq -e ".\"T389\".failed == true" "'"$d"'/.harness/tracking/manual-fail.json" >/dev/null'
assert "abandon: overlay keeps the reason (incl. em dash)" \
  bash -c 'jq -r ".\"T389\".reason" "'"$d"'/.harness/tracking/manual-fail.json" | grep -qF "no replacement"'
assert "abandon: did NOT touch T389's dependsOn"                     test "$(deps)" = '["T388","T100"]'

# 5. ERROR: rewiring a dep the task doesn't have
reset_tasks '["T388","T100"]'
assert "error: refuses when task doesn't depend on the named dead dep" \
  bash -c '! ( cd "'"$d"'" && NO_PUSH=1 bash .harness/scripts/rewire-dependents.sh T389 T999 T473 2>/dev/null )'

# 6. ERROR: rewire target isn't a real task
assert "error: refuses when replacement id is not a task" \
  bash -c '! ( cd "'"$d"'" && NO_PUSH=1 bash .harness/scripts/rewire-dependents.sh T389 T388 T404 2>/dev/null )'

# 7. GUARDRAIL: refuses while the loop lock is held by a live PID
GC="$d/.git"; LOCK="$GC/$(basename "$d")-loop.lock"
mkdir -p "$LOCK"; echo "$$" > "$LOCK/pid"     # $$ = this test shell — alive
reset_tasks '["T388","T100"]'
assert "guardrail: refuses to edit while the loop lock is held" \
  bash -c '! ( cd "'"$d"'" && NO_PUSH=1 bash .harness/scripts/rewire-dependents.sh T389 T388 T473 2>/dev/null )'
assert "guardrail: left dependsOn untouched when it refused"          test "$(deps)" = '["T388","T100"]'
rm -rf "$LOCK"

# 8. B05: off-main refusal — checkout a feature branch → refuses, no commit, dependsOn untouched.
( cd "$d" && git checkout -q -b feature-x )
reset_tasks '["T388","T100"]'
before="$(cd "$d" && git rev-list --count HEAD)"
assert "off-main: refuses to publish from a non-main branch" \
  bash -c '! ( cd "'"$d"'" && NO_PUSH=1 bash .harness/scripts/rewire-dependents.sh T389 T388 T473 2>/dev/null )'
assert "off-main: no commit made"         [ "$before" = "$(cd "$d" && git rev-list --count HEAD)" ]
assert "off-main: dependsOn left untouched" test "$(deps)" = '["T388","T100"]'
( cd "$d" && git checkout -q main )

# 9. B05: pathspec isolation — an unrelated staged file must not ride the rewire commit.
reset_tasks '["T388","T100"]'; ( cd "$d" && git add -A && git commit -q -m reset )
echo "unrelated WIP" >"$d/unrelated.txt"
( cd "$d" && git add unrelated.txt )
run T389 T388 T473 >/dev/null
assert "pathspec: the commit does NOT include the unrelated file" \
  bash -c "cd '$d' && ! git show --name-only --format= HEAD | grep -qF unrelated.txt"
assert "pathspec: the unrelated staged file is still staged (not committed, not lost)" \
  bash -c "cd '$d' && git diff --cached --name-only | grep -qF unrelated.txt"

rm -rf "$d"

# 10. C03: push_with_retry — a moved origin/main (another owner action landed first) doesn't lose the
# rewire edit; a single failed push attempt would have, since the OLD hand-rolled push here was one-shot.
d="$(mktemp -d)"; bare="$(mktemp -d)"
git init -q --bare -b main "$bare"
git init -q -b main "$d"
( cd "$d" && git config user.email t@t.com && git config user.name t )
mkdir -p "$d/.harness/scripts" "$d/.harness/tracking"
cp "$SCRIPT_DIR/rewire-dependents.sh" "$SCRIPT_DIR/repo-lock.sh" "$d/.harness/scripts/"
chmod +x "$d/.harness/scripts/"*.sh
cat > "$d/.harness/tracking/TASKS.json" <<'JSON'
{ "tasks": [
  { "id": "T100", "status": "done", "gate": null, "scope": [] },
  { "id": "T388", "status": "failed", "gate": null, "scope": [] },
  { "id": "T473", "status": "pending", "gate": null, "scope": [], "facets": {"layer":"frontend","workType":"bugfix"} },
  { "id": "T389", "status": "pending", "gate": null, "scope": [], "dependsOn": ["T388","T100"], "facets": {"layer":"frontend","workType":"bugfix"} }
] }
JSON
( cd "$d" && git add -A && git commit -q -m init && git remote add origin "$bare" && git push -q -u origin main )
# A second, independent clone pushes a decoy commit first — origin/main moves out from under $d.
d2="$(mktemp -d)"; git clone -q "$bare" "$d2"
( cd "$d2" && git config user.email t2@t2.com && git config user.name t2 && echo decoy >decoy.txt && git add decoy.txt && git commit -q -m decoy && git push -q origin main )
( cd "$d" && bash .harness/scripts/rewire-dependents.sh T389 T388 T473 >/dev/null )
assert "moved-remote: origin/main contains BOTH the decoy and the rewire commit" \
  bash -c "cd '$bare' && git log --format=%s main | grep -qF decoy && git log --format=%s main | grep -qF 'rewire-dependents'"
assert "moved-remote: the rewire actually landed on origin (not just local)" \
  bash -c "git -C '$bare' show main:.harness/tracking/TASKS.json | jq -e '.tasks[]|select(.id==\"T389\")|.dependsOn==[\"T473\",\"T100\"]' >/dev/null"
rm -rf "$d" "$d2" "$bare"

[ "$FAIL" = 0 ] && echo "ALL PASS" || { echo "SOME FAILED"; exit 1; }
