#!/usr/bin/env bash
#
# consolidate-rewire.test.sh — regression test for consolidate-ideas.mjs rewiring the pre-existing
# dependents of a review-failed replacement. A review-failed unit that re-attempts a terminal-failed
# task carries rewireFrom/rewireDependents; consolidation must swap the dead id for the replacement's
# new id in each named dependent's dependsOn (else the dependent is stranded forever — the incident this
# fixes). The scenario also runs under a path CONTAINING A SPACE (B13 regression: the old
# `new URL(import.meta.url).pathname` derivation percent-encoded the path — `.../with%20space/...` —
# and ENOENTed every fs call, breaking consolidation for any repo whose path has a space).
# Plugin-source test: runs in the plugin's CI, not copied into a consumer .harness/.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
command -v node >/dev/null 2>&1 || { echo "SKIP - node not available"; exit 0; }
command -v jq   >/dev/null 2>&1 || { echo "SKIP - jq not available"; exit 0; }
FAIL=0
assert() { local d="$1"; shift; if "$@"; then echo "ok - $d"; else echo "FAIL - $d"; FAIL=1; fi; }

TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

# run_scenario <harness-dir> <label> — set up the rewire fixture under the given harness dir, run the
# consolidator, and assert the rewire happened. <harness-dir> may contain spaces (quoted throughout).
run_scenario() {
  local d="$1" label="$2"
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

  # The consolidator running to completion is itself the B13 assertion under a spaced path — pre-fix
  # it ENOENTs on the percent-encoded path and exits non-zero here.
  if node "$d/scripts/consolidate-ideas.mjs" >/dev/null 2>&1; then
    assert "[$label] consolidator ran without error" true
  else
    assert "[$label] consolidator ran without error" false
    return
  fi

  local j="$d/tracking/TASKS.json" newid has388 hasNew has100
  newid="$(jq -r '.tasks[] | select(.title=="re-attempt of T388") | .id' "$j")"
  has388="$(jq -r '.tasks[] | select(.id=="T389") | (.dependsOn | index("T388")) != null' "$j")"
  hasNew="$(jq -r --arg n "$newid" '.tasks[] | select(.id=="T389") | (.dependsOn | index($n)) != null' "$j")"
  has100="$(jq -r '.tasks[] | select(.id=="T389") | (.dependsOn | index("T100")) != null' "$j")"

  assert "[$label] a replacement task was created"              test -n "$newid"
  assert "[$label] T389 no longer depends on the dead T388"     test "$has388" = false
  assert "[$label] T389 now depends on the replacement"         test "$hasNew" = true
  assert "[$label] T389's unrelated dep T100 is preserved"      test "$has100" = true
}

run_scenario "$TMPROOT/plain"      "plain path"
run_scenario "$TMPROOT/with space" "path with a space (B13)"

[ "$FAIL" = 0 ] && echo "ALL PASS" || { echo "SOME FAILED"; exit 1; }
