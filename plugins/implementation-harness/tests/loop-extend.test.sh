#!/usr/bin/env bash
#
# loop-extend.test.sh — hermetic tests for the custom/ behavior+config extension points added to BOTH
# loop variants: the append-only pre-push guard denylist (custom/sensitive-paths.txt) and the lifecycle
# hook dispatcher (run_hook → custom/hooks/on-<event>.sh). Spins up throwaway git repos (mktemp -d) so it
# never touches a real harness.
#
# This is a PLUGIN-SOURCE test: it exercises BOTH loop variants, which only coexist here in templates/.
# It runs in the plugin's CI and is NOT copied into a consumer's .harness/ (an install has only one
# variant). Run it from the plugin checkout:  plugins/.../tests/loop-extend.test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../templates/scripts" && pwd)"
FAIL=0
assert() { local desc="$1"; shift; if "$@"; then echo "ok - $desc"; else echo "FAIL - $desc"; FAIL=1; fi; }

setup_repo() {   # echoes the repo path — a git repo whose .harness/scripts holds both loop variants
  local d
  d="$(mktemp -d)"
  git init -q "$d"
  ( cd "$d" && git config user.email t@t.com && git config user.name t )
  mkdir -p "$d/.harness/scripts" "$d/.harness/config" "$d/.harness/custom/hooks"
  cp "$SCRIPT_DIR/repo-lock.sh" "$SCRIPT_DIR/scope-lib.sh" "$SCRIPT_DIR/loop-lib.sh" "$SCRIPT_DIR/loop.sh" "$SCRIPT_DIR/loop.in-place.sh" "$d/.harness/scripts/"
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

# ============ Visual-verify project snippet injection (custom/visual-verify-{build,audit}.md) ==========
# Extract the REAL visual_verify_block + _visual_verify_custom from the shipped loop (byte-identical across
# variants) and drive them with a tj() stub that opts the task in, so the block fires and we can check the
# snippet is appended when present / absent when not.
d="$(setup_repo)"; mkdir -p "$d/.harness/custom"
{
  echo 'tj(){ echo true; }'                    # any .visualVerify read → "true" → block fires (skips heuristic)
  echo 'VISUAL_VERIFY_HOOK="echo shot"'
  printf 'HARNESS_DIR=%q\n' "$d/.harness"
  sed -n '/^_visual_verify_custom() {/,/^}/p' "$SCRIPT_DIR/loop.sh"
  sed -n '/^visual_verify_block() {/,/^}/p' "$SCRIPT_DIR/loop.sh"
  echo 'visual_verify_block "$@"'
} > "$d/vv.sh"
vv() { bash "$d/vv.sh" "$@" 2>/dev/null; }
has() { case "$2" in *"$1"*) return 0;; *) return 1;; esac; }
CB="$d/.harness/custom/visual-verify-build.md"; CA="$d/.harness/custom/visual-verify-audit.md"

# absent → generic block fires, NO project snippet (byte-identical to stock)
ob="$(vv T1)"; oa="$(vv T1 audit)"
assert "vv build: generic block fires"            has 'VISUAL VERIFICATION' "$ob"
assert "vv audit: generic block fires"            has 'VISUAL EVIDENCE' "$oa"
assert "vv build: no snippet marker when absent"  bash -c 'case "$1" in *PROJECT-SPECIFIC*) exit 1;; *) exit 0;; esac' _ "$ob"
assert "vv audit: no snippet marker when absent"  bash -c 'case "$1" in *PROJECT-SPECIFIC*) exit 1;; *) exit 0;; esac' _ "$oa"

# build snippet present → appears in BUILD only
printf 'CAPTURE-THE-DASHBOARD-ROUTE\n' > "$CB"
ob="$(vv T1)"; oa="$(vv T1 audit)"
assert "vv build: snippet marker appended"        has 'PROJECT-SPECIFIC VISUAL VERIFICATION GUIDANCE' "$ob"
assert "vv build: snippet content appended"       has 'CAPTURE-THE-DASHBOARD-ROUTE' "$ob"
assert "vv audit: build snippet does NOT leak"    bash -c 'case "$1" in *CAPTURE-THE-DASHBOARD-ROUTE*) exit 1;; *) exit 0;; esac' _ "$oa"

