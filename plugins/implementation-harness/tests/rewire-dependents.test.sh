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
git init -q "$d"
( cd "$d" && git config user.email t@t.com && git config user.name t )
mkdir -p "$d/.harness/scripts" "$d/.harness/tracking"
cp "$SCRIPT_DIR/rewire-dependents.sh" "$d/.harness/scripts/"
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

rm -rf "$d"
[ "$FAIL" = 0 ] && echo "ALL PASS" || { echo "SOME FAILED"; exit 1; }
