#!/usr/bin/env bash
#
# loop-extend.test.sh — hermetic tests for the custom/ behavior+config extension points added to BOTH
# loop variants: the append-only pre-push guard denylist (custom/sensitive-paths.txt) and the lifecycle
# hook dispatcher (run_hook → custom/hooks/on-<event>.sh). Spins up throwaway git repos (mktemp -d) so it
# never touches a real harness.
#
# This is a PLUGIN-SOURCE test: it exercises BOTH loop variants, which only coexist here in templates/.
# It runs in the plugin's CI and is NOT copied into a consumer's .harness/ (an install has only one
# variant). Run it from the plugin checkout:  plugins/.../templates/scripts/loop-extend.test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAIL=0
assert() { local desc="$1"; shift; if "$@"; then echo "ok - $desc"; else echo "FAIL - $desc"; FAIL=1; fi; }

setup_repo() {   # echoes the repo path — a git repo whose .harness/scripts holds both loop variants
  local d
  d="$(mktemp -d)"
  git init -q "$d"
  ( cd "$d" && git config user.email t@t.com && git config user.name t )
  mkdir -p "$d/.harness/scripts" "$d/.harness/config" "$d/.harness/custom/hooks"
  cp "$SCRIPT_DIR/repo-lock.sh" "$SCRIPT_DIR/loop.sh" "$SCRIPT_DIR/loop.in-place.sh" "$d/.harness/scripts/"
  chmod +x "$d/.harness/scripts/"*.sh
  ( cd "$d" && git add -A && git commit -q -m init )
  echo "$d"
}

# ============ Guard denylist extension — end-to-end through each variant's --guard-selftest ============
probe() { ( cd "$1" && ".harness/scripts/$2" --guard-selftest "$3" 2>/dev/null ); }   # <repo> <variant> <path> → BLOCK/ALLOW

for V in loop.sh loop.in-place.sh; do
  d="$(setup_repo)"; CF="$d/.harness/custom/sensitive-paths.txt"

  # no custom file → base guard only
  assert "[$V] base selftest passes (no custom file)"  bash -c "( cd '$d' && .harness/scripts/$V --guard-selftest >/dev/null 2>&1 )"
  assert "[$V] base BLOCKs .env"                        test "$(probe "$d" "$V" '.env')" = BLOCK
  assert "[$V] base ALLOWs a would-be-custom path"      test "$(probe "$d" "$V" 'my-secrets/x')" = ALLOW

  # valid custom pattern → tightens the guard; base allow-list still wins; base cases still pass
  printf '# my project\n(^|/)my-secrets/\n\n' > "$CF"
  assert "[$V] custom pattern BLOCKs its path"          test "$(probe "$d" "$V" 'my-secrets/x')" = BLOCK
  assert "[$V] base .env.example still ALLOWed"         test "$(probe "$d" "$V" '.env.example')" = ALLOW
  assert "[$V] base selftest still passes with custom"  bash -c "( cd '$d' && .harness/scripts/$V --guard-selftest >/dev/null 2>&1 )"

  # blank + #-comment lines are ignored (only the real pattern took effect above); confirm a pure
  # comment/blank file is a no-op (base only)
  printf '# just a comment\n\n   \n' > "$CF"
  assert "[$V] comment/blank-only file → base only"     test "$(probe "$d" "$V" 'my-secrets/x')" = ALLOW

  # invalid custom regex → WARN + base-only fallback (custom ignored, base intact, guard never disabled)
  printf '[unterminated\n' > "$CF"
  warn="$( cd "$d" && ".harness/scripts/$V" --guard-selftest 'my-secrets/x' 2>&1 >/dev/null )"
  assert "[$V] invalid regex logs a WARN"               bash -c "case \"\$1\" in *'invalid regex'*) exit 0;; *) exit 1;; esac" _ "$warn"
  assert "[$V] invalid regex → custom ignored"          test "$(probe "$d" "$V" 'my-secrets/x')" = ALLOW
  assert "[$V] invalid regex → base guard intact"       test "$(probe "$d" "$V" '.env')" = BLOCK
  rm -rf "$d"
done

# ============ Lifecycle hook dispatcher — exercise the REAL run_hook() extracted from the shipped loop ==
d="$(setup_repo)"
sed -n '/^run_hook() {/,/^}/p' "$SCRIPT_DIR/loop.sh" > "$d/run_hook.inc"
assert "extracted run_hook() from loop.sh" test -s "$d/run_hook.inc"
# a self-contained probe: log stub + the real run_hook + an invocation printing its return code
{ echo 'log(){ printf "[loop] %s\n" "$*" >&2; }'; cat "$d/run_hook.inc"; echo 'run_hook "$@"; echo "rc=$?"'; } > "$d/probe.sh"
drive() { HARNESS_DIR="$d/.harness" ROOT="$d" MAIN_BRANCH="main" bash "$d/probe.sh" "$@" 2>/dev/null; }

# no hook file present → no-op, returns 0
assert "run_hook no-ops when hook absent (rc 0)"  bash -c "case \"\$1\" in *rc=0*) exit 0;; *) exit 1;; esac" _ "$(drive drained drained)"

# present hook → runs as a child with \$1 + exported HARNESS_* ; capture what the hook actually saw
PROBE="$d/.harness/custom/hooks/.seen"
cat > "$d/.harness/custom/hooks/on-drained.sh" <<EOF
#!/usr/bin/env bash
printf '%s|%s|%s|%s\n' "\$1" "\$HARNESS_ROOT" "\$HARNESS_DIR" "\$HARNESS_MAIN_BRANCH" > "$PROBE"
EOF
out="$(drive drained drained)"
assert "run_hook runs a present hook (rc 0)"      bash -c "case \"\$1\" in *rc=0*) exit 0;; *) exit 1;; esac" _ "$out"
assert "hook received reason arg \$1=drained"     test "$(cut -d'|' -f1 "$PROBE")" = drained
assert "hook got HARNESS_ROOT exported"           test "$(cut -d'|' -f2 "$PROBE")" = "$d"
assert "hook got HARNESS_DIR exported"            test "$(cut -d'|' -f3 "$PROBE")" = "$d/.harness"
assert "hook got HARNESS_MAIN_BRANCH exported"    test "$(cut -d'|' -f4 "$PROBE")" = main

# a hook that exits non-zero is NON-FATAL — run_hook still returns 0
cat > "$d/.harness/custom/hooks/on-blocked.sh" <<'EOF'
#!/usr/bin/env bash
exit 7
EOF
assert "nonzero hook exit is non-fatal (rc 0)"    bash -c "case \"\$1\" in *rc=0*) exit 0;; *) exit 1;; esac" _ "$(drive blocked T042 'some reason')"
rm -rf "$d"

# ============ Structural wiring assertions on the shipped loops ============
for V in loop.sh loop.in-place.sh; do
  L="$SCRIPT_DIR/$V"
  for ev in "run_hook drained drained" "run_hook drained idle" "run_hook exhausted max-iters" "run_hook exhausted rate-limit" "run_hook blocked" "run_hook integrated"; do
    assert "[$V] wires: $ev" grep -qF "$ev" "$L"
  done
  # a lifecycle hook must NEVER fire on the prereq/config error exit path (exit 3)
  assert "[$V] no run_hook on an exit-3 line" bash -c "! grep -nE 'run_hook.*exit 3|exit 3.*run_hook' '$L'"
done

if [ "$FAIL" = 0 ]; then echo "loop-extend.test.sh: ALL PASS"; else echo "loop-extend.test.sh: FAILURES"; exit 1; fi