# audit snippet present → appears in AUDIT
printf 'FAIL-IF-THE-CHART-IS-BLANK\n' > "$CA"
oa="$(vv T1 audit)"
assert "vv audit: snippet marker appended"        has 'PROJECT-SPECIFIC VISUAL VERIFICATION GUIDANCE' "$oa"
assert "vv audit: snippet content appended"       has 'FAIL-IF-THE-CHART-IS-BLANK' "$oa"
rm -rf "$d"

# ============ Build/audit prompt preamble injection (custom/{build,audit}-preamble.md) ============
# Extract the REAL _custom_preamble (byte-identical across variants) and exercise it directly — it's
# unconditional (no task gating), so no tj stub is needed.
d="$(setup_repo)"; mkdir -p "$d/.harness/custom"
{ printf 'HARNESS_DIR=%q\n' "$d/.harness"; sed -n '/^_custom_preamble() {/,/^}/p' "$SCRIPT_DIR/loop.sh"; echo '_custom_preamble "$@"'; } > "$d/pre.sh"
pre() { bash "$d/pre.sh" "$@" 2>/dev/null; }
BP="$d/.harness/custom/build-preamble.md"; AP="$d/.harness/custom/audit-preamble.md"

# absent → empty output (byte-identical prior prompt)
assert "preamble build: empty when absent"     bash -c 'case "$1" in ?*) exit 1;; *) exit 0;; esac' _ "$(pre build)"
assert "preamble audit: empty when absent"     bash -c 'case "$1" in ?*) exit 1;; *) exit 0;; esac' _ "$(pre audit)"

# build preamble present → appears (BUILD label) in build only
printf 'NEVER-CALL-PAID-APIS\n' > "$BP"
ob="$(pre build)"; oa="$(pre audit)"
assert "preamble build: BUILD marker appended"  has 'PROJECT-SPECIFIC BUILD GUIDANCE' "$ob"
assert "preamble build: content appended"        has 'NEVER-CALL-PAID-APIS' "$ob"
assert "preamble audit: build file not read"     bash -c 'case "$1" in *NEVER-CALL-PAID-APIS*) exit 1;; *) exit 0;; esac' _ "$oa"

# audit preamble present → appears (AUDIT label) in audit
printf 'USE-CACHED-FIXTURES\n' > "$AP"
oa="$(pre audit)"
assert "preamble audit: AUDIT marker appended"  has 'PROJECT-SPECIFIC AUDIT GUIDANCE' "$oa"
assert "preamble audit: content appended"        has 'USE-CACHED-FIXTURES' "$oa"
rm -rf "$d"

# ============ Structural wiring assertions on the shipped loops ============
for V in loop.sh loop.in-place.sh; do
  L="$SCRIPT_DIR/$V"
  # NOTE: idle no longer fires `drained` — an idle verdict is per-task (reconciled + continue), not a
  # drained backlog. The only `drained` fire point is the real select_task-empty exit (`drained drained`).
  for ev in "run_hook drained drained" "run_hook exhausted max-iters" "run_hook exhausted rate-limit" "run_hook blocked" "run_hook integrated" "_visual_verify_custom audit" "_visual_verify_custom build" "_custom_preamble build" "_custom_preamble audit"; do
    assert "[$V] wires: $ev" grep -qF "$ev" "$L"
  done
  # a lifecycle hook must NEVER fire on the prereq/config error exit path (exit 3)
  assert "[$V] no run_hook on an exit-3 line" bash -c "! grep -nE 'run_hook.*exit 3|exit 3.*run_hook' '$L'"
done

if [ "$FAIL" = 0 ]; then echo "loop-extend.test.sh: ALL PASS"; else echo "loop-extend.test.sh: FAILURES"; exit 1; fi
