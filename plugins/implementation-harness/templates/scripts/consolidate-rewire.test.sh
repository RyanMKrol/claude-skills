#!/usr/bin/env bash
#
# consolidate-rewire.test.sh — regression test for consolidate-ideas.mjs rewiring the pre-existing
# dependents of a review-failed replacement. A review-failed unit that re-attempts a terminal-failed
# task carries rewireFrom/rewireDependents; consolidation must swap the dead id for the replacement's
# new id in each named dependent's dependsOn (else the dependent is stranded forever — the incident this
# fixes). Plugin-source test: runs in the plugin's CI, not copied into a consumer .harness/.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
command -v node >/dev/null 2>&1 || { echo "SKIP - node not available"; exit 0; }
command -v jq   >/dev/null 2>&1 || { echo "SKIP - jq not available"; exit 0; }
FAIL=0
assert() { local d="$1"; shift; if "$@"; then echo "ok - $d"; else echo "FAIL - $d"; FAIL=1; fi; }

d="$(mktemp -d)"
trap 'rm -rf "$d"' EXIT
mkdir -p "$d/scripts" "$d/tracking" "$d/tasks" "$d/.pending-tasks"
cp "$SCRIPT_DIR/consolidate-ideas.mjs" "$d/scripts/"
cat > "$d/tracking/TASKS.json" <<'JSON'
{"tasks":[
  {"id":"T388","title":"failed original","status":"failed","dependsOn":[],"gate":null,"tags":[],"scope":[],"verify":[],"expectsTest":false},
  {"id":"T389","title":"dependent","status":"pending","dependsOn":["T388","T100"],"gate":null,"tags":[],"scope":[],"verify":[],"expectsTest":false}
]}
JSON
cat > "$d/.pending-tasks/reattempt.json" <<'JSON'
{"units":[{"tempId":"re-a","title":"re-attempt of T388","dependsOn":[],"gate":null,"tags":[],"scope":["x"],"verify":[],"expectsTest":false,
  "facets":{"layer":"db","workType":"feature","risk":[]},"specOverview":"Re-attempt of T388.","specDo":"do","specDoneWhen":"pass",
  "rewireFrom":"T388","rewireDependents":["T389"]}]}
JSON

node "$d/scripts/consolidate-ideas.mjs" >/dev/null

j="$d/tracking/TASKS.json"
newid="$(jq -r '.tasks[] | select(.title=="re-attempt of T388") | .id' "$j")"
has388="$(jq -r '.tasks[] | select(.id=="T389") | (.dependsOn | index("T388")) != null' "$j")"
hasNew="$(jq -r --arg n "$newid" '.tasks[] | select(.id=="T389") | (.dependsOn | index($n)) != null' "$j")"
has100="$(jq -r '.tasks[] | select(.id=="T389") | (.dependsOn | index("T100")) != null' "$j")"

assert "a replacement task was created"                  test -n "$newid"
assert "T389 no longer depends on the dead T388"          test "$has388" = false
assert "T389 now depends on the replacement ($newid)"     test "$hasNew" = true
assert "T389's unrelated dep T100 is preserved"           test "$has100" = true

[ "$FAIL" = 0 ] && echo "ALL PASS" || { echo "SOME FAILED"; exit 1; }
