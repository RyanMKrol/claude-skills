#!/usr/bin/env bash
#
# scope-gap-dismiss.test.sh — hermetic round-trip test for the scope-gap dismissal writer and its
# contract with check-task-scope.sh (the reader). Spins up a throwaway git repo (mktemp -d).
#
# Guards two things:
#   1. THE FIX: scope-gap-dismiss.sh replaces fix-scope-gaps' old inline multi-line jq/hash command — the
#      one that intermittently broke ("command not found") when a house-style em-dash reason landed in a
#      multi-line shell command. So this test dismisses with an em-dash reason and asserts it's stored
#      intact and honored — the whole point of routing the free text through a script argument.
#   2. THE CONTRACT: scope-gap-dismiss.sh (writer) and check-task-scope.sh (reader) must agree on the
#      file path, the {path, specHash} fields, and how the spec is hashed. The round trip (warn →
#      dismiss → suppressed → spec changes → warn resurfaces) fails loudly if either side drifts.
#
# PLUGIN-SOURCE test: runs in the plugin's CI, not copied into a consumer .harness/.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../templates/scripts" && pwd)"
FAIL=0
assert() { local desc="$1"; shift; if "$@"; then echo "ok - $desc"; else echo "FAIL - $desc"; FAIL=1; fi; }

d="$(mktemp -d)"
git init -q "$d"
( cd "$d" && git config user.email t@t.com && git config user.name t )
mkdir -p "$d/.harness/scripts" "$d/.harness/tracking" "$d/.harness/tasks" "$d/src/foo"
cp "$SCRIPT_DIR/scope-lib.sh" "$SCRIPT_DIR/check-task-scope.sh" "$SCRIPT_DIR/scope-gap-dismiss.sh" "$d/.harness/scripts/"
chmod +x "$d/.harness/scripts/"*.sh

# A task whose spec instructs editing an OUT-OF-scope path (src/foo/bar.js), plus an in-scope mention.
cat > "$d/.harness/tracking/TASKS.json" <<'JSON'
{ "tasks": [
  { "id": "T042", "status": "pending", "gate": null, "spec": ".harness/tasks/T042.md",
    "scope": ["src/keep.js"], "facets": {"layer":"frontend","workType":"bugfix"} }
] }
JSON
cat > "$d/.harness/tasks/T042.md" <<'MD'
# T042 — do the thing
Edit `src/foo/bar.js` to fix the bug. See `src/keep.js` for the existing pattern (context only).
MD
# a real tracked file under src/ so check-task-scope's PREFIX_ALT recognizes `src/...` mentions
echo "// keep" > "$d/src/keep.js"
( cd "$d" && git add -A && git commit -q -m init )

warns() { ( cd "$d" && bash .harness/scripts/check-task-scope.sh T042 2>/dev/null ); }
ignore_file="$d/.harness/.scope-gap-ignores/T042.json"

# 1. Before dismissal: the out-of-scope path is flagged.
assert "check flags the out-of-scope src/foo/bar.js"      bash -c 'warns() { ( cd "'"$d"'" && bash .harness/scripts/check-task-scope.sh T042 2>/dev/null ); }; warns | grep -qF "src/foo/bar.js"'

# 2. Dismiss it via the script — single arg reason WITH an em dash (the exact case that broke inline).
( cd "$d" && bash .harness/scripts/scope-gap-dismiss.sh "T042" "src/foo/bar.js" "cited as a read-only exemption reference — not an edit target" >/dev/null )
assert "dismissal file written"                            test -f "$ignore_file"
assert "dismissal records the path"                        bash -c 'jq -e ".dismissed[]|select(.path==\"src/foo/bar.js\")" "'"$ignore_file"'" >/dev/null'
assert "em-dash reason stored intact (not mangled)"        bash -c 'jq -r ".dismissed[0].reason" "'"$ignore_file"'" | grep -qF "read-only exemption reference — not an edit target"'
assert "specHash matches the real spec hash"               bash -c '
  h="$(jq -r ".dismissed[0].specHash" "'"$ignore_file"'")"
  if command -v sha256sum >/dev/null 2>&1; then real="$(sha256sum "'"$d"'/.harness/tasks/T042.md" | awk "{print \$1}")"; else real="$(shasum -a 256 "'"$d"'/.harness/tasks/T042.md" | awk "{print \$1}")"; fi
  [ "$h" = "$real" ]'

# 3. After dismissal: the warning is suppressed (reader honors writer).
assert "check no longer flags the dismissed path"          bash -c '! ( cd "'"$d"'" && bash .harness/scripts/check-task-scope.sh T042 2>/dev/null ) | grep -qF "src/foo/bar.js"'

# 4. Idempotent: re-dismissing the same (id,path) doesn't duplicate the entry.
( cd "$d" && bash .harness/scripts/scope-gap-dismiss.sh "T042" "src/foo/bar.js" "same path again" >/dev/null )
assert "re-dismiss replaces, not appends (one entry for the path)" \
  bash -c 'test "$(jq "[.dismissed[]|select(.path==\"src/foo/bar.js\")]|length" "'"$ignore_file"'")" = 1'

# 5. Auto-expire: editing the spec changes its hash, so the stale dismissal stops matching → warn returns.
printf '\nAlso touch `src/foo/bar.js` again.\n' >> "$d/.harness/tasks/T042.md"
assert "dismissal auto-expires when the spec changes (warn resurfaces)" \
  bash -c '( cd "'"$d"'" && bash .harness/scripts/check-task-scope.sh T042 2>/dev/null ) | grep -qF "src/foo/bar.js"'

rm -rf "$d"
[ "$FAIL" = 0 ] && echo "ALL PASS" || { echo "SOME FAILED"; exit 1; }
